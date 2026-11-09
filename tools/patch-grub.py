#!/usr/bin/env python3
"""
patch-grub.py — 向 Ubuntu Live ISO 的 grub 菜单注入 autoinstall 内核参数。

设计要点:
  * 只改 menuentry 内部的 `linux` / `linuxefi` 行, 不触碰任何引导二进制。
  * 幂等: 已经含 autoinstall 的行不会重复追加。
  * 同时兼容 BIOS 用的 /boot/grub/grub.cfg 和
    Ventoy / 多启动 U 盘用的 /boot/grub/loopback.cfg。

用法:
  patch-grub.py --file grub.cfg --menu-regex 'Try or Install' \
                --params 'autoinstall ds=nocloud;s=/cdrom/nocloud/' \
                --timeout 3
"""

import argparse
import re
import sys

LINUX_RE = re.compile(r"^\s*(linux|linuxefi)\s")
MENU_RE = re.compile(r"^\s*menuentry\s+(['\"])(.*?)\1")
SET_DEFAULT_RE = re.compile(r"^\s*set\s+default=")
SET_TIMEOUT_RE = re.compile(r"^\s*set\s+timeout=")

# kernel 命令行里 `---` 之后的内容不传给内核, 所以参数要插在 `---` 之前
SEP = "---"


def patch(text: str, menu_regex: str, params: str, timeout: int, dry_run: bool):
    out_lines = []
    in_target = False
    depth = 0
    patched = 0
    already = 0
    seen_menus = []

    for raw in text.splitlines(True):
        line = raw.rstrip("\n")
        stripped = line.strip()

        m = MENU_RE.match(line)
        if m:
            title = m.group(2)
            seen_menus.append(title)
            in_target = re.search(menu_regex, title) is not None
            depth = 1
            out_lines.append(line + "\n")
            continue

        # 进入 submenu 时退出 target 状态, 避免误伤嵌套条目
        if stripped.startswith("submenu ") or stripped.startswith("menuentry "):
            in_target = False

        if in_target and LINUX_RE.match(line):
            if "autoinstall" in line:
                already += 1
                out_lines.append(line + "\n")
                continue
            if SEP in line:
                head, _, tail = line.partition(SEP)
                new = f"{head.rstrip()} {params} {SEP}{tail}"
            else:
                new = f"{line.rstrip()} {params}"
            out_lines.append(new + "\n")
            patched += 1
            continue

        if SET_TIMEOUT_RE.match(line):
            out_lines.append(f"set timeout={timeout}\n")
            continue

        out_lines.append(line + "\n")

    new_text = "".join(out_lines)
    return new_text, patched, already, seen_menus


def main() -> int:
    ap = argparse.ArgumentParser(description="向 Live ISO 的 grub 菜单注入 autoinstall 参数")
    ap.add_argument("--file", required=True)
    ap.add_argument("--menu-regex", default=r"Try or Install",
                    help="要注入的 menuentry 标题正则 (默认匹配 Server/Desktop 的 Try or Install)")
    ap.add_argument("--params", default="autoinstall ds=nocloud;s=/cdrom/nocloud/")
    ap.add_argument("--timeout", type=int, default=3)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    with open(args.file, "r", encoding="utf-8", errors="surrogateescape") as f:
        original = f.read()

    new_text, patched, already, menus = patch(
        original, args.menu_regex, args.params, args.timeout, args.dry_run
    )

    # 已注入过: 视为成功, 保证脚本可重复执行
    if patched == 0 and already > 0:
        print(f"[ok] already patched ({already} line(s)), nothing to do: {args.file}")
        return 0

    # 一条都没命中说明 ISO 结构变了, 必须报错而不是静默产出坏镜像
    if patched == 0:
        sys.stderr.write(f"[FAIL] 没有匹配到任何 linux 行 (menu={args.menu_regex})\n")
        sys.stderr.write("       实际条目:\n")
        for t in menus:
            sys.stderr.write(f"         - {t}\n")
        return 2

    if args.dry_run:
        sys.stdout.write(new_text)
        return 0

    with open(args.file, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(new_text)

    print(f"[ok] patched {patched} kernel line(s) in {args.file}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
