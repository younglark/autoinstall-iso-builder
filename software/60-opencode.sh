#!/bin/bash
# 60-opencode.sh — OpenCode
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
export HOME=/root

command -v node >/dev/null || { echo "ERROR: 需要先执行 40-nodejs.sh"; exit 1; }

VER="${PIN_OPENCODE:-latest}"
if offline_enabled 2>/dev/null && [ -f "$(offline_root)/npm/prefix.tar.gz" ]; then
  echo "offline: 使用已解压/捆绑的 npm prefix (opencode pin=$VER)"
  command -v opencode >/dev/null || offline_extract_npm_prefix
else
  npm install -g "opencode-ai@${VER}" --no-audit --no-fund
fi

command -v opencode >/dev/null || { echo "ERROR: opencode 未进入 PATH"; exit 1; }
opencode --version
echo "opencode ok (pin=${VER}; 首次使用: opencode auth login)"
