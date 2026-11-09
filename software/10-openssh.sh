#!/bin/bash
# 10-openssh.sh — openssh-server
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
export DEBIAN_FRONTEND=noninteractive

if offline_enabled 2>/dev/null && offline_apt_ready 2>/dev/null; then
  offline_apt_install openssh-server
else
  apt-get install -y --no-install-recommends openssh-server
fi

systemctl enable ssh.service 2>/dev/null \
  || systemctl enable ssh.socket 2>/dev/null \
  || echo "warn: 未能 enable ssh 单元, 启动后请手工检查"

ALLOW_PW="${SSH_ALLOW_PW:-true}"
case "$(printf '%s' "$ALLOW_PW" | tr '[:upper:]' '[:lower:]')" in
  true|yes|1) PA=yes ;;
  *) PA=no ;;
esac
sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication ${PA}/" /etc/ssh/sshd_config
grep -q '^PasswordAuthentication ' /etc/ssh/sshd_config \
  || echo "PasswordAuthentication ${PA}" >> /etc/ssh/sshd_config
echo "PasswordAuthentication=${PA} (SSH_ALLOW_PW=${ALLOW_PW})"

command -v sshd >/dev/null
sshd -V 2>&1 | head -1 || true
echo "openssh-server ok"
