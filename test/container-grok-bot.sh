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
#   4) FlClash + Grok Bot 同一次 apt 解析 / 先装 FlClash 再跑钩子: 不能同时收
#      libayatana-appindicator3-1 和 libappindicator3-1 (二者 Conflicts)。这是真机 --force-fetch 曾踩过的坑。
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
   "$ROOT/tools/grok-bot-release.sh" "$ROOT/tools/grok-bot-archive-key.asc" \
   "$ROOT/tools/flclash-release.sh" "$work/prov/"
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
dpkg-query -W -f='${Status}\n' libappindicator3-1 2>/dev/null | grep -q 'install ok installed' && echo "RECS_OK" >> /logs/online.log
test -f /etc/apt/sources.list.d/grok-bot.sources && echo "SOURCES_OK" >> /logs/online.log
test -f /etc/apparmor.d/grok-bot && echo "APPARMOR_OK" >> /logs/online.log
test -x /usr/bin/grok-bot && echo "BIN_OK" >> /logs/online.log
# 签名源可用: update 后 grok-bot 的候选来自 downloads.cursor.com
apt-get update > /logs/online-update.log 2>&1 && apt-cache policy grok-bot >> /logs/online-update.log 2>&1
ON
docker run --rm --network host -v "$work/prov:/prov:ro" -v "$work/logs:/logs" -v "$work/online.sh:/online.sh:ro" "$IMG" bash /online.sh || true
if grep -qx 'rc=0' "$work/logs/online.log" && grep -q 'install ok installed' "$work/logs/online.log" \
   && grep -q 'sha256 来源: ' "$work/logs/online.log" && ! grep -q '^SKIP:' "$work/logs/online.log" \
   && grep -qx SOURCES_OK "$work/logs/online.log" && grep -qx RECS_OK "$work/logs/online.log" && grep -qx APPARMOR_OK "$work/logs/online.log" && grep -qx BIN_OK "$work/logs/online.log"; then
  pass "online: feed → verified deb → apt install (+ Recommends libappindicator3-1); grok-bot.sources kept; AppArmor profile installed ($(grep -o 'install ok installed .*' "$work/logs/online.log"))"
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
apt-get install -y -qq --download-only --no-install-recommends -o Dir::Cache::archives=/tmp/arch -o Dir::State::status=/tmp/status0 "$GROK_BOT_DEB_PATH" \
  $(grokbot_available_recommends "$GROK_BOT_DEB_PATH") >/dev/null
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
dpkg-query -W -f='${Status}\n' libappindicator3-1 2>/dev/null | grep -q 'install ok installed' && echo "RECS_OK" >> /logs/offline.log
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
   && grep -qx MOVED_OK "$work/logs/offline.log" && grep -qx UPDATE1_OK "$work/logs/offline.log" \
   && grep -qx RECS_OK "$work/logs/offline.log"; then
  pass "offline (--network none): installed from bundle (+ libappindicator3-1); grok-bot.sources parked in offline-bak; apt-get update ok"
else
  fail "offline install: $(tail -15 "$work/logs/offline.log")"
fi
if grep -qx RESTORED_OK "$work/logs/offline.log" && grep -qx TUNA_OK "$work/logs/offline.log" && grep -qx UPDATE2_OK "$work/logs/offline.log" \
   && grep -q 'downloads.cursor.com' "$work/logs/offline-update2.log"; then
  pass "restore-online-apt: grok-bot.sources restored unchanged next to Tsinghua ubuntu.sources; no-network apt-get update only warns"
else
  fail "restore / no-network update: $(tail -n 6 "$work/logs/offline.log" "$work/logs/offline-update2.log" "$work/logs/restore.log")"
fi

# ---- 4) FlClash + Grok Bot 同一次解析 (libayatana-appindicator3-1 Conflicts libappindicator3-1) ----
cat > "$work/fetch-flclash.sh" <<'FE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends ca-certificates curl >/dev/null
# shellcheck disable=SC1091
. /prov/flclash-release.sh
arch="$(dpkg --print-architecture)"
flclash_resolve "$arch"
flclash_download_to /bundle/flclash
printf '%s\n' "$FLCLASH_VERSION" > /bundle/flclash/version
echo "flclash=$FLCLASH_DEB_NAME"
FE
if docker run --rm --network host -v "$work/prov:/prov:ro" -v "$work/bundle:/bundle" -v "$work/fetch-flclash.sh:/fetch-flclash.sh:ro" "$IMG" bash /fetch-flclash.sh > "$work/logs/fetch-flclash.log" 2>&1 \
   && compgen -G "$work/bundle/flclash"/FlClash-*.deb >/dev/null; then
  pass "FlClash deb for conflict test: $(tail -1 "$work/logs/fetch-flclash.log")"
else
  fail "FlClash download for conflict test: $(tail -8 "$work/logs/fetch-flclash.log")"
fi
cat > "$work/conflict.sh" <<'CF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends ca-certificates dpkg-dev >/dev/null
# shellcheck disable=SC1091
. /prov/grok-bot-release.sh
# shellcheck disable=SC1091
. /prov/flclash-release.sh
GB="$(echo /bundle/grok-bot/*.deb)"
FC="$(echo /bundle/flclash/FlClash-*.deb)"
test -f "$GB" && test -f "$FC"
mkdir -p /tmp/c1/partial /tmp/c2/partial /tmp/c3/partial

# 冲突本身还在: 两个托盘库不能一起装 (Ubuntu 以后若不再冲突, 应改测试而不是删掉这条)
if apt-get install -y --download-only --no-install-recommends -o Dir::Cache::archives=/tmp/c1 \
     libayatana-appindicator3-1 libappindicator3-1 >/tmp/conflict.apt 2>&1; then
  echo "CONFLICT_GONE: libayatana-appindicator3-1 and libappindicator3-1 no longer conflict" >&2
  exit 1
fi
grep -q 'Conflicts: libappindicator3-1' /tmp/conflict.apt
echo CONFLICT_OK

# 种子函数: FlClash Depends (含 libayatana-appindicator3-1) 已在计划里 → 不收真包
mapfile -t PLANNED < <(flclash_deb_depends "$FC"; dpkg-deb -f "$GB" Depends 2>/dev/null | tr ',' '\n' | while IFS= read -r dep; do
  first="${dep%%|*}"; first="$(printf '%s' "$first" | sed 's/([^)]*)//g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$first" ] && printf '%s\n' "$first"
done)
recs="$(grokbot_seed_recommends "$GB" "${PLANNED[@]}" 2>/tmp/seed.err || true)"
grep -q '已由种子 libayatana-appindicator3-1 提供' /tmp/seed.err
printf '%s\n' "$recs" | grep -qx libappindicator3-1 && { echo "SEED_STILL_HAS_LIBAPPINDICATOR: [$recs]" >&2; exit 1; }
echo SEED_SKIP_OK

# 同一次 apt 解析: 两个 deb + 计算出的 Recommends 必须成功
# shellcheck disable=SC2086
apt-get install -y --download-only --no-install-recommends -o Dir::Cache::archives=/tmp/c2 \
  "$FC" "$GB" $recs >/dev/null
echo RESOLVE_OK
# 若仍把真包塞进同一组, 必须失败 (这就是修之前 --force-fetch 的报错)
if apt-get install -y --download-only --no-install-recommends -o Dir::Cache::archives=/tmp/c3 \
     "$FC" "$GB" libappindicator3-1 >/tmp/both.apt 2>&1; then
  echo "RESOLVE_SHOULD_CONFLICT" >&2
  exit 1
fi
grep -q 'Conflicts: libappindicator3-1' /tmp/both.apt
echo RESOLVE_CONFLICT_OK
CF
if docker run --rm --network host -v "$work/prov:/prov:ro" -v "$work/bundle:/bundle:ro" -v "$work/conflict.sh:/conflict.sh:ro" "$IMG" bash /conflict.sh > "$work/logs/conflict.log" 2>&1 \
   && grep -qx CONFLICT_OK "$work/logs/conflict.log" && grep -qx SEED_SKIP_OK "$work/logs/conflict.log" \
   && grep -qx RESOLVE_OK "$work/logs/conflict.log" && grep -qx RESOLVE_CONFLICT_OK "$work/logs/conflict.log"; then
  pass "FlClash + Grok Bot apt resolution: skips libappindicator3-1 (provided by libayatana-appindicator3-1); adding both still conflicts"
else
  fail "FlClash + Grok Bot apt resolution: $(tail -15 "$work/logs/conflict.log")"
fi

cat > "$work/together.sh" <<'TG'
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends ca-certificates /opt/offline/flclash/FlClash-*.deb >/tmp/fc.apt 2>&1 || { echo "FLCLASH_INSTALL_FAIL"; cat /tmp/fc.apt; exit 1; }
dpkg-query -W -f='${Status}\n' libayatana-appindicator3-1 2>/dev/null | grep -q 'install ok installed' && echo AYATANA_OK >> /logs/together.log
EDITION=desktop OFFLINE=1 OFFLINE_ROOT=/opt/offline bash /prov/39-grok-bot.sh >> /logs/together.log 2>&1
echo "rc=$?" >> /logs/together.log
dpkg-query -W -f='${Status} ${Version}\n' grok-bot >> /logs/together.log 2>&1
dpkg-query -W -f='${Status}\n' libappindicator3-1 2>/dev/null | grep -q 'install ok installed' && echo REAL_LIBAPP_INSTALLED >> /logs/together.log || echo NO_REAL_LIBAPP >> /logs/together.log
grep -q '已由已装的包提供' /logs/together.log && echo SKIP_REC_OK >> /logs/together.log
TG
chmod a+r "$work/together.sh"
docker run --rm --network host -v "$work/prov:/prov:ro" -v "$work/bundle:/opt/offline:ro" -v "$work/logs:/logs" -v "$work/together.sh:/together.sh:ro" "$IMG" bash /together.sh || true
if grep -qx 'rc=0' "$work/logs/together.log" && grep -q 'install ok installed' "$work/logs/together.log" \
   && ! grep -q '^SKIP:' "$work/logs/together.log" && grep -qx AYATANA_OK "$work/logs/together.log" \
   && grep -qx NO_REAL_LIBAPP "$work/logs/together.log" && grep -qx SKIP_REC_OK "$work/logs/together.log"; then
  pass "hook: FlClash first (libayatana-appindicator3-1), then Grok Bot skips real libappindicator3-1 and still installs"
else
  fail "hook FlClash then Grok Bot: $(tail -15 "$work/logs/together.log")"
fi

if [[ "$FAIL" -ne 0 ]]; then echo "container grok-bot: FAILED" >&2; exit 1; fi
echo "container grok-bot: ALL PASS"
