#!/bin/bash
# 38-rustdesk.sh — Desktop 默认远程桌面: RustDesk (局域网 IP 直连 21118/tcp + 固定密码)
# 官方: https://github.com/rustdesk/rustdesk/releases (官方 linux .deb, 版本钉扎 + sha256 校验)
#
# 由 provision.env 控制 (build-iso.sh: Desktop 默认 REMOTE_DESKTOP=rustdesk; --remote-desktop x11vnc|none 关掉):
#   REMOTE_DESKTOP=rustdesk  安装 RustDesk 并启用 rustdesk.service。选项装机时直接写进 root / 登录用户 /
#                            gdm 各自的 ~/.config/rustdesk/RustDesk2.toml [options] (aib-rustdesk-preseed),
#                            RustDesk 第一次启动就按这些选项运行:
#                              direct-server=Y                 局域网 IP 直连 (端口 21118)
#                              verification-method=use-permanent-password  只用固定密码
#                              approve-mode=password           不弹「接受连接」确认框
#                              direct-access-port=21118
#                              custom-rendezvous-server / relay-server     --rustdesk-server 时指向自建服务器;
#                                默认 (只允许局域网 IP 直连) 与 api-server 一起指向 127.0.0.1: 不连 RustDesk
#                                公共 ID / 中继服务器, 外网无法按 ID 连入; --rustdesk-allow-id 时三项都不设
#                            固定密码只能经运行中的 RustDesk 设置: 首次开机由 aib-rustdesk-setup.service (oneshot)
#                            等 rustdesk --server 进程及其 IPC 就绪后 rustdesk --password, 再读回确认选项。
#                            不记录 RustDesk ID (要看: sudo rustdesk --get-id)
#                            固定密码 = --rustdesk-password, 默认 = --password 明文; secret 未投递时 (防御路径)
#                            随机生成写入 /root/rustdesk-password (root 0600)。
#   PIN_RUSTDESK             版本, 默认见 tools/rustdesk-release.sh (RUSTDESK_DEFAULT_VERSION)
#   RUSTDESK_SERVER          自建 hbbs/hbbr 主机 (可空)
#   RUSTDESK_ALLOW_ID        1 = 保留 RustDesk 公共 ID 服务器 (默认 0: 只允许局域网 IP 直连)
# RustDesk 1.5 的固定密码是加盐哈希存储, 只能通过运行中的服务 (IPC) 设置, chroot 里做不到, 所以放到首次开机。
# 明文只在 /etc/aib/rustdesk.secret (root 0600), 设置成功 (或重试次数用完放弃) 后删除; 不进 provision.env / 日志。
# Wayland 由 36-x11vnc-xorg.sh 关闭 (RustDesk 在 Wayland 下连不上登录界面)。
#
# 测试钩子: AIB_TARGET_ROOT=<dir> 把所有文件写到该前缀下 (账号从 <dir>/etc/passwd 读); AIB_SKIP_PKG=1 跳过 apt/systemctl。
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
RUSTDESK_ALLOW_ID="${RUSTDESK_ALLOW_ID:-0}"
RUSTDESK_PORT=21118
RUSTDESK_LAN_ONLY_HOST=127.0.0.1
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
  echo "无明文 RustDesk 密码 (secret 未投递, 防御路径): 已生成随机密码 → $RANDOM_PW_FILE"
fi
install -d -m 0755 "$R/etc/aib"
( umask 077; printf 'RUSTDESK_PASSWORD=%q\n' "$RUSTDESK_PASSWORD" > "$R/etc/aib/rustdesk.secret" )
chown root:root "$R/etc/aib/rustdesk.secret" 2>/dev/null || true
chmod 0600 "$R/etc/aib/rustdesk.secret"
unset RUSTDESK_PASSWORD
echo "wrote /etc/aib/rustdesk.secret (root 0600; 首次开机设好固定密码后删除)"

# ---------------------------------------------------------------- 选项
# 「键 值」每行一条 (值不含空白和引号); 「!键」= 从 [options] 删掉该键。
# 装机时由 aib-rustdesk-preseed 直接写进各账号的 RustDesk2.toml [options] (首次启动就生效);
# 首次开机 aib-rustdesk-setup 设完密码后再逐条读回确认一次 (兜底)。
{
  echo "# 由 autoinstall-iso-builder software/38-rustdesk.sh 生成"
  echo "direct-server Y"
  echo "direct-access-port $RUSTDESK_PORT"
  echo "verification-method use-permanent-password"
  echo "approve-mode password"
  if [ -n "$RUSTDESK_SERVER" ]; then
    echo "custom-rendezvous-server $RUSTDESK_SERVER"
    echo "relay-server $RUSTDESK_SERVER"
    echo "!api-server"
  elif [ "$RUSTDESK_ALLOW_ID" != "1" ]; then
    # 只留局域网 IP 直连: ID 服务器 / 中继 / API 全指向本机回环 (本机没有 hbbs/hbbr, 连接立即被拒),
    # 设备不会注册到 rs-ny.rustdesk.com, 外网无法按 ID 找到它; 直连监听 (direct-server) 不受影响。
    echo "custom-rendezvous-server $RUSTDESK_LAN_ONLY_HOST"
    echo "relay-server $RUSTDESK_LAN_ONLY_HOST"
    echo "api-server http://$RUSTDESK_LAN_ONLY_HOST"
  else
    # 保留公共 ID 服务器: 三项都不设 (删掉残留), RustDesk 用内置的 rs-ny.rustdesk.com
    echo "!custom-rendezvous-server"
    echo "!relay-server"
    echo "!api-server"
  fi
} > "$R/etc/aib/rustdesk.options"
chmod 0644 "$R/etc/aib/rustdesk.options"

# 要预置配置的账号: root (rustdesk --service) + 登录用户 + GDM 登录界面账号。
# RustDesk 1.5.1 的 rustdesk.service (root) 只开 /tmp/RustDesk-service/ipc_service; 真正监听
# 21118 / 连 rendezvous 的 rustdesk --server 由它用 sudo -u <活动会话用户> 拉起: 登录界面时是 gdm
# (uid 120), 登录后是登录用户 (uid 1000); 只有 root 图形会话或 Wayland 登录界面才是 root。
# --server 用自己的 $HOME/.config/rustdesk, 只有 root 配置已有 ID+密钥对时才从 root 同步
# (src/server.rs wait_initial_config_sync), 首次开机 root 配置是空的 → 必须给每个账号各写一份。
{
  echo "root"
  [ -n "${TARGET_USER:-}" ] && [ "${TARGET_USER}" != "root" ] && echo "$TARGET_USER"
  echo "gdm"
  echo "gdm-greeter"
} > "$R/etc/aib/rustdesk.accounts"
chmod 0644 "$R/etc/aib/rustdesk.accounts"

install -d -m 0755 "$R/usr/local/sbin"
cat > "$R/usr/local/sbin/aib-rustdesk-preseed" <<'PRESEED'
#!/bin/bash
# aib-rustdesk-preseed — 把 /etc/aib/rustdesk.options 合并进各账号的 ~/.config/rustdesk/RustDesk2.toml [options]
# 由 autoinstall-iso-builder software/38-rustdesk.sh 生成; 装机时跑一次, 之后作为 rustdesk.service 的
# ExecStartPre 在首次设置完成前 (--if-not-done) 每次启动前再跑, 补上装机时还不存在的账号。
# RustDesk 1.5.1: Config2 文件 = $HOME/.config/rustdesk/RustDesk2.toml, 选项在 [options] 表里
# (hbb_common config.rs: Config2::file() / ProjectDirs::from("", "", "RustDesk"))。
# 只增改 / 删除列出的键, 文件里其它内容原样保留。
set -u
ROOT="${AIB_TARGET_ROOT:-}"
OPTIONS="${AIB_RUSTDESK_OPTIONS:-$ROOT/etc/aib/rustdesk.options}"
ACCOUNTS="${AIB_RUSTDESK_ACCOUNTS:-$ROOT/etc/aib/rustdesk.accounts}"
STAMP="${AIB_RUSTDESK_STAMP:-$ROOT/var/lib/aib/rustdesk-setup.done}"
PASSWD="${AIB_RUSTDESK_PASSWD:-$ROOT/etc/passwd}"
log() { echo "aib-rustdesk-preseed: $*"; }

if [ "${1:-}" = "--if-not-done" ] && [ -f "$STAMP" ]; then exit 0; fi
[ -f "$OPTIONS" ] || { log "没有 $OPTIONS"; exit 1; }

merge() {  # merge <toml>: 就地合并
  local f="$1" tmp
  tmp="$(mktemp "$f.XXXXXX")" || return 1
  awk '
    FNR == NR {
      if ($0 ~ /^[[:space:]]*(#|$)/) next
      if (substr($1, 1, 1) == "!") { del[substr($1, 2)] = 1; next }
      set[$1] = $2; order[++n] = $1; next
    }
    function emit(   i) { for (i = 1; i <= n; i++) printf "%s = \047%s\047\n", order[i], set[order[i]] }
    { lines++ }
    /^[[:space:]]*\[/ {
      insec = ($0 ~ /^[[:space:]]*\[options\][[:space:]]*$/)
      print
      if (insec) { emit(); done = 1 }
      next
    }
    insec && /=/ {
      k = $0; sub(/[[:space:]]*=.*/, "", k); gsub(/^[[:space:]]+|["\047]/, "", k)
      if ((k in set) || (k in del)) next
    }
    { print }
    END { if (!done) { if (lines > 0) print ""; print "[options]"; emit() } }
  ' "$OPTIONS" "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" && mv -f "$tmp" "$f"
}

rc=0
while read -r acct; do
  case "$acct" in ''|\#*) continue ;; esac
  ent="$(awk -F: -v u="$acct" '$1 == u { print $3 ":" $4 ":" $6; exit }' "$PASSWD" 2>/dev/null)"
  if [ -z "$ent" ]; then
    [ "$acct" = root ] && { log "passwd 里没有 root"; rc=1; }
    continue
  fi
  uid="${ent%%:*}"; rest="${ent#*:}"; gid="${rest%%:*}"; home="${rest#*:}"
  if [ -z "$home" ] || [ ! -d "$ROOT$home" ]; then
    log "跳过 $acct: 家目录 ${home:-?} 不存在 (之后 rustdesk.service 启动前会再试)"
    continue
  fi
  d="$ROOT$home/.config"
  for dir in "$d" "$d/rustdesk"; do
    if [ ! -d "$dir" ]; then
      mkdir -m 0700 "$dir" && chown "$uid:$gid" "$dir" 2>/dev/null
    fi
  done
  f="$d/rustdesk/RustDesk2.toml"
  [ -f "$f" ] || : > "$f"
  if merge "$f"; then
    chown "$uid:$gid" "$f" 2>/dev/null || [ "$(id -u)" != 0 ] || log "warn: chown $f 失败"
    log "已写入 $home/.config/rustdesk/RustDesk2.toml [options] ($acct)"
  else
    log "写 $f 失败 ($acct)"; rc=1
  fi
done < "$ACCOUNTS"
exit "$rc"
PRESEED
chmod 0755 "$R/usr/local/sbin/aib-rustdesk-preseed"
AIB_TARGET_ROOT="$R" "$R/usr/local/sbin/aib-rustdesk-preseed" \
  || { echo "ERROR: 预置 RustDesk2.toml 失败"; exit 1; }

cat > "$R/usr/local/sbin/aib-rustdesk-setup" <<'SETUP'
#!/bin/bash
# aib-rustdesk-setup — 首次开机: 通过运行中的 RustDesk 设置固定密码, 再读回确认选项 (成功后不再运行)
# 由 aib-rustdesk-setup.service 启动; 由 autoinstall-iso-builder software/38-rustdesk.sh 生成。
# 选项 (直连 / 127.0.0.1 rendezvous) 装机时已由 aib-rustdesk-preseed 写进各账号 RustDesk2.toml。
#
# 就绪判定 (RustDesk 1.5.1 源码 src/ipc.rs / src/platform/linux.rs):
#   root 跑 rustdesk --password 时, CLI 不连 /tmp/RustDesk-0/ipc, 而是找正在运行的 `rustdesk --server`
#   进程的 uid, 连 /tmp/RustDesk-<uid>/ipc。--server 由 rustdesk.service 以活动会话用户身份拉起:
#   只有 GDM 登录界面时是 gdm (120), 登录后是登录用户 (1000), Wayland 登录界面 / root 会话才是 0。
#   所以这里等: rustdesk.service active + 有 `rustdesk --server` 进程 + 该 uid 的 IPC socket 已建立,
#   不写死 uid; 然后反复 rustdesk --password 直到输出 Done! (守护进程确认后才打印, 唯一可靠的成功信号)。
#   --option 读取在 IPC 不通时会退回本地 root 配置, 不能当成功证据; --get-id 同理, 所以不调用、不记录 ID。
# 重试有上限: 每次运行最多等 READY_TIMEOUT 秒 + PW_TRIES 次; 每次开机最多 MAX_RUNS 次运行 (systemd 30s 后重试);
#   超过后以退出码 2 结束 (unit 进入 failed, 不再自动重试); 连续 MAX_BOOTS 次开机都失败则彻底放弃:
#   删除明文密码, 写 /var/lib/aib/rustdesk-setup.failed (原因), 以后不再运行。
# 日志里不出现明文密码。
set -u
SECRET="${AIB_RUSTDESK_SECRET:-/etc/aib/rustdesk.secret}"
OPTIONS="${AIB_RUSTDESK_OPTIONS:-/etc/aib/rustdesk.options}"
STAMP="${AIB_RUSTDESK_STAMP:-/var/lib/aib/rustdesk-setup.done}"
FAILED="${AIB_RUSTDESK_FAILED:-/var/lib/aib/rustdesk-setup.failed}"
BOOTS_FILE="${AIB_RUSTDESK_BOOTS_FILE:-/var/lib/aib/rustdesk-setup.boots}"
RUN_DIR="${AIB_RUSTDESK_RUN_DIR:-/run/aib-rustdesk-setup}"
UNIT="${AIB_RUSTDESK_UNIT:-rustdesk.service}"
IPC_TMP="${AIB_RUSTDESK_TMP:-/tmp}"
READY_TIMEOUT="${AIB_RUSTDESK_READY_TIMEOUT:-180}"
POLL="${AIB_RUSTDESK_POLL:-2}"
PW_TRIES="${AIB_RUSTDESK_PW_TRIES:-5}"
MAX_RUNS="${AIB_RUSTDESK_MAX_RUNS:-6}"
MAX_BOOTS="${AIB_RUSTDESK_MAX_BOOTS:-3}"
PORT="${RUSTDESK_PORT:-21118}"
RD="${RUSTDESK_BIN:-rustdesk}"
log() { echo "aib-rustdesk-setup: $*"; }

# ---- 计数: 本次开机第几次运行 (/run, 重启清零) + 第几次开机
mkdir -p "$RUN_DIR" "$(dirname "$STAMP")"
run=$(( $(cat "$RUN_DIR/runs" 2>/dev/null || echo 0) + 1 ))
echo "$run" > "$RUN_DIR/runs"
boots="$(cat "$BOOTS_FILE" 2>/dev/null || echo 0)"
if [ "$run" -eq 1 ]; then boots=$((boots + 1)); echo "$boots" > "$BOOTS_FILE"; fi

give_up() {  # 彻底放弃: 删明文, 留原因, 退出码 2
  { date '+%F %T'; echo "$1"; } > "$FAILED"
  rm -f "$SECRET"
  log "失败且不再重试 (连续 ${boots} 次开机): $1"
  log "明文密码已删除。手动设置: sudo rustdesk --password '<新密码>'; 原因见 $FAILED"
  exit 2
}
retry() {  # 本轮失败: 还有次数 → exit 1 (systemd 30s 后重试); 用完 → exit 2
  log "第 ${run}/${MAX_RUNS} 次运行失败 (第 ${boots}/${MAX_BOOTS} 次开机): $1"
  if [ "$run" -lt "$MAX_RUNS" ]; then log "30 秒后由 systemd 重试"; exit 1; fi
  [ "$boots" -lt "$MAX_BOOTS" ] || give_up "$1"
  log "本次开机重试次数用完, 停止重试 (unit 置为 failed); 下次开机再试。排查: systemctl status $UNIT; ps -eo uid,args | grep 'rustdesk --server'"
  exit 2
}

command -v "$RD" >/dev/null 2>&1 || retry "找不到 rustdesk 可执行文件"

# 防火墙: 只在 ufw 已启用时放行直连端口, 不会主动启用 ufw
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw status 2>/dev/null | grep -q "^${PORT}/tcp" || ufw allow "${PORT}/tcp" comment rustdesk >/dev/null 2>&1 || true
fi

# ---- 等就绪
server_uids() {  # 正在运行的 `<...>/rustdesk --server` 进程的 uid (排除 sudo 包装进程)
  ps -eo uid=,args= 2>/dev/null | awk '$2 ~ /(^|\/)rustdesk$/ && $3 == "--server" && NF == 3 { print $1 }' | sort -un
}
check_ready() {  # 输出缺的项; 就绪时设置 uids
  local miss="" u
  uids="$(server_uids | tr '\n' ' ')"; uids="${uids% }"
  systemctl is-active --quiet "$UNIT" 2>/dev/null || miss="$miss $UNIT 未 active;"
  if [ -z "$uids" ]; then
    miss="$miss 没有 rustdesk --server 进程 (rustdesk.service 只在有图形会话 —— GDM 登录界面或已登录用户 —— 时才拉起它);"
  else
    for u in $uids; do
      [ -S "$IPC_TMP/RustDesk-$u/ipc" ] || miss="$miss --server (uid $u) 的 IPC socket $IPC_TMP/RustDesk-$u/ipc 还没建立;"
    done
  fi
  printf '%s' "$miss"
}
waited=0
miss="$(check_ready)"
while [ -n "$miss" ] && [ "$waited" -lt "$READY_TIMEOUT" ]; do
  sleep "$POLL"; waited=$((waited + POLL))
  miss="$(check_ready)"
done
[ -z "$miss" ] || retry "等待 RustDesk 就绪超时 (${READY_TIMEOUT}s):$miss"
uids="$(server_uids | tr '\n' ' ')"; uids="${uids% }"
log "RustDesk 就绪 (等待 ${waited}s): --server uid=${uids:-?}, IPC $IPC_TMP/RustDesk-${uids%% *}/ipc"

# ---- 固定密码 (经 --server 的 IPC; Done! = 守护进程已确认)
if [ -f "$SECRET" ]; then
  RUSTDESK_PASSWORD=""
  # shellcheck disable=SC1090
  . "$SECRET"
  [ -n "$RUSTDESK_PASSWORD" ] || give_up "$SECRET 里没有密码"
  ok=0; last=""
  for i in $(seq 1 "$PW_TRIES"); do
    out="$(timeout 30 "$RD" --password "$RUSTDESK_PASSWORD" 2>&1)"
    if printf '%s\n' "$out" | grep -q 'Done!'; then ok=1; break; fi
    # 输出里万一回显了密码, 先打码再进日志
    last="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1)"
    last="${last//"$RUSTDESK_PASSWORD"/***}"
    log "rustdesk --password 第 $i/$PW_TRIES 次未成功: ${last:-无输出}"
    [ "$i" -lt "$PW_TRIES" ] && sleep "$POLL"
  done
  unset RUSTDESK_PASSWORD
  [ "$ok" -eq 1 ] || retry "设置固定密码失败 (${PW_TRIES} 次): ${last:-无输出}"
  log "固定密码已设置"
elif [ ! -f "$STAMP" ]; then
  log "没有 $SECRET (已设置过或被删除), 只确认选项"
fi

# ---- 选项读回 (兜底; 正常情况下装机预置已生效)
bad=""
if [ -f "$OPTIONS" ]; then
  while read -r k v; do
    case "$k" in ''|\#*|\!*) continue ;; esac
    got="$(timeout 15 "$RD" --option "$k" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
    if [ "$got" != "$v" ]; then
      log "option $k 读回 '$got', 补设为 $v"
      timeout 15 "$RD" --option "$k" "$v" >/dev/null 2>&1 || true
      sleep 1
      got="$(timeout 15 "$RD" --option "$k" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
    fi
    [ "$got" = "$v" ] || bad="$bad $k(读回 '$got');"
  done < "$OPTIONS"
fi
[ -z "$bad" ] || retry "选项未生效:$bad"

rm -f "$SECRET" "$FAILED" "$BOOTS_FILE"
date '+%F %T' > "$STAMP"
if grep -qx 'custom-rendezvous-server 127.0.0.1' "$OPTIONS" 2>/dev/null; then
  log "完成: 只允许局域网 IP 直连 <本机IP>:${PORT} (不连 RustDesk 公共 ID / 中继服务器); 明文密码已删除"
else
  log "完成: 局域网 IP 直连端口 ${PORT}/tcp; 明文密码已删除"
fi
SETUP
chmod 0755 "$R/usr/local/sbin/aib-rustdesk-setup"

install -d -m 0755 "$R/etc/systemd/system" "$R/etc/systemd/system/rustdesk.service.d"
cat > "$R/etc/systemd/system/rustdesk.service.d/aib-preseed.conf" <<'DROPIN'
# autoinstall-iso-builder: 首次设置完成前, 每次启动 RustDesk 前把直连 / rendezvous 选项写进各账号配置
[Service]
ExecStartPre=-/usr/local/sbin/aib-rustdesk-preseed --if-not-done
DROPIN
cat > "$R/etc/systemd/system/aib-rustdesk-setup.service" <<UNIT
[Unit]
Description=Apply autoinstall RustDesk settings (permanent password, direct IP access ${RUSTDESK_PORT}/tcp)
After=rustdesk.service network-online.target
Wants=rustdesk.service
ConditionPathExists=!/var/lib/aib/rustdesk-setup.done
ConditionPathExists=!/var/lib/aib/rustdesk-setup.failed
# 次数由脚本自己数 (每次开机最多 6 次运行, 最多 3 次开机), 不用 systemd 的启动频率限制
StartLimitIntervalSec=0

[Service]
Type=oneshot
Environment=RUSTDESK_PORT=${RUSTDESK_PORT}
ExecStart=/usr/local/sbin/aib-rustdesk-setup
TimeoutStartSec=15min
Restart=on-failure
RestartSec=30
# 退出码 2 = 重试次数用完, 不再自动重启 (unit 保持 failed)
RestartPreventExitStatus=2

[Install]
WantedBy=multi-user.target
UNIT
echo "wrote /etc/systemd/system/aib-rustdesk-setup.service + rustdesk.service.d/aib-preseed.conf"

if [ "$SKIP_PKG" != "1" ]; then
  if [ -f /etc/ufw/ufw.conf ] && grep -q '^ENABLED=yes' /etc/ufw/ufw.conf && command -v ufw >/dev/null 2>&1; then
    ufw allow "${RUSTDESK_PORT}/tcp" comment rustdesk || echo "warn: ufw allow 失败, 开机后由 aib-rustdesk-setup 再试"
  fi
  systemctl enable rustdesk.service
  systemctl enable aib-rustdesk-setup.service
  echo "RustDesk $(dpkg-query -W -f='${Version}' rustdesk 2>/dev/null || echo '?') ok"
fi

if [ -n "$RUSTDESK_SERVER" ]; then _rd_mode="自建服务器 $RUSTDESK_SERVER"
elif [ "$RUSTDESK_ALLOW_ID" = "1" ]; then _rd_mode="保留公共 ID 服务器"
else _rd_mode="只允许局域网 IP 直连, 不连公共 ID / 中继服务器"; fi
echo "rustdesk ok: 局域网 IP 直连 ${RUSTDESK_PORT}/tcp, 固定密码 (首次开机设置), $_rd_mode"
