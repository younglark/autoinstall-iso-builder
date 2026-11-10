#!/usr/bin/env bash
# validate-offline-bundle.sh — 构建前检查离线捆绑是否覆盖当前 software/ 需求
# 用法:
#   ./tools/validate-offline-bundle.sh --bundle DIR [--release noble|jammy|24.04|22.04]
#       [--skip "30 70"] [--pin-node N] [--pin-grok V] [--jenkins-plugins "a b"] ...
#       [--require-x11vnc]   (build-iso --x11vnc 时: 捆绑里必须有 x11vnc + xauth)
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
PIN_FLCLASH="${PIN_FLCLASH:-latest}"
REQUIRE_X11VNC=0
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
    --pin-flclash) PIN_FLCLASH="$2"; shift 2 ;;
    --jenkins-plugins) JENKINS_PLUGINS="$2"; shift 2 ;;
    --require-x11vnc) REQUIRE_X11VNC=1; shift ;;
    -h|--help)
      sed -n '2,7p' "$0"; exit 0 ;;
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
mapfile -t meta < <(python3 - "$BUNDLE/manifest.json" "$EXPECT_RELEASE" "$PIN_NODE_MAJOR" "$PIN_GROK" "$PIN_OPENCODE" "$PIN_OPENMAUSBOT" "$PIN_UNITY_CLI" "$PIN_GODOT" "$PIN_GITEA" "$(should_skip 45-gitea && echo 1 || echo 0)" "$PIN_FLCLASH" "$(should_skip 37-flclash && echo 1 || echo 0)" <<'PY'
import json, os, sys
path, expect_rel, node, grok, oc, om, unity, godot, gitea, gitea_skip, flclash, flclash_skip = sys.argv[1:13]
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
    have_pin = str(pins.get("flclash") or "")
    have_ver = str(fm.get("version") or "")
    fdir = os.path.join(os.path.dirname(path), "flclash")
    if not have_pin and not fm:
        errs.append("manifest 无 flclash (旧捆绑, 需 --force 重建)")
    elif flclash and flclash != "latest" and have_ver and have_ver != flclash:
        errs.append(f"flclash.version={have_ver} != {flclash}")
    elif flclash and have_pin and have_pin != flclash and not (have_ver and have_ver == flclash):
        errs.append(f"pins.flclash={have_pin} != {flclash}")
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
