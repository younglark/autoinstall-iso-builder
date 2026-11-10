#!/usr/bin/env python3
"""把 build-win-ventoy.sh 产出的 auto_install 片段合并进 U 盘的 /ventoy/ventoy.json。

- 只替换 image 相同的 auto_install 条目; 其它条目 (如 Ubuntu) 和其它顶层键 (theme、control、persistence...) 原样保留
- 目标不存在时新建; 存在时先写 <target>.bak (除非 --no-backup)
- --dry-run 只把合并结果打印到 stdout
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path


def merge(target: dict, snippet: dict) -> dict:
    new_entries = snippet.get("auto_install") or []
    if not isinstance(new_entries, list) or not new_entries:
        raise SystemExit("片段里没有 auto_install 数组")
    cur = target.get("auto_install", [])
    if not isinstance(cur, list):
        raise SystemExit("目标 ventoy.json 的 auto_install 不是数组, 拒绝覆盖")
    keys = {e.get("image") or e.get("parent") for e in new_entries}
    kept = [e for e in cur if (e.get("image") or e.get("parent")) not in keys]
    out = dict(target)
    out["auto_install"] = kept + new_entries
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--snippet", required=True)
    ap.add_argument("--target", required=True, help="U 盘上的 /ventoy/ventoy.json")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-backup", action="store_true")
    a = ap.parse_args(argv)
    snippet = json.loads(Path(a.snippet).read_text(encoding="utf-8"))
    tp = Path(a.target)
    target = json.loads(tp.read_text(encoding="utf-8-sig")) if tp.exists() else {}
    if not isinstance(target, dict):
        raise SystemExit("目标 ventoy.json 顶层不是对象")
    merged = merge(target, snippet)
    text = json.dumps(merged, ensure_ascii=False, indent=4) + "\n"
    if a.dry_run:
        sys.stdout.write(text)
        return 0
    if tp.exists() and not a.no_backup:
        shutil.copy2(tp, tp.with_suffix(tp.suffix + ".bak"))
    tp.parent.mkdir(parents=True, exist_ok=True)
    tp.write_text(text, encoding="utf-8")
    print(f"[ok] merged {len(snippet['auto_install'])} entr(y/ies) into {tp} "
          f"(auto_install total {len(merged['auto_install'])})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
