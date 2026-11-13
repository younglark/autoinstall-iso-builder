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
# 未传 --password 时的默认密码 (构建时告警, 装完请改)
DEFAULT_PASSWORD="ubuntu1990"
USED_DEFAULT_PASSWORD=0
PASS_HASH=""
PASS_PLAIN=""
LOCALE_="en_US.UTF-8"
KEYBOARD_="us"
TIMEZONE_="Asia/Shanghai"
MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu"
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
# Gitea 管理员 (默认 = --username / --password)
GITEA_ADMIN_USER=""
GITEA_ADMIN_PASSWORD=""
GITEA_ADMIN_EMAIL=""
# Jenkins 管理员 (同 Gitea 规则) 与预装插件
# --password-hash 已移除: 密码只接受 --password 明文或默认值, 所有服务统一使用
JENKINS_ADMIN_USER=""
JENKINS_ADMIN_PASSWORD=""
DEFAULT_JENKINS_PLUGINS="workflow-aggregator git gitea docker-workflow credentials-binding timestamper rebuild ansicolor docker-plugin parameterized-trigger"
JENKINS_PLUGINS="${JENKINS_PLUGINS:-$DEFAULT_JENKINS_PLUGINS}"
# 远程桌面 (仅 Desktop): 默认关 Wayland + 预装 RustDesk (IP 直连 21118); --remote-desktop x11vnc|none 切换;
# --wayland 保留 Wayland
WAYLAND=0
DISABLE_WAYLAND=0   # 内部: 由 EDITION + WAYLAND 推导后写入 provision.env
REMOTE_DESKTOP=""   # rustdesk | x11vnc | none; 空 = 按版本取默认 (Desktop rustdesk, Server none)
X11VNC=0            # 内部: REMOTE_DESKTOP=x11vnc
VNC_PASSWORD=""
RUSTDESK_PASSWORD=""
RUSTDESK_SERVER=""
RUSTDESK_ALLOW_ID=0    # 1 = RustDesk 保留公共 ID 服务器 (默认只允许局域网 IP 直连)
KEEP_OFFLINE_BUNDLE=0  # 1 = 装机后保留 /opt/offline (默认删除)
PIN_RUSTDESK="${PIN_RUSTDESK:-}"   # 空 = tools/rustdesk-release.sh 的 RUSTDESK_DEFAULT_VERSION
NO_FLCLASH=0
# Grok Bot 桌面版 (39-grok-bot.sh, 仅 Desktop): 默认装 feed 当前版本; --grok-bot-version / --grok-bot-url + --grok-bot-sha256 钉扎
NO_GROK_BOT=0
PIN_GROK_BOT="${PIN_GROK_BOT:-latest}"
GROK_BOT_DEB_URL="${GROK_BOT_DEB_URL:-}"
GROK_BOT_SHA256="${GROK_BOT_SHA256:-}"
# NVIDIA 驱动 (24-nvidia-driver.sh): 默认每台机器都装, 不做硬件检测
NO_NVIDIA_DRIVER=0
PIN_NVIDIA_DRIVER="${PIN_NVIDIA_DRIVER:-595}"
NVIDIA_KERNEL_FLAVOUR="${NVIDIA_KERNEL_FLAVOUR:-}"   # 空 = 装机时按已装内核 meta 自动判断
# Gitea / Jenkins 对外 URL 主机: 默认 <hostname>.local (mDNS); --service-url-host 覆盖 (IP / FQDN / localhost)
SERVICE_URL_HOST=""
MDNS_AVAHI=0        # 内部: Gitea / Jenkins / OpenCode Web 未被 --skip 时为 1 (12-avahi-mdns.sh 装 Avahi)

usage() {
  cat <<'USAGE'
用法:
  ./build-iso.sh --iso <原版ISO> --out <输出ISO> [选项]

必填:
  --iso PATH            官方 Ubuntu Server ISO (22.04 / 24.04) 或 Ubuntu Desktop 24.04 ISO
  --out PATH            输出 ISO 路径

身份 (可选; 不传则用默认用户 ubuntu / 密码 ubuntu1990, 构建时告警, 装完请改):
  --password PLAIN      明文, 脚本用 openssl passwd -6 现场哈希 (会留在 shell 历史里)
  --password-hash 已移除: 曾导致各服务密码随机生成 (镜像里没有明文可分发)

可选:
  --edition E           auto (默认) | server | desktop。auto 读 ISO 内
                        casper/install-sources.yaml 的 variant (退回 .disk/info) 判断
  --desktop-source S    仅 desktop: minimal (默认, ubuntu-desktop-minimal) |
                        standard (ubuntu-desktop, 带 Office 等全套) | 任意 source id
  --realname NAME       identity.realname (登录界面显示名); desktop 默认等于 --username
  --hostname NAME       默认 ubuntu-node。必须是单个 DNS 标签 (mDNS 主机名): 小写字母 / 数字 / 中间的
                        连字符, 1-63 位, 不能含点或下划线, 不能以连字符开头或结尾。
                        Gitea / Jenkins 的 URL 默认是 http://<NAME>.local:3000/ 与 :8080/ (每台机器请用不同名字)
  --username NAME       默认 ubuntu
  --packages "a,b,c"    预装软件包, 逗号分隔
  --mirror URL          默认清华 https://mirrors.tuna.tsinghua.edu.cn/ubuntu
                        (含 -security)。装完系统 apt 也用这个源。缺 CA 时先走 http
                        装 ca-certificates 再切回 https。内网或官方源请覆盖
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
  --keep-offline-bundle 全离线装机后保留 /opt/offline (约 2-3 GB)。默认在 software/ 和
                        restore-online-apt.sh 都跑完后删除 (装好的软件运行时不依赖它)
  --debs DIR            把目录下所有 .deb 打进 ISO 的 /pool 并离线安装 (旧局部离线)
  --no-provision        不执行 software/ 下的软件预装脚本
  --strict              任一软件装失败就中止安装 (默认: 记日志继续)
  --skip "30 70"        跳过脚本: 编号前缀或完整名均可 (30 或 30-jenkins)
  --pin-node N          Node 主版本, 默认 24 (也可用环境变量 PIN_NODE_MAJOR)
  --pin-grok VER        npm 版 @xai-official/grok, 默认 latest (PIN_GROK)
  --pin-opencode VER    npm 版 @opencode/cli (OpenCode 2.x), 默认 latest (PIN_OPENCODE)
  --pin-openmausbot VER npm 版 openmausbot, 默认 latest (PIN_OPENMAUSBOT)
  --pin-unity-cli VER  Unity CLI 版本, 默认拉 latest/latest-beta (PIN_UNITY_CLI)
  --pin-gitea VER       Gitea 版本 (如 28.3.0), 默认 latest (PIN_GITEA)
  --no-flclash          不预装 FlClash (等价于 --skip 37 / --skip 37-flclash);
                        Desktop 默认预装最新稳定版 (官方 GitHub Release + SHA256SUMS)
  --no-grok-bot         不预装 Grok Bot 桌面版 (等价于 --skip 39 / --skip 39-grok-bot)。
                        Desktop 默认预装官方 .deb (发布 feed 当前版本, sha256 取自签名的 apt 仓库索引),
                        保留它自带的 apt 源 (随 apt 更新); 不登录、不做任何配置, 装完用户自己登录
  --grok-bot-version V  Grok Bot 版本, 默认 latest (PIN_GROK_BOT); X.Y.Z 只能是 feed 当前版本或内置版本
  --grok-bot-url URL    完全钉扎: Grok Bot .deb 的 URL (可指向内网镜像), 必须同时给 --grok-bot-sha256
  --grok-bot-sha256 H   Grok Bot .deb 的期望 sha256 (GROK_BOT_SHA256)
  --no-nvidia-driver    不装 NVIDIA 驱动 (等价于 --skip 24 / --skip 24-nvidia-driver)。
                        默认每台机器都装 (不检测硬件): nvidia-driver-<N>-open + Canonical 签名的
                        预编译模块 linux-modules-nvidia-<N>-open-<flavour> + 同版本内核 meta,
                        以及 intel-media-va-driver-non-free / vainfo
  --nvidia-driver-version N
                        NVIDIA 驱动分支, 默认 595 (PIN_NVIDIA_DRIVER)
  --nvidia-kernel-flavour F
                        内核 flavour (如 generic-hwe-24.04 / generic), 默认装机时按已装内核自动判断
  --gitea-admin-user U  Gitea 管理员用户名, 默认 = --username
  --gitea-admin-password P
                        Gitea 管理员密码 (>=8 位), 默认 = --password 明文 (含默认密码)
  --gitea-admin-email E Gitea 管理员邮箱, 默认 <用户名>@localhost
  --jenkins-admin-user U
                        Jenkins 管理员用户名, 默认 = --username
  --jenkins-admin-password P
                        Jenkins 管理员密码, 默认 = --password 明文 (含默认密码)
  --service-url-host H  Gitea / Jenkins 对外 URL 的主机部分, 覆盖默认的 <hostname>.local:
                        IPv4 / FQDN / localhost, 如 192.168.1.20 或 ci.example.com
                        → http://H:3000/ 与 http://H:8080/
  --jenkins-plugins "a b c"
                        预装的 Jenkins 插件 (自动带全部依赖; 可写 name:version), 空格分隔
                        默认: workflow-aggregator git gitea docker-workflow credentials-binding timestamper rebuild ansicolor docker-plugin parameterized-trigger
  (远程桌面)            Desktop 默认: GDM 关闭 Wayland (/etc/gdm3/custom.conf WaylandEnable=false,
                        登录界面 / 锁屏 / 会话全走 Xorg) 并预装 RustDesk, 开机即可在登录界面、锁屏和
                        会话里用 RustDesk 客户端按 IP 直连 (端口 21118/tcp, 局域网), 并关闭合盖 / 空闲挂起
                        (锁屏保留)。关 Wayland 由 36 钩子落地, RustDesk 由 38 钩子落地
  --remote-desktop M    仅 desktop: rustdesk (默认) | x11vnc (VNC 5900, 不加密) | none (不装远程桌面)
  --rustdesk-password P RustDesk 固定密码 (≥6 位)。默认 = --password 明文 (含默认密码)
  --rustdesk-server H   自建 RustDesk 服务器 (hbbs/hbbr) 主机, 可带端口; 写入 custom-rendezvous-server /
                        relay-server, 可经自建服务器按 ID 连。默认不设
  --rustdesk-allow-id   RustDesk 保留公共 ID 服务器 (rs-ny.rustdesk.com), 可跨网络按 ID 连。默认关闭:
                        只允许局域网 <机器IP>:21118 直连, ID / 中继 / API 服务器指向 127.0.0.1,
                        不向公共服务器注册, 外网无法按 ID 连入
  --pin-rustdesk VER    RustDesk 版本 (如 1.5.1), 默认见 tools/rustdesk-release.sh (PIN_RUSTDESK)
  --wayland             仅 desktop: 保留 Wayland, 不改合盖 / 空闲挂起设置。不能与 --remote-desktop x11vnc
                        同用; 与 RustDesk 同用时告警 (Wayland 下连不了登录界面, 会话里每次要手动授权共享屏幕)
  --vnc-password P      x11vnc 密码 (≥6 位, VNC 只用前 8 个字符), 仅 --remote-desktop x11vnc。
                        默认 = --password 明文 (含默认密码)
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
                 --password 'Ch@ngeMe' \
                 --packages "vim,curl,htop,net-tools" \
                 --mirror http://archive.ubuntu.com/ubuntu \
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
    --password-hash)  die "--password-hash 已移除: 传哈希意味着镜像里没有明文可分发, 装机时 Gitea/Jenkins/OpenCode/RustDesk 只能各自生成随机密码 (写入目标机 /root/*-password)。请改用 --password '你的密码', 或什么都不传走默认 ubuntu/ubuntu1990 (构建时告警)" ;;
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
    --no-flclash)     NO_FLCLASH=1; shift ;;
    --no-grok-bot)    NO_GROK_BOT=1; shift ;;
    --grok-bot-version) PIN_GROK_BOT="$2"; shift 2 ;;
    --grok-bot-url)   GROK_BOT_DEB_URL="$2"; shift 2 ;;
    --grok-bot-sha256) GROK_BOT_SHA256="$2"; shift 2 ;;
    --no-nvidia-driver) NO_NVIDIA_DRIVER=1; shift ;;
    --nvidia-driver-version) PIN_NVIDIA_DRIVER="$2"; shift 2 ;;
    --nvidia-kernel-flavour) NVIDIA_KERNEL_FLAVOUR="$2"; shift 2 ;;
    --gitea-admin-user) GITEA_ADMIN_USER="$2"; shift 2 ;;
    --gitea-admin-password) GITEA_ADMIN_PASSWORD="$2"; shift 2 ;;
    --gitea-admin-email) GITEA_ADMIN_EMAIL="$2"; shift 2 ;;
    --jenkins-admin-user) JENKINS_ADMIN_USER="$2"; shift 2 ;;
    --jenkins-admin-password) JENKINS_ADMIN_PASSWORD="$2"; shift 2 ;;
    --jenkins-plugins) JENKINS_PLUGINS="$2"; shift 2 ;;
    --service-url-host) SERVICE_URL_HOST="$2"; shift 2 ;;
    --wayland)        WAYLAND=1; shift ;;
    --disable-wayland)
      die "$1 已移除: Desktop 现在默认关闭 Wayland (远程桌面默认 RustDesk); 要保留 Wayland 请用 --wayland" ;;
    --x11vnc)
      die "$1 已移除: Desktop 远程桌面默认 RustDesk; 要用 x11vnc 请改成 --remote-desktop x11vnc (保留 Wayland 用 --wayland)" ;;
    --remote-desktop) REMOTE_DESKTOP="$2"; shift 2 ;;
    --rustdesk-password) RUSTDESK_PASSWORD="$2"; shift 2 ;;
    --rustdesk-server) RUSTDESK_SERVER="$2"; shift 2 ;;
    --rustdesk-allow-id) RUSTDESK_ALLOW_ID=1; shift ;;
    --keep-offline-bundle) KEEP_OFFLINE_BUNDLE=1; shift ;;
    --pin-rustdesk)   PIN_RUSTDESK="$2"; shift 2 ;;
    --vnc-password)   VNC_PASSWORD="$2"; shift 2 ;;
    --iso-sha256)     ISO_SHA256="$2"; shift 2 ;;
    --iso-sha256sums) ISO_SHA256SUMS="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --keep-work)      KEEP_WORK=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) die "未知参数: $1 (用 --help 查看)" ;;
  esac
done

# 清华 http 升为 https (其它源不动)。装完系统 / 抓包都用规范化后的 URL。
# shellcheck disable=SC1091
. "$SCRIPT_DIR/tools/ubuntu-mirror.sh"
MIRROR="$(aib_normalize_mirror "$MIRROR")"


[[ -n "$SRC_ISO" ]] || { usage; die "缺少 --iso"; }
[[ -n "$OUT_ISO" ]] || { usage; die "缺少 --out"; }
[[ -f "$SRC_ISO" ]] || die "源 ISO 不存在: $SRC_ISO"

# 默认凭据: 未传 --password → 默认密码, 所有服务 (Gitea/Jenkins/OpenCode/RustDesk/VNC) 统一使用
if [[ -z "$PASS_PLAIN" ]]; then
  PASS_PLAIN="$DEFAULT_PASSWORD"
  USED_DEFAULT_PASSWORD=1
fi

if [[ -n "$SSH_AUTHORIZED_KEYS" ]]; then
  [[ -f "$SSH_AUTHORIZED_KEYS" ]] || die "--ssh-authorized-keys 文件不存在: $SSH_AUTHORIZED_KEYS"
fi

# hostname: mDNS / RFC 1123 单标签 (Gitea / Jenkins URL 用 <hostname>.local); 不自动改写
# shellcheck disable=SC1091
. "$SCRIPT_DIR/software/lib-service-url.sh"
aib_valid_mdns_label "$HOSTNAME_" \
  || die "--hostname 非法: '$HOSTNAME_'。必须是单个主机名标签: 只含小写字母 a-z、数字 0-9 和中间的连字符 -,
  1-63 位, 不能含点 (.) 或下划线 (_), 不能以连字符开头或结尾。例如: ubuntu-node、node01、desk-01"
if [[ -n "$SERVICE_URL_HOST" ]]; then
  SERVICE_URL_HOST="$(printf '%s' "$SERVICE_URL_HOST" | tr '[:upper:]' '[:lower:]')"
  aib_valid_service_host "$SERVICE_URL_HOST" \
    || die "--service-url-host 非法: '$SERVICE_URL_HOST'。只接受 IPv4 (如 192.168.1.20)、主机名 / FQDN
  (如 ci.example.com, 每段只含字母数字和中间的连字符) 或 localhost; 不要带 http:// 或端口"
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
if [[ "${NO_FLCLASH:-0}" -eq 1 ]]; then
  case " $PROVISION_SKIP " in
    *" 37 "*|*" 37-flclash "*) ;;
    *) PROVISION_SKIP="${PROVISION_SKIP:+$PROVISION_SKIP }37-flclash" ;;
  esac
fi
# Grok Bot: 格式校验与 tools/grok-bot-release.sh 同一套
# shellcheck disable=SC1091
. "$SCRIPT_DIR/tools/grok-bot-release.sh"
grokbot_valid_version "$PIN_GROK_BOT" || die "非法 --grok-bot-version: $PIN_GROK_BOT (latest 或 X.Y.Z, 如 0.79.4)"
[[ -z "$GROK_BOT_DEB_URL" ]] || grokbot_valid_url "$GROK_BOT_DEB_URL" \
  || die "非法 --grok-bot-url: $GROK_BOT_DEB_URL (http(s)://主机[:端口]/路径/xxx.deb, 路径只能含 A-Za-z0-9._~%/+-)"
GROK_BOT_SHA256="$(printf '%s' "$GROK_BOT_SHA256" | tr '[:upper:]' '[:lower:]')"
[[ -z "$GROK_BOT_SHA256" ]] || grokbot_valid_sha256 "$GROK_BOT_SHA256" || die "非法 --grok-bot-sha256 (64 位 hex)"
[[ -z "$GROK_BOT_DEB_URL" || -n "$GROK_BOT_SHA256" ]] || die "--grok-bot-url 必须同时给 --grok-bot-sha256 (保证可复现)"
if [[ "${NO_GROK_BOT:-0}" -eq 1 ]]; then
  case " $PROVISION_SKIP " in
    *" 39 "*|*" 39-grok-bot "*) ;;
    *) PROVISION_SKIP="${PROVISION_SKIP:+$PROVISION_SKIP }39-grok-bot" ;;
  esac
fi
[[ "$PIN_NVIDIA_DRIVER" =~ ^[0-9]{3,4}$ ]] || die "非法 --nvidia-driver-version: $PIN_NVIDIA_DRIVER (驱动分支号, 如 595)"
[[ -z "$NVIDIA_KERNEL_FLAVOUR" || "$NVIDIA_KERNEL_FLAVOUR" =~ ^[a-z0-9][a-z0-9.-]*$ ]] \
  || die "非法 --nvidia-kernel-flavour: $NVIDIA_KERNEL_FLAVOUR (如 generic-hwe-24.04 / generic)"
if [[ "${NO_NVIDIA_DRIVER:-0}" -eq 1 ]]; then
  case " $PROVISION_SKIP " in
    *" 24 "*|*" 24-nvidia-driver "*) ;;
    *) PROVISION_SKIP="${PROVISION_SKIP:+$PROVISION_SKIP }24-nvidia-driver" ;;
  esac
fi

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

# Gitea / Jenkins / OpenCode Web 对外 URL (装机时由钩子按目标机 /etc/hostname 落地; 这里只决定是否装 Avahi 并提示)
if [[ "$PROVISION" -eq 1 ]] && { ! should_skip_script 30-jenkins || ! should_skip_script 45-gitea || ! should_skip_script 60-opencode; }; then
  if [[ -n "$SERVICE_URL_HOST" ]]; then
    _url_host="$SERVICE_URL_HOST"
  else
    _url_host="$HOSTNAME_.local"
  fi
  MDNS_AVAHI=1
  should_skip_script 45-gitea     || log "Gitea URL: http://$_url_host:3000/"
  should_skip_script 30-jenkins   || log "Jenkins URL: http://$_url_host:8080/"
  should_skip_script 60-opencode  || log "OpenCode Web URL: http://$_url_host:4096/"
  if should_skip_script 12-avahi-mdns; then
    warn "--skip 跳过了 12-avahi-mdns: 不装 / 不启用 Avahi, $HOSTNAME_.local 可能无法解析"
  fi
  if [[ -z "$SERVICE_URL_HOST" ]]; then
    warn "Gitea / Jenkins / OpenCode Web URL 用 $HOSTNAME_.local (mDNS): 同一网络里每台机器要用不同的 --hostname (重名时 Avahi 会改成 $HOSTNAME_-2.local, URL 失效); 装完改主机名 URL 不会跟着变; Android / Docker 容器 / 跨网段通常解析不了 .local, 可用 --service-url-host 改成 IP 或域名"
  fi
elif [[ -n "$SERVICE_URL_HOST" ]]; then
  warn "--service-url-host 只用于预装的 Gitea / Jenkins / OpenCode Web; 都没装 (--skip / --no-provision), 忽略"
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
  warn "未传 --password: 使用默认密码 (用户 $USERNAME_; Gitea/Jenkins 管理员、OpenCode Web、RustDesk 同此)。这是公开的默认值, 装完请立即修改: passwd + Gitea/Jenkins/OpenCode Web 改密"
fi
command -v openssl >/dev/null || die "缺少 openssl, 无法哈希密码"
PASS_HASH="$(openssl passwd -6 "$PASS_PLAIN")"
[[ "$PASS_HASH" == \$* ]] || die "openssl passwd -6 输出异常 (应以 \$ 开头)"

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

# ---------------------------------------------------------------- 远程桌面 (Desktop 默认开启)
# Desktop: 默认关 Wayland (36-x11vnc-xorg.sh) + RustDesk (38-rustdesk.sh); --remote-desktop x11vnc 改装 x11vnc (36);
# --remote-desktop none 不装远程桌面; --wayland 保留 Wayland。Server: 全部关, 钩子空跑。
VNC_PW_SOURCE=""
RUSTDESK_PW_SOURCE=""
REMOTE_DESKTOP_SET=0
[[ -n "$REMOTE_DESKTOP" ]] && REMOTE_DESKTOP_SET=1
case "$REMOTE_DESKTOP" in
  ""|rustdesk|x11vnc|none) ;;
  *) die "--remote-desktop 必须是 rustdesk | x11vnc | none (got: $REMOTE_DESKTOP)" ;;
esac
if [[ -n "$PIN_RUSTDESK" ]]; then
  [[ "$PIN_RUSTDESK" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+)?$ ]] || die "非法 --pin-rustdesk: $PIN_RUSTDESK (X.Y.Z, 如 1.5.1)"
else
  # shellcheck disable=SC1091
  PIN_RUSTDESK="$(. "$SCRIPT_DIR/tools/rustdesk-release.sh" && printf '%s' "$RUSTDESK_DEFAULT_VERSION")"
fi
if [[ "$EDITION" != "desktop" ]]; then
  if [[ "$WAYLAND" -eq 1 ]]; then warn "--wayland 只用于 Desktop; 当前 edition=$EDITION, 忽略"; fi
  if [[ "$REMOTE_DESKTOP_SET" -eq 1 && "$REMOTE_DESKTOP" != "none" ]]; then
    warn "--remote-desktop 只用于 Desktop; 当前 edition=$EDITION, 忽略"
  fi
  DISABLE_WAYLAND=0
  REMOTE_DESKTOP=none
else
  if [[ "$WAYLAND" -eq 1 ]]; then DISABLE_WAYLAND=0; else DISABLE_WAYLAND=1; fi
  if [[ "$PROVISION" -ne 1 ]]; then
    # 关 Wayland / 远程桌面都由 software/ 钩子落地, --no-provision 时都做不了
    [[ "$WAYLAND" -eq 1 ]] || die "Desktop 默认关 Wayland + 预装 RustDesk, 由 software/36-x11vnc-xorg.sh / 38-rustdesk.sh 落地, 不能与 --no-provision 同用 (要保留 Wayland 且不装远程桌面请加 --wayland)"
    if [[ "$REMOTE_DESKTOP_SET" -eq 1 && "$REMOTE_DESKTOP" != "none" ]]; then
      die "--remote-desktop $REMOTE_DESKTOP 由 software/ 钩子安装, 不能与 --no-provision 同用"
    fi
    REMOTE_DESKTOP=none
  fi
  [[ -n "$REMOTE_DESKTOP" ]] || REMOTE_DESKTOP=rustdesk
  if [[ "$WAYLAND" -eq 1 && "$REMOTE_DESKTOP" == "x11vnc" ]]; then
    die "--remote-desktop x11vnc 只能接管 Xorg 显示, 不能与 --wayland 同用 (要保留 Wayland 请改用 --remote-desktop rustdesk 或 none)"
  fi
fi
X11VNC=0
[[ "$REMOTE_DESKTOP" == "x11vnc" ]] && X11VNC=1
if [[ "$X11VNC" -eq 1 ]]; then
  if [[ -n "$VNC_PASSWORD" ]]; then
    [[ "$VNC_PASSWORD" != *$'\n'* ]] || die "--vnc-password 不能含换行"
    [[ "${#VNC_PASSWORD}" -ge 6 ]] || die "--vnc-password 至少 6 位"
    VNC_PW_SOURCE="explicit"
  elif [[ -n "$PASS_PLAIN" ]]; then
    VNC_PASSWORD="$PASS_PLAIN"
    VNC_PW_SOURCE="password"
  else
    VNC_PW_SOURCE="random"
  fi
  if [[ -n "$VNC_PASSWORD" && "${#VNC_PASSWORD}" -gt 8 ]]; then
    warn "VNC 密码超过 8 位: VNC 协议只校验前 8 个字符"
  fi
elif [[ -n "$VNC_PASSWORD" ]]; then
  if [[ "$EDITION" == "desktop" ]]; then
    warn "--vnc-password 只用于 --remote-desktop x11vnc (当前 $REMOTE_DESKTOP), 忽略"
  else
    warn "--vnc-password 只用于 Desktop 的 x11vnc; 当前 edition=$EDITION, 忽略"
  fi
  VNC_PASSWORD=""
fi
if [[ "$REMOTE_DESKTOP" == "rustdesk" ]]; then
  if [[ -n "$RUSTDESK_PASSWORD" ]]; then
    [[ "$RUSTDESK_PASSWORD" != *$'\n'* ]] || die "--rustdesk-password 不能含换行"
    [[ "${#RUSTDESK_PASSWORD}" -ge 6 ]] || die "--rustdesk-password 至少 6 位"
    RUSTDESK_PW_SOURCE="explicit"
  elif [[ -n "$PASS_PLAIN" ]]; then
    RUSTDESK_PASSWORD="$PASS_PLAIN"
    RUSTDESK_PW_SOURCE="password"
  else
    RUSTDESK_PW_SOURCE="random"
  fi
  if [[ -n "$RUSTDESK_SERVER" ]]; then
    RUSTDESK_SERVER="$(printf '%s' "$RUSTDESK_SERVER" | tr '[:upper:]' '[:lower:]')"
    [[ "$RUSTDESK_SERVER" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]{1,5})?$ ]] \
      || die "--rustdesk-server 非法: '$RUSTDESK_SERVER'。只接受主机名 / IPv4, 可带 :端口 (如 192.168.1.20 或 rd.example.com:21116); 不要带 http://"
  fi
else
  if [[ -n "$RUSTDESK_PASSWORD" ]]; then
    warn "--rustdesk-password 只用于 Desktop 的 --remote-desktop rustdesk (当前 edition=$EDITION remote-desktop=$REMOTE_DESKTOP), 忽略"
    RUSTDESK_PASSWORD=""
  fi
  if [[ -n "$RUSTDESK_SERVER" ]]; then
    warn "--rustdesk-server 只用于 Desktop 的 --remote-desktop rustdesk (当前 edition=$EDITION remote-desktop=$REMOTE_DESKTOP), 忽略"
    RUSTDESK_SERVER=""
  fi
  if [[ "$RUSTDESK_ALLOW_ID" -eq 1 ]]; then
    warn "--rustdesk-allow-id 只用于 Desktop 的 --remote-desktop rustdesk (当前 edition=$EDITION remote-desktop=$REMOTE_DESKTOP), 忽略"
    RUSTDESK_ALLOW_ID=0
  fi
fi
if [[ "$RUSTDESK_ALLOW_ID" -eq 1 && -n "$RUSTDESK_SERVER" ]]; then
  warn "--rustdesk-allow-id 与 --rustdesk-server 同用: 按 ID 连走自建服务器 $RUSTDESK_SERVER, 不连公共服务器"
  RUSTDESK_ALLOW_ID=0
fi
if [[ "$DISABLE_WAYLAND" -eq 1 ]] && should_skip_script 36-x11vnc-xorg; then
  if [[ "$X11VNC" -eq 1 ]]; then
    warn "--skip 跳过了 36-x11vnc-xorg: 保留 Wayland, 不装 x11vnc"
  else
    warn "--skip 跳过了 36-x11vnc-xorg: 保留 Wayland, 不改合盖 / 空闲挂起"
  fi
fi
if [[ "$REMOTE_DESKTOP" == "rustdesk" ]]; then
  if should_skip_script 38-rustdesk; then
    warn "--skip 跳过了 38-rustdesk: 不装 RustDesk"
  else
    if [[ -n "$RUSTDESK_SERVER" ]]; then _rd_id="按 ID 连走自建服务器 $RUSTDESK_SERVER"
    elif [[ "$RUSTDESK_ALLOW_ID" -eq 1 ]]; then _rd_id="保留公共 ID 服务器 (--rustdesk-allow-id)"
    else _rd_id="只允许局域网 IP 直连, 不连公共 ID / 中继服务器; 恢复: --rustdesk-allow-id"; fi
    log "远程桌面: RustDesk $PIN_RUSTDESK (局域网 IP 直连 21118/tcp, 只用固定密码, $_rd_id)${RUSTDESK_PW_SOURCE:+ rustdesk-password=$RUSTDESK_PW_SOURCE}${RUSTDESK_SERVER:+ server=$RUSTDESK_SERVER}; 改用 x11vnc / 不装: --remote-desktop x11vnc|none"
    if [[ "$WAYLAND" -eq 1 ]] || should_skip_script 36-x11vnc-xorg; then
      warn "RustDesk + Wayland: 连不了 GDM 登录界面 / 锁屏后的重新登录, 会话里每次连接都要在本机手动同意共享屏幕; 要无人值守请去掉 --wayland"
    fi
    warn "RustDesk 安全提示: 21118 直连端口在局域网内任何人都能连 (靠固定密码保护); 不要映射到公网 (外网走 VPN / 自建中继)"
    if [[ "$RUSTDESK_PW_SOURCE" == "password" && "$USED_DEFAULT_PASSWORD" -eq 1 ]]; then
      warn "RustDesk 使用默认密码 (与用户 $USERNAME_ 相同, 公开的默认值); 装完请改: sudo rustdesk --password '<新密码>'"
    fi
  fi
fi
if [[ "$X11VNC" -eq 1 ]]; then
  if should_skip_script 36-x11vnc-xorg; then
    :
  else
    log "远程桌面: 关 Wayland + x11vnc (端口 5900)${VNC_PW_SOURCE:+ vnc-password=$VNC_PW_SOURCE}; 默认 RustDesk 请去掉 --remote-desktop x11vnc"
    warn "x11vnc 安全提示: VNC 流量不加密, 局域网内可直接连 5900 端口; 只在可信网络用, 不要映射到公网 (外网走 VPN / SSH 隧道)"
    if [[ "$VNC_PW_SOURCE" == "password" && "$USED_DEFAULT_PASSWORD" -eq 1 ]]; then
      warn "x11vnc 使用默认密码 (与用户 $USERNAME_ 相同, 公开的默认值); 装完请改: sudo x11vnc -storepasswd /etc/x11vnc.pass && sudo systemctl restart x11vnc"
    fi
  fi
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
    --pin-opencode "$PIN_OPENCODE" --pin-openmausbot "$PIN_OPENMAUSBOT"
    --ubuntu-mirror "$MIRROR")
  [[ -n "$PIN_UNITY_CLI" ]] && FETCH_ARGS+=(--pin-unity-cli "$PIN_UNITY_CLI")
  FETCH_ARGS+=(--pin-gitea "$PIN_GITEA" --jenkins-plugins "$JENKINS_PLUGINS" --pin-rustdesk "$PIN_RUSTDESK")
  if should_skip_script 24-nvidia-driver; then
    FETCH_ARGS+=(--no-nvidia-driver)
  else
    FETCH_ARGS+=(--nvidia-driver-version "$PIN_NVIDIA_DRIVER")
    [[ -n "$NVIDIA_KERNEL_FLAVOUR" ]] && FETCH_ARGS+=(--nvidia-kernel-flavours "$NVIDIA_KERNEL_FLAVOUR")
  fi
  # Grok Bot 只在 Desktop 装: Server 构建传 --edition server, 默认不抓 (已有 Desktop 抓的超集捆绑照常复用)
  FETCH_ARGS+=(--edition "$EDITION")
  if [[ "$EDITION" == "desktop" ]]; then
    if should_skip_script 39-grok-bot; then
      FETCH_ARGS+=(--no-grok-bot)
    else
      FETCH_ARGS+=(--grok-bot-version "$PIN_GROK_BOT")
      [[ -n "$GROK_BOT_DEB_URL" ]] && FETCH_ARGS+=(--grok-bot-url "$GROK_BOT_DEB_URL")
      [[ -n "$GROK_BOT_SHA256" ]] && FETCH_ARGS+=(--grok-bot-sha256 "$GROK_BOT_SHA256")
    fi
  fi
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
  if [[ "$KEEP_OFFLINE_BUNDLE" -eq 1 ]]; then
    log "装机后保留 /opt/offline (--keep-offline-bundle)"
  else
    log "装机后删除 /opt/offline (software/ 与 restore-online-apt.sh 跑完之后); 保留: --keep-offline-bundle"
  fi
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
    # NVIDIA 驱动 (validate 自己处理 --skip 24): 捆绑里模块 meta 与内核 meta 版本必须一致
    VAL_ARGS+=(--nvidia-driver-version "$PIN_NVIDIA_DRIVER")
    [[ -n "$NVIDIA_KERNEL_FLAVOUR" ]] && VAL_ARGS+=(--nvidia-kernel-flavour "$NVIDIA_KERNEL_FLAVOUR")
    # --remote-desktop x11vnc: 捆绑必须带 x11vnc + xauth (validate 自己处理 --skip 36)
    [[ "$X11VNC" -eq 1 ]] && VAL_ARGS+=(--require-x11vnc)
    # Desktop 默认 RustDesk: 捆绑必须带 rustdesk/ (同版本 deb + sha256) 且 apt 池能装 (validate 自己处理 --skip 38)
    [[ "$REMOTE_DESKTOP" == "rustdesk" ]] && VAL_ARGS+=(--require-rustdesk --pin-rustdesk "$PIN_RUSTDESK")
    # Desktop 默认 Grok Bot: 捆绑必须带 grok-bot/ (deb + sha256) 且 apt 池能装 (validate 自己处理 --skip 39)
    if [[ "$EDITION" == "desktop" ]]; then
      VAL_ARGS+=(--require-grok-bot --grok-bot-version "$PIN_GROK_BOT")
      [[ -n "$GROK_BOT_SHA256" ]] && VAL_ARGS+=(--grok-bot-sha256 "$GROK_BOT_SHA256")
    fi
    # Server 预装 Gitea / Jenkins: <hostname>.local 要 Avahi (Desktop 自带); 2026-11 之前的捆绑没有 → --force-fetch
    [[ "$EDITION" == "server" && "$MDNS_AVAHI" -eq 1 ]] && VAL_ARGS+=(--require-mdns)
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
[[ "$KEEP_OFFLINE_BUNDLE" -eq 1 ]] && RENDER_ARGS+=(--keep-offline-bundle)
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
  # https 源引导 (00-base / restore-online-apt 会用到)
  cp "$SCRIPT_DIR/tools/ubuntu-mirror.sh" "$WORK/provision/"
  chmod 0755 "$WORK/provision/ubuntu-mirror.sh"
  # Jenkins 插件解析器 (30-jenkins.sh 在线路径用; 与 fetch-offline-bundle 同一份)
  cp "$SCRIPT_DIR/tools/resolve-jenkins-plugins.py" "$WORK/provision/"
  cp "$SCRIPT_DIR/tools/flclash-release.sh" "$SCRIPT_DIR/tools/rustdesk-release.sh" "$SCRIPT_DIR/tools/grok-bot-release.sh" "$WORK/provision/"
  chmod 0755 "$WORK/provision/flclash-release.sh" "$WORK/provision/rustdesk-release.sh" "$WORK/provision/grok-bot-release.sh"
  cp "$SCRIPT_DIR/tools/grok-bot-archive-key.asc" "$WORK/provision/"
  # 逐行 %q 写入, 保证 source 安全 (旧写法 EXTRA_APT_PACKAGES=vim, htop 会把 htop 当命令执行)
  {
    echo "# 由 build-iso.sh 生成 (printf %q; 请勿手改未加引号的值)"
    printf 'TARGET_USER=%q
' "$USERNAME_"
    printf 'EDITION=%q
' "$EDITION"
    printf 'UBUNTU_MIRROR=%q
' "$MIRROR"
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
    printf 'AIB_HOSTNAME=%q\n' "$HOSTNAME_"
    printf 'SERVICE_URL_HOST=%q\n' "$SERVICE_URL_HOST"
    printf 'MDNS_AVAHI=%q\n' "$MDNS_AVAHI"
    printf 'DISABLE_WAYLAND=%q\n' "$DISABLE_WAYLAND"
    printf 'X11VNC=%q\n' "$X11VNC"
    printf 'REMOTE_DESKTOP=%q\n' "$REMOTE_DESKTOP"
    printf 'PIN_RUSTDESK=%q\n' "$PIN_RUSTDESK"
    printf 'RUSTDESK_SERVER=%q\n' "$RUSTDESK_SERVER"
    printf 'RUSTDESK_ALLOW_ID=%q\n' "$RUSTDESK_ALLOW_ID"
    printf 'PIN_NVIDIA_DRIVER=%q\n' "$PIN_NVIDIA_DRIVER"
    printf 'NVIDIA_KERNEL_FLAVOUR=%q\n' "$NVIDIA_KERNEL_FLAVOUR"
    printf 'PIN_GROK_BOT=%q\n' "$PIN_GROK_BOT"
    printf 'GROK_BOT_DEB_URL=%q\n' "$GROK_BOT_DEB_URL"
    printf 'GROK_BOT_SHA256=%q\n' "$GROK_BOT_SHA256"
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
  fi
  # Jenkins 管理员明文密码同理: 0600 文件, 30-jenkins.sh 只写 bcrypt 哈希进 init.groovy.d 并删除此文件
  if [[ -n "$JENKINS_ADMIN_PASSWORD" ]] && ! should_skip_script 30-jenkins; then
    ( umask 077; printf 'JENKINS_ADMIN_PASSWORD=%q\n' "$JENKINS_ADMIN_PASSWORD" > "$WORK/provision/jenkins-admin.secret" )
    chmod 0600 "$WORK/provision/jenkins-admin.secret"
    ok "Jenkins 管理员 $JENKINS_ADMIN_USER: 密码随 ISO 投递 (装机时转 bcrypt, 删除明文)"
  fi
  # x11vnc 明文密码同理: 0600 文件, 36-x11vnc-xorg.sh 转成 /etc/x11vnc.pass 后删除
  if [[ "$X11VNC" -eq 1 && -n "$VNC_PASSWORD" ]] && ! should_skip_script 36-x11vnc-xorg; then
    ( umask 077; printf 'VNC_PASSWORD=%q\n' "$VNC_PASSWORD" > "$WORK/provision/x11vnc.secret" )
    chmod 0600 "$WORK/provision/x11vnc.secret"
    ok "x11vnc: 密码随 ISO 投递 (装机时写 /etc/x11vnc.pass, 删除明文)"
  fi
  # RustDesk 固定密码同理: 0600 文件, 38-rustdesk.sh 移到 /etc/aib/rustdesk.secret (root 0600), 首次开机设好后删除
  if [[ "$REMOTE_DESKTOP" == "rustdesk" && -n "$RUSTDESK_PASSWORD" ]] && ! should_skip_script 38-rustdesk; then
    ( umask 077; printf 'RUSTDESK_PASSWORD=%q\n' "$RUSTDESK_PASSWORD" > "$WORK/provision/rustdesk.secret" )
    chmod 0600 "$WORK/provision/rustdesk.secret"
    ok "RustDesk: 固定密码随 ISO 投递 (首次开机设置后删除明文)"
  fi
  # OpenCode Web 明文密码同理: 0600 文件, 60-opencode.sh 写入 /etc/opencode/web.env 后删除
  if [[ -n "$PASS_PLAIN" ]] && ! should_skip_script 60-opencode; then
    ( umask 077; printf 'OPENCODE_WEB_PASSWORD=%q\n' "$PASS_PLAIN" > "$WORK/provision/opencode-web.secret" )
    chmod 0600 "$WORK/provision/opencode-web.secret"
    ok "OpenCode Web: 密码随 ISO 投递 (装机时写 /etc/opencode/web.env, 删除明文)"
  fi
  SCRIPT_COUNT=$(find "$WORK/provision" -maxdepth 1 -name '[0-9][0-9]-*.sh' | wc -l)
  ok "已打包 $SCRIPT_COUNT 个软件预装脚本 (node>=$PIN_NODE_MAJOR grok=$PIN_GROK)"
  [[ -n "$PROVISION_SKIP" ]] && warn "跳过: $PROVISION_SKIP"
  if should_skip_script 24-nvidia-driver; then
    log "NVIDIA 驱动: 不装 (--no-nvidia-driver / --skip 24)"
  else
    log "NVIDIA 驱动: 每台机器都装 (不检测硬件) nvidia-driver-${PIN_NVIDIA_DRIVER}-open + 预编译签名模块 (内核 flavour ${NVIDIA_KERNEL_FLAVOUR:-自动}); 关闭: --no-nvidia-driver"
  fi
fi
if [[ "$PROVISION" -eq 1 ]]; then
  if [[ "$EDITION" != "desktop" ]]; then
    if [[ "$PIN_GROK_BOT" != "latest" || -n "$GROK_BOT_DEB_URL$GROK_BOT_SHA256" ]]; then
      warn "--grok-bot-version / --grok-bot-url / --grok-bot-sha256 只用于 Desktop (当前 edition=$EDITION), 忽略"
    fi
  elif should_skip_script 39-grok-bot; then
    log "Grok Bot 桌面版: 不装 (--no-grok-bot / --skip 39)"
  else
    log "Grok Bot 桌面版: 预装 ${GROK_BOT_DEB_URL:+钉扎 URL }${PIN_GROK_BOT}${GROK_BOT_SHA256:+ sha256=${GROK_BOT_SHA256:0:12}…} (只装应用, 不登录; 失败只跳过); 关闭: --no-grok-bot"
    if [[ "$FULL_OFFLINE" -ne 1 && -z "$GROK_BOT_DEB_URL" ]]; then
      warn "Grok Bot 在线装机要访问 api2.cursor.sh / downloads.cursor.com (国内可能很慢或被拦截, 失败只跳过); 稳妥做法: --fetch-offline 离线捆绑"
    fi
  fi
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
  printf '%s\n' "$MIRROR" > "$WORK/ubuntu-mirror.url"
  MAP_ARGS+=(-map "$OFFLINE_BUNDLE" /offline)
  MAP_ARGS+=(-map "$SCRIPT_DIR/autoinstall/enable-offline-apt.sh" /offline/enable-offline-apt.sh)
  MAP_ARGS+=(-map "$SCRIPT_DIR/autoinstall/restore-online-apt.sh" /offline/restore-online-apt.sh)
  MAP_ARGS+=(-map "$SCRIPT_DIR/tools/ubuntu-mirror.sh" /offline/ubuntu-mirror.sh)
  MAP_ARGS+=(-map "$WORK/ubuntu-mirror.url" /offline/ubuntu-mirror.url)
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
