#!/bin/bash

###############################################################################
# Proxmox VE 节点重命名脚本（精确两步法）
# 版本: 1.1
# 描述: 严格按照两步法重命名PVE节点（单节点环境）
#      第二步使用 mv 迁移虚拟机配置文件，保证 pmxcfs 元数据正确
###############################################################################

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置文件路径
HOSTS_FILE="/etc/hosts"
HOSTNAME_FILE="/etc/hostname"
POSTFIX_FILE="/etc/postfix/main.cf"

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

###############################################################################
# 第一步：备份和修改系统配置文件
###############################################################################
step1_backup_and_modify() {
    local OLD_NODE="$1"
    local NEW_NODE="$2"
    
    log_step "========== 第一步：备份和修改系统配置文件 =========="
    
    # 1. 创建备份目录
    BACKUP_DIR="/root/backup_pve_rename_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR/old_node"
    log_info "备份目录: $BACKUP_DIR"

    # 2. 备份节点配置
    OLD_NODE_DIR="/etc/pve/nodes/$OLD_NODE"
    if [[ -d "$OLD_NODE_DIR" ]]; then
        mkdir -p "$BACKUP_DIR/old_node/lxc" "$BACKUP_DIR/old_node/qemu-server"
        cp -a "$OLD_NODE_DIR/lxc"/*.conf "$BACKUP_DIR/old_node/lxc/" 2>/dev/null || true
        cp -a "$OLD_NODE_DIR/qemu-server"/*.conf "$BACKUP_DIR/old_node/qemu-server/" 2>/dev/null || true
        find "$OLD_NODE_DIR" -maxdepth 1 -name "*.conf" -exec cp {} "$BACKUP_DIR/old_node/" \; 2>/dev/null || true
    else
        log_error "原节点目录不存在: $OLD_NODE_DIR"
        exit 1
    fi

    # 3. 备份系统文件
    cp "$HOSTS_FILE" "$BACKUP_DIR/hosts.backup"
    cp "$HOSTNAME_FILE" "$BACKUP_DIR/hostname.backup"
    [[ -f "$POSTFIX_FILE" ]] && cp "$POSTFIX_FILE" "$BACKUP_DIR/main.cf.backup"

    # 4. 修改系统文件
    echo "$NEW_NODE" > "$HOSTNAME_FILE"
    
    cp "$HOSTS_FILE" "${HOSTS_FILE}.tmp"
    CURRENT_IP=$(hostname -I | awk '{print $1}')
    sed -i "/[[:space:]]$OLD_NODE$/d" "${HOSTS_FILE}.tmp"
    sed -i "/[[:space:]]$OLD_NODE[[:space:]]/d" "${HOSTS_FILE}.tmp"
    if grep -q "^$CURRENT_IP" "${HOSTS_FILE}.tmp"; then
        sed -i "s/^$CURRENT_IP.*/$CURRENT_IP $NEW_NODE/" "${HOSTS_FILE}.tmp"
    else
        echo "$CURRENT_IP $NEW_NODE" >> "${HOSTS_FILE}.tmp"
    fi
    mv "${HOSTS_FILE}.tmp" "$HOSTS_FILE"

    [[ -f "$POSTFIX_FILE" ]] && sed -i "s/$OLD_NODE/$NEW_NODE/g" "$POSTFIX_FILE"

    # 5. 保存状态信息
    echo "OLD_NODE=$OLD_NODE" > "$BACKUP_DIR/rename.info"
    echo "NEW_NODE=$NEW_NODE" >> "$BACKUP_DIR/rename.info"
    echo "BACKUP_DIR=$BACKUP_DIR" >> "$BACKUP_DIR/rename.info"
    echo "STEP=1" >> "$BACKUP_DIR/rename.info"

    log_step "第一步完成！请重启服务器: reboot"
}

###############################################################################
# 第二步：迁移配置文件（使用 mv）和清理旧节点目录
###############################################################################
step2_migrate_and_cleanup() {
    local BACKUP_DIR="$1"

    log_step "========== 第二步：迁移配置文件（使用 mv）并清理旧节点 =========="

    source "$BACKUP_DIR/rename.info"

    CURRENT_HOSTNAME=$(hostname)
    if [[ "$CURRENT_HOSTNAME" != "$NEW_NODE" ]]; then
        log_error "当前主机名 ($CURRENT_HOSTNAME) 与新节点名 ($NEW_NODE) 不匹配"
        exit 1
    fi
    log_info "主机名验证通过: $CURRENT_HOSTNAME"

    OLD_NODE_DIR="/etc/pve/nodes/$OLD_NODE"
    NEW_NODE_DIR="/etc/pve/nodes/$NEW_NODE"

    # LXC 配置迁移
    if [[ -d "$OLD_NODE_DIR/lxc" ]]; then
        mkdir -p "$NEW_NODE_DIR/lxc"
        mv "$OLD_NODE_DIR/lxc/"*.conf "$NEW_NODE_DIR/lxc/" 2>/dev/null || true
        log_info "✓ 已迁移 LXC 配置文件"
    fi

    # QEMU 配置迁移
    if [[ -d "$OLD_NODE_DIR/qemu-server" ]]; then
        mkdir -p "$NEW_NODE_DIR/qemu-server"
        mv "$OLD_NODE_DIR/qemu-server/"*.conf "$NEW_NODE_DIR/qemu-server/" 2>/dev/null || true
        log_info "✓ 已迁移 QEMU 配置文件"
    fi

    # 迁移其他配置文件
    for conf_file in "$OLD_NODE_DIR"/*.conf; do
        [[ -f "$conf_file" ]] || continue
        mv "$conf_file" "$NEW_NODE_DIR/"
        log_info "迁移配置文件: $(basename "$conf_file")"
    done

    # 删除旧节点目录
    rm -rf "$OLD_NODE_DIR"
    log_info "✓ 旧节点目录已删除"

    # 更新状态
    echo "STEP=2" > "$BACKUP_DIR/rename.info"

    log_step "第二步完成！请重启服务器以确保所有服务使用新配置"
}

###############################################################################
# 主函数
###############################################################################
main() {
    echo "================================================================"
    echo "      Proxmox VE 节点重命名脚本（精确两步法）"
    echo "================================================================"

    # root 权限检查
    [[ $EUID -ne 0 ]] && { log_error "此脚本必须以root运行"; exit 1; }

    # 集群检查
    [[ -f /etc/pve/corosync.conf ]] && { log_error "检测到集群配置，本脚本仅适用于单节点"; exit 1; }

    local OLD_NODE=$(hostname)

    # 查找最近备份
    local latest_backup=""
    for backup in /root/backup_pve_rename_*/rename.info; do
        [[ -f "$backup" ]] && latest_backup="$backup"
    done

    if [[ -n "$latest_backup" ]]; then
        source "$latest_backup" 2>/dev/null || true
        if [[ "$STEP" == "1" ]]; then
            log_info "检测到未完成的第二步，备份目录: $(dirname "$latest_backup")"
            read -p "是否继续执行 STEP=2? (y/N): " CONFIRM
            [[ "$CONFIRM" =~ ^[Yy]$ ]] && step2_migrate_and_cleanup "$(dirname "$latest_backup")"
            exit 0
        fi
    fi

    # 第一步获取新节点名
    log_info "当前节点名: $OLD_NODE"
    read -p "请输入新的节点名: " NEW_NODE
    [[ -z "$NEW_NODE" ]] && { log_error "新节点名不能为空"; exit 1; }
    [[ "$NEW_NODE" == "$OLD_NODE" ]] && { log_error "新节点名与原节点名相同"; exit 1; }
    [[ -d "/etc/pve/nodes/$NEW_NODE" ]] && { log_error "新节点目录已存在"; exit 1; }

    log_step "重命名计划: 从 $OLD_NODE -> $NEW_NODE"
    read -p "是否继续执行第一步? (y/N): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { log_info "操作已取消"; exit 0; }

    # 执行第一步
    step1_backup_and_modify "$OLD_NODE" "$NEW_NODE"
}

###############################################################################
# 脚本执行入口
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
