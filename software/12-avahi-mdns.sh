#!/bin/bash
# 12-avahi-mdns.sh — mDNS (Avahi): 让局域网用 <主机名>.local 访问本机 Gitea / Jenkins
#
# 由 provision.env 控制 (build-iso.sh: Gitea 或 Jenkins 未被 --skip 时写 MDNS_AVAHI=1):
#   * 安装 avahi-daemon + libnss-mdns (Desktop 自带, 已装则跳过; Server 补装; 离线走捆绑)
#   * enable avahi-daemon.service (发布 <主机名>.local)
#   * ufw 已启用才放行 5353/udp (mDNS); 不会主动启用 ufw
# MDNS_AVAHI!=1 时什么都不做。
#
# 测试钩子: AIB_SKIP_PKG=1 跳过 apt/systemctl/ufw。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
# shellcheck disable=SC1091
[ -f "$HERE/lib-service-url.sh" ] && . "$HERE/lib-service-url.sh"
export DEBIAN_FRONTEND=noninteractive

SKIP_PKG="${AIB_SKIP_PKG:-0}"
PKGS=(avahi-daemon libnss-mdns)

if [ "${MDNS_AVAHI:-0}" != "1" ]; then
  echo "skip: 未预装 Gitea / Jenkins (MDNS_AVAHI=${MDNS_AVAHI:-0}), 不装 Avahi"
  exit 0
fi

installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

if [ "$SKIP_PKG" != "1" ]; then
  missing=()
  for p in "${PKGS[@]}"; do installed "$p" || missing+=("$p"); done
  if [ "${#missing[@]}" -eq 0 ]; then
    echo "avahi-daemon / libnss-mdns 已安装, 跳过 apt"
  elif offline_enabled 2>/dev/null && offline_apt_ready 2>/dev/null; then
    echo "offline: 从本地 apt 安装 ${missing[*]}"
    offline_apt_install "${missing[@]}"
  else
    apt-get update
    apt-get install -y --no-install-recommends "${missing[@]}"
  fi
  for p in "${PKGS[@]}"; do installed "$p" || { echo "ERROR: $p 未安装成功"; exit 1; }; done

  systemctl enable avahi-daemon.service 2>/dev/null \
    || ln -sfn /lib/systemd/system/avahi-daemon.service /etc/systemd/system/multi-user.target.wants/avahi-daemon.service
  systemctl enable avahi-daemon.socket 2>/dev/null || true

  # libnss-mdns postinst 会把 mdns4_minimal 写进 nsswitch hosts; 这里只校验, 不改
  grep -q '^hosts:.*mdns' /etc/nsswitch.conf 2>/dev/null \
    || echo "warn: /etc/nsswitch.conf 的 hosts 行没有 mdns (本机解析 .local 可能失败; 不影响别人访问本机)"

  # ufw 已启用才放行 (与 36-x11vnc 相同: chroot 内可能失败, 只告警)
  if [ -f /etc/ufw/ufw.conf ] && grep -q '^ENABLED=yes' /etc/ufw/ufw.conf && command -v ufw >/dev/null 2>&1; then
    ufw allow 5353/udp comment mdns || echo "warn: ufw allow 5353/udp 失败, 请装完后手动放行"
  fi
fi

host="$(SERVICE_URL_HOST="" aib_service_url_host 2>/dev/null || echo localhost)"
echo "avahi ok: 局域网可用 ${host} 访问本机 (同名主机冲突时 Avahi 会改名为 xxx-2.local)"
