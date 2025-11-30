#!/bin/bash

# 定义备份存储位置[根据实际情况修改]
_BACKUP_DIR="/home/pve/SystemBackup/PVE-Config"
# 定义日志文件路径[根据实际情况修改]
_LOG_FILE="$_BACKUP_DIR/backup_log.txt"

# 创建备份主目录
mkdir -p $_BACKUP_DIR || { echo "无法创建备份主目录 $_BACKUP_DIR"; exit 1; }

# 获取当前日期
_CURRENT_DATE=$(date +"%Y%m%d_%H%M%S")

# 创建带日期的备份目录
_BACKUP_DATE_DIR="$_BACKUP_DIR/backup_$_CURRENT_DATE"
mkdir -p $_BACKUP_DATE_DIR || { echo "无法创建日期备份目录 $_BACKUP_DATE_DIR"; exit 1; }

echo "[$(date)] 开始备份PVE配置到: $_BACKUP_DATE_DIR" >> $_LOG_FILE

# 备份关键配置文件
# 1. 备份PVE核心配置目录（包含虚拟机、存储、用户等配置）
cp -r /etc/pve "$_BACKUP_DATE_DIR" 2>/dev/null  # 忽略部分可能出现的临时文件错误[1](@ref)
# 2. 备份系统关键配置
cp /etc/fstab "$_BACKUP_DATE_DIR"
cp /etc/hostname "$_BACKUP_DATE_DIR"
cp /etc/hosts "$_BACKUP_DATE_DIR"
cp /etc/network/interfaces "$_BACKUP_DATE_DIR"  # 新增网络配置备份[1](@ref)
# 3. 备份集群配置
cp /var/lib/pve-cluster/config.db "$_BACKUP_DATE_DIR" 2>/dev/null

# 检查核心备份是否成功（至少检查一个关键文件是否存在）
if [ -f "$_BACKUP_DATE_DIR/hosts" ]; then
    echo "[$(date)] 备份已完成。" >> $_LOG_FILE
else
    echo "[$(date)] 错误：关键备份文件可能丢失，备份失败。" >> $_LOG_FILE
    exit 1
fi

# 删除旧备份，保留最近5个备份（数量可调整）
echo "[$(date)] 开始清理旧备份..." >> $_LOG_FILE
cd $_BACKUP_DIR || exit
find . -maxdepth 1 -type d -name "backup_*" | sort -r | tail -n +6 | xargs -r rm -rf
# 命令解释：
# find ... : 查找当前目录下所有以 "backup_" 开头的文件夹
# sort -r : 按名称倒序排列（新的在前）
# tail -n +6 : 从第6个开始取（即跳过最新的5个）
# xargs -r rm -rf : 将找到的目录传递给rm命令进行删除

echo "[$(date)] 旧备份清理完成。" >> $_LOG_FILE
echo "✅ PVE配置信息已完成备份！"
