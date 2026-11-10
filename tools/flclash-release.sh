#!/bin/bash
# flclash-release.sh — 解析并校验官方 FlClash GitHub Release 的 linux .deb
# 官方: https://github.com/chen08209/FlClash/releases
# 只用 GitHub 官方资产与同级 SHA256SUMS, 不使用第三方镜像。
# 由 software/37-flclash.sh 与 tools/fetch-offline-bundle.sh source。

FLCLASH_REPO_URL="${FLCLASH_REPO_URL:-https://github.com/chen08209/FlClash}"
FLCLASH_API_URL="${FLCLASH_API_URL:-https://api.github.com/repos/chen08209/FlClash}"

flclash_normalize_pin() {
  local p="${1:-latest}"
  p="${p#v}"
  printf '%s' "$p"
}

# latest 或 X.Y.Z (可带预发布后缀, 如 0.9.3 / 0.9.0-beta.1)
flclash_pin_ok() {
  local p
  p="$(flclash_normalize_pin "$1")"
  [[ "$p" == "latest" || "$p" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]]
}

flclash_asset_name() { # ver arch
  printf 'FlClash-%s-linux-%s.deb' "$1" "$2"
}

# 从官方 SHA256SUMS 取出某文件的哈希 (兼容 "hash  ./name" 与 "hash  name")
flclash_sums_hash() {
  local sums="$1" name="$2"
  awk -v n="$name" '
    NF>=2 {
      f=$2
      sub(/^\.\//, "", f)
      if (f==n) { print $1; exit }
    }
  ' "$sums"
}

# 解析 PIN + ARCH → 设置:
#   FLCLASH_VERSION FLCLASH_TAG FLCLASH_DEB_NAME
#   FLCLASH_DEB_URL FLCLASH_SUMS_URL
flclash_resolve() {
  local pin arch tag effective
  pin="$(flclash_normalize_pin "${1:-latest}")"
  arch="${2:-amd64}"
  case "$arch" in
    amd64|arm64) ;;
    *)
      echo "ERROR: FlClash 官方 linux deb 仅有 amd64 / arm64 (当前 $arch)" >&2
      return 1
      ;;
  esac
  if ! flclash_pin_ok "$pin"; then
    echo "ERROR: 非法 FlClash 版本: $1 (latest 或 X.Y.Z)" >&2
    return 1
  fi
  if [[ "$pin" == "latest" ]]; then
    effective="$(curl -fsSL --retry 3 --retry-delay 2 -o /dev/null -w '%{url_effective}' \
      "$FLCLASH_REPO_URL/releases/latest")" || effective=""
    tag="${effective##*/}"
    if [[ ! "$tag" =~ ^v?[0-9]+\.[0-9]+ ]]; then
      tag="$(curl -fsSL --retry 3 --retry-delay 2 "$FLCLASH_API_URL/releases/latest" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')" || tag=""
    fi
    [[ "$tag" =~ ^v?[0-9]+\.[0-9]+ ]] || {
      echo "ERROR: 无法解析 FlClash latest (GitHub releases/latest)" >&2
      return 1
    }
    pin="$(flclash_normalize_pin "$tag")"
  fi
  FLCLASH_VERSION="$pin"
  FLCLASH_TAG="v${pin}"
  FLCLASH_DEB_NAME="$(flclash_asset_name "$FLCLASH_VERSION" "$arch")"
  FLCLASH_DEB_URL="${FLCLASH_REPO_URL}/releases/download/${FLCLASH_TAG}/${FLCLASH_DEB_NAME}"
  FLCLASH_SUMS_URL="${FLCLASH_REPO_URL}/releases/download/${FLCLASH_TAG}/SHA256SUMS"
}

# 校验 dest 的 sha256。sums 文件存在则必须命中; 否则用 expect_sha (可空=只记录)
# 成功时把实际哈希写到 FLCLASH_SHA256
flclash_verify_deb() { # deb_path [sums_path] [expect_sha]
  local deb="$1" sums="${2:-}" expect="${3:-}" actual
  [ -f "$deb" ] || { echo "ERROR: 缺少 $deb" >&2; return 1; }
  actual="$(sha256sum "$deb" | awk '{print $1}')"
  if [ -n "$sums" ] && [ -f "$sums" ]; then
    expect="$(flclash_sums_hash "$sums" "$(basename "$deb")")"
    if [ -z "$expect" ]; then
      echo "ERROR: SHA256SUMS 中没有 $(basename "$deb")" >&2
      return 1
    fi
  fi
  if [ -n "$expect" ] && [ "$actual" != "$expect" ]; then
    echo "ERROR: FlClash deb sha256 不匹配" >&2
    echo "  expect: $expect" >&2
    echo "  actual: $actual" >&2
    return 1
  fi
  # 输出给调用方 (fetch-offline-bundle / 37-flclash)
  # shellcheck disable=SC2034
  FLCLASH_SHA256="$actual"
}

# 下载 SHA256SUMS + deb 到 dest_dir, 校验后设置 FLCLASH_DEB_PATH / FLCLASH_SHA256
# 若 dest_dir 已有同名 deb 且校验通过, 不重下。
flclash_download_to() { # dest_dir
  local dest="$1" sums tmp
  [ -n "$FLCLASH_DEB_URL" ] || { echo "ERROR: 请先 flclash_resolve" >&2; return 1; }
  mkdir -p "$dest"
  sums="$dest/SHA256SUMS"
  if [ ! -s "$sums" ]; then
    echo "下载 FlClash SHA256SUMS: $FLCLASH_SUMS_URL"
    if ! curl -fL --retry 3 --retry-delay 2 -o "$sums" "$FLCLASH_SUMS_URL"; then
      echo "warn: 该 Release 没有 SHA256SUMS, 将记录下载文件的 sha256" >&2
      rm -f "$sums"
      sums=""
    fi
  fi
  FLCLASH_DEB_PATH="$dest/$FLCLASH_DEB_NAME"
  if [ -f "$FLCLASH_DEB_PATH" ]; then
    if flclash_verify_deb "$FLCLASH_DEB_PATH" "$sums" ""; then
      echo "复用已下载的 $FLCLASH_DEB_NAME (sha256 一致)"
      return 0
    fi
    echo "warn: 已有 $FLCLASH_DEB_NAME 校验失败, 重新下载"
    rm -f "$FLCLASH_DEB_PATH"
  fi
  tmp="$(mktemp "$dest/.flclash.XXXXXX")"
  echo "下载 FlClash ${FLCLASH_VERSION}: $FLCLASH_DEB_URL"
  if ! curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$FLCLASH_DEB_URL"; then
    rm -f "$tmp"
    echo "ERROR: 无法下载 $FLCLASH_DEB_URL" >&2
    return 1
  fi
  mv -f "$tmp" "$FLCLASH_DEB_PATH"
  flclash_verify_deb "$FLCLASH_DEB_PATH" "$sums" ""
}

# 从 deb 的 Depends 抽出包名 (取 | 的第一候选, 去掉版本约束)
flclash_deb_depends() {
  local deb="$1" dep first
  dpkg-deb -f "$deb" Depends 2>/dev/null | tr ',' '\n' | while IFS= read -r dep; do
    first="${dep%%|*}"
    first="$(printf '%s' "$first" | sed 's/([^)]*)//g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$first" ] && printf '%s\n' "$first"
  done
}
