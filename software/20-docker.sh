#!/bin/bash
# 20-docker.sh — Docker CE
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
export DEBIAN_FRONTEND=noninteractive

if offline_enabled 2>/dev/null && offline_apt_ready 2>/dev/null; then
  echo "offline: 从本地 apt 安装 Docker CE (不添加 download.docker.com)"
  offline_apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$ARCH" "$CODENAME" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "data-root": "/var/lib/docker"
}
JSON

systemctl enable docker.service containerd.service 2>/dev/null || true
if [ -n "${TARGET_USER:-}" ] && [ "$TARGET_USER" != "root" ]; then
  usermod -aG docker "$TARGET_USER" || true
fi

/usr/bin/dockerd --version
/usr/bin/docker --version
/usr/bin/docker compose version | head -1
echo "docker ok"
