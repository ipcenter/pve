#!/bin/bash
###############################################################################
# Proxmox VE 集群管理脚本（安全退出集群 + 加入集群 + 检测）
###############################################################################

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

###############################################################################
# 检测集群状态
###############################################################################
detect_cluster() {
    echo "--------------------------------------------------"
    echo "[INFO] 正在检测集群状态..."

    if [[ ! -f /etc/pve/corosync.conf ]]; then
        IS_CLUSTER_NODE="no"
        echo "[INFO] 是否集群节点: 否"
        echo "[INFO] 节点名称: $(hostname)"
        echo "--------------------------------------------------"
        return
    fi

    IS_CLUSTER_NODE="yes"
    CLUSTER_NAME=$(pvecm status | awk -F': *' '/Name/ {print $2}')
    CURRENT_NODE=$(hostname)
    NODE_LIST=$(pvecm nodes | awk 'NR>1 {print $3}')
    NODE_COUNT=$(pvecm status | grep "Nodes:" | awk '{print $2}')

    MASTER_NODE=$(pvecm status | awk -F': *' '/Quorum leader/ {print $2}')
    [[ -z "$MASTER_NODE" ]] && MASTER_NODE="$CURRENT_NODE"

    if [[ "$CURRENT_NODE" == "$MASTER_NODE" ]]; then
        NODE_ROLE="master"
    else
        NODE_ROLE="slave"
    fi

    echo "[INFO] 是否集群节点: 是"
    echo "[INFO] 集群名称: $CLUSTER_NAME"
    echo "[INFO] 节点类型: $([[ "$NODE_ROLE" == "master" ]] && echo "集群主节点" || echo "从节点")"
    echo "[INFO] 集群节点数量: $NODE_COUNT"

    echo "集群节点列表:"
    while read -r node; do
        if [[ "$node" == "$CURRENT_NODE" ]]; then
            if [[ "$node" == "$MASTER_NODE" ]]; then
                echo "  $node (主节点/当前节点)"
            else
                echo "  $node (当前节点)"
            fi
        elif [[ "$node" == "$MASTER_NODE" ]]; then
            echo "  $node (主节点)"
        else
            echo "  $node"
        fi
    done <<< "$NODE_LIST"

    echo "--------------------------------------------------"

    export IS_CLUSTER_NODE CLUSTER_NAME NODE_LIST NODE_COUNT CURRENT_NODE MASTER_NODE NODE_ROLE
}

###############################################################################
# 安全退出集群
###############################################################################
leave_cluster() {
    detect_cluster

    if [[ "$IS_CLUSTER_NODE" != "yes" ]]; then
        log_info "当前不是集群节点，无需退出。"
        return
    fi

    echo "[INFO] 集群名称: $CLUSTER_NAME"
    echo "[INFO] 当前节点: $CURRENT_NODE"
    echo "[INFO] 当前角色: $NODE_ROLE"
    echo "[INFO] 节点数量: $NODE_COUNT"

    if [[ "$NODE_COUNT" -eq 1 ]]; then
        log_warn "当前为单节点集群，将退出集群并恢复独立节点模式。"
        read -p "确认退出？(y/N): " c
        [[ "$c" != "y" ]] && return

        log_step "停止集群服务..."
        systemctl stop corosync || true
        systemctl stop pve-cluster || true

        log_step "备份 corosync 配置..."
        [[ -f /etc/pve/corosync.conf ]] && mv /etc/pve/corosync.conf /root/corosync.conf.bak
        [[ -d /etc/corosync ]] && mv /etc/corosync /root/corosync.bak

        log_step "启动单节点 PMXCFS..."
        systemctl start pve-cluster
        sleep 3

        log_info "已退出单节点集群。建议重启系统以确保服务完全恢复。"
        return
    fi

    if [[ "$NODE_ROLE" == "master" ]]; then
        log_warn "当前为主节点，解散集群会影响所有节点！"
        read -p "确认解散整个集群？(y/N): " c
        [[ "$c" != "y" ]] && return

        log_step "停止集群服务..."
        systemctl stop corosync || true
        systemctl stop pve-cluster || true

        log_step "逐个移除从节点..."
        for node in $NODE_LIST; do
            [[ "$node" != "$CURRENT_NODE" ]] && pvecm delnode "$node" || true
        done

        log_step "启动主节点 PMXCFS..."
        systemctl start pve-cluster
        sleep 3
        log_info "集群已解散，主节点已恢复独立模式。"
        return
    fi

    # 从节点退出
    log_warn "当前是从节点，将从集群移除..."
    read -p "确认退出？(y/N): " c
    [[ "$c" != "y" ]] && return

    pvecm delnode "$CURRENT_NODE"
    log_info "已从集群移除。"
}

###############################################################################
# 加入集群
###############################################################################
join_cluster() {
    local MASTER_IP="$1"
    detect_cluster
    if [[ "$IS_CLUSTER_NODE" == "yes" ]]; then
        log_warn "当前节点已在集群中，忽略加入操作。"
        return
    fi

    if [[ -z "$MASTER_IP" ]]; then
        log_error "请指定集群主节点 IP 或名称。"
        return
    fi

    log_step "加入集群: $MASTER_IP"
    pvecm add "$MASTER_IP"
    log_info "加入集群完成"
}

###############################################################################
# 循环菜单
###############################################################################
main() {
    [[ $EUID -ne 0 ]] && { log_error "请以 root 运行"; exit 1; }

    while true; do
        echo "================================================================"
        echo "      Proxmox VE 集群管理脚本"
        echo "================================================================"
        echo "1) 检测集群状态"
        echo "2) 退出集群"
        echo "3) 加入集群"
        echo "4) 退出脚本"
        read -p "请选择操作 (1-4): " CHOICE

        case "$CHOICE" in
            1)
                detect_cluster
                ;;
            2)
                leave_cluster
                ;;
            3)
                read -p "请输入集群主节点 IP 或名称: " MASTER
                join_cluster "$MASTER"
                ;;
            4)
                log_info "退出脚本"
                exit 0
                ;;
            *)
                log_error "无效选项"
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
