#!/bin/bash
# 40-nodejs.sh — Node.js (默认 major=24, 可用 PIN_NODE_MAJOR 覆盖)
#
# 三件事都卡在这一个版本上:
#   * @xai-official/grok  需要 Node >= 20
#   * opencode-ai         需要 Node >= 18
#   * openmausbot         需要 Node >= 24   ← 决定了默认下限
# Ubuntu 24.04 自带 Node 18, 不够用, 所以不装发行版包。
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export HOME=/root

NODE_MAJOR="${PIN_NODE_MAJOR:-24}"

if command -v node >/dev/null && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge "$NODE_MAJOR" ]; then
  echo "已存在 Node $(node -v), 满足 >=${NODE_MAJOR}, 跳过"
  exit 0
fi

# 首选 NodeSource
if curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource_setup.sh; then
  bash /tmp/nodesource_setup.sh || echo "warn: NodeSource 脚本返回非零, 继续尝试"
  apt-get install -y nodejs || true
fi

# 回退: 官方二进制 tarball (NodeSource 被墙/源不可用时的兜底)
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt "$NODE_MAJOR" ]; then
  echo "回退到官方 tarball (v${NODE_MAJOR})"
  TARBALL=$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/" \
    | grep -oE "node-v${NODE_MAJOR}\\.[0-9.]*-linux-x64\\.tar\\.xz" | head -1)
  [ -n "$TARBALL" ] || { echo "ERROR: 无法确定 Node ${NODE_MAJOR} tarball 名称"; exit 1; }
  curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/${TARBALL}" -o /tmp/node.tar.xz
  tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
fi

node -v
npm -v
npm config set fund false --location=global
npm config set audit false --location=global
echo "nodejs ok"
