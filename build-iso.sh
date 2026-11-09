#!/usr/bin/env bash
# =============================================================================
# build-iso.sh — 把 subiquity autoinstall 烧进 Ubuntu Live ISO
#
# 原理: 不重建 ISO, 也不解包 squashfs。
#   * 在 ISO 根目录新增 /nocloud/{user-data,meta-data} 种子
#   * 给 grub 菜单注入 "autoinstall ds=nocloud;s=/cdrom/nocloud/"
#   * 用 xorriso 复制模式 + `-boot_image any replay` 原样复用引导记录
#
# 因此: 不需要 root, 不需要 loop 挂载, BIOS/UEFI 双启动与 Secure Boot 全部保留。
#
# 依赖: xorriso (>=1.5), python3 (+PyYAML 可选), openssl (仅明文密码时需要)
# 环境: Linux / WSL2。Windows 原生不支持。
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SRC_ISO=""
OUT_ISO=""
HOSTNAME_="ubuntu-node"
USERNAME_="ops"
PASS_HASH=""
PASS_PLAIN=""
LOCALE_="en_US.UTF-8"
KEYBOARD_="us"
TIMEZONE_="Asia/Shanghai"
MIRROR="http://archive.ubuntu.com/ubuntu"
PACKAGES=""
SSH_ALLOW_PW="true"
STORAGE_LAYOUT="direct"
OFFLINE=0
DEBS_DIR=""
MENU_REGEX="Try or Install"
DRY_RUN=0
KEEP_WORK=0
PROVISION=1
STRICT=0
PROVISION_SKIP=""

usage() {
  cat <<'EOF'
用法:
  ./build-iso.sh --iso <原版ISO> --out <输出ISO> [选项]

必填:
  --iso PATH            官方 Ubuntu Server ISO (22.04 / 24.04)
  --out PATH            输出 ISO 路径

身份 (二选一, 必填):
  --password-hash HASH  crypt 哈希, 推荐
  --password PLAIN      明文, 脚本用 openssl passwd -6 现场哈希 (会留在 shell 历史里)

可选:
  --hostname NAME       默认 ubuntu-node
  --username NAME       默认 ops
  --packages "a,b,c"    预装软件包, 逗号分隔
  --mirror URL          默认 archive.ubuntu.com; 内网请填本地源
  --locale / --keyboard / --timezone
  --ssh-allow-pw BOOL   默认 true (未配公钥时必须为 true, 否则装完登不进去)
  --storage-layout L    direct | lvm | zfs, 默认 direct
  --offline             不联网场景: updates=none, apt 允许 offline-install
  --debs DIR            把目录下所有 .deb 打进 ISO 的 /pool 并离线安装
  --no-provision        不执行 software/ 下的软件预装脚本
  --strict              任一软件装失败就中止安装 (默认: 记日志继续)
  --skip "30 70"        跳过指定编号的软件脚本, 用空格分隔前缀
  --menu-regex REGEX    要注入的菜单项标题正则, 默认 "Try or Install"
  --dry-run             只渲染配置并打印, 不产出 ISO
  --keep-work           保留临时目录便于排查

示例:
  ./build-iso.sh --iso ubuntu-24.04.1-live-server-amd64.iso \
                 --out out/ubuntu-24.04.1-autoinstall.iso \
                 --hostname node01 --username ops \
                 --password-hash "$(openssl passwd -6 'Ch@ngeMe')" \
                 --packages "vim,curl,htop,net-tools" \
                 --mirror http://mirrors.aliyun.com/ubuntu
EOF
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

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
    --storage-layout) STORAGE_LAYOUT="$2"; shift 2 ;;
    --offline)        OFFLINE=1; shift ;;
    --debs)           DEBS_DIR="$2"; shift 2 ;;
    --menu-regex)     MENU_REGEX="$2"; shift 2 ;;
    --no-provision)   PROVISION=0; shift ;;
    --strict)         STRICT=1; shift ;;
    --skip)           PROVISION_SKIP="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --keep-work)      KEEP_WORK=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) die "未知参数: $1 (用 --help 查看)" ;;
  esac
done

[[ -n "$SRC_ISO" ]] || { usage; die "缺少 --iso"; }
[[ -n "$OUT_ISO" ]] || { usage; die "缺少 --out"; }
[[ -f "$SRC_ISO" ]] || die "源 ISO 不存在: $SRC_ISO"

if [[ -z "$PASS_HASH" && -z "$PASS_PLAIN" ]]; then
  die "必须提供 --password-hash 或 --password (openssl passwd -6 '你的密码')"
fi
if [[ -z "$PASS_HASH" ]]; then
  command -v openssl >/dev/null || die "缺少 openssl, 无法哈希密码"
  PASS_HASH="$(openssl passwd -6 "$PASS_PLAIN")"
fi
[[ "$PASS_HASH" == \$* ]] || die "--password-hash 不像 crypt 哈希 (应以 \$ 开头)"

for bin in xorriso python3; do
  command -v "$bin" >/dev/null || die "缺少依赖: $bin   (apt install xorriso python3)"
done

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
[[ "$OFFLINE" -eq 1 ]] && RENDER_ARGS+=(--offline)
[[ "$WITH_POOL" -eq 1 ]] && RENDER_ARGS+=(--with-pool)
[[ "$PROVISION" -eq 1 ]] && RENDER_ARGS+=(--provision)

python3 "$SCRIPT_DIR/tools/render-user-data.py" "${RENDER_ARGS[@]}"
cp "$SCRIPT_DIR/autoinstall/meta-data" "$WORK/nocloud/meta-data"

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
  cat > "$WORK/provision/provision.env" <<EOF
# 由 build-iso.sh 生成
TARGET_USER=$USERNAME_
STRICT=$STRICT
PROVISION_SKIP="$PROVISION_SKIP"
EOF
  SCRIPT_COUNT=$(find "$WORK/provision" -maxdepth 1 -name '[0-9][0-9]-*.sh' | wc -l)
  ok "已打包 $SCRIPT_COUNT 个软件预装脚本"
  [[ -n "$PROVISION_SKIP" ]] && warn "跳过: $PROVISION_SKIP"
fi

# ------------------------------------------------------- 2. 取出并修补 grub
log "提取 grub 菜单"
xorriso -osirrox on -indev "$SRC_ISO" \
        -extract /boot/grub/grub.cfg "$WORK/grub.cfg" 2>/dev/null \
  || die "源 ISO 里没有 /boot/grub/grub.cfg, 这不像 Ubuntu Live ISO"

HAS_LOOPBACK=0
if xorriso -osirrox on -indev "$SRC_ISO" \
          -extract /boot/grub/loopback.cfg "$WORK/loopback.cfg" 2>/dev/null; then
  HAS_LOOPBACK=1
fi

patch_menu() {
  local f="$1"
  python3 "$SCRIPT_DIR/tools/patch-grub.py" \
    --file "$f" \
    --menu-regex "$MENU_REGEX" \
    --params "autoinstall ds=nocloud;s=/cdrom/nocloud/" \
    --timeout 3
}

log "注入 autoinstall 内核参数"
patch_menu "$WORK/grub.cfg" || die "grub.cfg 注入失败, 用 --menu-regex 指定正确的菜单标题"
[[ "$HAS_LOOPBACK" -eq 1 ]] && patch_menu "$WORK/loopback.cfg" || true

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run: 以下是渲染后的 user-data"
  echo "-------------------------------------------------------------"
  cat "$WORK/nocloud/user-data"
  echo "-------------------------------------------------------------"
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
[[ "$WITH_POOL" -eq 1 ]]    && MAP_ARGS+=(-map "$WORK/pool"            /pool)
[[ "$PROVISION" -eq 1 ]]    && MAP_ARGS+=(-map "$WORK/provision"       /provision)

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
if [[ "$PROVISION" -eq 1 ]]; then
  xorriso -indev "$OUT_ISO" -ls /provision 2>/dev/null | grep -q 'run-all.sh' \
    || die "/provision/run-all.sh 未写入"
  xorriso -osirrox on -indev "$OUT_ISO" -extract /nocloud/user-data "$WORK/v-user-data" 2>/dev/null
  grep -q 'run-all.sh' "$WORK/v-user-data" \
    || die "user-data 里没有调用 run-all.sh"
fi
ok "/nocloud 与 grub 参数均已就位"

SIZE_BYTES=$(stat -c %s "$OUT_ISO" 2>/dev/null || stat -f %z "$OUT_ISO")
if [[ "$SIZE_BYTES" -gt 4700000000 ]]; then
  warn "输出 ISO 超过 4.7GB, 单层 DVD 写不下, 只能走 U 盘"
fi

sha256sum "$OUT_ISO" | tee "$OUT_ISO.sha256"
ok "完成: $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
cat <<EOF

下一步:
  1) 写盘:  sudo dd if="$OUT_ISO" of=/dev/sdX bs=4M status=progress oflag=sync
  2) 或先在虚拟机验证:  bash $SCRIPT_DIR/test/qemu-smoke.sh "$OUT_ISO"

注意:
  * ISO 内的 md5sum.txt 未更新 —— casper 只在传 integrity-check 时才校验, 默认无影响。
  * 装完会 reboot。U 盘启动务必调整 BIOS 顺序, 否则会再装一遍。
EOF
