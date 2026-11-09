#!/bin/bash
# 10-openssh.sh — openssh-server
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
export DEBIAN_FRONTEND=noninteractive

if offline_enabled 2>/dev/null && offline_apt_ready 2>/dev/null; then
  if dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q 'install ok installed'; then
    echo "openssh-server already installed, skip apt"
  else
    offline_apt_install openssh-server
  fi
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
# drop-in 覆盖 cloud-init 的 50-cloud-init.conf (sshd Include 后写优先生效于同名键的常见布局;
# 同时改写/删除 cloud-init 片段, 避免 PasswordAuthentication yes 残留)
mkdir -p /etc/ssh/sshd_config.d
printf 'PasswordAuthentication %s\n' "$PA" > /etc/ssh/sshd_config.d/60-autoinstall-pw.conf
if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
  sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication ${PA}/" \
    /etc/ssh/sshd_config.d/50-cloud-init.conf
fi
echo "PasswordAuthentication=${PA} (SSH_ALLOW_PW=${ALLOW_PW})"

command -v sshd >/dev/null
sshd -V 2>&1 | head -1 || true
echo "openssh-server ok"
