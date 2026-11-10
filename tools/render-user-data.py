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

USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
PACKAGE_NAME_RE = re.compile(r"^[a-zA-Z0-9.+_-]+$")


def validate_username(name: str) -> None:
    if not USERNAME_RE.fullmatch(name or ""):
        raise SystemExit(
            f"[FAIL] --username 非法 (POSIX: 以小写字母或 _ 开头, 仅 [a-z0-9_-], 最长 32): {name!r}"
        )


def validate_packages_csv(raw: str) -> list[str]:
    """Require comma-separated package names with no spaces (safe for env files)."""
    raw = (raw or "").strip()
    if not raw:
        return []
    if any(c.isspace() for c in raw):
        raise SystemExit(
            "[FAIL] --packages 不能含空格; 请用逗号分隔, 例如: vim,curl,htop"
        )
    packages = [p for p in raw.split(",") if p]
    for p in packages:
        if not PACKAGE_NAME_RE.fullmatch(p):
            raise SystemExit(
                f"[FAIL] --packages 含非法包名 (仅 [a-zA-Z0-9.+_-]): {p!r}"
            )
    return packages



# Netplan written into autoinstall.network and /target late-command.
# match + optional: 装机时无网卡也不会卡住; 首启有网卡时按名通配 DHCP。
DHCP_NETPLAN = """network:
  version: 2
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: true
      optional: true
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
      dhcp6: true
      optional: true
"""


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


# 默认 apt 源: 清华大学开源镜像 http (含 -security; apt 走 GPG, 避免干净环境缺 CA)。与 build-iso.sh / fetch-offline-bundle.sh 保持一致。
DEFAULT_UBUNTU_MIRROR = "http://mirrors.tuna.tsinghua.edu.cn/ubuntu"


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


# 桌面版: 目标系统由 NetworkManager 管理网络; 同样按 en*/eth* 通配 DHCP,
# 但 renderer 必须是 NetworkManager, 否则网卡在 GNOME 里显示「未托管」。
DHCP_NETPLAN_NM = DHCP_NETPLAN.replace(
    "network:\n  version: 2\n", "network:\n  version: 2\n  renderer: NetworkManager\n", 1
)


def build_network_block(mode: str, edition: str = "server") -> str:
    """autoinstall.network 段。none 时返回空串(省略该键)。

    desktop: 也省略。桌面安装器的 live 会话由 NetworkManager 联网, 在 autoinstall
    里塞 networkd 风格的 netplan 会与之打架; 目标系统的 DHCP 由 late-command 写入
    renderer: NetworkManager 的 netplan。
    """
    if mode == "none" or edition == "desktop":
        return ""
    # DHCP_NETPLAN starts with "network:"; re-key under autoinstall indent (2 spaces)
    body = DHCP_NETPLAN.strip()
    assert body.startswith("network:\n")
    rest = body[len("network:\n") :]
    out = ["  network:"]
    for line in rest.splitlines():
        out.append("  " + line if line else "")
    return "\n".join(out) + "\n"


def yaml_dq(v: str) -> str:
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'


def build_realname_line(realname: str) -> str:
    if not realname:
        return ""
    return f"    realname: {yaml_dq(realname)}"


DESKTOP_SOURCE_ALIASES = {
    "minimal": "ubuntu-desktop-minimal",
    "standard": "ubuntu-desktop",
    "full": "ubuntu-desktop",
}


def resolve_desktop_source(value: str) -> str:
    v = (value or "minimal").strip()
    return DESKTOP_SOURCE_ALIASES.get(v, v)


def build_source_block(edition: str, source_id: str) -> str:
    """server: 省略 (沿用 ISO 默认 ubuntu-server); desktop: 显式写 source.id。"""
    if edition != "desktop":
        return ""
    return "\n".join(["  source:", f"    id: {source_id}", ""])


def build_interactive_sections_block(auto_disk: bool) -> str:
    """Default: stop on storage screen (layout values used as UI defaults).
    --auto-disk: fully unattended (dangerous: auto-wipes match size largest).
    """
    if auto_disk:
        return "  interactive-sections: []"
    return "  interactive-sections:\n    - storage"


def build_dhcp_late_commands(edition: str = "server") -> list[str]:
    """
    Subiquity 在无显式 network 时会按「安装时探测到的网卡」写 00-installer-config.yaml;
    离线无 NIC 装机后首启就没有 DHCP。即使有 autoinstall.network (match 通配),
    仍用 late-commands 落盘 50-autoinstall-dhcp.yaml 并关掉 cloud-init 网络改写, 避免冲突。
    """
    netplan = DHCP_NETPLAN_NM if edition == "desktop" else DHCP_NETPLAN
    body_lines = netplan.rstrip("\n").splitlines()
    quoted = " ".join("'" + line.replace("'", "'\\''") + "'" for line in body_lines)
    return [
        "mkdir -p /target/etc/netplan /target/etc/cloud/cloud.cfg.d",
        f"printf '%s\\n' {quoted} > /target/etc/netplan/50-autoinstall-dhcp.yaml",
        "chmod 600 /target/etc/netplan/50-autoinstall-dhcp.yaml",
        "printf '%s\\n' 'network: {config: disabled}' "
        "> /target/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg",
        "rm -f /target/etc/netplan/00-installer-config.yaml "
        "/target/etc/netplan/50-cloud-init.yaml",
    ]


def build_late_commands(
    *,
    with_pool: bool,
    provision: bool,
    full_offline: bool,
    network: str,
    edition: str = "server",
    username: str = "ops",
    auth_keys: list[str] | None = None,
):
    cmds = []

    if full_offline:
        # 1) 拷贝离线捆绑 2) 脚本挂 file: 源 (忌 find \( \) —— nested sh -c 会 Syntax error exit 2)
        # 3) 再 provision。enable/restore 由 build-iso 写入 ISO /offline/
        cmds += [
            "mkdir -p /target/opt/offline && cp -a /cdrom/offline/. /target/opt/offline/ && chmod -R a+rX /target/opt/offline",
            "curtin in-target --target=/target -- bash /opt/offline/enable-offline-apt.sh",
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
            "curtin in-target --target=/target -- bash /opt/offline/restore-online-apt.sh"
        )

    if network == "dhcp":
        cmds += build_dhcp_late_commands(edition)

    # Subiquity ssh.authorized-keys 偶发未写入家目录; ISO 上的脚本再落盘一次。
    if auth_keys:
        cmds.append(
            f"bash /cdrom/nocloud/write-authorized-keys.sh {username}"
        )

    cmds += [
        "curtin in-target --target=/target -- timedatectl set-ntp true || true",
        "curtin in-target --target=/target -- systemctl enable --now ssh || true",
    ]
    cmds.append(
        "curtin in-target --target=/target -- sh -c "
        "'mkdir -p /var/log/autoinstall && dpkg -l > /var/log/autoinstall/packages.txt'"
    )
    def yaml_cmd(c: str) -> str:
        # Quote so payloads containing 'key: value' stay valid YAML scalars.
        escaped = c.replace("\\", "\\\\").replace('"', '\\"')
        return f'    - "{escaped}"'

    return "\n".join(yaml_cmd(c) for c in cmds)


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
    ap.add_argument("--mirror", default=DEFAULT_UBUNTU_MIRROR)
    ap.add_argument("--packages", default="", help="逗号分隔")
    ap.add_argument("--ssh-allow-pw", default="true")
    ap.add_argument("--ssh-authorized-keys", default="")
    ap.add_argument("--storage-layout", default="direct", choices=["direct", "lvm", "zfs"])
    ap.add_argument("--offline", action="store_true",
                    help="apt fallback offline-install; updates stays security (Subiquity enum has no none)")
    ap.add_argument("--full-offline", action="store_true",
                    help="全离线: 使用 /cdrom/offline 捆绑, packages 改 late 安装")
    ap.add_argument("--with-pool", action="store_true")
    ap.add_argument("--provision", action="store_true")
    ap.add_argument(
        "--network",
        default="dhcp",
        choices=["dhcp", "none"],
        help="dhcp(默认): 写入 match en*/eth* 的 netplan + late-command; none: 不写",
    )
    ap.add_argument(
        "--edition",
        default="server",
        choices=["server", "desktop"],
        help="server(默认) | desktop (Ubuntu 24.04 Desktop, ubuntu-desktop-bootstrap)",
    )
    ap.add_argument(
        "--desktop-source",
        default="minimal",
        help="desktop 安装源: minimal(=ubuntu-desktop-minimal, 默认) | standard(=ubuntu-desktop) | 任意 source id",
    )
    ap.add_argument("--realname", default="", help="identity.realname; desktop 默认等于 username")
    ap.add_argument(
        "--auto-disk",
        action="store_true",
        help=(
            "全自动选盘 (interactive-sections: [])；默认停在 storage 页由用户确认。"
            "危险：会按 match size:largest 直接抹盘。仅用于 QEMU/CI 无人值守。"
        ),
    )
    args = ap.parse_args()

    pw = args.password_hash.strip()
    if not pw.startswith("$"):
        sys.stderr.write(
            "[FAIL] --password-hash 必须是 crypt 哈希, 例如:\n"
            "       openssl passwd -6 'YourPassword'\n"
        )
        return 2

    try:
        validate_username(args.username)
        packages = validate_packages_csv(args.packages)
    except SystemExit as e:
        sys.stderr.write(str(e) + "\n")
        return 2

    auth_keys = load_authorized_keys(args.ssh_authorized_keys or None)

    ssh_allow = str(args.ssh_allow_pw).strip().lower()
    if ssh_allow not in ("true", "false"):
        sys.stderr.write("[FAIL] --ssh-allow-pw 必须是 true 或 false\n")
        return 2
    if ssh_allow == "false" and not auth_keys:
        sys.stderr.write(
            "[FAIL] --ssh-allow-pw false 但未提供任何 SSH 公钥；"
            "装完将无法登录。请加 --ssh-authorized-keys，或改回 --ssh-allow-pw true\n"
        )
        return 2

    network = args.network
    edition = args.edition
    full_offline = bool(args.full_offline)
    source_id = resolve_desktop_source(args.desktop_source) if edition == "desktop" else ""
    realname = args.realname or (args.username if edition == "desktop" else "")
    # Desktop ISO 不带 openssh-server (官方文档明确), 安装器阶段装 ssh 需要联网;
    # 全离线时交给 software/10-openssh.sh 从离线捆绑安装。
    ssh_install_server = "false" if (edition == "desktop" and full_offline) else "true"
    offline = bool(args.offline) or full_offline

    # Subiquity only accepts updates in {security, all}; there is no "none".
    # Offline installs rely on apt.fallback: offline-install so mirror/update
    # probes do not block when the NIC is absent.
    updates = "security"
    fallback = "offline-install"

    # 全离线: 不在 autoinstall.packages 装第三方/额外包 (安装器阶段无网/无捆绑索引)
    render_packages = [] if full_offline else packages

    shutdown = "poweroff" if args.auto_disk else "reboot"

    values = {
        "HOSTNAME": args.hostname,
        "USERNAME": args.username,
        "PASSWORD_HASH": pw,
        "SHUTDOWN": shutdown,
        "LOCALE": args.locale,
        "KEYBOARD": args.keyboard,
        "TIMEZONE": args.timezone,
        "APT_PRIMARY_BLOCK": build_apt_primary_block(args.mirror, full_offline),
        "APT_FALLBACK": fallback,
        "UPDATES": updates,
        "SSH_ALLOW_PW": ssh_allow,
        "SSH_INSTALL_SERVER": ssh_install_server,
        "REALNAME_LINE": build_realname_line(realname),
        "SOURCE_BLOCK": build_source_block(edition, source_id),
        "SSH_AUTHORIZED_KEYS_BLOCK": yaml_quoted_list_block(auth_keys, indent="      "),
        "STORAGE_LAYOUT": args.storage_layout,
        "INTERACTIVE_SECTIONS_BLOCK": build_interactive_sections_block(bool(args.auto_disk)),
        "PACKAGES_BLOCK": yaml_list_block(render_packages),
        "NETWORK_BLOCK": build_network_block(network, edition),
        "LATE_COMMANDS_BLOCK": build_late_commands(
            with_pool=args.with_pool,
            provision=args.provision,
            full_offline=full_offline,
            network=network,
            edition=edition,
            username=args.username,
            auth_keys=auth_keys,
        ),
    }

    with open(args.template, "r", encoding="utf-8") as f:
        tmpl = f.read()

    def sub(m):
        key = m.group(1)
        if key not in values:
            raise KeyError(f"模板里有未知占位符 @@{key}@@")
        return str(values[key])

    # A placeholder alone on its line that renders empty drops the whole line.
    def sub_line(m):
        val = str(values.get(m.group(1), m.group(0)))
        if m.group(1) in values and val == "":
            return ""
        return val + "\n"

    tmpl = re.sub(r"^@@([A-Z0-9_]+)@@\n", sub_line, tmpl, flags=re.M)
    rendered = PLACEHOLDER_RE.sub(sub, tmpl)
    leftover = PLACEHOLDER_RE.findall(rendered)
    if leftover:
        sys.stderr.write(f"[FAIL] 未替换的占位符: {leftover}\n")
        return 2

    # Empty optional blocks leave blank lines behind; collapse them.
    rendered = re.sub(r"\n{3,}", "\n\n", rendered)

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
        isec = ai.get("interactive-sections")
        if args.auto_disk:
            if isec not in ([], None):
                sys.stderr.write(
                    f"[FAIL] --auto-disk 但 interactive-sections 不是 []: {isec!r}\n"
                )
                return 2
            if ai.get("shutdown") != "poweroff":
                sys.stderr.write(
                    f"[FAIL] --auto-disk 时 shutdown 应为 poweroff (防 U 盘循环抹盘), got {ai.get('shutdown')!r}\n"
                )
                return 2
        else:
            if not isinstance(isec, list) or "storage" not in isec:
                sys.stderr.write(
                    f"[FAIL] 默认应含 interactive-sections: [storage], got {isec!r}\n"
                )
                return 2
            if ai.get("shutdown") != "reboot":
                sys.stderr.write(
                    f"[FAIL] 非 --auto-disk 时 shutdown 应为 reboot, got {ai.get('shutdown')!r}\n"
                )
                return 2
        if edition == "desktop":
            src = (ai.get("source") or {}).get("id")
            if src != source_id:
                sys.stderr.write(f"[FAIL] desktop 但 source.id={src!r} != {source_id!r}\n")
                return 2
            if not (ai.get("identity") or {}).get("realname"):
                sys.stderr.write("[FAIL] desktop 缺少 identity.realname\n")
                return 2
            if "network" in ai:
                sys.stderr.write("[FAIL] desktop 不应写 autoinstall.network (live 会话归 NetworkManager)\n")
                return 2
            late = ai.get("late-commands") or []
            if network == "dhcp" and not any(
                "renderer: NetworkManager" in str(c) and "50-autoinstall-dhcp.yaml" in str(c)
                for c in late
            ):
                sys.stderr.write("[FAIL] desktop dhcp 但 late-commands 未写 renderer: NetworkManager\n")
                return 2
        elif network == "dhcp":
            net = ai.get("network") or {}
            eth = net.get("ethernets") or {}
            if "all-en" not in eth or "all-eth" not in eth:
                sys.stderr.write("[FAIL] network=dhcp 但缺少 all-en/all-eth\n")
                return 2
            late = ai.get("late-commands") or []
            if not any("50-autoinstall-dhcp.yaml" in str(c) for c in late):
                sys.stderr.write(
                    "[FAIL] network=dhcp 但 late-commands 未写 50-autoinstall-dhcp.yaml\n"
                )
                return 2
        elif network == "none":
            if "network" in (ai or {}):
                sys.stderr.write("[FAIL] network=none 但 YAML 仍含 network 键\n")
                return 2
        late = ai.get("late-commands") or []
        if auth_keys:
            if not any("write-authorized-keys.sh" in str(c) for c in late):
                sys.stderr.write(
                    "[FAIL] 提供了 ssh keys 但 late-commands 无 write-authorized-keys.sh\n"
                )
                return 2
        else:
            if any("write-authorized-keys.sh" in str(c) for c in late):
                sys.stderr.write(
                    "[FAIL] 未提供 ssh keys 但 late-commands 含 write-authorized-keys.sh\n"
                )
                return 2

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(rendered)

    print(
        f"[ok] wrote {args.out} (packages={len(render_packages)}, "
        f"ssh_keys={len(auth_keys)}, offline={offline}, full_offline={full_offline}, "
        f"network={network}, auto_disk={bool(args.auto_disk)}, shutdown={shutdown}, "
        f"edition={edition}"
        + (f", source={source_id}" if source_id else "")
        + ")"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
