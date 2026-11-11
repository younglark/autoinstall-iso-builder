#!/bin/bash
# 36-x11vnc-xorg.sh — Desktop 默认: 关闭 Wayland (GDM/锁屏/会话全走 Xorg) + 预装 x11vnc 开机即可连
#
# 由 provision.env 控制 (build-iso.sh: Desktop 默认写 DISABLE_WAYLAND=1 X11VNC=1;
# --wayland / Server 写两者为 0; 密码来自 --vnc-password / --password):
#   DISABLE_WAYLAND=1  /etc/gdm3/custom.conf [daemon] WaylandEnable=false (幂等, 保留其它键)
#   X11VNC=1           (隐含 DISABLE_WAYLAND=1) 安装 x11vnc + systemd 服务 x11vnc.service:
#                      开机后在 GDM 登录界面就能连, 登录后自动跟到用户会话, 锁屏也能连。
#                      另: logind 合盖不挂起, GDM 登录界面/用户会话空闲不自动挂起 (锁屏保留)。
# 两者都为 0 时什么都不做。仅 Desktop; Server 直接跳过。
#
# 测试钩子: AIB_TARGET_ROOT=<dir> 把所有文件写到该前缀下; AIB_SKIP_PKG=1 跳过 apt/systemctl/x11vnc。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
export DEBIAN_FRONTEND=noninteractive

R="${AIB_TARGET_ROOT:-}"
SKIP_PKG="${AIB_SKIP_PKG:-0}"
DISABLE_WAYLAND="${DISABLE_WAYLAND:-0}"
X11VNC="${X11VNC:-0}"
VNC_PORT=5900
SECRET_FILE="$HERE/x11vnc.secret"
RANDOM_PW_FILE="/root/x11vnc-password"

if [ "$DISABLE_WAYLAND" != "1" ] && [ "$X11VNC" != "1" ]; then
  rm -f "$SECRET_FILE"
  echo "skip: 保留 Wayland, 不装 x11vnc (--wayland 或 Server)"
  exit 0
fi
if [ "${EDITION:-}" != "desktop" ]; then
  rm -f "$SECRET_FILE"
  echo "skip: 关闭 Wayland / x11vnc 仅用于 Desktop (EDITION=${EDITION:-unset})"
  exit 0
fi
if [ "$X11VNC" = "1" ] && [ "$DISABLE_WAYLAND" != "1" ]; then
  echo "x11vnc 只能接管 Xorg 显示: 自动关闭 Wayland"
  DISABLE_WAYLAND=1
fi

# ---------------------------------------------------------------- GDM: 关 Wayland
# 幂等地把 key=value 写进 ini 文件的 [section] (替换已有/注释掉的同名键, 保留其它内容)
ini_set() {
  local file="$1" section="$2" key="$3" value="$4" tmp
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || : > "$file"
  tmp="$(mktemp)"
  awk -v sec="[$section]" -v key="$key" -v val="$value" '
    function emit() { if (!done) { print key "=" val; done=1 } }
    {
      line=$0
      if (line ~ /^[[:space:]]*\[/) {
        if (insec) emit()
        insec = (line ~ "^[[:space:]]*\\[" substr(sec, 2, length(sec) - 2) "\\][[:space:]]*$")
        if (insec) seen=1
        print line; next
      }
      if (insec && line ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=") {
        if (!done) { print key "=" val; done=1 }
        next
      }
      print line
    }
    END {
      if (insec) emit()
      if (!seen) { print ""; print sec; print key "=" val }
    }' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

GDM_CONF="$R/etc/gdm3/custom.conf"
ini_set "$GDM_CONF" daemon WaylandEnable false
echo "wrote $GDM_CONF: [daemon] WaylandEnable=false (登录界面/锁屏/会话均为 Xorg)"

if [ "$X11VNC" != "1" ]; then
  rm -f "$SECRET_FILE"
  echo "x11vnc 未启用; 只关闭了 Wayland"
  exit 0
fi

# ---------------------------------------------------------------- x11vnc 安装
if [ "$SKIP_PKG" != "1" ]; then
  if offline_enabled 2>/dev/null && offline_apt_ready 2>/dev/null; then
    echo "offline: 从本地 apt 安装 x11vnc"
    offline_apt_install x11vnc xauth
  else
    apt-get update
    apt-get install -y --no-install-recommends x11vnc xauth
  fi
  command -v x11vnc >/dev/null || { echo "ERROR: x11vnc 安装后找不到可执行文件"; exit 1; }
fi

# ---------------------------------------------------------------- VNC 密码
# 明文只在 0600 secret 文件里 (build-iso 写入), 用后即删; 不打印。VNC 协议只用前 8 个字符。
VNC_PASSWORD=""
if [ -f "$SECRET_FILE" ]; then
  # shellcheck disable=SC1090
  . "$SECRET_FILE"
  rm -f "$SECRET_FILE"
fi
if [ -z "$VNC_PASSWORD" ]; then
  VNC_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8 || true)"
  install -d -m 0700 "$R/root"
  ( umask 077; printf '%s\n' "$VNC_PASSWORD" > "$R$RANDOM_PW_FILE" )
  chmod 0600 "$R$RANDOM_PW_FILE"
  echo "无明文 VNC 密码 (只给了 --password-hash): 已生成随机密码 → $RANDOM_PW_FILE"
fi
install -d -m 0755 "$R/etc"
if [ "$SKIP_PKG" != "1" ]; then
  ( umask 077; x11vnc -storepasswd "$VNC_PASSWORD" "$R/etc/x11vnc.pass" >/dev/null 2>&1 ) \
    || { echo "ERROR: x11vnc -storepasswd 失败"; exit 1; }
else
  ( umask 077; printf 'test-only\n' > "$R/etc/x11vnc.pass" )
fi
chown root:root "$R/etc/x11vnc.pass" 2>/dev/null || true
chmod 0600 "$R/etc/x11vnc.pass"
unset VNC_PASSWORD
echo "wrote /etc/x11vnc.pass (root 0600)"

# ---------------------------------------------------------------- 跟随显示的启动器
# GDM (Xorg) 登录界面跑在 vt1 (:0, auth=/run/user/<gdm>/gdm/Xauthority);
# 用户登录后另起一个 Xorg (vt2, :1, auth=/run/user/<uid>/gdm/Xauthority), GNOME 锁屏也在这个 X 里。
# 所以不能把 x11vnc 钉死在 :0: 这里每 2 秒看一次当前活动 VT 上的 Xorg, 取它的 -auth 文件和
# 显示号 (xauth list), 变了就重启 x11vnc。x11vnc 自己的 -loop 会用旧 display/auth 重连, 不用它。
install -d -m 0755 "$R/usr/local/sbin"
cat > "$R/usr/local/sbin/aib-x11vnc-follow" <<'FOLLOW'
#!/bin/bash
# aib-x11vnc-follow — 让 x11vnc 跟随当前活动的 Xorg 显示 (GDM 登录界面 → 用户会话 → 注销回登录界面)
# 由 x11vnc.service 启动; 由 autoinstall-iso-builder software/36-x11vnc-xorg.sh 生成。
set -u
PORT="${X11VNC_PORT:-5900}"
PASSFILE="${X11VNC_PASSFILE:-/etc/x11vnc.pass}"
LOG="${X11VNC_LOG:-/var/log/x11vnc.log}"
INTERVAL="${X11VNC_POLL:-2}"

[ -s "$PASSFILE" ] || { echo "缺少 $PASSFILE (x11vnc -storepasswd 生成)"; exit 1; }

# 防火墙: 只在 ufw 已启用时放行, 不会主动启用 ufw
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw status 2>/dev/null | grep -q "^${PORT}/tcp" || ufw allow "${PORT}/tcp" comment x11vnc >/dev/null 2>&1 || true
fi

# 输出 "<display> <authfile>"; 优先活动 VT 上的 Xorg, 没有则任取一个
find_target() {
  local active pid vt auth disp first="" pick="" arg prev
  active="$(cat /sys/class/tty/tty0/active 2>/dev/null)"   # 例: tty2
  active="${active#tty}"
  for pid in $(pgrep -x Xorg 2>/dev/null; pgrep -x X 2>/dev/null); do
    vt=""; auth=""; prev=""
    while IFS= read -r -d '' arg; do
      case "$arg" in vt[0-9]*) vt="${arg#vt}" ;; esac
      [ "$prev" = "-auth" ] && auth="$arg"
      prev="$arg"
    done < "/proc/$pid/cmdline" 2>/dev/null
    if [ -z "$auth" ] || [ ! -r "$auth" ]; then continue; fi
    disp="$(xauth -f "$auth" list 2>/dev/null | sed -n 's/^[^ ]*:\([0-9][0-9]*\) .*/:\1/p' | head -1)"
    [ -n "$disp" ] || continue
    [ -n "$first" ] || first="$disp $auth"
    if [ -n "$active" ] && [ "$vt" = "$active" ]; then pick="$disp $auth"; break; fi
  done
  [ -n "$pick" ] || pick="$first"
  [ -n "$pick" ] && printf '%s\n' "$pick"
}

child=""
current=""
stop_child() {
  if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
    kill "$child" 2>/dev/null
    for _ in 1 2 3 4 5; do kill -0 "$child" 2>/dev/null || break; sleep 1; done
    kill -9 "$child" 2>/dev/null
    wait "$child" 2>/dev/null
  fi
  child=""
}
trap 'stop_child; exit 0' TERM INT

while :; do
  target="$(find_target)"
  if [ -z "$target" ]; then
    # GDM 还没起来 / 正在切换: 等
    [ -n "$child" ] && ! kill -0 "$child" 2>/dev/null && child=""
    sleep "$INTERVAL"; continue
  fi
  if [ "$target" != "$current" ] || [ -z "$child" ] || ! kill -0 "$child" 2>/dev/null; then
    stop_child
    current="$target"
    disp="${target%% *}"
    auth="${target#* }"
    echo "$(date '+%F %T') x11vnc -> display $disp (auth $auth)"
    x11vnc -display "$disp" -auth "$auth" -rfbauth "$PASSFILE" -rfbport "$PORT" \
      -forever -shared -noxdamage -repeat -xkb -nowf -o "$LOG" -q &
    child=$!
  fi
  sleep "$INTERVAL"
done
FOLLOW
chmod 0755 "$R/usr/local/sbin/aib-x11vnc-follow"

install -d -m 0755 "$R/etc/systemd/system"
cat > "$R/etc/systemd/system/x11vnc.service" <<UNIT
[Unit]
Description=x11vnc VNC server following the active GDM Xorg display (greeter / lock screen / session)
After=display-manager.service network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=X11VNC_PORT=${VNC_PORT}
ExecStart=/usr/local/sbin/aib-x11vnc-follow
Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
UNIT
echo "wrote /etc/systemd/system/x11vnc.service"

# ---------------------------------------------------------------- 不挂起 (开机即可用)
install -d -m 0755 "$R/etc/systemd/logind.conf.d"
cat > "$R/etc/systemd/logind.conf.d/90-autoinstall-x11vnc.conf" <<'LOGIND'
# autoinstall-iso-builder x11vnc (Desktop 默认): 合盖 / 空闲不挂起, 保证随时能 VNC 连上 (锁屏照常)
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
LOGIND

# GDM 登录界面 (gdm 用户) 的 dconf: system-db:gdm 优先于 greeter 默认值
install -d -m 0755 "$R/etc/dconf/db/gdm.d" "$R/etc/dconf/profile"
if [ ! -f "$R/etc/dconf/profile/gdm" ]; then
  printf 'user-db:user\nsystem-db:gdm\nfile-db:/usr/share/gdm/greeter-dconf-defaults\n' > "$R/etc/dconf/profile/gdm"
elif ! grep -q '^system-db:gdm' "$R/etc/dconf/profile/gdm"; then
  sed -i '1a system-db:gdm' "$R/etc/dconf/profile/gdm"
fi
cat > "$R/etc/dconf/db/gdm.d/90-autoinstall-no-suspend" <<'GDMDB'
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0
GDMDB
# 普通用户默认值: gschema override (不锁定, 用户仍可在设置里改); 锁屏不动
install -d -m 0755 "$R/usr/share/glib-2.0/schemas"
cat > "$R/usr/share/glib-2.0/schemas/90_autoinstall-x11vnc-no-suspend.gschema.override" <<'GS'
[org.gnome.settings-daemon.plugins.power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0
GS

if [ "$SKIP_PKG" != "1" ]; then
  if ! { command -v dconf >/dev/null 2>&1 && dconf update; }; then
    echo "warn: dconf update 失败/不存在 (登录界面空闲挂起可能未关)"
  fi
  if command -v glib-compile-schemas >/dev/null 2>&1; then
    glib-compile-schemas /usr/share/glib-2.0/schemas || true
  fi
  # ufw 已启用才放行 (chroot 内 ufw 可能无法 reload; 启动器开机时还会再检查一次)
  if [ -f /etc/ufw/ufw.conf ] && grep -q '^ENABLED=yes' /etc/ufw/ufw.conf && command -v ufw >/dev/null 2>&1; then
    ufw allow "${VNC_PORT}/tcp" comment x11vnc || echo "warn: ufw allow 失败, 开机后由 x11vnc.service 再试"
  fi
  systemctl enable x11vnc.service
fi

echo "x11vnc ok: 端口 ${VNC_PORT}/tcp, 开机即可从 GDM 登录界面连接 (Wayland 已关闭)"
