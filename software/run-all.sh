#!/bin/bash
# run-all.sh — 在目标系统 chroot 内按序执行软件脚本
#
# 设计原则: 单个软件装失败不拖垮整台机器。失败的脚本单独记日志,
# 汇总写到 /var/log/autoinstall/provision-failed.txt, 装机结束后仍可登录排查。
# 需要"失败即中止"时, 在 provision.env 里设 STRICT=1。
#
# --skip 接受编号前缀或完整名: "30 70" 与 "30-jenkins 70-openmausbot" 均可。
set -uo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
LOG="${PROVISION_LOG:-/var/log/autoinstall}"
mkdir -p "$LOG"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export HOME=/root

# provision.env 由 build-iso.sh 生成, 带 TARGET_USER / STRICT / PROVISION_SKIP / PIN_* / SSH_ALLOW_PW
if [ -f "$HERE/provision.env" ]; then
  # shellcheck disable=SC1091
  . "$HERE/provision.env"
fi
export TARGET_USER="${TARGET_USER:-root}"
export SSH_ALLOW_PW="${SSH_ALLOW_PW:-true}"
export PIN_NODE_MAJOR="${PIN_NODE_MAJOR:-24}"
export PIN_GROK="${PIN_GROK:-latest}"
export PIN_OPENCODE="${PIN_OPENCODE:-latest}"
export PIN_OPENMAUSBOT="${PIN_OPENMAUSBOT:-latest}"
STRICT="${STRICT:-0}"
PROVISION_SKIP="${PROVISION_SKIP:-}"

# 接受编号前缀 (30) 或完整脚本名 (30-jenkins)
should_skip() {
  local name="$1" tok
  # shellcheck disable=SC2086
  for tok in $PROVISION_SKIP; do
    [ -z "$tok" ] && continue
    case "$name" in
      "$tok"|"$tok"-*) return 0 ;;
    esac
  done
  return 1
}

echo "=============================================================="
echo " provisioning target user=$TARGET_USER strict=$STRICT"
echo " pins: node>=$PIN_NODE_MAJOR grok=$PIN_GROK opencode=$PIN_OPENCODE openmausbot=$PIN_OPENMAUSBOT"
[ -n "$PROVISION_SKIP" ] && echo " skipping: $PROVISION_SKIP"
echo "=============================================================="

: > "$LOG/provision-failed.txt"
FAILED=""
DONE=""

shopt -s nullglob
for s in "$HERE"/[0-9][0-9]-*.sh; do
  name="$(basename "$s" .sh)"

  if should_skip "$name"; then
    echo "==> $name  [skipped]"
    continue
  fi

  printf '==> %-22s ' "$name"
  if bash "$s" >"$LOG/${name}.log" 2>&1; then
    echo "ok"
    DONE="$DONE $name"
  else
    echo "FAILED"
    echo "$name" >> "$LOG/provision-failed.txt"
    FAILED="$FAILED $name"
    tail -n 12 "$LOG/${name}.log" | sed 's/^/      | /'
  fi
done

echo "--------------------------------------------------------------"
echo "完成:$DONE"
if [ -n "$FAILED" ]; then
  echo "失败:$FAILED"
  echo "日志:$LOG/<脚本名>.log   汇总:$LOG/provision-failed.txt"
  [ "$STRICT" = "1" ] && exit 1
fi
echo "--------------------------------------------------------------"
exit 0
