#!/bin/bash
# 85-godot.sh — Godot Engine 4.7.2 (Linux x86_64 标准编辑器二进制；不含 export templates)
# 官方: https://godotengine.org/download/archive/4.7.2-stable/
# 发布: https://github.com/godotengine/godot/releases/tag/4.7.2-stable
#
# 装到 /opt/godot/4.7.2/ + /usr/local/bin/godot 符号链接。
# 校验用官方 SHA512-SUMS.txt（Godot 不发布该 zip 的 SHA256）。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"

GODOT_VERSION="${PIN_GODOT:-4.7.2}"
# asset: Godot_v4.7.2-stable_linux.x86_64.zip (linux.x86_64 standard editor)
GODOT_TAG="${GODOT_VERSION}-stable"
ZIP_NAME="Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
BIN_NAME="Godot_v${GODOT_VERSION}-stable_linux.x86_64"
INSTALL_DIR="/opt/godot/${GODOT_VERSION}"
INSTALL_BIN="${INSTALL_DIR}/${BIN_NAME}"
LINK_BIN="/usr/local/bin/godot"
# 官方发布资产校验和（SHA512-SUMS.txt）
EXPECT_SHA512="${GODOT_SHA512:-9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65}"
DOWNLOAD_URL="${GODOT_DOWNLOAD_URL:-https://github.com/godotengine/godot/releases/download/${GODOT_TAG}/${ZIP_NAME}}"
# downloads.godotengine.org 查询式链接（备用）
FALLBACK_URL="${GODOT_FALLBACK_URL:-https://downloads.godotengine.org/?version=${GODOT_VERSION}&flavor=stable&slug=linux.x86_64.zip&platform=linux.64}"

if [ "$GODOT_VERSION" != "4.7.2" ]; then
  echo "ERROR: 本脚本固定预装 Godot 4.7.2（当前 PIN_GODOT=$GODOT_VERSION）"
  exit 1
fi

verify_zip() {
  local zip="$1" expect="$2"
  [ -f "$zip" ] || { echo "ERROR: 缺少 $zip"; return 1; }
  local actual
  actual="$(sha512sum "$zip" | awk '{print $1}')"
  if [ -n "$expect" ] && [ "$actual" != "$expect" ]; then
    echo "ERROR: Godot zip sha512 不匹配"
    echo "  expect: $expect"
    echo "  actual: $actual"
    return 1
  fi
}

install_from_zip() {
  local zip="$1"
  command -v unzip >/dev/null || {
    echo "ERROR: 需要 unzip（应由 00-base 安装）"
    return 1
  }
  verify_zip "$zip" "$EXPECT_SHA512"
  install -d -m 0755 "$INSTALL_DIR"
  # -j: 扁平解压到目标目录；覆盖旧文件
  unzip -o -j "$zip" -d "$INSTALL_DIR"
  [ -f "$INSTALL_BIN" ] || {
    echo "ERROR: 解压后缺少 $INSTALL_BIN"
    ls -la "$INSTALL_DIR" || true
    return 1
  }
  chmod 0755 "$INSTALL_BIN"
  install -d -m 0755 /usr/local/bin
  ln -sfn "$INSTALL_BIN" "$LINK_BIN"
}

install_offline() {
  local dir zip name
  dir="$(offline_root)/godot"
  [ -d "$dir" ] || {
    echo "ERROR: 离线捆绑缺少 godot/ — 请用 --force 重建: ./tools/fetch-offline-bundle.sh --force ..."
    return 1
  }
  if [ -f "$dir/zip.name" ]; then
    name="$(cat "$dir/zip.name")"
  else
    name="$ZIP_NAME"
  fi
  zip="$dir/$name"
  [ -f "$zip" ] || zip="$dir/$ZIP_NAME"
  [ -f "$zip" ] || {
    echo "ERROR: 离线捆绑 godot/ 内无 zip (期望 $name)"
    ls -la "$dir" || true
    return 1
  }
  if [ -f "$dir/sha512" ]; then
    EXPECT_SHA512="$(tr -d '[:space:]' < "$dir/sha512")"
  fi
  echo "offline: 安装 Godot ${GODOT_VERSION} 自 $zip"
  install_from_zip "$zip"
}

download_zip() {
  local dest="$1" url
  for url in "$DOWNLOAD_URL" "$FALLBACK_URL"; do
    echo "下载 Godot ${GODOT_VERSION}: $url"
    if curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"; then
      return 0
    fi
    echo "warn: 下载失败，尝试备用源…"
    rm -f "$dest"
  done
  echo "ERROR: 无法下载 $ZIP_NAME"
  return 1
}

install_online() {
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  download_zip "$tmp/$ZIP_NAME"
  install_from_zip "$tmp/$ZIP_NAME"
  echo "Godot ${GODOT_VERSION} → $INSTALL_BIN (link $LINK_BIN)"
}

if offline_enabled 2>/dev/null; then
  install_offline
else
  install_online
fi

hash -r 2>/dev/null || true
command -v godot >/dev/null || { echo "ERROR: godot 未进入 PATH"; exit 1; }
[ -x "$INSTALL_BIN" ] || { echo "ERROR: 缺少可执行 $INSTALL_BIN"; exit 1; }
[ -L "$LINK_BIN" ] || [ -x "$LINK_BIN" ] || { echo "ERROR: 缺少 $LINK_BIN"; exit 1; }

ver="$(godot --version 2>/dev/null | head -1 || true)"
echo "godot --version: $ver"
case "$ver" in
  4.7.2*) ;;
  *)
    echo "ERROR: 期望 Godot 4.7.2.x，得到: $ver"
    exit 1
    ;;
esac
echo "godot ok (仅引擎二进制；不含 export templates；GUI 需本机显示驱动/库)"
