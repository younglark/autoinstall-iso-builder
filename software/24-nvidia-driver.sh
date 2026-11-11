#!/bin/bash
# 24-nvidia-driver.sh — NVIDIA 驱动 (Canonical 预编译签名的 open 内核模块) + Intel VA-API
#
# 不做硬件检测: 每台机器都装 (默认开启; build-iso.sh --no-nvidia-driver / --skip 24 关闭)。
# 没有 N 卡的机器只是多了用户态库和一个不会被加载的模块, 不影响启动。
#
# 安装的包 (全部来自 Ubuntu 官方 restricted / multiverse / universe):
#   nvidia-driver-${PIN_NVIDIA_DRIVER}-open             用户态驱动 (默认 595)
#   linux-modules-nvidia-${V}-open-${FLAVOUR}           预编译模块 meta (Canonical 签名, Secure Boot 可直接加载)
#   linux-${FLAVOUR}                                    同版本内核 meta (模块 meta 精确依赖某个内核 ABI,
#                                                       两个 meta 一起装、版本一致, 不走 DKMS)
#   nvidia-settings nvidia-prime                        仅 Desktop (混合显卡切换 / 设置面板)
#   intel-media-va-driver-non-free vainfo               Intel 核显 VA-API 硬解/硬编 (前者仅 amd64)
# 模块 meta 自带 Provides: nvidia-dkms-${V}-open, 所以 apt 不会装 dkms / 现场编译。
#
# FLAVOUR: 按目标机已装的内核 meta 自动判断 (linux-generic-hwe-24.04 → generic-hwe-24.04,
#          linux-generic → generic, linux-oem-24.04 → oem-24.04 …); NVIDIA_KERNEL_FLAVOUR 覆盖。
#
# 版本不匹配 (仓库/离线捆绑里没有与模块同版本的内核 meta, 或已装内核比模块新, 或没有该 flavour 的
# 预编译模块) 时: 打印 "nvidia-driver: SKIP: …" 并以 0 退出, 不装驱动、不让装机失败。
# Secure Boot: 不登记 MOK, 只提示 (预编译模块已由 Canonical 签名)。
# Wayland: 不改 /etc/gdm3/custom.conf (36-x11vnc-xorg.sh 之后写 WaylandEnable=false);
#          gdm 的 61-gdm.rules 对 NVIDIA 只会写 WaylandEnable false / PreferredDisplayServer,
#          这里再兜底检查: 若有规则会写 WaylandEnable true 且 DISABLE_WAYLAND=1, 用 /etc/udev/rules.d 同名文件屏蔽那一行。
#
# 环境变量: PIN_NVIDIA_DRIVER (默认 595) NVIDIA_KERNEL_FLAVOUR (默认自动) EDITION DISABLE_WAYLAND OFFLINE
# 测试钩子: AIB_TARGET_ROOT=<dir> 文件路径前缀; NVIDIA_ARCH 覆盖架构; apt-get/apt-cache/dpkg* 可用 PATH 替身。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
export DEBIAN_FRONTEND=noninteractive

R="${AIB_TARGET_ROOT:-}"
V="${PIN_NVIDIA_DRIVER:-595}"
EDITION="${EDITION:-server}"
DISABLE_WAYLAND="${DISABLE_WAYLAND:-0}"

log()  { echo "nvidia-driver: $*"; }
skip() { echo "nvidia-driver: SKIP: $*"; exit 0; }

[[ "$V" =~ ^[0-9]{3,4}$ ]] || { echo "ERROR: 非法 PIN_NVIDIA_DRIVER: $V (如 595)"; exit 1; }
DRIVER_PKG="nvidia-driver-${V}-open"

ARCH="${NVIDIA_ARCH:-$(dpkg --print-architecture)}"
case "$ARCH" in
  amd64|arm64) ;;
  *) skip "架构 $ARCH 没有 NVIDIA 预编译模块" ;;
esac

VID=""
if [ -f "$R/etc/os-release" ]; then
  # shellcheck disable=SC1091
  VID="$(. "$R/etc/os-release" && echo "${VERSION_ID:-}")"
fi

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
inst_ver()      { if pkg_installed "$1"; then dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; fi; }
cand_ver()      { apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}' | grep -v '^(none)$' || true; }
has_ver()       { apt-cache madison "$1" 2>/dev/null | awk -F'|' '{gsub(/[[:space:]]/,"",$2); print $2}' | grep -qxF "$2"; }

detect_flavour() {
  local fl
  if [ -n "${NVIDIA_KERNEL_FLAVOUR:-}" ]; then
    echo "$NVIDIA_KERNEL_FLAVOUR"; return
  fi
  for fl in ${VID:+generic-hwe-$VID oem-$VID lowlatency-hwe-$VID} generic lowlatency; do
    if pkg_installed "linux-$fl" || pkg_installed "linux-image-$fl"; then
      echo "$fl"; return
    fi
  done
  # 没找到任何内核 meta: Desktop 默认 HWE, Server 默认 GA
  if [ "$EDITION" = "desktop" ] && [ -n "$VID" ]; then echo "generic-hwe-$VID"; else echo generic; fi
}

FL="$(detect_flavour)"
[[ "$FL" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "ERROR: 非法 NVIDIA_KERNEL_FLAVOUR: $FL"; exit 1; }
MOD_META="linux-modules-nvidia-${V}-open-${FL}"
KMETA="linux-${FL}"
log "driver=$DRIVER_PKG kernel-flavour=$FL arch=$ARCH edition=$EDITION offline=${OFFLINE:-0}"

if offline_enabled 2>/dev/null; then
  offline_apt_ready 2>/dev/null || skip "离线模式但没有本地 apt 池"
  log "offline: 只用本地捆绑 apt 池"
else
  apt-get update || log "warn: apt-get update 失败, 用现有索引继续"
fi

# ---------- 版本一致性: 模块 meta ↔ 内核 meta ↔ 内核 ABI ----------
MODVER="$(cand_ver "$MOD_META")"
[ -n "$MODVER" ] || skip "仓库里没有 $MOD_META (内核 flavour $FL 没有预编译 NVIDIA $V 模块); 不装驱动。可设 NVIDIA_KERNEL_FLAVOUR 或 --no-nvidia-driver"
ABI="$(apt-cache show "$MOD_META=$MODVER" 2>/dev/null \
  | sed -n 's/^Depends: //p' | head -1 | tr ',' '\n' \
  | sed -n "s/^[[:space:]]*linux-modules-nvidia-${V}-open-\([0-9][^ (]*\).*/\1/p" | head -1 || true)"
[ -n "$ABI" ] || skip "无法从 $MOD_META $MODVER 的依赖里读出内核 ABI"
KVER="$(cand_ver "$KMETA")"
KPKGS=("$KMETA")
if [ "$KVER" != "$MODVER" ]; then
  if has_ver "$KMETA" "$MODVER" && has_ver "linux-image-$FL" "$MODVER" && has_ver "linux-headers-$FL" "$MODVER"; then
    log "内核 meta 候选 ${KVER:-无} 与模块 $MODVER 不一致: 锁定 $KMETA=$MODVER"
    KPKGS=("$KMETA=$MODVER" "linux-image-$FL=$MODVER" "linux-headers-$FL=$MODVER")
  else
    skip "内核与 NVIDIA 模块版本不匹配: $KMETA 候选=${KVER:-无}, $MOD_META=$MODVER (内核 $ABI), 仓库里没有同版本内核 meta; 不装驱动, 不影响装机。仓库同步后重跑本脚本或重新抓离线捆绑"
  fi
fi
INSTK="$(inst_ver "$KMETA")"
if [ -n "$INSTK" ] && dpkg --compare-versions "$INSTK" gt "$MODVER"; then
  skip "已装 $KMETA $INSTK 比预编译模块 $MOD_META $MODVER 新 (会降级内核); 不装驱动"
fi
if [ -z "$(cand_ver "linux-image-$ABI")" ] && [ -z "$(cand_ver "linux-image-unsigned-$ABI")" ]; then
  skip "模块 $MOD_META $MODVER 需要内核 linux-image-$ABI, 但仓库里没有; 不装驱动"
fi
[ -n "$(cand_ver "$DRIVER_PKG")" ] || skip "仓库里没有 $DRIVER_PKG; 不装驱动"
log "kernel: $KMETA ${KVER:-?} → $ABI; module: $MOD_META $MODVER (版本一致)"

PKGS=("${KPKGS[@]}" "$MOD_META" "$DRIVER_PKG")
if [ "$EDITION" = "desktop" ]; then
  for p in nvidia-settings nvidia-prime; do
    if [ -n "$(cand_ver "$p")" ]; then PKGS+=("$p"); fi
  done
fi

# 先模拟: 解析失败或会拉 DKMS 就跳过 (不现场编译、不碰 MOK)
SIM="$(apt-get install -s --no-install-recommends "${PKGS[@]}" 2>&1)" \
  || { printf '%s\n' "$SIM" | tail -n 15; skip "apt 无法解析 ${PKGS[*]} (见上)"; }
if printf '%s\n' "$SIM" | grep -Eq '^Inst (dkms|nvidia-dkms-)'; then
  skip "apt 计划安装 DKMS (预编译模块没能满足 nvidia-dkms-${V}-open); 不装驱动"
fi

GDM_CONF="$R/etc/gdm3/custom.conf"
gdm_before="$(sha256sum "$GDM_CONF" 2>/dev/null | cut -d' ' -f1 || true)"

apt-get install -y --no-install-recommends "${PKGS[@]}"

if pkg_installed dkms; then
  log "warn: dkms 已安装 (不是本脚本引入的?); 预编译模块仍优先"
fi
_ko="$(find "$R/lib/modules/$ABI" "$R/usr/lib/modules/$ABI" -name 'nvidia.ko*' 2>/dev/null | head -1 || true)"
if [ -n "$_ko" ]; then
  log "预编译模块: ${_ko#"$R"}"
else
  log "warn: /lib/modules/$ABI 下没找到 nvidia.ko (开机后 'modinfo nvidia' 确认)"
fi

# ---------- Intel VA-API (可选, 失败不致命) ----------
VA=()
if [ "$ARCH" = "amd64" ]; then VA+=(intel-media-va-driver-non-free); fi
VA+=(vainfo)
VA_OK=()
for p in "${VA[@]}"; do
  if [ -n "$(cand_ver "$p")" ]; then VA_OK+=("$p"); else log "warn: 仓库里没有 $p (multiverse/universe 未启用?), 跳过"; fi
done
if [ "${#VA_OK[@]}" -gt 0 ]; then
  apt-get install -y --no-install-recommends "${VA_OK[@]}" || log "warn: VA-API 包安装失败: ${VA_OK[*]}"
fi

# ---------- Secure Boot: 只提示 ----------
SB=""
if command -v mokutil >/dev/null 2>&1; then
  SB="$(mokutil --sb-state 2>/dev/null | head -1 || true)"
fi
if [ -z "$SB" ]; then
  _ev="$(find "$R/sys/firmware/efi/efivars" -maxdepth 1 -name 'SecureBoot-*' 2>/dev/null | head -1 || true)"
  if [ -n "$_ev" ] && [ "$(od -An -tu1 -j4 -N1 "$_ev" 2>/dev/null | tr -d ' ')" = "1" ]; then SB="SecureBoot enabled"; fi
fi
case "$SB" in
  *enabled*) log "Secure Boot 已开启: 预编译模块由 Canonical 签名, 可直接加载; 不登记 MOK" ;;
  *) log "Secure Boot: ${SB:-未知/未开启}; 预编译模块由 Canonical 签名, 开不开都能加载 (不登记 MOK)" ;;
esac

# ---------- Wayland 兜底: 不让 NVIDIA / gdm udev 规则打开 Wayland ----------
if [ "$DISABLE_WAYLAND" = "1" ]; then
  for f in "$R/usr/lib/udev/rules.d/61-gdm.rules" "$R/lib/udev/rules.d/61-gdm.rules"; do
    [ -f "$f" ] || continue
    if grep -Eq 'WaylandEnable[[:space:]]+true' "$f"; then
      mkdir -p "$R/etc/udev/rules.d"
      grep -Ev 'WaylandEnable[[:space:]]+true' "$f" > "$R/etc/udev/rules.d/61-gdm.rules"
      log "屏蔽 ${f#"$R"} 里会打开 Wayland 的规则 → /etc/udev/rules.d/61-gdm.rules"
    fi
    break
  done
  gdm_after="$(sha256sum "$GDM_CONF" 2>/dev/null | cut -d' ' -f1 || true)"
  if [ "$gdm_before" != "$gdm_after" ] && grep -Eq '^[[:space:]]*WaylandEnable[[:space:]]*=[[:space:]]*true' "$GDM_CONF" 2>/dev/null; then
    sed -i -E 's/^[[:space:]]*WaylandEnable[[:space:]]*=[[:space:]]*true/WaylandEnable=false/' "$GDM_CONF"
    log "安装过程把 custom.conf 改成了 WaylandEnable=true, 已改回 false"
  fi
fi

log "ok: $DRIVER_PKG + $MOD_META $MODVER (内核 $ABI; 重启后生效, 'nvidia-smi' 验证)"
