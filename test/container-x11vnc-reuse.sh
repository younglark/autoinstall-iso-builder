#!/usr/bin/env bash
# =============================================================================
# container-x11vnc-reuse.sh — 需要 docker 和外网 (只走 Ubuntu 官方/指定源, 体量 ~30MB)
#
#   1) 用 fetch-offline-bundle 的同一份容器内脚本 (FETCH_MINIMAL_SEEDS 钩子) 抓
#      x11vnc xauth (+ 测试用 xvfb procps) 两次, 第二次必须「复用 N, 新下载 0」
#   2) --network none 的新容器里只用这份离线池安装 x11vnc, 跑 software/36-x11vnc-xorg.sh
#   3) 两个改名为 Xorg 的 Xvfb (:0 = 登录界面, :1 = 用户会话) 验证 aib-x11vnc-follow
#      先接 :0, :0 退出后自动改接 :1。和真机 GDM 一样用 -displayfd 起、Xauthority 不带显示号
#
#   bash test/container-x11vnc-reuse.sh [--mirror URL] [--release noble]
# =============================================================================
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR="http://archive.ubuntu.com/ubuntu"
RELEASE="noble"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mirror) MIRROR="$2"; shift 2 ;;
    --release) RELEASE="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done
case "$RELEASE" in noble) IMG=ubuntu:24.04 ;; jammy) IMG=ubuntu:22.04 ;; *) echo "release?" >&2; exit 2 ;; esac
command -v docker >/dev/null || { echo "需要 docker" >&2; exit 1; }

FAIL=0
pass() { printf '[pass] %s\n' "$*"; }
fail() { printf '[fail] %s\n' "$*" >&2; FAIL=1; }

work="$(mktemp -d -t aib-x11vnc-XXXXXX)"
cleanup() { docker run --rm -v "$work:/w" "$IMG" rm -rf /w/cache /w/out1 /w/out2 >/dev/null 2>&1 || true; rm -rf -- "$work"; }
trap cleanup EXIT
# shellcheck disable=SC2016  # sed 模式里的字面量 $WORK
sed -n '/^cat > "\$WORK\/fetch-debs.sh" <<.INNER.$/,/^INNER$/p' "$ROOT/tools/fetch-offline-bundle.sh" | sed '1d;$d' > "$work/fetch-debs.sh"
[[ -s "$work/fetch-debs.sh" ]] || { echo "提取容器内脚本失败" >&2; exit 1; }
mkdir -p "$work/cache" "$work/out1" "$work/out2"
SEEDS="x11vnc xauth xvfb procps"

run_fetch() { # outdir
  docker run --rm --network host \
    -v "$work/fetch-debs.sh:/fetch-debs.sh:ro" \
    -v "$ROOT/tools/ubuntu-mirror.sh:/ubuntu-mirror.sh:ro" \
    -v "$ROOT/tools/apt-deb-reuse.sh:/apt-deb-reuse.sh:ro" \
    -v "$work/cache:/apt-cache" -e FETCH_APT_CACHE=/apt-cache \
    -v "$work/$1:/out" \
    -e FETCH_MINIMAL_SEEDS="$SEEDS" -e DEBIAN_FRONTEND=noninteractive \
    "$IMG" bash /fetch-debs.sh "$RELEASE" amd64 24 "$MIRROR" ""
}

echo "== fetch #1 (空缓存) =="
run_fetch out1 > "$work/f1.log" 2>&1 || { tail -30 "$work/f1.log"; fail "fetch #1"; exit 1; }
grep -E '^(deb 需求|deb 复用|apt deb:|deb 缓存)' "$work/f1.log"
echo "== fetch #2 (同一缓存) =="
run_fetch out2 > "$work/f2.log" 2>&1 || { tail -30 "$work/f2.log"; fail "fetch #2"; exit 1; }
grep -E '^(deb 需求|deb 复用|apt deb:|deb 缓存)' "$work/f2.log"
reused=0; downloaded=0; total=0
# shellcheck disable=SC1091
. "$work/out1/.apt-reuse-stats"; r1=$reused; d1=$downloaded; t1=$total
# shellcheck disable=SC1091
. "$work/out2/.apt-reuse-stats"; r2=$reused; d2=$downloaded; t2=$total
if [[ "$r1" -eq 0 && "$d1" -gt 0 && "$t2" -eq "$t1" && "$r2" -eq "$t2" && "$d2" -eq 0 ]]; then
  pass "第二次全部复用: 复用 $r2 / 新下载 $d2 (第一次下载 $d1)"
else
  fail "复用统计异常: #1 r=$r1 d=$d1 t=$t1; #2 r=$r2 d=$d2 t=$t2"
fi
if diff <(cd "$work/out1/apt" && sha256sum ./*.deb) <(cd "$work/out2/apt" && sha256sum ./*.deb) >/dev/null \
   && grep -q '^Package: x11vnc$' "$work/out2/apt/Packages"; then
  pass "两次产出的 deb 完全一致, Packages 含 x11vnc"
else
  fail "两次产出不一致"
fi

echo "== 离线安装 x11vnc + 36-x11vnc-xorg.sh + 跟随显示 =="
cat > "$work/offline-test.sh" <<'IN'
#!/bin/bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
echo 'deb [trusted=yes] file:/opt/offline/apt ./' > /etc/apt/sources.list.d/00-offline-bundle.list
apt-get update -qq
apt-get install -y -qq --no-install-recommends x11vnc xauth xvfb procps >/dev/null
# chroot 风格: 无 systemd, systemctl/dconf 用桩记录调用
mkdir -p /tmp/shim
printf '#!/bin/sh\necho "systemctl $*" >> /tmp/shim/calls\n' > /tmp/shim/systemctl
chmod +x /tmp/shim/systemctl
export PATH="/tmp/shim:$PATH"
mkdir -p /opt/provision
cp /src/software/36-x11vnc-xorg.sh /src/software/lib-offline.sh /opt/provision/
( umask 077; printf 'VNC_PASSWORD=%q\n' 'Vnc#Pass9' > /opt/provision/x11vnc.secret )
mkdir -p /etc/gdm3; printf '[daemon]\n#WaylandEnable=false\n' > /etc/gdm3/custom.conf
EDITION=desktop X11VNC=1 OFFLINE=1 OFFLINE_ROOT=/opt/offline bash /opt/provision/36-x11vnc-xorg.sh > /tmp/36.log 2>&1 \
  || { cat /tmp/36.log; exit 1; }
grep -q 'Vnc#Pass9' /tmp/36.log && { echo "FAIL password leaked"; exit 1; }
[ ! -e /opt/provision/x11vnc.secret ] || { echo "FAIL secret kept"; exit 1; }
[ "$(stat -c %a /etc/x11vnc.pass)" = 600 ] && [ -s /etc/x11vnc.pass ] || { echo "FAIL pass file"; exit 1; }
grep -qx 'WaylandEnable=false' /etc/gdm3/custom.conf || { echo "FAIL gdm"; exit 1; }
grep -q 'systemctl enable x11vnc.service' /tmp/shim/calls || { echo "FAIL enable"; exit 1; }
echo "OK install"

grep -q 'setpriv --reuid="$owner"' /usr/local/sbin/aib-x11vnc-follow || { echo "FAIL follower lacks setpriv"; exit 1; }
grep -qE -- '-noshm|-nowf|-noxdamage' /usr/local/sbin/aib-x11vnc-follow && { echo "FAIL follower still has -noshm/-nowf/-noxdamage"; exit 1; }

# 伪造 GDM: 登录界面 :0 与用户会话 :1, 进程名都叫 Xorg (follower 按 Xorg 进程找 -auth)。
# 与真机一致: Xorg 用 -displayfd 起 (命令行没有 :N), Xauthority 只有不带显示号的条目
# (<host>/unix: 与 #ffff#<host>#:), xauth list 里拿不到显示号。
mk_gdm_xauth() { # file: FamilyLocal + FamilyWild, number 为空, 随机 cookie
  local h c; h="$(hostname)"; c="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  be16() { printf '%b' "\\$(printf '%03o' $(( $1 >> 8 )))\\$(printf '%03o' $(( $1 & 255 )))"; }
  hex2bin() { local s="$1" i; for ((i = 0; i < ${#s}; i += 2)); do printf '%b' "\\$(printf '%03o' "0x${s:i:2}")"; done; }
  {
    be16 256;   be16 ${#h}; printf '%s' "$h"; be16 0; be16 18; printf 'MIT-MAGIC-COOKIE-1'; be16 16; hex2bin "$c"
    be16 65535; be16 ${#h}; printf '%s' "$h"; be16 0; be16 18; printf 'MIT-MAGIC-COOKIE-1'; be16 16; hex2bin "$c"
  } > "$1"
}
mkdir -p /tmp/xbin /run/user/120/gdm /run/user/1000/gdm
cp "$(command -v Xvfb)" /tmp/xbin/Xorg
mk_gdm_xauth /run/user/120/gdm/Xauthority
mk_gdm_xauth /run/user/1000/gdm/Xauthority
# 与真机一致: auth 文件属 gdm (登录界面) / 登录用户 (会话); follower 以属主身份跑 x11vnc
id gdm >/dev/null 2>&1 || useradd -r -u 120 -M -s /usr/sbin/nologin gdm
id ubuntu >/dev/null 2>&1 || useradd -u 1000 -m ubuntu
chown gdm /run/user/120/gdm/Xauthority; chown ubuntu /run/user/1000/gdm/Xauthority
[ "$(xauth -f /run/user/1000/gdm/Xauthority list | wc -l)" = 2 ] \
  && ! xauth -f /run/user/1000/gdm/Xauthority list | grep -q ':[0-9]' || { echo "FAIL xauth fixture"; exit 1; }
/tmp/xbin/Xorg -displayfd 3 -auth /run/user/120/gdm/Xauthority -nolisten tcp -screen 0 800x600x24 3>/tmp/dfd0 >/dev/null 2>&1 &
X0=$!
sleep 2
[ "$(tr -dc 0-9 < /tmp/dfd0)" = 0 ] || { echo "FAIL greeter displayfd != 0"; exit 1; }
X11VNC_POLL=1 X11VNC_RUNDIR=/tmp/aibx /usr/local/sbin/aib-x11vnc-follow > /tmp/follow.log 2>&1 &
FP=$!
on_display() { # 等待 x11vnc 进程接到指定 display
  for _ in $(seq 1 20); do
    pgrep -af '^x11vnc ' | grep -q -- "-display $1 " && return 0
    sleep 1
  done
  return 1
}
listening() { grep -qi ':170C ' /proc/net/tcp /proc/net/tcp6 2>/dev/null; }  # 5900
on_display :0 || { echo "FAIL not on :0"; cat /tmp/follow.log /tmp/aibx/*.log; exit 1; }
for _ in $(seq 1 10); do listening && break; sleep 1; done
listening || { echo "FAIL :0 not listening"; tail /tmp/aibx/*.log; exit 1; }
[ "$(ps -o user= -p "$(pgrep -x x11vnc | head -1)")" = gdm ] || { echo "FAIL greeter x11vnc not running as gdm"; ps -o user,args -C x11vnc; exit 1; }
echo "OK greeter :0 (x11vnc as gdm)"
# 用户登录: 起 :1, 登录界面退出
/tmp/xbin/Xorg -displayfd 3 -auth /run/user/1000/gdm/Xauthority -nolisten tcp -screen 0 800x600x24 3>/tmp/dfd1 >/dev/null 2>&1 &
sleep 1
[ "$(tr -dc 0-9 < /tmp/dfd1)" = 1 ] || { echo "FAIL session displayfd != 1"; exit 1; }
kill "$X0"
on_display :1 || { echo "FAIL not on :1"; cat /tmp/follow.log; tail /tmp/aibx/*.log; exit 1; }
for _ in $(seq 1 10); do listening && break; sleep 1; done
listening || { echo "FAIL :1 not listening"; tail /tmp/aibx/*.log; exit 1; }
[ "$(ps -o user= -p "$(pgrep -x x11vnc | head -1)")" = ubuntu ] || { echo "FAIL session x11vnc not running as ubuntu"; ps -o user,args -C x11vnc; exit 1; }
echo "OK session :1 (x11vnc as ubuntu)"
grep -c 'x11vnc -> display' /tmp/follow.log
kill "$FP"; wait "$FP" 2>/dev/null || true
pgrep -x x11vnc >/dev/null && { echo "FAIL x11vnc left running"; exit 1; }
echo "OK stop"
IN
if docker run --rm --network none \
     -v "$work/out2/apt:/opt/offline/apt:ro" -v "$ROOT:/src:ro" -v "$work/offline-test.sh:/t.sh:ro" \
     "$IMG" bash /t.sh > "$work/o.log" 2>&1; then
  cat "$work/o.log"
  pass "离线安装 x11vnc + 36 脚本 + 登录界面→会话 跟随"
else
  cat "$work/o.log" >&2
  fail "离线安装 / 跟随测试"
fi

if [[ "$FAIL" -ne 0 ]]; then echo "container x11vnc/reuse: FAILED" >&2; exit 1; fi
echo "container x11vnc/reuse: ALL PASS"
