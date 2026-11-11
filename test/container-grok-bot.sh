#!/usr/bin/env bash
# =============================================================================
# container-grok-bot.sh — 需要 docker 和外网 (Grok Bot deb 约 110MB, 下载两次; 依赖走 Ubuntu 官方源)
#
#   1) 在线: 干净 ubuntu 容器里跑 software/39-grok-bot.sh (读发布 feed → 下载 → 签名 apt 索引校验 sha256
#      → apt 装依赖)。检查 grok-bot 已装、grok-bot.sources 保留、apt-get update 能用它的签名源、
#      AppArmor profile 已放进 /etc/apparmor.d
#   2) 抓一个最小离线池: grok-bot/ (deb + sha256) + apt/ (deb 和依赖闭包, dpkg-scanpackages)
#   3) --network none 的新容器: enable-offline-apt.sh → 39-grok-bot.sh (OFFLINE=1) → 检查 grok-bot.sources
#      被挪进 offline-bak、无网 apt-get update 仍成功 → restore-online-apt.sh (清华源) 后 grok-bot.sources
#      原样回来、ubuntu 源改成清华、无网 apt-get update 仍不报错 (只告警)
#
#   bash test/container-grok-bot.sh [--release noble|jammy]
# =============================================================================
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="noble"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done
case "$RELEASE" in noble) IMG=ubuntu:24.04 ;; jammy) IMG=ubuntu:22.04 ;; *) echo "release?" >&2; exit 2 ;; esac
command -v docker >/dev/null || { echo "需要 docker" >&2; exit 1; }

FAIL=0
pass() { printf '[pass] %s\n' "$*"; }
fail() { printf '[fail] %s\n' "$*" >&2; FAIL=1; }

work="$(mktemp -d -t aib-grokbot-XXXXXX)"
cleanup() { [ -n "${KEEP_WORK:-}" ] && { echo "work: $work"; return; };  docker run --rm -v "$work:/w" "$IMG" rm -rf /w/bundle /w/logs >/dev/null 2>&1 || true; rm -rf -- "$work"; }
trap cleanup EXIT
mkdir -p "$work/prov" "$work/bundle/apt-sources" "$work/logs"  # 空 apt-sources/: 真实捆绑都有, 没有时 restore 会提前退出
cp "$ROOT/software/39-grok-bot.sh" "$ROOT/software/lib-offline.sh" \
   "$ROOT/tools/grok-bot-release.sh" "$ROOT/tools/grok-bot-archive-key.asc" "$work/prov/"
cp "$ROOT/autoinstall/enable-offline-apt.sh" "$ROOT/autoinstall/restore-online-apt.sh" "$ROOT/tools/ubuntu-mirror.sh" "$work/bundle/"
chmod -R a+rX "$work"

# ---- 1) 在线安装 -------------------------------------------------------------
cat > "$work/online.sh" <<'ON'
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
# 最小环境: 只有 curl + gpgv (不需要 python3); apparmor 提供 apparmor_parser (容器里内核 AppArmor 不可用)
apt-get install -y -qq --no-install-recommends ca-certificates curl apparmor >/dev/null
EDITION=desktop bash /prov/39-grok-bot.sh > /logs/online.log 2>&1; echo "rc=$?" >> /logs/online.log
dpkg-query -W -f='${Status} ${Version}\n' grok-bot >> /logs/online.log 2>&1
test -f /etc/apt/sources.list.d/grok-bot.sources && echo "SOURCES_OK" >> /logs/online.log
test -f /etc/apparmor.d/grok-bot && echo "APPARMOR_OK" >> /logs/online.log
test -x /usr/bin/grok-bot && echo "BIN_OK" >> /logs/online.log
# 签名源可用: update 后 grok-bot 的候选来自 downloads.cursor.com
apt-get update > /logs/online-update.log 2>&1 && apt-cache policy grok-bot >> /logs/online-update.log 2>&1
ON
docker run --rm --network host -v "$work/prov:/prov:ro" -v "$work/logs:/logs" -v "$work/online.sh:/online.sh:ro" "$IMG" bash /online.sh || true
if grep -qx 'rc=0' "$work/logs/online.log" && grep -q 'install ok installed' "$work/logs/online.log" \
   && grep -q 'sha256 来源: ' "$work/logs/online.log" && ! grep -q '^SKIP:' "$work/logs/online.log" \
   && grep -qx SOURCES_OK "$work/logs/online.log" && grep -qx APPARMOR_OK "$work/logs/online.log" && grep -qx BIN_OK "$work/logs/online.log"; then
  pass "online: feed → verified deb → apt install; grok-bot.sources kept; AppArmor profile installed ($(grep -o 'install ok installed .*' "$work/logs/online.log"))"
else
  fail "online install: $(tail -15 "$work/logs/online.log")"
fi
if grep -q 'downloads.cursor.com/aptrepo grok-bot' "$work/logs/online-update.log"; then
  pass "online: apt-get update uses the signed grok-bot repo (updates via apt)"
else
  fail "online apt repo: $(tail -8 "$work/logs/online-update.log")"
fi

# ---- 2) 最小离线池 -----------------------------------------------------------
cat > "$work/fetch.sh" <<'FE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# 依赖闭包按 "干净镜像" 算 (装 curl / dpkg-dev 之前的 dpkg status), 否则 curl 带进来的库会漏进离线池之外
cp /var/lib/dpkg/status /tmp/status0
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends ca-certificates curl dpkg-dev >/dev/null
. /prov/grok-bot-release.sh
arch="$(dpkg --print-architecture)"
grokbot_resolve latest "$arch"
grokbot_download_to /bundle/grok-bot "$arch"
printf '%s\n' "$GROK_BOT_VERSION" > /bundle/grok-bot/version
printf '%s\n' "$GROK_BOT_SHA256" > /bundle/grok-bot/sha256
printf '%s\n' "$GROK_BOT_DEB_NAME" > /bundle/grok-bot/deb.name
mkdir -p /bundle/apt /tmp/arch/partial
apt-get install -y -qq --download-only --no-install-recommends -o Dir::Cache::archives=/tmp/arch -o Dir::State::status=/tmp/status0 "$GROK_BOT_DEB_PATH" >/dev/null
cp /tmp/arch/*.deb "$GROK_BOT_DEB_PATH" /bundle/apt/
cd /bundle/apt && dpkg-scanpackages . /dev/null > Packages 2>/dev/null
echo "debs=$(ls /bundle/apt/*.deb | wc -l) size=$(du -sh /bundle/apt | cut -f1)"
FE
if docker run --rm --network host -v "$work/prov:/prov:ro" -v "$work/bundle:/bundle" -v "$work/fetch.sh:/fetch.sh:ro" "$IMG" bash /fetch.sh > "$work/logs/fetch.log" 2>&1; then
  pass "mini offline pool: $(tail -1 "$work/logs/fetch.log")"
else
  fail "mini offline pool: $(tail -8 "$work/logs/fetch.log")"
fi

# ---- 3) 无网离线安装 ---------------------------------------------------------
cat > "$work/offline.sh" <<'OFF'
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
echo https://mirrors.tuna.tsinghua.edu.cn/ubuntu > /opt/offline/ubuntu-mirror.url
bash /opt/offline/enable-offline-apt.sh > /logs/enable.log 2>&1 || echo "ENABLE_FAIL" >> /logs/offline.log
EDITION=desktop OFFLINE=1 OFFLINE_ROOT=/opt/offline bash /prov/39-grok-bot.sh >> /logs/offline.log 2>&1; echo "rc=$?" >> /logs/offline.log
dpkg-query -W -f='${Status} ${Version}\n' grok-bot >> /logs/offline.log 2>&1
test ! -e /etc/apt/sources.list.d/grok-bot.sources && test -f /etc/apt/sources.list.d.offline-bak/grok-bot.sources && echo "MOVED_OK" >> /logs/offline.log
apt-get update > /logs/offline-update1.log 2>&1 && echo "UPDATE1_OK" >> /logs/offline.log
cp /etc/apt/sources.list.d.offline-bak/grok-bot.sources /tmp/gb.before
bash /opt/offline/restore-online-apt.sh > /logs/restore.log 2>&1 || echo "RESTORE_FAIL" >> /logs/offline.log
cmp -s /tmp/gb.before /etc/apt/sources.list.d/grok-bot.sources && echo "RESTORED_OK" >> /logs/offline.log
# 清华改写只动 Ubuntu 源 (无 ca-certificates 时走 http 引导, 写到哪个文件不重要); grok-bot.sources 不能被改
grep -rqs 'mirrors.tuna.tsinghua.edu.cn/ubuntu' /etc/apt/sources.list /etc/apt/sources.list.d/ \
  && ! grep -q tuna /etc/apt/sources.list.d/grok-bot.sources && echo "TUNA_OK" >> /logs/offline.log
grep -rh 'tuna' /etc/apt/sources.list /etc/apt/sources.list.d/ >> /logs/restore.log 2>&1 || true
# 装完仍无网: update 只告警 (含 downloads.cursor.com), 退出码 0
apt-get update > /logs/offline-update2.log 2>&1 && echo "UPDATE2_OK" >> /logs/offline.log
OFF
chmod a+r "$work/offline.sh"
docker run --rm --network none -v "$work/prov:/prov:ro" -v "$work/bundle:/opt/offline" -v "$work/logs:/logs" -v "$work/offline.sh:/offline.sh:ro" "$IMG" bash /offline.sh || true
if grep -qx 'rc=0' "$work/logs/offline.log" && grep -q 'install ok installed' "$work/logs/offline.log" \
   && ! grep -q '^SKIP:' "$work/logs/offline.log" && ! grep -q ENABLE_FAIL "$work/logs/offline.log" \
   && grep -qx MOVED_OK "$work/logs/offline.log" && grep -qx UPDATE1_OK "$work/logs/offline.log"; then
  pass "offline (--network none): installed from bundle; grok-bot.sources parked in offline-bak; apt-get update ok"
else
  fail "offline install: $(tail -15 "$work/logs/offline.log")"
fi
if grep -qx RESTORED_OK "$work/logs/offline.log" && grep -qx TUNA_OK "$work/logs/offline.log" && grep -qx UPDATE2_OK "$work/logs/offline.log" \
   && grep -q 'downloads.cursor.com' "$work/logs/offline-update2.log"; then
  pass "restore-online-apt: grok-bot.sources restored unchanged next to Tsinghua ubuntu.sources; no-network apt-get update only warns"
else
  fail "restore / no-network update: $(tail -n 6 "$work/logs/offline.log" "$work/logs/offline-update2.log" "$work/logs/restore.log")"
fi

if [[ "$FAIL" -ne 0 ]]; then echo "container grok-bot: FAILED" >&2; exit 1; fi
echo "container grok-bot: ALL PASS"
