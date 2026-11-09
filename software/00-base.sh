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

if offline_enabled 2>/dev/null && offline_apt_ready 2>/dev/null; then
  echo "offline: 跳过 DNS/外网, 使用本地 apt"
  apt-get update
  offline_apt_install ca-certificates curl gnupg jq git unzip lsb-release apt-transport-https || true
  # 用户 --packages 在离线模式下改由这里安装 (autoinstall.packages 置空以免安装器联网)
  if [ -n "${EXTRA_APT_PACKAGES:-}" ]; then
    # shellcheck disable=SC2086
    IFS=',' read -r -a _extra <<< "$EXTRA_APT_PACKAGES"
    pkgs=()
    for p in "${_extra[@]}"; do
      p="$(echo "$p" | xargs)"
      [ -n "$p" ] && pkgs+=("$p")
    done
    if [ "${#pkgs[@]}" -gt 0 ]; then
      echo "offline: 安装 EXTRA_APT_PACKAGES: ${pkgs[*]}"
      offline_apt_install "${pkgs[@]}"
    fi
  fi
else
  if ! getent hosts archive.ubuntu.com >/dev/null 2>&1; then
    echo "resolv.conf 不可用, 临时写入公共 DNS"
    rm -f /etc/resolv.conf
    {
      echo "nameserver 223.5.5.5"
      echo "nameserver 1.1.1.1"
    } > /etc/resolv.conf
  fi
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg jq git unzip lsb-release apt-transport-https
fi

echo "base ok: $(. /etc/os-release && echo "$PRETTY_NAME") offline=${OFFLINE:-0}"
