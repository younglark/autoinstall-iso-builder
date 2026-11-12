#!/usr/bin/env bash
# =============================================================================
# fetch-offline-bundle.sh — 为指定 Ubuntu 发行版构建「全离线」软件包捆绑
#
# 产出目录结构:
#   <out>/
#     manifest.json
#     apt/                 # file:/ apt 源 (Packages + *.deb)
#     apt-sources/         # 第三方 keyring + .list/.sources (装完写回, 供联网更新)
#     npm/prefix.tar.gz    # 预装的全局 npm 树 (解压到 /usr/local)
#     node/                # 官方 Node tarball (nodesource 失败时的兜底)
#     unity-cli/           # Unity CLI 二进制 + version/sha256（不含 Editor）
#     godot/               # Godot 4.7.2 Linux x86_64 zip + sha512（不含 export templates）
#     gitea/               # Gitea linux-amd64 二进制 + version/sha256 (官方 dl.gitea.com 校验和)
#     flclash/             # FlClash linux .deb + version/sha256 (官方 GitHub Release SHA256SUMS)
#     rustdesk/            # RustDesk linux .deb (钉扎版本) + version/sha256 (官方 GitHub Release digest)
#     grok-bot/            # Grok Bot 桌面版 .deb + version/sha256/url (发布 feed + 签名 apt 索引); 依赖闭包在 apt/
#     nvidia/              # driver (分支号) + flavours ("<flavour> <模块/内核 meta 版本> <内核 ABI>"/行);
#                          # 对应 deb (驱动 + 预编译模块 + 同版本内核) 在 apt/ 池里
#     package-list.txt
#
# 依赖: docker (推荐), 宿主机 node/npm (打 npm 包)。无 docker 时退出并提示。
#
# apt 解析方式 (--apt-runner / 环境变量 AIB_APT_RUNNER):
#   docker  默认。宿主机 `docker run ubuntu:<release>` 解析依赖闭包 (Linux 原生用法不变)
#   direct  已在「同发行版 + 同架构」的一次性容器里 (如 builder 镜像), 直接在本容器跑 apt,
#           不需要 docker-in-docker。只允许在容器内使用 (会改写本机 /etc/apt)。
#
# 避免重复下载 (--force 也适用):
#   * apt deb: 先按「空缓存」解析出本次需要的全部 deb (文件名 + 大小 + 索引哈希),
#     再从本地 deb 缓存 (默认 cache/apt-archives/<release>-<arch>/) 和旧捆绑 apt/ 里
#     把「文件名、大小相同且哈希与 Packages 索引一致」的放进 apt 的 archives 目录 (apt 跳过下载前
#     还会按索引里最强的哈希再校验一次),
#     apt 只下载缺的。新下的 deb 回写缓存。缓存默认只增不删 (--prune-apt-cache 清掉本次不用的)。
#   * Unity CLI / Gitea / Godot / FlClash / RustDesk / Grok Bot / Jenkins 插件 / Node tarball: 版本不变且校验和一致时复用旧捆绑里的文件。
#   指纹只描述捆绑内容/参数, 与缓存无关。
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

RELEASE="noble"          # jammy|noble
ARCH="amd64"
OUT=""
PACKAGES=""
CACHE_ROOT="${OFFLINE_CACHE_ROOT:-$ROOT/cache/offline-bundles}"
APT_CACHE="${AIB_APT_CACHE:-}"   # 空 = <cache-root 的上级>/apt-archives/<release>-<arch>
NO_APT_CACHE=0
PRUNE_APT_CACHE=0
PIN_NODE_MAJOR="${PIN_NODE_MAJOR:-24}"
PIN_GROK="${PIN_GROK:-latest}"
PIN_OPENCODE="${PIN_OPENCODE:-latest}"
PIN_OPENMAUSBOT="${PIN_OPENMAUSBOT:-latest}"
PIN_UNITY_CLI="${PIN_UNITY_CLI:-}"
PIN_GITEA="${PIN_GITEA:-latest}"
PIN_RUSTDESK="${PIN_RUSTDESK:-}"   # 空 = tools/rustdesk-release.sh 的 RUSTDESK_DEFAULT_VERSION
# NVIDIA 驱动 (24-nvidia-driver.sh): 分支号; 空 flavours = 按发行版默认 (HWE + GA 两套内核)
PIN_NVIDIA_DRIVER="${PIN_NVIDIA_DRIVER:-595}"
NVIDIA_KERNEL_FLAVOURS="${NVIDIA_KERNEL_FLAVOURS:-}"
NO_NVIDIA_DRIVER=0
# Grok Bot 桌面版 (39-grok-bot.sh): latest = 发布 feed 当前版本; URL + sha256 完全钉扎
PIN_GROK_BOT="${PIN_GROK_BOT:-latest}"
GROK_BOT_DEB_URL="${GROK_BOT_DEB_URL:-}"
GROK_BOT_SHA256="${GROK_BOT_SHA256:-}"
NO_GROK_BOT=0
BUNDLE_EDITION="all"   # --edition: all (默认) | desktop | server; server 默认不抓 Grok Bot
JENKINS_PLUGINS="${JENKINS_PLUGINS:-workflow-aggregator git gitea docker-workflow credentials-binding timestamper rebuild ansicolor docker-plugin parameterized-trigger}"
# Jenkins 插件解析器 (纯 Python 标准库; 与 software/30-jenkins.sh 在线路径同一份)
RESOLVER="$SCRIPT_DIR/resolve-jenkins-plugins.py"
RESOLVER_SHA="$(sha256sum "$RESOLVER" 2>/dev/null | cut -c1-16)"
SKIP_NPM=0
FORCE=0
APT_RUNNER="${AIB_APT_RUNNER:-docker}"
# 默认清华源 https (含 -security)。缺 CA 时先走 http 装 ca-certificates 再切回 https。UBUNTU_MIRROR / --ubuntu-mirror 覆盖。
# 非 amd64/i386 在参数解析后改用 ubuntu-ports (见下方)。
UBUNTU_MIRROR="${UBUNTU_MIRROR:-}"

usage() {
  cat <<'USAGE'
用法:
  ./tools/fetch-offline-bundle.sh --release noble|jammy --out DIR [选项]

选项:
  --release NAME        jammy (22.04) 或 noble (24.04), 默认 noble
  --arch ARCH           默认 amd64
  --out DIR             输出目录 (建议 cache/offline-bundles/noble-amd64)
  --packages "a,b,c"    额外 apt 包 (与 build-iso --packages 对齐)
  --cache-root DIR      捆绑缓存根目录, 默认 ./cache/offline-bundles
  --pin-node N          Node 主版本, 默认 24
  --pin-grok VER        默认 latest
  --pin-opencode VER    npm 版 @opencode/cli (OpenCode 2.x), 默认 latest
  --pin-openmausbot VER 默认 latest
  --pin-unity-cli VER   Unity CLI 版本 (默认拉 latest/latest-beta)
  --pin-gitea VER       Gitea 版本 (默认 latest, 由 dl.gitea.com/gitea/version.json 解析)
  --pin-rustdesk VER    RustDesk 版本 (默认 tools/rustdesk-release.sh 的 RUSTDESK_DEFAULT_VERSION)
  --jenkins-plugins "a b"
                        预装 Jenkins 插件 (按捆绑里同一 Jenkins 版本的 update center 解析全部必需依赖)
                        默认: workflow-aggregator git gitea docker-workflow credentials-binding timestamper rebuild ansicolor docker-plugin parameterized-trigger
  --nvidia-driver-version N
                        NVIDIA 驱动分支, 默认 595 (PIN_NVIDIA_DRIVER)。捆绑 nvidia-driver-N-open、
                        预编译签名模块 meta 和同版本内核 meta (版本一致才收), 以及 Intel VA-API
  --nvidia-kernel-flavours "a b"
                        内核 flavour, 默认 noble: "generic-hwe-24.04 generic", jammy: "generic-hwe-22.04 generic"
  --no-nvidia-driver    不捆绑 NVIDIA 驱动 / 内核 (配合 build-iso --no-nvidia-driver)
  --grok-bot-version V  Grok Bot 桌面版版本, 默认 latest (发布 feed 当前版本; PIN_GROK_BOT)
  --grok-bot-url URL    完全钉扎 Grok Bot .deb URL (必须同时给 --grok-bot-sha256)
  --grok-bot-sha256 H   Grok Bot .deb 期望 sha256
  --no-grok-bot         不捆绑 Grok Bot (配合 build-iso --no-grok-bot)
  --edition E           捆绑给哪个版本用: all (默认, 同 desktop) | desktop | server。
                        server 时默认不抓 Grok Bot (只在 Desktop 安装); build-iso 自动传当前 edition。
                        server 构建遇到已带 grok-bot 的捆绑 (desktop 抓的) 仍直接复用
  --ubuntu-mirror URL   抓包时的 Ubuntu 源; 默认清华
                        https://mirrors.tuna.tsinghua.edu.cn/ubuntu
                        (非 amd64/i386 默认 .../ubuntu-ports)。含 -security。
                        清华 http 会升为 https; 其它 URL 原样使用
  --skip-npm            不打包 npm 全局树 (调试用)
  --apt-runner R        docker (默认) | direct (仅限容器内, 见脚本头注释)
  --force               忽略已有 manifest/fingerprint, 强制重建 (参数变更或缺件时需 --force);
                        仍会复用缓存/旧捆绑里 sha256 一致的 deb 等文件, 只下载变化的
  --apt-cache DIR       本地 deb 缓存目录, 默认 <cache-root>/../apt-archives/<release>-<arch>
                        (默认即 cache/apt-archives/noble-amd64; 环境变量 AIB_APT_CACHE)
  --no-apt-cache        不读写 deb 缓存 (旧捆绑 apt/ 仍会复用)
  --prune-apt-cache     抓完后删掉缓存里本次没用到的 deb (默认不删)
USAGE
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --packages) PACKAGES="$2"; shift 2 ;;
    --cache-root) CACHE_ROOT="$2"; shift 2 ;;
    --pin-node) PIN_NODE_MAJOR="$2"; shift 2 ;;
    --pin-grok) PIN_GROK="$2"; shift 2 ;;
    --pin-opencode) PIN_OPENCODE="$2"; shift 2 ;;
    --pin-openmausbot) PIN_OPENMAUSBOT="$2"; shift 2 ;;
    --pin-unity-cli) PIN_UNITY_CLI="$2"; shift 2 ;;
    --pin-gitea) PIN_GITEA="$2"; shift 2 ;;
    --pin-rustdesk) PIN_RUSTDESK="$2"; shift 2 ;;
    --jenkins-plugins) JENKINS_PLUGINS="$2"; shift 2 ;;
    --nvidia-driver-version) PIN_NVIDIA_DRIVER="$2"; shift 2 ;;
    --nvidia-kernel-flavours|--nvidia-kernel-flavour) NVIDIA_KERNEL_FLAVOURS="$2"; shift 2 ;;
    --no-nvidia-driver) NO_NVIDIA_DRIVER=1; shift ;;
    --grok-bot-version) PIN_GROK_BOT="$2"; shift 2 ;;
    --grok-bot-url) GROK_BOT_DEB_URL="$2"; shift 2 ;;
    --grok-bot-sha256) GROK_BOT_SHA256="$2"; shift 2 ;;
    --no-grok-bot) NO_GROK_BOT=1; shift ;;
    --edition) BUNDLE_EDITION="$2"; shift 2 ;;
    --ubuntu-mirror) UBUNTU_MIRROR="$2"; shift 2 ;;
    --skip-npm) SKIP_NPM=1; shift ;;
    --force) FORCE=1; shift ;;
    --apt-runner) APT_RUNNER="$2"; shift 2 ;;
    --apt-cache) APT_CACHE="$2"; shift 2 ;;
    --no-apt-cache) NO_APT_CACHE=1; shift ;;
    --prune-apt-cache) PRUNE_APT_CACHE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

case "$RELEASE" in
  jammy|noble) ;;
  22.04) RELEASE=jammy ;;
  24.04) RELEASE=noble ;;
  *) die "--release 必须是 jammy|noble (或 22.04|24.04)" ;;
esac

# --ubuntu-mirror / 环境变量 UBUNTU_MIRROR 优先; 未指定时按架构选清华源
if [[ -z "$UBUNTU_MIRROR" ]]; then
  case "$ARCH" in
    amd64|i386) UBUNTU_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu" ;;
    *)          UBUNTU_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports" ;;
  esac
fi
# 清华 http -> https; 用户指定的其它源不动
# shellcheck disable=SC1091
. "$SCRIPT_DIR/ubuntu-mirror.sh"
UBUNTU_MIRROR="$(aib_normalize_mirror "$UBUNTU_MIRROR")"

[[ "$PIN_GITEA" == "latest" || "$PIN_GITEA" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]] \
  || die "非法 --pin-gitea: $PIN_GITEA"
[[ "$PIN_NVIDIA_DRIVER" =~ ^[0-9]{3,4}$ ]] || die "非法 --nvidia-driver-version: $PIN_NVIDIA_DRIVER (如 595)"
if [[ -z "$NVIDIA_KERNEL_FLAVOURS" ]]; then
  case "$RELEASE" in
    noble) NVIDIA_KERNEL_FLAVOURS="generic-hwe-24.04 generic" ;;
    jammy) NVIDIA_KERNEL_FLAVOURS="generic-hwe-22.04 generic" ;;
  esac
fi
NVIDIA_KERNEL_FLAVOURS="$(printf '%s' "$NVIDIA_KERNEL_FLAVOURS" | tr -s '[:space:],' ' ' | sed 's/^ //; s/ $//')"
for _fl in $NVIDIA_KERNEL_FLAVOURS; do
  [[ "$_fl" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || die "非法 --nvidia-kernel-flavours 项: $_fl"
done
# 指纹 / 容器里用: 不捆绑时分支记为 none
NVIDIA_FP_DRIVER="$PIN_NVIDIA_DRIVER"
NVIDIA_FP_FLAVOURS="$NVIDIA_KERNEL_FLAVOURS"
if [[ "$NO_NVIDIA_DRIVER" -eq 1 ]]; then
  NVIDIA_FP_DRIVER="none"; NVIDIA_FP_FLAVOURS=""
fi
# shellcheck disable=SC1091
. "$SCRIPT_DIR/flclash-release.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/rustdesk-release.sh"
[[ -n "$PIN_RUSTDESK" ]] || PIN_RUSTDESK="$RUSTDESK_DEFAULT_VERSION"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/grok-bot-release.sh"
grokbot_valid_version "$PIN_GROK_BOT" || die "非法 --grok-bot-version: $PIN_GROK_BOT"
GROK_BOT_SHA256="$(printf '%s' "$GROK_BOT_SHA256" | tr '[:upper:]' '[:lower:]')"
[[ -z "$GROK_BOT_DEB_URL" ]] || grokbot_valid_url "$GROK_BOT_DEB_URL" || die "非法 --grok-bot-url: $GROK_BOT_DEB_URL"
[[ -z "$GROK_BOT_SHA256" ]] || grokbot_valid_sha256 "$GROK_BOT_SHA256" || die "非法 --grok-bot-sha256"
[[ -z "$GROK_BOT_DEB_URL" || -n "$GROK_BOT_SHA256" ]] || die "--grok-bot-url 必须同时给 --grok-bot-sha256"
case "$BUNDLE_EDITION" in
  all|desktop) ;;
  server)
    if [[ "$NO_GROK_BOT" -ne 1 ]]; then
      NO_GROK_BOT=1
      log "Grok Bot: --edition server, 默认不捆绑 (只在 Desktop 安装)"
    fi
    ;;
  *) die "--edition 必须是 all | desktop | server (got: $BUNDLE_EDITION)" ;;
esac
# 指纹: 不捆绑记为 none; latest 不随 feed 变化 (同 FlClash: 复用已有捆绑, 要新版用 --force)
# "|recommends": 捆绑里含 deb 的 Recommends (libappindicator3-1); 没有它的旧捆绑指纹不同, 需要 --force
GROKBOT_FP="none"
[[ "$NO_GROK_BOT" -eq 1 ]] || GROKBOT_FP="${PIN_GROK_BOT}|${GROK_BOT_DEB_URL}|${GROK_BOT_SHA256}|recommends"
rustdesk_valid_version "$PIN_RUSTDESK" || die "非法 --pin-rustdesk: $PIN_RUSTDESK"
JENKINS_PLUGINS="$(printf '%s' "$JENKINS_PLUGINS" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
[[ -n "$JENKINS_PLUGINS" ]] || die "--jenkins-plugins 不能为空"
for _jp in $JENKINS_PLUGINS; do
  [[ "$_jp" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(:[A-Za-z0-9._-]+)?$ ]] || die "--jenkins-plugins 含非法插件名: $_jp"
done

if [[ -z "$OUT" ]]; then
  OUT="$CACHE_ROOT/${RELEASE}-${ARCH}"
fi
if [[ "$NO_APT_CACHE" -eq 1 ]]; then
  APT_CACHE=""
elif [[ -z "$APT_CACHE" ]]; then
  APT_CACHE="$(dirname -- "$CACHE_ROOT")/apt-archives/${RELEASE}-${ARCH}"
fi

in_container() {
  [[ -f /.dockerenv || -f /run/.containerenv || "${AIB_IN_CONTAINER:-0}" == "1" ]]
}

case "$APT_RUNNER" in
  docker)
    command -v docker >/dev/null || die "需要 docker 来解析目标发行版依赖 (docker pull ubuntu:${RELEASE})。
  macOS/Windows 请用 scripts/aib.sh / scripts/aib.ps1 (容器内 direct 模式)"
    docker info >/dev/null 2>&1 || die "dockerd 不可用: docker info 失败"
    ;;
  direct)
    in_container || die "--apt-runner direct 只能在一次性容器内使用 (会改写 /etc/apt); 宿主机请用默认 docker"
    [[ "$(id -u)" -eq 0 ]] || die "--apt-runner direct 需要 root (容器内 apt-get)"
    # shellcheck disable=SC1091
    HOST_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    [[ "$HOST_CODENAME" == "$RELEASE" ]] || die "direct 模式要求容器发行版与 --release 一致: 容器=$HOST_CODENAME 目标=$RELEASE
  (aib 包装脚本会按 --release 自动选 builder 镜像变体; jammy 用 :<tag>-jammy)"
    HOST_ARCH="$(dpkg --print-architecture)"
    [[ "$HOST_ARCH" == "$ARCH" ]] || die "direct 模式要求容器架构与 --arch 一致: 容器=$HOST_ARCH 目标=$ARCH
  (Apple Silicon 请用 --platform linux/amd64 运行; aib 包装脚本已自动处理)"
    ;;
  *) die "--apt-runner 必须是 docker 或 direct (got: $APT_RUNNER)" ;;
esac

# 计算期望指纹; 已有捆绑指纹一致才复用 (否则提示 --force)
bundle_fp() { # grok_bot 指纹项
  python3 - "$RELEASE" "$ARCH" "$PIN_NODE_MAJOR" "$PIN_GROK" "$PIN_OPENCODE" "$PIN_OPENMAUSBOT" "$PIN_UNITY_CLI" "$PACKAGES" "$PIN_GITEA" "$JENKINS_PLUGINS" "$RESOLVER_SHA" "$PIN_RUSTDESK" "$NVIDIA_FP_DRIVER" "$NVIDIA_FP_FLAVOURS" "$1" <<'FP'
import hashlib, json, sys
payload = {
  "schema": 4,
  "release": sys.argv[1],
  "arch": sys.argv[2],
  "pins": {
    "node_major": sys.argv[3],
    "grok": sys.argv[4],
    "opencode": sys.argv[5],
    "opencode_package": "@opencode/cli",
    "openmausbot": sys.argv[6],
    "unity_cli": sys.argv[7],
    "godot": "4.7.2",
    "gitea": sys.argv[9],
    "flclash": "latest",
    "rustdesk": sys.argv[12],
    "nvidia_driver": sys.argv[13],
    "nvidia_kernel_flavours": sorted(set(sys.argv[14].split())),
    "grok_bot": sys.argv[15],
  },
  "extra_packages": [p for p in sys.argv[8].split(",") if p],
  "jenkins_plugins": sorted(set(sys.argv[10].split())),
  "jenkins_plugin_resolver": sys.argv[11],
  "seeds": [
    "git", "ripgrep", "openssh-server", "gh",
    "docker-ce", "nvidia-container-toolkit", "jenkins", "nodejs",
    "microsoft-edge-stable", "x11vnc", "xauth",
    "unity-cli", "godot", "gitea", "flclash", "rustdesk", "grok-bot", "apt-sources",
    "fontconfig", "libharfbuzz0b", "python3-bcrypt", "jenkins-plugins",
    "nvidia-driver", "intel-media-va-driver-non-free", "vainfo",
    # avahi-daemon / libnss-mdns (Server 上 Gitea / Jenkins 的 <hostname>.local) 故意不进指纹:
    # Desktop 自带, 旧捆绑仍可复用; Server 用旧捆绑时 validate --require-mdns 报缺包 → --force-fetch
  ],
}
print(hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16])
FP
}
expected_fp="$(bundle_fp "$GROKBOT_FP")"

if [[ "$FORCE" -ne 1 && -f "$OUT/manifest.json" && -d "$OUT/apt" ]]; then
  have_fp="$(python3 -c "import json;print(json.load(open('$OUT/manifest.json')).get('fingerprint',''))" 2>/dev/null || true)"
  # 不要 Grok Bot (server / --no-grok-bot) 时, 带 grok-bot 的同参数捆绑 (Desktop 抓的超集) 也可复用:
  # 用 manifest 里记录的 grok_bot 指纹项重算一次, 一致就复用 (多出的 grok-bot/ 在 Server 上不会被装)
  if [[ -n "$have_fp" && "$have_fp" != "$expected_fp" && "$GROKBOT_FP" == "none" ]]; then
    have_gb="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('pins',{}).get('grok_bot',''))" "$OUT/manifest.json" 2>/dev/null || true)"
    if [[ -n "$have_gb" && "$have_gb" != "none" && "$(bundle_fp "$have_gb")" == "$have_fp" ]]; then
      log "已有捆绑多带了 Grok Bot ($have_gb), 本次不需要, 照常复用"
      expected_fp="$have_fp"
    fi
  fi
  if [[ -n "$have_fp" && "$have_fp" == "$expected_fp" ]]; then
    ok "复用已有捆绑 (fingerprint=$have_fp): $OUT ($(du -sh "$OUT" | cut -f1))"
    python3 -c "import json;print(json.dumps(json.load(open('$OUT/manifest.json')),indent=2,ensure_ascii=False))" 2>/dev/null || true
    exit 0
  fi
  if [[ -n "$have_fp" && "$have_fp" != "$expected_fp" ]]; then
    die "离线捆绑指纹不匹配 (have=$have_fp want=$expected_fp)。请加 --force 重建: $OUT"
  fi
  die "离线捆绑缺少 fingerprint (旧格式)。请加 --force 重建: $OUT"
fi

mkdir -p "$OUT" "$CACHE_ROOT"
[[ -n "$APT_CACHE" ]] && mkdir -p "$APT_CACHE"
WORK="$(mktemp -d -t offline-bundle-XXXXXX)"
cleanup() {
  if command -v sudo >/dev/null; then
    sudo rm -rf -- "$WORK" 2>/dev/null || rm -rf -- "$WORK" 2>/dev/null || true
  else
    rm -rf -- "$WORK" 2>/dev/null || true
  fi
}
trap cleanup EXIT

IMG="ubuntu:${RELEASE}"
case "$RELEASE" in
  jammy) IMG="ubuntu:22.04" ;;
  noble) IMG="ubuntu:24.04" ;;
esac

if [[ "$APT_RUNNER" == "docker" ]]; then
  log "拉取/使用镜像 $IMG"
  docker pull "$IMG" >/dev/null
fi

# --------------- 容器内: 配源、下载 deb 闭包、生成 Packages ---------------
cat > "$WORK/fetch-debs.sh" <<'INNER'
#!/bin/bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
RELEASE="$1"
ARCH="$2"
NODE_MAJOR="$3"
MIRROR="$4"
EXTRA_PACKAGES="$5"
OUTDIR="${FETCH_OUTDIR:-/out}"
# deb 复用来源 (可为空): 持久缓存 (可写) 与旧捆绑 apt/ (只读)
APT_CACHE_DIR="${FETCH_APT_CACHE:-}"
PREV_APT_DIR="${FETCH_PREV_APT:-}"
PREV_NODE_DIR="${FETCH_PREV_NODE:-}"
PRUNE_APT_CACHE="${FETCH_PRUNE_APT_CACHE:-0}"
NVIDIA_DRIVER="${FETCH_NVIDIA_DRIVER:-}"          # 空 = 不捆绑
NVIDIA_FLAVOURS="${FETCH_NVIDIA_FLAVOURS:-}"
KEEP_LINUX_FIRMWARE="${FETCH_KEEP_LINUX_FIRMWARE:-0}"
ARCHIVES=/var/cache/apt/archives

echo "== container: $(. /etc/os-release && echo "$PRETTY_NAME") arch=$ARCH =="

# 清华 https 且缺 CA 时, 先走 http 装 ca-certificates 再切回 https
# shellcheck disable=SC1091
if [ -f /ubuntu-mirror.sh ]; then
  . /ubuntu-mirror.sh
elif [ -f "$(dirname "$0")/ubuntu-mirror.sh" ]; then
  . "$(dirname "$0")/ubuntu-mirror.sh"
elif [ -f /opt/aib/tools/ubuntu-mirror.sh ]; then
  . /opt/aib/tools/ubuntu-mirror.sh
else
  echo "ERROR: ubuntu-mirror.sh not found" >&2
  exit 1
fi
# deb 复用 helper (tools/apt-deb-reuse.sh)
# shellcheck disable=SC1091
if [ -f /apt-deb-reuse.sh ]; then
  . /apt-deb-reuse.sh
elif [ -f "$(dirname "$0")/apt-deb-reuse.sh" ]; then
  . "$(dirname "$0")/apt-deb-reuse.sh"
else
  . /opt/aib/tools/apt-deb-reuse.sh
fi
aib_bootstrap_apt_mirror "$RELEASE" "$MIRROR"
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg dpkg-dev apt-utils xz-utils

# 测试钩子 (test/container-x11vnc-reuse.sh): FETCH_MINIMAL_SEEDS="a b" 只用官方源抓这几个包,
# 跳过第三方源 / Node / Jenkins, 用来验证 deb 复用与离线安装。正常抓包不要设置。
if [ -n "${FETCH_MINIMAL_SEEDS:-}" ]; then
  # shellcheck disable=SC2206
  SEEDS=($FETCH_MINIMAL_SEEDS)
else
install -m 0755 -d /etc/apt/keyrings

# Docker CE
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${RELEASE} stable" \
  > /etc/apt/sources.list.d/docker.list

# NVIDIA Container Toolkit (toolkit; GPU driver: 24-nvidia-driver.sh, Ubuntu restricted)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  -o /etc/apt/keyrings/nvidia-container-toolkit.asc
chmod a+r /etc/apt/keyrings/nvidia-container-toolkit.asc
echo "deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.asc] https://nvidia.github.io/libnvidia-container/stable/deb/${ARCH} /" \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list

# GitHub CLI (official; stable/main, not release-codename)
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list

# Jenkins (2026 signing key; 2023 key expired 2026-03-26)
KEY_OK=0
for url in \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key ; do
  if curl -fsSL "$url" -o /etc/apt/keyrings/jenkins-keyring.asc 2>/dev/null; then
    KEY_OK=1; echo "Jenkins key: $url"; break
  fi
done
[ "$KEY_OK" -eq 1 ] || { echo "ERROR: Jenkins key"; exit 1; }
chmod a+r /etc/apt/keyrings/jenkins-keyring.asc
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list

# NodeSource
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/ns.sh
bash /tmp/ns.sh

# Microsoft Edge (官方源仅 amd64)
if [ "$ARCH" = "amd64" ]; then
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc     -o /etc/apt/keyrings/microsoft.asc
  chmod a+r /etc/apt/keyrings/microsoft.asc
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.asc] https://packages.microsoft.com/repos/edge stable main"     > /etc/apt/sources.list.d/microsoft-edge.list
fi

apt-get update

# 导出第三方 apt 源种子: 装机 restore-online-apt.sh 写回 keyring + list/sources
# 与 software/*.sh 在线路径使用同一批 URL/密钥; 捆绑里有的全部写回 (不按 --skip 裁剪)
mkdir -p "$OUTDIR/apt-sources/keyrings" "$OUTDIR/apt-sources/sources.list.d"
cp -a /etc/apt/keyrings/docker.asc \
  /etc/apt/keyrings/nvidia-container-toolkit.asc \
  /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  /etc/apt/keyrings/jenkins-keyring.asc \
  "$OUTDIR/apt-sources/keyrings/"
# Edge: 种子用官方 postinst 格式 (deb822 + /usr/share/keyrings/microsoft-edge.gpg),
# 不要写回 legacy microsoft-edge.list, 否则会与包写入的 .sources 重复。
if [ -f /etc/apt/keyrings/microsoft.asc ]; then
  gpg --dearmor < /etc/apt/keyrings/microsoft.asc     > "$OUTDIR/apt-sources/keyrings/microsoft-edge.gpg"
  chmod 644 "$OUTDIR/apt-sources/keyrings/microsoft-edge.gpg"
fi
# NodeSource 官方 setup 落在 /usr/share/keyrings + deb822 .sources
cp -a /usr/share/keyrings/nodesource.gpg "$OUTDIR/apt-sources/keyrings/"
cp -a /etc/apt/sources.list.d/docker.list \
  /etc/apt/sources.list.d/nvidia-container-toolkit.list \
  /etc/apt/sources.list.d/github-cli.list \
  /etc/apt/sources.list.d/jenkins.list \
  /etc/apt/sources.list.d/nodesource.sources \
  "$OUTDIR/apt-sources/sources.list.d/"
if [ "$ARCH" = "amd64" ]; then
  cat > "$OUTDIR/apt-sources/sources.list.d/microsoft-edge.sources" <<'ESR'
### THIS FILE IS AUTOMATICALLY CONFIGURED ###
# Changes to this file will not be preserved.
# This file will not be recreated if removed.
X-Repolib-Name: Microsoft Edge
Types: deb
URIs: https://packages.microsoft.com/repos/edge-stable
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/microsoft-edge.gpg
ESR
fi
cat > "$OUTDIR/apt-sources/README.txt" <<'ASR'
Third-party apt keyrings + sources captured at fetch time.
restore-online-apt.sh copies every seed here onto the installed system after
leaving offline mode (Docker CE, GitHub CLI, NVIDIA container toolkit,
Jenkins, NodeSource, Microsoft Edge). Online installs never use this directory.
ASR
ls -la "$OUTDIR/apt-sources/keyrings" "$OUTDIR/apt-sources/sources.list.d"

JAVA_PKG=""
for p in openjdk-21-jre-headless openjdk-17-jre-headless; do
  if apt-cache show "$p" >/dev/null 2>&1; then JAVA_PKG="$p"; break; fi
done
[ -n "$JAVA_PKG" ] || { echo "ERROR: no suitable OpenJDK"; exit 1; }

# seed: 预装栈 + base 工具 + 用户 packages
# shellcheck disable=SC2206
SEEDS=(
  ca-certificates curl gnupg jq git ripgrep unzip lsb-release apt-transport-https
  openssh-server
  gh
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  nvidia-container-toolkit
  "$JAVA_PKG" jenkins fontconfig libharfbuzz0b python3-bcrypt
  nodejs
  x11vnc xauth
  avahi-daemon libnss-mdns
)
# Microsoft Edge 仅 amd64; 非 amd64 跳过以免 apt 解析失败
if [ "$ARCH" = "amd64" ]; then
  SEEDS+=(microsoft-edge-stable)
fi
fi  # FETCH_MINIMAL_SEEDS
IFS=',' read -r -a EXTRA <<< "$EXTRA_PACKAGES"
for p in "${EXTRA[@]}"; do
  p="$(echo "$p" | xargs)"
  [ -n "$p" ] && SEEDS+=("$p")
done

# FlClash 官方 deb (宿主机已校验): 声明依赖并入种子, 稍后把 deb 本身放进 apt 池
FLCLASH_DEB=""
FLCLASH_IN="${FETCH_FLCLASH_DIR:-/flclash-in}"
if [ -z "${FETCH_MINIMAL_SEEDS:-}" ] && [ -d "$FLCLASH_IN" ]; then
  for _f in "$FLCLASH_IN"/FlClash-*-linux-*.deb; do
    [ -f "$_f" ] || continue
    FLCLASH_DEB="$_f"
    break
  done
fi
if [ -n "$FLCLASH_DEB" ]; then
  echo "FlClash local deb: $FLCLASH_DEB ($(dpkg-deb -f "$FLCLASH_DEB" Package) $(dpkg-deb -f "$FLCLASH_DEB" Version))"
  # 声明依赖 (libayatana-appindicator3-1, libsecret-1-0, …) 并入 SEEDS, 走复用/递归闭包
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    SEEDS+=("$_d")
  done < <(dpkg-deb -f "$FLCLASH_DEB" Depends 2>/dev/null | tr ',' '\n' | while IFS= read -r dep; do
    first="${dep%%|*}"
    first="$(printf '%s' "$first" | sed 's/([^)]*)//g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$first" ] && printf '%s\n' "$first"
  done)
fi

# RustDesk 官方 deb (宿主机已校验): 同 FlClash, Depends 并入种子 (libxdo3, gstreamer1.0-pipewire, …)
RUSTDESK_DEB=""
RUSTDESK_IN="${FETCH_RUSTDESK_DIR:-/rustdesk-in}"
if [ -z "${FETCH_MINIMAL_SEEDS:-}" ] && [ -d "$RUSTDESK_IN" ]; then
  for _f in "$RUSTDESK_IN"/rustdesk-*.deb; do
    [ -f "$_f" ] || continue
    RUSTDESK_DEB="$_f"
    break
  done
fi
if [ -n "$RUSTDESK_DEB" ]; then
  echo "RustDesk local deb: $RUSTDESK_DEB ($(dpkg-deb -f "$RUSTDESK_DEB" Package) $(dpkg-deb -f "$RUSTDESK_DEB" Version))"
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    SEEDS+=("$_d")
  done < <(dpkg-deb -f "$RUSTDESK_DEB" Depends 2>/dev/null | tr ',' '\n' | while IFS= read -r dep; do
    first="${dep%%|*}"
    first="$(printf '%s' "$first" | sed 's/([^)]*)//g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$first" ] && printf '%s\n' "$first"
  done)
fi
# Grok Bot 官方 deb (宿主机已校验): 同 FlClash, Depends 并入种子 (libgtk-3-0, libnss3, libsecret-1-0, …)
GROKBOT_DEB=""
GROKBOT_RECS=()
GROKBOT_IN="${FETCH_GROKBOT_DIR:-/grok-bot-in}"
if [ -z "${FETCH_MINIMAL_SEEDS:-}" ] && [ -d "$GROKBOT_IN" ]; then
  for _f in "$GROKBOT_IN"/*.deb; do
    [ -f "$_f" ] || continue
    GROKBOT_DEB="$_f"
    break
  done
fi
if [ -n "$GROKBOT_DEB" ]; then
  echo "Grok Bot local deb: $GROKBOT_DEB ($(dpkg-deb -f "$GROKBOT_DEB" Package) $(dpkg-deb -f "$GROKBOT_DEB" Version))"
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    SEEDS+=("$_d")
  done < <(dpkg-deb -f "$GROKBOT_DEB" Depends 2>/dev/null | tr ',' '\n' | while IFS= read -r dep; do
    first="${dep%%|*}"
    first="$(printf '%s' "$first" | sed 's/([^)]*)//g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$first" ] && printf '%s\n' "$first"
  done)
  # Recommends (libappindicator3-1, 托盘图标) 也进捆绑; 已有种子 Provides 它则不另收真包
  # (FlClash 的 libayatana-appindicator3-1 Provides 且 Conflicts libappindicator3-1)
  # shellcheck disable=SC1091
  if [ -f /grok-bot-release.sh ]; then
    . /grok-bot-release.sh
  elif [ -f "$(dirname "$0")/grok-bot-release.sh" ]; then
    . "$(dirname "$0")/grok-bot-release.sh"
  else
    echo "ERROR: 找不到 grok-bot-release.sh (无法处理 Grok Bot Recommends)" >&2
    exit 1
  fi
  GROKBOT_RECS=()
  while IFS= read -r _r; do
    [ -n "$_r" ] || continue
    GROKBOT_RECS+=("$_r"); SEEDS+=("$_r")
  done < <(grokbot_seed_recommends "$GROKBOT_DEB" "${SEEDS[@]}")
  echo "Grok Bot Recommends 捆绑: ${GROKBOT_RECS[*]:-(无)}"
fi
# NVIDIA 驱动 + Canonical 预编译签名模块 + 同版本内核 (24-nvidia-driver.sh 离线路径)
# 每个 flavour: 模块 meta 的版本必须能找到同版本的 linux-<flavour> / linux-image-<flavour> /
# linux-headers-<flavour>, 否则不收这个 flavour (装机时会按 "版本不匹配" 跳过)。
# 种子写成 pkg=ver 锁定版本; 记录到 nvidia/flavours 供 validate 和装机核对。
NV_SEEDS=()
if [ -z "${FETCH_MINIMAL_SEEDS:-}" ] && [ -n "$NVIDIA_DRIVER" ]; then
  nv_cand() { apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}' | grep -v '^(none)$' || true; }
  nv_has()  { apt-cache madison "$1" 2>/dev/null | awk -F'|' '{gsub(/[[:space:]]/,"",$2); print $2}' | grep -qxF "$2"; }
  mkdir -p "$OUTDIR/nvidia"
  printf '%s\n' "$NVIDIA_DRIVER" > "$OUTDIR/nvidia/driver"
  : > "$OUTDIR/nvidia/flavours"
  if [ -n "$(nv_cand "nvidia-driver-${NVIDIA_DRIVER}-open")" ]; then
    NV_SEEDS+=("nvidia-driver-${NVIDIA_DRIVER}-open" nvidia-settings nvidia-prime vainfo)
    [ "$ARCH" = "amd64" ] && NV_SEEDS+=(intel-media-va-driver-non-free)
    for _fl in $NVIDIA_FLAVOURS; do
      _mm="linux-modules-nvidia-${NVIDIA_DRIVER}-open-${_fl}"
      _mv="$(nv_cand "$_mm")"
      if [ -z "$_mv" ]; then echo "WARN: nvidia: 没有 $_mm, 跳过 flavour $_fl"; continue; fi
      _abi="$(apt-cache show "$_mm=$_mv" 2>/dev/null | sed -n 's/^Depends: //p' | head -1 | tr ',' '\n' \
        | sed -n "s/^[[:space:]]*linux-modules-nvidia-${NVIDIA_DRIVER}-open-\([0-9][^ (]*\).*/\1/p" | head -1)"
      if [ -z "$_abi" ]; then echo "WARN: nvidia: 读不出 $_mm $_mv 的内核 ABI, 跳过 flavour $_fl"; continue; fi
      if nv_has "linux-$_fl" "$_mv" && nv_has "linux-image-$_fl" "$_mv" && nv_has "linux-headers-$_fl" "$_mv"; then
        NV_SEEDS+=("$_mm=$_mv" "linux-modules-nvidia-${NVIDIA_DRIVER}-open-$_abi=$_mv"
                   "linux-$_fl=$_mv" "linux-image-$_fl=$_mv" "linux-headers-$_fl=$_mv")
        printf '%s %s %s\n' "$_fl" "$_mv" "$_abi" >> "$OUTDIR/nvidia/flavours"
        echo "nvidia: flavour $_fl → 模块/内核 meta $_mv, 内核 $_abi"
      else
        echo "WARN: nvidia: $_mm=$_mv 没有同版本的 linux-$_fl / linux-image-$_fl / linux-headers-$_fl, 跳过 flavour $_fl"
      fi
    done
  else
    echo "WARN: nvidia: $RELEASE 没有 nvidia-driver-${NVIDIA_DRIVER}-open, 不捆绑 NVIDIA 驱动"
  fi
  SEEDS+=("${NV_SEEDS[@]}")
fi

echo "seed packages (${#SEEDS[@]}): ${SEEDS[*]}"
# apt-cache depends 不认 pkg=ver: 递归依赖按包名解析 (锁定版本就是当前候选)
SEED_NAMES=()
for _s in "${SEEDS[@]}"; do SEED_NAMES+=("${_s%%=*}"); done

# ---- deb 复用: 先按空 archives 解析出本次需要的全部文件 (名 + 大小 + 索引哈希) ----
NEED_LIST="$(mktemp)"
SEED_URIS="$(mktemp)"
CLOSURE_NAMES="$(mktemp)"
KDROP_LIST="$(mktemp)"
EMPTY_ARCH="$(mktemp -d)"
mkdir -p "$EMPTY_ARCH/partial"
# 输出格式: 'URI' 文件名 大小 SHA256:hex
print_uris() {
  apt-get -qq -y --print-uris -o Dir::Cache::archives="$EMPTY_ARCH" "$@" 2>/dev/null \
    | awk -F"'" 'NF>=3 {print $3}' | awk 'NF>=3 {print $1, $2, $3}'
}

# SEEDS 的求解器闭包 (pkg=ver 锁版本, 与下面实际下载同一事务): 内核类包以它为准。
# 容器里没装任何内核, 所以闭包里的内核类包就是选定 flavour (generic / generic-hwe-*) 及其 ABI 需要的全部。
print_uris install --download-only --reinstall "${SEEDS[@]}" > "$SEED_URIS" \
  || print_uris install --download-only "${SEEDS[@]}" > "$SEED_URIS" || true
aib_deb_pkg_name < "$SEED_URIS" | sort -u > "$CLOSURE_NAMES"

# 已装在容器里的依赖 (如 libcurl4t64) 不会因 --reinstall SEEDS 而被重新下载,
# 导致离线池缺依赖: curl_X 需要 libcurl4t64(=X) 但池里没有。强制把递归 Depends 也 download。
mapfile -t _dep_pkgs < <(
  apt-cache depends --recurse --no-recommends --no-suggests \
    --no-conflicts --no-breaks --no-replaces --no-enhances \
    "${SEED_NAMES[@]}" 2>/dev/null \
    | awk '/^[A-Za-z0-9]/{print $1}' | sort -u \
    | aib_kernel_filter "$CLOSURE_NAMES" "$KDROP_LIST"
)
if [ -s "$KDROP_LIST" ]; then
  echo "递归依赖里不属于选定内核 flavour 的内核类包: 跳过 $(wc -l < "$KDROP_LIST") 个 (aws/azure/gcp/oracle/lowlatency/… 及其 NVIDIA 预编译模块)"
fi
# 分两类 (都要下载; 区别只在用不用求解器):
#   _dl     求解器闭包里的 / 容器里已装的: 彼此可共存, 照旧 install --download-only --reinstall 分批
#           (同时带上它们的 Recommends, 与原来一致)
#   _dl_alt 只因 "A | B" 替代 / 虚包 Provides 被递归带进来、求解器没选的 (elogind / libpam-elogind /
#           dbus-broker / systemd-standalone-sysusers / dkms 工具链 …): 用 apt-get download 直接取文件,
#           不进事务 —— 原来它们和 systemd 等放在同一批里互斥, 整批失败再逐个回退 (polkitd 的
#           default-logind | logind …), 日志全是噪声; 结果文件不变。
_inst_names="$(mktemp)"
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk '$1 ~ /^ii/ {print $2}' | sort -u > "$_inst_names"
_dl=(); _dl_alt=()
for _p in "${_dep_pkgs[@]}"; do
  # linux-firmware* (~600MB) 不进捆绑: 目标机装机时已带 linux-firmware, 内核 meta 的依赖不带版本约束
  case "$_p" in linux-firmware|linux-firmware-*) [ "$KEEP_LINUX_FIRMWARE" = "1" ] || continue ;; esac
  # 跳过虚拟包 / 不存在的名字
  apt-cache show "$_p" >/dev/null 2>&1 || continue
  if grep -qxF -- "$_p" "$CLOSURE_NAMES" || grep -qxF -- "$_p" "$_inst_names"; then
    _dl+=("$_p")
  else
    _dl_alt+=("$_p")
  fi
done
rm -f "$_inst_names"
# 解析阶段: SEEDS 闭包 + 递归依赖 (与下面实际下载同样的分批/逐个回退)
{
  cat "$SEED_URIS"
  _j=0
  while [ "$_j" -lt "${#_dl[@]}" ]; do
    _c=("${_dl[@]:_j:40}")
    if ! print_uris install --download-only --reinstall "${_c[@]}"; then
      for _q in "${_c[@]}"; do print_uris download "$_q" || true; done
    fi
    _j=$((_j + 40))
  done
  _j=0
  while [ "$_j" -lt "${#_dl_alt[@]}" ]; do
    _c=("${_dl_alt[@]:_j:40}")
    if ! print_uris download "${_c[@]}"; then
      for _q in "${_c[@]}"; do print_uris download "$_q" || true; done
    fi
    _j=$((_j + 40))
  done
} | sort -u -k1,1 > "$NEED_LIST"
rm -rf "$EMPTY_ARCH"
echo "deb 需求: $(wc -l < "$NEED_LIST") 个文件"

REUSED_LIST="$(mktemp)"
_reused=0
if [ -n "$APT_CACHE_DIR$PREV_APT_DIR" ]; then
  _reused="$(aib_deb_seed "$NEED_LIST" "$ARCHIVES" "$REUSED_LIST" "$APT_CACHE_DIR" "$PREV_APT_DIR")"
fi
echo "deb 复用 (缓存/旧捆绑, 大小+索引哈希一致): $_reused"
# 复用的文件已在 archives: 下面的 apt 下载会按索引哈希确认并跳过

# 下载完整依赖闭包到 archives (容器极简, 几乎全部会下; 已复用的跳过)
apt-get install -y --download-only --reinstall -o Dir::Cache::archives=/var/cache/apt/archives \
  "${SEEDS[@]}" || apt-get install -y --download-only -o Dir::Cache::archives=/var/cache/apt/archives \
  "${SEEDS[@]}"

if [ "${#_dl[@]}" -gt 0 ]; then
  echo "force-download ${#_dl[@]} recursive depends (incl. already-installed)"
  # 分批, 避免命令行过长; 失败不致命 (个别过渡包可忽略)
  _i=0
  while [ "$_i" -lt "${#_dl[@]}" ]; do
    _chunk=("${_dl[@]:_i:40}")
    if ! apt-get install -y --download-only --reinstall \
      -o Dir::Cache::archives=/var/cache/apt/archives \
      "${_chunk[@]}"; then
      # 批内都是可共存的包, 正常不会失败; 兜底逐个 apt-get download (不解析依赖, 不会冲突)
      echo "chunk failed; per-package download fallback (${#_chunk[@]})"
      ( cd /var/cache/apt/archives && for _q in "${_chunk[@]}"; do
          apt-get download -q -o APT::Sandbox::User=root "$_q" >/dev/null 2>&1 || echo "  skip: $_q"
        done )
    fi
    _i=$((_i + 40))
  done
fi
if [ "${#_dl_alt[@]}" -gt 0 ]; then
  echo "download ${#_dl_alt[@]} alternative-only recursive depends (apt-get download, no resolver)"
  # 已在 archives 的 (复用或已下载, 大小+哈希一致) apt-get download 会直接跳过
  _i=0
  while [ "$_i" -lt "${#_dl_alt[@]}" ]; do
    _alt=("${_dl_alt[@]:_i:40}")
    if ! ( cd /var/cache/apt/archives && apt-get download -q -o APT::Sandbox::User=root "${_alt[@]}" >/dev/null 2>&1 ); then
      # 批内个别名字无候选 (只剩旧版本 / 被 pin 掉) 时整批失败: 逐个下载
      echo "batch download failed; per-package download fallback (${#_alt[@]})"
      ( cd /var/cache/apt/archives && for _q in "${_alt[@]}"; do
          apt-get download -q -o APT::Sandbox::User=root "$_q" >/dev/null 2>&1 || echo "  skip: $_q"
        done )
    fi
    _i=$((_i + 40))
  done
fi

# 内核类包核对: 只能是求解器为选定 flavour 解析出的那些 (防止递归展开把其它 flavour 内核带回来)
_kbad=0; _kn=0; _kbytes=0
for _f in "$ARCHIVES"/*.deb; do
  [ -f "$_f" ] || continue
  _p="$(basename "$_f" | aib_deb_pkg_name)"
  aib_is_kernel_pkg "$_p" || continue
  _kn=$((_kn + 1)); _kbytes=$((_kbytes + $(stat -c %s "$_f")))
  if ! grep -qxF -- "$_p" "$CLOSURE_NAMES"; then
    echo "ERROR: 捆绑里出现不属于选定内核 flavour 的内核类包: $(basename "$_f")" >&2
    _kbad=1
  fi
done
echo "内核类 deb (flavour: ${NVIDIA_FLAVOURS:-无}): $_kn 个, $((_kbytes / 1048576)) MiB"
[ "$_kbad" -eq 0 ] || exit 1
rm -f "$SEED_URIS" "$CLOSURE_NAMES" "$KDROP_LIST"

# 把 FlClash .deb 放进 archives, 并用 apt 再解析一次依赖 (以防 Depends 有遗漏)
if [ -n "$FLCLASH_DEB" ]; then
  echo "apt download-only for local FlClash deb (resolve Depends against $RELEASE)"
  apt-get install -y --download-only --no-install-recommends     -o Dir::Cache::archives="$ARCHIVES"     "$FLCLASH_DEB" || {
    echo "ERROR: 无法解析/下载 FlClash 的 apt 依赖: $FLCLASH_DEB" >&2
    exit 1
  }
  cp -a "$FLCLASH_DEB" "$ARCHIVES/$(basename "$FLCLASH_DEB")"
fi
if [ -n "$RUSTDESK_DEB" ]; then
  echo "apt download-only for local RustDesk deb (resolve Depends against $RELEASE)"
  apt-get install -y --download-only --no-install-recommends -o Dir::Cache::archives="$ARCHIVES" "$RUSTDESK_DEB" || {
    echo "ERROR: 无法解析/下载 RustDesk 的 apt 依赖: $RUSTDESK_DEB" >&2
    exit 1
  }
  cp -a "$RUSTDESK_DEB" "$ARCHIVES/$(basename "$RUSTDESK_DEB")"
fi
if [ -n "$GROKBOT_DEB" ]; then
  echo "apt download-only for local Grok Bot deb (resolve Depends against $RELEASE)"
  apt-get install -y --download-only --no-install-recommends -o Dir::Cache::archives="$ARCHIVES" "$GROKBOT_DEB" ${GROKBOT_RECS[@]+"${GROKBOT_RECS[@]}"} || {
    echo "ERROR: 无法解析/下载 Grok Bot 的 apt 依赖: $GROKBOT_DEB" >&2
    exit 1
  }
  cp -a "$GROKBOT_DEB" "$ARCHIVES/$(basename "$GROKBOT_DEB")"
fi

# linux-firmware* 是内核 meta 拉进来的 (容器里没有); 目标机已装, 不进捆绑 (FETCH_KEEP_LINUX_FIRMWARE=1 保留)
if [ "$KEEP_LINUX_FIRMWARE" != "1" ]; then
  _fw="$(find "$ARCHIVES" -maxdepth 1 \( -name 'linux-firmware_*.deb' -o -name 'linux-firmware-*.deb' \) | wc -l)"
  if [ "$_fw" -gt 0 ]; then
    echo "drop $_fw linux-firmware deb(s) ($(du -ch "$ARCHIVES"/linux-firmware*.deb | tail -1 | cut -f1)): 目标机自带"
    rm -f "$ARCHIVES"/linux-firmware_*.deb "$ARCHIVES"/linux-firmware-*.deb
  fi
fi

# 统计 + 回写缓存
_total="$(find "$ARCHIVES" -maxdepth 1 -name '*.deb' | wc -l)"
echo "apt deb: 共 $_total, 复用 $_reused, 新下载 $((_total - _reused))"
if [ -n "$APT_CACHE_DIR" ]; then
  read -r _synced _pruned < <(aib_deb_sync_cache "$ARCHIVES" "$APT_CACHE_DIR" "$REUSED_LIST" "$PRUNE_APT_CACHE")
  echo "deb 缓存 $APT_CACHE_DIR: 新增/更新 $_synced, 清理 $_pruned, 现有 $(find "$APT_CACHE_DIR" -maxdepth 1 -name '*.deb' | wc -l)"
fi
printf 'reused=%s\ndownloaded=%s\ntotal=%s\n' "$_reused" "$((_total - _reused))" "$_total" > "$OUTDIR/.apt-reuse-stats"
rm -f "$NEED_LIST" "$REUSED_LIST"

mkdir -p "$OUTDIR/apt"
# 扁平池: deb [trusted=yes] file:/opt/offline/apt ./
find /var/cache/apt/archives -maxdepth 1 -name '*.deb' -exec cp -a {} "$OUTDIR/apt/" \;
cd "$OUTDIR/apt"
dpkg-scanpackages . /dev/null > Packages
gzip -9c Packages > Packages.gz
# Release with Date + hashes (apt still needs trusted=yes for unsigned repo)
SIZE_P=$(wc -c < Packages)
SIZE_Z=$(wc -c < Packages.gz)
MD5_P=$(md5sum Packages | awk '{print $1}')
MD5_Z=$(md5sum Packages.gz | awk '{print $1}')
SHA_P=$(sha256sum Packages | awk '{print $1}')
SHA_Z=$(sha256sum Packages.gz | awk '{print $1}')
cat > Release <<REL
Archive: offline
Codename: offline
Components: .
Architectures: ${ARCH}
Date: $(date -Ru)
MD5Sum:
 ${MD5_P} ${SIZE_P} Packages
 ${MD5_Z} ${SIZE_Z} Packages.gz
SHA256:
 ${SHA_P} ${SIZE_P} Packages
 ${SHA_Z} ${SIZE_Z} Packages.gz
REL

ls -1 *.deb | sort > "$OUTDIR/package-list.txt"
echo "deb count: $(wc -l < "$OUTDIR/package-list.txt")"
du -sh "$OUTDIR/apt"
# 测试钩子: 只抓最小种子时到此为止 (不要 node / jenkins)
[ -n "${FETCH_MINIMAL_SEEDS:-}" ] && exit 0

# Node 官方 tarball 兜底
mkdir -p "$OUTDIR/node"
TARBALL=$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/" \
  | grep -oE "node-v${NODE_MAJOR}\\.[0-9.]*-linux-x64\\.tar\\.xz" | head -1 || true)
if [ -n "$TARBALL" ]; then
  NODE_SHA="$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/SHASUMS256.txt" 2>/dev/null \
    | awk -v f="$TARBALL" '$2==f {print $1}' || true)"
  if [ -n "$NODE_SHA" ] && [ -n "$PREV_NODE_DIR" ] && [ -f "$PREV_NODE_DIR/$TARBALL" ] \
     && [ "$(sha256sum "$PREV_NODE_DIR/$TARBALL" | cut -d' ' -f1)" = "$NODE_SHA" ]; then
    cp -p "$PREV_NODE_DIR/$TARBALL" "$OUTDIR/node/${TARBALL}"
    echo "node tarball 复用 (sha256 一致): $TARBALL"
  else
    curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/${TARBALL}" \
      -o "$OUTDIR/node/${TARBALL}"
    if [ -n "$NODE_SHA" ]; then
      echo "$NODE_SHA  $OUTDIR/node/${TARBALL}" | sha256sum -c - >/dev/null \
        || { echo "ERROR: node tarball sha256 不匹配"; exit 1; }
    fi
  fi
  echo "$TARBALL" > "$OUTDIR/node/tarball.name"
fi

# 记下 java 包名供安装时使用
echo "$JAVA_PKG" > "$OUTDIR/java-package.txt"

# Jenkins 版本 (插件在宿主机按此版本的 update center 解析, 不需要 Java)
JDEB="$(ls "$OUTDIR"/apt/jenkins_*.deb | sort -V | tail -1)"
JVER="$(dpkg-deb -f "$JDEB" Version)"
printf '%s' "${JVER%%-*}" > "$OUTDIR/jenkins-version.txt"
INNER
chmod +x "$WORK/fetch-debs.sh"
cp "$SCRIPT_DIR/ubuntu-mirror.sh" "$WORK/ubuntu-mirror.sh"
cp "$SCRIPT_DIR/apt-deb-reuse.sh" "$WORK/apt-deb-reuse.sh"
cp "$SCRIPT_DIR/grok-bot-release.sh" "$WORK/grok-bot-release.sh"

# --------------- FlClash deb (host; 官方 GitHub Release + SHA256SUMS) ---------------
# 必须在容器抓 deb 依赖之前下好, 以便把 Depends 并入 noble/jammy apt 闭包。
if [[ "$ARCH" == "amd64" || "$ARCH" == "arm64" ]]; then
  log "解析 FlClash 最新稳定版 (linux-$ARCH)"
  flclash_resolve "$ARCH" || die "无法解析 FlClash 最新稳定版"
  mkdir -p "$WORK/flclash-in"
  # 优先复用旧捆绑里校验和一致的 deb, 避免重复从 GitHub 拉 ~40MB
  if [[ -d "$OUT/flclash" ]]; then
    _prev_sums=""
    [[ -f "$OUT/flclash/SHA256SUMS" ]] && _prev_sums="$OUT/flclash/SHA256SUMS"
    if [[ -f "$OUT/flclash/$FLCLASH_DEB_NAME" ]]; then
      _prev_sha=""
      [[ -f "$OUT/flclash/sha256" ]] && _prev_sha="$(tr -d '[:space:]' < "$OUT/flclash/sha256")"
      if flclash_verify_deb "$OUT/flclash/$FLCLASH_DEB_NAME" "$_prev_sums" "$_prev_sha" 2>/dev/null; then
        cp -p "$OUT/flclash/$FLCLASH_DEB_NAME" "$WORK/flclash-in/$FLCLASH_DEB_NAME"
        if [[ -n "$_prev_sums" ]]; then
          cp -p "$OUT/flclash/SHA256SUMS" "$WORK/flclash-in/SHA256SUMS" || true
        fi
        ok "复用旧捆绑 flclash/$FLCLASH_DEB_NAME (sha256 一致)"
      fi
    fi
  fi
  flclash_download_to "$WORK/flclash-in" || die "下载/校验 FlClash 失败: $FLCLASH_DEB_URL"
  printf '%s\n' "$FLCLASH_VERSION" > "$WORK/flclash-in/version"
  printf '%s\n' "$FLCLASH_SHA256" > "$WORK/flclash-in/sha256"
  printf '%s\n' "$FLCLASH_DEB_NAME" > "$WORK/flclash-in/deb.name"
  ok "FlClash $FLCLASH_VERSION ($FLCLASH_DEB_NAME, $(du -h "$WORK/flclash-in/$FLCLASH_DEB_NAME" | cut -f1))"
else
  warn "FlClash 官方 linux deb 不支持 arch=$ARCH, 跳过"
  FLCLASH_VERSION=""
  FLCLASH_SHA256=""
  FLCLASH_DEB_NAME=""
fi

# --------------- RustDesk deb (host; 官方 GitHub Release, 钉扎版本 + sha256) ---------------
if [[ "$ARCH" == "amd64" || "$ARCH" == "arm64" ]]; then
  log "RustDesk $PIN_RUSTDESK (linux-$ARCH)"
  rustdesk_resolve "$PIN_RUSTDESK" "$ARCH" || die "无法解析 RustDesk $PIN_RUSTDESK"
  mkdir -p "$WORK/rustdesk-in"
  # 优先复用旧捆绑里校验和一致的 deb (约 25MB)
  if [[ -f "$OUT/rustdesk/$RUSTDESK_DEB_NAME" ]] && rustdesk_verify_deb "$OUT/rustdesk/$RUSTDESK_DEB_NAME" "$RUSTDESK_SHA256" 2>/dev/null; then
    cp -p "$OUT/rustdesk/$RUSTDESK_DEB_NAME" "$WORK/rustdesk-in/$RUSTDESK_DEB_NAME"
    ok "复用旧捆绑 rustdesk/$RUSTDESK_DEB_NAME (sha256 一致)"
  fi
  rustdesk_download_to "$WORK/rustdesk-in" || die "下载/校验 RustDesk 失败: $RUSTDESK_DEB_URL"
  ok "RustDesk $RUSTDESK_VERSION ($RUSTDESK_DEB_NAME, $(du -h "$WORK/rustdesk-in/$RUSTDESK_DEB_NAME" | cut -f1))"
else
  warn "RustDesk 官方 linux deb 不支持 arch=$ARCH, 跳过"
  RUSTDESK_VERSION=""
  RUSTDESK_SHA256=""
  RUSTDESK_DEB_NAME=""
fi

# --------------- Grok Bot deb (host; 发布 feed + 签名 apt 索引 / 钉扎 sha256) ---------------
GROK_BOT_VERSION="" GROK_BOT_SHA256_OUT="" GROK_BOT_DEB_NAME="" GROK_BOT_URL_OUT="" GROK_BOT_SHA_SOURCE=""
if [[ "$NO_GROK_BOT" -eq 1 ]]; then
  log "Grok Bot: 不捆绑 (--no-grok-bot)"
elif [[ "$ARCH" == "amd64" || "$ARCH" == "arm64" ]]; then
  log "Grok Bot ${PIN_GROK_BOT}${GROK_BOT_DEB_URL:+ (钉扎 URL)} (linux-$ARCH)"
  grokbot_resolve "$PIN_GROK_BOT" "$ARCH" "$GROK_BOT_DEB_URL" "$GROK_BOT_SHA256" \
    || die "无法解析 Grok Bot $PIN_GROK_BOT (发布 feed / apt 仓库不可达? 国内可能要代理; 不要 Grok Bot 用 --no-grok-bot)"
  mkdir -p "$WORK/grok-bot-in"
  # 优先复用旧捆绑里校验和一致的 deb (约 110MB)
  if [[ -f "$OUT/grok-bot/$GROK_BOT_DEB_NAME" ]] \
     && grokbot_verify_deb "$OUT/grok-bot/$GROK_BOT_DEB_NAME" "$GROK_BOT_SHA256" "$GROK_BOT_VERSION" "$ARCH" 2>/dev/null; then
    cp -p "$OUT/grok-bot/$GROK_BOT_DEB_NAME" "$WORK/grok-bot-in/$GROK_BOT_DEB_NAME"
    ok "复用旧捆绑 grok-bot/$GROK_BOT_DEB_NAME (sha256 一致)"
  fi
  grokbot_download_to "$WORK/grok-bot-in" "$ARCH" || die "下载/校验 Grok Bot 失败: $GROK_BOT_DEB_URL"
  GROK_BOT_SHA256_OUT="$GROK_BOT_SHA256"
  GROK_BOT_URL_OUT="$GROK_BOT_DEB_URL"
  ok "Grok Bot $GROK_BOT_VERSION ($GROK_BOT_DEB_NAME, $(du -h "$WORK/grok-bot-in/$GROK_BOT_DEB_NAME" | cut -f1), sha256 来源 $GROK_BOT_SHA_SOURCE)"
else
  warn "Grok Bot 官方 linux deb 不支持 arch=$ARCH, 跳过"
fi

NVIDIA_IN_DRIVER=""
[[ "$NO_NVIDIA_DRIVER" -eq 1 ]] || NVIDIA_IN_DRIVER="$PIN_NVIDIA_DRIVER"
log "在 $IMG 中解析并下载 apt 依赖闭包"
mkdir -p "$WORK/out"
if [[ "$APT_RUNNER" == "direct" ]]; then
  log "direct 模式: 直接在当前容器 ($(. /etc/os-release && echo "$PRETTY_NAME"), $(dpkg --print-architecture)) 里跑 apt"
  _prev_apt=""; [[ -d "$OUT/apt" ]] && _prev_apt="$OUT/apt"
  _prev_node=""; [[ -d "$OUT/node" ]] && _prev_node="$OUT/node"
  FETCH_OUTDIR="$WORK/out" DEBIAN_FRONTEND=noninteractive \
    FETCH_APT_CACHE="$APT_CACHE" FETCH_PREV_APT="$_prev_apt" FETCH_PREV_NODE="$_prev_node" \
    FETCH_PRUNE_APT_CACHE="$PRUNE_APT_CACHE" \
    FETCH_FLCLASH_DIR="$WORK/flclash-in" \
    FETCH_RUSTDESK_DIR="$WORK/rustdesk-in" \
    FETCH_GROKBOT_DIR="$WORK/grok-bot-in" \
    FETCH_NVIDIA_DRIVER="$NVIDIA_IN_DRIVER" FETCH_NVIDIA_FLAVOURS="$NVIDIA_FP_FLAVOURS" \
    FETCH_KEEP_LINUX_FIRMWARE="${FETCH_KEEP_LINUX_FIRMWARE:-0}" \
    bash "$WORK/fetch-debs.sh" "$RELEASE" "$ARCH" "$PIN_NODE_MAJOR" "$UBUNTU_MIRROR" "$PACKAGES"
else
  REUSE_ARGS=()
  if [[ -n "$APT_CACHE" ]]; then
    REUSE_ARGS+=(-v "$(cd -- "$APT_CACHE" && pwd):/apt-cache" -e FETCH_APT_CACHE=/apt-cache)
  fi
  [[ -d "$OUT/apt" ]] && REUSE_ARGS+=(-v "$(cd -- "$OUT/apt" && pwd):/prev-apt:ro" -e FETCH_PREV_APT=/prev-apt)
  [[ -d "$OUT/node" ]] && REUSE_ARGS+=(-v "$(cd -- "$OUT/node" && pwd):/prev-node:ro" -e FETCH_PREV_NODE=/prev-node)
  if [[ -d "$WORK/flclash-in" ]] && compgen -G "$WORK/flclash-in"/FlClash-*-linux-*.deb >/dev/null; then
    REUSE_ARGS+=(-v "$(cd -- "$WORK/flclash-in" && pwd):/flclash-in:ro" -e FETCH_FLCLASH_DIR=/flclash-in)
  fi
  if [[ -d "$WORK/rustdesk-in" ]] && compgen -G "$WORK/rustdesk-in"/rustdesk-*.deb >/dev/null; then
    REUSE_ARGS+=(-v "$(cd -- "$WORK/rustdesk-in" && pwd):/rustdesk-in:ro" -e FETCH_RUSTDESK_DIR=/rustdesk-in)
  fi
  if [[ -d "$WORK/grok-bot-in" ]] && compgen -G "$WORK/grok-bot-in"/*.deb >/dev/null; then
    REUSE_ARGS+=(-v "$(cd -- "$WORK/grok-bot-in" && pwd):/grok-bot-in:ro" -e FETCH_GROKBOT_DIR=/grok-bot-in)
  fi
  docker run --rm --network host \
    --dns 8.8.8.8 --dns 1.1.1.1 \
    -v "$WORK/fetch-debs.sh:/fetch-debs.sh:ro" \
    -v "$WORK/ubuntu-mirror.sh:/ubuntu-mirror.sh:ro" \
    -v "$WORK/apt-deb-reuse.sh:/apt-deb-reuse.sh:ro" \
    -v "$WORK/grok-bot-release.sh:/grok-bot-release.sh:ro" \
    -v "$WORK/out:/out" \
    "${REUSE_ARGS[@]+"${REUSE_ARGS[@]}"}" \
    -e FETCH_PRUNE_APT_CACHE="$PRUNE_APT_CACHE" \
    -e FETCH_NVIDIA_DRIVER="$NVIDIA_IN_DRIVER" -e FETCH_NVIDIA_FLAVOURS="$NVIDIA_FP_FLAVOURS" \
    -e FETCH_KEEP_LINUX_FIRMWARE="${FETCH_KEEP_LINUX_FIRMWARE:-0}" \
    -e DEBIAN_FRONTEND=noninteractive \
    "$IMG" bash /fetch-debs.sh "$RELEASE" "$ARCH" "$PIN_NODE_MAJOR" "$UBUNTU_MIRROR" "$PACKAGES"
fi

# 容器以 root 写 /out, 改回当前用户以免 cleanup/复用失败
if command -v sudo >/dev/null; then
  sudo chown -R "$(id -u):$(id -g)" "$WORK/out" 2>/dev/null || true
  [[ -n "$APT_CACHE" ]] && { sudo chown -R "$(id -u):$(id -g)" "$APT_CACHE" 2>/dev/null || true; }
fi
if [[ -f "$WORK/out/.apt-reuse-stats" ]]; then
  # shellcheck disable=SC1091
  . "$WORK/out/.apt-reuse-stats"
  ok "apt deb: 复用 ${reused:-0}, 新下载 ${downloaded:-0} (共 ${total:-0})"
  rm -f "$WORK/out/.apt-reuse-stats"
fi

# 旧捆绑里的大文件先挪到一边, 版本/校验和不变时直接复用 (见下方各段)
PREV="$WORK/prev"
mkdir -p "$PREV"
for _d in unity-cli godot gitea jenkins-plugins; do
  [[ -d "$OUT/$_d" ]] && mv "$OUT/$_d" "$PREV/$_d"
done
# 复用文件: prev/<sub>/<name> 存在且校验和一致则拷到 dest, 返回 0
reuse_prev() { # sub name dest algo(sha256|sha512) hex
  local src="$PREV/$1/$2" sum
  [[ -f "$src" && -n "$5" ]] || return 1
  sum="$("${4}sum" "$src" | cut -d' ' -f1)"
  [[ "$sum" == "$5" ]] || return 1
  cp -p "$src" "$3"
  ok "复用旧捆绑 $1/$2 (${4} 一致)"
}

# 同步到 OUT (保留可复用)
rm -rf "$OUT/apt" "$OUT/apt-sources" "$OUT/node" "$OUT/unity-cli" "$OUT/godot" "$OUT/gitea" "$OUT/flclash" "$OUT/rustdesk" "$OUT/grok-bot" "$OUT/nvidia" "$OUT/jenkins-plugins" "$OUT/jenkins-version.txt" "$OUT/package-list.txt" "$OUT/java-package.txt"
mkdir -p "$OUT"
cp -a "$WORK/out/." "$OUT/"
if [[ -n "${FLCLASH_DEB_NAME:-}" && -f "$WORK/flclash-in/$FLCLASH_DEB_NAME" ]]; then
  mkdir -p "$OUT/flclash"
  cp -p "$WORK/flclash-in/$FLCLASH_DEB_NAME" "$OUT/flclash/$FLCLASH_DEB_NAME"
  [[ -f "$WORK/flclash-in/SHA256SUMS" ]] && cp -p "$WORK/flclash-in/SHA256SUMS" "$OUT/flclash/SHA256SUMS"
  printf '%s\n' "$FLCLASH_VERSION" > "$OUT/flclash/version"
  printf '%s\n' "$FLCLASH_SHA256" > "$OUT/flclash/sha256"
  printf '%s\n' "$FLCLASH_DEB_NAME" > "$OUT/flclash/deb.name"
fi
if [[ -n "${RUSTDESK_DEB_NAME:-}" && -f "$WORK/rustdesk-in/$RUSTDESK_DEB_NAME" ]]; then
  mkdir -p "$OUT/rustdesk"
  cp -p "$WORK/rustdesk-in/$RUSTDESK_DEB_NAME" "$OUT/rustdesk/$RUSTDESK_DEB_NAME"
  printf '%s\n' "$RUSTDESK_VERSION" > "$OUT/rustdesk/version"
  printf '%s\n' "$RUSTDESK_SHA256" > "$OUT/rustdesk/sha256"
  printf '%s\n' "$RUSTDESK_DEB_NAME" > "$OUT/rustdesk/deb.name"
fi
if [[ -n "${GROK_BOT_DEB_NAME:-}" && -f "$WORK/grok-bot-in/$GROK_BOT_DEB_NAME" ]]; then
  mkdir -p "$OUT/grok-bot"
  cp -p "$WORK/grok-bot-in/$GROK_BOT_DEB_NAME" "$OUT/grok-bot/$GROK_BOT_DEB_NAME"
  printf '%s\n' "$GROK_BOT_VERSION" > "$OUT/grok-bot/version"
  printf '%s\n' "$GROK_BOT_SHA256_OUT" > "$OUT/grok-bot/sha256"
  printf '%s\n' "$GROK_BOT_DEB_NAME" > "$OUT/grok-bot/deb.name"
  printf '%s\n' "$GROK_BOT_URL_OUT" > "$OUT/grok-bot/url"
  printf '%s\n' "$GROK_BOT_SHA_SOURCE" > "$OUT/grok-bot/sha256.source"
fi

# --------------- Jenkins 插件 (宿主机 python3; update center sha256 校验) ---------------
JVER="$(cat "$OUT/jenkins-version.txt")"
log "解析 Jenkins 插件 (Jenkins $JVER): $JENKINS_PLUGINS"
JP_DIR="$OUT/jenkins-plugins"
mkdir -p "$JP_DIR"
# 旧插件先放回: 解析器对 sha256 与 update center 一致的文件不重下
[[ -d "$PREV/jenkins-plugins" ]] && find "$PREV/jenkins-plugins" -maxdepth 1 -name '*.jpi' -exec cp -p {} "$JP_DIR/" \;
# shellcheck disable=SC2086
python3 "$RESOLVER" --jenkins-version "$JVER" --out "$JP_DIR" $JENKINS_PLUGINS \
  || die "Jenkins 插件解析/下载失败"
printf '%s' "$JVER" > "$JP_DIR/jenkins-version"
# 去掉不在 lock 里的旧插件
for _jpi in "$JP_DIR"/*.jpi; do
  [[ -f "$_jpi" ]] || continue
  grep -q "^$(basename "$_jpi" .jpi):" "$JP_DIR/plugins.lock" || rm -f "$_jpi"
done
# shellcheck disable=SC2086
printf '%s\n' $JENKINS_PLUGINS | sort -u > "$JP_DIR/requested.txt"
ok "Jenkins 插件: $(wc -l < "$JP_DIR/plugins.lock") 个 ($(du -sh "$JP_DIR" | cut -f1))"

# --------------- npm 全局树 (宿主机 node, 与目标 arch 一致的 linux) ---------------
if [[ "$SKIP_NPM" -eq 0 ]]; then
  command -v npm >/dev/null || die "需要宿主机 npm 以打包全局 CLI"
  log "打包 npm 全局树 (grok=$PIN_GROK opencode=@opencode/cli@$PIN_OPENCODE openmausbot=$PIN_OPENMAUSBOT)"
  NPM_PREFIX="$WORK/npm-prefix"
  mkdir -p "$NPM_PREFIX"
  # @opencode/cli 的 postinstall 必须跑, 否则 bin 只是桩。不要 --ignore-scripts。
  # 旧 npm 可能不认 --allow-scripts, 失败时回退到默认会执行脚本的安装。
  if ! npm install -g --prefix "$NPM_PREFIX" \
    "@xai-official/grok@${PIN_GROK}" \
    "@opencode/cli@${PIN_OPENCODE}" \
    "openmausbot@${PIN_OPENMAUSBOT}" \
    --no-audit --no-fund \
    --allow-scripts="@xai-official/grok,@opencode/cli,openmausbot"; then
    npm install -g --prefix "$NPM_PREFIX" \
      "@xai-official/grok@${PIN_GROK}" \
      "@opencode/cli@${PIN_OPENCODE}" \
      "openmausbot@${PIN_OPENMAUSBOT}" \
      --no-audit --no-fund
  fi
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/../software/lib-offline.sh"
  _oc_arch="$(aib_opencode_node_arch "$ARCH")"
  aib_prune_opencode_cli_platform "$NPM_PREFIX" "$_oc_arch"
  if [ -x "$NPM_PREFIX/bin/opencode" ]; then
    "$NPM_PREFIX/bin/opencode" --version >/dev/null \
      || die "离线 npm 树里的 opencode --version 失败 (postinstall 可能没跑)"
  else
    die "离线 npm 树缺少 $NPM_PREFIX/bin/opencode"
  fi
  mkdir -p "$OUT/npm"
  tar --owner=0 --group=0 --numeric-owner -czf "$OUT/npm/prefix.tar.gz" -C "$NPM_PREFIX" .
  ok "npm prefix $(du -h "$OUT/npm/prefix.tar.gz" | cut -f1) (opencode 已裁掉非目标平台包)"
else
  warn "跳过 npm (--skip-npm)"
  mkdir -p "$OUT/npm"
  : > "$OUT/npm/.skipped"
fi

# --------------- Unity CLI binary (host; not apt) ---------------
# 直接拉 CDN 二进制 + sha256，系统装机脚本装到 /usr/local/bin/unity。不含 Editor。
log "下载 Unity CLI (linux-x64)"
UNITY_CDN="${UNITY_CLI_CDN_BASE:-https://public-cdn.cloud.unity3d.com/hub/prod/cli/}"
UNITY_PLATFORM="linux-x64"
UNITY_DIR="$OUT/unity-cli"
mkdir -p "$UNITY_DIR"
UNITY_MANIFEST=""
UNITY_VERSION=""
if [[ -n "$PIN_UNITY_CLI" ]]; then
  UNITY_MANIFEST="$(curl -fsSL "${UNITY_CDN}${PIN_UNITY_CLI}/latest.json")" \
    || die "无法拉取 Unity CLI 版本清单: ${UNITY_CDN}${PIN_UNITY_CLI}/latest.json"
else
  if UNITY_MANIFEST="$(curl -fsSL "${UNITY_CDN}latest.json" 2>/dev/null)"; then
    ok "Unity CLI stable 清单"
  else
    warn "Unity CLI stable 不可用，回退 latest-beta.json"
    UNITY_MANIFEST="$(curl -fsSL "${UNITY_CDN}latest-beta.json")" \
      || die "无法拉取 Unity CLI beta 清单"
  fi
fi
eval "$(python3 - "$UNITY_MANIFEST" "$UNITY_PLATFORM" <<'UPY'
import json, sys
o = json.loads(sys.argv[1])
plat = sys.argv[2]
b = o["binaries"][plat]
print(f'UNITY_VERSION={o["version"]!r}')
print(f'UNITY_FILENAME={b["filename"]!r}')
print(f'UNITY_SHA256={b["sha256"]!r}')
UPY
)"
[[ -n "$UNITY_VERSION" && -n "$UNITY_FILENAME" && -n "$UNITY_SHA256" ]] \
  || die "Unity CLI 清单字段不完整"
if [[ -n "$PIN_UNITY_CLI" && "$UNITY_VERSION" != "$PIN_UNITY_CLI" ]]; then
  die "Unity CLI 版本不匹配: 请求 $PIN_UNITY_CLI 得到 $UNITY_VERSION"
fi
reuse_prev unity-cli "$UNITY_FILENAME" "$UNITY_DIR/$UNITY_FILENAME" sha256 "$UNITY_SHA256" \
  || curl -fsSL "${UNITY_CDN}${UNITY_VERSION}/${UNITY_FILENAME}" -o "$UNITY_DIR/$UNITY_FILENAME" \
  || die "下载 Unity CLI 失败: ${UNITY_CDN}${UNITY_VERSION}/${UNITY_FILENAME}"
echo "$UNITY_SHA256  $UNITY_DIR/$UNITY_FILENAME" | sha256sum -c - \
  || die "Unity CLI sha256 校验失败"
# 统一落一份名为 unity 的可执行文件，方便离线脚本
cp -a "$UNITY_DIR/$UNITY_FILENAME" "$UNITY_DIR/unity"
chmod +x "$UNITY_DIR/unity" "$UNITY_DIR/$UNITY_FILENAME"
printf '%s\n' "$UNITY_VERSION" > "$UNITY_DIR/version"
printf '%s\n' "$UNITY_SHA256" > "$UNITY_DIR/sha256"
printf '%s\n' "$UNITY_FILENAME" > "$UNITY_DIR/binary.name"
ok "Unity CLI $UNITY_VERSION ($(du -h "$UNITY_DIR/unity" | cut -f1))"

# --------------- Godot Engine binary (host; zip only, no export templates) ---------------
# 官方 4.7.2 Linux x86_64：GitHub releases + SHA512-SUMS.txt
log "下载 Godot 4.7.2 (linux.x86_64)"
GODOT_VERSION="4.7.2"
# asset: Godot_v4.7.2-stable_linux.x86_64.zip
GODOT_TAG="${GODOT_VERSION}-stable"
GODOT_ZIP="Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
GODOT_SHA512="9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65"
GODOT_DIR="$OUT/godot"
mkdir -p "$GODOT_DIR"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_TAG}/${GODOT_ZIP}"
GODOT_FALLBACK="https://downloads.godotengine.org/?version=${GODOT_VERSION}&flavor=stable&slug=linux.x86_64.zip&platform=linux.64"
if reuse_prev godot "$GODOT_ZIP" "$GODOT_DIR/$GODOT_ZIP" sha512 "$GODOT_SHA512"; then
  :
elif ! curl -fL --retry 3 --retry-delay 2 -o "$GODOT_DIR/$GODOT_ZIP" "$GODOT_URL"; then
  warn "GitHub 下载失败，尝试 downloads.godotengine.org"
  curl -fL --retry 3 --retry-delay 2 -o "$GODOT_DIR/$GODOT_ZIP" "$GODOT_FALLBACK" \
    || die "下载 Godot 失败: $GODOT_ZIP"
fi
echo "${GODOT_SHA512}  $GODOT_DIR/$GODOT_ZIP" | sha512sum -c - \
  || die "Godot sha512 校验失败"
printf '%s\n' "$GODOT_VERSION" > "$GODOT_DIR/version"
printf '%s\n' "$GODOT_SHA512" > "$GODOT_DIR/sha512"
printf '%s\n' "$GODOT_ZIP" > "$GODOT_DIR/zip.name"
ok "Godot $GODOT_VERSION ($(du -h "$GODOT_DIR/$GODOT_ZIP" | cut -f1); 不含 export templates)"

# --------------- Gitea binary (host; 官方 dl.gitea.com + .sha256) ---------------
GITEA_DL="${GITEA_DL_BASE:-https://dl.gitea.com/gitea}"
if [[ "$PIN_GITEA" == "latest" ]]; then
  GITEA_VERSION="$(curl -fsSL "$GITEA_DL/version.json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["latest"]["version"])')" \
    || die "无法解析 Gitea 最新版本: $GITEA_DL/version.json"
else
  GITEA_VERSION="$PIN_GITEA"
fi
[[ "$GITEA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]] || die "Gitea 版本号异常: $GITEA_VERSION"
log "下载 Gitea $GITEA_VERSION (linux-amd64)"
GITEA_FILE="gitea-${GITEA_VERSION}-linux-amd64"
GITEA_DIR="$OUT/gitea"
mkdir -p "$GITEA_DIR"
GITEA_SHA256="$(curl -fsSL "$GITEA_DL/$GITEA_VERSION/$GITEA_FILE.sha256" | awk '{print $1}')"
[[ "$GITEA_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "无法获取 Gitea 官方 sha256"
reuse_prev gitea "$GITEA_FILE" "$GITEA_DIR/$GITEA_FILE" sha256 "$GITEA_SHA256" \
  || curl -fL --retry 3 --retry-delay 2 -o "$GITEA_DIR/$GITEA_FILE" "$GITEA_DL/$GITEA_VERSION/$GITEA_FILE" \
  || die "下载 Gitea 失败: $GITEA_DL/$GITEA_VERSION/$GITEA_FILE"
echo "$GITEA_SHA256  $GITEA_DIR/$GITEA_FILE" | sha256sum -c - || die "Gitea sha256 校验失败"
chmod 0755 "$GITEA_DIR/$GITEA_FILE"
printf '%s\n' "$GITEA_VERSION" > "$GITEA_DIR/version"
printf '%s\n' "$GITEA_SHA256" > "$GITEA_DIR/sha256"
printf '%s\n' "$GITEA_FILE" > "$GITEA_DIR/binary.name"
ok "Gitea $GITEA_VERSION ($(du -h "$GITEA_DIR/$GITEA_FILE" | cut -f1))"

# --------------- manifest ---------------
APT_COUNT=0
[[ -f "$OUT/package-list.txt" ]] && APT_COUNT=$(wc -l < "$OUT/package-list.txt")
SIZE_BYTES=$(du -sb "$OUT" | awk '{print $1}')
SIZE_HUMAN=$(du -sh "$OUT" | cut -f1)
CREATED=$(date -u +%FT%TZ)

python3 - "$OUT" <<PY
import json, os, sys, hashlib, pathlib
out = pathlib.Path(sys.argv[1])
debs = sorted(p.name for p in (out/"apt").glob("*.deb")) if (out/"apt").exists() else []
node = []
nd = out/"node"
if nd.exists():
    node = [p.name for p in nd.iterdir() if p.is_file()]
unity_meta = {}
ud = out/"unity-cli"
if ud.exists():
    unity_meta = {
      "version": (ud/"version").read_text().strip() if (ud/"version").exists() else None,
      "sha256": (ud/"sha256").read_text().strip() if (ud/"sha256").exists() else None,
      "filename": (ud/"binary.name").read_text().strip() if (ud/"binary.name").exists() else None,
      "present": (ud/"unity").exists() or any(ud.glob("unity-*")),
    }
godot_meta = {}
gd = out/"godot"
if gd.exists():
    godot_meta = {
      "version": (gd/"version").read_text().strip() if (gd/"version").exists() else None,
      "sha512": (gd/"sha512").read_text().strip() if (gd/"sha512").exists() else None,
      "zip": (gd/"zip.name").read_text().strip() if (gd/"zip.name").exists() else None,
      "present": any(gd.glob("Godot_*.zip")) or any(gd.glob("*.zip")),
    }
gitea_meta = {}
gt = out/"gitea"
if gt.exists():
    gitea_meta = {
      "version": (gt/"version").read_text().strip() if (gt/"version").exists() else None,
      "sha256": (gt/"sha256").read_text().strip() if (gt/"sha256").exists() else None,
      "filename": (gt/"binary.name").read_text().strip() if (gt/"binary.name").exists() else None,
      "present": any(gt.glob("gitea-*-linux-amd64")),
    }
flclash_meta = {}
fc = out/"flclash"
if fc.exists():
    flclash_meta = {
      "version": (fc/"version").read_text().strip() if (fc/"version").exists() else None,
      "sha256": (fc/"sha256").read_text().strip() if (fc/"sha256").exists() else None,
      "filename": (fc/"deb.name").read_text().strip() if (fc/"deb.name").exists() else None,
      "present": any(fc.glob("FlClash-*-linux-*.deb")),
    }
rustdesk_meta = {}
rd = out/"rustdesk"
if rd.exists():
    rustdesk_meta = {
      "version": (rd/"version").read_text().strip() if (rd/"version").exists() else None,
      "sha256": (rd/"sha256").read_text().strip() if (rd/"sha256").exists() else None,
      "filename": (rd/"deb.name").read_text().strip() if (rd/"deb.name").exists() else None,
      "present": any(rd.glob("rustdesk-*.deb")),
    }
grok_bot_meta = None
gb = out/"grok-bot"
if gb.is_dir():
    _gbr = lambda n: (gb/n).read_text().strip() if (gb/n).exists() else None
    _gbf = gb/(_gbr("deb.name") or "-")
    grok_bot_meta = {
      "version": _gbr("version"),
      "sha256": _gbr("sha256"),
      "sha256_source": _gbr("sha256.source"),
      "filename": _gbr("deb.name"),
      "url": _gbr("url"),
      "size_bytes": _gbf.stat().st_size if _gbf.is_file() else None,
      "present": _gbf.is_file(),
    }
nvidia_meta = None
nv = out/"nvidia"
if nv.is_dir():
    fl = []
    if (nv/"flavours").exists():
        for line in (nv/"flavours").read_text().splitlines():
            parts = line.split()
            if len(parts) == 3:
                fl.append({"flavour": parts[0], "version": parts[1], "kernel_abi": parts[2]})
    nvidia_meta = {
      "driver": (nv/"driver").read_text().strip() if (nv/"driver").exists() else None,
      "flavours": fl,
      "linux_firmware_bundled": any((out/"apt").glob("linux-firmware_*.deb")),
    }
jenkins_plugins_meta = None
jp = out/"jenkins-plugins"
if jp.is_dir():
    lock = (jp/"plugins.lock").read_text().split() if (jp/"plugins.lock").exists() else []
    jenkins_plugins_meta = {
      "jenkins_version": (jp/"jenkins-version").read_text().strip() if (jp/"jenkins-version").exists() else None,
      "resolver": "tools/resolve-jenkins-plugins.py",
      "requested": (jp/"requested.txt").read_text().split() if (jp/"requested.txt").exists() else [],
      "count": len(lock),
      "size_bytes": sum(p.stat().st_size for p in jp.glob("*.jpi")),
      "lock": lock,
    }
apt_src = out/"apt-sources"
apt_sources_meta = None
if apt_src.is_dir():
    apt_sources_meta = {
      "keyrings": sorted(p.name for p in (apt_src/"keyrings").iterdir() if p.is_file()) if (apt_src/"keyrings").is_dir() else [],
      "sources": sorted(p.name for p in (apt_src/"sources.list.d").iterdir() if p.is_file()) if (apt_src/"sources.list.d").is_dir() else [],
    }
manifest = {
  "schema": 4,
  "fingerprint": "${expected_fp}",
  "release": "${RELEASE}",
  "arch": "${ARCH}",
  "created_at": "${CREATED}",
  "ubuntu_mirror": "${UBUNTU_MIRROR}",
  "pins": {
    "node_major": "${PIN_NODE_MAJOR}",
    "grok": "${PIN_GROK}",
    "opencode": "${PIN_OPENCODE}",
    "opencode_package": "@opencode/cli",
    "openmausbot": "${PIN_OPENMAUSBOT}",
    "unity_cli": "${PIN_UNITY_CLI}" or (unity_meta.get("version") or ""),
    "godot": "4.7.2",
    "gitea": "${PIN_GITEA}",
    "flclash": "latest",
    "rustdesk": "${PIN_RUSTDESK}",
    "nvidia_driver": "${NVIDIA_FP_DRIVER}",
    "nvidia_kernel_flavours": sorted(set("${NVIDIA_FP_FLAVOURS}".split())),
    "grok_bot": "${GROKBOT_FP}",
  },
  "extra_packages": [p.strip() for p in "${PACKAGES}".split(",") if p.strip()],
  "apt_deb_count": len(debs),
  "size_bytes": int("${SIZE_BYTES}"),
  "size_human": "${SIZE_HUMAN}",
  "npm_prefix": (out/"npm/prefix.tar.gz").exists(),
  "node_tarballs": node,
  "java_package": (out/"java-package.txt").read_text().strip() if (out/"java-package.txt").exists() else None,
  "unity_cli": unity_meta or None,
  "godot": godot_meta or None,
  "gitea": gitea_meta or None,
  "flclash": flclash_meta or None,
  "rustdesk": rustdesk_meta or None,
  "grok_bot": grok_bot_meta,
  "nvidia": nvidia_meta,
  "jenkins_plugins": jenkins_plugins_meta,
  "apt_sources": apt_sources_meta,
}
(out/"manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
print(json.dumps(manifest, indent=2, ensure_ascii=False))
PY

ok "离线捆绑完成: $OUT ($SIZE_HUMAN, ${APT_COUNT} debs)"
