#!/usr/bin/env python3
"""渲染 Windows 11 无人值守答案文件 (autounattend.xml) 的 safe / autodisk 两个变体。

  safe     : DiskConfiguration/WillShowUI=Always, 不写 Disk, 不抹盘, 不写 InstallTo
             -> Setup 停在「你想将 Windows 安装在哪里」由人确认 (对应 Ubuntu 侧默认停在选盘)
  autodisk : Disk/WillWipeDisk=true, 抹掉 --disk-id 指定的盘并建 ESP + MSR + Windows 三分区
             --disk-id 默认 ventoy-nonvtoy -> $$VT_WINDOWS_DISK_1ST_NONVTOY$$ (Ventoy 启动时展开)

密码: 优先环境变量 AIB_WIN_PASSWORD, 其次 --password-file, 再次 --password (会进 shell 历史),
都没给时用仓库默认 ubuntu1990 (stderr 告警)。密码绝不写到 stdout / stderr。
默认 PlainText=false: Value = base64(UTF-16LE(密码 + "Password")), 与 Windows SIM 一致;
这只是混淆, 不是加密 (Learn LocalAccount 示例 cAB3AFAAYQBzAHMAdwBvAHIAZAA 即 "pw" 的这种编码)。
"""
from __future__ import annotations

import argparse
import base64
import os
import re
import sys
from pathlib import Path

DEFAULT_PASSWORD = "ubuntu1990"

# Learn: Default input profiles (input locales) for Windows language packs
INPUT_LOCALES = {
    "zh-CN": "0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}{FA550B04-5AD7-411F-A5AC-CA038EC515D7}",
    "en-US": "0409:00000409",
}

DISK_IDS = {
    "ventoy-nonvtoy": "$$VT_WINDOWS_DISK_1ST_NONVTOY$$",
    "ventoy-nonusb": "$$VT_WINDOWS_DISK_1ST_NONUSB$$",
}

# specialize / RunSynchronousCommand/Path (Learn: 最长 259 字符)。
# 在 D:..Z: 里找 \aib-win\aib-win.marker, 把整个 aib-win 复制到 C:\aib。
PAYLOAD_COPY_CMD = (
    'cmd.exe /c "for %i in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do '
    '@if exist %i:\\aib-win\\aib-win.marker '
    'xcopy %i:\\aib-win C:\\aib\\ /e /i /h /y /q >> C:\\Windows\\Temp\\aib-payload-copy.log 2>&1"'
)

# Learn ComputerName: <=15 字节, 不能含下列字符/空格, 不能全是数字
_BAD_HOST = set(" {|}~[\\]^':;<=>?@!\"#$%`()+/.,*&")

VARIANTS = ("safe", "autodisk")


def xml_escape(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;").replace("'", "&apos;"))


def encode_password(password: str, suffix: str = "Password") -> str:
    return base64.b64encode((password + suffix).encode("utf-16-le")).decode("ascii")


def validate_hostname(h: str) -> None:
    if not h or len(h.encode("utf-8")) > 15:
        raise SystemExit(f"--hostname 必须 1-15 字节 (Learn ComputerName): {h!r}")
    if any(c in _BAD_HOST for c in h) or h.isdigit():
        raise SystemExit(f"--hostname 含非法字符或全是数字 (Learn ComputerName): {h!r}")


def validate_username(u: str) -> None:
    # 本地账户名: 不超过 20 字符, 不含 " / \ [ ] : ; | = , + * ? < > @ 以及空格开头结尾
    if not u or len(u) > 20 or re.search(r'["/\\\[\]:;|=,+*?<>@]', u) or u != u.strip() or u.endswith("."):
        raise SystemExit(f"--username 不是合法的本地账户名: {u!r}")
    if u.lower() in {"administrator", "guest", "defaultaccount", "wdagutilityaccount", "system"}:
        raise SystemExit(f"--username 不能用内置账户名: {u!r}")


def disk_block(variant: str, disk_id: str) -> tuple[str, str]:
    if variant == "safe":
        disk = (
            "<DiskConfiguration>\n"
            "        <WillShowUI>Always</WillShowUI>\n"
            "      </DiskConfiguration>"
        )
        return disk, "<!-- safe: 不写 InstallTo, Setup 显示安装位置页由人选择 -->"
    did = xml_escape(disk_id)
    disk = f"""<DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>{did}</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>300</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>16</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>FAT32</Format>
              <Label>System</Label>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>3</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
              <Letter>C</Letter>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
        <WillShowUI>OnError</WillShowUI>
      </DiskConfiguration>"""
    install_to = f"""<InstallTo>
            <DiskID>{did}</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>"""
    return disk, install_to


def render(template: str, variant: str, *, hostname: str, username: str, password: str,
           locale: str, ui_language: str, input_locale: str, timezone: str, edition: str,
           disk_id: str, plaintext: bool) -> str:
    disk, install_to = disk_block(variant, disk_id)
    if plaintext:
        acct = auto = xml_escape(password)
    else:
        # LocalAccount 与 AutoLogon 的 SIM 隐藏编码都以 "Password" 作后缀
        acct = auto = encode_password(password)
    repl = {
        "@@UI_LANGUAGE@@": xml_escape(ui_language),
        "@@LOCALE@@": xml_escape(locale),
        "@@INPUT_LOCALE@@": xml_escape(input_locale),
        "@@EDITION@@": xml_escape(edition),
        "@@HOSTNAME@@": xml_escape(hostname),
        "@@TIMEZONE@@": xml_escape(timezone),
        "@@USERNAME@@": xml_escape(username),
        "@@PAYLOAD_COPY_CMD@@": xml_escape(PAYLOAD_COPY_CMD),
        "@@PASSWORD_PLAINTEXT@@": "true" if plaintext else "false",
        "@@ACCOUNT_PASSWORD_VALUE@@": acct,
        "@@AUTOLOGON_PASSWORD_VALUE@@": auto,
    }
    out = template.replace("<!--@@DISK_CONFIGURATION@@-->", disk)
    out = out.replace("<!--@@INSTALL_TO@@-->", install_to)
    for k, v in repl.items():
        out = out.replace(k, v)
    left = re.findall(r"@@[A-Z_]+@@", out)
    if left:
        raise SystemExit(f"模板占位符未替换: {sorted(set(left))}")
    # Ventoy: 含变量的模板必须 UTF-8, 每行最多一个变量
    for n, line in enumerate(out.splitlines(), 1):
        if len(re.findall(r"\$\$[A-Za-z0-9_]+\$\$", line)) > 1:
            raise SystemExit(f"第 {n} 行含多个 Ventoy 变量 (Ventoy 每行只展开一个)")
    return out


def read_password(args: argparse.Namespace) -> tuple[str, str]:
    env = os.environ.get("AIB_WIN_PASSWORD")
    if env:
        return env, "env AIB_WIN_PASSWORD"
    if args.password_file:
        pw = Path(args.password_file).read_text(encoding="utf-8").rstrip("\r\n")
        if not pw:
            raise SystemExit("--password-file 为空")
        return pw, "--password-file"
    if args.password:
        return args.password, "--password"
    return DEFAULT_PASSWORD, "default"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--template", default=str(Path(__file__).resolve().parent.parent / "windows" / "autounattend.xml.tmpl"))
    ap.add_argument("--out-dir", required=True, help="输出目录, 写 aib-win-<variant>.xml")
    ap.add_argument("--variant", choices=VARIANTS + ("both",), default="both")
    ap.add_argument("--prefix", default="aib-win", help="输出文件名前缀 (默认 aib-win -> aib-win-safe.xml)")
    ap.add_argument("--hostname", default="WIN-AIB")
    ap.add_argument("--username", default="ubuntu")
    ap.add_argument("--password", help="明文 (会进 shell 历史; 优先用环境变量 AIB_WIN_PASSWORD 或 --password-file)")
    ap.add_argument("--password-file")
    ap.add_argument("--plaintext-password", action="store_true", help="PlainText=true (默认 false: SIM 同款混淆)")
    ap.add_argument("--locale", default="zh-CN", help="SystemLocale / UserLocale (默认 zh-CN)")
    ap.add_argument("--ui-language", help="UILanguage, 必须与 ISO 语言一致 (默认 = --locale)")
    ap.add_argument("--input-locale", help=f"InputLocale (默认按 locale 取: {', '.join(INPUT_LOCALES)})")
    ap.add_argument("--timezone", default="China Standard Time")
    ap.add_argument("--edition", default="Windows 11 Pro", help="install.wim 的 /IMAGE/NAME (用 wimlib-imagex info 查)")
    ap.add_argument("--disk-id", default="ventoy-nonvtoy",
                    help="autodisk 目标盘: ventoy-nonvtoy (默认) / ventoy-nonusb / 整数磁盘号 (非 Ventoy, 如 QEMU)")
    args = ap.parse_args(argv)

    validate_hostname(args.hostname)
    validate_username(args.username)
    ui_language = args.ui_language or args.locale
    input_locale = args.input_locale or INPUT_LOCALES.get(args.locale)
    if not input_locale:
        raise SystemExit(f"--locale {args.locale} 没有内置 InputLocale, 请显式给 --input-locale")
    if args.disk_id in DISK_IDS:
        disk_id = DISK_IDS[args.disk_id]
    elif args.disk_id.isdigit():
        disk_id = args.disk_id
    else:
        raise SystemExit(f"--disk-id 只能是 {'/'.join(DISK_IDS)} 或整数: {args.disk_id!r}")
    if not args.edition.strip():
        raise SystemExit("--edition 不能为空")

    password, src = read_password(args)
    if src == "default":
        print(f"[warn] 未提供密码, 使用仓库公开默认密码 (用户 {args.username}); 装完请立即修改", file=sys.stderr)

    template = Path(args.template).read_text(encoding="utf-8")
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    variants = VARIANTS if args.variant == "both" else (args.variant,)
    for v in variants:
        xml = render(template, v, hostname=args.hostname, username=args.username, password=password,
                     locale=args.locale, ui_language=ui_language, input_locale=input_locale,
                     timezone=args.timezone, edition=args.edition, disk_id=disk_id,
                     plaintext=args.plaintext_password)
        p = out_dir / f"{args.prefix}-{v}.xml"
        # UTF-8 无 BOM, LF
        p.write_bytes(xml.encode("utf-8"))
        try:
            os.chmod(p, 0o600)
        except OSError:
            pass
        print(f"[ok] {p} (variant={v}, edition={args.edition!r}, user={args.username}, password from {src})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
