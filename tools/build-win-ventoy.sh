#!/usr/bin/env bash
# =============================================================================
# build-win-ventoy.sh — 生成 Windows 11 无人值守的 Ventoy 交付物 (不修改官方 ISO)
#
# 产出目录 (拷到 Ventoy U 盘根目录即可, 与 Ubuntu 条目共存):
#   OUT/ventoy/script/aib-win-safe.xml       默认: 停在安装位置页, 由人选盘 (不抹盘)
#   OUT/ventoy/script/aib-win-autodisk.xml   危险: 抹第一块非 Ventoy 盘 ($$VT_WINDOWS_DISK_1ST_NONVTOY$$)
#   OUT/ventoy/ventoy.auto_install.json      auto_install 片段 (用 tools/merge-ventoy-json.py 合并进 /ventoy/ventoy.json)
#   OUT/aib-win/                             payload: marker + run-all.ps1 + scripts/ (specialize 阶段复制到 C:\aib)
#   OUT/manifest.txt                         ISO sha256 / 版本列表 / 参数 (不含密码)
#
# 用法:
#   tools/build-win-ventoy.sh --iso Win11_26H2_Chinese_Simplified_x64.iso --iso-sha256 B795B52D... --out out/win-ventoy
#   AIB_WIN_PASSWORD='...' tools/build-win-ventoy.sh --iso ... --out ... --hostname WIN-DEV --username alice
#
# 选项:
#   --iso FILE           官方 ISO (只读; 用于 sha256 校验与列出版本, 可不给)
#   --iso-sha256 HEX     期望的 SHA256 (微软下载页给出), 不匹配立即失败
#   --out DIR            输出目录 (必填; 已存在时覆盖其中的 aib-win/ 与 ventoy/ 产物)
#   --ventoy-image PATH  ventoy.json 里 image 的 U 盘内路径 (默认 /ISO/<ISO 文件名>; 没给 --iso 时必填)
#   --hostname H         默认 WIN-AIB (<=15 字节)
#   --username U         默认 ubuntu
#   --password P         明文 (会进 shell 历史, 调试用); 推荐环境变量 AIB_WIN_PASSWORD 或 --password-file
#   --password-file F    从文件读密码 (首行)
#   --locale L           默认 zh-CN (UILanguage 须与 ISO 语言一致)
#   --timezone TZ        默认 "China Standard Time"
#   --edition NAME       默认 "Windows 11 Pro" (/IMAGE/NAME); 给了 --iso 时会核对 install.wim/esd 里是否存在
#   --skip-edition-check 不解包 install.wim/esd 列版本 (省 5-7GB 临时空间)
#   --autosel N          ventoy.json autosel: 0 不用模板 / 1 safe (默认) / 2 autodisk
#   --timeout S          ventoy.json timeout (默认 10 秒后按 autosel 选择)
#   --disk-id ID         autodisk 目标盘: ventoy-nonvtoy (默认) / ventoy-nonusb / 整数 (非 Ventoy)
#   --plaintext-password XML 里 PlainText=true (默认 false, SIM 同款混淆; 都不是加密)
# =============================================================================
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf '[fail] %s\n' "$*" >&2; exit 1; }
info() { printf '[info] %s\n' "$*" >&2; }
usage() { sed -n '3,/^# ====*$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

ISO="" ISO_SHA="" OUT="" VIMAGE="" HOSTNAME_="WIN-AIB" USERNAME_="ubuntu" PASSWORD_="" PASSWORD_FILE=""
LOCALE="zh-CN" TIMEZONE="China Standard Time" EDITION="Windows 11 Pro" SKIP_EDITION=0
AUTOSEL=1 TIMEOUT=10 DISK_ID="ventoy-nonvtoy" PLAINTEXT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) ISO="${2:?}"; shift 2 ;;
    --iso-sha256) ISO_SHA="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --ventoy-image) VIMAGE="${2:?}"; shift 2 ;;
    --hostname) HOSTNAME_="${2:?}"; shift 2 ;;
    --username) USERNAME_="${2:?}"; shift 2 ;;
    --password) PASSWORD_="${2:?}"; shift 2 ;;
    --password-file) PASSWORD_FILE="${2:?}"; shift 2 ;;
    --locale) LOCALE="${2:?}"; shift 2 ;;
    --timezone) TIMEZONE="${2:?}"; shift 2 ;;
    --edition) EDITION="${2:?}"; shift 2 ;;
    --skip-edition-check) SKIP_EDITION=1; shift ;;
    --autosel) AUTOSEL="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --disk-id) DISK_ID="${2:?}"; shift 2 ;;
    --plaintext-password) PLAINTEXT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1 (见 --help)" ;;
  esac
done

[[ -n "$OUT" ]] || die "--out 必填"
[[ "$AUTOSEL" =~ ^[0-2]$ ]] || die "--autosel 只能是 0/1/2"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout 必须是非负整数"
if [[ -n "$ISO" ]]; then
  [[ -f "$ISO" ]] || die "ISO 不存在: $ISO"
  [[ -n "$VIMAGE" ]] || VIMAGE="/ISO/$(basename -- "$ISO")"
else
  [[ -n "$VIMAGE" ]] || die "没给 --iso 时必须给 --ventoy-image (U 盘上 ISO 的路径, 如 /ISO/Win11_26H2_Chinese_Simplified_x64.iso)"
  [[ -z "$ISO_SHA" ]] || die "--iso-sha256 需要配合 --iso"
  SKIP_EDITION=1
fi
[[ "$VIMAGE" == /* ]] || die "--ventoy-image 必须是 U 盘根目录起的绝对路径: $VIMAGE"

ISO_SHA_ACTUAL=""
if [[ -n "$ISO" ]]; then
  iso_before="$(stat -c '%s %Y' -- "$ISO")"
  if [[ -n "$ISO_SHA" ]]; then
    want="$(printf '%s' "$ISO_SHA" | tr 'A-F' 'a-f')"
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "--iso-sha256 不是 64 位十六进制"
    info "计算 ISO SHA256 (数 GB, 需要一两分钟)..."
    ISO_SHA_ACTUAL="$(sha256sum -- "$ISO" | awk '{print $1}')"
    [[ "$ISO_SHA_ACTUAL" == "$want" ]] || die "ISO SHA256 不匹配: 期望 $want, 实际 $ISO_SHA_ACTUAL"
    info "ISO SHA256 校验通过"
  fi
fi

mkdir -p "$OUT"
OUT="$(cd -- "$OUT" && pwd)"
WORK="$(mktemp -d "$OUT/.work.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

EDITIONS=""
if [[ -n "$ISO" && "$SKIP_EDITION" -eq 0 ]]; then
  command -v 7z >/dev/null || die "缺 7z (7zip 包; Windows ISO 的大文件只在 UDF 里, xorriso 读不到)。或用 --skip-edition-check"
  command -v wimlib-imagex >/dev/null || die "缺 wimlib-imagex (wimtools 包)。或用 --skip-edition-check"
  listing="$(7z l -ba -- "$ISO" 2>/dev/null || true)"
  img=""
  for cand in sources/install.wim sources/install.esd; do
    if grep -qiE "[[:space:]]${cand//./\\.}\$" <<<"$listing"; then img="$cand"; break; fi
  done
  [[ -n "$img" ]] || die "ISO 里没找到 sources/install.wim / install.esd (split .swm 暂不支持; 可 --skip-edition-check)"
  info "解出 $img 列版本 (只读 ISO, 临时文件在 $WORK)..."
  7z e -y -bso0 -bsp0 -o"$WORK" -- "$ISO" "$img" >/dev/null || die "7z 解出 $img 失败"
  EDITIONS="$(wimlib-imagex info "$WORK/$(basename -- "$img")" | sed -n 's/^Name:[[:space:]]*//p')"
  rm -f -- "$WORK/$(basename -- "$img")"
  [[ -n "$EDITIONS" ]] || die "wimlib-imagex 没列出任何版本"
  info "ISO 内版本 (/IMAGE/NAME):"
  while IFS= read -r e; do printf '  - %s\n' "$e" >&2; done <<<"$EDITIONS"
  grep -Fxq -- "$EDITION" <<<"$EDITIONS" || die "--edition '$EDITION' 不在 ISO 的版本列表里 (见上)"
fi

# ---------------------------------------------------------------- XML
render_args=(--out-dir "$OUT/ventoy/script" --prefix aib-win --hostname "$HOSTNAME_" --username "$USERNAME_"
  --locale "$LOCALE" --timezone "$TIMEZONE" --edition "$EDITION" --disk-id "$DISK_ID")
[[ -n "$PASSWORD_FILE" ]] && render_args+=(--password-file "$PASSWORD_FILE")
[[ "$PLAINTEXT" -eq 1 ]] && render_args+=(--plaintext-password)
mkdir -p "$OUT/ventoy/script"
if [[ -n "$PASSWORD_" && -z "${AIB_WIN_PASSWORD:-}" ]]; then
  # 明文参数改走环境变量传给 python, 不出现在子进程 argv
  AIB_WIN_PASSWORD="$PASSWORD_" python3 "$ROOT/tools/render-unattend.py" "${render_args[@]}" >&2
else
  python3 "$ROOT/tools/render-unattend.py" "${render_args[@]}" >&2
fi

# ---------------------------------------------------------------- ventoy.json 片段
python3 - "$OUT/ventoy/ventoy.auto_install.json" "$VIMAGE" "$AUTOSEL" "$TIMEOUT" <<'PY'
import json, sys
out, image, autosel, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
snippet = {"auto_install": [{
    "image": image,
    "template": ["/ventoy/script/aib-win-safe.xml", "/ventoy/script/aib-win-autodisk.xml"],
    "autosel": autosel,
    "timeout": timeout,
}]}
with open(out, "w", encoding="utf-8") as f:
    json.dump(snippet, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

# ---------------------------------------------------------------- payload
rm -rf -- "$OUT/aib-win"
cp -R -- "$ROOT/windows/payload" "$OUT/aib-win"
[[ -f "$OUT/aib-win/aib-win.marker" && -f "$OUT/aib-win/run-all.ps1" ]] || die "payload 不完整"

# ---------------------------------------------------------------- manifest (不含密码)
{
  echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "builder_revision: $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "${AIB_VERSION:-unknown}")"
  echo "ventoy_image: $VIMAGE"
  [[ -n "$ISO" ]] && echo "iso_file: $(basename -- "$ISO")"
  [[ -n "$ISO_SHA_ACTUAL" ]] && echo "iso_sha256: $ISO_SHA_ACTUAL (verified)"
  echo "edition: $EDITION"
  if [[ -n "$EDITIONS" ]]; then
    echo "iso_editions:"
    while IFS= read -r e; do printf '  - %s\n' "$e"; done <<<"$EDITIONS"
  fi
  echo "hostname: $HOSTNAME_"
  echo "username: $USERNAME_"
  echo "locale: $LOCALE"
  echo "timezone: $TIMEZONE"
  echo "autodisk_disk_id: $DISK_ID"
  echo "ventoy_autosel: $AUTOSEL (0=none 1=safe 2=autodisk)  timeout: $TIMEOUT"
} > "$OUT/manifest.txt"

if [[ -n "$ISO" ]]; then
  [[ "$(stat -c '%s %Y' -- "$ISO")" == "$iso_before" ]] || die "ISO 被修改了 (不应发生)"
fi

cat >&2 <<MSG
[ok] 产出: $OUT
     ventoy/script/aib-win-safe.xml  ventoy/script/aib-win-autodisk.xml
     ventoy/ventoy.auto_install.json  aib-win/  manifest.txt
下一步 (<U盘> = Ventoy 数据分区挂载点):
  mkdir -p <U盘>/ventoy/script && cp "$OUT"/ventoy/script/aib-win-*.xml <U盘>/ventoy/script/
  cp -r "$OUT/aib-win" <U盘>/
  python3 tools/merge-ventoy-json.py --snippet "$OUT/ventoy/ventoy.auto_install.json" --target <U盘>/ventoy/ventoy.json
  官方 ISO 原样放到 <U盘>$VIMAGE
MSG
