#!/usr/bin/env bash
# =============================================================================
# make-fake-iso.sh — 用 test/fixtures 拼一张「看起来像」Ubuntu Live 的小 ISO (几百 KB)
#
# 只含 build-iso.sh 需要读的文件: /boot/grub/grub.cfg (+loopback.cfg)、
# /casper/install-sources.yaml、/.disk/info。没有内核/引导记录, 不能启动,
# 只用于 CI 端到端跑通 build-iso.sh (渲染 → 注入 → xorriso 重打包 → 校验)。
#
#   test/make-fake-iso.sh [server|desktop] OUT.iso
# =============================================================================
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EDITION="${1:-server}"
OUT="${2:-fake-${EDITION}.iso}"
command -v xorriso >/dev/null || { echo "缺少 xorriso" >&2; exit 1; }

tmp="$(mktemp -d -t fake-iso-XXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/root/boot/grub" "$tmp/root/casper" "$tmp/root/.disk"
case "$EDITION" in
  server)
    cp "$ROOT/test/fixtures/grub.cfg" "$tmp/root/boot/grub/grub.cfg"
    cp "$ROOT/test/fixtures/server-2404/install-sources.yaml" "$tmp/root/casper/"
    cp "$ROOT/test/fixtures/server-2404/disk-info" "$tmp/root/.disk/info"
    ;;
  desktop)
    cp "$ROOT/test/fixtures/desktop-2404/grub.cfg" "$tmp/root/boot/grub/grub.cfg"
    cp "$ROOT/test/fixtures/desktop-2404/loopback.cfg" "$tmp/root/boot/grub/loopback.cfg"
    cp "$ROOT/test/fixtures/desktop-2404/install-sources.yaml" "$tmp/root/casper/"
    cp "$ROOT/test/fixtures/desktop-2404/disk-info" "$tmp/root/.disk/info"
    ;;
  *) echo "edition 必须是 server|desktop" >&2; exit 1 ;;
esac
mkdir -p "$(dirname -- "$OUT")"
xorriso -as mkisofs -r -J -V "FAKE_UBUNTU" -o "$OUT" "$tmp/root" >/dev/null 2>&1
echo "fake $EDITION ISO: $OUT ($(du -h "$OUT" | cut -f1))"
