#!/bin/bash
# write-authorized-keys.sh — late-command helper
# Subiquity ssh.authorized-keys 偶发未落到用户家目录; 本脚本从 ISO 种子再写一遍。
#
# 用法 (安装器环境, 目标根在 /target):
#   bash /cdrom/nocloud/write-authorized-keys.sh <username> [keys-file]
set -euo pipefail

USER_NAME="${1:-}"
KEYS_FILE="${2:-/cdrom/nocloud/authorized_keys}"
TARGET="${TARGET:-/target}"

if [ -z "$USER_NAME" ]; then
  echo "usage: $0 <username> [keys-file]" >&2
  exit 2
fi
if [ ! -f "$KEYS_FILE" ]; then
  echo "write-authorized-keys: keys file missing ($KEYS_FILE), skip"
  exit 0
fi
# 无有效公钥则跳过
if ! grep -vE '^[[:space:]]*(#|$)' "$KEYS_FILE" | grep -q .; then
  echo "write-authorized-keys: no keys in $KEYS_FILE, skip"
  exit 0
fi

PASSWD="$TARGET/etc/passwd"
if [ ! -f "$PASSWD" ]; then
  echo "write-authorized-keys: $PASSWD missing" >&2
  exit 1
fi
ent="$(awk -F: -v u="$USER_NAME" '$1==u {print; exit}' "$PASSWD" || true)"
if [ -z "$ent" ]; then
  echo "write-authorized-keys: user $USER_NAME not in $PASSWD" >&2
  exit 1
fi
uid="$(echo "$ent" | cut -d: -f3)"
gid="$(echo "$ent" | cut -d: -f4)"
home="$(echo "$ent" | cut -d: -f6)"
# passwd home is absolute on target, e.g. /home/ops
ssh_dir="$TARGET$home/.ssh"
keys_out="$ssh_dir/authorized_keys"

mkdir -p "$ssh_dir"
# 只写入非空非注释行
grep -vE '^[[:space:]]*(#|$)' "$KEYS_FILE" > "$keys_out"
chown -R "$uid:$gid" "$ssh_dir"
chmod 700 "$ssh_dir"
chmod 600 "$keys_out"
echo "write-authorized-keys: wrote $(wc -l < "$keys_out") key(s) -> $keys_out (uid=$uid gid=$gid)"
