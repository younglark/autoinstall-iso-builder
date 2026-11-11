#!/bin/bash
# 38-rustdesk.sh — Desktop 默认远程桌面: RustDesk (局域网 IP 直连 21118/tcp + 固定密码)
# 官方: https://github.com/rustdesk/rustdesk/releases (官方 linux .deb, 版本钉扎 + sha256 校验)
#
# 由 provision.env 控制 (build-iso.sh: Desktop 默认 REMOTE_DESKTOP=rustdesk; --remote-desktop x11vnc|none 关掉):
#   REMOTE_DESKTOP=rustdesk  安装 RustDesk 并启用 rustdesk.service; 首次开机由 aib-rustdesk-setup.service
#                            (oneshot) 通过 RustDesk 自己的 CLI 设置:
#                              direct-server=Y                 局域网 IP 直连 (端口 21118)
#                              verification-method=use-permanent-password  只用固定密码
#                              approve-mode=password           不弹「接受连接」确认框
#                              custom-rendezvous-server / relay-server     仅 --rustdesk-server 时
#                            固定密码 = --rustdesk-password, 默认 = --password 明文; 只给了 --password-hash 时
#                            随机生成写入 /root/rustdesk-password (root 0600)。
#   PIN_RUSTDESK             版本, 默认见 tools/rustdesk-release.sh (RUSTDESK_DEFAULT_VERSION)
#   RUSTDESK_SERVER          自建 hbbs/hbbr 主机 (可空)
# RustDesk 1.5 的固定密码是加盐哈希存储, 只能通过运行中的服务 (IPC) 设置, chroot 里做不到, 所以放到首次开机。
# 明文只在 /etc/aib/rustdesk.secret (root 0600), 设置成功后删除; 不进 provision.env / 日志。
# Wayland 由 36-x11vnc-xorg.sh 关闭 (RustDesk 在 Wayland 下连不上登录界面)。
#
# 测试钩子: AIB_TARGET_ROOT=<dir> 把所有文件写到该前缀下; AIB_SKIP_PKG=1 跳过 apt/systemctl。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
# shellcheck disable=SC1091
if [ -f "$HERE/rustdesk-release.sh" ]; then
  . "$HERE/rustdesk-release.sh"
elif [ -f "$HERE/../tools/rustdesk-release.sh" ]; then
  . "$HERE/../tools/rustdesk-release.sh"
else
  echo "ERROR: 找不到 rustdesk-release.sh"
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive

R="${AIB_TARGET_ROOT:-}"
SKIP_PKG="${AIB_SKIP_PKG:-0}"
REMOTE_DESKTOP="${REMOTE_DESKTOP:-none}"
PIN_RUSTDESK="${PIN_RUSTDESK:-$RUSTDESK_DEFAULT_VERSION}"
RUSTDESK_SERVER="${RUSTDESK_SERVER:-}"
RUSTDESK_PORT=21118
SECRET_FILE="$HERE/rustdesk.secret"
RANDOM_PW_FILE="/root/rustdesk-password"
ARCH="${RUSTDESK_ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}"

if [ "$REMOTE_DESKTOP" != "rustdesk" ]; then
  rm -f "$SECRET_FILE"
  echo "skip: 远程桌面不是 RustDesk (REMOTE_DESKTOP=$REMOTE_DESKTOP)"
  exit 0
fi
if [ "${EDITION:-}" != "desktop" ]; then
  rm -f "$SECRET_FILE"
  echo "skip: RustDesk 仅在 Desktop 预装 (EDITION=${EDITION:-unset})"
  exit 0
fi
if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
  rm -f "$SECRET_FILE"
  echo "skip: RustDesk 官方 linux deb 仅支持 amd64 / arm64 (当前 $ARCH)"
  exit 0
fi
if [ -n "$RUSTDESK_SERVER" ] && [[ ! "$RUSTDESK_SERVER" =~ ^[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]]; then
  echo "ERROR: RUSTDESK_SERVER 非法: $RUSTDESK_SERVER"
  exit 1
fi

# ---------------------------------------------------------------- 安装
rustdesk_installed() {
  dpkg-query -W -f='${Status}' rustdesk 2>/dev/null | grep -q 'install ok installed'
}

install_offline() {
  local dir name deb sha
  dir="$(offline_root)/rustdesk"
  [ -d "$dir" ] || { echo "ERROR: 离线捆绑缺少 rustdesk/ — 请用 --force 重建: ./tools/fetch-offline-bundle.sh --force ..."; return 1; }
  name="$(tr -d '[:space:]' < "$dir/deb.name" 2>/dev/null || true)"
  sha="$(tr -d '[:space:]' < "$dir/sha256" 2>/dev/null || true)"
  deb="$dir/$name"
  if [ -z "$name" ] || [ ! -f "$deb" ]; then
    echo "ERROR: 离线捆绑 rustdesk/ 内无 deb"; ls -la "$dir" || true; return 1
  fi
  echo "offline: 安装 RustDesk $(cat "$dir/version" 2>/dev/null || echo '?') 自 $deb"
  rustdesk_verify_deb "$deb" "$sha"
  apt-get install -y --no-install-recommends "$deb"
}

install_online() {
  local tmp
  rustdesk_resolve "$PIN_RUSTDESK" "$ARCH"
  if rustdesk_installed && [ "$(dpkg-query -W -f='${Version}' rustdesk 2>/dev/null)" = "$RUSTDESK_VERSION" ]; then
    echo "RustDesk $RUSTDESK_VERSION 已安装, 跳过下载"
    return 0
  fi
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  rustdesk_download_to "$tmp"
  apt-get update || true
  apt-get install -y --no-install-recommends "$RUSTDESK_DEB_PATH"
}

if [ "$SKIP_PKG" != "1" ]; then
  if offline_enabled 2>/dev/null; then
    install_offline
  else
    install_online
  fi
  rustdesk_installed || { echo "ERROR: rustdesk 包未安装"; exit 1; }
  [ -x /usr/bin/rustdesk ] || ln -sf /usr/share/rustdesk/rustdesk /usr/bin/rustdesk
  # 官方 postinst 只在 /proc/1/exe 是 systemd 时才放 unit; chroot 里可能没放, 这里兜底
  if [ ! -f /usr/lib/systemd/system/rustdesk.service ] && [ -f /usr/share/rustdesk/files/systemd/rustdesk.service ]; then
    install -D -m 0644 /usr/share/rustdesk/files/systemd/rustdesk.service /usr/lib/systemd/system/rustdesk.service
    sed -i 's|^ExecStop=pkill|ExecStop=/usr/bin/pkill|' /usr/lib/systemd/system/rustdesk.service
  fi
fi

# ---------------------------------------------------------------- 固定密码 (首次开机用)
RUSTDESK_PASSWORD=""
if [ -f "$SECRET_FILE" ]; then
  # shellcheck disable=SC1090
  . "$SECRET_FILE"
  rm -f "$SECRET_FILE"
fi
if [ -z "$RUSTDESK_PASSWORD" ]; then
  RUSTDESK_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12 || true)"
  install -d -m 0700 "$R/root"
  ( umask 077; printf '%s\n' "$RUSTDESK_PASSWORD" > "$R$RANDOM_PW_FILE" )
  chmod 0600 "$R$RANDOM_PW_FILE"
  echo "无明文 RustDesk 密码 (只给了 --password-hash): 已生成随机密码 → $RANDOM_PW_FILE"
fi
install -d -m 0755 "$R/etc/aib"
( umask 077; printf 'RUSTDESK_PASSWORD=%q\n' "$RUSTDESK_PASSWORD" > "$R/etc/aib/rustdesk.secret" )
chown root:root "$R/etc/aib/rustdesk.secret" 2>/dev/null || true
chmod 0600 "$R/etc/aib/rustdesk.secret"
unset RUSTDESK_PASSWORD
echo "wrote /etc/aib/rustdesk.secret (root 0600; 首次开机设好固定密码后删除)"

# ---------------------------------------------------------------- 选项
# 「键 值」每行一条 (值不含空白); aib-rustdesk-setup 逐条 rustdesk --option 并回读确认
{
  echo "# 由 autoinstall-iso-builder software/38-rustdesk.sh 生成; aib-rustdesk-setup.service 首次开机应用"
  echo "direct-server Y"
  echo "verification-method use-permanent-password"
  echo "approve-mode password"
  if [ -n "$RUSTDESK_SERVER" ]; then
    echo "custom-rendezvous-server $RUSTDESK_SERVER"
    echo "relay-server $RUSTDESK_SERVER"
  fi
} > "$R/etc/aib/rustdesk.options"
chmod 0644 "$R/etc/aib/rustdesk.options"

# 预置服务端配置 (root 运行的 rustdesk --service 读 /root/.config/rustdesk/RustDesk2.toml):
# 首次开机 IPC 设置之前 direct-server 等就已生效; 已有配置不覆盖
install -d -m 0700 "$R/root/.config" "$R/root/.config/rustdesk"
if [ ! -f "$R/root/.config/rustdesk/RustDesk2.toml" ]; then
  {
    echo "[options]"
    while read -r k v; do
      case "$k" in ''|\#*) continue ;; esac
      printf "%s = '%s'\n" "$k" "$v"
    done < "$R/etc/aib/rustdesk.options"
  } > "$R/root/.config/rustdesk/RustDesk2.toml"
  chmod 0600 "$R/root/.config/rustdesk/RustDesk2.toml"
  echo "wrote /root/.config/rustdesk/RustDesk2.toml [options]"
fi

install -d -m 0755 "$R/usr/local/sbin"
cat > "$R/usr/local/sbin/aib-rustdesk-setup" <<'SETUP'
#!/bin/bash
# aib-rustdesk-setup — 首次开机: 通过运行中的 RustDesk 服务设置固定密码与选项 (成功后不再运行)
# 由 aib-rustdesk-setup.service 启动; 由 autoinstall-iso-builder software/38-rustdesk.sh 生成。
set -u
SECRET="${AIB_RUSTDESK_SECRET:-/etc/aib/rustdesk.secret}"
OPTIONS="${AIB_RUSTDESK_OPTIONS:-/etc/aib/rustdesk.options}"
STAMP="${AIB_RUSTDESK_STAMP:-/var/lib/aib/rustdesk-setup.done}"
PORT="${RUSTDESK_PORT:-21118}"
RD="${RUSTDESK_BIN:-rustdesk}"
log() { echo "aib-rustdesk-setup: $*"; }

command -v "$RD" >/dev/null 2>&1 || { log "找不到 rustdesk"; exit 1; }

# 防火墙: 只在 ufw 已启用时放行直连端口, 不会主动启用 ufw
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw status 2>/dev/null | grep -q "^${PORT}/tcp" || ufw allow "${PORT}/tcp" comment rustdesk >/dev/null 2>&1 || true
fi

# 等服务的 IPC 起来 (rustdesk --option 读回非空的 verification-method / 或能拿到 ID)
id=""
for _ in $(seq 1 40); do
  id="$(timeout 15 "$RD" --get-id 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
  [ -n "$id" ] && break
  sleep 3
done
[ -n "$id" ] || { log "RustDesk 服务没有响应 (systemctl status rustdesk); 稍后重试"; exit 1; }

fail=0
if [ -f "$OPTIONS" ]; then
  while read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    got=""
    for _ in 1 2 3; do
      timeout 15 "$RD" --option "$k" "$v" >/dev/null 2>&1 || true
      sleep 1
      got="$(timeout 15 "$RD" --option "$k" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
      [ "$got" = "$v" ] && break
    done
    if [ "$got" = "$v" ]; then log "option $k=$v"; else log "option $k 未生效 (读回 '$got')"; fail=1; fi
  done < "$OPTIONS"
fi

if [ -f "$SECRET" ]; then
  RUSTDESK_PASSWORD=""
  # shellcheck disable=SC1090
  . "$SECRET"
  if [ -z "$RUSTDESK_PASSWORD" ]; then
    log "$SECRET 里没有密码"; fail=1
  else
    out="$(timeout 30 "$RD" --password "$RUSTDESK_PASSWORD" 2>&1)"
    if printf '%s\n' "$out" | grep -q 'Done!'; then
      rm -f "$SECRET"
      log "固定密码已设置 (明文已删除)"
    else
      log "设置固定密码失败: $(printf '%s\n' "$out" | tail -n 1)"; fail=1
    fi
  fi
  unset RUSTDESK_PASSWORD
fi

[ "$fail" -eq 0 ] || exit 1
mkdir -p "$(dirname "$STAMP")"
date '+%F %T' > "$STAMP"
log "完成: 局域网 IP 直连端口 ${PORT}/tcp, RustDesk ID $id"
SETUP
chmod 0755 "$R/usr/local/sbin/aib-rustdesk-setup"

install -d -m 0755 "$R/etc/systemd/system"
cat > "$R/etc/systemd/system/aib-rustdesk-setup.service" <<UNIT
[Unit]
Description=Apply autoinstall RustDesk settings (permanent password, direct IP access ${RUSTDESK_PORT}/tcp)
After=rustdesk.service network-online.target
Wants=rustdesk.service
ConditionPathExists=!/var/lib/aib/rustdesk-setup.done
StartLimitIntervalSec=1800
StartLimitBurst=20

[Service]
Type=oneshot
Environment=RUSTDESK_PORT=${RUSTDESK_PORT}
ExecStart=/usr/local/sbin/aib-rustdesk-setup
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT
echo "wrote /etc/systemd/system/aib-rustdesk-setup.service"

if [ "$SKIP_PKG" != "1" ]; then
  if [ -f /etc/ufw/ufw.conf ] && grep -q '^ENABLED=yes' /etc/ufw/ufw.conf && command -v ufw >/dev/null 2>&1; then
    ufw allow "${RUSTDESK_PORT}/tcp" comment rustdesk || echo "warn: ufw allow 失败, 开机后由 aib-rustdesk-setup 再试"
  fi
  systemctl enable rustdesk.service
  systemctl enable aib-rustdesk-setup.service
  echo "RustDesk $(dpkg-query -W -f='${Version}' rustdesk 2>/dev/null || echo '?') ok"
fi

echo "rustdesk ok: 局域网 IP 直连 ${RUSTDESK_PORT}/tcp, 固定密码 (首次开机设置)${RUSTDESK_SERVER:+, 自建服务器 $RUSTDESK_SERVER}"
