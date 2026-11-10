#!/bin/bash
# 99-cleanup.sh — 收尾: 恢复 resolv.conf、放开服务启动、清缓存、写清单
set -uo pipefail

# --- 恢复 systemd-resolved 的符号链接 (00-base.sh 临时改成了实体文件) ---
if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
  rm -f /etc/resolv.conf
  ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  echo "resolv.conf 已恢复为 systemd-resolved 链接"
fi

# --- 放行服务启动 (必须删, 否则装完没有任何服务会自启) ---
rm -f /usr/sbin/policy-rc.d

# --- 清理 ---
rm -f /opt/provision/gitea-admin.secret /opt/provision/jenkins-admin.secret /opt/provision/x11vnc.secret
rm -f /tmp/nodesource_setup.sh /tmp/node.tar.xz
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# --- 落一份可核对的清单 ---
# sshd --version 走 stderr; docker compose 是子命令; jenkins 是服务不是 CLI。
_manifest_ver() {
  case "$1" in
    sshd)
      # OpenSSH_x.y, 输出在 stderr
      sshd -V 2>&1 | head -1
      ;;
    "docker compose")
      if command -v docker >/dev/null; then
        docker compose version 2>/dev/null | head -1 || echo "(not found)"
      else
        echo "(not found)"
      fi
      ;;
    gitea)
      if [ -x /usr/local/bin/gitea ]; then
        /usr/local/bin/gitea --version 2>/dev/null | head -1
      else
        echo "(not found)"
      fi
      ;;
    jenkins)
      if command -v jenkins >/dev/null; then
        jenkins --version 2>/dev/null | head -1 || echo "(not found)"
      elif dpkg-query -W -f='${Version}' jenkins >/dev/null 2>&1; then
        echo "jenkins $(dpkg-query -W -f='${Version}' jenkins)"
      else
        echo "(not found)"
      fi
      ;;
    FlClash)
      _st="$(dpkg-query -W -f='${Status}' FlClash 2>/dev/null || true)"
      [ -n "$_st" ] || _st="$(dpkg-query -W -f='${Status}' flclash 2>/dev/null || true)"
      if echo "$_st" | grep -q 'install ok installed'; then
        _ver="$(dpkg-query -W -f='${Version}' FlClash 2>/dev/null || true)"
        [ -n "$_ver" ] || _ver="$(dpkg-query -W -f='${Version}' flclash 2>/dev/null || true)"
        echo "FlClash ${_ver}"
      else
        echo "(not found)"
      fi
      ;;
    *)
      # shellcheck disable=SC2086
      if command -v $1 >/dev/null 2>&1 || [ "$1" = "docker compose" ]; then
        $1 --version 2>/dev/null | head -1 || echo "(not found)"
      else
        echo "(not found)"
      fi
      ;;
  esac
}

mkdir -p /var/log/autoinstall
{
  echo "# provisioned at $(date -u +%FT%TZ)"
  echo "# host: $(cat /etc/hostname 2>/dev/null)"
  echo
  for c in git gh rg docker "docker compose" nvidia-ctk java node npm grok opencode openmausbot unity godot gitea jenkins microsoft-edge-stable FlClash sshd; do
    printf '%-18s ' "$c"
    _manifest_ver "$c" || echo "(not found)"
  done
} > /var/log/autoinstall/manifest.txt 2>&1

cat /var/log/autoinstall/manifest.txt
echo "cleanup ok"
