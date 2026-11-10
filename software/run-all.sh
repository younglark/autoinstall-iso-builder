#!/bin/bash
# run-all.sh — 在目标系统 chroot 内按序执行软件脚本
#
# 设计原则: 单个软件装失败不拖垮整台机器。失败的脚本单独记日志,
# 汇总写到 /var/log/autoinstall/provision-failed.txt, 装机结束后仍可登录排查。
# 需要"失败即中止"时, 在 provision.env 里设 STRICT=1。
#
# --skip 接受编号前缀或完整名: "30 70" 与 "30-jenkins 70-openmausbot" 均可。
# OFFLINE=1 时各脚本走 /opt/offline 本地源, 零外网请求。
set -uo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
LOG="${PROVISION_LOG:-/var/log/autoinstall}"
mkdir -p "$LOG"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export HOME=/root

# provision.env 由 build-iso.sh 生成
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
export PIN_UNITY_CLI="${PIN_UNITY_CLI:-}"
export PIN_GODOT="${PIN_GODOT:-4.7.2}"
export PIN_GITEA="${PIN_GITEA:-latest}"
export GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-}"
export GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-}"
export JENKINS_ADMIN_USER="${JENKINS_ADMIN_USER:-}"
export JENKINS_PLUGINS="${JENKINS_PLUGINS:-}"
export OFFLINE="${OFFLINE:-0}"
export OFFLINE_ROOT="${OFFLINE_ROOT:-/opt/offline}"
export EXTRA_APT_PACKAGES="${EXTRA_APT_PACKAGES:-}"
export EDITION="${EDITION:-server}"
export UBUNTU_MIRROR="${UBUNTU_MIRROR:-}"
STRICT="${STRICT:-0}"
PROVISION_SKIP="${PROVISION_SKIP:-}"

# 把 lib-offline.sh 放到 PATH 旁, 供子脚本 source
export PROVISION_LIB="$HERE/lib-offline.sh"

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
echo " provisioning target user=$TARGET_USER edition=${EDITION:-server} strict=$STRICT offline=$OFFLINE"
echo " pins: node>=$PIN_NODE_MAJOR grok=$PIN_GROK opencode=$PIN_OPENCODE openmausbot=$PIN_OPENMAUSBOT unity-cli=${PIN_UNITY_CLI:-latest} godot=$PIN_GODOT gitea=$PIN_GITEA"
[ -n "$PROVISION_SKIP" ] && echo " skipping: $PROVISION_SKIP"
[ -n "$EXTRA_APT_PACKAGES" ] && echo " extra apt: $EXTRA_APT_PACKAGES"
echo "=============================================================="

: > "$LOG/provision-failed.txt"
FAILED=""
DONE=""

# 确保 lib 可被数字脚本找到 (ISO 打包时一并复制)
if [ ! -f "$HERE/lib-offline.sh" ] && [ -f "${PROVISION_LIB:-}" ]; then
  cp -a "$PROVISION_LIB" "$HERE/lib-offline.sh" 2>/dev/null || true
fi

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

# Gitea 管理员明文密码文件: 45-gitea 用后会删; 被 --skip 或失败时这里兜底删除
rm -f "$HERE/gitea-admin.secret" "$HERE/jenkins-admin.secret"

echo "--------------------------------------------------------------"
echo "完成:$DONE"
if [ -n "$FAILED" ]; then
  echo "失败:$FAILED"
  echo "日志:$LOG/<脚本名>.log   汇总:$LOG/provision-failed.txt"
  [ "$STRICT" = "1" ] && exit 1
fi
echo "--------------------------------------------------------------"
exit 0
