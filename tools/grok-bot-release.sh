#!/bin/bash
# shellcheck disable=SC2034  # GROK_BOT_* 结果变量由 source 方使用
# grok-bot-release.sh — 解析 / 下载 / 校验 Grok Bot 桌面版官方 linux .deb
# 由 software/39-grok-bot.sh 与 tools/fetch-offline-bundle.sh source。
#
# 来源 (都是官方):
#   发布 feed  https://api2.cursor.sh/updates/api/download/stable/linux-x64/sand   (arm64: linux-arm64)
#              JSON: {"version", "commitSha", "debUrl", ...}; 只给当前最新版, 不给 sha256
#   apt 仓库   https://downloads.cursor.com/aptrepo  suite grok-bot (deb 装好后 postinst 自己也会登记这个源)
#
# 版本 / 校验 (按优先级):
#   1. GROK_BOT_DEB_URL + GROK_BOT_SHA256   完全钉扎 (可复现; 也可指向内网镜像)
#   2. PIN_GROK_BOT=X.Y.Z 且下面内置了它   内置的官方 URL + sha256
#   3. PIN_GROK_BOT=latest (默认) 或 = feed 当前版本: feed 给 URL; sha256 取自 apt 仓库的 Packages,
#      Packages 由 gpgv 校验过签名的 InRelease 担保 (公钥 tools/grok-bot-archive-key.asc)
#   其它版本: feed 只给最新版, 只能用 1. (报错并提示)。只给 GROK_BOT_SHA256 时按 2./3. 取 URL, 用给定 sha256 校验。
# 下载后再核对 deb 的 Package=grok-bot / Architecture / Version。

GROK_BOT_FEED_BASE="${GROK_BOT_FEED_BASE:-https://api2.cursor.sh/updates/api/download/stable}"
GROK_BOT_APT_BASE="${GROK_BOT_APT_BASE:-https://downloads.cursor.com/aptrepo}"
GROK_BOT_APT_SUITE="grok-bot"
GROK_BOT_KEY_FILE="${GROK_BOT_KEY_FILE:-$(dirname -- "${BASH_SOURCE[0]}")/grok-bot-archive-key.asc}"
# 国内访问 downloads.cursor.com 可能很慢: 连接超时短一点, 整体给足时间 (deb 约 110 MB)
GROK_BOT_CURL=(curl -fL --retry 3 --retry-delay 3 --connect-timeout 20)

# 官方 0.79.4 (2026-11-10 发布; sha256 与 apt 仓库 Packages 一致)
grokbot_known() { # ver dpkg-arch  →  "url sha256"
  case "$1/$2" in
    0.79.4/amd64) echo "https://downloads.cursor.com/grokbot/stable/7b5e3d87b3866229f111269975bc91bd8f3f7243/linux/x64/grok-bot_0.79.4_amd64.deb cf0fd0032249cf08e75f6dff045766b5195078dd878d1eeed60a68c4d31a7a5a" ;;
    0.79.4/arm64) echo "https://downloads.cursor.com/grokbot/stable/7b5e3d87b3866229f111269975bc91bd8f3f7243/linux/arm64/grok-bot_0.79.4_arm64.deb 2ba919c2c8a6ff29e8ad9065b82daa13635e4306677a5c6ce00e9bfb3c1f5324" ;;
    *) return 1 ;;
  esac
}

grokbot_valid_version() { [[ "$1" == latest || "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+~-][0-9A-Za-z.+~-]+)?$ ]]; }
grokbot_valid_url()     { [[ "$1" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?/[A-Za-z0-9._~%/+-]*\.deb$ ]]; }
grokbot_valid_sha256()  { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

grokbot_feed_arch() { # dpkg-arch → feed 平台名
  case "$1" in
    amd64) echo linux-x64 ;;
    arm64) echo linux-arm64 ;;
    *) return 1 ;;
  esac
}

# 读发布 feed → "version debUrl"
grokbot_feed() { # dpkg-arch → "version debUrl" (不依赖 python: 最小系统的 python3-minimal 没有 json 模块)
  local fa body v u
  fa="$(grokbot_feed_arch "$1")" || return 1
  body="$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 60 "$GROK_BOT_FEED_BASE/$fa/sand" 2>/dev/null)" || return 1
  body="$(printf '%s' "$body" | tr -d '\r\n')"
  v="$(printf '%s' "$body" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  u="$(printf '%s' "$body" | sed -n 's/.*"debUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$v" ] && [ -n "$u" ] || return 1
  printf '%s %s\n' "$v" "$u"
}

# 签名的 apt 索引里某版本 deb 的 sha256: gpgv 校验 InRelease → Packages 的 sha256 → 取 deb 的 SHA256
grokbot_index_sha256() { # ver dpkg-arch deb_name
  local ver="$1" arch="$2" name="$3" gbtmp want have sha="" rc=1
  [ -f "$GROK_BOT_KEY_FILE" ] || { echo "ERROR: 缺少 Grok Bot 仓库公钥 $GROK_BOT_KEY_FILE" >&2; return 1; }
  command -v gpgv >/dev/null 2>&1 || { echo "ERROR: 需要 gpgv 校验 Grok Bot apt 仓库签名" >&2; return 1; }
  gbtmp="$(mktemp -d)"
  if grep -vE '^(#|-----|=|$)' "$GROK_BOT_KEY_FILE" | base64 -d > "$gbtmp/key.gpg" 2>/dev/null \
     && curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 60 \
          -o "$gbtmp/InRelease" "$GROK_BOT_APT_BASE/dists/$GROK_BOT_APT_SUITE/InRelease" \
     && gpgv --keyring "$gbtmp/key.gpg" --output "$gbtmp/Release" "$gbtmp/InRelease" 2>/dev/null; then
    want="$(awk -v f="main/binary-$arch/Packages" '/^SHA256:/ {s=1; next} /^[^ ]/ {s=0} s && $3==f {print $1; exit}' "$gbtmp/Release")"
    if [ -n "$want" ] && curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 60 \
         -o "$gbtmp/Packages" "$GROK_BOT_APT_BASE/dists/$GROK_BOT_APT_SUITE/main/binary-$arch/Packages"; then
      have="$(sha256sum "$gbtmp/Packages" | awk '{print $1}')"
      if [ "$have" = "$want" ]; then
        sha="$(awk -v v="$ver" -v n="$name" '
          /^$/ {p=""; ver=""; fn=""; h=""}
          /^Package: / {p=$2} /^Version: / {ver=$2} /^SHA256: / {h=$2}
          /^Filename: / {fn=$2; sub(/.*\//, "", fn)}
          p=="grok-bot" && ver==v && fn==n && h!="" {print h; exit}' "$gbtmp/Packages")"
        grokbot_valid_sha256 "$sha" && rc=0
      else
        echo "ERROR: Grok Bot apt 仓库 Packages 的 sha256 与签名的 InRelease 不符" >&2
      fi
    fi
  else
    echo "ERROR: 无法获取或校验 Grok Bot apt 仓库 InRelease 签名 ($GROK_BOT_APT_BASE)" >&2
  fi
  rm -rf "$gbtmp"
  [ "$rc" -eq 0 ] && printf '%s\n' "$sha"
  return "$rc"
}

# 解析 → 设置 GROK_BOT_VERSION (完全钉扎 URL 时可能为空, 下载后从 deb 读) GROK_BOT_DEB_URL
#          GROK_BOT_DEB_NAME GROK_BOT_SHA256 GROK_BOT_SHA_SOURCE (pinned|builtin|apt-index)
grokbot_resolve() { # [pin] [dpkg-arch] [url] [sha256]
  local pin="${1:-latest}" arch="${2:-amd64}" url="${3:-}" sha="${4:-}" known feed fver furl
  GROK_BOT_VERSION="" GROK_BOT_DEB_URL="" GROK_BOT_DEB_NAME="" GROK_BOT_SHA256="" GROK_BOT_SHA_SOURCE=""
  grokbot_valid_version "$pin" || { echo "ERROR: Grok Bot 版本号非法: $pin (X.Y.Z 或 latest)" >&2; return 1; }
  grokbot_feed_arch "$arch" >/dev/null || { echo "ERROR: Grok Bot 官方 linux deb 只有 amd64 / arm64 (当前 $arch)" >&2; return 1; }
  [ -z "$url" ] || grokbot_valid_url "$url" || { echo "ERROR: Grok Bot deb URL 非法: $url" >&2; return 1; }
  [ -z "$sha" ] || grokbot_valid_sha256 "$sha" || { echo "ERROR: Grok Bot sha256 非法 (64 位小写 hex)" >&2; return 1; }
  if [ -n "$url" ]; then
    [ -n "$sha" ] || { echo "ERROR: 指定 Grok Bot deb URL 时必须同时给 sha256" >&2; return 1; }
    [ "$pin" = latest ] || GROK_BOT_VERSION="$pin"
    GROK_BOT_DEB_URL="$url"; GROK_BOT_SHA256="$sha"; GROK_BOT_SHA_SOURCE="pinned"
  elif [ "$pin" != latest ] && known="$(grokbot_known "$pin" "$arch")"; then
    GROK_BOT_VERSION="$pin"; GROK_BOT_DEB_URL="${known% *}"; GROK_BOT_SHA256="${known#* }"; GROK_BOT_SHA_SOURCE="builtin"
    if [ -n "$sha" ] && [ "$sha" != "$GROK_BOT_SHA256" ]; then
      echo "ERROR: 给定的 Grok Bot sha256 与内置的 $pin 官方值不符" >&2; return 1
    fi
  else
    feed="$(grokbot_feed "$arch")" || feed=""
    fver="${feed%% *}"; furl="${feed#* }"
    if [ -z "$feed" ] || ! grokbot_valid_version "$fver" || [ "$fver" = latest ] || ! grokbot_valid_url "$furl"; then
      echo "ERROR: 无法读取 Grok Bot 发布 feed ($GROK_BOT_FEED_BASE/$(grokbot_feed_arch "$arch")/sand)" >&2
      return 1
    fi
    if [ "$pin" != latest ] && [ "$pin" != "$fver" ]; then
      echo "ERROR: Grok Bot $pin 不是 feed 当前版本 ($fver), 也没有内置 sha256; 请改用 --grok-bot-url <deb URL> --grok-bot-sha256 <hex>" >&2
      return 1
    fi
    GROK_BOT_VERSION="$fver"; GROK_BOT_DEB_URL="$furl"
    if [ -n "$sha" ]; then
      GROK_BOT_SHA256="$sha"; GROK_BOT_SHA_SOURCE="pinned"
    elif known="$(grokbot_known "$fver" "$arch")" && [ "${known% *}" = "$furl" ]; then
      GROK_BOT_SHA256="${known#* }"; GROK_BOT_SHA_SOURCE="builtin"
    else
      GROK_BOT_SHA256="$(grokbot_index_sha256 "$fver" "$arch" "${furl##*/}")" || {
        echo "ERROR: 拿不到 Grok Bot $fver 的官方 sha256 (签名的 apt 仓库索引); 可用 --grok-bot-sha256 指定" >&2
        return 1
      }
      GROK_BOT_SHA_SOURCE="apt-index"
    fi
  fi
  GROK_BOT_DEB_NAME="${GROK_BOT_DEB_URL##*/}"
  [[ "$GROK_BOT_DEB_NAME" =~ ^[A-Za-z0-9._+~-]+\.deb$ ]] || { echo "ERROR: Grok Bot deb 文件名非法: $GROK_BOT_DEB_NAME" >&2; return 1; }
}

# deb 的 Recommends (每组取第一个候选, 去掉版本约束), 一行一个。0.79.4: libappindicator3-1
# (noble/jammy 都有这个包; libayatana-appindicator3-1 也 Provides 它)。
grokbot_recommends() { # deb
  dpkg-deb -f "$1" Recommends 2>/dev/null | tr ',' '\n' | while IFS= read -r r; do
    r="${r%%|*}"
    r="$(printf '%s' "$r" | sed 's/([^)]*)//g; s/:any//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ "$r" =~ ^[a-z0-9][a-z0-9.+-]+$ ]] && printf '%s\n' "$r"
  done
  return 0
}

# 上面的 Recommends 里 apt 当前能装的那些 (有 Candidate), 一行一个
grokbot_available_recommends() { # deb
  local r c
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    c="$(apt-cache policy "$r" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    if [ -n "$c" ] && [ "$c" != "(none)" ]; then printf '%s\n' "$r"; fi
  done < <(grokbot_recommends "$1")
  return 0
}

grokbot_verify_deb() { # deb expect_sha [expect_ver] [dpkg-arch]
  local deb="$1" expect="$2" ver="${3:-}" arch="${4:-}" actual f
  [ -f "$deb" ] || { echo "ERROR: 缺少 $deb" >&2; return 1; }
  grokbot_valid_sha256 "$expect" || { echo "ERROR: Grok Bot 期望 sha256 非法" >&2; return 1; }
  actual="$(sha256sum "$deb" | awk '{print $1}')"
  if [ "$actual" != "$expect" ]; then
    echo "ERROR: Grok Bot deb sha256 不匹配: $(basename "$deb")" >&2
    echo "  expect: $expect" >&2
    echo "  actual: $actual" >&2
    return 1
  fi
  if command -v dpkg-deb >/dev/null 2>&1; then
    f="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
    [ "$f" = grok-bot ] || { echo "ERROR: $(basename "$deb") 不是 grok-bot 包 (Package=$f)" >&2; return 1; }
    f="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
    if [ -n "$ver" ] && [ "$f" != "$ver" ]; then
      echo "ERROR: $(basename "$deb") 版本是 $f, 不是 $ver" >&2; return 1
    fi
    f="$(dpkg-deb -f "$deb" Architecture 2>/dev/null || true)"
    if [ -n "$arch" ] && [ "$f" != "$arch" ]; then
      echo "ERROR: $(basename "$deb") 架构是 $f, 不是 $arch" >&2; return 1
    fi
  fi
}

# 下载到 dest_dir 并校验; 已有同名且校验通过则不重下。设置 GROK_BOT_DEB_PATH, 版本为空时从 deb 读
grokbot_download_to() { # dest_dir [dpkg-arch]
  local dest="$1" arch="${2:-}" gbtmp
  [ -n "${GROK_BOT_DEB_URL:-}" ] || { echo "ERROR: 请先 grokbot_resolve" >&2; return 1; }
  mkdir -p "$dest"
  GROK_BOT_DEB_PATH="$dest/$GROK_BOT_DEB_NAME"
  if [ -f "$GROK_BOT_DEB_PATH" ] && grokbot_verify_deb "$GROK_BOT_DEB_PATH" "$GROK_BOT_SHA256" "$GROK_BOT_VERSION" "$arch" 2>/dev/null; then
    echo "复用已下载的 $GROK_BOT_DEB_NAME (sha256 一致)"
  else
    rm -f "$GROK_BOT_DEB_PATH"
    gbtmp="$(mktemp "$dest/.grok-bot.XXXXXX")"
    echo "下载 Grok Bot ${GROK_BOT_VERSION:-(钉扎 URL)}: $GROK_BOT_DEB_URL"
    if ! "${GROK_BOT_CURL[@]}" --max-time "${GROK_BOT_MAX_TIME:-1800}" -o "$gbtmp" "$GROK_BOT_DEB_URL"; then
      rm -f "$gbtmp"
      echo "ERROR: 无法下载 $GROK_BOT_DEB_URL (国内访问 downloads.cursor.com 可能很慢或被拦截; 可改用离线捆绑)" >&2
      return 1
    fi
    mv -f "$gbtmp" "$GROK_BOT_DEB_PATH"
    grokbot_verify_deb "$GROK_BOT_DEB_PATH" "$GROK_BOT_SHA256" "$GROK_BOT_VERSION" "$arch" || { rm -f "$GROK_BOT_DEB_PATH"; return 1; }
  fi
  if [ -z "$GROK_BOT_VERSION" ] && command -v dpkg-deb >/dev/null 2>&1; then
    GROK_BOT_VERSION="$(dpkg-deb -f "$GROK_BOT_DEB_PATH" Version 2>/dev/null || true)"
  fi
}
