#!/usr/bin/env bash
# =============================================================================
# 容器入口: aib <子命令> [参数...]
#   build             -> build-iso.sh
#   fetch-offline     -> tools/fetch-offline-bundle.sh   (apt-runner=direct, 无需 docker-in-docker)
#   validate-offline  -> tools/validate-offline-bundle.sh
#   check-iso ISO     -> test/qemu-smoke.sh ISO --guard-only (只读检查 user-data)
#   local-check       -> test/local-check.sh
#   shell             -> bash
#   help | version
#
# 文件属主: 设置 AIB_UID / AIB_GID (Linux 包装脚本自动传) 时,
#   不需要 root 的子命令降权为该 uid 运行; 需要 root 的 (fetch-offline、build --fetch-offline,
#   因为要在容器里 apt-get) 以 root 运行, 结束后把产出 chown 回该 uid。
# =============================================================================
set -Eeuo pipefail

AIB_HOME="${AIB_HOME:-/opt/aib}"
export OFFLINE_CACHE_ROOT="${OFFLINE_CACHE_ROOT:-/work/cache/offline-bundles}"
export AIB_APT_RUNNER="${AIB_APT_RUNNER:-direct}"
export HOME="${HOME:-/tmp}"

die() { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
autoinstall-iso-builder 容器 (version: ${AIB_VERSION:-dev}, $(. /etc/os-release && echo "$PRETTY_NAME"), $(dpkg --print-architecture))

用法: aib <子命令> [参数...]       (工作目录 /work = 宿主机挂载目录)

子命令:
  build [build-iso.sh 参数]             构建 autoinstall ISO      (aib build --help)
  fetch-offline [fetch 参数]            抓全离线捆绑 (需 linux/amd64, 发行版与镜像变体一致)
  validate-offline --bundle DIR [...]   校验离线捆绑
  check-iso ISO                         只读检查产出 ISO 的 user-data (qemu-smoke --guard-only)
  local-check                           仓库自带的组件级校验
  shell                                 进入 bash
  help | version

示例:
  aib build --iso ubuntu-24.04.3-live-server-amd64.iso --out out/node01.iso \\
            --hostname node01 --password 'Ch@ngeMe'
  aib fetch-offline --release noble --out cache/offline-bundles/noble-amd64
USAGE
}

# ---------------------------------------------------------------- 属主处理
OWNER_TARGETS=()
# 记录 path 的 "将被创建的最高祖先" (或已存在的 path 本身), 结束后 chown -R
note_owner_target() {
  local p="$1" cur prev
  [[ -n "$p" ]] || return 0
  [[ "$p" == /* ]] || p="$PWD/$p"
  cur="$p"
  prev="$p"
  while [[ ! -e "$cur" && "$cur" != "/" ]]; do
    prev="$cur"
    cur="$(dirname -- "$cur")"
  done
  if [[ -e "$p" ]]; then
    OWNER_TARGETS+=("$p")
  else
    OWNER_TARGETS+=("$prev")
  fi
}

fix_owner() {
  [[ -n "${AIB_UID:-}" && "$(id -u)" -eq 0 && "${AIB_UID}" != "0" ]] || return 0
  local t
  for t in "${OWNER_TARGETS[@]}"; do
    case "$t" in /work|/work/*|/mnt/aib*) ;; *) continue ;; esac
    if [[ -e "$t" ]]; then
      chown -R "${AIB_UID}:${AIB_GID:-$AIB_UID}" -- "$t" 2>/dev/null || true
    fi
  done
}

# 取某个选项的值 (--opt VAL)
opt_val() {
  local want="$1"; shift
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "$want" && $# -ge 2 ]]; then printf '%s' "$2"; return 0; fi
    shift
  done
  return 1
}
has_opt() {
  local a
  for a in "${@:2}"; do [[ "$a" == "$1" ]] && return 0; done
  return 1
}

# 以 AIB_UID 降权执行 (未设置或已非 root 则直接执行)
run_unprivileged() {
  if [[ -n "${AIB_UID:-}" && "$(id -u)" -eq 0 && "${AIB_UID}" != "0" ]]; then
    exec setpriv --reuid="$AIB_UID" --regid="${AIB_GID:-$AIB_UID}" --clear-groups \
      env HOME=/tmp "$@"
  fi
  exec "$@"
}

# 以 root 执行并在结束后修正属主
run_root_then_chown() {
  local rc=0
  "$@" || rc=$?
  fix_owner
  return "$rc"
}

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift

case "$cmd" in
  build)
    if has_opt --fetch-offline "$@" || has_opt --force-fetch "$@"; then
      [[ "$(id -u)" -eq 0 ]] || die "build --fetch-offline 需要容器以 root 运行 (容器内 apt-get); 不要加 docker --user, 用 AIB_UID/AIB_GID 修正属主"
      note_owner_target "$(opt_val --out "$@" || true)"
      note_owner_target "$(opt_val --offline-bundle "$@" || echo "$OFFLINE_CACHE_ROOT")"
      note_owner_target "${AIB_APT_CACHE:-$(dirname -- "$OFFLINE_CACHE_ROOT")/apt-archives}"
      run_root_then_chown bash "$AIB_HOME/build-iso.sh" "$@"
    else
      run_unprivileged bash "$AIB_HOME/build-iso.sh" "$@"
    fi
    ;;
  fetch-offline|fetch)
    if has_opt -h "$@" || has_opt --help "$@"; then
      exec bash "$AIB_HOME/tools/fetch-offline-bundle.sh" --help
    fi
    [[ "$(id -u)" -eq 0 ]] || die "fetch-offline 需要容器以 root 运行 (容器内 apt-get); 不要加 docker --user, 用 AIB_UID/AIB_GID 修正属主"
    note_owner_target "$(opt_val --out "$@" || true)"
    note_owner_target "$(opt_val --cache-root "$@" || echo "$OFFLINE_CACHE_ROOT")"
    # deb 缓存 (fetch-offline-bundle 默认 <cache-root>/../apt-archives)
    if _ac="$(opt_val --apt-cache "$@")"; then
      note_owner_target "$_ac"
    else
      note_owner_target "${AIB_APT_CACHE:-$(dirname -- "$(opt_val --cache-root "$@" || echo "$OFFLINE_CACHE_ROOT")")/apt-archives}"
    fi
    run_root_then_chown bash "$AIB_HOME/tools/fetch-offline-bundle.sh" "$@"
    ;;
  validate-offline|validate)
    run_unprivileged bash "$AIB_HOME/tools/validate-offline-bundle.sh" "$@"
    ;;
  check-iso)
    [[ $# -ge 1 ]] || die "用法: aib check-iso <产出的 ISO>"
    run_unprivileged bash "$AIB_HOME/test/qemu-smoke.sh" "$1" --guard-only
    ;;
  local-check)
    run_unprivileged bash "$AIB_HOME/test/local-check.sh" "$@"
    ;;
  shell|bash|sh)
    run_unprivileged bash "$@"
    ;;
  version|--version)
    echo "${AIB_VERSION:-dev}"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    die "未知子命令: $cmd"
    ;;
esac
