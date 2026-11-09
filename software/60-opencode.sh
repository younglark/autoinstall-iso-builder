#!/bin/bash
# 60-opencode.sh — OpenCode (开源终端 AI 编码代理)
# 版本由 PIN_OPENCODE 控制 (默认 latest)。
set -euo pipefail
export HOME=/root

command -v node >/dev/null || { echo "ERROR: 需要先执行 40-nodejs.sh"; exit 1; }

VER="${PIN_OPENCODE:-latest}"
npm install -g "opencode-ai@${VER}" --no-audit --no-fund

command -v opencode >/dev/null || { echo "ERROR: opencode 未进入 PATH"; exit 1; }

# 装完还要 opencode auth login 才能用, 密钥不进镜像
opencode --version
echo "opencode ok (pin=${VER}; 首次使用: opencode auth login)"
