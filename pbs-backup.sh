#!/bin/bash
# =============================================================================
# 2025 终极版 PVE 宿主机配置三件套备份脚本（仅备份系统本身，不含虚拟机镜像）
# 适用于所有 PVE 8.x / 9.x / 10.x 节点，部署后每天自动跑一次即可
# 存放在 PBS 的 pve-config Datastore 中
# =============================================================================

# ====================== 请修改这里 ======================
PBS_REPO="root@pam@192.168.X.X:pve-config"   # ← 改成你的 PBS IP 和 Datastore
# =======================================================

# 第一段：备份 /etc 目录（最重要！所有 PVE 配置都在这里）
# 体积通常只有几 MB，每天增量几乎为 0
proxmox-backup-client backup etc.pxar:/etc \
  --repository "$PBS_REPO" \
  --skip-lost-and-found

# 第二段：备份整个根分区（精简热备），但排除所有不需要的大文件和临时目录
# 首次 8~18 GB，以后每天增量通常 < 50 MB
proxmox-backup-client backup root.pxar:/ \
  --repository "$PBS_REPO" \
  --skip-lost-and-found \
  --exclude='/proc/**' \
  --exclude='/sys/**' \
  --exclude='/dev/**' \
  --exclude='/run/**' \
  --exclude='/tmp/**' \
  --exclude='/var/tmp/**' \
  --exclude='/var/run/**' \
  --exclude='/mnt/**' \
  --exclude='/media/**' \
  --exclude='/var/lib/vz/**'      # ← 双保险：强制排除虚拟机镜像目录（client 本身也会自动跳过大文件）

# 第三段：备份当前安装的所有软件包列表（重装系统后 10 秒就能恢复软件环境）
# 体积只有几 KB
dpkg --get-selections > /root/dpkg-selections.txt
proxmox-backup-client backup pkglist.pxar:/root/dpkg-selections.txt \
  --repository "$PBS_REPO" -f

# ====================== 可选：每天自动清理无用缓存，进一步减小增量 ======================
# 这几行可以让 root.pxar 体积再降 3~8 GB，且每天增量更小
apt clean 2>/dev/null || true
journalctl --vacuum-time=7d --quiet 2>/dev/null || true          # 只保留 7 天系统日志
find /var/log -type f \( -name "*.log.*" -o -name "*.old" \) -delete 2>/dev/null || true
# =====================================================================================

echo "[$(date)] PVE 宿主机三件套备份完成 → $HOSTNAME" >> /var/log/pve-host-backup.log

