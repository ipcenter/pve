#!/bin/bash

echo "================================================="
echo " Proxmox VE Web UI PVE节点故障诊断脚本"
echo "================================================="

fail=0   # 是否发现问题的标志

check() {
    echo
    echo ">>> $1"
}

# 1. 服务状态
check "检查 PVE 核心服务状态"
for svc in pveproxy pvedaemon pvestatd pve-cluster; do
    if systemctl is-active --quiet "$svc"; then
        echo "✔ $svc 正常运行"
    else
        echo "✘ $svc 未运行"
        fail=1
    fi
done

# 2. 端口监听
check "检查 8006 端口监听"
if ss -lntp | grep -q ":8006"; then
    ss -lntp | grep 8006
else
    echo "✘ 8006 端口未监听"
    fail=1
fi

# 3. pmxcfs
check "检查 /etc/pve (pmxcfs)"
if mount | grep -q "/etc/pve"; then
    echo "✔ /etc/pve 已挂载"
else
    echo "✘ /etc/pve 未挂载"
    fail=1
fi

# 4. SSL 证书文件
check "检查 PVE SSL 证书"
for f in /etc/pve/local/pve-ssl.pem /etc/pve/local/pve-ssl.key; do
    if [ -f "$f" ]; then
        size=$(stat -c%s "$f")
        echo "✔ $f 存在，大小 ${size} bytes"
        if [ "$size" -lt 100 ]; then
            echo "⚠ 文件过小，疑似损坏"
            fail=1
        fi
    else
        echo "✘ $f 不存在"
        fail=1
    fi
done

# 5. TLS 握手测试
check "测试 HTTPS TLS 握手"
timeout 5 openssl s_client -connect 127.0.0.1:8006 < /dev/null \
    >/tmp/pve_tls_test.log 2>&1

if grep -q "BEGIN CERTIFICATE" /tmp/pve_tls_test.log; then
    echo "✔ TLS 握手成功"
else
    echo "✘ TLS 握手失败"
    tail -n 5 /tmp/pve_tls_test.log
    fail=1
fi

# 6. 最近错误日志
check "最近 pveproxy 错误日志"
journalctl -u pveproxy --since "10 minutes ago" --no-pager | tail -n 20

echo
echo "================================================="

# 最终总结
if [ "$fail" -eq 0 ]; then
    echo "✅ 当前一切服务正常，无需修复"
else
    echo "❌ 检测到问题，请按上面提示进行处理"
fi

echo "================================================="
