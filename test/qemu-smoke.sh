#!/usr/bin/env bash
# =============================================================================
# qemu-smoke.sh — 在虚拟机里真跑一遍装机, 验证 autoinstall ISO 是否可用
#
# 装机约 8-15 分钟 (取决于机器)。要求 ISO 用 --auto-disk 构建
# (interactive-sections: [])，装完关机 (poweroff + -no-reboot)，
# 随后用 libguestfs 直接读目标盘里的包清单做断言 —— 这是唯一可信的验收方式。
#
# 选项:
#   --uefi          UEFI 固件
#   --offline-nic   不给虚拟机网卡 (验证全离线捆绑; 需 ISO 已含 /offline)
#   --guard-only    只检查 ISO 的 interactive-sections，不启动 QEMU（给 local-check 用）
# =============================================================================
set -Eeuo pipefail

ISO="${1:-}"
shift || true
MODE="bios"
OFFLINE_NIC=0
GUARD_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --uefi) MODE="uefi" ;;
    --offline-nic) OFFLINE_NIC=1 ;;
    --guard-only) GUARD_ONLY=1 ;;
  esac
done

if [[ -z "$ISO" || ! -f "$ISO" ]]; then
  echo "用法: $0 <iso> [--uefi] [--offline-nic] [--guard-only]" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 从 ISO 抽出 /nocloud/user-data（优先 xorriso；回退 isoinfo / bsdtar）
# ---------------------------------------------------------------------------
extract_user_data() {
  local iso="$1" dest="$2"
  local tmp_extract out
  tmp_extract="$(mktemp -d -t qemu-smoke-ud-XXXXXX)"

  cleanup_extract() { rm -rf "$tmp_extract"; }
  # 注意：不用 RETURN trap，避免与外层函数互相覆盖

  if command -v xorriso >/dev/null 2>&1; then
    # 抽整个 nocloud 目录最稳妥
    if xorriso -osirrox on -indev "$iso" -extract /nocloud "$tmp_extract/nocloud" >/dev/null 2>&1 \
      && [[ -f "$tmp_extract/nocloud/user-data" ]]; then
      cp "$tmp_extract/nocloud/user-data" "$dest"
      cleanup_extract
      return 0
    fi
    # 某些构建把路径写成无前导斜杠
    if xorriso -osirrox on -indev "$iso" -extract nocloud "$tmp_extract/nocloud" >/dev/null 2>&1 \
      && [[ -f "$tmp_extract/nocloud/user-data" ]]; then
      cp "$tmp_extract/nocloud/user-data" "$dest"
      cleanup_extract
      return 0
    fi
  fi

  if command -v isoinfo >/dev/null 2>&1; then
    out="$(isoinfo -R -i "$iso" -x "/nocloud/user-data" 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      printf '%s' "$out" >"$dest"
      cleanup_extract
      return 0
    fi
  fi

  if command -v bsdtar >/dev/null 2>&1; then
    if bsdtar -xOf "$iso" nocloud/user-data >"$dest" 2>/dev/null && [[ -s "$dest" ]]; then
      cleanup_extract
      return 0
    fi
  fi

  cleanup_extract
  return 1
}

# 非空 interactive-sections → 拒绝进入长时间 QEMU 等待
refuse_interactive_iso() {
  local iso="$1"
  local ud result
  ud="$(mktemp -t qemu-smoke-userdata-XXXXXX)"

  if ! extract_user_data "$iso" "$ud"; then
    rm -f "$ud"
    echo "[FAIL] 无法从 ISO 读取 /nocloud/user-data（需要 xorriso 或 isoinfo/bsdtar）" >&2
    echo "       apt install xorriso" >&2
    return 1
  fi

  # 退出码: 0=OK, 2=interactive；stdout: OK|... 或 INTERACTIVE|a,b
  set +e
  result="$(python3 - "$ud" <<'PY'
import sys

path = sys.argv[1]
try:
    import yaml  # type: ignore
except ImportError:
    yaml = None

def emit_ok(kind: str) -> None:
    print(f"OK|{kind}")
    sys.exit(0)

def emit_interactive(items) -> None:
    if isinstance(items, (list, tuple)):
        print("INTERACTIVE|" + ",".join(str(x) for x in items))
    else:
        print("INTERACTIVE|" + str(items))
    sys.exit(2)

if yaml is not None:
    doc = yaml.safe_load(open(path, encoding="utf-8"))
    ai = (doc or {}).get("autoinstall") or {}
    isec = ai.get("interactive-sections")
    if isec is None:
        emit_ok("missing")
    if isinstance(isec, (list, tuple)):
        if len(isec) == 0:
            emit_ok("empty")
        emit_interactive(isec)
    if isec:
        emit_interactive(isec)
    emit_ok("empty")

# 无 PyYAML：极简启发式
import re

text = open(path, encoding="utf-8", errors="replace").read()
m = re.search(
    r"(?m)^[ \t]*interactive-sections:[ \t]*(.*?)(?=\n[ \t]*\S|\Z)",
    text,
    re.S,
)
if not m:
    emit_ok("missing")
body = m.group(1).strip()
if body in ("", "[]", "~", "null", "Null", "NULL"):
    emit_ok("empty")
items = re.findall(r"(?m)^[ \t]*-[ \t]+(\S+)", "\n" + body)
if items:
    emit_interactive(items)
if body and body != "[]":
    emit_interactive(body.replace("\n", " "))
emit_ok("empty")
PY
)"
  py_rc=$?
  set -e
  rm -f "$ud"

  if [[ "$py_rc" -eq 2 || "$result" == INTERACTIVE\|* ]]; then
    local sections="${result#INTERACTIVE|}"
    echo "[FAIL] 此 ISO 的 interactive-sections 非空: [${sections}]" >&2
    echo "       冒烟测试是无人值守的：Subiquity 会停在选盘页，QEMU 会空等直至超时。" >&2
    echo "       请用 --auto-disk 重新构建 ISO 后再跑：" >&2
    echo "         ./build-iso.sh ... --auto-disk" >&2
    echo "         bash test/qemu-smoke.sh <新 iso> ..." >&2
    return 2
  fi
  if [[ "$py_rc" -ne 0 || "$result" != OK\|* ]]; then
    echo "[FAIL] 无法解析 interactive-sections（rc=$py_rc got: ${result:-<empty>}）" >&2
    return 1
  fi
  echo "==> interactive-sections 检查通过 (${result#OK|})"
  return 0
}

echo "==> 检查 ISO autoinstall 是否可无人值守..."
# set -e：失败时直接带函数退出码结束（已打印说明）
refuse_interactive_iso "$ISO"

if [[ "$GUARD_ONLY" -eq 1 ]]; then
  echo "==> --guard-only：跳过 QEMU"
  exit 0
fi

command -v qemu-system-x86_64 >/dev/null || { echo "缺少 qemu: apt install qemu-system-x86"; exit 1; }

WORKDIR="$(mktemp -d -t qemu-smoke-XXXXXX)"
DISK="$WORKDIR/disk.qcow2"
LOG="$WORKDIR/serial.log"

# Desktop 24.04 建议 QEMU_MEM=8192 QEMU_DISK=40G (GUI 安装器 + standard 源更吃内存/磁盘)
qemu-img create -f qcow2 "$DISK" "${QEMU_DISK:-30G}" >/dev/null

QEMU_ARGS=(
  -m "${QEMU_MEM:-4096}" -smp "${QEMU_SMP:-2}" -machine q35
  -drive file="$DISK",if=virtio,format=qcow2
  -cdrom "$ISO"
  -boot order=d,menu=off
  -display none -serial file:"$LOG" -monitor none
  -no-reboot
)
# Probe KVM: nested/broken hosts hang with 0% CPU and empty serial. Fall back to TCG.
if [[ "${FORCE_TCG:-0}" != 1 ]] && { [[ -e /dev/kvm ]] || [[ -c /dev/kvm ]]; }; then
  if timeout 5 qemu-system-x86_64 -enable-kvm -cpu host -m 256 -nographic -monitor none -nic none 2>/dev/null \
       | grep -q SeaBIOS; then
    QEMU_ARGS+=(-enable-kvm -cpu host)
    echo "==> KVM 可用"
  else
    echo "==> /dev/kvm 存在但不可用 (探测无 SeaBIOS), 改用 TCG (会很慢)"
  fi
else
  echo "==> TCG 模式 (无 KVM 或 FORCE_TCG=1)"
fi

if [[ "$OFFLINE_NIC" -eq 1 ]]; then
  # 无网卡: 证明安装不依赖外网
  QEMU_ARGS+=(-nic none)
  echo "==> 离线网卡模式 (-nic none)"
else
  QEMU_ARGS+=(-nic user,model=virtio)
fi

if [[ "$MODE" == "uefi" ]]; then
  OVMF=""
  for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    [[ -f "$c" ]] && { OVMF="$c"; break; }
  done
  [[ -n "$OVMF" ]] || { echo "找不到 OVMF 固件, 改跑 BIOS: apt install ovmf"; exit 1; }
  cp "$OVMF" "$WORKDIR/OVMF_VARS.fd"
  QEMU_ARGS+=(
    -drive if=pflash,format=raw,readonly=on,file="$OVMF"
    -drive if=pflash,format=raw,file="$WORKDIR/OVMF_VARS.fd"
  )
  echo "==> UEFI 模式 (固件: $OVMF)"
else
  echo "==> BIOS 模式"
fi

echo "==> 串口日志: $LOG"
echo "==> 开始装机, 完成后自动退出..."
timeout "${QEMU_TIMEOUT:-7200}" qemu-system-x86_64 "${QEMU_ARGS[@]}" || echo "(qemu 退出码 $?)"

echo
if command -v virt-cat >/dev/null 2>&1; then
  echo "==> 装机清单 /var/log/autoinstall/manifest.txt:"
  virt-cat -a "$DISK" /var/log/autoinstall/manifest.txt 2>/dev/null | sed 's/^/    /' \
    || echo "    (缺失 —— 99-cleanup.sh 没跑到)"

  echo
  echo "==> 预装失败项 /var/log/autoinstall/provision-failed.txt:"
  FAILED="$(virt-cat -a "$DISK" /var/log/autoinstall/provision-failed.txt 2>/dev/null || true)"
  if [ -n "$FAILED" ]; then
    echo "$FAILED" | sed 's/^/    [!] /'
    echo "    ↑ 这些软件没装上, 日志在 /var/log/autoinstall/<脚本>.log"
  else
    echo "    无"
  fi

  echo
  echo "==> 关键可执行文件:"
  # sshd 在 /usr/sbin；unity/godot 在 /usr/local/bin；nvidia-ctk / gh / rg 多在 /usr/bin
  BINS="$( {
    virt-ls -a "$DISK" /usr/bin
    virt-ls -a "$DISK" /usr/sbin
    virt-ls -a "$DISK" /usr/local/bin
  } 2>/dev/null || true)"

  # 与 software/99-cleanup.sh 常见预装对齐；缺失只报告，不因此失败
  # （构建时 --skip 了对应脚本属于预期）
  EXPECTED_BINS=(
    git
    gh
    rg
    docker
    nvidia-ctk
    node
    npm
    grok
    opencode
    openmausbot
    unity
    godot
    gitea
    sshd
  )
  missing=0
  for b in "${EXPECTED_BINS[@]}"; do
    if echo "$BINS" | grep -qx "$b"; then
      printf '    %-14s ok\n' "$b"
    else
      printf '    %-14s MISSING\n' "$b"
      missing=$((missing + 1))
    fi
  done
  if [[ "$missing" -gt 0 ]]; then
    echo "    ↑ $missing 个预装工具未找到（若构建时 --skip 了对应脚本可忽略）"
  fi

  echo
  echo "==> Gitea (45-gitea.sh):"
  if virt-ls -a "$DISK" /etc/systemd/system/multi-user.target.wants 2>/dev/null | grep -qx 'gitea.service'; then
    echo "    gitea.service enabled"
  else
    echo "    [!] gitea.service 未 enable (若 --skip 45 可忽略)"
  fi
  GITEA_INI="$(virt-cat -a "$DISK" /etc/gitea/app.ini 2>/dev/null || true)"
  if grep -q '^INSTALL_LOCK = true' <<<"$GITEA_INI"; then
    echo "    app.ini INSTALL_LOCK = true"
    grep -E '^(HTTP_ADDR|HTTP_PORT|DB_TYPE|DISABLE_REGISTRATION) ' <<<"$GITEA_INI" | sed 's/^/    /'
  else
    echo "    [!] /etc/gitea/app.ini 缺失或无 INSTALL_LOCK (若 --skip 45 可忽略)"
  fi
  virt-ls -a "$DISK" /var/lib/gitea/data 2>/dev/null | grep -qx 'gitea.db' \
    && echo "    SQLite gitea.db 已初始化 (含管理员)"
  virt-ls -a "$DISK" /opt/provision 2>/dev/null | grep -qx 'gitea-admin.secret' \
    && echo "    [!] /opt/provision/gitea-admin.secret 仍在 (应已删除)"

  echo
  echo "==> Jenkins (30-jenkins.sh, 零配置):"
  if virt-ls -a "$DISK" /etc/systemd/system/multi-user.target.wants 2>/dev/null | grep -qx 'jenkins.service'; then
    echo "    jenkins.service enabled"
  else
    echo "    [!] jenkins.service 未 enable (若 --skip 30 可忽略)"
  fi
  if virt-cat -a "$DISK" /etc/systemd/system/jenkins.service.d/50-autoinstall.conf 2>/dev/null | grep -q 'runSetupWizard=false'; then
    echo "    安装向导已跳过 (drop-in runSetupWizard=false)"
  else
    echo "    [!] 缺 jenkins.service.d/50-autoinstall.conf (若 --skip 30 可忽略)"
  fi
  JPLUG="$(virt-ls -a "$DISK" /var/lib/jenkins/plugins 2>/dev/null | grep -c '\.jpi$' || true)"
  echo "    预装插件: ${JPLUG:-0} 个 .jpi"
  # 首次启动后 groovy 应已自删, 且 config.xml 启用安全
  if virt-ls -a "$DISK" /var/lib/jenkins/init.groovy.d 2>/dev/null | grep -q 'autoinstall-admin'; then
    echo "    [!] init.groovy.d/00-autoinstall-admin.groovy 仍在 (Jenkins 尚未首次启动成功?)"
  fi
  virt-cat -a "$DISK" /var/lib/jenkins/config.xml 2>/dev/null \
    | grep -E 'useSecurity|FullControlOnceLoggedIn|disableSignup' | sed 's/^ */    /'
  virt-ls -a "$DISK" /opt/provision 2>/dev/null | grep -qx 'jenkins-admin.secret' \
    && echo "    [!] /opt/provision/jenkins-admin.secret 仍在 (应已删除)"

  echo
  echo "==> SSH:"
  virt-ls -a "$DISK" /etc/ssh 2>/dev/null | grep -c 'ssh_host' \
    && echo "    SSH 主机密钥已生成"
  virt-cat -a "$DISK" /etc/hostname 2>/dev/null | sed 's/^/    hostname: /'
else
  echo "==> (未安装 libguestfs-tools, 无法自动断言; apt install libguestfs-tools)"
fi

echo
echo "==> 串口日志尾部:"
tail -n 30 "$LOG" || true
echo
echo "虚拟机与磁盘保留在: $WORKDIR"
