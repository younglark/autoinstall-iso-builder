#!/bin/bash
# 40-nodejs.sh — Node.js (默认 major=24)
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
export DEBIAN_FRONTEND=noninteractive
export HOME=/root

NODE_MAJOR="${PIN_NODE_MAJOR:-24}"

if command -v node >/dev/null && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge "$NODE_MAJOR" ]; then
  echo "已存在 Node $(node -v), 满足 >=${NODE_MAJOR}, 跳过"
  exit 0
fi

if offline_enabled 2>/dev/null; then
  echo "offline: 安装 Node (本地 apt 或捆绑 tarball)"
  if offline_apt_ready 2>/dev/null; then
    offline_apt_install nodejs || true
  fi
  if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt "$NODE_MAJOR" ]; then
    offline_install_node_tarball || { echo "ERROR: 离线 Node 安装失败"; exit 1; }
  fi
else
  if curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource_setup.sh; then
    bash /tmp/nodesource_setup.sh || echo "warn: NodeSource 脚本返回非零, 继续尝试"
    apt-get install -y nodejs || true
  fi
  if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt "$NODE_MAJOR" ]; then
    echo "回退到官方 tarball (v${NODE_MAJOR})"
    TARBALL=$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/" \
      | grep -oE "node-v${NODE_MAJOR}\\.[0-9.]*-linux-x64\\.tar\\.xz" | head -1)
    [ -n "$TARBALL" ] || { echo "ERROR: 无法确定 Node ${NODE_MAJOR} tarball 名称"; exit 1; }
    curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/${TARBALL}" -o /tmp/node.tar.xz
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
  fi
fi

node -v
npm -v
npm config set fund false --location=global
npm config set audit false --location=global
echo "nodejs ok"
