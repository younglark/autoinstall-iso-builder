#!/bin/bash
# 10-openssh.sh — openssh-server
#
# subiquity 的 ssh.install-server 也会装, 这里做幂等兜底:
# 即使有人在 user-data 里关掉了, 本脚本仍保证 sshd 存在并开机自启。
# PasswordAuthentication 跟随 provision.env 里的 SSH_ALLOW_PW (与 autoinstall ssh.allow-pw 一致)。
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get install -y --no-install-recommends openssh-server

# 24.04 起部分版本走 socket 激活, 两种都尝试启用
systemctl enable ssh.service 2>/dev/null \
  || systemctl enable ssh.socket 2>/dev/null \
  || echo "warn: 未能 enable ssh 单元, 启动后请手工检查"

ALLOW_PW="${SSH_ALLOW_PW:-true}"
case "$(printf '%s' "$ALLOW_PW" | tr '[:upper:]' '[:lower:]')" in
  true|yes|1) PA=yes ;;
  *) PA=no ;;
esac
sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication ${PA}/" /etc/ssh/sshd_config
# 若原文件没有该指令则追加
grep -q '^PasswordAuthentication ' /etc/ssh/sshd_config \
  || echo "PasswordAuthentication ${PA}" >> /etc/ssh/sshd_config
echo "PasswordAuthentication=${PA} (SSH_ALLOW_PW=${ALLOW_PW})"

command -v sshd >/dev/null
sshd -V 2>&1 | head -1 || true
echo "openssh-server ok"
