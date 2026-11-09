#!/usr/bin/env bash
# =============================================================================
# fetch-offline-bundle.sh — 为指定 Ubuntu 发行版构建「全离线」软件包捆绑
#
# 产出目录结构:
#   <out>/
#     manifest.json
#     apt/                 # file:/ apt 源 (Packages + *.deb)
#     npm/prefix.tar.gz    # 预装的全局 npm 树 (解压到 /usr/local)
#     node/                # 官方 Node tarball (nodesource 失败时的兜底)
#     package-list.txt
#
# 依赖: docker (推荐), 宿主机 node/npm (打 npm 包)。无 docker 时退出并提示。
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
SKIP_NPM=0
FORCE=0
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
  --ubuntu-mirror URL   容器内 Ubuntu 源
  --skip-npm            不打包 npm 全局树 (调试用)
  --force               忽略已有 manifest, 强制重建
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
    --ubuntu-mirror) UBUNTU_MIRROR="$2"; shift 2 ;;
    --skip-npm) SKIP_NPM=1; shift ;;
    --force) FORCE=1; shift ;;
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

if [[ -z "$OUT" ]]; then
  OUT="$CACHE_ROOT/${RELEASE}-${ARCH}"
fi

command -v docker >/dev/null || die "需要 docker 来解析目标发行版依赖 (docker pull ubuntu:${RELEASE})"
docker info >/dev/null 2>&1 || die "dockerd 不可用: docker info 失败"

if [[ "$FORCE" -ne 1 && -f "$OUT/manifest.json" && -d "$OUT/apt" ]]; then
  ok "复用已有捆绑: $OUT ($(du -sh "$OUT" | cut -f1))"
  python3 -c "import json;print(json.dumps(json.load(open('$OUT/manifest.json')),indent=2,ensure_ascii=False))" 2>/dev/null || true
  exit 0
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

log "拉取/使用镜像 $IMG"
docker pull "$IMG" >/dev/null

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
OUTDIR="/out"

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

JAVA_PKG=""
for p in openjdk-21-jre-headless openjdk-17-jre-headless; do
  if apt-cache show "$p" >/dev/null 2>&1; then JAVA_PKG="$p"; break; fi
done
[ -n "$JAVA_PKG" ] || { echo "ERROR: no suitable OpenJDK"; exit 1; }

# seed: 预装栈 + base 工具 + 用户 packages
# shellcheck disable=SC2206
SEEDS=(
  ca-certificates curl gnupg jq git unzip lsb-release apt-transport-https
  openssh-server
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  "$JAVA_PKG" jenkins
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
    apt-get install -y --download-only --reinstall \
      -o Dir::Cache::archives=/var/cache/apt/archives \
      "${_chunk[@]}" || true
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
INNER
chmod +x "$WORK/fetch-debs.sh"

log "在 $IMG 中解析并下载 apt 依赖闭包"
mkdir -p "$WORK/out"
docker run --rm --network host \
  --dns 8.8.8.8 --dns 1.1.1.1 \
  -v "$WORK/fetch-debs.sh:/fetch-debs.sh:ro" \
  -v "$WORK/out:/out" \
  -e DEBIAN_FRONTEND=noninteractive \
  "$IMG" bash /fetch-debs.sh "$RELEASE" "$ARCH" "$PIN_NODE_MAJOR" "$UBUNTU_MIRROR" "$PACKAGES"

# 容器以 root 写 /out, 改回当前用户以免 cleanup/复用失败
if command -v sudo >/dev/null; then
  sudo chown -R "$(id -u):$(id -g)" "$WORK/out" 2>/dev/null || true
fi

# 同步到 OUT (保留可复用)
rm -rf "$OUT/apt" "$OUT/node" "$OUT/package-list.txt" "$OUT/java-package.txt"
mkdir -p "$OUT"
cp -a "$WORK/out/." "$OUT/"

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
  tar -czf "$OUT/npm/prefix.tar.gz" -C "$NPM_PREFIX" .
  ok "npm prefix $(du -h "$OUT/npm/prefix.tar.gz" | cut -f1)"
else
  warn "跳过 npm (--skip-npm)"
  mkdir -p "$OUT/npm"
  : > "$OUT/npm/.skipped"
fi

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
manifest = {
  "schema": 1,
  "release": "${RELEASE}",
  "arch": "${ARCH}",
  "created_at": "${CREATED}",
  "ubuntu_mirror": "${UBUNTU_MIRROR}",
  "pins": {
    "node_major": "${PIN_NODE_MAJOR}",
    "grok": "${PIN_GROK}",
    "opencode": "${PIN_OPENCODE}",
    "openmausbot": "${PIN_OPENMAUSBOT}",
  },
  "extra_packages": [p.strip() for p in "${PACKAGES}".split(",") if p.strip()],
  "apt_deb_count": len(debs),
  "size_bytes": int("${SIZE_BYTES}"),
  "size_human": "${SIZE_HUMAN}",
  "npm_prefix": (out/"npm/prefix.tar.gz").exists(),
  "node_tarballs": node,
  "java_package": (out/"java-package.txt").read_text().strip() if (out/"java-package.txt").exists() else None,
}
(out/"manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
print(json.dumps(manifest, indent=2, ensure_ascii=False))
PY

ok "离线捆绑完成: $OUT ($SIZE_HUMAN, ${APT_COUNT} debs)"
