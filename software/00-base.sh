#!/bin/bash
# 00-base.sh — 基础环境与 apt 前置
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

mkdir -p /usr/sbin
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d

mkdir -p /etc/apt/apt.conf.d
printf 'APT::Get::Assume-Yes "true";\nDpkg::Options { "--force-confdef"; "--force-confold"; };\n' \
  > /etc/apt/apt.conf.d/99autoinstall

# 已安装 (任意版本) 则跳过, 避免离线捆绑里较新 curl 与 ISO 自带 libcurl4t64 版本冲突。
pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

filter_missing() {
  local p
  MISSING_PKGS=()
  for p in "$@"; do
    [ -n "$p" ] || continue
    if pkg_installed "$p"; then
      echo "skip already installed: $p ($(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || echo '?'))"
    else
      MISSING_PKGS+=("$p")
    fi
  done
}

BASE_PKGS=(ca-certificates curl gnupg jq git ripgrep unzip lsb-release apt-transport-https)

if offline_enabled 2>/dev/null && offline_apt_ready 2>/dev/null; then
  echo "offline: 跳过 DNS/外网, 使用本地 apt"
  apt-get update
  filter_missing "${BASE_PKGS[@]}"
  if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    echo "offline: 安装缺失基础包: ${MISSING_PKGS[*]}"
    offline_apt_install "${MISSING_PKGS[@]}"
  else
    echo "offline: 基础包均已满足, 跳过"
  fi
  # 用户 --packages 在离线模式下改由这里安装 (autoinstall.packages 置空以免安装器联网)
  if [ -n "${EXTRA_APT_PACKAGES:-}" ]; then
    # shellcheck disable=SC2086
    IFS=',' read -r -a _extra <<< "$EXTRA_APT_PACKAGES"
    extra_clean=()
    for p in "${_extra[@]}"; do
      p="$(echo "$p" | xargs)"
      [ -n "$p" ] && extra_clean+=("$p")
    done
    if [ "${#extra_clean[@]}" -gt 0 ]; then
      filter_missing "${extra_clean[@]}"
      if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
        echo "offline: 安装 EXTRA_APT_PACKAGES(缺失): ${MISSING_PKGS[*]}"
        offline_apt_install "${MISSING_PKGS[@]}"
      else
        echo "offline: EXTRA_APT_PACKAGES 均已满足, 跳过"
      fi
    fi
  fi
else
  # 默认源是清华; 同时探测官方源, 避免只有一边能解析时误判 DNS 坏了
  if ! getent hosts mirrors.tuna.tsinghua.edu.cn >/dev/null 2>&1 \
     && ! getent hosts archive.ubuntu.com >/dev/null 2>&1; then
    echo "resolv.conf 不可用, 临时写入公共 DNS"
    rm -f /etc/resolv.conf
    {
      echo "nameserver 223.5.5.5"
      echo "nameserver 1.1.1.1"
    } > /etc/resolv.conf
  fi
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg jq git ripgrep unzip lsb-release apt-transport-https
fi

echo "base ok: $(. /etc/os-release && echo "$PRETTY_NAME") offline=${OFFLINE:-0}"
