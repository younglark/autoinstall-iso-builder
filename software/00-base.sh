#!/bin/bash
# 00-base.sh — 基础环境与 apt 前置
#
# 三条关键处理, 少一条后面就会连环失败:
#   1. chroot 里没有 systemd PID1, 用 policy-rc.d 拦住 postinst 的启动动作
#   2. resolv.conf 在目标系统里指向 systemd-resolved, chroot 下不可用, 临时落地
#   3. needrestart 在非交互模式下会卡住, 直接放行
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# --- 2. 让 chroot 里能解析域名 -------------------------------------------
if ! getent hosts archive.ubuntu.com >/dev/null 2>&1; then
  echo "resolv.conf 不可用, 临时写入公共 DNS"
  rm -f /etc/resolv.conf
  {
    echo "nameserver 223.5.5.5"
    echo "nameserver 1.1.1.1"
  } > /etc/resolv.conf
fi

# --- 1. 禁止 deb 安装过程中启动服务 --------------------------------------
mkdir -p /usr/sbin
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d

# --- 3. 非交互 -------------------------------------------------------------
mkdir -p /etc/apt/apt.conf.d
printf 'APT::Get::Assume-Yes "true";\nDpkg::Options { "--force-confdef"; "--force-confold"; };\n' \
  > /etc/apt/apt.conf.d/99autoinstall

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg jq git unzip lsb-release apt-transport-https

echo "base ok: $(. /etc/os-release && echo "$PRETTY_NAME")"
