#!/bin/bash
# 15-github-cli.sh — GitHub CLI (gh)
# 官方: https://github.com/cli/cli/blob/trunk/docs/install_linux.md
# 只装二进制；不执行 gh auth（装机后本机登录）。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
export DEBIAN_FRONTEND=noninteractive

if offline_enabled 2>/dev/null && offline_apt_ready 2>/dev/null; then
  echo "offline: 从本地 apt 安装 gh (不添加 cli.github.com)"
  offline_apt_install gh
else
  ARCH="$(dpkg --print-architecture)"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  # 官方源按 stable/main，不绑 Ubuntu 代号（与 docker 不同）
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
    "$ARCH" > /etc/apt/sources.list.d/github-cli.list
  apt-get update
  apt-get install -y --no-install-recommends gh
fi

command -v gh >/dev/null
gh --version
echo "github-cli ok (未登录；装机后执行 gh auth login)"
