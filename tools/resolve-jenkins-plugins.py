#!/usr/bin/env python3
"""resolve-jenkins-plugins.py — 轻量 Jenkins 插件解析/下载器 (仅 Python 3 标准库)

按目标 Jenkins core 版本取官方 update center
    https://updates.jenkins.io/update-center.actual.json?version=<core>
递归解析请求插件的必需 (非 optional) 依赖, 选择 requiredCore <= core 的版本,
下载 .hpi 并用 update center 的 sha256 校验, 输出 <name>.jpi 与 lock 文件
(每行 name:version:sha256hex)。

  name            update center 为该 core 推荐的版本
  name:version    固定版本 (从 plugin-versions.json 取 URL / sha256)

用法:
  resolve-jenkins-plugins.py --jenkins-version 2.580.2 --out DIR \
      [--lock FILE] [--uc-url URL] [--no-download] PLUGIN [PLUGIN ...]
退出码: 0 成功; 1 解析/下载/校验失败; 2 参数错误
"""
import argparse
import base64
import hashlib
import json
import os
import re
import sys
import tempfile
import time
import urllib.request

UC_BASE = os.environ.get("JENKINS_UC_BASE", "https://updates.jenkins.io")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
VER_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def fetch(url, dest=None, tries=4):
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "autoinstall-iso-builder/resolve-jenkins-plugins"})
            with urllib.request.urlopen(req, timeout=120) as r:
                if dest is None:
                    return r.read()
                with open(dest, "wb") as f:
                    while True:
                        b = r.read(1 << 16)
                        if not b:
                            break
                        f.write(b)
                return None
        except Exception as e:  # noqa: BLE001 — 网络错误统一重试
            last = e
            time.sleep(2 * (i + 1))
    raise RuntimeError(f"下载失败 {url}: {last}")


def vkey(v):
    """Jenkins/Maven 风格版本比较的近似: 数字段按数值, 其余按字符串。"""
    parts = re.findall(r"\d+|[A-Za-z]+", str(v))
    return [(0, int(p), "") if p.isdigit() else (1, 0, p) for p in parts]


def vle(a, b):
    return vkey(a) <= vkey(b)


def b64_to_hex(s):
    return base64.b64decode(s).hex()


class Resolver:
    def __init__(self, core, uc_url):
        self.core = core
        self.uc_url = uc_url or f"{UC_BASE}/update-center.actual.json?version={core}"
        self._uc = None
        self._versions = None

    @property
    def uc(self):
        if self._uc is None:
            log(f"update center: {self.uc_url}")
            self._uc = json.loads(fetch(self.uc_url))
        return self._uc

    @property
    def versions(self):
        if self._versions is None:
            url = f"{UC_BASE}/current/plugin-versions.json"
            log(f"plugin-versions: {url}")
            self._versions = json.loads(fetch(url))["plugins"]
        return self._versions

    def entry(self, name, pinned=None):
        """返回 {name, version, url, sha256(hex), requiredCore, dependencies}。"""
        p = self.uc["plugins"].get(name)
        if pinned is None and p and vle(p.get("requiredCore", "0"), self.core):
            return self._norm(p)
        # 固定版本, 或 UC 推荐版本不兼容 → 在全部历史版本里找
        hist = self.versions.get(name)
        if not hist:
            raise RuntimeError(f"未知插件: {name}")
        if pinned is not None:
            e = hist.get(pinned)
            if not e:
                raise RuntimeError(f"插件 {name} 没有版本 {pinned}")
            if not vle(e.get("requiredCore", "0"), self.core):
                raise RuntimeError(f"{name}:{pinned} 需要 Jenkins >= {e['requiredCore']} (目标 {self.core})")
            return self._norm(e)
        ok = [e for e in hist.values() if vle(e.get("requiredCore", "0"), self.core)]
        if not ok:
            raise RuntimeError(f"插件 {name} 没有兼容 Jenkins {self.core} 的版本")
        return self._norm(max(ok, key=lambda e: vkey(e["version"])))

    @staticmethod
    def _norm(e):
        sha = e.get("sha256") or ""
        return {
            "name": e["name"],
            "version": e["version"],
            "url": e["url"],
            "sha256": b64_to_hex(sha) if sha and not re.fullmatch(r"[0-9a-f]{64}", sha) else sha,
            "requiredCore": e.get("requiredCore", ""),
            "dependencies": e.get("dependencies", []),
        }

    def resolve(self, requests):
        chosen = {}
        pins = {}
        for r in requests:
            n, _, v = r.partition(":")
            pins[n] = v or None
        queue = list(pins)
        mins = {}  # name -> [(min_version, required_by)]
        while queue:
            n = queue.pop(0)
            if n in chosen:
                continue
            e = self.entry(n, pins.get(n))
            chosen[n] = e
            for d in e["dependencies"]:
                dn = d["name"]
                if d.get("optional") and dn not in pins:
                    continue
                mins.setdefault(dn, []).append((d.get("version", "0"), n))
                if dn not in chosen:
                    queue.append(dn)
        for dn, reqs in mins.items():
            have = chosen[dn]["version"]
            for mv, by in reqs:
                if not vle(mv, have):
                    raise RuntimeError(f"依赖冲突: {by} 需要 {dn}>={mv}, 但选中 {dn}:{have}"
                                       + (" (固定版本过低?)" if pins.get(dn) else ""))
        return chosen


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--jenkins-version", required=True)
    ap.add_argument("--out", required=True, help="下载目录 (<name>.jpi)")
    ap.add_argument("--lock", help="lock 文件路径 (默认 OUT/plugins.lock)")
    ap.add_argument("--uc-url", help="覆盖 update center URL")
    ap.add_argument("--no-download", action="store_true", help="只解析并打印 lock")
    ap.add_argument("plugins", nargs="+")
    a = ap.parse_args()

    if not re.fullmatch(r"\d+(\.\d+)*", a.jenkins_version):
        log(f"非法 --jenkins-version: {a.jenkins_version}")
        return 2
    for p in a.plugins:
        n, sep, v = p.partition(":")
        if not NAME_RE.fullmatch(n) or (sep and not VER_RE.fullmatch(v)):
            log(f"非法插件名: {p}")
            return 2

    try:
        chosen = Resolver(a.jenkins_version, a.uc_url).resolve(a.plugins)
    except RuntimeError as e:
        log(f"ERROR: {e}")
        return 1
    lock_lines = [f"{n}:{e['version']}:{e['sha256']}" for n, e in sorted(chosen.items())]
    log(f"resolved {len(chosen)} plugins for Jenkins {a.jenkins_version}")

    if a.no_download:
        print("\n".join(lock_lines))
        return 0

    os.makedirs(a.out, exist_ok=True)
    for n, e in sorted(chosen.items()):
        dest = os.path.join(a.out, f"{n}.jpi")
        if os.path.exists(dest) and hashlib.sha256(open(dest, "rb").read()).hexdigest() == e["sha256"]:
            continue
        fd, tmp = tempfile.mkstemp(dir=a.out, prefix=f".{n}.", suffix=".part")
        os.close(fd)
        try:
            fetch(e["url"], tmp)
            got = hashlib.sha256(open(tmp, "rb").read()).hexdigest()
            if not e["sha256"] or got != e["sha256"]:
                raise RuntimeError(f"sha256 不匹配 {n}:{e['version']} (got {got}, want {e['sha256'] or '缺失'})")
            os.chmod(tmp, 0o644)
            os.replace(tmp, dest)
            log(f"  {n}:{e['version']}")
        except RuntimeError as ex:
            log(f"ERROR: {ex}")
            return 1
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    lock = a.lock or os.path.join(a.out, "plugins.lock")
    with open(lock, "w") as f:
        f.write("\n".join(lock_lines) + "\n")
    log(f"lock: {lock}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
