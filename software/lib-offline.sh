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
  # --no-same-owner: 勿把宿主机 uid 1000 写成 /usr/local 属主 (装机用户恰为 1000)
  # --no-overwrite-dir: 不覆盖已有目录的元数据/属主
  tar --no-same-owner --no-overwrite-dir -xzf "$tgz" -C /usr/local
  hash -r 2>/dev/null || true
}

# 把官方 Node tarball 装到 /opt/node-vX.Y.Z 并 symlink 进 /usr/local/{bin,lib,...}
# 避免 tar 把整个 /usr/local 属主改成打包用户。
offline_install_node_tarball() {
  local dir name tarball verdir base
  dir="$(offline_root)/node"
  [ -d "$dir" ] || return 1
  if [ -f "$dir/tarball.name" ]; then
    name="$(cat "$dir/tarball.name")"
    tarball="$dir/$name"
  else
    tarball="$(find "$dir" -maxdepth 1 -name 'node-v*-linux-x64.tar.xz' -print 2>/dev/null | head -1 || true)"
  fi
  [ -n "${tarball:-}" ] && [ -f "$tarball" ] || return 1
  base="$(basename "$tarball" .tar.xz)"   # node-v24.x.y-linux-x64
  verdir="/opt/${base}"
  mkdir -p /opt
  rm -rf "$verdir"
  mkdir -p "$verdir"
  tar --no-same-owner --no-overwrite-dir -xJf "$tarball" -C "$verdir" --strip-components=1
  # 官方 tarball 顶层含 bin include lib share
  local sub item
  for sub in bin include lib share; do
    if [ -d "$verdir/$sub" ]; then
      mkdir -p "/usr/local/$sub"
      # 逐项链接, 不 chown /usr/local
      for item in "$verdir/$sub"/*; do
        [ -e "$item" ] || continue
        ln -sfn "$item" "/usr/local/$sub/$(basename "$item")"
      done
    fi
  done
  hash -r 2>/dev/null || true
}

# npm 全局前缀里的 @opencode/cli 会拉同一 arch 的全部可选二进制 (glibc/musl、avx2/baseline, 各约 235MB)。
# postinstall 已把当前主机适用的那份拷/链到 @opencode/cli/bin/opencode.exe。
# 这里只保留目标 linux + 本 arch 的 glibc 变体 (avx2 + baseline), 去掉 musl / 其它 OS。
# $1 = npm prefix (如 /usr/local 或打包用的临时 prefix); $2 = node arch (x64 / arm64)。
aib_opencode_node_arch() {
  case "${1:-}" in
    amd64|x86_64|x64) printf 'x64\n' ;;
    arm64|aarch64) printf 'arm64\n' ;;
    *) printf 'x64\n' ;;
  esac
}

aib_prune_opencode_cli_platform() {
  local prefix="$1" arch_node="$2"
  local mods="$prefix/lib/node_modules/@opencode/cli/node_modules/@opencode"
  [ -d "$mods" ] || return 0
  local d base
  for d in "$mods"/cli-*; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    case "$base" in
      "cli-linux-${arch_node}"|"cli-linux-${arch_node}-baseline") ;;
      *) rm -rf "$d" ;;
    esac
  done
}

# 在目标机再跑一次 postinstall, 按本机 CPU (avx2 / baseline) 选二进制。
aib_opencode_cli_postinstall() {
  local prefix="$1"
  local script="$prefix/lib/node_modules/@opencode/cli/postinstall.mjs"
  [ -f "$script" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  node "$script" || return 1
}
