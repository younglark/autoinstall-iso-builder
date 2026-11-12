#!/bin/bash
# 13-no-dist-upgrade-prompt.sh — 关闭大版本发行版升级提示 (Prompt=never)
#
# Desktop / Server 默认生效，无开关。只改 /etc/update-manager/release-upgrades，
# 不关闭日常 Software Updater 弹窗、update-notifier、unattended-upgrades、
# 重启提示或 MOTD。
#
# ubuntu-release-upgrader 的 MetaReleaseCore 读到 Prompt=never（或 no）后立即
# 返回、不查询下一代发行版，因此 check-new-release / check-new-release-gtk
# 都不会认为有可升级版本。不必再 mask update-notifier-release.path。
# com.ubuntu.update-manager 的 check-dist-upgrades 已废弃（改读本文件）；
# show-dist-upgrade-notification 在 24.04 的 schema 里不存在，不写 override。
#
# 测试钩子: AIB_TARGET_ROOT=<dir> 把文件写到该前缀下。
set -euo pipefail

R="${AIB_TARGET_ROOT:-}"
FILE="$R/etc/update-manager/release-upgrades"
STAMP="$R/var/lib/ubuntu-release-upgrader/release-upgrade-available"

install -d -m 0755 "$(dirname "$FILE")"

if [ ! -f "$FILE" ]; then
  printf '%s\n' '[DEFAULT]' 'Prompt=never' > "$FILE"
else
  if grep -qE '^[[:space:]]*Prompt[[:space:]]*=' "$FILE"; then
    sed -i 's/^[[:space:]]*Prompt[[:space:]]*=.*/Prompt=never/' "$FILE"
  elif grep -qE '^[[:space:]]*\[DEFAULT\][[:space:]]*$' "$FILE"; then
    sed -i '/^[[:space:]]*\[DEFAULT\][[:space:]]*$/a Prompt=never' "$FILE"
  else
    printf '\n[DEFAULT]\nPrompt=never\n' >> "$FILE"
  fi
fi
chmod 0644 "$FILE"

# 装机过程一般不会有这份缓存；若已有非空戳记，清掉以免 MOTD/GTK 再展示一次旧结果。
# 不禁用 /etc/update-motd.d/91-release-upgrade 本身。
if [ -s "$STAMP" ]; then
  rm -f "$STAMP"
fi

echo "release-upgrades: Prompt=never ($FILE)"
