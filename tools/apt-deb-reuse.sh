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

# ---- 内核类包过滤 (NVIDIA 预编译模块 / 内核 meta 的虚包、替代依赖) ----
# apt-cache depends --recurse 会把 "A | B" 的所有替代、虚包的所有 Provides 都展开:
# linux-modules-nvidia-595-open-generic 的 nvidia-dkms-595-open 等虚包会拉进 aws/azure/gcp/oracle/
# lowlatency/nvidia/6.14 hwe … 全部 flavour 的 linux-image / linux-modules / 预编译模块 (每个 ~150MB)。
# 内核类包只保留 apt 求解器为 SEEDS (pkg=ver 锁版本) 实际解析出的那些 (= 选定 flavour + 其 ABI)。

# aib_deb_pkg_name: stdin 每行 "<文件名> ..." (pkg_ver_arch.deb) → 包名
aib_deb_pkg_name() {
  awk 'NF { n = $1; sub(/_.*/, "", n); if (n != "") print n }'
}

# aib_is_kernel_pkg NAME: 内核 / 内核模块 / 头文件 / 工具 / 内核 meta (按 flavour 区分的包) → 0
#   不算内核类 (与 flavour 无关, 照常走递归闭包): linux-firmware* (另有规则) linux-base* linux-libc-dev
#   linux-sound-base linux-doc linux-source* linux-tools-common linux-cloud-tools-common linux-tools-host
aib_is_kernel_pkg() {
  case "$1" in
    linux-firmware|linux-firmware-*|linux-base|linux-base-*|linux-libc-dev|linux-libc-dev-*) return 1 ;;
    linux-sound-base|linux-doc|linux-source|linux-source-*) return 1 ;;
    linux-tools-common|linux-cloud-tools-common|linux-tools-host) return 1 ;;
    linux-*) return 0 ;;
    nvidia-dkms-*|nvidia-kernel-source-*) return 0 ;;
    *) return 1 ;;
  esac
}

# aib_kernel_filter ALLOW_FILE [DROPPED_FILE] < 包名 > 包名
#   内核类且不在 ALLOW_FILE (求解器闭包包名, 每行一个) 的丢弃 (写入 DROPPED_FILE); 其余原样输出
aib_kernel_filter() {
  local allow="$1" dropped="${2:-/dev/null}" p
  : > "$dropped"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if aib_is_kernel_pkg "$p" && ! grep -qxF -- "$p" "$allow"; then
      printf '%s\n' "$p" >> "$dropped"
      continue
    fi
    printf '%s\n' "$p"
  done
}
