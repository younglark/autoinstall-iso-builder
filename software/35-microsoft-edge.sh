#!/bin/bash
# 35-microsoft-edge.sh — Microsoft Edge 稳定版, 并设为默认浏览器
# 官方源: https://packages.microsoft.com/repos/edge
# 仅 Desktop + amd64 默认安装; Server / 非 amd64 直接跳过。Firefox 保留。
# --skip 35 或 --skip 35-microsoft-edge 可跳过。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
export DEBIAN_FRONTEND=noninteractive

ARCH="$(dpkg --print-architecture)"
if [ "$ARCH" != "amd64" ]; then
  echo "skip: Microsoft Edge 官方源仅支持 amd64 (当前 $ARCH)"
  exit 0
fi
if [ "${EDITION:-}" != "desktop" ]; then
  echo "skip: Microsoft Edge 仅在 Desktop 预装 (EDITION=${EDITION:-unset})"
  exit 0
fi

EDGE_PKG="microsoft-edge-stable"
EDGE_REPO_URL="https://packages.microsoft.com/repos/edge"
EDGE_KEY_URL="https://packages.microsoft.com/keys/microsoft.asc"
EDGE_KEYRING="/etc/apt/keyrings/microsoft.asc"
EDGE_LIST="/etc/apt/sources.list.d/microsoft-edge.list"

if offline_enabled 2>/dev/null && offline_apt_ready 2>/dev/null; then
  echo "offline: 从本地 apt 安装 $EDGE_PKG (不添加 packages.microsoft.com)"
  offline_apt_install "$EDGE_PKG"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "$EDGE_KEY_URL" -o "$EDGE_KEYRING"
  chmod a+r "$EDGE_KEYRING"
  printf 'deb [arch=amd64 signed-by=%s] %s stable main\n' \
    "$EDGE_KEYRING" "$EDGE_REPO_URL" > "$EDGE_LIST"
  apt-get update
  apt-get install -y --no-install-recommends "$EDGE_PKG"
fi

# 包的 postinst 会把临时 .list 迁成官方 deb822
# (/etc/apt/sources.list.d/microsoft-edge.sources + /usr/share/keyrings/microsoft-edge.gpg),
# 并删掉 microsoft-edge.list。离线安装同样会跑 postinst。缺的话补写, 保证联网后能更新。
ensure_edge_online_source() {
  local sources=/etc/apt/sources.list.d/microsoft-edge.sources
  local gpg=/usr/share/keyrings/microsoft-edge.gpg
  if [ ! -s "$gpg" ]; then
    install -m 0755 -d /usr/share/keyrings
    if [ -s "$EDGE_KEYRING" ]; then
      gpg --dearmor < "$EDGE_KEYRING" > "$gpg"
      chmod 644 "$gpg"
    elif [ -s /etc/apt/keyrings/microsoft.asc ]; then
      gpg --dearmor < /etc/apt/keyrings/microsoft.asc > "$gpg"
      chmod 644 "$gpg"
    fi
  fi
  if [ ! -s "$sources" ]; then
    cat > "$sources" <<'SRC'
### THIS FILE IS AUTOMATICALLY CONFIGURED ###
# Changes to this file will not be preserved.
# This file will not be recreated if removed.
X-Repolib-Name: Microsoft Edge
Types: deb
URIs: https://packages.microsoft.com/repos/edge-stable
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/microsoft-edge.gpg
SRC
    chmod 644 "$sources"
    echo "wrote $sources"
  else
    echo "apt source already present: $sources"
  fi
}
ensure_edge_online_source

EDGE_BIN=""
for c in microsoft-edge-stable microsoft-edge; do
  if command -v "$c" >/dev/null 2>&1; then
    EDGE_BIN="$(command -v "$c")"
    break
  fi
done
[ -n "$EDGE_BIN" ] || { echo "ERROR: $EDGE_PKG 已安装但找不到可执行文件"; exit 1; }

EDGE_DESKTOP="microsoft-edge.desktop"
if [ ! -f "/usr/share/applications/$EDGE_DESKTOP" ]; then
  if [ -f /usr/share/applications/microsoft-edge-stable.desktop ]; then
    EDGE_DESKTOP="microsoft-edge-stable.desktop"
  else
    echo "ERROR: 找不到 Edge 的 .desktop 文件"
    ls -la /usr/share/applications/microsoft-edge* 2>/dev/null || true
    exit 1
  fi
fi

# --- 默认浏览器: alternatives ---
update-alternatives --install /usr/bin/x-www-browser x-www-browser "$EDGE_BIN" 200
update-alternatives --set x-www-browser "$EDGE_BIN"
update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser "$EDGE_BIN" 200
update-alternatives --set gnome-www-browser "$EDGE_BIN"

# --- 默认浏览器: mimeapps.list ---
upsert_mimeapps() {
  local file="$1"
  local desktop="$2"
  mkdir -p "$(dirname "$file")"
  local tmp
  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    cp -a "$file" "$tmp"
  else
    printf '[Default Applications]\n' > "$tmp"
  fi
  if ! grep -q '^\[Default Applications\]' "$tmp"; then
    printf '\n[Default Applications]\n' >> "$tmp"
  fi
  local key
  for key in text/html x-scheme-handler/http x-scheme-handler/https \
             x-scheme-handler/about x-scheme-handler/unknown; do
    if grep -q "^${key}=" "$tmp"; then
      sed -i "s|^${key}=.*|${key}=${desktop}|" "$tmp"
    else
      sed -i "/^\[Default Applications\]/a ${key}=${desktop}" "$tmp"
    fi
  done
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

upsert_mimeapps /etc/xdg/mimeapps.list "$EDGE_DESKTOP"
upsert_mimeapps /usr/share/applications/mimeapps.list "$EDGE_DESKTOP"
upsert_mimeapps /usr/share/applications/defaults.list "$EDGE_DESKTOP"
upsert_mimeapps /etc/skel/.config/mimeapps.list "$EDGE_DESKTOP"

# 为已创建的装机用户写一份 (chroot 里通常还没有图形会话)
if [ -n "${TARGET_USER:-}" ] && [ "$TARGET_USER" != "root" ]; then
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
  if [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ]; then
    upsert_mimeapps "$TARGET_HOME/.config/mimeapps.list" "$EDGE_DESKTOP"
    TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
    chown -R "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.config" || true
    if command -v xdg-settings >/dev/null 2>&1; then
      # chroot / 无会话时可能失败, 不作为硬错误
      runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" \
        XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-GNOME}" \
        xdg-settings set default-web-browser "$EDGE_DESKTOP" 2>/dev/null || true
    fi
  fi
fi

# --- 抑制首次运行提示 (不关闭自动更新) ---
install -m 0755 -d /etc/opt/edge/policies/managed
cat > /etc/opt/edge/policies/managed/10-autoinstall.json <<'JSON'
{
  "HideFirstRunExperience": true,
  "DefaultBrowserSettingEnabled": false
}
JSON

# --- GNOME 收藏夹: 用 Edge 替换 Firefox (有 gschema 才写; 可选) ---
configure_gnome_favorites() {
  local desktop="$1"
  local schema_dir=/usr/share/glib-2.0/schemas
  [ -d "$schema_dir" ] || { echo "无 glib schemas, 跳过 GNOME 收藏夹"; return 0; }
  if ! command -v python3 >/dev/null 2>&1; then
    echo "无 python3, 跳过 GNOME 收藏夹"
    return 0
  fi
  python3 - "$schema_dir" "$desktop" <<'PY'
import pathlib, re, sys

schema_dir = pathlib.Path(sys.argv[1])
desktop = sys.argv[2]
# GVariant 数组: ['a.desktop', "b.desktop"]
list_re = re.compile(r"favorite-apps\s*=\s*(\[[^\]]*\])", re.S)
item_re = re.compile(r"['\"]([^'\"]+)['\"]")
found = None
# 编号小的先出现, 后面的 override 覆盖前者; 取最后一次
for path in sorted(schema_dir.glob("*.gschema.override")):
    if path.name.startswith("90_autoinstall-microsoft-edge"):
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    matches = list_re.findall(text)
    if matches:
        found = matches[-1]

if found:
    items = item_re.findall(found)
else:
    items = [
        "org.gnome.Nautilus.desktop",
        "org.gnome.Software.desktop",
        "org.gnome.yelp.desktop",
    ]

out = []
seen_edge = False
for name in items:
    if "firefox" in name.lower():
        if not seen_edge:
            out.append(desktop)
            seen_edge = True
        continue
    if name == desktop:
        if not seen_edge:
            out.append(desktop)
            seen_edge = True
        continue
    out.append(name)
if not seen_edge:
    out.insert(0, desktop)

body = "[org.gnome.shell]\nfavorite-apps=[{}]\n".format(
    ", ".join("'" + n + "'" for n in out)
)
(schema_dir / "90_autoinstall-microsoft-edge.gschema.override").write_text(body, encoding="utf-8")
print("GNOME favorite-apps:", out)
PY
  if command -v glib-compile-schemas >/dev/null 2>&1; then
    glib-compile-schemas "$schema_dir" || true
  fi
}

configure_gnome_favorites "$EDGE_DESKTOP"

"$EDGE_BIN" --version
echo "microsoft-edge ok (default browser: $EDGE_DESKTOP)"
