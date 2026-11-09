#!/usr/bin/env python3
"""
render-user-data.py — 把 user-data.tmpl 渲染成 subiquity 可直接消费的 user-data。
"""

import argparse
import os
import re
import sys

try:
    import yaml
except ImportError:
    yaml = None

PLACEHOLDER_RE = re.compile(r"@@([A-Z0-9_]+)@@")


def yaml_list_block(items, indent="    "):
    if not items:
        return f"{indent}[]"
    return "\n".join(f"{indent}- {i}" for i in items)


def yaml_quoted_list_block(items, indent="    "):
    if not items:
        return f"{indent}[]"
    lines = []
    for i in items:
        escaped = i.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'{indent}- "{escaped}"')
    return "\n".join(lines)


def build_apt_primary_block(mirror: str, full_offline: bool) -> str:
    """legacy primary 格式. 全离线时置空列表, 配合 fallback: offline-install 避免镜像探测卡住。"""
    if full_offline:
        return "    primary: []"
    return "\n".join(
        [
            "    primary:",
            "      - arches: [amd64, i386]",
            f'        uri: "{mirror}"',
        ]
    )


def build_late_commands(
    *,
    with_pool: bool,
    provision: bool,
    full_offline: bool,
):
    cmds = []

    if full_offline:
        # 1) 拷贝离线捆绑 2) 临时只指向 file: 源 3) 再 provision
        cmds += [
            "mkdir -p /target/opt/offline && cp -a /cdrom/offline/. /target/opt/offline/",
            (
                "curtin in-target --target=/target -- sh -c '"
                "mkdir -p /etc/apt/sources.list.d.offline-bak; "
                "if [ -f /etc/apt/sources.list ]; then mv /etc/apt/sources.list /etc/apt/sources.list.offline-bak; fi; "
                "mkdir -p /etc/apt/sources.list.d; "
                "find /etc/apt/sources.list.d -maxdepth 1 -type f \\\\( -name \"*.list\" -o -name \"*.sources\" \\\\) "
                "-exec mv {} /etc/apt/sources.list.d.offline-bak/ \\\\; 2>/dev/null || true; "
                "echo \"deb [trusted=yes] file:/opt/offline/apt ./\" > /etc/apt/sources.list.d/00-offline-bundle.list; "
                "apt-get update"
                "'"
            ),
        ]

    if with_pool and not full_offline:
        # 旧 --debs 路径 (非全离线捆绑)
        cmds += [
            "mkdir -p /target/opt/offline-debs",
            "cp -a /cdrom/pool/. /target/opt/offline-debs/ || true",
            "curtin in-target --target=/target -- sh -c "
            "'cd /opt/offline-debs && for i in 1 2 3; do dpkg -i ./*.deb && break; done; "
            "dpkg --configure -a || true'",
        ]

    if provision:
        cmds += [
            "mkdir -p /target/opt/provision && cp -a /cdrom/provision/. /target/opt/provision/",
            "curtin in-target --target=/target -- bash /opt/provision/run-all.sh",
        ]

    if full_offline:
        # 恢复安装器写入的官方源, 便于以后联网升级; 保留 /opt/offline 供重装
        cmds.append(
            "curtin in-target --target=/target -- sh -c '"
            "rm -f /etc/apt/sources.list.d/00-offline-bundle.list; "
            "if [ -f /etc/apt/sources.list.offline-bak ]; then "
            "mv /etc/apt/sources.list.offline-bak /etc/apt/sources.list; fi; "
            "if [ -d /etc/apt/sources.list.d.offline-bak ]; then "
            "mv /etc/apt/sources.list.d.offline-bak/* /etc/apt/sources.list.d/ 2>/dev/null || true; "
            "rmdir /etc/apt/sources.list.d.offline-bak 2>/dev/null || true; fi"
            "'"
        )

    cmds += [
        "curtin in-target --target=/target -- timedatectl set-ntp true || true",
        "curtin in-target --target=/target -- systemctl enable --now ssh || true",
    ]
    cmds.append(
        "curtin in-target --target=/target -- sh -c "
        "'mkdir -p /var/log/autoinstall && dpkg -l > /var/log/autoinstall/packages.txt'"
    )
    return "\n".join(f"    - {c}" for c in cmds)


def load_authorized_keys(path: str | None) -> list[str]:
    if not path:
        return []
    keys = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            keys.append(line)
    return keys


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
    ap.add_argument("--ssh-authorized-keys", default="")
    ap.add_argument("--storage-layout", default="direct", choices=["direct", "lvm", "zfs"])
    ap.add_argument("--offline", action="store_true",
                    help="apt fallback offline-install + updates none")
    ap.add_argument("--full-offline", action="store_true",
                    help="全离线: 使用 /cdrom/offline 捆绑, packages 改 late 安装")
    ap.add_argument("--with-pool", action="store_true")
    ap.add_argument("--provision", action="store_true")
    args = ap.parse_args()

    pw = args.password_hash.strip()
    if not pw.startswith("$"):
        sys.stderr.write(
            "[FAIL] --password-hash 必须是 crypt 哈希, 例如:\n"
            "       openssl passwd -6 'YourPassword'\n"
        )
        return 2

    packages = [p.strip() for p in args.packages.split(",") if p.strip()]
    auth_keys = load_authorized_keys(args.ssh_authorized_keys or None)

    ssh_allow = str(args.ssh_allow_pw).strip().lower()
    if ssh_allow not in ("true", "false"):
        sys.stderr.write("[FAIL] --ssh-allow-pw 必须是 true 或 false\n")
        return 2

    full_offline = bool(args.full_offline)
    offline = bool(args.offline) or full_offline

    if offline:
        updates = "none"
        fallback = "offline-install"
    else:
        updates = "security"
        fallback = "offline-install"

    # 全离线: 不在 autoinstall.packages 装第三方/额外包 (安装器阶段无网/无捆绑索引)
    render_packages = [] if full_offline else packages

    values = {
        "HOSTNAME": args.hostname,
        "USERNAME": args.username,
        "PASSWORD_HASH": pw,
        "LOCALE": args.locale,
        "KEYBOARD": args.keyboard,
        "TIMEZONE": args.timezone,
        "APT_PRIMARY_BLOCK": build_apt_primary_block(args.mirror, full_offline),
        "APT_FALLBACK": fallback,
        "UPDATES": updates,
        "SSH_ALLOW_PW": ssh_allow,
        "SSH_AUTHORIZED_KEYS_BLOCK": yaml_quoted_list_block(auth_keys, indent="      "),
        "STORAGE_LAYOUT": args.storage_layout,
        "PACKAGES_BLOCK": yaml_list_block(render_packages),
        "LATE_COMMANDS_BLOCK": build_late_commands(
            with_pool=args.with_pool,
            provision=args.provision,
            full_offline=full_offline,
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
        if full_offline:
            late = ai.get("late-commands") or []
            if not any("offline" in str(c) for c in late):
                sys.stderr.write("[FAIL] full-offline 但 late-commands 未引用 offline\n")
                return 2

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(rendered)

    print(
        f"[ok] wrote {args.out} (packages={len(render_packages)}, "
        f"ssh_keys={len(auth_keys)}, offline={offline}, full_offline={full_offline})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
