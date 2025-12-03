#!/bin/bash

# Proxmox VE 单节点重命名脚本 (优化版)
# 已解决 "command not found" 错误问题，增强了错误处理和恢复机制
# 注意：此脚本仅适用于非集群（单节点）环境！

set -e  # 遇到任何错误立即退出脚本

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以root权限运行"
        exit 1
    fi
}

# 检查环境是否为单节点
check_environment() {
    log_info "正在检查当前环境..."
    
    if [[ -f /etc/pve/corosync.conf ]]; then
        log_error "检测到集群配置文件。此脚本仅适用于单节点环境！"
        read -p "强制继续? (y/N): " force_confirm
        if [[ ! $force_confirm =~ ^[Yy]$ ]]; then
            exit 1
        fi
        log_warn "您已选择强制继续，请自行承担风险。"
    fi
    
    log_info "环境检查通过：当前为单节点环境"
}

# 备份配置
backup_config() {
    local original_hostname="$1"
    local backup_dir="/root/pve_rename_backup_$(date +%Y%m%d_%H%M%S)"
    
    log_info "正在创建备份到目录: $backup_dir"
    mkdir -p "$backup_dir"
    
    # 备份关键系统文件
    cp -a /etc/hosts "$backup_dir/" 2>/dev/null || true
    cp -a /etc/hostname "$backup_dir/" 2>/dev/null || true
    [[ -f /etc/postfix/main.cf ]] && cp -a /etc/postfix/main.cf "$backup_dir/" 2>/dev/null || true
    
    # 备份PVE配置
    if [[ -d "/etc/pve/nodes/$original_hostname/qemu-server" ]]; then
        mkdir -p "$backup_dir/qemu-server"
        cp -a "/etc/pve/nodes/$original_hostname/qemu-server/"* "$backup_dir/qemu-server/" 2>/dev/null || true
    fi
    
    if [[ -d "/etc/pve/nodes/$original_hostname/lxc" ]]; then
        mkdir -p "$backup_dir/lxc"
        cp -a "/etc/pve/nodes/$original_hostname/lxc/"* "$backup_dir/lxc/" 2>/dev/null || true
    fi
    
    echo "备份时间: $(date)" > "$backup_dir/backup.info"
    echo "原主机名: $original_hostname" >> "$backup_dir/backup.info"
    
    log_info "备份完成：$backup_dir"
    echo "$backup_dir"
}

# 检查新主机名合法性
check_new_hostname() {
    local new_hostname="$1"
    local original_hostname="$2"
    
    if [[ -z "$new_hostname" ]]; then
        log_error "主机名不能为空"
        return 1
    fi
    
    if [[ "$new_hostname" == "$original_hostname" ]]; then
        log_error "新主机名与当前主机名相同，无需更改"
        return 1
    fi
    
    if ! [[ "$new_hostname" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        log_error "主机名包含非法字符，只允许字母、数字、连字符(-)和点号(.)"
        return 1
    fi
    
    if [[ "$new_hostname" =~ ^[.-] ]] || [[ "$new_hostname" =~ [.-]$ ]]; then
        log_error "主机名不能以连字符(-)或点号(.)开头或结尾"
        return 1
    fi
    
    if [[ ${#new_hostname} -gt 63 ]]; then
        log_error "主机名长度不能超过63个字符"
        return 1
    fi
    
    if [[ -d "/etc/pve/nodes/$new_hostname" ]]; then
        log_error "节点名称 '$new_hostname' 已存在，请选择其他名称"
        return 1
    fi
    
    return 0
}

# 安全更新hosts文件 - 修复版本
update_hosts_file() {
    local original_hostname="$1"
    local new_hostname="$2"
    
    log_info "正在更新 /etc/hosts 文件"
    
    # 创建备份
    local backup_file="/etc/hosts.backup_$$"
    cp /etc/hosts "$backup_file"
    
    # 安全替换 - 避免将数字当作命令执行
    if grep -q "[[:space:]]$original_hostname$" /etc/hosts; then
        sed -i "s/[[:space:]]${original_hostname}$/ ${new_hostname}/g" /etc/hosts
        log_info "已替换行尾的主机名引用"
    fi
    
    if grep -q "[[:space:]]$original_hostname[[:space:]]" /etc/hosts; then
        sed -i "s/[[:space:]]${original_hostname}[[:space:]]/ ${new_hostname} /g" /etc/hosts
        log_info "已替换中间的主机名引用"
    fi
    
    # 验证更新
    if grep -q "$new_hostname" /etc/hosts; then
        log_info "/etc/hosts 文件更新成功"
        rm -f "$backup_file"
    else
        log_warn "/etc/hosts 文件中未找到原主机名的精确匹配"
    fi
}

# 安全迁移PVE节点配置目录 - 关键修复
# 迁移PVE节点配置目录 - 改进版
# 安全迁移PVE节点配置目录 - 关键修复
migrate_pve_node_directory() {
    local original_hostname="$1"
    local new_hostname="$2"
    
    local old_node_dir="/etc/pve/nodes/$original_hostname"
    local new_node_dir="/etc/pve/nodes/$new_hostname"
    
    log_info "开始迁移PVE节点配置目录"
    
    if [[ ! -d "$old_node_dir" ]]; then
        log_warn "原节点目录 $old_node_dir 不存在，跳过迁移"
        return 0
    fi
    
    # 检查目标目录是否存在，如果不存在则创建
    if [[ ! -d "$new_node_dir" ]]; then
        log_info "目标节点目录 $new_node_dir 不存在，正在创建..."
        mkdir -p "$new_node_dir"
        chmod 755 "$new_node_dir"
        chown root:root "$new_node_dir"
        log_info "创建成功: $new_node_dir"
    fi
    
    # 停止pve-cluster服务
    log_info "停止pve-cluster服务..."
    if ! systemctl stop pve-cluster; then
        log_error "停止pve-cluster服务失败"
        return 1
    fi
    
    # 设置集群文件系统为本地模式
    log_info "设置集群文件系统为本地模式..."
    if ! pmxcfs -l; then
        log_error "无法设置pmxcfs为本地模式"
        systemctl start pve-cluster
        return 1
    fi
    
    # 创建中转文件夹
    local tmp_dir="$new_node_dir/tmp"
    mkdir -p "$tmp_dir"
    
    # 将配置文件复制到临时目录
    log_info "正在复制配置文件到临时目录..."
    cp -a "$old_node_dir/"* "$tmp_dir/"
    
    # 移动目录到目标位置
    log_info "移动节点配置目录..."
    mv "$tmp_dir" "$new_node_dir/"
    
    # 完成后删除临时目录
    rm -rf "$tmp_dir"
    
    # 安全重启集群文件系统
    log_info "重新启动集群文件系统..."
    safe_pkill "pmxcfs"
    
    # 启动pve-cluster服务
    log_info "启动pve-cluster服务..."
    if ! systemctl start pve-cluster; then
        log_error "启动pve-cluster服务失败"
        return 1
    fi
    
    # 等待并验证
    log_info "等待集群服务启动..."
    local max_attempts=10
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if systemctl is-active --quiet pve-cluster && [[ -d "$new_node_dir" ]]; then
            log_info "PVE集群服务已正常启动"
            return 0
        fi
        sleep 3
        ((attempt++))
    done
    
    log_error "PVE集群服务启动超时"
    return 1
}



# 安全进程终止函数
safe_pkill() {
    local process_pattern="$1"
    local signal="${2:-TERM}"
    
    log_info "安全终止进程: $process_pattern"
    
    # 检查进程是否存在
    if pgrep -f "$process_pattern" >/dev/null; then
        log_info "找到匹配进程，发送信号: $signal"
        # 执行终止操作，但不捕获可能包含PID的返回值
        if pkill -$signal -f "$process_pattern"; then
            log_info "进程终止命令已发送"
        else
            log_warn "终止进程时可能遇到问题"
        fi
    else
        log_info "未找到匹配的进程: $process_pattern"
    fi
    
    # 确保进程已终止
    sleep 2
    return 0
}

# 重启PVE服务
restart_pve_services() {
    log_info "重启PVE相关服务..."
    
    local services=("pve-cluster.service" "pvedaemon.service" "pveproxy.service" "pvestatd.service")
    
    for service in "${services[@]}"; do
        log_info "重启服务: $service"
        if systemctl restart "$service"; then
            log_info "$service 重启成功"
        else
            log_warn "$service 重启遇到问题，但继续执行"
        fi
        sleep 2
    done
    
    log_info "所有PVE服务重启完成"
}

# 验证重命名结果
verify_rename() {
    local original_hostname="$1"
    local new_hostname="$2"
    
    log_info "验证重命名结果..."
    
    local success=true
    
    local current_hostname=$(hostname)
    if [[ "$current_hostname" == "$new_hostname" ]]; then
        log_info "✓ 系统主机名更新成功: $current_hostname"
    else
        log_error "✗ 系统主机名更新失败，当前: $current_hostname, 期望: $new_hostname"
        success=false
    fi
    
    if [[ -d "/etc/pve/nodes/$new_hostname" ]]; then
        log_info "✓ PVE节点目录迁移成功"
    else
        log_error "✗ PVE节点目录迁移失败"
        success=false
    fi
    
    if [[ ! -d "/etc/pve/nodes/$original_hostname" ]]; then
        log_info "✓ 旧节点目录已清理"
    else
        log_warn "⚠ 旧节点目录仍然存在"
    fi
    
    local services=("pve-cluster.service" "pvedaemon.service" "pveproxy.service")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log_info "✓ 服务 $service 运行正常"
        else
            log_error "✗ 服务 $service 运行异常"
            success=false
        fi
    done
    
    if $success; then
        log_info "重命名验证完成，所有关键检查项通过"
        return 0
    else
        log_error "重命名验证发现一些问题，请检查上述错误"
        return 1
    fi
}


# 提示用户手动删除旧节点目录
prompt_remove_old_node_dir() {
    local original_hostname="$1"
    
    log_info "节点重命名完成。"
    
    read -p "是否删除旧的节点目录 (/etc/pve/nodes/$original_hostname)? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "正在删除旧的节点目录: /etc/pve/nodes/$original_hostname"
        rm -rf "/etc/pve/nodes/$original_hostname"
        log_info "旧节点目录已删除"
    else
        log_warn "请记得手动删除旧的节点目录: /etc/pve/nodes/$original_hostname"
    fi
}


# 主重命名函数
rename_pve_node() {
    local original_hostname=$(hostname)
    local new_hostname=""
    local backup_dir=""
    
    log_info "当前主机名: $original_hostname"
    echo
    read -p "请输入新的主机名: " new_hostname
    
    if ! check_new_hostname "$new_hostname" "$original_hostname"; then
        exit 1
    fi
    
    echo
    log_info "计划将节点从 '$original_hostname' 重命名为 '$new_hostname'"
    log_warn "此操作需要重启多项服务，可能导致服务短暂中断"
    echo
    
    read -p "是否继续? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        exit 0
    fi
    
    # 显示回滚指引
    show_rollback_guide "$original_hostname" "$new_hostname"
    
    read -p "我已了解回滚步骤，继续执行重命名操作? (y/N): " final_confirm
    if [[ ! "$final_confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        exit 0
    fi
    
    echo
    log_info "=== 开始执行重命名操作 ==="
    local start_time=$(date +%s)
    
    # 执行备份
    backup_dir=$(backup_config "$original_hostname")
    
    # 执行重命名操作
    # 1. 修改系统主机名
    log_info "步骤 1/6: 修改系统主机名"
    hostnamectl set-hostname "$new_hostname"
    
    # 2. 更新 /etc/hostname 文件
    log_info "步骤 2/6: 更新 /etc/hostname 文件"
    echo "$new_hostname" > /etc/hostname
    
    # 3. 更新 /etc/hosts 文件
    log_info "步骤 3/6: 更新 /etc/hosts 文件"
    update_hosts_file "$original_hostname" "$new_hostname"
    
    # 4. 更新 Postfix 配置
    if [[ -f /etc/postfix/main.cf ]]; then
        log_info "步骤 4/6: 更新 Postfix 邮件配置"
        sed -i "s/$original_hostname/$new_hostname/g" /etc/postfix/main.cf || log_warn "Postfix配置更新可能失败"
    fi
    
    # 5. 迁移 PVE 节点配置目录
    log_info "步骤 5/6: 迁移 PVE 节点配置（关键步骤）"
    if ! migrate_pve_node_directory "$original_hostname" "$new_hostname"; then
        log_error "PVE节点配置迁移失败，请根据回滚指引进行恢复"
        exit 1
    fi
    
    # 6. 重启 PVE 服务
    log_info "步骤 6/6: 重启 PVE 服务"
    restart_pve_services
    
    # 验证结果
    log_info "验证重命名结果..."
    if verify_rename "$original_hostname" "$new_hostname"; then
        log_info "✓ 重命名操作基本成功"
    else
        log_warn "⚠ 重命名操作完成，但发现一些问题需要关注"
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo
    log_info "=== 重命名操作完成 ==="
    log_info "总执行时间: ${duration}秒"
    log_info "备份位置: $backup_dir"
    echo
    log_warn "*** 重要提示 ***"
    log_warn "1. 建议立即重启服务器以确保所有更改完全生效"
    log_warn "2. 重启后请通过Web界面检查所有虚拟机和服务的状态"
    log_info "当前主机名: $(hostname)"

    # 提示用户删除旧节点目录
    prompt_remove_old_node_dir "$original_hostname"
}


# 回滚函数

# 显示回滚指引
show_rollback_guide() {
    local original_hostname="$1"
    local new_hostname="$2"
    
    echo
    echo "================================================================"
    echo "                       回滚指引"
    echo "================================================================"
    echo "如果重命名后遇到问题，可以按以下步骤手动回滚："
    echo
    echo "1. 恢复系统主机名:"
    echo "   hostnamectl set-hostname $original_hostname"
    echo
    echo "2. 恢复系统文件:"
    echo "   cp /etc/hosts.backup.* /etc/hosts 2>/dev/null || true"
    echo "   echo \"$original_hostname\" > /etc/hostname"
    echo
    echo "3. 恢复PVE节点配置（关键步骤）:"
    echo "   systemctl stop pve-cluster"
    echo "   pmxcfs -l"
    echo "   mv /etc/pve/nodes/$new_hostname /etc/pve/nodes/$original_hostname"
    echo "   pkill -f pmxcfs || true"
    echo "   systemctl start pve-cluster"
    echo
    echo "4. 重启PVE服务:"
    echo "   systemctl restart pve-cluster pvedaemon pveproxy pvestatd"
    echo
    echo "5. 重启服务器使所有更改生效"
    echo "================================================================"
    echo
}



# 主执行流程
main() {
    echo "================================================================"
    echo "           Proxmox VE 单节点重命名脚本 (优化版)"
    echo "================================================================"
    echo "警告：此操作具有风险，请务必先在测试环境中验证！"
    echo "================================================================"
    
    check_root
    check_environment
    rename_pve_node
}

# 脚本执行入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
