#!/usr/bin/env bash
# =============================================================================
# aib.sh — 在 macOS / Linux (含 WSL2) 上用容器运行 autoinstall-iso-builder
#
#   ./scripts/aib.sh [包装选项] <子命令> [子命令参数...]
#
# 包装选项 (必须写在子命令之前):
#   (默认)           用本地镜像 autoinstall-iso-builder:local (抓 22.04 捆绑用 :local-jammy);
#                    不存在时自动用本仓库 Dockerfile docker build (首次约 3-10 分钟, 之后秒级)
#   --rebuild        强制重新 docker build 本地镜像 (git pull 更新仓库后用; 仍复用未变的层缓存)
#   --image REF      改用指定的完整镜像引用 (自建/内网仓库), 不再自动构建 (或环境变量 AIB_IMAGE)
#   --local          兼容旧用法, 等同默认 (无操作)
#   --platform P     覆盖 docker --platform (默认: 需要 apt 解析的步骤强制 linux/amd64, 其余原生)
#   --docker-arg A   追加一个 docker run 参数, 可重复 (如 --docker-arg --network=host);
#                    也可用环境变量 AIB_DOCKER_ARGS="--network=host -e HTTPS_PROXY=..." (按空白切分)
#   (环境变量 AIB_BUILD_ARGS="--network=host ..." 追加到自动 docker build, 如代理/DNS 受限环境;
#    APT_MIRROR=URL 作为 --build-arg 传给 docker build 换 apt 源;
#    Dockerfile 默认已是清华源, 空值 APT_MIRROR= 可回到官方源)
#   --dry-run        只打印将执行的 docker 命令, 不运行 (不需要 docker)
#   -h, --help
#
# 子命令: build | fetch-offline | validate-offline | check-iso | local-check | shell | help | version
#
# 路径处理: 当前目录挂到容器 /work; --iso/--out/--offline-bundle 等路径参数若在当前目录外,
#   自动把其父目录挂到 /mnt/aibN 并改写参数。Linux 上产出文件属主为当前用户。
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

IMAGE="${AIB_IMAGE:-}"          # 空 = 本地构建的镜像
LOCAL_REPO="autoinstall-iso-builder"
REBUILD=0
PLATFORM="${AIB_PLATFORM:-}"
DRY_RUN=0
EXTRA_DOCKER_ARGS=()
if [[ -n "${AIB_DOCKER_ARGS:-}" ]]; then
  read -r -a EXTRA_DOCKER_ARGS <<< "$AIB_DOCKER_ARGS"
fi

die() { printf '[aib] 错误: %s\n' "$*" >&2; exit 1; }
info() { printf '[aib] %s\n' "$*" >&2; }

usage() { sed -n '3,/^# ====*$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

# 带路径值的选项 (build / fetch-offline / validate-offline 共用)
PATH_OPTS=" --iso --out --offline-bundle --ssh-authorized-keys --debs --iso-sha256sums --cache-root --bundle --apt-cache "
# 其中是「输出」的 (父目录不存在时自动创建)
OUT_OPTS=" --out --offline-bundle --cache-root --apt-cache "

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) [[ $# -ge 2 ]] || die "--image 需要参数"; IMAGE="$2"; shift 2 ;;
    --rebuild) REBUILD=1; shift ;;
    --local) shift ;;
    --platform) [[ $# -ge 2 ]] || die "--platform 需要参数"; PLATFORM="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --docker-arg) [[ $# -ge 2 ]] || die "--docker-arg 需要参数"; EXTRA_DOCKER_ARGS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "未知包装选项: $1 (子命令参数请写在子命令之后)" ;;
    *) break ;;
  esac
done

[[ $# -gt 0 ]] || { usage; exit 1; }
SUBCMD="$1"; shift
ARGS=("$@")

# ---------------------------------------------------------------- 工具函数
# 纯词法规范化 (不要求路径存在; 兼容 macOS 无 realpath -m)
normalize_path() {
  local p="$1" part parts=() out=() IFS='/'
  [[ "$p" == /* ]] || p="$PWD/$p"
  read -r -a parts <<< "$p"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..) [[ ${#out[@]} -gt 0 ]] && unset 'out[${#out[@]}-1]' ;;
      *) out+=("$part") ;;
    esac
  done
  if [[ ${#out[@]} -eq 0 ]]; then printf '/'; else printf '/%s' "${out[@]}"; fi
}

CWD="$(normalize_path "$PWD")"
MOUNT_SRCS=()   # 宿主机目录
MOUNT_DSTS=()   # 容器目录

# 宿主机路径 -> 容器路径 (必要时追加挂载)。结果写到全局 CPATH
# (不能用 $(...) 调用: 子 shell 里追加的挂载会丢失)
CPATH=""
to_container_path() {
  local host="$1" is_out="$2" abs parent base i dst
  abs="$(normalize_path "$host")"
  if [[ "$abs" == "$CWD" ]]; then CPATH="/work"; return; fi
  if [[ "$CWD" == "/" ]]; then CPATH="/work$abs"; return; fi
  if [[ "$abs" == "$CWD"/* ]]; then CPATH="/work/${abs#"$CWD"/}"; return; fi
  parent="$(dirname -- "$abs")"
  base="$(basename -- "$abs")"
  if [[ "$is_out" == 1 && ! -d "$parent" && "$DRY_RUN" -eq 0 ]]; then
    mkdir -p -- "$parent"
  fi
  for ((i = 0; i < ${#MOUNT_SRCS[@]}; i++)); do
    if [[ "${MOUNT_SRCS[$i]}" == "$parent" ]]; then
      CPATH="${MOUNT_DSTS[$i]}/$base"; return
    fi
  done
  dst="/mnt/aib$(( ${#MOUNT_SRCS[@]} + 1 ))"
  MOUNT_SRCS+=("$parent")
  MOUNT_DSTS+=("$dst")
  CPATH="$dst/$base"
}

# 取子命令参数里 --opt 的值 (没有则输出 x)
arg_val() {
  local j v="x"
  for ((j = 0; j + 1 < ${#ARGS[@]}; j++)); do
    if [[ "${ARGS[$j]}" == "$1" ]]; then v="${ARGS[$((j + 1))]}"; fi
  done
  printf '%s' "$v"
}
has_arg() { local a; for a in "${ARGS[@]+"${ARGS[@]}"}"; do [[ "$a" == "$1" ]] && return 0; done; return 1; }

# ---------------------------------------------------------------- 改写参数
NEW_ARGS=()
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  a="${ARGS[$i]}"
  if [[ "$PATH_OPTS" == *" $a "* && $((i + 1)) -lt ${#ARGS[@]} ]]; then
    is_out=0; [[ "$OUT_OPTS" == *" $a "* ]] && is_out=1
    # 子命令 build 的 --out 是文件, 其余 --out 是目录; 都按父目录挂载即可
    to_container_path "${ARGS[$((i + 1))]}" "$is_out"
    NEW_ARGS+=("$a" "$CPATH")
    i=$((i + 2))
    continue
  fi
  NEW_ARGS+=("$a")
  i=$((i + 1))
done
# check-iso 的第一个位置参数是 ISO 路径
if [[ "$SUBCMD" == "check-iso" && ${#NEW_ARGS[@]} -ge 1 ]]; then
  to_container_path "${NEW_ARGS[0]}" 0
  NEW_ARGS[0]="$CPATH"
fi

# ---------------------------------------------------------------- 选镜像 / 平台
VARIANT=""
NEEDS_AMD64=0
case "$SUBCMD" in
  fetch-offline|fetch)
    NEEDS_AMD64=1
    case "$(arg_val --release)" in jammy|22.04) VARIANT="-jammy" ;; esac
    ;;
  build)
    if has_arg --fetch-offline || has_arg --force-fetch; then
      NEEDS_AMD64=1
      # build 在容器内按 ISO 识别 release; 22.04 ISO + --fetch-offline 需 jammy 变体
      case "$(basename -- "$(arg_val --iso)")" in
        *22.04*|*jammy*) VARIANT="-jammy" ;;
      esac
    fi
    ;;
esac
if [[ -z "$PLATFORM" && "$NEEDS_AMD64" -eq 1 ]]; then
  PLATFORM="linux/amd64"
fi

# 本地镜像 tag: local[-jammy][-<arch>]; 只有强制平台与本机架构不同 (如 Apple Silicon 抓捆绑)
# 才加架构后缀, 避免同一 tag 在 arm64/amd64 之间来回覆盖
normalize_arch() {
  case "$1" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) echo "$1" ;; esac
}
ARCH_SUFFIX=""
if [[ -n "$PLATFORM" ]]; then
  want_arch="$(normalize_arch "${PLATFORM#*/}")"
  if [[ "$want_arch" != "$(normalize_arch "$(uname -m)")" ]]; then ARCH_SUFFIX="-$want_arch"; fi
fi
if [[ -n "$IMAGE" ]]; then
  IMAGE_REF="$IMAGE"
  AUTO_BUILD=0
else
  IMAGE_REF="${LOCAL_REPO}:local${VARIANT}${ARCH_SUFFIX}"
  AUTO_BUILD=1
fi
[[ "$REBUILD" -eq 1 && "$AUTO_BUILD" -eq 0 ]] && die "--rebuild 只作用于本地镜像, 不能与 --image 同用"

# ---------------------------------------------------------------- 组装 docker 命令
DOCKER=(docker run --rm)
if [[ -t 0 && -t 1 ]]; then DOCKER+=(-it); fi
[[ -n "$PLATFORM" ]] && DOCKER+=(--platform "$PLATFORM")
# Git Bash / MSYS (Windows): docker.exe 需要 Windows 路径 (/c/Users/x -> C:\Users\x)
host_src() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) if command -v cygpath >/dev/null; then cygpath -w "$1"; return; fi ;;
  esac
  printf '%s' "$1"
}
DOCKER+=(--mount "type=bind,source=$(host_src "$CWD"),target=/work" -w /work)
for ((i = 0; i < ${#MOUNT_SRCS[@]}; i++)); do
  [[ "${MOUNT_SRCS[$i]}" != *,* ]] || die "路径含逗号, docker --mount 不支持: ${MOUNT_SRCS[$i]}"
  DOCKER+=(--mount "type=bind,source=$(host_src "${MOUNT_SRCS[$i]}"),target=${MOUNT_DSTS[$i]}")
done
[[ "$CWD" != *,* ]] || die "当前目录含逗号, docker --mount 不支持: $CWD"
# Linux (含 WSL2): 让产出属于当前用户
if [[ "$(uname -s)" == "Linux" && "$(id -u)" -ne 0 ]]; then
  DOCKER+=(-e "AIB_UID=$(id -u)" -e "AIB_GID=$(id -g)")
fi
for v in PIN_NODE_MAJOR PIN_GROK PIN_OPENCODE PIN_OPENMAUSBOT PIN_UNITY_CLI PIN_GITEA PIN_RUSTDESK PIN_NVIDIA_DRIVER NVIDIA_KERNEL_FLAVOUR NVIDIA_KERNEL_FLAVOURS PIN_GROK_BOT GROK_BOT_DEB_URL GROK_BOT_SHA256 UBUNTU_MIRROR UNITY_CLI_CDN_BASE RUSTDESK_DL_BASE; do
  [[ -n "${!v:-}" ]] && DOCKER+=(-e "$v=${!v}")
done
DOCKER+=("${EXTRA_DOCKER_ARGS[@]+"${EXTRA_DOCKER_ARGS[@]}"}")
DOCKER+=("$IMAGE_REF" "$SUBCMD")
DOCKER+=("${NEW_ARGS[@]+"${NEW_ARGS[@]}"}")

print_cmd() {
  local line="" a prev=""
  for a in "$@"; do
    if [[ "$prev" == "--password" || "$prev" == "--gitea-admin-password" || "$prev" == "--jenkins-admin-password" || "$prev" == "--vnc-password" || "$prev" == "--rustdesk-password" ]]; then a="***"; fi
    if [[ "$a" =~ ^[A-Za-z0-9_./:=,@+%-]+$ ]]; then
      line="${line}${a} "
    else
      line="${line}'${a//\'/\'\\\'\'}' "
    fi
    prev="$a"
  done
  printf '%s\n' "${line% }"
}

REVISION=""
if command -v git >/dev/null && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
fi
if [[ "$AUTO_BUILD" -eq 1 ]]; then
  [[ -f "$REPO_ROOT/Dockerfile" ]] || die "找不到 $REPO_ROOT/Dockerfile; 请在完整仓库里运行, 或用 --image 指定镜像"
  ubuntu_version="24.04"; [[ "$VARIANT" == "-jammy" ]] && ubuntu_version="22.04"
  BUILD_CMD=(docker build -t "$IMAGE_REF" --build-arg "UBUNTU_VERSION=$ubuntu_version")
  [[ -n "$PLATFORM" ]] && BUILD_CMD+=(--platform "$PLATFORM")
  [[ -n "${APT_MIRROR:-}" ]] && BUILD_CMD+=(--build-arg "APT_MIRROR=$APT_MIRROR")
  if [[ -n "${AIB_BUILD_ARGS:-}" ]]; then
    read -r -a _extra_build <<< "$AIB_BUILD_ARGS"
    BUILD_CMD+=("${_extra_build[@]}")
  fi
  # 只打 label, 不传 build-arg (build-arg 变化会让 apt 层缓存失效)
  [[ -n "$REVISION" ]] && BUILD_CMD+=(--label "aib.revision=$REVISION")
  BUILD_CMD+=("$REPO_ROOT")
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$AUTO_BUILD" -eq 1 ]]; then
    if [[ "$REBUILD" -eq 1 ]]; then echo "# --rebuild: 先构建镜像"; else echo "# 本地镜像不存在时先构建:"; fi
    print_cmd "${BUILD_CMD[@]}"
  fi
  print_cmd "${DOCKER[@]}"
  exit 0
fi

command -v docker >/dev/null || die "未找到 docker。macOS/Windows 请安装 Docker Desktop (或 OrbStack/Colima), Linux 安装 docker engine"
docker info >/dev/null 2>&1 || die "docker 守护进程不可用 (Docker Desktop 是否已启动?)"

# Git Bash / MSYS: 阻止把 /work 之类参数改写成 Windows 路径
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' ;; esac

if [[ "$AUTO_BUILD" -eq 1 ]]; then
  if [[ "$REBUILD" -eq 1 ]]; then
    info "重新构建本地镜像 $IMAGE_REF"
    "${BUILD_CMD[@]}" >&2
  elif ! docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
    info "本地镜像 $IMAGE_REF 不存在, 首次构建 (约 3-10 分钟, 取决于网络; Dockerfile 默认清华 apt 源, 换源可设 APT_MIRROR=...)"
    "${BUILD_CMD[@]}" >&2
  elif [[ -n "$REVISION" ]]; then
    have_rev="$(docker image inspect -f '{{ index .Config.Labels "aib.revision" }}' "$IMAGE_REF" 2>/dev/null || true)"
    if [[ -n "$have_rev" && "$have_rev" != "$REVISION" ]]; then
      info "提示: 本地镜像构建于 ${have_rev:0:7}, 仓库已是 ${REVISION:0:7}; 如脚本有更新请加 --rebuild"
    fi
  fi
fi

if [[ "$NEEDS_AMD64" -eq 1 && "$(uname -m)" =~ ^(arm64|aarch64)$ ]]; then
  info "ARM 主机: apt 解析步骤以 linux/amd64 仿真运行 (Docker Desktop: 建议开启 Rosetta), 会比较慢"
fi

exec "${DOCKER[@]}"
