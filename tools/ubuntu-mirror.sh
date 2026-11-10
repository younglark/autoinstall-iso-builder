#!/usr/bin/env bash
# =============================================================================
# ubuntu-mirror.sh — 默认 Ubuntu apt 源 (清华大学开源镜像, https)
#
# 干净容器 / 安装器 chroot 在装好 ca-certificates 之前, https 会因 TLS
# 无法校验而失败。本脚本在缺 CA 时先用同一清华源的 http 安装
# ca-certificates, 再把源切回 https 继续。apt 包仍由 GPG 签名校验。
#
# 只改 mirrors.tuna.tsinghua.edu.cn; 用户指定的其它源原样保留。
# 若用户给的是清华 http, 最终会升为 https。
#
# 用法 (source 后调用函数):
#   aib_bootstrap_apt_mirror <release> <mirror>   # 写入源并完成 bootstrap
#   aib_ensure_https_apt                          # 已有源: 缺 CA 则 http 引导再切 https
#   aib_apply_final_ubuntu_mirror <mirror>        # 装完把 Ubuntu 源写成最终 URL
#   aib_apply_builder_mirrors <apt> <ports>       # Dockerfile 构建器换源
#   aib_normalize_mirror <url>                    # 清华 http -> https, 其它不变
#
# 也可执行: tools/ubuntu-mirror.sh bootstrap <release> <mirror>
# =============================================================================

AIB_TUNA_HOST="mirrors.tuna.tsinghua.edu.cn"
AIB_DEFAULT_UBUNTU_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu"
AIB_DEFAULT_UBUNTU_PORTS_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports"

aib_default_ubuntu_mirror() {
  case "${1:-amd64}" in
    amd64|i386) printf '%s\n' "$AIB_DEFAULT_UBUNTU_MIRROR" ;;
    *)          printf '%s\n' "$AIB_DEFAULT_UBUNTU_PORTS_MIRROR" ;;
  esac
}

aib_is_tuna_mirror() {
  case "$1" in
    "http://${AIB_TUNA_HOST}"/*|"https://${AIB_TUNA_HOST}"/*) return 0 ;;
    "http://${AIB_TUNA_HOST}"|"https://${AIB_TUNA_HOST}") return 0 ;;
    *) return 1 ;;
  esac
}

aib_tuna_https() { printf '%s\n' "https://${1#*://}"; }
aib_tuna_http()  { printf '%s\n' "http://${1#*://}"; }

# 清华源统一成 https; 空值或其它主机原样返回。
aib_normalize_mirror() {
  local url="${1-}"
  if [[ -n "$url" ]] && aib_is_tuna_mirror "$url"; then
    aib_tuna_https "$url"
  else
    printf '%s\n' "$url"
  fi
}

aib_pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

aib_apt_codename() {
  # shellcheck disable=SC1091
  . /etc/os-release
  printf '%s\n' "${VERSION_CODENAME:-}"
}

aib_apt_etc() { printf '%s\n' "${APT_ETC:-/etc/apt}"; }

# 写入 legacy sources.list (含 -security), 清掉 noble+ 的 deb822 以免冲突。
aib_write_ubuntu_sources() {
  local release="$1" mirror="$2"
  local etc; etc="$(aib_apt_etc)"
  mkdir -p "$etc" "$etc/sources.list.d"
  cat > "$etc/sources.list" <<SL
deb ${mirror} ${release} main restricted universe multiverse
deb ${mirror} ${release}-updates main restricted universe multiverse
deb ${mirror} ${release}-security main restricted universe multiverse
SL
  rm -f "$etc/sources.list.d/ubuntu.sources" 2>/dev/null || true
}

# 只改清华主机的 scheme, 不动第三方源。ubuntu-ports 要写在 /ubuntu 前面。
aib_rewrite_tuna_scheme() {
  local scheme="$1" f from to
  if [[ "$scheme" == https ]]; then
    from='http://mirrors.tuna.tsinghua.edu.cn'
    to='https://mirrors.tuna.tsinghua.edu.cn'
  else
    from='https://mirrors.tuna.tsinghua.edu.cn'
    to='http://mirrors.tuna.tsinghua.edu.cn'
  fi
  local etc; etc="$(aib_apt_etc)"
  for f in "$etc/sources.list" "$etc/sources.list.d/ubuntu.sources" \
           "$etc/sources.list.d"/*.list "$etc/sources.list.d"/*.sources; do
    [[ -f "$f" ]] || continue
    case "$f" in *00-offline-bundle.list) continue ;; esac
    sed -i "s#${from}#${to}#g" "$f"
  done
}

# 把官方源 / 已有清华源的 URI 换成 $mirror (不碰第三方源)。
# 返回 0 表示改到了已有文件; 1 表示没找到可替换的 Ubuntu 源。
aib_replace_ubuntu_uris() {
  local new="$1" f found=0
  local etc; etc="$(aib_apt_etc)"
  for f in "$etc/sources.list" "$etc/sources.list.d/ubuntu.sources" \
           "$etc/sources.list.d"/*.list "$etc/sources.list.d"/*.sources; do
    [[ -f "$f" ]] || continue
    case "$f" in *00-offline-bundle.list) continue ;; esac
    if grep -qE 'https?://(archive\.ubuntu\.com/ubuntu|security\.ubuntu\.com/ubuntu|ports\.ubuntu\.com/ubuntu-ports|mirrors\.tuna\.tsinghua\.edu\.cn/ubuntu(-ports)?)' "$f"; then
      sed -i \
        -e "s#https\\?://archive.ubuntu.com/ubuntu#${new}#g" \
        -e "s#https\\?://security.ubuntu.com/ubuntu#${new}#g" \
        -e "s#https\\?://ports.ubuntu.com/ubuntu-ports#${new}#g" \
        -e "s#https\\?://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports#${new}#g" \
        -e "s#https\\?://mirrors.tuna.tsinghua.edu.cn/ubuntu#${new}#g" \
        "$f"
      found=1
    fi
  done
  [[ "$found" -eq 1 ]]
}

# 缺 CA 且目标是清华 https 时: 先 http 装 ca-certificates, 再切 https。
# 其它镜像按原样写源并 apt-get update。
aib_bootstrap_apt_mirror() {
  local release="$1" mirror="$2"
  local final boot
  export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

  if aib_is_tuna_mirror "$mirror"; then
    final="$(aib_tuna_https "$mirror")"
    if aib_pkg_installed ca-certificates; then
      aib_write_ubuntu_sources "$release" "$final"
      apt-get update
    else
      boot="$(aib_tuna_http "$mirror")"
      echo "bootstrap: ca-certificates 缺失, 先用 $boot 安装后再切到 $final"
      aib_write_ubuntu_sources "$release" "$boot"
      apt-get update
      apt-get install -y --no-install-recommends ca-certificates
      aib_write_ubuntu_sources "$release" "$final"
      apt-get update
    fi
  else
    aib_write_ubuntu_sources "$release" "$mirror"
    apt-get update
  fi
}

# 系统源已经配好时用 (安装器 chroot / 00-base 在线路径)。
# 不是清华源则什么都不做; 是清华且缺 CA 则 http 引导后再切 https。
aib_ensure_https_apt() {
  export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
  local etc; etc="$(aib_apt_etc)"
  if ! grep -RqsE 'https?://mirrors\.tuna\.tsinghua\.edu\.cn' \
       "$etc/sources.list" "$etc/sources.list.d" 2>/dev/null; then
    return 0
  fi
  if aib_pkg_installed ca-certificates; then
    aib_rewrite_tuna_scheme https
    return 0
  fi
  echo "bootstrap: ca-certificates 缺失, 临时改用 http 安装后再切回 https"
  aib_rewrite_tuna_scheme http
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates
  aib_rewrite_tuna_scheme https
  apt-get update
}

# 装完把 Ubuntu 源写成最终 URL (清华会规范成 https)。
aib_apply_final_ubuntu_mirror() {
  local mirror="$1" release
  [[ -n "$mirror" ]] || return 0
  mirror="$(aib_normalize_mirror "$mirror")"
  if aib_is_tuna_mirror "$mirror" && ! aib_pkg_installed ca-certificates; then
    aib_bootstrap_apt_mirror "$(aib_apt_codename)" "$mirror"
    return 0
  fi
  if aib_replace_ubuntu_uris "$mirror"; then
    return 0
  fi
  release="$(aib_apt_codename)"
  [[ -n "$release" ]] || return 0
  aib_write_ubuntu_sources "$release" "$mirror"
}

# Dockerfile: 把基础镜像的官方源换成 APT_MIRROR / APT_PORTS_MIRROR。
# 清华 https 且缺 CA 时先 http 引导。空值保留官方源。
aib_apply_builder_mirrors() {
  local apt_mirror="${1-}" ports_mirror="${2-}"
  local boot_apt boot_ports need_boot=0
  local f
  export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
  apt_mirror="$(aib_normalize_mirror "$apt_mirror")"
  ports_mirror="$(aib_normalize_mirror "$ports_mirror")"
  boot_apt="$apt_mirror"
  boot_ports="$ports_mirror"
  if ! aib_pkg_installed ca-certificates; then
    if aib_is_tuna_mirror "$apt_mirror"; then
      boot_apt="$(aib_tuna_http "$apt_mirror")"
      need_boot=1
    fi
    if aib_is_tuna_mirror "$ports_mirror"; then
      boot_ports="$(aib_tuna_http "$ports_mirror")"
      need_boot=1
    fi
  fi
  local etc; etc="$(aib_apt_etc)"
  for f in "$etc/sources.list.d/ubuntu.sources" "$etc/sources.list"; do
    [[ -f "$f" ]] || continue
    if [[ -n "$boot_apt" ]]; then
      sed -i \
        -e "s#http://archive.ubuntu.com/ubuntu#${boot_apt}#g" \
        -e "s#https://archive.ubuntu.com/ubuntu#${boot_apt}#g" \
        -e "s#http://security.ubuntu.com/ubuntu#${boot_apt}#g" \
        -e "s#https://security.ubuntu.com/ubuntu#${boot_apt}#g" \
        "$f"
    fi
    if [[ -n "$boot_ports" ]]; then
      sed -i \
        -e "s#http://ports.ubuntu.com/ubuntu-ports#${boot_ports}#g" \
        -e "s#https://ports.ubuntu.com/ubuntu-ports#${boot_ports}#g" \
        "$f"
    fi
  done
  apt-get update
  if [[ "$need_boot" -eq 1 ]]; then
    echo "bootstrap: ca-certificates 缺失, 已用 http 清华源, 安装后再切 https"
    apt-get install -y --no-install-recommends ca-certificates
    aib_rewrite_tuna_scheme https
    apt-get update
  fi
}

# 仅在被直接执行时跑 CLI；被 source 时不要跑（否则会抢调用方参数或直接 exit）。
# 用 $0 的文件名判断，避免 ${BASH_SOURCE[0]} / [[ ]]：dash/sh source 时那些会立刻
# Bad substitution（#21 container-smoke 就是这样挂的）。Dockerfile 里是
# `. /tmp/aib-ubuntu-mirror.sh`，$0 一般是 bash / sh / -c，不会匹配下面的名字。
# 直接执行 tools/ubuntu-mirror.sh，或拷成 aib-ubuntu-mirror.sh 再执行时，$0 才是脚本名。
# 函数体里的 [[ 仍是 bash 语法；构建器已用 SHELL bash，其它调用方也是 bash。
case "${0##*/}" in
  ubuntu-mirror.sh|aib-ubuntu-mirror.sh)
    set -euo pipefail
    cmd="${1:-}"
    case "$cmd" in
      bootstrap)
        aib_bootstrap_apt_mirror "${2:?release}" "${3:?mirror}"
        ;;
      normalize)
        aib_normalize_mirror "${2-}"
        ;;
      default)
        aib_default_ubuntu_mirror "${2:-amd64}"
        ;;
      *)
        echo "用法: $0 bootstrap <release> <mirror> | normalize <url> | default [arch]" >&2
        exit 2
        ;;
    esac
    ;;
esac
