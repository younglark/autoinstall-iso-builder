#!/bin/bash
# Remove temporary offline apt pin, restore installer-written Ubuntu sources,
# then install third-party apt keyrings + lists shipped in the offline bundle
# (apt-sources/) so a later networked `apt update` can pull security updates.
#
# Approach: restore every seed present under apt-sources/ (captured at fetch
# time for Docker / GitHub CLI / NVIDIA toolkit / Jenkins / NodeSource).
# Online installs never call this script.
set -euo pipefail

OFFLINE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APT_ETC="${APT_ETC:-/etc/apt}"
SHARE_KEYRINGS="${SHARE_KEYRINGS:-/usr/share/keyrings}"

rm -f "$APT_ETC/sources.list.d/00-offline-bundle.list"
rm -f "$APT_ETC/apt.conf.d/99-offline-bundle"
if [ -f "$APT_ETC/sources.list.offline-bak" ]; then
  mv "$APT_ETC/sources.list.offline-bak" "$APT_ETC/sources.list"
fi
if [ -d "$APT_ETC/sources.list.d.offline-bak" ]; then
  shopt -s nullglob
  for f in "$APT_ETC/sources.list.d.offline-bak"/*; do
    mv "$f" "$APT_ETC/sources.list.d/"
  done
  shopt -u nullglob
  rmdir "$APT_ETC/sources.list.d.offline-bak" 2>/dev/null || true
fi

# --- third-party apt seeds from offline bundle ---
APT_SRC="${OFFLINE_ROOT}/apt-sources"
if [ ! -d "$APT_SRC" ]; then
  echo "warn: $APT_SRC 不存在 — 跳过第三方 apt 源写回 (旧捆绑? 请 --force 重建)"
  exit 0
fi

install -m 0755 -d "$APT_ETC/keyrings" "$APT_ETC/sources.list.d" "$SHARE_KEYRINGS"

restored=0
if [ -d "$APT_SRC/keyrings" ]; then
  shopt -s nullglob
  for f in "$APT_SRC/keyrings"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    # NodeSource setup 把 keyring 放在 /usr/share/keyrings, Signed-By 也指向那里
    if [ "$base" = "nodesource.gpg" ]; then
      install -m 0644 "$f" "$SHARE_KEYRINGS/$base"
    else
      install -m 0644 "$f" "$APT_ETC/keyrings/$base"
      chmod a+r "$APT_ETC/keyrings/$base"
    fi
    restored=$((restored + 1))
  done
  shopt -u nullglob
fi

if [ -d "$APT_SRC/sources.list.d" ]; then
  shopt -s nullglob
  for f in "$APT_SRC/sources.list.d"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      *.list|*.sources)
        install -m 0644 "$f" "$APT_ETC/sources.list.d/$base"
        restored=$((restored + 1))
        ;;
      *)
        echo "warn: 忽略非 apt 源文件: $base"
        ;;
    esac
  done
  shopt -u nullglob
fi

echo "restored third-party apt sources from $APT_SRC ($restored files)"

# 把 Ubuntu 源写成构建时的 --mirror (默认清华 https)。ca-certificates 已由 00-base
# 从离线捆绑装好, 因此现在切 https 是安全的。
HELPER=""
for _m in "$OFFLINE_ROOT/ubuntu-mirror.sh" /opt/provision/ubuntu-mirror.sh; do
  if [ -f "$_m" ]; then HELPER="$_m"; break; fi
done
# shellcheck disable=SC1090
[ -n "$HELPER" ] && . "$HELPER"
MIRROR_URL=""
if [ -f "$OFFLINE_ROOT/ubuntu-mirror.url" ]; then
  MIRROR_URL="$(tr -d '[:space:]' < "$OFFLINE_ROOT/ubuntu-mirror.url")"
fi
if [ -z "$MIRROR_URL" ] && [ -f /opt/provision/provision.env ]; then
  # shellcheck disable=SC1091
  . /opt/provision/provision.env
  MIRROR_URL="${UBUNTU_MIRROR:-}"
fi
if command -v aib_apply_final_ubuntu_mirror >/dev/null 2>&1 && [ -n "$MIRROR_URL" ]; then
  aib_apply_final_ubuntu_mirror "$MIRROR_URL"
  echo "final Ubuntu apt mirror: $MIRROR_URL"
elif command -v aib_ensure_https_apt >/dev/null 2>&1; then
  aib_ensure_https_apt
fi

# 装机时可能仍无网, 不在这里 apt-get update; 联网后自行 update 即可
if [ -d "$APT_ETC/sources.list.d" ]; then
  find "$APT_ETC/sources.list.d" -maxdepth 1 -type f -printf '  source: %f\n' 2>/dev/null || true
fi
