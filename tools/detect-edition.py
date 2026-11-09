#!/usr/bin/env python3
"""
detect-edition.py — 根据 ISO 内的 casper/install-sources.yaml 与 .disk/info 判断版本。

输出 (stdout, 便于 shell eval):
  EDITION=server|desktop|unknown
  RELEASE=24.04 (尽力而为, 取 .disk/info 的 X.Y)
  SOURCES=id1,id2          install-sources.yaml 里的全部 source id
  DEFAULT_SOURCE=id        default: true 的 source id
  SUBIQUITY=1|0            是否是 Subiquity 系安装器 (存在 install-sources.yaml)

判定顺序:
  1. install-sources.yaml 的 variant: desktop / server (24.04+ 最可靠)
  2. .disk/info 以 "Ubuntu-Server" 开头 -> server, 其它 Ubuntu -> desktop
用法:
  detect-edition.py --install-sources FILE --disk-info FILE   (文件可不存在)
"""

import argparse
import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - CI 装了 python3-yaml
    yaml = None


def parse_sources(text: str):
    """返回 [(id, variant, default)]. 无 PyYAML 时用正则兜底。"""
    if yaml is not None:
        try:
            data = yaml.safe_load(text) or []
        except Exception:
            data = []
        out = []
        if isinstance(data, list):
            for item in data:
                if isinstance(item, dict) and item.get("id"):
                    out.append(
                        (str(item["id"]), str(item.get("variant") or ""), bool(item.get("default")))
                    )
        return out
    out = []
    for block in re.split(r"^- ", text, flags=re.M)[1:]:
        m_id = re.search(r"^\s*id:\s*(\S+)", block, re.M)
        if not m_id:
            continue
        m_var = re.search(r"^\s*variant:\s*(\S+)", block, re.M)
        m_def = re.search(r"default:\s*true", block)
        out.append((m_id.group(1), m_var.group(1) if m_var else "", bool(m_def)))
    return out


def detect(sources_text: str | None, disk_info: str | None):
    edition = "unknown"
    sources = parse_sources(sources_text) if sources_text else []
    variants = {v for _, v, _ in sources if v}
    if "desktop" in variants:
        edition = "desktop"
    elif "server" in variants:
        edition = "server"
    elif sources:
        ids = " ".join(i for i, _, _ in sources)
        if "server" in ids:
            edition = "server"
        elif "desktop" in ids:
            edition = "desktop"

    info = (disk_info or "").strip()
    if edition == "unknown" and info:
        if info.lower().startswith("ubuntu-server"):
            edition = "server"
        elif info.lower().startswith("ubuntu"):
            edition = "desktop"

    m = re.search(r"\b(\d{2}\.\d{2})(?:\.\d+)*\b", info)
    release = m.group(1) if m else ""
    default = next((i for i, _, d in sources if d), "")
    return {
        "EDITION": edition,
        "RELEASE": release,
        "SOURCES": ",".join(i for i, _, _ in sources),
        "DEFAULT_SOURCE": default,
        "SUBIQUITY": "1" if sources else "0",
    }


def read_opt(path: str | None):
    if path and os.path.isfile(path):
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--install-sources", default="")
    ap.add_argument("--disk-info", default="")
    args = ap.parse_args()
    res = detect(read_opt(args.install_sources), read_opt(args.disk_info))
    for k, v in res.items():
        # 值里不含空格/引号 (id 与版本号), 直接 KEY=VALUE
        print(f"{k}={v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
