#!/bin/bash
# 50-grok.sh — xAI Grok Build (官方 CLI)
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
export HOME=/root

command -v node >/dev/null || { echo "ERROR: 需要先执行 40-nodejs.sh"; exit 1; }

VER="${PIN_GROK:-latest}"
if offline_enabled 2>/dev/null && [ -f "$(offline_root)/npm/prefix.tar.gz" ]; then
  echo "offline: 从 npm prefix 树安装 grok (pin=$VER 已在捆绑时固化)"
  offline_extract_npm_prefix
else
  npm install -g "@xai-official/grok@${VER}" --no-audit --no-fund
fi

command -v grok >/dev/null || { echo "ERROR: grok 未进入 PATH"; exit 1; }
grok --version
echo "grok ok (pin=${VER}; 运行前请配置 XAI_API_KEY, 镜像内不预置任何密钥)"
