#!/usr/bin/env bash
# validate-offline-bundle.sh — 构建前检查离线捆绑是否覆盖当前 software/ 需求
# 用法:
#   ./tools/validate-offline-bundle.sh --bundle DIR [--release noble|jammy|24.04|22.04]
#       [--skip "30 70"] [--pin-node N] [--pin-grok V] [--jenkins-plugins "a b"] ...
#       [--require-x11vnc]   (build-iso --remote-desktop x11vnc 时: 捆绑里必须有 x11vnc + xauth)
#       [--require-rustdesk] [--pin-rustdesk VER]
#                            (build-iso Desktop 默认 RustDesk 时: 捆绑里必须有 rustdesk/ 同版本 deb + sha256, apt 池可装)
#       [--require-grok-bot] [--grok-bot-version V] [--grok-bot-sha256 H]
#                            (build-iso Desktop 默认 Grok Bot 时: 捆绑里必须有 grok-bot/ deb + sha256, 且它和直接依赖都在 apt 池)
#       [--require-mdns]     (build-iso Server 预装 Gitea / Jenkins 时: 捆绑里必须有 avahi-daemon + libnss-mdns)
#       [--nvidia-driver-version N] [--nvidia-kernel-flavour F]
#                            (未 --skip 24 时: nvidia/ 记录的每个 flavour, 模块 meta / 内核 meta / 内核 ABI 版本必须一致)
set -Eeuo pipefail

BUNDLE=""
EXPECT_RELEASE=""
PROVISION_SKIP=""
PIN_NODE_MAJOR="${PIN_NODE_MAJOR:-24}"
PIN_GROK="${PIN_GROK:-latest}"
PIN_OPENCODE="${PIN_OPENCODE:-latest}"
PIN_OPENMAUSBOT="${PIN_OPENMAUSBOT:-latest}"
PIN_UNITY_CLI="${PIN_UNITY_CLI:-}"
PIN_GODOT="${PIN_GODOT:-4.7.2}"
PIN_GITEA="${PIN_GITEA:-latest}"
REQUIRE_X11VNC=0
REQUIRE_MDNS=0
REQUIRE_RUSTDESK=0
PIN_RUSTDESK="${PIN_RUSTDESK:-}"
REQUIRE_GROK_BOT=0
PIN_GROK_BOT="${PIN_GROK_BOT:-latest}"
GROK_BOT_SHA256="${GROK_BOT_SHA256:-}"
PIN_NVIDIA_DRIVER="${PIN_NVIDIA_DRIVER:-595}"
NVIDIA_KERNEL_FLAVOUR="${NVIDIA_KERNEL_FLAVOUR:-}"
JENKINS_PLUGINS="${JENKINS_PLUGINS:-workflow-aggregator git gitea docker-workflow credentials-binding timestamper rebuild ansicolor docker-plugin parameterized-trigger}"

die()  { printf '[fail] %s\n' "$*" >&2; exit 1; }
ok()   { printf '[ok] %s\n' "$*"; }

should_skip() {
  local name="$1" tok
  for tok in $PROVISION_SKIP; do
    [[ -z "$tok" ]] && continue
    case "$name" in
      "$tok"|"$tok"-*) return 0 ;;
    esac
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE="$2"; shift 2 ;;
    --release) EXPECT_RELEASE="$2"; shift 2 ;;
    --skip) PROVISION_SKIP="$2"; shift 2 ;;
    --pin-node) PIN_NODE_MAJOR="$2"; shift 2 ;;
    --pin-grok) PIN_GROK="$2"; shift 2 ;;
    --pin-opencode) PIN_OPENCODE="$2"; shift 2 ;;
    --pin-openmausbot) PIN_OPENMAUSBOT="$2"; shift 2 ;;
    --pin-unity-cli) PIN_UNITY_CLI="$2"; shift 2 ;;
    --pin-godot) PIN_GODOT="$2"; shift 2 ;;
    --pin-gitea) PIN_GITEA="$2"; shift 2 ;;
    --jenkins-plugins) JENKINS_PLUGINS="$2"; shift 2 ;;
    --require-x11vnc) REQUIRE_X11VNC=1; shift ;;
    --require-mdns) REQUIRE_MDNS=1; shift ;;
    --require-rustdesk) REQUIRE_RUSTDESK=1; shift ;;
    --pin-rustdesk) PIN_RUSTDESK="$2"; shift 2 ;;
    --require-grok-bot) REQUIRE_GROK_BOT=1; shift ;;
    --grok-bot-version) PIN_GROK_BOT="$2"; shift 2 ;;
    --grok-bot-sha256) GROK_BOT_SHA256="$2"; shift 2 ;;
    --nvidia-driver-version) PIN_NVIDIA_DRIVER="$2"; shift 2 ;;
    --nvidia-kernel-flavour) NVIDIA_KERNEL_FLAVOUR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,14p' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[[ -n "$BUNDLE" ]] || die "缺少 --bundle"
[[ -d "$BUNDLE" ]] || die "捆绑目录不存在: $BUNDLE"
[[ -f "$BUNDLE/manifest.json" ]] || die "缺 manifest.json: $BUNDLE"
[[ -d "$BUNDLE/apt" ]] || die "缺 apt/: $BUNDLE"
[[ -f "$BUNDLE/apt/Packages" || -f "$BUNDLE/apt/Packages.gz" ]] || die "缺 apt/Packages: $BUNDLE"

case "$EXPECT_RELEASE" in
  22.04) EXPECT_RELEASE=jammy ;;
  24.04) EXPECT_RELEASE=noble ;;
esac

# 需要出现在 Packages 里的包 (按未 skip 的脚本)
NEED_PKGS=(git ripgrep openssh-server ca-certificates curl)
should_skip 15-github-cli || NEED_PKGS+=(gh)
should_skip 20-docker || NEED_PKGS+=(docker-ce docker-ce-cli containerd.io)
should_skip 25-nvidia-container-toolkit || NEED_PKGS+=(nvidia-container-toolkit)
should_skip 30-jenkins || NEED_PKGS+=(jenkins fontconfig libharfbuzz0b python3-bcrypt)
should_skip 40-nodejs || NEED_PKGS+=(nodejs)
should_skip 35-microsoft-edge || NEED_PKGS+=(microsoft-edge-stable)
if [[ "$REQUIRE_X11VNC" -eq 1 ]] && ! should_skip 36-x11vnc-xorg; then
  NEED_PKGS+=(x11vnc xauth)
fi
# Server 上 Gitea / Jenkins 的 <hostname>.local 要 Avahi (Desktop 自带, 不要求); 旧捆绑没有 → --force-fetch
if [[ "$REQUIRE_MDNS" -eq 1 ]] && ! should_skip 12-avahi-mdns && { ! should_skip 30-jenkins || ! should_skip 45-gitea; }; then
  NEED_PKGS+=(avahi-daemon libnss-mdns)
fi

PACKAGES_FILE="$BUNDLE/apt/Packages"
if [[ ! -f "$PACKAGES_FILE" && -f "$BUNDLE/apt/Packages.gz" ]]; then
  PACKAGES_FILE="$(mktemp)"
  gzip -dc "$BUNDLE/apt/Packages.gz" > "$PACKAGES_FILE"
  trap 'rm -f -- "$PACKAGES_FILE"' EXIT
fi

missing=()
for pkg in "${NEED_PKGS[@]}"; do
  if ! awk -v p="$pkg" '
    BEGIN{found=0}
    /^Package: / { cur=$2 }
    /^Package: / && $2==p { found=1; exit }
    END{ exit found?0:1 }
  ' "$PACKAGES_FILE"; then
    missing+=("$pkg")
  fi
done

# 目录类资产
need_dirs=()
missing_dirs=()
jp_errs=()
should_skip 80-unity-cli || need_dirs+=(unity-cli)
should_skip 85-godot || need_dirs+=(godot)
should_skip 45-gitea || need_dirs+=(gitea)
should_skip 37-flclash || need_dirs+=(flclash)
# Jenkins 插件: 目录 + lock + 与请求列表一致 (按 jenkins 同版本解析)
if ! should_skip 30-jenkins; then
  JP="$BUNDLE/jenkins-plugins"
  if [[ ! -d "$JP" ]]; then
    missing_dirs+=("jenkins-plugins/")
  else
    for f in plugins.lock requested.txt jenkins-version; do
      [[ -s "$JP/$f" ]] || missing_dirs+=("jenkins-plugins/$f")
    done
    if [[ -s "$JP/requested.txt" ]]; then
      # shellcheck disable=SC2086
      _want="$(printf '%s\n' $JENKINS_PLUGINS | sort -u | tr '\n' ' ')"
      _have="$(sort -u < "$JP/requested.txt" | tr '\n' ' ')"
      [[ "$_want" == "$_have" ]] || jp_errs+=("jenkins-plugins 请求列表 ($_have) != --jenkins-plugins ($_want)")
    fi
    if [[ -s "$JP/plugins.lock" ]]; then
      # lock 每行 name:version:sha256 (resolve-jenkins-plugins.py, sha256 来自 update center)
      while IFS=: read -r _n _v _s; do
        [[ -n "$_n" ]] || continue
        [[ -n "$_v" && "$_s" =~ ^[0-9a-f]{64}$ ]] || { jp_errs+=("jenkins-plugins/plugins.lock: $_n 缺版本或 sha256 (旧捆绑?)"); continue; }
        if [[ ! -f "$JP/$_n.jpi" ]]; then
          missing_dirs+=("jenkins-plugins/$_n.jpi")
        elif [[ "$(sha256sum "$JP/$_n.jpi" | cut -d' ' -f1)" != "$_s" ]]; then
          jp_errs+=("jenkins-plugins/$_n.jpi sha256 与 plugins.lock 不符")
        fi
      done < "$JP/plugins.lock"
      for _p in $JENKINS_PLUGINS; do
        grep -q "^${_p%%:*}:" "$JP/plugins.lock" || jp_errs+=("jenkins-plugins 缺请求的插件: ${_p%%:*}")
      done
    fi
  fi
fi
# npm prefix: 只要没全部跳过 npm CLI 就需要
need_npm=0
should_skip 50-grok || need_npm=1
should_skip 60-opencode || need_npm=1
should_skip 70-openmausbot || need_npm=1

for d in "${need_dirs[@]+"${need_dirs[@]}"}"; do
  [[ -d "$BUNDLE/$d" ]] || missing_dirs+=("$d/")
done
if ! should_skip 37-flclash && [[ -d "$BUNDLE/flclash" ]]; then
  _fn=""
  [[ -f "$BUNDLE/flclash/deb.name" ]] && _fn="$(tr -d '[:space:]' < "$BUNDLE/flclash/deb.name")"
  if [[ -z "$_fn" || ! -f "$BUNDLE/flclash/$_fn" || ! -f "$BUNDLE/flclash/sha256" ]]; then
    missing_dirs+=("flclash/deb 或 sha256")
  else
    _want="$(tr -d '[:space:]' < "$BUNDLE/flclash/sha256")"
    _have="$(sha256sum "$BUNDLE/flclash/$_fn" | awk '{print $1}')"
    if [[ ! "$_want" =~ ^[0-9a-f]{64}$ ]]; then
      jp_errs+=("flclash/sha256 不是 64 位 hex")
    elif [[ "$_have" != "$_want" ]]; then
      jp_errs+=("flclash/$_fn sha256 与 flclash/sha256 不符")
    elif [[ -f "$BUNDLE/flclash/SHA256SUMS" ]]; then
      _sum="$(awk -v n="$_fn" 'NF>=2 {f=$2; sub(/^\.\//,"",f); if(f==n){print $1; exit}}' "$BUNDLE/flclash/SHA256SUMS")"
      if [[ -n "$_sum" && "$_sum" != "$_want" ]]; then
        jp_errs+=("flclash/sha256 与官方 SHA256SUMS 不符")
      fi
    fi
    # 离线 apt 池也必须能装这个 deb 的 Depends (包本身应出现在 Packages 里)
    if ! awk '
      BEGIN{found=0}
      /^Package: / && (tolower($2)=="flclash") { found=1; exit }
      END{ exit found?0:1 }
    ' "$PACKAGES_FILE"; then
      missing+=("FlClash")
    fi
  fi
fi
# RustDesk (Desktop 默认远程桌面): 钉扎版本的官方 deb + sha256, 且 deb 本身在 apt 池 (依赖闭包随之进池)
if [[ "$REQUIRE_RUSTDESK" -eq 1 ]] && ! should_skip 38-rustdesk; then
  RD="$BUNDLE/rustdesk"
  if [[ ! -d "$RD" ]]; then
    missing_dirs+=("rustdesk/ (2026-11 之前的捆绑没有)")
  else
    _fn="$(tr -d '[:space:]' < "$RD/deb.name" 2>/dev/null || true)"
    _ver="$(tr -d '[:space:]' < "$RD/version" 2>/dev/null || true)"
    _want="$(tr -d '[:space:]' < "$RD/sha256" 2>/dev/null || true)"
    if [[ -z "$_fn" || ! -f "$RD/$_fn" ]]; then
      missing_dirs+=("rustdesk/deb")
    elif [[ ! "$_want" =~ ^[0-9a-f]{64}$ ]]; then
      jp_errs+=("rustdesk/sha256 不是 64 位 hex")
    elif [[ "$(sha256sum "$RD/$_fn" | awk '{print $1}')" != "$_want" ]]; then
      jp_errs+=("rustdesk/$_fn sha256 与 rustdesk/sha256 不符")
    fi
    if [[ -n "$PIN_RUSTDESK" && "$_ver" != "$PIN_RUSTDESK" ]]; then
      jp_errs+=("rustdesk/version=${_ver:-?} != --pin-rustdesk $PIN_RUSTDESK")
    fi
    if ! awk '/^Package: / && $2=="rustdesk" { f=1; exit } END { exit f?0:1 }' "$PACKAGES_FILE"; then
      missing+=("rustdesk")
    fi
  fi
fi
# Grok Bot 桌面版 (Desktop 默认): deb + sha256 一致; grok-bot 和它的每个直接依赖 (任一备选) 都在 apt 池
if [[ "$REQUIRE_GROK_BOT" -eq 1 ]] && ! should_skip 39-grok-bot; then
  GB="$BUNDLE/grok-bot"
  if [[ ! -d "$GB" ]]; then
    missing_dirs+=("grok-bot/ (加入 Grok Bot 之前的旧捆绑; --force-fetch 重建, 或 --no-grok-bot)")
  else
    _fn="$(tr -d '[:space:]' < "$GB/deb.name" 2>/dev/null || true)"
    _ver="$(tr -d '[:space:]' < "$GB/version" 2>/dev/null || true)"
    _want="$(tr -d '[:space:]' < "$GB/sha256" 2>/dev/null || true)"
    if [[ -z "$_fn" || ! -f "$GB/$_fn" ]]; then
      missing_dirs+=("grok-bot/deb")
    elif [[ ! "$_want" =~ ^[0-9a-f]{64}$ ]]; then
      jp_errs+=("grok-bot/sha256 不是 64 位 hex")
    elif [[ "$(sha256sum "$GB/$_fn" | awk '{print $1}')" != "$_want" ]]; then
      jp_errs+=("grok-bot/$_fn sha256 与 grok-bot/sha256 不符")
    fi
    if [[ "$PIN_GROK_BOT" != "latest" && "$_ver" != "$PIN_GROK_BOT" ]]; then
      jp_errs+=("grok-bot/version=${_ver:-?} != --grok-bot-version $PIN_GROK_BOT")
    fi
    _gsha="$(printf '%s' "$GROK_BOT_SHA256" | tr '[:upper:]' '[:lower:]')"
    if [[ -n "$_gsha" && "$_want" != "$_gsha" ]]; then
      jp_errs+=("grok-bot/sha256 != --grok-bot-sha256")
    fi
    # 池里的 grok-bot 版本 + 直接依赖 (Package 或 Provides 命中任一备选即可)
    _gbchk="$(python3 - "$PACKAGES_FILE" "$_ver" <<'GBPY'
import re, sys
paras = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n\n")
have, gb = set(), []
for para in paras:
    f = {}
    for line in para.splitlines():
        m = re.match(r"^([A-Za-z0-9-]+):\s*(.*)$", line)
        if m:
            f[m.group(1)] = m.group(2)
    n = f.get("Package")
    if not n:
        continue
    have.add(n)
    for p in f.get("Provides", "").split(","):
        p = re.sub(r"\(.*?\)", "", p).strip()
        if p:
            have.add(p)
    if n == "grok-bot":
        gb.append(f)
if not gb:
    print("NOPKG"); sys.exit()
want = sys.argv[2]
sel = [f for f in gb if f.get("Version") == want] if want else gb
if not sel:
    print("NOVER " + ",".join(f.get("Version", "?") for f in gb)); sys.exit()
miss = []
for grp in sel[0].get("Depends", "").split(","):
    alts = [re.sub(r"\(.*?\)|:any", "", a).strip() for a in grp.split("|")]
    alts = [a for a in alts if a]
    if alts and not any(a in have for a in alts):
        miss.append("|".join(alts))
# Recommends (libappindicator3-1, 托盘图标): 39-grok-bot.sh 会连同它装; 缺了只告警 (装机退回只装 deb)
rmiss = []
for grp in sel[0].get("Recommends", "").split(","):
    alts = [re.sub(r"\(.*?\)|:any", "", a).strip() for a in grp.split("|")]
    alts = [a for a in alts if a]
    if alts and not any(a in have for a in alts):
        rmiss.append("|".join(alts))
print("MISS " + " ".join(miss) if miss else "OK")
if rmiss:
    print("RECMISS " + " ".join(rmiss))
GBPY
)" || _gbchk="ERR"
    _gbrec="$(sed -n 's/^RECMISS //p' <<<"$_gbchk")"
    _gbchk="$(head -n1 <<<"$_gbchk")"
    if [[ -n "$_gbrec" ]]; then
      echo "warn: apt 池缺 Grok Bot 的 Recommends: $_gbrec (托盘图标可能不显示; --force-fetch 重建可补上)" >&2
    fi
    case "$_gbchk" in
      OK) ;;
      NOPKG) missing+=("grok-bot") ;;
      NOVER*) jp_errs+=("apt 池里 grok-bot 版本是 ${_gbchk#NOVER }, 不是 grok-bot/version=${_ver:-?}") ;;
      MISS*) read -r -a _gbmiss <<< "${_gbchk#MISS }"; missing+=("${_gbmiss[@]}") ;;
      *) jp_errs+=("grok-bot 依赖检查失败") ;;
    esac
  fi
fi
# NVIDIA 驱动 (24-nvidia-driver.sh): 预编译模块必须和同一个内核版本配套, 否则装机会跳过驱动
if ! should_skip 24-nvidia-driver; then
  [[ "$PIN_NVIDIA_DRIVER" =~ ^[0-9]{3,4}$ ]] || die "非法 --nvidia-driver-version: $PIN_NVIDIA_DRIVER"
  NVD="$BUNDLE/nvidia"
  if [[ ! -f "$NVD/driver" || ! -f "$NVD/flavours" ]]; then
    missing_dirs+=("nvidia/{driver,flavours} (加入 NVIDIA 驱动之前的旧捆绑)")
  else
    _nvd="$(tr -d '[:space:]' < "$NVD/driver")"
    if [[ "$_nvd" != "$PIN_NVIDIA_DRIVER" ]]; then
      jp_errs+=("nvidia/driver=$_nvd != --nvidia-driver-version $PIN_NVIDIA_DRIVER")
    else
      # 包 → 池里所有版本
      nv_vers() { awk -v p="$1" '/^Package: /{cur=$2} /^Version: /{ if (cur==p) print $2 }' "$PACKAGES_FILE"; }
      nv_has()  { nv_vers "$1" | grep -qxF "$2"; }
      nv_any()  { [[ -n "$(nv_vers "$1")" ]]; }
      nv_any "nvidia-driver-${PIN_NVIDIA_DRIVER}-open" || missing+=("nvidia-driver-${PIN_NVIDIA_DRIVER}-open")
      nv_any vainfo || missing+=(vainfo)
      _march="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('arch',''))" "$BUNDLE/manifest.json" 2>/dev/null || true)"
      if [[ "${_march:-amd64}" == "amd64" ]]; then
        nv_any intel-media-va-driver-non-free || missing+=(intel-media-va-driver-non-free)
      fi
      _nfl=0
      while read -r _fl _ver _abi _rest; do
        [[ -n "${_fl:-}" ]] || continue
        _nfl=$((_nfl + 1))
        if [[ -z "${_ver:-}" || -z "${_abi:-}" || -n "${_rest:-}" ]]; then
          jp_errs+=("nvidia/flavours 格式错误: $_fl ${_ver:-} ${_abi:-}"); continue
        fi
        _mm="linux-modules-nvidia-${PIN_NVIDIA_DRIVER}-open-$_fl"
        for _p in "$_mm" "linux-modules-nvidia-${PIN_NVIDIA_DRIVER}-open-$_abi" "linux-$_fl" "linux-image-$_fl" "linux-headers-$_fl"; do
          nv_has "$_p" "$_ver" || jp_errs+=("nvidia: $_p 没有版本 $_ver (flavour $_fl 的模块与内核版本不一致)")
        done
        nv_any "linux-image-$_abi" || nv_any "linux-image-unsigned-$_abi" \
          || jp_errs+=("nvidia: 缺内核 linux-image-$_abi (flavour $_fl)")
        # 模块 meta 必须精确依赖同一个内核 ABI 的模块
        _dep="$(awk -v p="$_mm" -v v="$_ver" '/^Package: /{cur=$2; ver=""} /^Version: /{ver=$2} /^Depends: / { if (cur==p && ver==v) { print; exit } }' "$PACKAGES_FILE")"
        [[ "$_dep" == *"linux-modules-nvidia-${PIN_NVIDIA_DRIVER}-open-$_abi (= $_ver)"* ]] \
          || jp_errs+=("nvidia: $_mm $_ver 的依赖不是内核 $_abi")
      done < "$NVD/flavours"
      if [[ "$_nfl" -eq 0 ]]; then
        jp_errs+=("nvidia/flavours 为空: 抓包时没有版本一致的预编译模块 + 内核 (或发行版没有 nvidia-driver-${PIN_NVIDIA_DRIVER}-open); 换 --nvidia-driver-version 或 --no-nvidia-driver")
      fi
      if [[ -n "$NVIDIA_KERNEL_FLAVOUR" ]] && ! grep -q "^${NVIDIA_KERNEL_FLAVOUR} " "$NVD/flavours"; then
        jp_errs+=("nvidia/flavours 没有 --nvidia-kernel-flavour $NVIDIA_KERNEL_FLAVOUR")
      fi
    fi
  fi
fi
if [[ "$need_npm" -eq 1 ]]; then
  [[ -f "$BUNDLE/npm/prefix.tar.gz" ]] || missing_dirs+=("npm/prefix.tar.gz")
fi

# 第三方 apt 源种子 (装完 restore-online-apt 写回; 捆绑内有则全部校验)
# 不按 --skip 裁剪: fetch 总是抓全套, restore 也总是全写回
missing_srcs=()
if [[ ! -d "$BUNDLE/apt-sources/keyrings" || ! -d "$BUNDLE/apt-sources/sources.list.d" ]]; then
  missing_dirs+=("apt-sources/{keyrings,sources.list.d}/")
else
  for f in docker.asc githubcli-archive-keyring.gpg nvidia-container-toolkit.asc \
           jenkins-keyring.asc nodesource.gpg microsoft-edge.gpg; do
    [[ -f "$BUNDLE/apt-sources/keyrings/$f" ]] || missing_srcs+=("apt-sources/keyrings/$f")
  done
  for f in docker.list github-cli.list nvidia-container-toolkit.list \
           jenkins.list nodesource.sources microsoft-edge.sources; do
    [[ -f "$BUNDLE/apt-sources/sources.list.d/$f" ]] || missing_srcs+=("apt-sources/sources.list.d/$f")
  done
fi
if ! should_skip 40-nodejs; then
  if [[ ! -d "$BUNDLE/node" ]] || ! find "$BUNDLE/node" -maxdepth 1 -name 'node-v*-linux-x64.tar.xz' -print -quit | grep -q .; then
    # nodejs deb 已在 NEED_PKGS; tarball 是兜底, 缺也不致命若 deb 在
    :
  fi
fi

# manifest release / pins
mapfile -t meta < <(python3 - "$BUNDLE/manifest.json" "$EXPECT_RELEASE" "$PIN_NODE_MAJOR" "$PIN_GROK" "$PIN_OPENCODE" "$PIN_OPENMAUSBOT" "$PIN_UNITY_CLI" "$PIN_GODOT" "$PIN_GITEA" "$(should_skip 45-gitea && echo 1 || echo 0)" "$(should_skip 37-flclash && echo 1 || echo 0)" <<'PY'
import json, os, sys
path, expect_rel, node, grok, oc, om, unity, godot, gitea, gitea_skip, flclash_skip = sys.argv[1:12]
m = json.load(open(path, encoding="utf-8"))
errs = []
rel = str(m.get("release") or "")
if expect_rel and rel and rel != expect_rel:
    errs.append(f"manifest.release={rel} != ISO/期望 {expect_rel}")
pins = m.get("pins") or {}
checks = [
    ("node_major", node),
    ("grok", grok),
    ("opencode", oc),
    ("openmausbot", om),
]
for k, want in checks:
    have = str(pins.get(k, ""))
    if have and want and have != want:
        errs.append(f"pins.{k}={have} != {want}")
if unity:
    have = str(pins.get("unity_cli") or (m.get("unity_cli") or {}).get("version") or "")
    if have and have != unity:
        errs.append(f"pins.unity_cli={have} != {unity}")
have_g = str(pins.get("godot") or (m.get("godot") or {}).get("version") or "")
if godot and have_g and have_g != godot:
    errs.append(f"pins.godot={have_g} != {godot}")
if gitea_skip != "1":
    gm = m.get("gitea") or {}
    have_pin = str(pins.get("gitea") or "")
    have_ver = str(gm.get("version") or "")
    gdir = os.path.join(os.path.dirname(path), "gitea")
    if not have_pin and not gm:
        errs.append("manifest 无 gitea (旧捆绑, 需 --force 重建)")
    elif gitea and gitea != "latest" and have_ver and have_ver != gitea:
        errs.append(f"gitea.version={have_ver} != {gitea}")
    elif gitea and have_pin and have_pin != gitea and not (have_ver and have_ver == gitea):
        errs.append(f"pins.gitea={have_pin} != {gitea}")
    fn = str(gm.get("filename") or "")
    if os.path.isdir(gdir) and (not fn or not os.path.isfile(os.path.join(gdir, fn)) or not os.path.isfile(os.path.join(gdir, "sha256"))):
        errs.append("gitea/ 缺二进制或 sha256")
if flclash_skip != "1":
    fm = m.get("flclash") or {}
    if not fm and not pins.get("flclash"):
        errs.append("manifest 无 flclash (旧捆绑, 需 --force 重建)")
print(rel or "")
print(m.get("fingerprint") or "")
for e in errs:
    print("ERR:" + e)
PY
)

MANIFEST_REL="${meta[0]:-}"
MANIFEST_FP="${meta[1]:-}"
pin_errs=()
for line in "${meta[@]:2}"; do
  [[ "$line" == ERR:* ]] && pin_errs+=("${line#ERR:}")
done
pin_errs+=("${jp_errs[@]+"${jp_errs[@]}"}")

hint="请用 --force / --force-fetch 重建离线捆绑:
  ./tools/fetch-offline-bundle.sh --release ${EXPECT_RELEASE:-noble} --out $BUNDLE --force"

if [[ ${#missing[@]} -gt 0 || ${#missing_dirs[@]} -gt 0 || ${#missing_srcs[@]} -gt 0 || ${#pin_errs[@]} -gt 0 ]]; then
  {
    echo "离线捆绑不完整或不匹配: $BUNDLE"
    [[ ${#missing[@]} -gt 0 ]] && echo "  apt 缺包: ${missing[*]}"
    [[ ${#missing_dirs[@]} -gt 0 ]] && echo "  缺目录/文件: ${missing_dirs[*]}"
    [[ ${#missing_srcs[@]} -gt 0 ]] && echo "  缺 apt-sources: ${missing_srcs[*]}"
    for e in "${pin_errs[@]+"${pin_errs[@]}"}"; do echo "  $e"; done
    echo "  $hint"
  } >&2
  exit 1
fi

ok "offline-bundle 校验通过 (release=${MANIFEST_REL:-?} fp=${MANIFEST_FP:-none})"
