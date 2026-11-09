#!/usr/bin/env bash
# =============================================================================
# qemu-smoke.sh — 在虚拟机里真跑一遍装机, 验证 autoinstall ISO 是否可用
#
# 装机约 8-15 分钟 (取决于机器)。装完自动关机 (shutdown 时的 reboot + -no-reboot),
# 随后用 libguestfs 直接读目标盘里的包清单做断言 —— 这是唯一可信的验收方式。
# =============================================================================
set -Eeuo pipefail

ISO="${1:-}"
shift || true
MODE="bios"
[[ "${1:-}" == "--uefi" ]] && MODE="uefi"

if [[ -z "$ISO" || ! -f "$ISO" ]]; then
  echo "用法: $0 <iso> [--uefi]" >&2
  exit 1
fi

command -v qemu-system-x86_64 >/dev/null || { echo "缺少 qemu: apt install qemu-system-x86"; exit 1; }

WORKDIR="$(mktemp -d -t qemu-smoke-XXXXXX)"
DISK="$WORKDIR/disk.qcow2"
LOG="$WORKDIR/serial.log"

qemu-img create -f qcow2 "$DISK" 30G >/dev/null

QEMU_ARGS=(
  -m 4096 -smp 2 -machine q35
  -drive file="$DISK",if=virtio,format=qcow2
  -cdrom "$ISO"
  -boot order=d,menu=off
  -nographic -serial file:"$LOG" -monitor none
  -no-reboot
)
[[ -x /dev/kvm ]] && QEMU_ARGS+=(-enable-kvm -cpu host)

if [[ "$MODE" == "uefi" ]]; then
  OVMF=""
  for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    [[ -f "$c" ]] && { OVMF="$c"; break; }
  done
  [[ -n "$OVMF" ]] || { echo "找不到 OVMF 固件, 改跑 BIOS: apt install ovmf"; exit 1; }
  cp "$OVMF" "$WORKDIR/OVMF_VARS.fd"
  QEMU_ARGS+=(
    -drive if=pflash,format=raw,readonly=on,file="$OVMF"
    -drive if=pflash,format=raw,file="$WORKDIR/OVMF_VARS.fd"
  )
  echo "==> UEFI 模式 (固件: $OVMF)"
else
  echo "==> BIOS 模式"
fi

echo "==> 串口日志: $LOG"
echo "==> 开始装机, 完成后自动退出..."
timeout 3600 qemu-system-x86_64 "${QEMU_ARGS[@]}" || echo "(qemu 退出码 $?)"

echo
if command -v virt-cat >/dev/null 2>&1; then
  echo "==> 装机清单 /var/log/autoinstall/manifest.txt:"
  virt-cat -a "$DISK" /var/log/autoinstall/manifest.txt 2>/dev/null | sed 's/^/    /' \
    || echo "    (缺失 —— 99-cleanup.sh 没跑到)"

  echo
  echo "==> 预装失败项 /var/log/autoinstall/provision-failed.txt:"
  FAILED="$(virt-cat -a "$DISK" /var/log/autoinstall/provision-failed.txt 2>/dev/null || true)"
  if [ -n "$FAILED" ]; then
    echo "$FAILED" | sed 's/^/    [!] /'
    echo "    ↑ 这些软件没装上, 日志在 /var/log/autoinstall/<脚本>.log"
  else
    echo "    无"
  fi

  echo
  echo "==> 关键可执行文件:"
  BINS="$( { virt-ls -a "$DISK" /usr/bin; virt-ls -a "$DISK" /usr/local/bin; } 2>/dev/null || true)"
  for b in docker grok opencode openmausbot sshd node npm; do
    if echo "$BINS" | grep -qx "$b"; then
      printf '    %-14s ok\n' "$b"
    else
      printf '    %-14s MISSING\n' "$b"
    fi
  done

  echo
  echo "==> Jenkins 与 SSH:"
  virt-ls -a "$DISK" /etc/ssh 2>/dev/null | grep -c 'ssh_host' \
    && echo "    SSH 主机密钥已生成"
  virt-cat -a "$DISK" /etc/hostname 2>/dev/null | sed 's/^/    hostname: /'
else
  echo "==> (未安装 libguestfs-tools, 无法自动断言; apt install libguestfs-tools)"
fi

echo
echo "==> 串口日志尾部:"
tail -n 30 "$LOG" || true
echo
echo "虚拟机与磁盘保留在: $WORKDIR"
