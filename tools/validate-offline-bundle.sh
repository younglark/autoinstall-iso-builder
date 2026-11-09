#!/usr/bin/env bash
# validate-offline-bundle.sh — 构建前检查离线捆绑是否覆盖当前 software/ 需求
# 用法:
#   ./tools/validate-offline-bundle.sh --bundle DIR [--release noble|jammy|24.04|22.04]
#       [--skip "30 70"] [--pin-node N] [--pin-grok V] ...
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
    -h|--help)
      sed -n '2,6p' "$0"; exit 0 ;;
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
should_skip 30-jenkins || NEED_PKGS+=(jenkins)
should_skip 40-nodejs || NEED_PKGS+=(nodejs)

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
should_skip 80-unity-cli || need_dirs+=(unity-cli)
should_skip 85-godot || need_dirs+=(godot)
# npm prefix: 只要没全部跳过 npm CLI 就需要
need_npm=0
should_skip 50-grok || need_npm=1
should_skip 60-opencode || need_npm=1
should_skip 70-openmausbot || need_npm=1

missing_dirs=()
for d in "${need_dirs[@]+"${need_dirs[@]}"}"; do
  [[ -d "$BUNDLE/$d" ]] || missing_dirs+=("$d/")
done
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
           jenkins-keyring.asc nodesource.gpg; do
    [[ -f "$BUNDLE/apt-sources/keyrings/$f" ]] || missing_srcs+=("apt-sources/keyrings/$f")
  done
  for f in docker.list github-cli.list nvidia-container-toolkit.list \
           jenkins.list nodesource.sources; do
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
mapfile -t meta < <(python3 - "$BUNDLE/manifest.json" "$EXPECT_RELEASE" "$PIN_NODE_MAJOR" "$PIN_GROK" "$PIN_OPENCODE" "$PIN_OPENMAUSBOT" "$PIN_UNITY_CLI" "$PIN_GODOT" <<'PY'
import json, sys
path, expect_rel, node, grok, oc, om, unity, godot = sys.argv[1:9]
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
