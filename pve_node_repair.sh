#!/bin/bash
# 文件名: pve_standalone_fix_db.sh
# 描述: 修复Proxmox VE单节点数据库问题

echo "================================================"
echo "  Proxmox VE 单节点修复脚本"
echo "================================================"

# 1. 停止所有相关服务
echo -e "\n[1/5] 停止所有相关服务..."
systemctl stop pveproxy pvedaemon pvestatd pve-cluster corosync
pkill -9 -f pmxcfs 2>/dev/null
sleep 2

# 2. 备份当前数据库
echo -e "\n[2/5] 备份当前数据库..."
BACKUP_DIR="/root/pve_db_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p $BACKUP_DIR
cp -a /var/lib/pve-cluster $BACKUP_DIR/ 2>/dev/null
echo "数据库备份保存到: $BACKUP_DIR"

# 3. 修复数据库结构
echo -e "\n[3/5] 修复数据库结构..."
DB_FILE="/var/lib/pve-cluster/config.db"

# 如果数据库文件存在，重命名备份
if [ -f "$DB_FILE" ]; then
    mv "$DB_FILE" "${DB_FILE}.bak"
fi

# 创建正确的数据库结构
cat > /tmp/init_db.sql << 'EOF'
CREATE TABLE tree (
  path TEXT PRIMARY KEY,
  data BYTEA,
  ctime INTEGER,
  mtime INTEGER,
  inode INTEGER
);
INSERT INTO tree (path, data, ctime, mtime, inode) VALUES 
  ('version', '3', strftime('%s','now'), strftime('%s','now'), 0);
EOF

# 初始化数据库
sqlite3 "$DB_FILE" < /tmp/rm -f /tmp/init_db.sql
chown www-data:www-data "$DB_FILE"
chmod 0640 "$DB_FILE"

echo "数据库已重新初始化"

# 4. 修复权限
echo -e "\n[4/5] 修复权限..."
chown -R www-data:www-data /var/lib/pve-cluster
chmod 0750 /var/lib/pve-cluster
chown -R www-data:www-data /etc/pve
chmod 0750 /etc/pve
chown -R www-data:www-data /var/run/pve-cluster
chmod 0755 /var/run/pve-cluster

# 5. 启动服务
echo -e "\n[5/5] 启动服务..."
systemctl start pve-cluster
sleep 5

# 检查pmxcfs是否运行
if ! pgrep -f pmxcfs > /dev/null; then
    echo "手动启动pmxcfs..."
    pmxcfs -l &
    sleep 3
fi

# 启动其他服务
systemctl start pvedaemon
systemctl start pvestatd
systemctl start pveproxy

echo "================================================"
echo "修复完成！等待10秒后检查状态..."
echo "================================================"
sleep 10

# 检查服务状态
echo -e "\n--- 服务状态 ---"
for service in pve-cluster pvedaemon pveproxy pvestatd; do
    status=$(systemctl is-active $service 2>/dev/null)
    if [ "$status" = "active" ]; then
        echo "✓ $service: 运行中"
    else
        echo "✗ $service: 未运行"
    fi
done

# 检查端口
echo -e "\n--- 端口监听 ---"
if ss -tln | grep -q ':8006'; then
    echo "✓ 8006端口已监听"
else
    echo "✗ 8006端口未监听"
fi

# 测试Web访问
echo -e "\n--- Web访问测试 ---"
IP=$(hostname -I | awk '{print $1}')
if curl -k -s https://localhost:8006 2>/dev/null | grep -qi "proxmox"; then
    echo "✓ Web界面可访问: https://$IP:8006"
else
    echo "✗ Web界面可能有问题"
    echo "请尝试: curl -k https://localhost:8006"
fi

echo "================================================"
echo "如果仍有问题，请检查日志:"
echo "journalctl -u pve-cluster -u pveproxy -f"
echo "================================================"
