#!/bin/bash
# 20-docker.sh — Docker CE (官方仓库, 非 ubuntu 自带的 docker.io)
#
# 用 download.docker.com 的 docker-ce, 因为要 compose v2 / buildx 插件
# 和可控的版本升级节奏; 发行版自带的 docker.io 通常落后一个大版本。
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF

apt-get update
apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 日志轮转: 不配的话 containerd 日志能把磁盘写满, 这是最常被忽略的一项
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "data-root": "/var/lib/docker"
}
EOF

systemctl enable docker.service containerd.service 2>/dev/null || true

# 免 sudo 使用 docker
if [ -n "${TARGET_USER:-}" ] && [ "$TARGET_USER" != "root" ]; then
  usermod -aG docker "$TARGET_USER" || true
fi

/usr/bin/dockerd --version
/usr/bin/docker --version
/usr/bin/docker compose version | head -1
echo "docker ok"
