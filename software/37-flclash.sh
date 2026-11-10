#!/bin/bash
# 37-flclash.sh — 预装 FlClash (ClashMeta 图形客户端)
# 官方: https://github.com/chen08209/FlClash/releases
# 默认 Desktop 安装最新稳定版 linux deb (始终跟随 GitHub releases/latest)。
# Server / 非 amd64,arm64 自动跳过; --skip 37 或 --no-flclash 也可跳过。
# 只装应用, 不写订阅、不设系统代理、不启用 TUN、不装开机自启。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
# shellcheck disable=SC1091
if [ -f "$HERE/flclash-release.sh" ]; then
  . "$HERE/flclash-release.sh"
elif [ -f "$HERE/../tools/flclash-release.sh" ]; then
  . "$HERE/../tools/flclash-release.sh"
else
  echo "ERROR: 找不到 flclash-release.sh"
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive

ARCH="${FLCLASH_ARCH:-$(dpkg --print-architecture)}"
if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
  echo "skip: FlClash 官方 linux deb 仅支持 amd64 / arm64 (当前 $ARCH)"
  exit 0
fi
if [ "${EDITION:-}" != "desktop" ]; then
  echo "skip: FlClash 仅在 Desktop 预装 (EDITION=${EDITION:-unset})"
  exit 0
fi

FLCLASH_BIN="/usr/bin/FlClash"
FLCLASH_OPT="/opt/FlClash/FlClash"

# control 字段是 FlClash, 但 dpkg-deb -f 会折成小写; 查询两种名字
flclash_pkg_status() {
  local s
  s="$(dpkg-query -W -f='${Status}' FlClash 2>/dev/null || true)"
  [ -n "$s" ] || s="$(dpkg-query -W -f='${Status}' flclash 2>/dev/null || true)"
  printf '%s' "$s"
}

flclash_pkg_version() {
  local v
  v="$(dpkg-query -W -f='${Version}' FlClash 2>/dev/null || true)"
  [ -n "$v" ] || v="$(dpkg-query -W -f='${Version}' flclash 2>/dev/null || true)"
  printf '%s' "$v"
}

already_ok() {
  local want="$1" have
  flclash_pkg_status | grep -q 'install ok installed' || return 1
  [ -x "$FLCLASH_BIN" ] || [ -x "$FLCLASH_OPT" ] || return 1
  [ -n "$want" ] || return 0
  have="$(flclash_pkg_version)"
  case "$have" in
    "$want"|"$want"+*) return 0 ;;
    *) return 1 ;;
  esac
}

install_deb() {
  local deb="$1"
  [ -f "$deb" ] || { echo "ERROR: 缺少 $deb"; return 1; }
  # 解析依赖并一起装 (离线时由本地 file: 源提供)
  apt-get install -y --no-install-recommends "$deb"
}

install_offline() {
  local dir name deb sums sha
  dir="$(offline_root)/flclash"
  [ -d "$dir" ] || {
    echo "ERROR: 离线捆绑缺少 flclash/ — 请用 --force 重建: ./tools/fetch-offline-bundle.sh --force ..."
    return 1
  }
  if [ -f "$dir/deb.name" ]; then
    name="$(cat "$dir/deb.name")"
  else
    name="$FLCLASH_DEB_NAME"
  fi
  deb="$dir/$name"
  if [ ! -f "$deb" ]; then
    deb="$(find "$dir" -maxdepth 1 -name 'FlClash-*-linux-*.deb' -print | head -1 || true)"
  fi
  if [ -z "${deb:-}" ] || [ ! -f "$deb" ]; then
    echo "ERROR: 离线捆绑 flclash/ 内无 deb (期望 $name)"
    ls -la "$dir" || true
    return 1
  fi
  sums=""
  [ -f "$dir/SHA256SUMS" ] && sums="$dir/SHA256SUMS"
  sha=""
  [ -f "$dir/sha256" ] && sha="$(tr -d '[:space:]' < "$dir/sha256")"
  echo "offline: 安装 FlClash (version=$(cat "$dir/version" 2>/dev/null || echo unknown)) 自 $deb"
  flclash_verify_deb "$deb" "$sums" "$sha"
  if already_ok "$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"; then
    echo "FlClash 已安装且版本一致, 跳过 apt"
    return 0
  fi
  install_deb "$deb"
}

install_online() {
  local tmp
  flclash_resolve "$ARCH"
  if already_ok "$FLCLASH_VERSION"; then
    echo "FlClash $FLCLASH_VERSION 已安装, 跳过下载"
    return 0
  fi
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  flclash_download_to "$tmp"
  install_deb "$FLCLASH_DEB_PATH"
}

if offline_enabled 2>/dev/null; then
  # 离线捆绑已写入抓取时的最新稳定版; 不在此处再访问 GitHub
  install_offline
else
  install_online
fi

if ! flclash_pkg_status | grep -q 'install ok installed'; then
  echo "ERROR: FlClash 包未安装"
  exit 1
fi
if [ ! -x "$FLCLASH_BIN" ] && [ ! -x "$FLCLASH_OPT" ]; then
  echo "ERROR: FlClash 已安装但找不到可执行文件 ($FLCLASH_BIN 或 $FLCLASH_OPT)"
  ls -la /opt/FlClash /usr/bin/FlClash 2>/dev/null || true
  exit 1
fi
if [ ! -f /usr/share/applications/FlClash.desktop ]; then
  echo "ERROR: 找不到 FlClash.desktop"
  exit 1
fi

ver="$(flclash_pkg_version)"
ver="${ver:-unknown}"
echo "FlClash $ver ok (只预装应用, 未配置订阅/系统代理/TUN/自启)"
