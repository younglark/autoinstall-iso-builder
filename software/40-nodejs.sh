#!/bin/bash
# 40-nodejs.sh — Node.js 24 (LTS)
#
# 三件事都卡在这一个版本上:
#   * @xai-official/grok  需要 Node >= 20
#   * opencode-ai         需要 Node >= 18
#   * openmausbot         需要 Node >= 24   ← 决定了必须上 24
# Ubuntu 24.04 自带 Node 18, 不够用, 所以不装发行版包。
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export HOME=/root

if command -v node >/dev/null && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 24 ]; then
  echo "已存在 Node $(node -v), 跳过"
  exit 0
fi

# 首选 NodeSource
if curl -fsSL https://deb.nodesource.com/setup_24.x -o /tmp/nodesource_setup.sh; then
  bash /tmp/nodesource_setup.sh || echo "warn: NodeSource 脚本返回非零, 继续尝试"
  apt-get install -y nodejs || true
fi

# 回退: 官方二进制 tarball (NodeSource 被墙/源不可用时的兜底)
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt 24 ]; then
  echo "回退到官方 tarball"
  TARBALL=$(curl -fsSL https://nodejs.org/dist/latest-v24.x/ \
    | grep -o 'node-v24\.[0-9.]*-linux-x64\.tar\.xz' | head -1)
  [ -n "$TARBALL" ] || { echo "ERROR: 无法确定 Node 24 tarball 名称"; exit 1; }
  curl -fsSL "https://nodejs.org/dist/latest-v24.x/${TARBALL}" -o /tmp/node.tar.xz
  tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
fi

node -v
npm -v
npm config set fund false --location=global
npm config set audit false --location=global
echo "nodejs ok"
