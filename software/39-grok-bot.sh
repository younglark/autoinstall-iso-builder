#!/bin/bash
# 39-grok-bot.sh — Desktop 预装 Grok Bot 桌面版 (官方 linux .deb)
# 来源: 发布 feed https://api2.cursor.sh/updates/api/download/stable/linux-x64/sand (arm64: linux-arm64)
#       → debUrl (downloads.cursor.com); 校验见 tools/grok-bot-release.sh。
#
# 由 provision.env 控制 (build-iso.sh: Desktop 默认装; --no-grok-bot / --skip 39 关掉):
#   PIN_GROK_BOT      版本, 默认 latest (feed 当前版本); X.Y.Z 钉扎
#   GROK_BOT_DEB_URL  完全钉扎: deb URL (须同时给 GROK_BOT_SHA256)
#   GROK_BOT_SHA256   期望 sha256
# 只装应用: 不登录、不写账号/配置、不设开机自启; 装完由用户自己打开 Grok Bot 登录。
# 任何失败都只记 "SKIP: ..." 并 exit 0 (不算装机失败), 原因写到 /var/log/autoinstall/grok-bot.skip。
#
# apt 源: 官方 postinst 会写 /etc/apt/sources.list.d/grok-bot.sources (+ /usr/share/keyrings/grok-bot.gpg),
# 之后 grok-bot 随 apt upgrade 更新; 这里保留它。离线装机时先把它挪进 enable-offline-apt.sh 的
# sources.list.d.offline-bak/, 装机后续的 apt-get update 不会去连 downloads.cursor.com;
# restore-online-apt.sh 装完会把它和其它源一起挪回。它只指向 downloads.cursor.com, 清华源改写 (只动 Ubuntu 源) 不碰它。
#
# 测试钩子: AIB_TARGET_ROOT=<dir> 文件操作写到该前缀下; AIB_SKIP_PKG=1 跳过 apt / 下载。
set -uo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
export DEBIAN_FRONTEND=noninteractive

R="${AIB_TARGET_ROOT:-}"
SKIP_PKG="${AIB_SKIP_PKG:-0}"
PIN_GROK_BOT="${PIN_GROK_BOT:-latest}"
GROK_BOT_DEB_URL="${GROK_BOT_DEB_URL:-}"
GROK_BOT_SHA256="${GROK_BOT_SHA256:-}"
ARCH="${GROK_BOT_ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}"
LOGDIR="$R/var/log/autoinstall"
SKIP_FILE="$LOGDIR/grok-bot.skip"
APP_DIR="/opt/Grok Bot"
SOURCES="/etc/apt/sources.list.d/grok-bot.sources"
OFFLINE_BAK="/etc/apt/sources.list.d.offline-bak"

skip() { # 原因 → 日志 + grok-bot.skip, exit 0
  echo "SKIP: Grok Bot 未安装: $*"
  mkdir -p "$LOGDIR" 2>/dev/null && printf '%s\n' "$*" > "$SKIP_FILE" 2>/dev/null
  exit 0
}

if [ "${EDITION:-}" != "desktop" ]; then
  echo "skip: Grok Bot 仅在 Desktop 预装 (EDITION=${EDITION:-unset})"
  exit 0
fi
case "$ARCH" in
  amd64|arm64) ;;
  *) echo "skip: Grok Bot 官方 linux deb 仅支持 amd64 / arm64 (当前 $ARCH)"; exit 0 ;;
esac
rm -f "$SKIP_FILE" 2>/dev/null || true

# shellcheck disable=SC1091
if [ -f "$HERE/grok-bot-release.sh" ]; then
  . "$HERE/grok-bot-release.sh"
elif [ -f "$HERE/../tools/grok-bot-release.sh" ]; then
  . "$HERE/../tools/grok-bot-release.sh"
else
  skip "找不到 grok-bot-release.sh"
fi

grokbot_installed() {
  dpkg-query -W -f='${Status}' grok-bot 2>/dev/null | grep -q 'install ok installed'
}

install_offline() {
  local dir name deb sha ver
  dir="$(offline_root)/grok-bot"
  [ -d "$dir" ] || { echo "离线捆绑缺少 grok-bot/ (旧捆绑或抓包时 --no-grok-bot; 用 --force-fetch 重建)"; return 1; }
  name="$(tr -d '[:space:]' < "$dir/deb.name" 2>/dev/null || true)"
  sha="$(tr -d '[:space:]' < "$dir/sha256" 2>/dev/null || true)"
  ver="$(tr -d '[:space:]' < "$dir/version" 2>/dev/null || true)"
  deb="$dir/$name"
  if [ -z "$name" ] || [ ! -f "$deb" ]; then
    echo "离线捆绑 grok-bot/ 内无 deb"; ls -la "$dir" || true; return 1
  fi
  echo "offline: 安装 Grok Bot ${ver:-?} 自 $deb"
  grokbot_verify_deb "$deb" "$sha" "$ver" "$ARCH" || return 1
  if grokbot_installed && [ "$(dpkg-query -W -f='${Version}' grok-bot 2>/dev/null)" = "$ver" ]; then
    echo "Grok Bot $ver 已安装, 跳过"
    return 0
  fi
  # 依赖由本地 file: 源 (离线捆绑 apt/) 提供
  apt-get install -y --no-install-recommends "$deb"
}

install_online() {
  local tmp rc
  grokbot_resolve "$PIN_GROK_BOT" "$ARCH" "$GROK_BOT_DEB_URL" "$GROK_BOT_SHA256" || return 1
  echo "Grok Bot ${GROK_BOT_VERSION:-?}: $GROK_BOT_DEB_URL (sha256 来源: $GROK_BOT_SHA_SOURCE)"
  if [ -n "$GROK_BOT_VERSION" ] && grokbot_installed \
     && [ "$(dpkg-query -W -f='${Version}' grok-bot 2>/dev/null)" = "$GROK_BOT_VERSION" ]; then
    echo "Grok Bot $GROK_BOT_VERSION 已安装, 跳过下载"
    return 0
  fi
  tmp="$(mktemp -d)"
  rc=0
  if grokbot_download_to "$tmp" "$ARCH"; then
    # apt 解析依赖 (GTK / NSS 等, Desktop 基本都已装); update 失败不致命
    apt-get update || echo "warn: apt-get update 失败, 用现有索引继续"
    apt-get install -y --no-install-recommends "$GROK_BOT_DEB_PATH" || rc=1
  else
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# ---------------------------------------------------------------- 安装
if [ "$SKIP_PKG" != "1" ]; then
  if offline_enabled 2>/dev/null; then
    install_offline || skip "离线安装失败 (见上方日志)"
  else
    install_online || skip "在线下载或安装失败 (downloads.cursor.com 在国内可能很慢或被拦截, 可改用离线捆绑; 见上方日志)"
  fi
  grokbot_installed || skip "dpkg 显示 grok-bot 未安装"
fi

# ---------------------------------------------------------------- AppArmor
# Ubuntu 24.04 默认 kernel.apparmor_restrict_unprivileged_userns=1, Electron 沙箱要靠包里的 AppArmor
# profile (userns)。官方 postinst 只在 apparmor_status --enabled 时复制; chroot 里可能判断不到, 这里兜底
# 复制到 /etc/apparmor.d (开机由 apparmor.service 加载), 先用 apparmor_parser 做语法检查。
prof_src="$R$APP_DIR/resources/apparmor-profile"
prof_dst="$R/etc/apparmor.d/grok-bot"
if [ -f "$prof_src" ] && [ ! -f "$prof_dst" ] && [ -d "$R/etc/apparmor.d" ]; then
  if [ -z "$R" ] && ! command -v apparmor_parser >/dev/null 2>&1; then
    echo "AppArmor: 没有 apparmor_parser, 不安装 profile"
  elif [ -n "$R" ] || apparmor_parser --skip-kernel-load --debug "$prof_src" >/dev/null 2>&1; then
    cp -f "$prof_src" "$prof_dst"
    echo "AppArmor: 已安装 /etc/apparmor.d/grok-bot (开机加载)"
  else
    echo "AppArmor: apparmor_parser 不接受包里的 profile, 未安装 (24.04 上 Grok Bot 可能启动不了沙箱)"
  fi
fi

# ---------------------------------------------------------------- apt 源
if [ -f "$R$SOURCES" ]; then
  if offline_enabled 2>/dev/null && [ -d "$R$OFFLINE_BAK" ]; then
    mv -f "$R$SOURCES" "$R$OFFLINE_BAK/"
    echo "apt 源 grok-bot.sources: 离线装机期间挪到 $OFFLINE_BAK/ (restore-online-apt 装完挪回, 之后 apt 可更新 Grok Bot)"
  else
    echo "apt 源 grok-bot.sources 已登记 (downloads.cursor.com/aptrepo, Grok Bot 随 apt upgrade 更新)"
  fi
elif [ "$SKIP_PKG" != "1" ]; then
  echo "warn: postinst 没写 $SOURCES (Grok Bot 不会随 apt 更新)"
fi

if [ "$SKIP_PKG" != "1" ]; then
  [ -e /usr/bin/grok-bot ] || ln -sf "$APP_DIR/grok-bot" /usr/bin/grok-bot
  [ -f /usr/share/applications/grok-bot.desktop ] || echo "warn: 找不到 grok-bot.desktop"
  echo "Grok Bot $(dpkg-query -W -f='${Version}' grok-bot 2>/dev/null || echo '?') ok (只预装应用, 用户装完自行登录)"
fi
