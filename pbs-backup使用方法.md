# 1. 保存脚本
cat > /root/backup-pve-host.sh << 'EOF'
（把上面整段代码粘贴在这里）
EOF

# 2. 给执行权限
chmod +x /root/backup-pve-host.sh

# 3. 加到 crontab（每天凌晨 3:30 自动跑）
(crontab -l 2>/dev/null; echo "30 3 * * * /root/backup-pve-host.sh >> /var/log/pve-host-backup.log 2>&1") | crontab -

#恢复时只需要这四条命令（重装完系统后）

apt install proxmox-backup-client -y

proxmox-backup-client restore etc.pxar   latest /etc   --allow-existing-dirs --repository root@pam@192.168.1.16:pve-config
proxmox-backup-client restore root.pxar  latest /      --allow-existing-dirs --repository ...
proxmox-backup-client restore pkglist.pxar latest /root/dpkg-selections.txt --repository ...
dpkg --set-selections < /root/dpkg-selections.txt && apt-get dselect-upgrade

reboot   # 必须重启才能让新配置全部生效
