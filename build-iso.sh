#!/usr/bin/env bash
# =============================================================================
# build-iso.sh — 把 subiquity autoinstall 烧进 Ubuntu Live ISO
#   支持 Ubuntu Server 22.04 / 24.04 与 Ubuntu Desktop 24.04 (--edition)
#
# 原理: 不重建 ISO, 也不解包 squashfs。
#   * 在 ISO 根目录新增 /nocloud/{user-data,meta-data} 种子
#   * 给 grub 菜单注入 "autoinstall ds=nocloud\;s=/cdrom/nocloud/"
#   * 用 xorriso 复制模式 + `-boot_image any replay` 原样复用引导记录
#
# 因此: 不需要 root, 不需要 loop 挂载, BIOS/UEFI 双启动与 Secure Boot 全部保留。
#
# 依赖: xorriso (>=1.5), python3 (+PyYAML 可选), openssl (仅明文密码时需要)
# 环境: Linux / WSL2 原生; macOS / Windows 用容器 (scripts/aib.sh / scripts/aib.ps1)。
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SRC_ISO=""
OUT_ISO=""
HOSTNAME_="ubuntu-node"
USERNAME_="ubuntu"
# 未传 --password / --password-hash 时的默认密码 (构建时告警, 装完请改)
DEFAULT_PASSWORD="ubuntu1990"
USED_DEFAULT_PASSWORD=0
PASS_HASH=""
PASS_PLAIN=""
LOCALE_="en_US.UTF-8"
KEYBOARD_="us"
TIMEZONE_="Asia/Shanghai"
MIRROR="http://archive.ubuntu.com/ubuntu"
PACKAGES=""
SSH_ALLOW_PW="true"
SSH_AUTHORIZED_KEYS=""
STORAGE_LAYOUT="direct"
NETWORK_MODE="dhcp"
AUTO_DISK=0
FORCE_FETCH=0
FETCH_OFFLINE=0
OFFLINE=0
OFFLINE_BUNDLE=""
FULL_OFFLINE=0
DEBS_DIR=""
MENU_REGEX=""
EDITION="auto"
DESKTOP_SOURCE="minimal"
REALNAME_=""
DRY_RUN=0
KEEP_WORK=0
PROVISION=1
STRICT=0
PROVISION_SKIP=""
ISO_SHA256=""
ISO_SHA256SUMS=""
# 版本钉扎 (可用同名环境变量预置; CLI 优先)
PIN_NODE_MAJOR="${PIN_NODE_MAJOR:-24}"
PIN_GROK="${PIN_GROK:-latest}"
PIN_OPENCODE="${PIN_OPENCODE:-latest}"
PIN_OPENMAUSBOT="${PIN_OPENMAUSBOT:-latest}"
PIN_UNITY_CLI="${PIN_UNITY_CLI:-}"
PIN_GITEA="${PIN_GITEA:-latest}"
# Gitea 管理员 (默认 = --username / --password; 只有哈希时装机生成随机密码)
GITEA_ADMIN_USER=""
GITEA_ADMIN_PASSWORD=""
GITEA_ADMIN_EMAIL=""
# Jenkins 管理员 (同 Gitea 规则) 与预装插件
JENKINS_ADMIN_USER=""
JENKINS_ADMIN_PASSWORD=""
DEFAULT_JENKINS_PLUGINS="workflow-aggregator git gitea docker-workflow credentials-binding timestamper rebuild ansicolor docker-plugin parameterized-trigger"
JENKINS_PLUGINS="${JENKINS_PLUGINS:-$DEFAULT_JENKINS_PLUGINS}"

usage() {
  cat <<'USAGE'
用法:
  ./build-iso.sh --iso <原版ISO> --out <输出ISO> [选项]

必填:
  --iso PATH            官方 Ubuntu Server ISO (22.04 / 24.04) 或 Ubuntu Desktop 24.04 ISO
  --out PATH            输出 ISO 路径

身份 (二选一; 都不传则用默认用户 ubuntu / 密码 ubuntu1990, 构建时告警, 装完请改):
  --password-hash HASH  crypt 哈希, 推荐
  --password PLAIN      明文, 脚本用 openssl passwd -6 现场哈希 (会留在 shell 历史里)

可选:
  --edition E           auto (默认) | server | desktop。auto 读 ISO 内
                        casper/install-sources.yaml 的 variant (退回 .disk/info) 判断
  --desktop-source S    仅 desktop: minimal (默认, ubuntu-desktop-minimal) |
                        standard (ubuntu-desktop, 带 Office 等全套) | 任意 source id
  --realname NAME       identity.realname (登录界面显示名); desktop 默认等于 --username
  --hostname NAME       默认 ubuntu-node
  --username NAME       默认 ubuntu
  --packages "a,b,c"    预装软件包, 逗号分隔
  --mirror URL          默认 archive.ubuntu.com; 内网请填本地源
  --locale / --keyboard / --timezone
  --ssh-allow-pw BOOL   默认 true; false 时必须同时提供 --ssh-authorized-keys, 否则构建失败
  --ssh-authorized-keys FILE
                        authorized_keys 文件 (每行一把公钥); 写入 autoinstall ssh.authorized-keys,
                        并打进 /nocloud + late-command 再写一次到用户家目录 (防 Subiquity 漏写)
  --storage-layout L    direct | lvm | zfs, 默认 direct
  --network MODE        dhcp (默认) | none; dhcp 写入 en*/eth* 通配 DHCP netplan,
                        并用 late-command 确保装完后系统始终有 DHCP
  --auto-disk           全自动选盘并抹盘 (interactive-sections: [])。默认停在硬盘选择页
                        由用户确认。危险：按 match size:largest 自动抹最大盘。仅用于
                        QEMU/CI 无人值守；物理机切勿默认开启。
                        开启后 shutdown=poweroff (关机不重启), 防止 U 盘未拔循环抹盘。
  --offline             全离线安装 (需 --offline-bundle; 零外网请求仍装完全部 software/)
  --offline-bundle DIR  fetch-offline-bundle.sh 产出目录 (含 apt/ npm/ manifest.json)
  --fetch-offline       构建前自动调用 tools/fetch-offline-bundle.sh (需 docker)
  --force-fetch         配合 --fetch-offline: 忽略缓存指纹, 强制重建离线捆绑
  --debs DIR            把目录下所有 .deb 打进 ISO 的 /pool 并离线安装 (旧局部离线)
  --no-provision        不执行 software/ 下的软件预装脚本
  --strict              任一软件装失败就中止安装 (默认: 记日志继续)
  --skip "30 70"        跳过脚本: 编号前缀或完整名均可 (30 或 30-jenkins)
  --pin-node N          Node 主版本, 默认 24 (也可用环境变量 PIN_NODE_MAJOR)
  --pin-grok VER        npm 版 @xai-official/grok, 默认 latest (PIN_GROK)
  --pin-opencode VER    npm 版 opencode-ai, 默认 latest (PIN_OPENCODE)
  --pin-openmausbot VER npm 版 openmausbot, 默认 latest (PIN_OPENMAUSBOT)
  --pin-unity-cli VER  Unity CLI 版本, 默认拉 latest/latest-beta (PIN_UNITY_CLI)
  --pin-gitea VER       Gitea 版本 (如 28.3.0), 默认 latest (PIN_GITEA)
  --gitea-admin-user U  Gitea 管理员用户名, 默认 = --username
  --gitea-admin-password P
                        Gitea 管理员密码 (>=8 位), 默认 = --password 明文;
                        只给了 --password-hash 时装机生成随机密码写入 /root/gitea-admin-password
  --gitea-admin-email E Gitea 管理员邮箱, 默认 <用户名>@localhost
  --jenkins-admin-user U
                        Jenkins 管理员用户名, 默认 = --username
  --jenkins-admin-password P
                        Jenkins 管理员密码, 默认 = --password 明文;
                        只给了 --password-hash 时装机生成随机密码写入 /root/jenkins-admin-password
  --jenkins-plugins "a b c"
                        预装的 Jenkins 插件 (自动带全部依赖; 可写 name:version), 空格分隔
                        默认: workflow-aggregator git gitea docker-workflow credentials-binding timestamper rebuild ansicolor docker-plugin parameterized-trigger
  --iso-sha256 HEX      校验源 ISO 的 SHA256, 不匹配则失败
  --iso-sha256sums FILE 用 SHA256SUMS 文件按 basename 校验源 ISO
  --menu-regex REGEX    要注入的菜单项标题正则。默认 server: "Try or Install";
                        desktop: "^(Try or Install Ubuntu|Ubuntu \(safe graphics\))$"
  --dry-run             只渲染配置并打印, 不产出 ISO
  --keep-work           保留临时目录便于排查

示例:
  ./build-iso.sh --iso ubuntu-24.04.1-live-server-amd64.iso \
                 --out out/ubuntu-24.04.1-autoinstall.iso \
                 --hostname node01 --username ops \
                 --password-hash "$(openssl passwd -6 'Ch@ngeMe')" \
                 --packages "vim,curl,htop,net-tools" \
                 --mirror http://mirrors.aliyun.com/ubuntu \
                 --iso-sha256sums SHA256SUMS \
                 --ssh-authorized-keys ~/.ssh/id_ed25519.pub \
                 --pin-grok 0.1.0
USAGE
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# 与 software/run-all.sh 的 --skip 语义一致: 编号前缀或完整名
should_skip_script() {
  local name="$1" tok
  for tok in $PROVISION_SKIP; do
    [[ -z "$tok" ]] && continue
    case "$name" in
      "$tok"|"$tok"-*) return 0 ;;
    esac
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)            SRC_ISO="$2"; shift 2 ;;
    --out)            OUT_ISO="$2"; shift 2 ;;
    --hostname)       HOSTNAME_="$2"; shift 2 ;;
    --username)       USERNAME_="$2"; shift 2 ;;
    --password-hash)  PASS_HASH="$2"; shift 2 ;;
    --password)       PASS_PLAIN="$2"; shift 2 ;;
    --locale)         LOCALE_="$2"; shift 2 ;;
    --keyboard)       KEYBOARD_="$2"; shift 2 ;;
    --timezone)       TIMEZONE_="$2"; shift 2 ;;
    --mirror)         MIRROR="$2"; shift 2 ;;
    --packages)       PACKAGES="$2"; shift 2 ;;
    --ssh-allow-pw)   SSH_ALLOW_PW="$2"; shift 2 ;;
    --ssh-authorized-keys) SSH_AUTHORIZED_KEYS="$2"; shift 2 ;;
    --storage-layout) STORAGE_LAYOUT="$2"; shift 2 ;;
    --network)        NETWORK_MODE="$2"; shift 2 ;;
    --auto-disk)      AUTO_DISK=1; shift ;;
    --offline)        OFFLINE=1; shift ;;
    --offline-bundle) OFFLINE_BUNDLE="$2"; OFFLINE=1; shift 2 ;;
    --fetch-offline)  FETCH_OFFLINE=1; OFFLINE=1; shift ;;
    --force-fetch)    FORCE_FETCH=1; FETCH_OFFLINE=1; OFFLINE=1; shift ;;
    --debs)           DEBS_DIR="$2"; shift 2 ;;
    --menu-regex)     MENU_REGEX="$2"; shift 2 ;;
    --edition)        EDITION="$2"; shift 2 ;;
    --desktop-source) DESKTOP_SOURCE="$2"; shift 2 ;;
    --realname)       REALNAME_="$2"; shift 2 ;;
    --no-provision)   PROVISION=0; shift ;;
    --strict)         STRICT=1; shift ;;
    --skip)           PROVISION_SKIP="$2"; shift 2 ;;
    --pin-node)       PIN_NODE_MAJOR="$2"; shift 2 ;;
    --pin-grok)       PIN_GROK="$2"; shift 2 ;;
    --pin-opencode)   PIN_OPENCODE="$2"; shift 2 ;;
    --pin-openmausbot) PIN_OPENMAUSBOT="$2"; shift 2 ;;
    --pin-unity-cli)  PIN_UNITY_CLI="$2"; shift 2 ;;
    --pin-gitea)      PIN_GITEA="$2"; shift 2 ;;
    --gitea-admin-user) GITEA_ADMIN_USER="$2"; shift 2 ;;
    --gitea-admin-password) GITEA_ADMIN_PASSWORD="$2"; shift 2 ;;
    --gitea-admin-email) GITEA_ADMIN_EMAIL="$2"; shift 2 ;;
    --jenkins-admin-user) JENKINS_ADMIN_USER="$2"; shift 2 ;;
    --jenkins-admin-password) JENKINS_ADMIN_PASSWORD="$2"; shift 2 ;;
    --jenkins-plugins) JENKINS_PLUGINS="$2"; shift 2 ;;
    --iso-sha256)     ISO_SHA256="$2"; shift 2 ;;
    --iso-sha256sums) ISO_SHA256SUMS="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --keep-work)      KEEP_WORK=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) die "未知参数: $1 (用 --help 查看)" ;;
  esac
done

[[ -n "$SRC_ISO" ]] || { usage; die "缺少 --iso"; }
[[ -n "$OUT_ISO" ]] || { usage; die "缺少 --out"; }
[[ -f "$SRC_ISO" ]] || die "源 ISO 不存在: $SRC_ISO"

# 默认凭据: 两种密码参数都没传 → 默认密码 (Gitea 管理员随之默认相同)
if [[ -z "$PASS_HASH" && -z "$PASS_PLAIN" ]]; then
  PASS_PLAIN="$DEFAULT_PASSWORD"
  USED_DEFAULT_PASSWORD=1
fi

if [[ -n "$SSH_AUTHORIZED_KEYS" ]]; then
  [[ -f "$SSH_AUTHORIZED_KEYS" ]] || die "--ssh-authorized-keys 文件不存在: $SSH_AUTHORIZED_KEYS"
fi

# username / packages 白名单 (与 render-user-data 一致; 防止 provision.env 注入)
[[ "$USERNAME_" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]   || die "--username 非法 (POSIX: 以小写字母或 _ 开头, 仅 [a-z0-9_-], 最长 32): $USERNAME_"
if [[ -n "$PACKAGES" ]]; then
  if [[ "$PACKAGES" =~ [[:space:]] ]]; then
    die "--packages 不能含空格; 请用逗号分隔, 例如: vim,curl,htop"
  fi
  IFS=',' read -r -a _pkgs <<< "$PACKAGES"
  for _p in "${_pkgs[@]}"; do
    [[ -z "$_p" ]] && continue
    [[ "$_p" =~ ^[a-zA-Z0-9.+_-]+$ ]] || die "--packages 含非法包名: $_p"
  done
fi
# pin 白名单 (字母数字 . _ - 或 latest)
_pin_ok() { [[ "$1" =~ ^[a-zA-Z0-9._+-]+$ ]] || [[ "$1" == "latest" ]]; }
_pin_ok "$PIN_NODE_MAJOR" || die "非法 --pin-node: $PIN_NODE_MAJOR"
_pin_ok "$PIN_GROK" || die "非法 --pin-grok: $PIN_GROK"
_pin_ok "$PIN_OPENCODE" || die "非法 --pin-opencode: $PIN_OPENCODE"
_pin_ok "$PIN_OPENMAUSBOT" || die "非法 --pin-openmausbot: $PIN_OPENMAUSBOT"
[[ -z "$PIN_UNITY_CLI" || "$PIN_UNITY_CLI" =~ ^[a-zA-Z0-9._+-]+$ ]] || die "非法 --pin-unity-cli: $PIN_UNITY_CLI"
[[ "$PIN_GITEA" == "latest" || "$PIN_GITEA" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]] \
  || die "非法 --pin-gitea: $PIN_GITEA (latest 或 X.Y.Z, 如 28.3.0)"

# Gitea 管理员 (45-gitea.sh)。默认取系统用户名与明文密码
[[ -n "$GITEA_ADMIN_USER" ]] || GITEA_ADMIN_USER="$USERNAME_"
[[ "$GITEA_ADMIN_USER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,38}$ ]] \
  || die "--gitea-admin-user 非法 (字母数字开头, 仅 [A-Za-z0-9._-], 最长 39): $GITEA_ADMIN_USER"
case "$(printf '%s' "$GITEA_ADMIN_USER" | tr '[:upper:]' '[:lower:]')" in
  api|assets|explore|login|user|users|org|repo|attachments|avatars|install|issues|pulls|notifications|swagger|-|.|..)
    die "Gitea 管理员用户名 '$GITEA_ADMIN_USER' 是 Gitea 保留名; 请用 --gitea-admin-user 换一个" ;;
esac
if [[ -n "$GITEA_ADMIN_EMAIL" ]]; then
  [[ "$GITEA_ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || die "--gitea-admin-email 非法: $GITEA_ADMIN_EMAIL"
fi
if [[ -n "$GITEA_ADMIN_PASSWORD" ]]; then
  [[ "${#GITEA_ADMIN_PASSWORD}" -ge 8 ]] || die "--gitea-admin-password 至少 8 位 (Gitea 默认 MIN_PASSWORD_LENGTH)"
  [[ "$GITEA_ADMIN_PASSWORD" != *$'\n'* ]] || die "--gitea-admin-password 不能含换行"
elif [[ -n "$PASS_PLAIN" ]]; then
  GITEA_ADMIN_PASSWORD="$PASS_PLAIN"
fi
# Jenkins 管理员 (30-jenkins.sh)。默认取系统用户名与明文密码
[[ -n "$JENKINS_ADMIN_USER" ]] || JENKINS_ADMIN_USER="$USERNAME_"
[[ "$JENKINS_ADMIN_USER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
  || die "--jenkins-admin-user 非法 (字母数字开头, 仅 [A-Za-z0-9._-], 最长 64): $JENKINS_ADMIN_USER"
case "$(printf '%s' "$JENKINS_ADMIN_USER" | tr '[:upper:]' '[:lower:]')" in
  system|anonymous|unknown|jenkins)
    die "Jenkins 管理员用户名 '$JENKINS_ADMIN_USER' 是 Jenkins 保留/系统名; 请用 --jenkins-admin-user 换一个" ;;
esac
if [[ -n "$JENKINS_ADMIN_PASSWORD" ]]; then
  [[ "$JENKINS_ADMIN_PASSWORD" != *$'\n'* ]] || die "--jenkins-admin-password 不能含换行"
  [[ "${#JENKINS_ADMIN_PASSWORD}" -le 72 ]] || die "--jenkins-admin-password 最长 72 字节 (bcrypt 限制)"
elif [[ -n "$PASS_PLAIN" ]]; then
  JENKINS_ADMIN_PASSWORD="$PASS_PLAIN"
fi
# 插件白名单: name 或 name:version, 空格分隔 (防 provision.env / 命令注入)
JENKINS_PLUGINS="$(printf '%s' "$JENKINS_PLUGINS" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
[[ -n "$JENKINS_PLUGINS" ]] || die "--jenkins-plugins 不能为空"
for _jp in $JENKINS_PLUGINS; do
  [[ "$_jp" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(:[A-Za-z0-9._-]+)?$ ]] || die "--jenkins-plugins 含非法插件名: $_jp"
done
if ! should_skip_script 45-gitea && [[ "$USERNAME_" == "git" ]]; then
  die "--username git 与 Gitea 的系统用户 git 冲突; 换个用户名, 或 --skip 45 不装 Gitea"
fi

# SSH: allow-pw=false 且无公钥 → 装完登不进, 构建期直接拒绝
_ssh_allow="$(printf '%s' "$SSH_ALLOW_PW" | tr '[:upper:]' '[:lower:]')"
case "$_ssh_allow" in true|false) ;; *) die "--ssh-allow-pw 必须是 true 或 false" ;; esac
_has_keys=0
if [[ -n "$SSH_AUTHORIZED_KEYS" ]] && grep -vE '^[[:space:]]*(#|$)' "$SSH_AUTHORIZED_KEYS" | grep -q .; then
  _has_keys=1
fi
if [[ "$_ssh_allow" == "false" && "$_has_keys" -eq 0 ]]; then
  die "--ssh-allow-pw false 但未提供任何 SSH 公钥; 装完将无法登录。请加 --ssh-authorized-keys, 或改回 --ssh-allow-pw true"
fi

if [[ "$USED_DEFAULT_PASSWORD" -eq 1 ]]; then
  warn "未传 --password / --password-hash: 使用默认密码 (用户 $USERNAME_; Gitea/Jenkins 管理员同此)。这是公开的默认值, 装完请立即修改: passwd + Gitea/Jenkins 网页改密"
fi
if [[ -z "$PASS_HASH" ]]; then
  command -v openssl >/dev/null || die "缺少 openssl, 无法哈希密码"
  PASS_HASH="$(openssl passwd -6 "$PASS_PLAIN")"
fi
[[ "$PASS_HASH" == \$* ]] || die "--password-hash 不像 crypt 哈希 (应以 \$ 开头)"

# ---------------------------------------------------------------- 源 ISO 完整性
verify_iso_sha256() {
  local expected="$1" actual
  actual="$(sha256sum -- "$SRC_ISO" | awk '{print $1}')"
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
  if [[ "$actual" != "$expected" ]]; then
    die "源 ISO SHA256 不匹配
  expected: $expected
  actual:   $actual"
  fi
  ok "源 ISO SHA256 校验通过"
}

if [[ -n "$ISO_SHA256SUMS" ]]; then
  [[ -f "$ISO_SHA256SUMS" ]] || die "--iso-sha256sums 文件不存在: $ISO_SHA256SUMS"
  base="$(basename -- "$SRC_ISO")"
  # SHA256SUMS 常见格式: <hash>  <filename> 或 <hash> *<filename>
  line="$(grep -E "[[:space:]](\*?)${base}\$" "$ISO_SHA256SUMS" | head -1 || true)"
  [[ -n "$line" ]] || die "SHA256SUMS 中找不到 ${base}: $ISO_SHA256SUMS"
  sum="$(awk '{print $1}' <<<"$line")"
  log "按 SHA256SUMS 校验 $base"
  verify_iso_sha256 "$sum"
elif [[ -n "$ISO_SHA256" ]]; then
  log "按 --iso-sha256 校验源 ISO"
  verify_iso_sha256 "$ISO_SHA256"
fi

for bin in xorriso python3; do
  command -v "$bin" >/dev/null || die "缺少依赖: $bin   (apt install xorriso python3)"
done

# ---------------------------------------------------------------- 版本识别
case "$EDITION" in
  auto|server|desktop) ;;
  *) die "--edition 必须是 auto | server | desktop (got: $EDITION)" ;;
esac

DETECT_DIR="$(mktemp -d -t iso-detect-XXXXXX)"
xorriso -osirrox on -indev "$SRC_ISO" \
  -extract /casper/install-sources.yaml "$DETECT_DIR/install-sources.yaml" 2>/dev/null || true
xorriso -osirrox on -indev "$SRC_ISO" \
  -extract /.disk/info "$DETECT_DIR/disk-info" 2>/dev/null || true
DETECT_OUT="$(python3 "$SCRIPT_DIR/tools/detect-edition.py" \
  --install-sources "$DETECT_DIR/install-sources.yaml" --disk-info "$DETECT_DIR/disk-info")"
rm -rf -- "$DETECT_DIR"
ISO_EDITION="$(sed -n 's/^EDITION=//p' <<<"$DETECT_OUT")"
ISO_RELEASE="$(sed -n 's/^RELEASE=//p' <<<"$DETECT_OUT")"
ISO_SOURCES="$(sed -n 's/^SOURCES=//p' <<<"$DETECT_OUT")"
ISO_SUBIQUITY="$(sed -n 's/^SUBIQUITY=//p' <<<"$DETECT_OUT")"

if [[ "$EDITION" == "auto" ]]; then
  case "$ISO_EDITION" in
    server|desktop) EDITION="$ISO_EDITION" ;;
    *) EDITION="server"; warn "无法从 ISO 识别版本, 按 server 处理 (可用 --edition 指定)" ;;
  esac
  log "识别到 ISO: edition=$EDITION release=${ISO_RELEASE:-?} sources=${ISO_SOURCES:-?}"
elif [[ "$ISO_EDITION" != "unknown" && "$ISO_EDITION" != "$EDITION" ]]; then
  warn "--edition $EDITION 与 ISO 识别结果 ($ISO_EDITION) 不一致, 以 --edition 为准"
fi

if [[ "$EDITION" == "desktop" ]]; then
  # 22.04 Desktop 用的是 Ubiquity (preseed), 不消费 Subiquity autoinstall
  if [[ "$ISO_SUBIQUITY" != "1" ]]; then
    die "这张 Desktop ISO 没有 casper/install-sources.yaml, 不是 Subiquity 系安装器。
  只支持 Ubuntu Desktop 24.04+ (22.04 Desktop 用 Ubiquity, 不支持 autoinstall)"
  fi
  case "$DESKTOP_SOURCE" in
    minimal)  DESKTOP_SOURCE_ID="ubuntu-desktop-minimal" ;;
    standard|full) DESKTOP_SOURCE_ID="ubuntu-desktop" ;;
    *)        DESKTOP_SOURCE_ID="$DESKTOP_SOURCE" ;;
  esac
  if [[ -n "$ISO_SOURCES" && ",$ISO_SOURCES," != *",$DESKTOP_SOURCE_ID,"* ]]; then
    die "--desktop-source $DESKTOP_SOURCE_ID 不在 ISO 的 install-sources.yaml 里 (可选: $ISO_SOURCES)"
  fi
  [[ -n "$MENU_REGEX" ]] || MENU_REGEX='^(Try or Install Ubuntu|Ubuntu \(safe graphics\))$'
  [[ -n "$REALNAME_" ]] || REALNAME_="$USERNAME_"
  log "Desktop 模式: source=$DESKTOP_SOURCE_ID realname=$REALNAME_ (网络交给 NetworkManager)"
else
  [[ -n "$MENU_REGEX" ]] || MENU_REGEX="Try or Install"
fi

# ---------------------------------------------------------------- 全离线捆绑
# ISO_RELEASE 已由 detect-edition 填好 (24.04/22.04); 映射到 jammy/noble
release_to_codename() {
  case "$1" in
    22.04|jammy) echo jammy ;;
    24.04|noble|*) echo noble ;;
  esac
}

if [[ "${FETCH_OFFLINE:-0}" -eq 1 ]]; then
  if [[ -n "$ISO_RELEASE" ]]; then
    REL_HINT="$(release_to_codename "$ISO_RELEASE")"
  else
    REL_HINT="noble"
    base="$(basename -- "$SRC_ISO")"
    case "$base" in
      *22.04*|*jammy*) REL_HINT=jammy ;;
      *24.04*|*noble*) REL_HINT=noble ;;
    esac
    warn "未识别 ISO_RELEASE, 按文件名猜测: $REL_HINT"
  fi
  OB_OUT="${OFFLINE_BUNDLE:-${OFFLINE_CACHE_ROOT:-$SCRIPT_DIR/cache/offline-bundles}/${REL_HINT}-amd64}"
  log "自动抓取离线捆绑 -> $OB_OUT (release=$REL_HINT force=${FORCE_FETCH:-0})"
  FETCH_ARGS=(--release "$REL_HINT" --out "$OB_OUT" --packages "$PACKAGES"
    --pin-node "$PIN_NODE_MAJOR" --pin-grok "$PIN_GROK"
    --pin-opencode "$PIN_OPENCODE" --pin-openmausbot "$PIN_OPENMAUSBOT")
  [[ -n "$PIN_UNITY_CLI" ]] && FETCH_ARGS+=(--pin-unity-cli "$PIN_UNITY_CLI")
  FETCH_ARGS+=(--pin-gitea "$PIN_GITEA" --jenkins-plugins "$JENKINS_PLUGINS")
  [[ "${FORCE_FETCH:-0}" -eq 1 ]] && FETCH_ARGS+=(--force)
  bash "$SCRIPT_DIR/tools/fetch-offline-bundle.sh" "${FETCH_ARGS[@]}"
  OFFLINE_BUNDLE="$OB_OUT"
fi

if [[ -n "$OFFLINE_BUNDLE" ]]; then
  [[ -d "$OFFLINE_BUNDLE" ]] || die "--offline-bundle 目录不存在: $OFFLINE_BUNDLE"
  [[ -f "$OFFLINE_BUNDLE/manifest.json" ]] || die "不像离线捆绑 (缺 manifest.json): $OFFLINE_BUNDLE"
  [[ -d "$OFFLINE_BUNDLE/apt" ]] || die "不像离线捆绑 (缺 apt/): $OFFLINE_BUNDLE"
  OFFLINE=1
  FULL_OFFLINE=1
  log "全离线捆绑: $OFFLINE_BUNDLE ($(du -sh "$OFFLINE_BUNDLE" | cut -f1))"
  if [[ "$PROVISION" -eq 1 ]]; then
    REL_FOR_V=""
    if [[ -n "$ISO_RELEASE" ]]; then
      REL_FOR_V="$(release_to_codename "$ISO_RELEASE")"
    fi
    VAL_ARGS=(--bundle "$OFFLINE_BUNDLE" --skip "$PROVISION_SKIP"
      --pin-node "$PIN_NODE_MAJOR" --pin-grok "$PIN_GROK"
      --pin-opencode "$PIN_OPENCODE" --pin-openmausbot "$PIN_OPENMAUSBOT")
    [[ -n "$REL_FOR_V" ]] && VAL_ARGS+=(--release "$REL_FOR_V")
    [[ -n "$PIN_UNITY_CLI" ]] && VAL_ARGS+=(--pin-unity-cli "$PIN_UNITY_CLI")
    VAL_ARGS+=(--pin-gitea "$PIN_GITEA" --jenkins-plugins "$JENKINS_PLUGINS")
    bash "$SCRIPT_DIR/tools/validate-offline-bundle.sh" "${VAL_ARGS[@]}"       || die "离线捆绑校验失败 (见上)。重建: ./tools/fetch-offline-bundle.sh --force ..."
  fi
elif [[ "$OFFLINE" -eq 1 && "$PROVISION" -eq 1 ]]; then
  die "--offline 且启用 provision 时必须提供 --offline-bundle DIR (或 --fetch-offline)。
  先运行: ./tools/fetch-offline-bundle.sh --release noble --out cache/offline-bundles/noble-amd64"
fi

if [[ "$EDITION" == "desktop" && "$FULL_OFFLINE" -eq 1 ]]; then
  if [[ "$PROVISION" -ne 1 ]]; then
    die "Desktop 全离线需要 provision (software/10-openssh.sh 从捆绑装 openssh-server; Desktop ISO 不带 ssh)。
  去掉 --no-provision, 或不用 --offline-bundle"
  fi
  if should_skip_script 10-openssh; then
    warn "Desktop 全离线且跳过了 10-openssh: 装完不会有 SSH 服务"
  fi
  log "Desktop 全离线: 安装器阶段不装 ssh (install-server: false), 由 10-openssh 从捆绑安装"
fi
WITH_POOL=0
if [[ -n "$DEBS_DIR" ]]; then
  [[ -d "$DEBS_DIR" ]] || die "--debs 目录不存在: $DEBS_DIR"
  shopt -s nullglob
  DEB_COUNT=$(find "$DEBS_DIR" -maxdepth 1 -name '*.deb' | wc -l)
  shopt -u nullglob
  [[ "$DEB_COUNT" -gt 0 ]] || die "--debs 目录下没有 .deb: $DEBS_DIR"
  WITH_POOL=1
  OFFLINE=1
  log "检测到 $DEB_COUNT 个本地包, 自动启用离线模式"
fi

WORK="$(mktemp -d -t ubuntu-iso-XXXXXX)"
cleanup() {
  if [[ "$KEEP_WORK" -eq 1 ]]; then
    warn "临时目录保留在: $WORK"
  else
    rm -rf -- "$WORK"
  fi
}
trap cleanup EXIT

log "源 ISO: $SRC_ISO ($(du -h "$SRC_ISO" | cut -f1))"
log "工作目录: $WORK"

# ---------------------------------------------------------------- 1. 渲染配置
mkdir -p "$WORK/nocloud"

case "$NETWORK_MODE" in
  dhcp|none) ;;
  *) die "--network 必须是 dhcp 或 none (got: $NETWORK_MODE)" ;;
esac

RENDER_ARGS=(
  --template "$SCRIPT_DIR/autoinstall/user-data.tmpl"
  --out "$WORK/nocloud/user-data"
  --hostname "$HOSTNAME_"
  --username "$USERNAME_"
  --password-hash "$PASS_HASH"
  --locale "$LOCALE_"
  --keyboard "$KEYBOARD_"
  --timezone "$TIMEZONE_"
  --mirror "$MIRROR"
  --packages "$PACKAGES"
  --ssh-allow-pw "$SSH_ALLOW_PW"
  --storage-layout "$STORAGE_LAYOUT"
)
[[ -n "$SSH_AUTHORIZED_KEYS" ]] && RENDER_ARGS+=(--ssh-authorized-keys "$SSH_AUTHORIZED_KEYS")
[[ "$OFFLINE" -eq 1 ]] && RENDER_ARGS+=(--offline)
[[ "$FULL_OFFLINE" -eq 1 ]] && RENDER_ARGS+=(--full-offline)
[[ "$WITH_POOL" -eq 1 ]] && RENDER_ARGS+=(--with-pool)
[[ "$PROVISION" -eq 1 ]] && RENDER_ARGS+=(--provision)
RENDER_ARGS+=(--network "$NETWORK_MODE")
RENDER_ARGS+=(--edition "$EDITION")
if [[ "$EDITION" == "desktop" ]]; then
  RENDER_ARGS+=(--desktop-source "$DESKTOP_SOURCE_ID" --realname "$REALNAME_")
elif [[ -n "$REALNAME_" ]]; then
  RENDER_ARGS+=(--realname "$REALNAME_")
fi
[[ "$AUTO_DISK" -eq 1 ]] && RENDER_ARGS+=(--auto-disk)

if [[ "$AUTO_DISK" -eq 1 ]]; then
  warn "--auto-disk 已开启：装机将自动抹除 match size:largest 的磁盘，无确认步骤；装完 shutdown=poweroff"
else
  log "默认停在硬盘选择页（interactive storage）；无人值守请加 --auto-disk"
fi

python3 "$SCRIPT_DIR/tools/render-user-data.py" "${RENDER_ARGS[@]}"
cp "$SCRIPT_DIR/autoinstall/meta-data" "$WORK/nocloud/meta-data"

# Desktop: 再放一份 /autoinstall.yaml 到 ISO 根 (Subiquity 优先级: 内核参数 > live 根 >
# cloud-config > 介质根)。正常走 NoCloud; 若 live 会话的 cloud-init 没拿到种子则兜底。
# 文件就是同一份配置 (仅含顶层 autoinstall: 键, 24.04+ 允许)。
if [[ "$EDITION" == "desktop" ]]; then
  cp "$WORK/nocloud/user-data" "$WORK/autoinstall.yaml"
fi

# SSH 公钥: 除写入 user-data ssh.authorized-keys 外, 再放进 /nocloud 供 late-command 脚本落盘
# (Subiquity 偶发不写 ~/.ssh/authorized_keys)
if [[ -n "$SSH_AUTHORIZED_KEYS" ]] && grep -vE '^[[:space:]]*(#|$)' "$SSH_AUTHORIZED_KEYS" | grep -q .; then
  cp "$SSH_AUTHORIZED_KEYS" "$WORK/nocloud/authorized_keys"
  cp "$SCRIPT_DIR/autoinstall/write-authorized-keys.sh" "$WORK/nocloud/write-authorized-keys.sh"
  chmod 0755 "$WORK/nocloud/write-authorized-keys.sh"
  ok "已打包 SSH 公钥晚写脚本 (/nocloud/write-authorized-keys.sh)"
fi

# 本地 deb 打进 ISO 的 /pool
if [[ "$WITH_POOL" -eq 1 ]]; then
  mkdir -p "$WORK/pool"
  cp -a "$DEBS_DIR"/*.deb "$WORK/pool/"
  ok "已收集 $DEB_COUNT 个 deb 到 /pool ($(du -sh "$WORK/pool" | cut -f1))"
fi

# 软件预装脚本打进 ISO 的 /provision
if [[ "$PROVISION" -eq 1 ]]; then
  [[ -d "$SCRIPT_DIR/software" ]] || die "缺少 software/ 目录"
  [[ -f "$SCRIPT_DIR/software/run-all.sh" ]] || die "缺少 software/run-all.sh"
  mkdir -p "$WORK/provision"
  # 只带 .sh 和 env, 不带任何本地残留
  cp "$SCRIPT_DIR/software"/*.sh "$WORK/provision/"
  chmod 0755 "$WORK/provision"/*.sh
  # Jenkins 插件解析器 (30-jenkins.sh 在线路径用; 与 fetch-offline-bundle 同一份)
  cp "$SCRIPT_DIR/tools/resolve-jenkins-plugins.py" "$WORK/provision/"
  # 逐行 %q 写入, 保证 source 安全 (旧写法 EXTRA_APT_PACKAGES=vim, htop 会把 htop 当命令执行)
  {
    echo "# 由 build-iso.sh 生成 (printf %q; 请勿手改未加引号的值)"
    printf 'TARGET_USER=%q
' "$USERNAME_"
    printf 'STRICT=%q
' "$STRICT"
    printf 'PROVISION_SKIP=%q
' "$PROVISION_SKIP"
    printf 'SSH_ALLOW_PW=%q
' "$SSH_ALLOW_PW"
    printf 'PIN_NODE_MAJOR=%q
' "$PIN_NODE_MAJOR"
    printf 'PIN_GROK=%q
' "$PIN_GROK"
    printf 'PIN_OPENCODE=%q
' "$PIN_OPENCODE"
    printf 'PIN_OPENMAUSBOT=%q
' "$PIN_OPENMAUSBOT"
    printf 'PIN_UNITY_CLI=%q
' "$PIN_UNITY_CLI"
    printf 'PIN_GODOT=%q
' "${PIN_GODOT:-4.7.2}"
    printf 'PIN_GITEA=%q
' "$PIN_GITEA"
    printf 'GITEA_ADMIN_USER=%q
' "$GITEA_ADMIN_USER"
    printf 'GITEA_ADMIN_EMAIL=%q
' "$GITEA_ADMIN_EMAIL"
    printf 'JENKINS_ADMIN_USER=%q\n' "$JENKINS_ADMIN_USER"
    printf 'JENKINS_PLUGINS=%q\n' "$JENKINS_PLUGINS"
    printf 'OFFLINE=%q
' "$FULL_OFFLINE"
    printf 'OFFLINE_ROOT=%q
' "/opt/offline"
    printf 'EXTRA_APT_PACKAGES=%q
' "$PACKAGES"
  } > "$WORK/provision/provision.env"
  # Gitea 管理员明文密码单独放 0600 文件 (不进 provision.env / 日志); 45-gitea.sh 用后删除
  if [[ -n "$GITEA_ADMIN_PASSWORD" ]] && ! should_skip_script 45-gitea; then
    ( umask 077; printf 'GITEA_ADMIN_PASSWORD=%q\n' "$GITEA_ADMIN_PASSWORD" > "$WORK/provision/gitea-admin.secret" )
    chmod 0600 "$WORK/provision/gitea-admin.secret"
    ok "Gitea 管理员 $GITEA_ADMIN_USER: 密码随 ISO 投递 (装机后删除目标机副本)"
  elif ! should_skip_script 45-gitea; then
    warn "Gitea 管理员 $GITEA_ADMIN_USER: 无明文密码 (只给了 --password-hash), 装机生成随机密码 → /root/gitea-admin-password"
  fi
  # Jenkins 管理员明文密码同理: 0600 文件, 30-jenkins.sh 只写 bcrypt 哈希进 init.groovy.d 并删除此文件
  if [[ -n "$JENKINS_ADMIN_PASSWORD" ]] && ! should_skip_script 30-jenkins; then
    ( umask 077; printf 'JENKINS_ADMIN_PASSWORD=%q\n' "$JENKINS_ADMIN_PASSWORD" > "$WORK/provision/jenkins-admin.secret" )
    chmod 0600 "$WORK/provision/jenkins-admin.secret"
    ok "Jenkins 管理员 $JENKINS_ADMIN_USER: 密码随 ISO 投递 (装机时转 bcrypt, 删除明文)"
  elif ! should_skip_script 30-jenkins; then
    warn "Jenkins 管理员 $JENKINS_ADMIN_USER: 无明文密码 (只给了 --password-hash), 装机生成随机密码 → /root/jenkins-admin-password"
  fi
  SCRIPT_COUNT=$(find "$WORK/provision" -maxdepth 1 -name '[0-9][0-9]-*.sh' | wc -l)
  ok "已打包 $SCRIPT_COUNT 个软件预装脚本 (node>=$PIN_NODE_MAJOR grok=$PIN_GROK)"
  [[ -n "$PROVISION_SKIP" ]] && warn "跳过: $PROVISION_SKIP"
fi

# ------------------------------------------------------- 2. 取出并修补 grub
log "提取 grub 菜单"
xorriso -osirrox on -indev "$SRC_ISO" \
        -extract /boot/grub/grub.cfg "$WORK/grub.cfg" 2>/dev/null \
  || die "源 ISO 里没有 /boot/grub/grub.cfg, 这不像 Ubuntu Live ISO"
# ISO Rock Ridge extracts are often mode 0444; patch-grub needs write access.
chmod u+w "$WORK/grub.cfg" 2>/dev/null || true

HAS_LOOPBACK=0
if xorriso -osirrox on -indev "$SRC_ISO" \
          -extract /boot/grub/loopback.cfg "$WORK/loopback.cfg" 2>/dev/null; then
  HAS_LOOPBACK=1
  chmod u+w "$WORK/loopback.cfg" 2>/dev/null || true
fi

# GRUB 必须转义分号, 否则 ds= 后半段被当成下一条 grub 命令
GRUB_AUTOINSTALL_PARAMS='autoinstall ds=nocloud\;s=/cdrom/nocloud/'

patch_menu() {
  local f="$1"
  python3 "$SCRIPT_DIR/tools/patch-grub.py" \
    --file "$f" \
    --menu-regex "$MENU_REGEX" \
    --params "$GRUB_AUTOINSTALL_PARAMS" \
    --timeout 3
}

log "注入 autoinstall 内核参数"
patch_menu "$WORK/grub.cfg" || die "grub.cfg 注入失败, 用 --menu-regex 指定正确的菜单标题"
if [[ "$HAS_LOOPBACK" -eq 1 ]]; then
  patch_menu "$WORK/loopback.cfg" || true
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run: 以下是渲染后的 user-data"
  echo "-------------------------------------------------------------"
  cat "$WORK/nocloud/user-data"
  echo "-------------------------------------------------------------"
  log "edition=$EDITION menu-regex=$MENU_REGEX"
  log "以下是注入后的 grub linux 行"
  grep -n 'autoinstall' "$WORK/grub.cfg" || true
  if [[ "$PROVISION" -eq 1 ]]; then
    log "以下是将要执行的软件预装顺序"
    for f in "$WORK/provision"/[0-9][0-9]-*.sh; do
      printf '    %s\n' "$(basename "$f")"
    done
  fi
  exit 0
fi

# ------------------------------------------------------------- 3. 重新打包
mkdir -p "$(dirname -- "$OUT_ISO")"
rm -f -- "$OUT_ISO"

MAP_ARGS=(
  -map "$WORK/nocloud"          /nocloud
  -map "$WORK/grub.cfg"         /boot/grub/grub.cfg
)
[[ "$HAS_LOOPBACK" -eq 1 ]] && MAP_ARGS+=(-map "$WORK/loopback.cfg" /boot/grub/loopback.cfg)
[[ "$EDITION" == "desktop" ]] && MAP_ARGS+=(-map "$WORK/autoinstall.yaml" /autoinstall.yaml)
[[ "$WITH_POOL" -eq 1 ]]    && MAP_ARGS+=(-map "$WORK/pool"            /pool)
[[ "$PROVISION" -eq 1 ]]    && MAP_ARGS+=(-map "$WORK/provision"       /provision)
# offline-bundle map (+ apt enable/restore helpers; avoid nested sh -c find \( \))
if [[ "$FULL_OFFLINE" -eq 1 ]]; then
  MAP_ARGS+=(-map "$OFFLINE_BUNDLE" /offline)
  MAP_ARGS+=(-map "$SCRIPT_DIR/autoinstall/enable-offline-apt.sh" /offline/enable-offline-apt.sh)
  MAP_ARGS+=(-map "$SCRIPT_DIR/autoinstall/restore-online-apt.sh" /offline/restore-online-apt.sh)
fi

log "打包 (复制模式, 引导记录 replay)"
xorriso -indev "$SRC_ISO" -outdev "$OUT_ISO" \
        "${MAP_ARGS[@]}" \
        -boot_image any replay \
        -commit 2>&1 | sed -e 's/^/    /' | tail -n 20

[[ -f "$OUT_ISO" ]] || die "打包失败, 未生成输出文件"

# --------------------------------------------------------------- 4. 校验
log "校验引导记录"
BOOT_REPORT="$(xorriso -indev "$OUT_ISO" -report_el_torito plain -report_system_area plain 2>&1 || true)"
echo "$BOOT_REPORT" | grep -qi 'El Torito' || die "输出 ISO 丢失 El Torito 引导记录"
BIOS_OK=no; UEFI_OK=no; GPT_OK=no
echo "$BOOT_REPORT" | grep -qi 'i386-pc\|isolinux\|El Torito boot img' && BIOS_OK=yes
echo "$BOOT_REPORT" | grep -qi 'efi\|UEFI' && UEFI_OK=yes
echo "$BOOT_REPORT" | grep -qi 'GPT' && GPT_OK=yes
printf '    BIOS/El-Torito: %s   UEFI: %s   GPT(hybrid): %s\n' "$BIOS_OK" "$UEFI_OK" "$GPT_OK"

log "校验注入内容"
xorriso -indev "$OUT_ISO" -ls /nocloud 2>/dev/null | grep -q 'user-data' \
  || die "/nocloud/user-data 未写入"
xorriso -osirrox on -indev "$OUT_ISO" -extract /boot/grub/grub.cfg "$WORK/verify.cfg" 2>/dev/null
grep -q 'autoinstall ds=nocloud' "$WORK/verify.cfg" \
  || die "grub.cfg 里的 autoinstall 参数丢失"
# 确认 GRUB 分号已转义
grep -qE 'ds=nocloud\\;s=/cdrom/nocloud/' "$WORK/verify.cfg" \
  || die "grub.cfg 里 ds= 分号未转义 (应为 ds=nocloud\\;s=...)"
if [[ "$FULL_OFFLINE" -eq 1 ]]; then
  xorriso -indev "$OUT_ISO" -ls /offline 2>/dev/null | grep -q 'manifest.json' \
    || die "/offline/manifest.json 未写入"
  xorriso -indev "$OUT_ISO" -ls /offline 2>/dev/null | grep -q 'enable-offline-apt.sh' \
    || die "/offline/enable-offline-apt.sh 未写入"
  xorriso -indev "$OUT_ISO" -ls /offline 2>/dev/null | grep -q 'restore-online-apt.sh' \
    || die "/offline/restore-online-apt.sh 未写入"
  ok "校验 /offline 捆绑已写入"
fi
if [[ "$PROVISION" -eq 1 ]]; then
  xorriso -indev "$OUT_ISO" -ls /provision 2>/dev/null | grep -q 'run-all.sh' \
    || die "/provision/run-all.sh 未写入"
  xorriso -osirrox on -indev "$OUT_ISO" -extract /nocloud/user-data "$WORK/v-user-data" 2>/dev/null
  grep -q 'run-all.sh' "$WORK/v-user-data" \
    || die "user-data 里没有调用 run-all.sh"
fi
if [[ "$EDITION" == "desktop" ]]; then
  xorriso -indev "$OUT_ISO" -ls / 2>/dev/null | grep -q 'autoinstall.yaml' \
    || die "Desktop: /autoinstall.yaml 未写入"
  xorriso -osirrox on -indev "$OUT_ISO" -extract /nocloud/user-data "$WORK/v-ud-desktop" 2>/dev/null
  grep -q 'id: '"$DESKTOP_SOURCE_ID" "$WORK/v-ud-desktop" \
    || die "Desktop: user-data 里 source.id 不是 $DESKTOP_SOURCE_ID"
  ok "Desktop: source=$DESKTOP_SOURCE_ID, /autoinstall.yaml 兜底已写入"
fi
ok "/nocloud 与 grub 参数均已就位"

SIZE_BYTES=$(stat -c %s "$OUT_ISO" 2>/dev/null || stat -f %z "$OUT_ISO")
if [[ "$SIZE_BYTES" -gt 4700000000 ]]; then
  warn "输出 ISO 超过 4.7GB, 单层 DVD 写不下, 只能走 U 盘"
fi

sha256sum "$OUT_ISO" | tee "$OUT_ISO.sha256"
ok "完成: $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
cat <<DONE

下一步:
  1) 写盘:  sudo dd if="$OUT_ISO" of=/dev/sdX bs=4M status=progress oflag=sync
  2) 或先在虚拟机验证:  bash $SCRIPT_DIR/test/qemu-smoke.sh "$OUT_ISO"

注意:
  * ISO 内的 md5sum.txt 未更新 —— casper 只在传 integrity-check 时才校验, 默认无影响。
  * 默认 interactive 装完会 reboot; 加了 --auto-disk 则 poweroff (关机), 避免 U 盘未拔循环抹盘。
DONE
