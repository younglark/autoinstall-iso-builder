#!/bin/bash
# 60-opencode.sh — OpenCode 2.x (@opencode/cli) + 开机启用 Web (0.0.0.0:4096)
#
# 官方: https://opencode.ai/docs/cli/web/  https://opencode.ai/docs/cli/commands/
# npm: @opencode/cli (postinstall 必须跑, 否则 bin 只是桩)。
# Web: `opencode serve --hostname 0.0.0.0 --port 4096` (前台, 适合 systemd; 不要用
#      `opencode service` / `pair --remote`, 以免后台服务、开浏览器或开远程隧道)。
# 密码: OPENCODE_PASSWORD (Basic auth 用户名恒为 opencode)。明文只来自
#      /provision/opencode-web.secret, 写入 /etc/opencode/web.env (root 0600) 后删除。
# 只给了 --password-hash 时生成随机密码 → /root/opencode-web-password (root 0600)。
# 系统配置 /etc/opencode/opencode.json 设 update=disable, 服务不自动升级。
# 防火墙不动。URL: http://<主机名>.local:4096/ (或 --service-url-host)。
#
# 测试钩子: AIB_TARGET_ROOT=<dir> 把文件写到该前缀; AIB_SKIP_PKG=1 跳过 npm/node。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
# shellcheck disable=SC1091
[ -f "$HERE/lib-service-url.sh" ] && . "$HERE/lib-service-url.sh"

R="${AIB_TARGET_ROOT:-}"
SKIP_PKG="${AIB_SKIP_PKG:-0}"
PKG="@opencode/cli"
VER="${PIN_OPENCODE:-latest}"
PORT="${OPENCODE_WEB_PORT:-4096}"
UNIT="$R/etc/systemd/system/opencode-web.service"
ENV_FILE="$R/etc/opencode/web.env"
CFG_FILE="$R/etc/opencode/opencode.json"
SECRET_FILE="$HERE/opencode-web.secret"
RANDOM_PW_FILE="$R/root/opencode-web-password"
NPM_PREFIX="${AIB_NPM_PREFIX:-/usr/local}"

URL_HOST="localhost"
if command -v aib_service_url_host >/dev/null 2>&1; then
  URL_HOST="$(aib_service_url_host)"
fi
WEB_URL="http://${URL_HOST}:${PORT}/"

svc_user="${TARGET_USER:-}"
if [ -z "$svc_user" ] || [ "$svc_user" = "root" ]; then
  echo "ERROR: OpenCode Web 必须以安装用户运行, 不能是 root (TARGET_USER=${TARGET_USER:-})"
  rm -f "$SECRET_FILE"
  exit 1
fi

svc_home=""
if [ -n "$R" ] && [ -f "$R/etc/passwd" ]; then
  svc_home="$(awk -F: -v u="$svc_user" '$1==u { print $6; exit }' "$R/etc/passwd")"
fi
if [ -z "$svc_home" ]; then
  svc_home="$(getent passwd "$svc_user" 2>/dev/null | cut -d: -f6 || true)"
fi
if [ -z "$svc_home" ]; then
  svc_home="/home/$svc_user"
fi

# ---------------------------------------------------------------- 安装
BIN=""
if [ "$SKIP_PKG" != "1" ]; then
  export HOME="${HOME:-/root}"
  command -v node >/dev/null || { echo "ERROR: 需要先执行 40-nodejs.sh"; rm -f "$SECRET_FILE"; exit 1; }

  if offline_enabled 2>/dev/null && [ -f "$(offline_root)/npm/prefix.tar.gz" ]; then
    echo "offline: 使用已解压/捆绑的 npm prefix (opencode pin=$VER pkg=$PKG)"
    command -v opencode >/dev/null || offline_extract_npm_prefix
    if command -v aib_opencode_cli_postinstall >/dev/null 2>&1; then
      aib_opencode_cli_postinstall /usr/local || echo "warn: opencode postinstall 在目标机重跑失败, 沿用捆绑内二进制"
    fi
  else
    # 禁止 --ignore-scripts: 否则 bin 只是桩, serve 不可用。
    npm install -g "${PKG}@${VER}" --no-audit --no-fund --allow-scripts="$PKG" \
      || npm install -g "${PKG}@${VER}" --no-audit --no-fund
    if command -v aib_prune_opencode_cli_platform >/dev/null 2>&1; then
      _arch="$(aib_opencode_node_arch "$(dpkg --print-architecture 2>/dev/null || uname -m)")"
      aib_prune_opencode_cli_platform /usr/local "$_arch"
    fi
  fi

  BIN="$(command -v opencode || true)"
  [ -n "$BIN" ] || { echo "ERROR: opencode 未进入 PATH"; rm -f "$SECRET_FILE"; exit 1; }
  if ! "$BIN" --version >/dev/null 2>&1; then
    echo "ERROR: opencode --version 失败 (postinstall 可能没跑, 二进制是桩)"
    rm -f "$SECRET_FILE"
    exit 1
  fi
  "$BIN" --version
else
  BIN="${OPENCODE_BIN:-/usr/local/bin/opencode}"
fi

# ---------------------------------------------------------------- 密码 → EnvironmentFile
WEB_PW=""
if [ -f "$SECRET_FILE" ]; then
  # shellcheck disable=SC1090
  WEB_PW="$(. "$SECRET_FILE"; printf '%s' "${OPENCODE_WEB_PASSWORD:-}")"
fi
PW_SOURCE="build"
if [ -z "$WEB_PW" ]; then
  WEB_PW="$(openssl rand -base64 18 2>/dev/null | tr -d '/+=\n' | cut -c1-20)"
  [ "${#WEB_PW}" -ge 16 ] || WEB_PW="$(head -c 64 /dev/urandom | sha256sum | cut -c1-24)"
  PW_SOURCE="random"
fi
case "$WEB_PW" in
  *$'\n'*|*$'\r'*)
    echo "ERROR: OpenCode Web 密码不能含换行"
    WEB_PW=""
    rm -f "$SECRET_FILE"
    exit 1
    ;;
esac

install -d -m 0755 "$(dirname "$ENV_FILE")"
install -d -m 0755 "$(dirname "$RANDOM_PW_FILE")"
# systemd EnvironmentFile: 需要时用双引号转义, 不把密码写进命令行参数
OPENCODE_PW_TMP="$WEB_PW" python3 - "$ENV_FILE" <<'PY'
import os, sys
dest = sys.argv[1]
pw = os.environ["OPENCODE_PW_TMP"]
if "\n" in pw or "\r" in pw:
    raise SystemExit("password contains newline")
safe = all(c.isalnum() or c in "._/+-:@%=," for c in pw)
val = pw if safe else '"' + pw.replace("\\", "\\\\").replace('"', '\\"') + '"'
with open(dest, "w", encoding="utf-8") as f:
    f.write("OPENCODE_PASSWORD=%s\n" % val)
PY
unset OPENCODE_PW_TMP
chmod 0600 "$ENV_FILE"
if [ "$(id -u)" -eq 0 ]; then
  chown root:root "$ENV_FILE" 2>/dev/null || true
fi

if [ "$PW_SOURCE" = "random" ]; then
  umask 077
  printf '%s\n' "$WEB_PW" > "$RANDOM_PW_FILE"
  umask 022
  chmod 0600 "$RANDOM_PW_FILE"
  echo "OpenCode Web: 无构建明文, 随机密码写入 $RANDOM_PW_FILE (root 0600)"
else
  echo "OpenCode Web: 密码 = 构建时 --password (写入 $ENV_FILE, 0600)"
fi
WEB_PW=""
rm -f "$SECRET_FILE"

# 系统级关闭自动更新 (官方: update=disable; 项目级会被忽略)
# https://opencode.ai/docs/config/
cat > "$CFG_FILE" <<'JSON'
{
  "update": "disable"
}
JSON
chmod 0644 "$CFG_FILE"

# ---------------------------------------------------------------- systemd
install -d -m 0755 "$(dirname "$UNIT")"
install -d -m 0755 "$R/etc/systemd/system/multi-user.target.wants"
cat > "$UNIT" <<UNIT_EOF
# 由 software/60-opencode.sh 生成。前台 serve, 不要改成 opencode service / pair --remote。
[Unit]
Description=OpenCode Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${svc_user}
Group=${svc_user}
WorkingDirectory=${svc_home}
Environment=HOME=${svc_home}
EnvironmentFile=${ENV_FILE#"$R"}
ExecStart=${BIN} serve --hostname 0.0.0.0 --port ${PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF
chmod 0644 "$UNIT"

if [ "$SKIP_PKG" != "1" ]; then
  systemctl enable opencode-web.service 2>/dev/null \
    || ln -sfn "$UNIT" "$R/etc/systemd/system/multi-user.target.wants/opencode-web.service"
  [ -e "$R/etc/systemd/system/multi-user.target.wants/opencode-web.service" ] \
    || { echo "ERROR: opencode-web.service 未 enable"; exit 1; }
else
  ln -sfn "$UNIT" "$R/etc/systemd/system/multi-user.target.wants/opencode-web.service"
fi

# ---------------------------------------------------------------- 校验
grep -q '^User='"$svc_user"'$' "$UNIT" || { echo "ERROR: 单元 User 不是 $svc_user"; exit 1; }
grep -q 'User=root' "$UNIT" && { echo "ERROR: 单元 User 不能是 root"; exit 1; }
grep -q 'serve --hostname 0.0.0.0 --port '"$PORT" "$UNIT" || { echo "ERROR: ExecStart 不是 serve 0.0.0.0:$PORT"; exit 1; }
grep -q '^Restart=on-failure$' "$UNIT" || { echo "ERROR: 缺 Restart=on-failure"; exit 1; }
if grep -E '^ExecStart=' "$UNIT" | grep -qE -- '--service|pair --remote'; then
  echo "ERROR: 单元不能启用 service/remote 隧道"
  exit 1
fi
[ -f "$ENV_FILE" ] || { echo "ERROR: 缺少 $ENV_FILE"; exit 1; }
_mode="$(stat -c %a "$ENV_FILE")"
[ "$_mode" = "600" ] || { echo "ERROR: $ENV_FILE 权限是 $_mode, 应为 600"; exit 1; }
grep -q '^OPENCODE_PASSWORD=' "$ENV_FILE" || { echo "ERROR: web.env 缺少 OPENCODE_PASSWORD"; exit 1; }
grep -q '"update": "disable"' "$CFG_FILE" || { echo "ERROR: 未关闭自动更新"; exit 1; }

echo "opencode ok (pin=${VER} pkg=${PKG}; web ${WEB_URL} 也可 http://<本机IP>:${PORT}/, 监听 0.0.0.0:${PORT}, 用户 ${svc_user}; 首次使用请以该用户执行 opencode auth login 或在网页登录模型提供商)"
