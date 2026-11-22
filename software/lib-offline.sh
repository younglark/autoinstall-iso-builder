#!/bin/bash
# lib-offline.sh — 离线模式公共函数 (由各 software/*.sh source)
#
# OFFLINE=1 且存在 /opt/offline 时走本地 apt / npm / node tarball。
# 由 late-commands 在 run-all 之前挂好 file: apt 源。

offline_enabled() {
  [ "${OFFLINE:-0}" = "1" ] || [ "${OFFLINE:-}" = "true" ]
}

offline_root() {
  echo "${OFFLINE_ROOT:-/opt/offline}"
}

offline_apt_ready() {
  [ -f "$(offline_root)/apt/Packages" ] || [ -f "$(offline_root)/apt/Packages.gz" ]
}

# 确保只从本地 offline apt 安装 (源应已由 late-commands 写入)
offline_apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

# 离线 npm 树先解到临时目录。grok / opencode 不进 /usr/local:
# 官方安装器把它们放在登录用户家里, 这样 `grok update` / `opencode upgrade`
# 不用 root。全局前缀只留 OpenMausBot。
aib_npm_stage_dir() {
  printf '%s\n' "${AIB_NPM_STAGE:-/var/tmp/aib-npm-prefix}"
}

# 只有 tar 成功之后才写标记。半截目录或换过的 prefix.tar.gz 会整目录重解。
aib_prepare_npm_stage() {
  local stage tgz id stamp tmp
  stage="$(aib_npm_stage_dir)"
  tgz="$(offline_root)/npm/prefix.tar.gz"
  [ -f "$tgz" ] || return 1
  if id="$(stat -c '%s %Y' "$tgz" 2>/dev/null)"; then
    :
  else
    id="$(stat -f '%z %m' "$tgz")"
  fi
  stamp="$stage/.aib-prefix-stamp"
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$id" ] && [ -d "$stage/lib/node_modules" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$stage")"
  tmp="$(mktemp -d "${stage}.extract.XXXXXX")"
  # 解到空目录, 不需要 --no-overwrite-dir (那个是为了往已有 /usr/local 上解时不改目录属主)。
  if ! tar --no-same-owner -xzf "$tgz" -C "$tmp"; then
    rm -rf "$tmp"
    return 1
  fi
  printf '%s\n' "$id" > "$tmp/.aib-prefix-stamp"
  rm -rf "$stage"
  mv "$tmp" "$stage"
}

# 装机用户在目标系统上的家目录 (不含 AIB_TARGET_ROOT)。
aib_target_user_home() {
  local user="${TARGET_USER:-}" home="" root="${AIB_TARGET_ROOT:-}"
  if [ -z "$user" ]; then
    user="$(id -un 2>/dev/null || echo root)"
  fi
  if [ -n "$root" ] && [ -f "$root/etc/passwd" ]; then
    home="$(awk -F: -v u="$user" '$1==u { print $6; exit }' "$root/etc/passwd")"
  fi
  if [ -z "$home" ]; then
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  fi
  if [ -z "$home" ]; then
    if [ "$user" = "root" ]; then
      home=/root
    else
      home="/home/$user"
    fi
  fi
  printf '%s\n' "$home"
}

# 逻辑路径 → 写入路径 (测试时加 AIB_TARGET_ROOT)。
aib_fs() {
  printf '%s%s\n' "${AIB_TARGET_ROOT:-}" "$1"
}

aib_own_user() {
  local user="${TARGET_USER:-}"
  [ -n "$user" ] || return 0
  [ "$(id -u 2>/dev/null || echo 1)" -eq 0 ] || return 0
  id "$user" >/dev/null 2>&1 || return 0
  chown -R "$user:$user" "$@" 2>/dev/null || chown -R "$user" "$@" 2>/dev/null || true
}

# 在 shell rc 里放一段带标记的 PATH。再次装机时整段替换。
aib_install_shell_block() {
  local file="$1" begin="$2" end="$3" block="$4" tmp
  mkdir -p "$(dirname "$file")"
  touch "$file"
  tmp="$(mktemp)"
  # 整行相等才算标记。子串匹配会在重装时把标记后面的 rc 删掉。
  # 结束标记缺失时不改已有内容, 改成追加。
  if grep -F -qx "$begin" "$file" 2>/dev/null && grep -F -qx "$end" "$file" 2>/dev/null; then
    BLOCK="$block" awk -v b="$begin" -v e="$end" '
      BEGIN { block = ENVIRON["BLOCK"] }
      $0 == b { printf "%s\n", block; skip=1; next }
      $0 == e && skip { skip=0; next }
      skip { next }
      { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    cat "$file" > "$tmp"
    printf '\n%s\n' "$block" >> "$tmp"
  fi
  mv "$tmp" "$file"
}

# 去掉全局 npm 里的 grok / opencode, 避免 /usr/local/bin 盖住家目录里的那份。
aib_npm_dest_prefix() {
  printf '%s\n' "${AIB_NPM_PREFIX:-/usr/local}"
}

aib_unpublish_global_user_clis() {
  local dest
  dest="$(aib_npm_dest_prefix)"
  rm -f "$dest/bin/grok" "$dest/bin/opencode" "$dest/bin/opencode2"
  rm -rf "$dest/lib/node_modules/@xai-official" "$dest/lib/node_modules/@opencode"
  hash -r 2>/dev/null || true
}

offline_extract_npm_prefix() {
  local stage src base name dest
  aib_prepare_npm_stage || { echo "ERROR: 缺少 $(offline_root)/npm/prefix.tar.gz"; return 1; }
  stage="$(aib_npm_stage_dir)"
  dest="$(aib_npm_dest_prefix)"
  mkdir -p "$dest/lib/node_modules" "$dest/bin"
  # npm 会把依赖提升到 openmausbot 的同级。只拷包目录会丢掉这些模块。
  # @xai-official / @opencode 留给用户家目录, 不进全局前缀。
  if [ -d "$stage/lib/node_modules" ]; then
    for src in "$stage/lib/node_modules"/*; do
      [ -e "$src" ] || continue
      base="$(basename "$src")"
      case "$base" in
        @xai-official|@opencode) continue ;;
      esac
      rm -rf "$dest/lib/node_modules/$base"
      cp -a "$src" "$dest/lib/node_modules/"
    done
  fi
  if [ -d "$stage/bin" ]; then
    for src in "$stage/bin"/*; do
      [ -e "$src" ] || [ -L "$src" ] || continue
      name="$(basename "$src")"
      case "$name" in
        grok|opencode|opencode2) continue ;;
      esac
      rm -f "$dest/bin/$name"
      if [ -L "$src" ]; then
        ln -sfn "$(readlink "$src")" "$dest/bin/$name"
      else
        cp -a "$src" "$dest/bin/$name"
      fi
    done
  fi
  aib_unpublish_global_user_clis
}

# 把官方 Node tarball 装到 /opt/node-vX.Y.Z 并 symlink 进 /usr/local/{bin,lib,...}
# 避免 tar 把整个 /usr/local 属主改成打包用户。
offline_install_node_tarball() {
  local dir name tarball verdir base
  dir="$(offline_root)/node"
  [ -d "$dir" ] || return 1
  if [ -f "$dir/tarball.name" ]; then
    name="$(cat "$dir/tarball.name")"
    tarball="$dir/$name"
  else
    tarball="$(find "$dir" -maxdepth 1 -name 'node-v*-linux-x64.tar.xz' -print 2>/dev/null | head -1 || true)"
  fi
  [ -n "${tarball:-}" ] && [ -f "$tarball" ] || return 1
  base="$(basename "$tarball" .tar.xz)"   # node-v24.x.y-linux-x64
  verdir="/opt/${base}"
  mkdir -p /opt
  rm -rf "$verdir"
  mkdir -p "$verdir"
  tar --no-same-owner --no-overwrite-dir -xJf "$tarball" -C "$verdir" --strip-components=1
  # 官方 tarball 顶层含 bin include lib share
  local sub item
  for sub in bin include lib share; do
    if [ -d "$verdir/$sub" ]; then
      mkdir -p "/usr/local/$sub"
      # 逐项链接, 不 chown /usr/local
      for item in "$verdir/$sub"/*; do
        [ -e "$item" ] || continue
        ln -sfn "$item" "/usr/local/$sub/$(basename "$item")"
      done
    fi
  done
  hash -r 2>/dev/null || true
}

# npm 全局前缀里的 @opencode/cli 会拉同一 arch 的全部可选二进制 (glibc/musl、avx2/baseline, 各约 235MB)。
# postinstall 已把当前主机适用的那份拷/链到 @opencode/cli/bin/opencode.exe。
# 这里只保留目标 linux + 本 arch 的 glibc 变体 (avx2 + baseline), 去掉 musl / 其它 OS。
# $1 = npm prefix (如 /usr/local 或打包用的临时 prefix); $2 = node arch (x64 / arm64)。
aib_opencode_node_arch() {
  case "${1:-}" in
    amd64|x86_64|x64) printf 'x64\n' ;;
    arm64|aarch64) printf 'arm64\n' ;;
    *) printf 'x64\n' ;;
  esac
}

aib_prune_opencode_cli_platform() {
  local prefix="$1" arch_node="$2"
  local mods="$prefix/lib/node_modules/@opencode/cli/node_modules/@opencode"
  [ -d "$mods" ] || return 0
  local d base
  for d in "$mods"/cli-*; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    case "$base" in
      "cli-linux-${arch_node}"|"cli-linux-${arch_node}-baseline") ;;
      *) rm -rf "$d" ;;
    esac
  done
}

# 在目标机再跑一次 postinstall, 按本机 CPU (avx2 / baseline) 选二进制。
aib_opencode_cli_postinstall() {
  local prefix="$1"
  local script="$prefix/lib/node_modules/@opencode/cli/postinstall.mjs"
  [ -f "$script" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  node "$script" || return 1
}
