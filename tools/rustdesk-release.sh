#!/bin/bash
# rustdesk-release.sh — 解析并校验官方 RustDesk GitHub Release 的 linux .deb
# 官方: https://github.com/rustdesk/rustdesk/releases
# 版本钉扎 (默认 RUSTDESK_DEFAULT_VERSION, 已在真机 Ubuntu 24.04 Desktop 上验证)。默认版本的 sha256 写死在下面;
# 其它版本 (--pin-rustdesk) 用 GitHub Release API 给出的资产 digest (sha256) 校验, 拿不到就失败。
# 由 software/38-rustdesk.sh 与 tools/fetch-offline-bundle.sh source。

RUSTDESK_DEFAULT_VERSION="1.5.1"
RUSTDESK_REPO_URL="${RUSTDESK_REPO_URL:-https://github.com/rustdesk/rustdesk}"
RUSTDESK_API_URL="${RUSTDESK_API_URL:-https://api.github.com/repos/rustdesk/rustdesk}"
# 下载基址 (默认 GitHub releases/download; 内网可指向同样目录结构的镜像, sha256 仍按官方值校验)
RUSTDESK_DL_BASE="${RUSTDESK_DL_BASE:-$RUSTDESK_REPO_URL/releases/download}"

# 官方资产 sha256 (GitHub Release API digest; 1.5.1 于 2026-11-01 发布)
rustdesk_known_sha256() { # ver deb_name
  case "$1/$2" in
    1.5.1/rustdesk-1.5.1-x86_64.deb)  echo b5d682ad90cb7571ecbdbf26eef58d3c4514e726a74ef6d08ce3f0b114ef0bd9 ;;
    1.5.1/rustdesk-1.5.1-aarch64.deb) echo d1471ed916dc21e3ae3965f936c51944e1f2635a6d521fcc4663486696018465 ;;
    *) return 1 ;;
  esac
}

rustdesk_valid_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+)?$ ]]
}

rustdesk_asset_name() { # ver dpkg-arch
  case "$2" in
    amd64) printf 'rustdesk-%s-x86_64.deb' "$1" ;;
    arm64) printf 'rustdesk-%s-aarch64.deb' "$1" ;;
    *) return 1 ;;
  esac
}

# 解析 → 设置 RUSTDESK_VERSION RUSTDESK_DEB_NAME RUSTDESK_DEB_URL RUSTDESK_SHA256
rustdesk_resolve() { # [ver] [dpkg-arch]
  local ver="${1:-$RUSTDESK_DEFAULT_VERSION}" arch="${2:-amd64}" name sha=""
  rustdesk_valid_version "$ver" || { echo "ERROR: RustDesk 版本号非法: $ver (应为 X.Y.Z)" >&2; return 1; }
  name="$(rustdesk_asset_name "$ver" "$arch")" \
    || { echo "ERROR: RustDesk 官方 linux deb 只有 amd64 / arm64 (当前 $arch)" >&2; return 1; }
  if ! sha="$(rustdesk_known_sha256 "$ver" "$name")"; then
    # 非默认版本: 用 GitHub Release API 的资产 digest (sha256:<hex>)
    sha="$(curl -fsSL --retry 3 --retry-delay 2 "$RUSTDESK_API_URL/releases/tags/$ver" 2>/dev/null \
      | python3 -c '
import json, sys
name = sys.argv[1]
for a in json.load(sys.stdin).get("assets", []):
    if a.get("name") == name and str(a.get("digest") or "").startswith("sha256:"):
        print(a["digest"].split(":", 1)[1]); break
' "$name" 2>/dev/null)" || sha=""
  fi
  if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: 拿不到 RustDesk $ver ($name) 的官方 sha256 (GitHub Release API digest)" >&2
    return 1
  fi
  RUSTDESK_VERSION="$ver"
  RUSTDESK_DEB_NAME="$name"
  RUSTDESK_DEB_URL="$RUSTDESK_DL_BASE/$ver/$name"
  RUSTDESK_SHA256="$sha"
}

rustdesk_verify_deb() { # deb expect_sha
  local deb="$1" expect="$2" actual
  [ -f "$deb" ] || { echo "ERROR: 缺少 $deb" >&2; return 1; }
  [[ "$expect" =~ ^[0-9a-f]{64}$ ]] || { echo "ERROR: RustDesk 期望 sha256 非法" >&2; return 1; }
  actual="$(sha256sum "$deb" | awk '{print $1}')"
  if [ "$actual" != "$expect" ]; then
    echo "ERROR: RustDesk deb sha256 不匹配: $(basename "$deb")" >&2
    echo "  expect: $expect" >&2
    echo "  actual: $actual" >&2
    return 1
  fi
}

# 下载到 dest_dir 并校验; 已有同名且校验通过则不重下。设置 RUSTDESK_DEB_PATH
rustdesk_download_to() { # dest_dir
  local dest="$1" tmp
  [ -n "${RUSTDESK_DEB_URL:-}" ] || { echo "ERROR: 请先 rustdesk_resolve" >&2; return 1; }
  mkdir -p "$dest"
  RUSTDESK_DEB_PATH="$dest/$RUSTDESK_DEB_NAME"
  if [ -f "$RUSTDESK_DEB_PATH" ] && rustdesk_verify_deb "$RUSTDESK_DEB_PATH" "$RUSTDESK_SHA256" 2>/dev/null; then
    echo "复用已下载的 $RUSTDESK_DEB_NAME (sha256 一致)"
    return 0
  fi
  rm -f "$RUSTDESK_DEB_PATH"
  tmp="$(mktemp "$dest/.rustdesk.XXXXXX")"
  echo "下载 RustDesk ${RUSTDESK_VERSION}: $RUSTDESK_DEB_URL"
  if ! curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$RUSTDESK_DEB_URL"; then
    rm -f "$tmp"
    echo "ERROR: 无法下载 $RUSTDESK_DEB_URL" >&2
    return 1
  fi
  mv -f "$tmp" "$RUSTDESK_DEB_PATH"
  rustdesk_verify_deb "$RUSTDESK_DEB_PATH" "$RUSTDESK_SHA256"
}
