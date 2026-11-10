#!/usr/bin/env bash
# =============================================================================
# win-check.sh — Windows 无人值守 (autounattend + Ventoy 交付物) 静态校验, 不需要真实 ISO
#   bash test/win-check.sh
#
# - 模板 / 两个变体: XML well-formed (xmllint 有则用, 否则 python), 必需元素与取值, 禁用元素
# - Ventoy 变量: 仅 autodisk 有, 每行最多一个, UTF-8 无 BOM
# - 密码: 渲染与构建的 stdout/stderr 不含明文或编码后的密码; 编码与 Learn 示例一致
# - build-win-ventoy.sh: 无 ISO 模式; 有 wimlib-imagex + 7z + xorriso 时用假 ISO (假 install.wim) 端到端,
#   含 sha256 校验 / 版本核对 / ISO 不被修改
# - merge-ventoy-json.py: 不覆盖已有 Ubuntu 条目与其它顶层键, 幂等
# - payload: marker / run-all.ps1 / 脚本存在, UTF-8 BOM (Windows PowerShell 5.1 才按 UTF-8 读);
#   有 pwsh 时做语法解析
# =============================================================================
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FAIL=0
pass() { printf '[pass] %s\n' "$*"; }
fail() { printf '[fail] %s\n' "$*" >&2; FAIL=1; }
tmp="$(mktemp -d -t aib-win-XXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT

SENTINEL='S3ntinel-Pw!x'
SENTINEL_B64="$(python3 -c 'import base64,sys;print(base64.b64encode((sys.argv[1]+"Password").encode("utf-16-le")).decode())' "$SENTINEL")"

wellformed() { # file
  if command -v xmllint >/dev/null; then
    xmllint --noout "$1"
  else
    python3 -c 'import sys,xml.etree.ElementTree as E;E.parse(sys.argv[1])' "$1"
  fi
}

no_leak() { # name file...
  local name="$1"; shift
  if grep -qF -- "$SENTINEL" "$@" || grep -qF -- "$SENTINEL_B64" "$@"; then
    fail "$name: 输出里出现了密码"
  else
    pass "$name: 输出不含密码"
  fi
}

echo "== win: template =="
if wellformed windows/autounattend.xml.tmpl; then pass "template well-formed"; else fail "template well-formed"; fi

echo "== win: render (env password) =="
if AIB_WIN_PASSWORD="$SENTINEL" python3 tools/render-unattend.py --out-dir "$tmp/r" --hostname WIN-DEV --username alice \
     >"$tmp/render.out" 2>"$tmp/render.err"; then
  pass "render both"
else
  fail "render both"; cat "$tmp/render.err" >&2
fi
no_leak "render" "$tmp/render.out" "$tmp/render.err"
for v in safe autodisk; do
  if wellformed "$tmp/r/aib-win-$v.xml"; then pass "$v well-formed"; else fail "$v well-formed"; fi
done

echo "== win: render (--password argv) =="
if python3 tools/render-unattend.py --out-dir "$tmp/r2" --variant safe --password "$SENTINEL" >"$tmp/r2.out" 2>"$tmp/r2.err"; then
  pass "render --password"
else
  fail "render --password"
fi
no_leak "render --password" "$tmp/r2.out" "$tmp/r2.err"
r3="$(python3 tools/render-unattend.py --out-dir "$tmp/r3" --variant safe 2>&1)"
if [[ "$r3" == *公开默认密码* ]]; then
  pass "默认密码告警"
else
  fail "默认密码告警"
fi

echo "== win: elements =="
if python3 - "$tmp/r" "$SENTINEL" <<'PY'
import base64, re, sys, xml.etree.ElementTree as E
d, pw = sys.argv[1], sys.argv[2]
NS = {"u": "urn:schemas-microsoft-com:unattend"}
errors = []
def chk(cond, msg):
    if not cond: errors.append(msg)

# Learn LocalAccount 示例: cAB3AFAAYQBzAHMAdwBvAHIAZAA (= "pw" + "Password", UTF-16LE, 无 padding)
sample = "cAB3AFAAYQBzAHMAdwBvAHIAZAA"
chk(base64.b64decode(sample + "=" * (-len(sample) % 4)).decode("utf-16-le") == "pwPassword", "Learn 示例编码解码")

for v in ("safe", "autodisk"):
    raw = open(f"{d}/aib-win-{v}.xml", "rb").read()
    chk(not raw.startswith(b"\xef\xbb\xbf"), f"{v}: 不应有 BOM")
    text = raw.decode("utf-8")
    body = re.sub(r"<!--.*?-->", "", text, flags=re.S)  # 注释里允许出现说明文字
    chk(text.startswith('<?xml version="1.0" encoding="utf-8"?>'), f"{v}: XML 声明 utf-8")
    r = E.fromstring(raw)
    def one(pass_, comp, path):
        el = r.findall(f"u:settings[@pass='{pass_}']/u:component[@name='{comp}']/{path}", NS)
        return el
    def val(pass_, comp, path):
        el = one(pass_, comp, path)
        return el[0].text if len(el) == 1 else None
    for c in r.iter("{urn:schemas-microsoft-com:unattend}component"):
        chk(c.get("processorArchitecture") == "amd64" and c.get("publicKeyToken") == "31bf3856ad364e35"
            and c.get("language") == "neutral" and c.get("versionScope") == "nonSxS", f"{v}: component 属性 {c.get('name')}")
    W, S = "Microsoft-Windows-International-Core-WinPE", "Microsoft-Windows-Setup"
    chk(val("windowsPE", W, "u:SetupUILanguage/u:UILanguage") == "zh-CN", f"{v}: SetupUILanguage")
    for k in ("SystemLocale", "UILanguage", "UserLocale"):
        chk(val("windowsPE", W, f"u:{k}") == "zh-CN", f"{v}: WinPE {k}")
        chk(val("oobeSystem", "Microsoft-Windows-International-Core", f"u:{k}") == "zh-CN", f"{v}: oobe {k}")
    pinyin = "0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}{FA550B04-5AD7-411F-A5AC-CA038EC515D7}"
    chk(val("windowsPE", W, "u:InputLocale") == pinyin, f"{v}: WinPE InputLocale")
    chk(val("oobeSystem", "Microsoft-Windows-International-Core", "u:InputLocale") == pinyin, f"{v}: oobe InputLocale")
    chk(val("windowsPE", S, "u:UserData/u:AcceptEula") == "true", f"{v}: AcceptEula")
    chk(val("windowsPE", S, "u:ImageInstall/u:OSImage/u:InstallFrom/u:MetaData/u:Key") == "/IMAGE/NAME", f"{v}: /IMAGE/NAME")
    chk(val("windowsPE", S, "u:ImageInstall/u:OSImage/u:InstallFrom/u:MetaData/u:Value") == "Windows 11 Pro", f"{v}: edition")
    chk(val("specialize", "Microsoft-Windows-Shell-Setup", "u:ComputerName") == "WIN-DEV", f"{v}: ComputerName")
    chk(val("specialize", "Microsoft-Windows-Shell-Setup", "u:TimeZone") == "China Standard Time", f"{v}: TimeZone")
    path = val("specialize", "Microsoft-Windows-Deployment", "u:RunSynchronous/u:RunSynchronousCommand/u:Path")
    chk(path is not None and len(path) <= 259 and "aib-win.marker" in path and "C:\\aib\\" in path, f"{v}: payload copy Path (<=259)")
    SH = "Microsoft-Windows-Shell-Setup"
    chk(val("oobeSystem", SH, "u:OOBE/u:HideOnlineAccountScreens") == "true", f"{v}: HideOnlineAccountScreens")
    chk(val("oobeSystem", SH, "u:OOBE/u:HideWirelessSetupInOOBE") == "true", f"{v}: HideWirelessSetupInOOBE")
    chk(val("oobeSystem", SH, "u:OOBE/u:ProtectYourPC") == "3", f"{v}: ProtectYourPC=3")
    acct = one("oobeSystem", SH, "u:UserAccounts/u:LocalAccounts/u:LocalAccount")
    chk(len(acct) == 1, f"{v}: 一个 LocalAccount")
    if acct:
        a = acct[0]
        chk(a.findtext("u:Name", namespaces=NS) == "alice", f"{v}: LocalAccount Name")
        chk(a.findtext("u:Group", namespaces=NS) == "Administrators", f"{v}: Administrators")
        chk(a.findtext("u:Password/u:PlainText", namespaces=NS) == "false", f"{v}: PlainText=false")
        enc = a.findtext("u:Password/u:Value", namespaces=NS) or ""
        chk(base64.b64decode(enc).decode("utf-16-le") == pw + "Password", f"{v}: LocalAccount 密码编码")
    chk(val("oobeSystem", SH, "u:AutoLogon/u:Enabled") == "true", f"{v}: AutoLogon Enabled")
    chk(val("oobeSystem", SH, "u:AutoLogon/u:LogonCount") == "1", f"{v}: LogonCount=1")
    chk(val("oobeSystem", SH, "u:AutoLogon/u:Username") == "alice", f"{v}: AutoLogon Username")
    fl = one("oobeSystem", SH, "u:FirstLogonCommands/u:SynchronousCommand")
    chk(len(fl) == 1, f"{v}: 只有一条 FirstLogonCommands")
    if fl:
        chk("C:\\aib\\run-all.ps1" in (fl[0].findtext("u:CommandLine", namespaces=NS) or ""), f"{v}: run-all.ps1")
    for bad in ("ProductKey", "PreventDeviceEncryption", "SkipMachineOOBE", "BypassNRO", "BypassTPMCheck",
                "BypassSecureBootCheck", "LabConfig", "ms-cxh", "HideEULAPage"):
        chk(bad not in body, f"{v}: 禁用项 {bad}")
    chk(pw not in text, f"{v}: XML 不含明文密码 (PlainText=false)")
    for n, line in enumerate(text.splitlines(), 1):
        chk(len(re.findall(r"\$\$[A-Za-z0-9_]+\$\$", line)) <= 1, f"{v}: 第 {n} 行多个 Ventoy 变量")
    dc = r.find("u:settings[@pass='windowsPE']/u:component[@name='Microsoft-Windows-Setup']/u:DiskConfiguration", NS)
    disks = dc.findall("u:Disk", NS) if dc is not None else []
    inst = r.findall(".//u:OSImage/u:InstallTo", NS)
    if v == "safe":
        chk(dc is not None and dc.findtext("u:WillShowUI", namespaces=NS) == "Always", "safe: WillShowUI=Always")
        chk(not disks and "WillWipeDisk" not in text and not inst, "safe: 不写 Disk / WillWipeDisk / InstallTo")
        chk("$$" not in text, "safe: 无 Ventoy 变量")
    else:
        chk(len(disks) == 1, "autodisk: 一个 Disk")
        if disks:
            dk = disks[0]
            chk(dk.findtext("u:DiskID", namespaces=NS) == "$$VT_WINDOWS_DISK_1ST_NONVTOY$$", "autodisk: DiskID 变量")
            chk(dk.findtext("u:WillWipeDisk", namespaces=NS) == "true", "autodisk: WillWipeDisk")
            types = [p.findtext("u:Type", namespaces=NS) for p in dk.findall("u:CreatePartitions/u:CreatePartition", NS)]
            chk(types == ["EFI", "MSR", "Primary"], f"autodisk: 分区 {types}")
            fmts = {p.findtext("u:PartitionID", namespaces=NS): p.findtext("u:Format", namespaces=NS)
                    for p in dk.findall("u:ModifyPartitions/u:ModifyPartition", NS)}
            chk(fmts == {"1": "FAT32", "3": "NTFS"}, f"autodisk: 格式化 {fmts}")
        chk(len(inst) == 1 and inst[0].findtext("u:DiskID", namespaces=NS) == "$$VT_WINDOWS_DISK_1ST_NONVTOY$$"
            and inst[0].findtext("u:PartitionID", namespaces=NS) == "3", "autodisk: InstallTo")
        chk(text.count("$$VT_WINDOWS_DISK_1ST_NONVTOY$$") == 2, "autodisk: 变量出现 2 次")
if errors:
    print("\n".join(errors), file=sys.stderr); sys.exit(1)
PY
then
  pass "required / forbidden elements (safe + autodisk)"
else
  fail "required / forbidden elements"
fi

echo "== win: render 参数校验 =="
for bad in "--hostname 12345" "--hostname TOO-LONG-HOSTNAME-X" "--hostname a.b" "--username Administrator" "--disk-id foo" "--locale fr-FR"; do
  # shellcheck disable=SC2086
  if python3 tools/render-unattend.py --out-dir "$tmp/bad" $bad >/dev/null 2>&1; then fail "应拒绝: $bad"; else pass "拒绝: $bad"; fi
done
if python3 tools/render-unattend.py --out-dir "$tmp/q" --variant autodisk --disk-id 0 >/dev/null 2>&1 \
   && grep -q '<DiskID>0</DiskID>' "$tmp/q/aib-win-autodisk.xml" && ! grep -q '\$\$' "$tmp/q/aib-win-autodisk.xml"; then
  pass "--disk-id 0 (非 Ventoy)"
else
  fail "--disk-id 0"
fi

echo "== win: payload =="
pl=windows/payload
if [[ -f $pl/aib-win.marker && -f $pl/run-all.ps1 && -f $pl/scripts/00-logging.ps1 && -f $pl/scripts/10-openssh-server.ps1 && -f $pl/scripts/99-cleanup.ps1 ]]; then
  pass "payload files"
else
  fail "payload files"
fi
bom_ok=1
for f in "$pl"/run-all.ps1 "$pl"/scripts/*.ps1; do
  [[ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')" == "efbbbf" ]] || { bom_ok=0; echo "  no BOM: $f" >&2; }
done
if [[ $bom_ok -eq 1 ]]; then pass "ps1 UTF-8 BOM"; else fail "ps1 UTF-8 BOM"; fi
if grep -q 'Panther' $pl/scripts/99-cleanup.ps1 && grep -q 'AutoAdminLogon' $pl/scripts/99-cleanup.ps1 \
   && grep -q 'DefaultPassword' $pl/scripts/99-cleanup.ps1 && grep -q 'AutoLogonCount' $pl/scripts/99-cleanup.ps1; then
  pass "cleanup: Panther + AutoLogon"
else
  fail "cleanup: Panther + AutoLogon"
fi
if grep -qi 'password' $pl/run-all.ps1; then fail "run-all.ps1 不应处理密码"; else pass "run-all.ps1 无密码"; fi
if command -v pwsh >/dev/null; then
  # shellcheck disable=SC2016
  if pwsh -NoProfile -Command '
    $bad = 0
    foreach ($f in @(Get-ChildItem windows/payload -Recurse -Filter *.ps1)) {
      $t = $null; $e = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
      if ($e.Count) { $bad++; $e | ForEach-Object { Write-Host "$($f.Name): $($_.Message)" } }
    }
    exit $bad'; then
    pass "pwsh parse payload"
  else
    fail "pwsh parse payload"
  fi
else
  echo "(pwsh not installed, payload parse skipped)"
fi

echo "== win: build-win-ventoy (无 ISO) =="
mkdir -p "$tmp/usb/ventoy"
if AIB_WIN_PASSWORD="$SENTINEL" bash tools/build-win-ventoy.sh --out "$tmp/o1" --ventoy-image /ISO/Win11_test.iso \
     --hostname WIN-DEV >"$tmp/b1.out" 2>"$tmp/b1.err"; then
  pass "build (no ISO)"
else
  fail "build (no ISO)"; cat "$tmp/b1.err" >&2
fi
no_leak "build (no ISO)" "$tmp/b1.out" "$tmp/b1.err" "$tmp/o1/manifest.txt" "$tmp/o1/ventoy/ventoy.auto_install.json"
if [[ -f "$tmp/o1/ventoy/script/aib-win-safe.xml" && -f "$tmp/o1/ventoy/script/aib-win-autodisk.xml" \
      && -f "$tmp/o1/aib-win/aib-win.marker" && -f "$tmp/o1/aib-win/run-all.ps1" && -f "$tmp/o1/manifest.txt" ]] \
   && ! ls -d "$tmp"/o1/.work.* >/dev/null 2>&1; then
  pass "build outputs + 临时目录已清理"
else
  fail "build outputs"
fi
if python3 - "$tmp/o1/ventoy/ventoy.auto_install.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
e = d["auto_install"]
assert list(d) == ["auto_install"] and len(e) == 1, d
e = e[0]
assert e["image"] == "/ISO/Win11_test.iso"
assert e["template"] == ["/ventoy/script/aib-win-safe.xml", "/ventoy/script/aib-win-autodisk.xml"]
assert e["autosel"] == 1 and e["timeout"] == 10
PY
then pass "ventoy.json snippet"; else fail "ventoy.json snippet"; fi
if bash tools/build-win-ventoy.sh --out "$tmp/o0" >/dev/null 2>&1; then fail "无 --iso 且无 --ventoy-image 应失败"; else pass "无 --iso 需 --ventoy-image"; fi
if bash tools/build-win-ventoy.sh --out "$tmp/o0" --ventoy-image /x.iso --autosel 5 >/dev/null 2>&1; then fail "--autosel 5 应失败"; else pass "--autosel 校验"; fi

echo "== win: merge-ventoy-json =="
cat > "$tmp/usb/ventoy/ventoy.json" <<'JSON'
{
  "control": [{"VTOY_DEFAULT_MENU_MODE": "0"}],
  "auto_install": [
    {"image": "/ISO/ubuntu-24.04-desktop-offline-auto.iso", "template": "/ventoy/script/ubuntu.yaml"},
    {"image": "/ISO/Win11_test.iso", "template": "/ventoy/script/old.xml"}
  ]
}
JSON
if python3 tools/merge-ventoy-json.py --snippet "$tmp/o1/ventoy/ventoy.auto_install.json" --target "$tmp/usb/ventoy/ventoy.json" 2>/dev/null \
   && python3 tools/merge-ventoy-json.py --snippet "$tmp/o1/ventoy/ventoy.auto_install.json" --target "$tmp/usb/ventoy/ventoy.json" 2>/dev/null \
   && python3 - "$tmp/usb/ventoy/ventoy.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["control"] == [{"VTOY_DEFAULT_MENU_MODE": "0"}], d
imgs = [e["image"] for e in d["auto_install"]]
assert imgs == ["/ISO/ubuntu-24.04-desktop-offline-auto.iso", "/ISO/Win11_test.iso"], imgs
assert d["auto_install"][1]["template"][0] == "/ventoy/script/aib-win-safe.xml"
PY
then
  pass "merge 保留 Ubuntu 条目 + 其它键, 替换同 image, 幂等"
else
  fail "merge-ventoy-json"
fi
if [[ -f "$tmp/usb/ventoy/ventoy.json.bak" ]]; then pass "merge 写 .bak"; else fail "merge 写 .bak"; fi
if python3 tools/merge-ventoy-json.py --snippet "$tmp/o1/ventoy/ventoy.auto_install.json" --target "$tmp/usb/new/ventoy.json" 2>/dev/null \
   && [[ -f "$tmp/usb/new/ventoy.json" ]]; then pass "merge 新建"; else fail "merge 新建"; fi

echo "== win: build-win-ventoy (假 ISO + 假 install.wim) =="
if command -v wimlib-imagex >/dev/null && command -v 7z >/dev/null && command -v xorriso >/dev/null; then
  mkdir -p "$tmp/wimsrc/Windows" "$tmp/isotree/sources"
  echo fake > "$tmp/wimsrc/Windows/readme.txt"
  wimlib-imagex capture "$tmp/wimsrc" "$tmp/isotree/sources/install.wim" "Windows 11 Home" --compress=none >/dev/null
  wimlib-imagex append "$tmp/wimsrc" "$tmp/isotree/sources/install.wim" "Windows 11 Pro" >/dev/null
  xorriso -as mkisofs -quiet -V FAKE_WIN -J -r -o "$tmp/Win11_fake.iso" "$tmp/isotree" 2>/dev/null
  sha="$(sha256sum "$tmp/Win11_fake.iso" | awk '{print $1}')"
  if AIB_WIN_PASSWORD="$SENTINEL" bash tools/build-win-ventoy.sh --iso "$tmp/Win11_fake.iso" --iso-sha256 "${sha^^}" \
       --out "$tmp/o2" >"$tmp/b2.out" 2>"$tmp/b2.err"; then
    pass "build (fake ISO, sha ok)"
  else
    fail "build (fake ISO)"; cat "$tmp/b2.err" >&2
  fi
  no_leak "build (fake ISO)" "$tmp/b2.out" "$tmp/b2.err" "$tmp/o2/manifest.txt"
  if grep -q '  - Windows 11 Home' "$tmp/o2/manifest.txt" && grep -q '  - Windows 11 Pro' "$tmp/o2/manifest.txt" \
     && grep -q "iso_sha256: $sha (verified)" "$tmp/o2/manifest.txt" && grep -q '"image": "/ISO/Win11_fake.iso"' "$tmp/o2/ventoy/ventoy.auto_install.json"; then
    pass "manifest editions + sha + 默认 image 路径"
  else
    fail "manifest"
  fi
  if [[ "$(sha256sum "$tmp/Win11_fake.iso" | awk '{print $1}')" == "$sha" ]]; then pass "ISO 未被修改"; else fail "ISO 被修改"; fi
  if bash tools/build-win-ventoy.sh --iso "$tmp/Win11_fake.iso" --iso-sha256 "$(printf '0%.0s' {1..64})" --out "$tmp/o3" >/dev/null 2>&1; then
    fail "错误 sha 应失败"
  else
    pass "错误 sha 失败"
  fi
  if bash tools/build-win-ventoy.sh --iso "$tmp/Win11_fake.iso" --edition "Windows 11 Enterprise" --out "$tmp/o4" >/dev/null 2>"$tmp/b4.err"; then
    fail "不存在的版本应失败"
  else
    if grep -q '不在 ISO 的版本列表里' "$tmp/b4.err"; then pass "不存在的版本失败"; else fail "版本失败提示"; fi
  fi
else
  echo "(wimlib-imagex / 7z / xorriso 不全, 假 ISO 端到端跳过)"
fi

if [[ "$FAIL" -ne 0 ]]; then echo "win-check: FAILED" >&2; exit 1; fi
echo "win-check: ALL PASS"
