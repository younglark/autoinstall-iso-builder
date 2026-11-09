#!/bin/bash
# 10-openssh.sh — openssh-server
#
# subiquity 的 ssh.install-server 也会装, 这里做幂等兜底:
# 即使有人在 user-data 里关掉了, 本脚本仍保证 sshd 存在并开机自启。
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get install -y --no-install-recommends openssh-server

# 24.04 起部分版本走 socket 激活, 两种都尝试启用
systemctl enable ssh.service 2>/dev/null \
  || systemctl enable ssh.socket 2>/dev/null \
  || echo "warn: 未能 enable ssh 单元, 启动后请手工检查"

# 保持密码登录策略与 autoinstall 里 ssh.allow-pw 一致
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

command -v sshd >/dev/null
sshd -V 2>&1 | head -1 || true
echo "openssh-server ok"
