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
#     package-list.txt
#
# 依赖: docker (推荐), 宿主机 node/npm (打 npm 包)。无 docker 时退出并提示。
#
# apt 解析方式 (--apt-runner / 环境变量 AIB_APT_RUNNER):
#   docker  默认。宿主机 `docker run ubuntu:<release>` 解析依赖闭包 (Linux 原生用法不变)
#   direct  已在「同发行版 + 同架构」的一次性容器里 (如 builder 镜像), 直接在本容器跑 apt,
#           不需要 docker-in-docker。只允许在容器内使用 (会改写本机 /etc/apt)。
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

RELEASE="noble"          # jammy|noble
ARCH="amd64"
OUT=""
PACKAGES=""
CACHE_ROOT="${OFFLINE_CACHE_ROOT:-$ROOT/cache/offline-bundles}"
PIN_NODE_MAJOR="${PIN_NODE_MAJOR:-24}"
PIN_GROK="${PIN_GROK:-latest}"
PIN_OPENCODE="${PIN_OPENCODE:-latest}"
PIN_OPENMAUSBOT="${PIN_OPENMAUSBOT:-latest}"
PIN_UNITY_CLI="${PIN_UNITY_CLI:-}"
PIN_GITEA="${PIN_GITEA:-latest}"
JENKINS_PLUGINS="${JENKINS_PLUGINS:-workflow-aggregator git gitea docker-workflow credentials-binding timestamper rebuild ansicolor docker-plugin parameterized-trigger}"
# Jenkins 插件解析器 (纯 Python 标准库; 与 software/30-jenkins.sh 在线路径同一份)
RESOLVER="$SCRIPT_DIR/resolve-jenkins-plugins.py"
RESOLVER_SHA="$(sha256sum "$RESOLVER" 2>/dev/null | cut -c1-16)"
SKIP_NPM=0
FORCE=0
APT_RUNNER="${AIB_APT_RUNNER:-docker}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}"

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
  --pin-opencode VER    默认 latest
  --pin-openmausbot VER 默认 latest
  --pin-unity-cli VER   Unity CLI 版本 (默认拉 latest/latest-beta)
  --pin-gitea VER       Gitea 版本 (默认 latest, 由 dl.gitea.com/gitea/version.json 解析)
  --jenkins-plugins "a b"
                        预装 Jenkins 插件 (按捆绑里同一 Jenkins 版本的 update center 解析全部必需依赖)
                        默认: workflow-aggregator git gitea docker-workflow credentials-binding timestamper rebuild ansicolor docker-plugin parameterized-trigger
  --ubuntu-mirror URL   容器内 Ubuntu 源
  --skip-npm            不打包 npm 全局树 (调试用)
  --apt-runner R        docker (默认) | direct (仅限容器内, 见脚本头注释)
  --force               忽略已有 manifest/fingerprint, 强制重建 (参数变更或缺件时需 --force)
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
    --jenkins-plugins) JENKINS_PLUGINS="$2"; shift 2 ;;
    --ubuntu-mirror) UBUNTU_MIRROR="$2"; shift 2 ;;
    --skip-npm) SKIP_NPM=1; shift ;;
    --force) FORCE=1; shift ;;
    --apt-runner) APT_RUNNER="$2"; shift 2 ;;
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

[[ "$PIN_GITEA" == "latest" || "$PIN_GITEA" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]] \
  || die "非法 --pin-gitea: $PIN_GITEA"
JENKINS_PLUGINS="$(printf '%s' "$JENKINS_PLUGINS" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
[[ -n "$JENKINS_PLUGINS" ]] || die "--jenkins-plugins 不能为空"
for _jp in $JENKINS_PLUGINS; do
  [[ "$_jp" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(:[A-Za-z0-9._-]+)?$ ]] || die "--jenkins-plugins 含非法插件名: $_jp"
done

if [[ -z "$OUT" ]]; then
  OUT="$CACHE_ROOT/${RELEASE}-${ARCH}"
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
expected_fp="$(python3 - "$RELEASE" "$ARCH" "$PIN_NODE_MAJOR" "$PIN_GROK" "$PIN_OPENCODE" "$PIN_OPENMAUSBOT" "$PIN_UNITY_CLI" "$PACKAGES" "$PIN_GITEA" "$JENKINS_PLUGINS" "$RESOLVER_SHA" <<'FP'
import hashlib, json, sys
payload = {
  "schema": 3,
  "release": sys.argv[1],
  "arch": sys.argv[2],
  "pins": {
    "node_major": sys.argv[3],
    "grok": sys.argv[4],
    "opencode": sys.argv[5],
    "openmausbot": sys.argv[6],
    "unity_cli": sys.argv[7],
    "godot": "4.7.2",
    "gitea": sys.argv[9],
  },
  "extra_packages": [p for p in sys.argv[8].split(",") if p],
  "jenkins_plugins": sorted(set(sys.argv[10].split())),
  "jenkins_plugin_resolver": sys.argv[11],
  "seeds": [
    "git", "ripgrep", "openssh-server", "gh",
    "docker-ce", "nvidia-container-toolkit", "jenkins", "nodejs",
    "unity-cli", "godot", "gitea", "apt-sources",
    "fontconfig", "libharfbuzz0b", "python3-bcrypt", "jenkins-plugins",
  ],
}
print(hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16])
FP
)"

if [[ "$FORCE" -ne 1 && -f "$OUT/manifest.json" && -d "$OUT/apt" ]]; then
  have_fp="$(python3 -c "import json;print(json.load(open('$OUT/manifest.json')).get('fingerprint',''))" 2>/dev/null || true)"
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

echo "== container: $(. /etc/os-release && echo "$PRETTY_NAME") arch=$ARCH =="

# 使用指定 Ubuntu 镜像, 避免容器默认源慢/不可达
cat > /etc/apt/sources.list <<SL
deb ${MIRROR} ${RELEASE} main restricted universe multiverse
deb ${MIRROR} ${RELEASE}-updates main restricted universe multiverse
deb ${MIRROR} ${RELEASE}-security main restricted universe multiverse
SL
# noble+ 可能用 deb822; 清掉以免冲突
rm -f /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg dpkg-dev apt-utils xz-utils

install -m 0755 -d /etc/apt/keyrings

# Docker CE
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${RELEASE} stable" \
  > /etc/apt/sources.list.d/docker.list

# NVIDIA Container Toolkit (toolkit only; no GPU driver)
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

apt-get update

# 导出第三方 apt 源种子: 装机 restore-online-apt.sh 写回 keyring + list/sources
# 与 software/*.sh 在线路径使用同一批 URL/密钥; 捆绑里有的全部写回 (不按 --skip 裁剪)
mkdir -p "$OUTDIR/apt-sources/keyrings" "$OUTDIR/apt-sources/sources.list.d"
cp -a /etc/apt/keyrings/docker.asc \
  /etc/apt/keyrings/nvidia-container-toolkit.asc \
  /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  /etc/apt/keyrings/jenkins-keyring.asc \
  "$OUTDIR/apt-sources/keyrings/"
# NodeSource 官方 setup 落在 /usr/share/keyrings + deb822 .sources
cp -a /usr/share/keyrings/nodesource.gpg "$OUTDIR/apt-sources/keyrings/"
cp -a /etc/apt/sources.list.d/docker.list \
  /etc/apt/sources.list.d/nvidia-container-toolkit.list \
  /etc/apt/sources.list.d/github-cli.list \
  /etc/apt/sources.list.d/jenkins.list \
  /etc/apt/sources.list.d/nodesource.sources \
  "$OUTDIR/apt-sources/sources.list.d/"
cat > "$OUTDIR/apt-sources/README.txt" <<'ASR'
Third-party apt keyrings + sources captured at fetch time.
restore-online-apt.sh copies every seed here onto the installed system after
leaving offline mode (Docker CE, GitHub CLI, NVIDIA container toolkit,
Jenkins, NodeSource). Online installs never use this directory.
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
)
IFS=',' read -r -a EXTRA <<< "$EXTRA_PACKAGES"
for p in "${EXTRA[@]}"; do
  p="$(echo "$p" | xargs)"
  [ -n "$p" ] && SEEDS+=("$p")
done

echo "seed packages (${#SEEDS[@]}): ${SEEDS[*]}"

# 下载完整依赖闭包到 archives (容器极简, 几乎全部会下)
apt-get install -y --download-only --reinstall -o Dir::Cache::archives=/var/cache/apt/archives \
  "${SEEDS[@]}" || apt-get install -y --download-only -o Dir::Cache::archives=/var/cache/apt/archives \
  "${SEEDS[@]}"

# 已装在容器里的依赖 (如 libcurl4t64) 不会因 --reinstall SEEDS 而被重新下载,
# 导致离线池缺依赖: curl_X 需要 libcurl4t64(=X) 但池里没有。强制把递归 Depends 也 download。
mapfile -t _dep_pkgs < <(
  apt-cache depends --recurse --no-recommends --no-suggests \
    --no-conflicts --no-breaks --no-replaces --no-enhances \
    "${SEEDS[@]}" 2>/dev/null \
    | awk '/^[A-Za-z0-9]/{print $1}' | sort -u
)
_dl=()
for _p in "${_dep_pkgs[@]}"; do
  # 跳过虚拟包 / 不存在的名字
  if apt-cache show "$_p" >/dev/null 2>&1; then
    _dl+=("$_p")
  fi
done
if [ "${#_dl[@]}" -gt 0 ]; then
  echo "force-download ${#_dl[@]} recursive depends (incl. already-installed)"
  # 分批, 避免命令行过长; 失败不致命 (个别过渡包可忽略)
  _i=0
  while [ "$_i" -lt "${#_dl[@]}" ]; do
    _chunk=("${_dl[@]:_i:40}")
    if ! apt-get install -y --download-only --reinstall \
      -o Dir::Cache::archives=/var/cache/apt/archives \
      "${_chunk[@]}"; then
      # 整批是一个事务: 批内有互斥的候选 (如 libqt5gui5t64 vs libqt5gui5-gles) 时整批作废,
      # 会把同批的 libpsl5t64 / python3.12 等一起漏掉。逐个 apt-get download (不解析依赖, 不会冲突)。
      echo "chunk failed; per-package download fallback (${#_chunk[@]})"
      ( cd /var/cache/apt/archives && for _q in "${_chunk[@]}"; do
          apt-get download -o APT::Sandbox::User=root "$_q" >/dev/null 2>&1 || echo "  skip: $_q"
        done )
    fi
    _i=$((_i + 40))
  done
fi

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

# Node 官方 tarball 兜底
mkdir -p "$OUTDIR/node"
TARBALL=$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/" \
  | grep -oE "node-v${NODE_MAJOR}\\.[0-9.]*-linux-x64\\.tar\\.xz" | head -1 || true)
if [ -n "$TARBALL" ]; then
  curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/${TARBALL}" \
    -o "$OUTDIR/node/${TARBALL}"
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

log "在 $IMG 中解析并下载 apt 依赖闭包"
mkdir -p "$WORK/out"
if [[ "$APT_RUNNER" == "direct" ]]; then
  log "direct 模式: 直接在当前容器 ($(. /etc/os-release && echo "$PRETTY_NAME"), $(dpkg --print-architecture)) 里跑 apt"
  FETCH_OUTDIR="$WORK/out" DEBIAN_FRONTEND=noninteractive \
    bash "$WORK/fetch-debs.sh" "$RELEASE" "$ARCH" "$PIN_NODE_MAJOR" "$UBUNTU_MIRROR" "$PACKAGES"
else
  docker run --rm --network host \
    --dns 8.8.8.8 --dns 1.1.1.1 \
    -v "$WORK/fetch-debs.sh:/fetch-debs.sh:ro" \
    -v "$WORK/out:/out" \
    -e DEBIAN_FRONTEND=noninteractive \
    "$IMG" bash /fetch-debs.sh "$RELEASE" "$ARCH" "$PIN_NODE_MAJOR" "$UBUNTU_MIRROR" "$PACKAGES"
fi

# 容器以 root 写 /out, 改回当前用户以免 cleanup/复用失败
if command -v sudo >/dev/null; then
  sudo chown -R "$(id -u):$(id -g)" "$WORK/out" 2>/dev/null || true
fi

# 同步到 OUT (保留可复用)
rm -rf "$OUT/apt" "$OUT/apt-sources" "$OUT/node" "$OUT/unity-cli" "$OUT/godot" "$OUT/gitea" "$OUT/jenkins-plugins" "$OUT/jenkins-version.txt" "$OUT/package-list.txt" "$OUT/java-package.txt"
mkdir -p "$OUT"
cp -a "$WORK/out/." "$OUT/"

# --------------- Jenkins 插件 (宿主机 python3; update center sha256 校验) ---------------
JVER="$(cat "$OUT/jenkins-version.txt")"
log "解析 Jenkins 插件 (Jenkins $JVER): $JENKINS_PLUGINS"
JP_DIR="$OUT/jenkins-plugins"
mkdir -p "$JP_DIR"
# shellcheck disable=SC2086
python3 "$RESOLVER" --jenkins-version "$JVER" --out "$JP_DIR" $JENKINS_PLUGINS \
  || die "Jenkins 插件解析/下载失败"
printf '%s' "$JVER" > "$JP_DIR/jenkins-version"
# shellcheck disable=SC2086
printf '%s\n' $JENKINS_PLUGINS | sort -u > "$JP_DIR/requested.txt"
ok "Jenkins 插件: $(wc -l < "$JP_DIR/plugins.lock") 个 ($(du -sh "$JP_DIR" | cut -f1))"

# --------------- npm 全局树 (宿主机 node, 与目标 arch 一致的 linux) ---------------
if [[ "$SKIP_NPM" -eq 0 ]]; then
  command -v npm >/dev/null || die "需要宿主机 npm 以打包全局 CLI"
  log "打包 npm 全局树 (grok=$PIN_GROK opencode=$PIN_OPENCODE openmausbot=$PIN_OPENMAUSBOT)"
  NPM_PREFIX="$WORK/npm-prefix"
  mkdir -p "$NPM_PREFIX"
  npm install -g --prefix "$NPM_PREFIX" \
    "@xai-official/grok@${PIN_GROK}" \
    "opencode-ai@${PIN_OPENCODE}" \
    "openmausbot@${PIN_OPENMAUSBOT}" \
    --no-audit --no-fund \
    --allow-scripts="@xai-official/grok,opencode-ai,openmausbot" || \
  npm install -g --prefix "$NPM_PREFIX" \
    "@xai-official/grok@${PIN_GROK}" \
    "opencode-ai@${PIN_OPENCODE}" \
    "openmausbot@${PIN_OPENMAUSBOT}" \
    --no-audit --no-fund --ignore-scripts
  mkdir -p "$OUT/npm"
  tar --owner=0 --group=0 --numeric-owner -czf "$OUT/npm/prefix.tar.gz" -C "$NPM_PREFIX" .
  ok "npm prefix $(du -h "$OUT/npm/prefix.tar.gz" | cut -f1)"
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
curl -fsSL "${UNITY_CDN}${UNITY_VERSION}/${UNITY_FILENAME}" -o "$UNITY_DIR/$UNITY_FILENAME" \
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
if ! curl -fL --retry 3 --retry-delay 2 -o "$GODOT_DIR/$GODOT_ZIP" "$GODOT_URL"; then
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
curl -fL --retry 3 --retry-delay 2 -o "$GITEA_DIR/$GITEA_FILE" "$GITEA_DL/$GITEA_VERSION/$GITEA_FILE" \
  || die "下载 Gitea 失败: $GITEA_DL/$GITEA_VERSION/$GITEA_FILE"
GITEA_SHA256="$(curl -fsSL "$GITEA_DL/$GITEA_VERSION/$GITEA_FILE.sha256" | awk '{print $1}')"
[[ "$GITEA_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "无法获取 Gitea 官方 sha256"
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
  "schema": 3,
  "fingerprint": "${expected_fp}",
  "release": "${RELEASE}",
  "arch": "${ARCH}",
  "created_at": "${CREATED}",
  "ubuntu_mirror": "${UBUNTU_MIRROR}",
  "pins": {
    "node_major": "${PIN_NODE_MAJOR}",
    "grok": "${PIN_GROK}",
    "opencode": "${PIN_OPENCODE}",
    "openmausbot": "${PIN_OPENMAUSBOT}",
    "unity_cli": "${PIN_UNITY_CLI}" or (unity_meta.get("version") or ""),
    "godot": "4.7.2",
    "gitea": "${PIN_GITEA}",
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
  "jenkins_plugins": jenkins_plugins_meta,
  "apt_sources": apt_sources_meta,
}
(out/"manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
print(json.dumps(manifest, indent=2, ensure_ascii=False))
PY

ok "离线捆绑完成: $OUT ($SIZE_HUMAN, ${APT_COUNT} debs)"
