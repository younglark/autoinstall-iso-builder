#!/bin/bash
# 60-opencode.sh — OpenCode (开源终端 AI 编码代理)
set -euo pipefail
export HOME=/root

command -v node >/dev/null || { echo "ERROR: 需要先执行 40-nodejs.sh"; exit 1; }

npm install -g opencode-ai@latest --no-audit --no-fund

command -v opencode >/dev/null || { echo "ERROR: opencode 未进入 PATH"; exit 1; }

# 装完还要 opencode auth login 才能用, 密钥不进镜像
opencode --version
echo "opencode ok (首次使用: opencode auth login)"
