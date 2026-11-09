#!/usr/bin/env python3
"""
render-user-data.py — 把 user-data.tmpl 渲染成 subiquity 可直接消费的 user-data。

关键约束:
  * 占位符用 @@KEY@@ 而不是 ${KEY}, 因为 crypt 密码哈希里全是 $6$...$。
  * 渲染后必须能被 yaml.safe_load 解析, 否则 subiquity 会在装机最后一步失败。
"""

import argparse
import os
import re
import sys

try:
    import yaml
except ImportError:  # 没有 PyYAML 时降级为只做文本校验
    yaml = None

PLACEHOLDER_RE = re.compile(r"@@([A-Z0-9_]+)@@")


def yaml_list_block(items, indent="    "):
    if not items:
        return f"{indent}[]"
    return "\n".join(f"{indent}- {i}" for i in items)


def build_late_commands(offline: bool, with_pool: bool, provision: bool):
    cmds = []
    if provision:
        # software/ 目录被打进 ISO 的 /provision, 在目标 chroot 里逐个执行
        cmds += [
            "mkdir -p /target/opt/provision && cp -a /cdrom/provision/. /target/opt/provision/",
            "curtin in-target --target=/target -- bash /opt/provision/run-all.sh",
        ]
    cmds += [
        "curtin in-target --target=/target -- timedatectl set-ntp true",
        "curtin in-target --target=/target -- systemctl enable --now ssh || true",
    ]
    if with_pool:
        cmds += [
            "mkdir -p /target/opt/offline-debs",
            "cp -a /cdrom/pool/. /target/opt/offline-debs/ || true",
            # 本地 deb 的依赖顺序不保证正确, 多轮 dpkg -i + configure 兜底
            "curtin in-target --target=/target -- sh -c "
            "'cd /opt/offline-debs && for i in 1 2 3; do dpkg -i ./*.deb && break; done; "
            "dpkg --configure -a || true'",
        ]
    # 落一份包清单, 装机后可直接比对
    cmds.append(
        "curtin in-target --target=/target -- sh -c "
        "'mkdir -p /var/log/autoinstall && dpkg -l > /var/log/autoinstall/packages.txt'"
    )
    return "\n".join(f"    - {c}" for c in cmds)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--hostname", default="ubuntu-node")
    ap.add_argument("--username", default="ops")
    ap.add_argument("--password-hash", required=True)
    ap.add_argument("--locale", default="en_US.UTF-8")
    ap.add_argument("--keyboard", default="us")
    ap.add_argument("--timezone", default="Asia/Shanghai")
    ap.add_argument("--mirror", default="http://archive.ubuntu.com/ubuntu")
    ap.add_argument("--packages", default="", help="逗号分隔")
    ap.add_argument("--ssh-allow-pw", default="true")
    ap.add_argument("--storage-layout", default="direct", choices=["direct", "lvm", "zfs"])
    ap.add_argument("--offline", action="store_true", help="不依赖外网, 允许 apt 降级为离线")
    ap.add_argument("--with-pool", action="store_true", help="ISO 内含 /pool 本地 deb")
    ap.add_argument("--provision", action="store_true", help="ISO 内含 /provision 软件脚本")
    args = ap.parse_args()

    pw = args.password_hash.strip()
    if not pw.startswith("$"):
        sys.stderr.write(
            "[FAIL] --password-hash 必须是 crypt 哈希, 例如:\n"
            "       openssl passwd -6 'YourPassword'\n"
            "       或 mkpasswd -m sha-512\n"
        )
        return 2

    packages = [p.strip() for p in args.packages.split(",") if p.strip()]

    if args.offline:
        updates = "none"
        fallback = "offline-install"
    else:
        updates = "security"
        fallback = "offline-install"

    values = {
        "HOSTNAME": args.hostname,
        "USERNAME": args.username,
        "PASSWORD_HASH": pw,
        "LOCALE": args.locale,
        "KEYBOARD": args.keyboard,
        "TIMEZONE": args.timezone,
        "APT_MIRROR": args.mirror,
        "APT_FALLBACK": fallback,
        "UPDATES": updates,
        "SSH_ALLOW_PW": args.ssh_allow_pw,
        "STORAGE_LAYOUT": args.storage_layout,
        "PACKAGES_BLOCK": yaml_list_block(packages),
        "LATE_COMMANDS_BLOCK": build_late_commands(
            args.offline, args.with_pool, args.provision
        ),
    }

    with open(args.template, "r", encoding="utf-8") as f:
        tmpl = f.read()

    def sub(m):
        key = m.group(1)
        if key not in values:
            raise KeyError(f"模板里有未知占位符 @@{key}@@")
        return str(values[key])

    rendered = PLACEHOLDER_RE.sub(sub, tmpl)

    leftover = PLACEHOLDER_RE.findall(rendered)
    if leftover:
        sys.stderr.write(f"[FAIL] 未替换的占位符: {leftover}\n")
        return 2

    if yaml is not None:
        try:
            doc = yaml.safe_load(rendered)
        except Exception as e:
            sys.stderr.write(f"[FAIL] 渲染结果不是合法 YAML: {e}\n")
            return 2
        ai = (doc or {}).get("autoinstall")
        if not ai or ai.get("version") != 1:
            sys.stderr.write("[FAIL] YAML 缺少 autoinstall.version: 1\n")
            return 2
        for k in ("identity", "storage", "apt"):
            if k not in ai:
                sys.stderr.write(f"[WARN] autoinstall 缺少 {k} 段\n")

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(rendered)

    print(f"[ok] wrote {args.out} ({len(packages)} packages, offline={args.offline})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
