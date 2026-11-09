#!/bin/bash
# lib-offline.sh — 离线模式公共函数 (由各 software/*.sh source)
#
# OFFLINE=1 且存在 /opt/offline 时走本地 apt / npm / node tarball。
# 由 late-commands 在 run-all 之前挂好 file: apt 源。

offline_enabled() {
  [ "${OFFLINE:-0}" = "1" ] || [ "${OFFLINE:-}" = "true" ]
}

offline_root() {
  echo "${OFFLINE_ROOT:-/opt/offline}"
}

offline_apt_ready() {
  [ -f "$(offline_root)/apt/Packages" ] || [ -f "$(offline_root)/apt/Packages.gz" ]
}

# 确保只从本地 offline apt 安装 (源应已由 late-commands 写入)
offline_apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

offline_extract_npm_prefix() {
  local tgz
  tgz="$(offline_root)/npm/prefix.tar.gz"
  [ -f "$tgz" ] || { echo "ERROR: 缺少 $tgz"; return 1; }
  # 解压到 /usr/local (与 npm --prefix /usr/local 布局一致: bin/ lib/)
  tar -xzf "$tgz" -C /usr/local
  hash -r 2>/dev/null || true
}

offline_install_node_tarball() {
  local dir name tarball
  dir="$(offline_root)/node"
  [ -d "$dir" ] || return 1
  if [ -f "$dir/tarball.name" ]; then
    name="$(cat "$dir/tarball.name")"
    tarball="$dir/$name"
  else
    tarball="$(find "$dir" -maxdepth 1 -name 'node-v*-linux-x64.tar.xz' -print 2>/dev/null | head -1 || true)"
  fi
  [ -n "${tarball:-}" ] && [ -f "$tarball" ] || return 1
  tar -xJf "$tarball" -C /usr/local --strip-components=1
  hash -r 2>/dev/null || true
}
