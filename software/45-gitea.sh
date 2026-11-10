#!/bin/bash
# 45-gitea.sh — Gitea (自托管 Git 服务, 单二进制 + SQLite), 装机即配置好, 开机自启
# 官方: https://docs.gitea.com/installation/install-from-binary
# 下载: https://dl.gitea.com/gitea/<ver>/gitea-<ver>-linux-amd64 (+ .sha256)
#
# 装完零配置可用:
#   * /usr/local/bin/gitea (官方推荐固定名, 升级时 git hooks 路径不变)
#   * 系统用户 git (home /home/git; 系统 OpenSSH + Gitea 管理 authorized_keys → git@host:user/repo.git)
#   * /etc/gitea/app.ini: INSTALL_LOCK, SQLite, 每台机器独立生成的 SECRET_KEY / INTERNAL_TOKEN / JWT,
#     HTTP 0.0.0.0:3000 (局域网可访问, 不与 Jenkins 8080 冲突), LFS, OFFLINE_MODE, 开放注册
#   * 管理员账号在 chroot 内直接写 SQLite 创建 (不需要 Gitea 在运行)
#   * gitea.service enabled (官方单元 + After=network-online.target); 防火墙不动
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"

PIN="${PIN_GITEA:-latest}"
DL_BASE="${GITEA_DL_BASE:-https://dl.gitea.com/gitea}"
PLATFORM="linux-amd64"
INSTALL_BIN="/usr/local/bin/gitea"
GITEA_USER="git"
GITEA_HOME="/home/git"
WORK_DIR="/var/lib/gitea"
CONF_DIR="/etc/gitea"
CONF="$CONF_DIR/app.ini"
UNIT="/etc/systemd/system/gitea.service"
HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
# 管理员凭据: provision.env 给用户名/邮箱; 明文密码 (若构建时有) 在单独 0600 文件, 用后即删
SECRET_FILE="$HERE/gitea-admin.secret"
RANDOM_PW_FILE="/root/gitea-admin-password"

case "$PIN" in
  latest) ;;
  *) [[ "$PIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]] || { echo "ERROR: 非法 PIN_GITEA=$PIN"; exit 1; } ;;
esac

verify_and_install() {
  local src="$1" expect="$2" actual
  [ -f "$src" ] || { echo "ERROR: 缺少 $src"; return 1; }
  [ -n "$expect" ] || { echo "ERROR: 缺少期望 sha256, 拒绝安装未校验的二进制"; return 1; }
  actual="$(sha256sum "$src" | awk '{print $1}')"
  if [ "$actual" != "$expect" ]; then
    echo "ERROR: Gitea sha256 不匹配"
    echo "  expect: $expect"
    echo "  actual: $actual"
    return 1
  fi
  install -d -m 0755 /usr/local/bin
  install -m 0755 "$src" "$INSTALL_BIN"
}

install_offline() {
  local dir name sha
  dir="$(offline_root)/gitea"
  [ -d "$dir" ] || {
    echo "ERROR: 离线捆绑缺少 gitea/ — 请用 --force 重建: ./tools/fetch-offline-bundle.sh --force ..."
    return 1
  }
  name="$(cat "$dir/binary.name" 2>/dev/null || echo gitea)"
  [ -f "$dir/$name" ] || name="gitea"
  sha="$(tr -d '[:space:]' < "$dir/sha256" 2>/dev/null || true)"
  echo "offline: 安装 Gitea $(cat "$dir/version" 2>/dev/null || echo '?') 自 $dir/$name"
  if [ "$PIN" != "latest" ] && [ "$(cat "$dir/version" 2>/dev/null)" != "$PIN" ]; then
    echo "ERROR: 捆绑内 Gitea 版本 $(cat "$dir/version" 2>/dev/null) != PIN_GITEA=$PIN"
    return 1
  fi
  verify_and_install "$dir/$name" "$sha"
}

install_online() {
  local ver file tmp sha
  if [ "$PIN" = "latest" ]; then
    ver="$(curl -fsSL "$DL_BASE/version.json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["latest"]["version"])')" \
      || { echo "ERROR: 无法解析 Gitea 最新版本 ($DL_BASE/version.json)"; return 1; }
  else
    ver="$PIN"
  fi
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]] || { echo "ERROR: 版本号异常: $ver"; return 1; }
  file="gitea-${ver}-${PLATFORM}"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  echo "下载 Gitea $ver: $DL_BASE/$ver/$file"
  curl -fL --retry 3 --retry-delay 2 -o "$tmp/$file" "$DL_BASE/$ver/$file"
  sha="$(curl -fsSL "$DL_BASE/$ver/$file.sha256" | awk '{print $1}')"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "ERROR: 官方 sha256 获取失败"; return 1; }
  verify_and_install "$tmp/$file" "$sha"
}

if offline_enabled 2>/dev/null; then
  install_offline
else
  install_online
fi
command -v git >/dev/null || { echo "ERROR: Gitea 需要 git (应由 00-base 安装)"; exit 1; }
GITEA_VER="$("$INSTALL_BIN" --version | awk '{print $3}')"
echo "gitea --version: $("$INSTALL_BIN" --version)"

# ---------------------------------------------------------------- 用户与目录 (官方布局)
if ! id "$GITEA_USER" >/dev/null 2>&1; then
  adduser --system --shell /bin/bash --gecos 'Git Version Control' \
    --group --disabled-password --home "$GITEA_HOME" "$GITEA_USER"
fi
install -d -m 0750 -o "$GITEA_USER" -g "$GITEA_USER" "$GITEA_HOME"
install -d -m 0700 -o "$GITEA_USER" -g "$GITEA_USER" "$GITEA_HOME/.ssh"
for d in "$WORK_DIR" "$WORK_DIR/custom" "$WORK_DIR/data" "$WORK_DIR/log"; do
  install -d -m 0750 -o "$GITEA_USER" -g "$GITEA_USER" "$d"
done
install -d -m 0750 -o root -g "$GITEA_USER" "$CONF_DIR"

as_git() {
  runuser -u "$GITEA_USER" -- env HOME="$GITEA_HOME" USER="$GITEA_USER" GITEA_WORK_DIR="$WORK_DIR" "$@"
}

# ---------------------------------------------------------------- app.ini
# 已存在 (重跑脚本) 则保留, 避免轮换密钥让已有会话/令牌失效
if [ ! -s "$CONF" ]; then
  SECRET_KEY="$("$INSTALL_BIN" generate secret SECRET_KEY)"
  INTERNAL_TOKEN="$("$INSTALL_BIN" generate secret INTERNAL_TOKEN)"
  JWT_SECRET="$("$INSTALL_BIN" generate secret JWT_SECRET)"
  LFS_JWT_SECRET="$("$INSTALL_BIN" generate secret LFS_JWT_SECRET)"
  umask 027
  cat > "$CONF" <<INI
; 由 autoinstall software/45-gitea.sh 生成 (装机时每台机器独立生成密钥)
; 修改后: sudo systemctl restart gitea
APP_NAME = Gitea
RUN_USER = ${GITEA_USER}
RUN_MODE = prod
WORK_PATH = ${WORK_DIR}

[server]
PROTOCOL = http
; 监听所有网卡, 局域网可直接访问 http://<本机IP>:${HTTP_PORT}/
HTTP_ADDR = 0.0.0.0
HTTP_PORT = ${HTTP_PORT}
; 网页上显示的克隆地址; 用 IP/域名访问时请改成 http://<IP或域名>:${HTTP_PORT}/ 并同步 DOMAIN / SSH_DOMAIN
ROOT_URL = http://localhost:${HTTP_PORT}/
DOMAIN = localhost
SSH_DOMAIN = localhost
APP_DATA_PATH = ${WORK_DIR}/data
; 使用系统 OpenSSH (端口 22), Gitea 维护 ~git/.ssh/authorized_keys
DISABLE_SSH = false
START_SSH_SERVER = false
SSH_PORT = 22
LFS_START_SERVER = true
LFS_JWT_SECRET = ${LFS_JWT_SECRET}
; 不访问外部 CDN / Gravatar (离线友好)
OFFLINE_MODE = true

[database]
DB_TYPE = sqlite3
PATH = ${WORK_DIR}/data/gitea.db
SQLITE_JOURNAL_MODE = WAL

[repository]
ROOT = ${WORK_DIR}/data/gitea-repositories

[lfs]
PATH = ${WORK_DIR}/data/lfs

[security]
INSTALL_LOCK = true
SECRET_KEY = ${SECRET_KEY}
INTERNAL_TOKEN = ${INTERNAL_TOKEN}
PASSWORD_HASH_ALGO = pbkdf2

[oauth2]
JWT_SECRET = ${JWT_SECRET}

[service]
; 开放注册: 任何能访问本机的人都可自助注册。要关闭改成 true
DISABLE_REGISTRATION = false
REQUIRE_SIGNIN_VIEW = false
DEFAULT_KEEP_EMAIL_PRIVATE = true

[mailer]
ENABLED = false

[session]
PROVIDER = file

[log]
MODE = console
LEVEL = info
ROOT_PATH = ${WORK_DIR}/log
INI
  umask 022
fi
chown root:"$GITEA_USER" "$CONF"
chmod 0640 "$CONF"

# ---------------------------------------------------------------- 数据库 + 管理员
as_git "$INSTALL_BIN" --config "$CONF" --work-path "$WORK_DIR" migrate

ADMIN_USER="${GITEA_ADMIN_USER:-${TARGET_USER:-}}"
ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-}"
ADMIN_PW=""
if [ -f "$SECRET_FILE" ]; then
  # shellcheck disable=SC1090
  ADMIN_PW="$(. "$SECRET_FILE"; printf '%s' "${GITEA_ADMIN_PASSWORD:-}")"
fi
if [ -z "$ADMIN_USER" ] || [ "$ADMIN_USER" = "root" ]; then
  ADMIN_USER="gitea-admin"
fi
[ -n "$ADMIN_EMAIL" ] || ADMIN_EMAIL="${ADMIN_USER}@localhost"

if as_git "$INSTALL_BIN" --config "$CONF" --work-path "$WORK_DIR" admin user list --admin 2>/dev/null \
    | awk 'NR>1{print $2}' | grep -qxF "$ADMIN_USER"; then
  echo "Gitea 管理员 $ADMIN_USER 已存在, 跳过创建"
else
  PW_SOURCE="build"
  if [ "${#ADMIN_PW}" -lt 8 ]; then
    [ -n "$ADMIN_PW" ] && echo "warn: 构建时给的密码不足 8 位 (Gitea 最小长度), 改为随机密码"
    ADMIN_PW="$(openssl rand -base64 18 2>/dev/null | tr -d '/+=\n' | cut -c1-20)"
    [ "${#ADMIN_PW}" -ge 16 ] || ADMIN_PW="$(head -c 64 /dev/urandom | sha256sum | cut -c1-24)"
    PW_SOURCE="random"
  fi
  # 密码只经命令行参数传给 gitea (chroot 内短暂可见), 不写日志
  as_git "$INSTALL_BIN" --config "$CONF" --work-path "$WORK_DIR" admin user create \
    --username "$ADMIN_USER" --password "$ADMIN_PW" --email "$ADMIN_EMAIL" \
    --admin --must-change-password=false
  if [ "$PW_SOURCE" = "random" ]; then
    umask 077
    printf '%s\n' "$ADMIN_PW" > "$RANDOM_PW_FILE"
    umask 022
    chmod 0600 "$RANDOM_PW_FILE"
    echo "Gitea 管理员 $ADMIN_USER 已创建; 随机密码写入 $RANDOM_PW_FILE (root 0600)"
  else
    echo "Gitea 管理员 $ADMIN_USER 已创建 (密码 = 构建时 --password / --gitea-admin-password)"
  fi
fi
ADMIN_PW=""
rm -f "$SECRET_FILE"

# ---------------------------------------------------------------- systemd
cat > "$UNIT" <<UNIT_EOF
# 基于官方 contrib/service/systemd/gitea.service (v${GITEA_VER}); 由 software/45-gitea.sh 生成
[Unit]
Description=Gitea (Git with a cup of tea)
After=network-online.target
Wants=network-online.target

[Service]
RestartSec=2s
Type=simple
User=${GITEA_USER}
Group=${GITEA_USER}
WorkingDirectory=${WORK_DIR}/
ExecStart=${INSTALL_BIN} web --config ${CONF}
Restart=always
Environment=USER=${GITEA_USER} HOME=${GITEA_HOME} GITEA_WORK_DIR=${WORK_DIR}

[Install]
WantedBy=multi-user.target
UNIT_EOF
chmod 0644 "$UNIT"
systemctl enable gitea.service 2>/dev/null \
  || ln -sfn "$UNIT" /etc/systemd/system/multi-user.target.wants/gitea.service
[ -e /etc/systemd/system/multi-user.target.wants/gitea.service ] \
  || { echo "ERROR: gitea.service 未 enable"; exit 1; }

# ---------------------------------------------------------------- 校验
[ -x "$INSTALL_BIN" ] || { echo "ERROR: 缺少 $INSTALL_BIN"; exit 1; }
grep -q '^INSTALL_LOCK = true' "$CONF" || { echo "ERROR: app.ini 缺 INSTALL_LOCK"; exit 1; }
[ -s "$WORK_DIR/data/gitea.db" ] || { echo "ERROR: SQLite 数据库未初始化"; exit 1; }
echo "gitea ok: http://<本机IP>:${HTTP_PORT}/ (0.0.0.0:${HTTP_PORT}); 管理员 ${ADMIN_USER}; ssh git@<host>:<user>/<repo>.git"
