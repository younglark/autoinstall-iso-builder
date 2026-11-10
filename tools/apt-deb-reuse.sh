#!/usr/bin/env bash
# apt-deb-reuse.sh — fetch-offline-bundle 的 deb 复用 helper (被 source; 也给 test/local-check.sh 单测)
#
# 需求清单 NEED_LIST 每行: <文件名> <大小> <算法:哈希>  (即 apt-get --print-uris 的后三列,
# 哈希来自 Packages 索引)。只有「文件名相同 + 大小相同 + 哈希一致」才复用, 放进 apt 的
# archives 目录后 apt 会再按索引确认并跳过下载。

# aib_deb_hash_ok FILE "SHA256:hex"
aib_deb_hash_ok() {
  local f="$1" spec="$2" algo hex
  algo="${spec%%:*}"; hex="${spec#*:}"
  case "$algo" in
    SHA256) [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$hex" ] ;;
    SHA512) [ "$(sha512sum "$f" | cut -d' ' -f1)" = "$hex" ] ;;
    MD5Sum|MD5) [ "$(md5sum "$f" | cut -d' ' -f1)" = "$hex" ] ;;
    *) return 1 ;;
  esac
}

# aib_deb_seed NEED_LIST ARCHIVES REUSED_LIST SRC_DIR...
#   把各 SRC_DIR 里校验通过的需求文件拷进 ARCHIVES, 文件名追加到 REUSED_LIST; 输出复用个数
aib_deb_seed() {
  local need="$1" archives="$2" reused_list="$3" n=0 fn size hash src
  shift 3
  : >> "$reused_list"
  while read -r fn size hash; do
    [ -n "$fn" ] || continue
    case "$fn" in */*|.*) continue ;; esac
    [ -e "$archives/$fn" ] && continue
    for src in "$@"; do
      if [ -z "$src" ] || [ ! -f "$src/$fn" ]; then continue; fi
      [ "$(stat -c %s "$src/$fn")" = "$size" ] || continue
      aib_deb_hash_ok "$src/$fn" "$hash" || continue
      cp -p "$src/$fn" "$archives/$fn"
      echo "$fn" >> "$reused_list"
      n=$((n + 1))
      break
    done
  done < "$need"
  echo "$n"
}

# aib_deb_sync_cache ARCHIVES CACHE_DIR REUSED_LIST PRUNE(0|1)
#   新下载 (或缓存里内容不同) 的 deb 写回缓存; PRUNE=1 时删掉缓存里本次没用到的。输出 "synced pruned"
aib_deb_sync_cache() {
  local archives="$1" cache="$2" reused_list="$3" prune="${4:-0}" synced=0 pruned=0 f b
  mkdir -p "$cache"
  for f in "$archives"/*.deb; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    if [ -f "$cache/$b" ] && grep -qxF "$b" "$reused_list" 2>/dev/null; then continue; fi
    cmp -s "$f" "$cache/$b" 2>/dev/null && continue
    cp -p "$f" "$cache/$b.tmp" && mv -f "$cache/$b.tmp" "$cache/$b"
    synced=$((synced + 1))
  done
  if [ "$prune" = "1" ]; then
    for f in "$cache"/*.deb; do
      [ -f "$f" ] || continue
      [ -f "$archives/$(basename "$f")" ] && continue
      rm -f "$f"
      pruned=$((pruned + 1))
    done
  fi
  echo "$synced $pruned"
}
