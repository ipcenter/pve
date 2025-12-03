#!/bin/bash

# =============================================================================
# PVE 宿主机纯配置备份脚本 (不包含虚拟机数据)
# 使用 Proxmox Backup Server (PBS) 客户端进行备份
# =============================================================================

# 退出遇到错误
set -e

# ====================== 配置区域 ======================
# 请根据您的实际环境修改以下变量
PBS_REPOSITORY="root@pam@192.168.1.16:8007:pve-config" # PBS仓库地址
BACKUP_ID="pve_backup-$(hostname)"                      # 备份ID，使用主机名区分

# =====================================================

# 日志函数，同时输出到标准输出和日志文件
LOG_FILE="/var/log/pve-host-config-backup.log"
log_message() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" | tee -a "$LOG_FILE"
}

# 备份开始提示
log_message "=== 开始 PVE 宿主机配置备份 ==="
log_message "备份目标仓库: $PBS_REPOSITORY"
log_message "备份ID: $BACKUP_ID"

# 检查PBS仓库连通性
log_message "检查PBS仓库连通性..."
if ! proxmox-backup-client status --repository "$PBS_REPOSITORY" > /dev/null 2>&1; then
    log_message "❌ 错误：无法连接到PBS仓库 $PBS_REPOSITORY，请检查网络、地址或权限。"
    exit 1
fi
log_message "✅ PBS仓库连接成功"

# 创建临时工作目录
TEMP_DIR=$(mktemp -d)
log_message "创建临时工作目录: $TEMP_DIR"

# 阶段1：收集系统配置到临时目录
CONFIG_DIR="$TEMP_DIR/pve-host-config"
mkdir -p "$CONFIG_DIR"

log_message "阶段1: 收集系统关键配置文件..."

# 1.1 备份整个 /etc/pve 目录（这是PVE配置的核心）
if [ -d "/etc/pve" ]; then
    # 使用tar来打包/etc/pve，可以更好地处理权限和特殊文件结构
    tar czf "$CONFIG_DIR/etc-pve-backup.tar.gz" -C / etc/pve/ 2>/dev/null || {
        log_message "⚠️  打包 /etc/pve 时遇到一些问题，但继续执行..."
    }
    log_message "✅ 已备份 /etc/pve 目录"
else
    log_message "❌ 错误：未找到 /etc/pve 目录，备份无法继续。"
    exit 1
fi

# 1.2 备份其他关键系统配置文件
mkdir -p "$CONFIG_DIR/etc"
[ -f /etc/hosts ] && cp -f /etc/hosts "$CONFIG_DIR/etc/" 2>/dev/null && log_message "✅ 已备份 /etc/hosts" || log_message "⚠️  跳过 /etc/hosts"
[ -f /etc/hostname ] && cp -f /etc/hostname "$CONFIG_DIR/etc/" 2>/dev/null && log_message "✅ 已备份 /etc/hostname" || log_message "⚠️  跳过 /etc/hostname"
[ -f /etc/fstab ] && cp -f /etc/fstab "$CONFIG_DIR/etc/" 2>/dev/null && log_message "✅ 已备份 /etc/fstab" || log_message "⚠️  跳过 /etc/fstab"
mkdir -p "$CONFIG_DIR/etc/network"
[ -f /etc/network/interfaces ] && cp -f /etc/network/interfaces "$CONFIG_DIR/etc/network/" 2>/dev/null && log_message "✅ 已备份 /etc/network/interfaces" || log_message "⚠️  跳过 /etc/network/interfaces"

# 1.3 备份已安装软件包列表
if dpkg --get-selections > "$CONFIG_DIR/dpkg-selections.txt" 2>/dev/null; then
    log_message "✅ 已备份软件包列表"
else
    log_message "⚠️  生成软件包列表失败"
fi


# 在您现有脚本的“阶段1”部分添加以下内容

log_message "备份软件包管理相关信息..."

# 2.1 备份软件包列表
if dpkg --get-selections > "$CONFIG_DIR/dpkg-selections.txt" 2>/dev/null; then
    log_message "✅ 已备份软件包列表"
else
    log_message "⚠️  生成软件包列表失败"
fi

# 2.2 备份软件源配置
mkdir -p "$CONFIG_DIR/etc/apt"
cp -r /etc/apt/sources.list* "$CONFIG_DIR/etc/apt/" 2>/dev/null || log_message "⚠️  备份软件源配置时遇到问题"

# 2.3 备份APT密钥
if apt-key exportall > "$CONFIG_DIR/apt-trusted-keys.gpg" 2>/dev/null; then
    log_message "✅ 已备份APT可信密钥"
else
    # 如果上述命令失败，尝试备份密钥目录
    cp -r /etc/apt/trusted.gpg.d/ "$CONFIG_DIR/etc/apt/" 2>/dev/null || log_message "⚠️  备份APT密钥失败"
fi

# 2.4 备份自定义软件配置（示例：常见的自定义配置目录）
mkdir -p "$CONFIG_DIR/usr/local"
[ -d /usr/local/bin ] && cp -r /usr/local/bin "$CONFIG_DIR/usr/local/" 2>/dev/null
[ -d /usr/local/etc ] && cp -r /usr/local/etc "$CONFIG_DIR/usr/local/" 2>/dev/null

# 2.5 备份cron任务
crontab -l > "$CONFIG_DIR/root-crontab" 2>/dev/null || log_message "⚠️  无法备份root用户的cron任务"

# 阶段2：上传备份到PBS
log_message "阶段2: 上传配置到PBS..."
upload_output=$(proxmox-backup-client backup host-config.pxar:"$TEMP_DIR" \
  --repository "$PBS_REPOSITORY" \
  --backup-id "$BACKUP_ID" \
  --backup-type "host" \
  --skip-lost-and-found 2>&1)

# 修复：正确的条件判断语法
backup_exit_code=$?
if [ $backup_exit_code -eq 0 ]; then
    log_message "✅ 配置数据成功上传至PBS"
    UPLOAD_SUCCESS=true
else
    log_message "❌ 上传配置数据到PBS失败，退出代码: $backup_exit_code"
    log_message "上传命令输出: $upload_output"
    UPLOAD_SUCCESS=false
fi

# 阶段3：清理工作
log_message "阶段3: 清理临时文件..."
rm -rf "$TEMP_DIR"
log_message "✅ 临时文件已清理"

# 最终提示
if [ "$UPLOAD_SUCCESS" = true ]; then
    log_message "=== PVE 宿主机配置备份已成功完成！ ==="
    echo "=========================================="
    echo "✅ 备份成功！"
    echo "   备份ID: $BACKUP_ID"
    echo "   仓库: $PBS_REPOSITORY"
    echo "   详细日志请查看: $LOG_FILE"
    echo "=========================================="
else
    log_message "=== PVE 宿主机配置备份失败！ ==="
    echo "=========================================="
    echo "❌ 备份过程中出现错误，请检查日志。"
    echo "   日志文件: $LOG_FILE"
    echo "=========================================="
    exit 1
fi
