#!/bin/bash
# 50-grok.sh — xAI Grok Build (官方 CLI)
#
# 注意区分两个东西:
#   @xai-official/grok   ← xAI 官方 (@xai-official), 文档里称 "Grok Build"
#   @vibe-kit/grok-cli   ← 社区项目, 非官方, 版本更新不保证
# 这里装官方那个。
set -euo pipefail
export HOME=/root

command -v node >/dev/null || { echo "ERROR: 需要先执行 40-nodejs.sh"; exit 1; }

npm install -g @xai-official/grok@latest --no-audit --no-fund

command -v grok >/dev/null || { echo "ERROR: grok 未进入 PATH"; exit 1; }

# 首次运行会开浏览器做 OAuth, 无头环境必须用 API key:
#   export XAI_API_KEY="xai-..."    (https://console.x.ai)
grok --version
echo "grok ok (运行前请配置 XAI_API_KEY, 镜像内不预置任何密钥)"
