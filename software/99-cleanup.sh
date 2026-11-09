#!/bin/bash
# 99-cleanup.sh — 收尾: 恢复 resolv.conf、放开服务启动、清缓存、写清单
set -uo pipefail

# --- 恢复 systemd-resolved 的符号链接 (00-base.sh 临时改成了实体文件) ---
if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
  rm -f /etc/resolv.conf
  ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  echo "resolv.conf 已恢复为 systemd-resolved 链接"
fi

# --- 放行服务启动 (必须删, 否则装完没有任何服务会自启) ---
rm -f /usr/sbin/policy-rc.d

# --- 清理 ---
rm -f /tmp/nodesource_setup.sh /tmp/node.tar.xz
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# --- 落一份可核对的清单 ---
mkdir -p /var/log/autoinstall
{
  echo "# provisioned at $(date -u +%FT%TZ)"
  echo "# host: $(cat /etc/hostname 2>/dev/null)"
  echo
  for c in git gh rg docker "docker compose" nvidia-ctk java node npm grok opencode openmausbot unity godot sshd; do
    printf '%-18s ' "$c"
    # shellcheck disable=SC2086
    $c --version 2>/dev/null | head -1 || echo "(not found)"
  done
} > /var/log/autoinstall/manifest.txt 2>&1

cat /var/log/autoinstall/manifest.txt
echo "cleanup ok"
