#!/bin/bash

# 检查是否以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请以 root 用户运行此脚本。"
    exit 1
fi

# 定义备份存储位置
_BACKUP_DIR="/home/pve/SystemBackup/PVE-Config"
_LOG_FILE="$_BACKUP_DIR/backup_log.txt"

# 创建备份主目录
mkdir -p "$_BACKUP_DIR" || { echo "无法创建备份主目录 $_BACKUP_DIR"; exit 1; }

# 获取当前日期
_CURRENT_DATE=$(date +"%Y%m%d_%H%M%S")
_BACKUP_DATE_DIR="$_BACKUP_DIR/backup_$_CURRENT_DATE"

# 日志函数
log_message() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" >> "$_LOG_FILE"
}

# 备份函数
backup_file() {
    local source_file="$1"
    local target_dir="$2"
    
    if [ ! -e "$source_file" ]; then
        log_message "⚠️  警告：$source_file 不存在，跳过备份"
        return 1
    fi
    
    mkdir -p "$target_dir" || { log_message "❌ 无法创建目录 $target_dir"; return 1; }
    
    if cp -a "$source_file" "$target_dir"/ 2>/dev/null; then
        log_message "✅ 成功备份: $source_file → $target_dir"
        return 0
    else
        log_message "❌ 备份失败: $source_file"
        return 1
    fi
}

# 开始备份
log_message "=== 开始PVE配置备份 ==="
log_message "备份目录: $_BACKUP_DATE_DIR"
mkdir -p "$_BACKUP_DATE_DIR" || { log_message "❌ 无法创建备份目录"; exit 1; }

# 📋 PVE核心配置文件备份清单
log_message "开始备份PVE核心配置文件..."

# 1. PVE虚拟化配置目录（最重要的部分）
backup_file "/etc/pve" "$_BACKUP_DATE_DIR/etc"

# 2. 系统网络配置
backup_file "/etc/network/interfaces" "$_BACKUP_DATE_DIR/etc/network"
backup_file "/etc/hosts" "$_BACKUP_DATE_DIR/etc"
backup_file "/etc/hostname" "$_BACKUP_DATE_DIR/etc"

# 3. 系统配置
backup_file "/etc/fstab" "$_BACKUP_DATE_DIR/etc"
backup_file "/etc/group" "$_BACKUP_DATE_DIR/etc"
backup_file "/etc/passwd" "$_BACKUP_DATE_DIR/etc"
backup_file "/etc/shadow" "$_BACKUP_DATE_DIR/etc"

# 4. PVE集群配置
backup_file "/var/lib/pve-cluster/config.db" "$_BACKUP_DATE_DIR/var/lib/pve-cluster"

# 5. 存储配置（如果有的话）
backup_file "/etc/pve/storage.cfg" "$_BACKUP_DATE_DIR/etc/pve"
backup_file "/etc/pve/user.cfg" "$_BACKUP_DATE_DIR/etc/pve"

# 6. 证书文件（如果有自定义证书）
backup_file "/etc/pve/pve-root-ca.pem" "$_BACKUP_DATE_DIR/etc/pve"
backup_file "/etc/pve/priv/pve-root-ca.key" "$_BACKUP_DATE_DIR/etc/pve/priv"

# 验证备份完整性
log_message "验证备份完整性..."
if [ -f "$_BACKUP_DATE_DIR/etc/hosts" ] && [ -d "$_BACKUP_DATE_DIR/etc/pve" ]; then
    log_message "✅ 备份验证通过"
else
    log_message "❌ 备份验证失败，关键文件缺失"
    exit 1
fi

# 清理旧备份（保留最近5个）
log_message "开始清理旧备份..."
cd "$_BACKUP_DIR" || exit
backup_count=$(find . -maxdepth 1 -type d -name "backup_*" | wc -l)
if [ "$backup_count" -gt 5 ]; then
    find . -maxdepth 1 -type d -name "backup_*" | sort | head -n -5 | xargs -r rm -rf
    log_message "✅ 已清理旧备份，保留最近5个"
else
    log_message "ℹ️  备份数量不足5个，跳过清理"
fi

# 生成备份报告
log_message "=== 备份完成 ==="
echo "✅ PVE配置备份完成！"
echo "📁 备份位置: $_BACKUP_DATE_DIR"
echo "📊 备份内容:"
tree "$_BACKUP_DATE_DIR" 2>/dev/null || find "$_BACKUP_DATE_DIR" -type f | head -20
echo "📋 日志文件: $_LOG_FILE"
