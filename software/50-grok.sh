#!/bin/bash
# 50-grok.sh — xAI Grok Build, 布局对齐官方 install.sh
#
# 二进制在 $HOME/.grok/downloads/grok-<version>-<os>-<arch>,
# ~/.grok/bin/grok 与 agent 用相对链接指向它。
# ~/.grok/config.toml 写 installer = "internal", 这样 `grok update`
# 走官方下载通道, 写用户家目录, 不走 `npm i -g`。
# 不把 npm 包装器留在 /usr/local/bin (那个会设 GROK_MANAGED_BY_NPM)。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"

VER="${PIN_GROK:-latest}"
SKIP_PKG="${AIB_SKIP_PKG:-0}"
USER_NAME="${TARGET_USER:-root}"
USER_HOME="$(aib_target_user_home)"
GROK_HOME="$USER_HOME/.grok"
BIN_LINK="$GROK_HOME/bin/grok"

case "$(uname -m)" in
  x86_64|amd64|AMD64) GROK_ARCH=x86_64; NPM_ARCH=x64 ;;
  aarch64|arm64|ARM64) GROK_ARCH=aarch64; NPM_ARCH=arm64 ;;
  *) echo "ERROR: grok 不支持的架构 $(uname -m)"; exit 1 ;;
esac
GROK_PLATFORM="linux-${GROK_ARCH}"

aib_decode_brotli() {
  SRC="$1" DST="$2" node <<'JS'
const fs = require("fs");
const zlib = require("zlib");
fs.writeFileSync(process.env.DST, zlib.brotliDecompressSync(fs.readFileSync(process.env.SRC)));
fs.chmodSync(process.env.DST, 0o755);
JS
}

aib_place_grok_binary() {
  local src="$1" dest_fs="$2"
  mkdir -p "$(dirname "$dest_fs")"
  if [ -L "$src" ]; then
    src="$(readlink -f "$src")"
  fi
  local sz
  sz="$(wc -c < "$src" | tr -d ' ')"
  if [ "${sz:-0}" -lt 1000000 ]; then
    echo "ERROR: grok 二进制过小 ($sz 字节): $src"
    return 1
  fi
  install -m 0755 "$src" "$dest_fs"
}

aib_grok_mark_internal() {
  local cfg="$1" tmp
  if [ ! -f "$cfg" ]; then
    printf '[cli]\ninstaller = "internal"\n' > "$cfg"
    return 0
  fi
  tmp="$(mktemp)"
  if grep -q '^\[cli\]' "$cfg"; then
    awk '
      /^\[cli\][[:space:]]*(#.*)?$/ { print; print "installer = \"internal\""; in_cli=1; next }
      /^\[.*\][[:space:]]*(#.*)?$/ { in_cli=0 }
      in_cli && /^[[:space:]]*installer[[:space:]]*=/ { next }
      { print }
    ' "$cfg" > "$tmp"
  else
    cat "$cfg" > "$tmp"
    printf '\n[cli]\ninstaller = "internal"\n' >> "$tmp"
  fi
  mv "$tmp" "$cfg"
}

if [ "$SKIP_PKG" != "1" ]; then
  export HOME="${HOME:-/root}"
  command -v node >/dev/null || { echo "ERROR: 需要先执行 40-nodejs.sh"; exit 1; }

  STAGE=""
  CLEAN_STAGE=0
  if offline_enabled 2>/dev/null && [ -f "$(offline_root)/npm/prefix.tar.gz" ]; then
    echo "offline: 从 npm 树取出 grok 二进制, 装到 ${GROK_HOME} (pin=$VER 已在捆绑时固化)"
    aib_prepare_npm_stage || { echo "ERROR: 无法展开 npm prefix"; exit 1; }
    STAGE="$(aib_npm_stage_dir)"
  else
    STAGE="$(mktemp -d)"
    CLEAN_STAGE=1
    echo "online: npm prefix ${STAGE} 取 @xai-official/grok@${VER}, 再装到 ${GROK_HOME}"
    # --ignore-scripts: postinstall 会把 installer=npm 写进 root 的 ~/.grok,
    # 之后 grok update 又会去写 /usr/local。二进制从 .br 自己解压。
    npm install --prefix "$STAGE" --ignore-scripts --no-audit --no-fund \
      "@xai-official/grok@${VER}"
  fi

  PKG="$STAGE/lib/node_modules/@xai-official/grok"
  [ -f "$PKG/package.json" ] || { echo "ERROR: 缺少 $PKG"; exit 1; }
  NATIVE="$PKG/bin/grok-native"
  BR="$PKG/node_modules/@xai-official/grok-linux-${NPM_ARCH}/bin/grok.br"
  if [ ! -f "$BR" ]; then
    BR="$(find "$STAGE/lib/node_modules" -path "*/grok-linux-${NPM_ARCH}/bin/grok.br" -print -quit 2>/dev/null || true)"
  fi
  WORK="$(mktemp -d)"
  if [ -f "$NATIVE" ]; then
    SRC_BIN="$NATIVE"
  elif [ -f "$BR" ]; then
    SRC_BIN="$WORK/grok"
    aib_decode_brotli "$BR" "$SRC_BIN"
  else
    echo "ERROR: 找不到 grok-native 或 $BR"
    exit 1
  fi

  GROK_VER="$(PKG_JSON="$PKG/package.json" node -p 'require(process.env.PKG_JSON).version')"
  case "$GROK_VER" in
    [0-9]*) ;;
    *) echo "ERROR: 非法 grok 版本: ${GROK_VER:-空}"; exit 1 ;;
  esac
  GROK_FILE="grok-${GROK_VER}-${GROK_PLATFORM}"
  DEST_FS="$(aib_fs "$GROK_HOME/downloads/${GROK_FILE}")"
  aib_place_grok_binary "$SRC_BIN" "$DEST_FS"
  mkdir -p "$(aib_fs "$GROK_HOME/bin")"
  ln -sfn "../downloads/${GROK_FILE}" "$(aib_fs "$GROK_HOME/bin/grok")"
  ln -sfn "../downloads/${GROK_FILE}" "$(aib_fs "$GROK_HOME/bin/agent")"
  aib_grok_mark_internal "$(aib_fs "$GROK_HOME/config.toml")"
  chmod 0644 "$(aib_fs "$GROK_HOME/config.toml")"

  if [ -z "${AIB_TARGET_ROOT:-}" ]; then
    mkdir -p "$USER_HOME/.grok/completions/bash" "$USER_HOME/.grok/completions/zsh"
    "$DEST_FS" completions bash > "$USER_HOME/.grok/completions/bash/grok.bash" 2>/dev/null || true
    "$DEST_FS" completions zsh > "$USER_HOME/.grok/completions/zsh/_grok" 2>/dev/null || true
    "$DEST_FS" --version
  fi

  rm -rf "$WORK"
  if [ "$CLEAN_STAGE" = "1" ]; then
    rm -rf "$STAGE"
  fi
  aib_unpublish_global_user_clis
else
  mkdir -p "$(aib_fs "$GROK_HOME/bin")" "$(aib_fs "$GROK_HOME/downloads")"
  aib_grok_mark_internal "$(aib_fs "$GROK_HOME/config.toml")"
fi

BASHRC="$(aib_fs "$USER_HOME/.bashrc")"
aib_install_shell_block "$BASHRC" "# >>> grok installer >>>" "# <<< grok installer <<<" "$(cat <<'BLOCK'
# >>> grok installer >>>
export PATH="$HOME/.grok/bin:$PATH"
[[ -r "$HOME/.grok/completions/bash/grok.bash" ]] && source "$HOME/.grok/completions/bash/grok.bash"
# <<< grok installer <<<
BLOCK
)"

mkdir -p "$(aib_fs "$USER_HOME/.local/bin")"
ln -sfn "$GROK_HOME/bin/grok" "$(aib_fs "$USER_HOME/.local/bin/grok")"
ln -sfn "$GROK_HOME/bin/agent" "$(aib_fs "$USER_HOME/.local/bin/agent")"

aib_own_user "$(aib_fs "$GROK_HOME")" "$(aib_fs "$USER_HOME/.local")" "$BASHRC"

echo "grok ok (pin=${VER}; ${BIN_LINK} installer=internal; 用户 ${USER_NAME} 可直接 grok update; 运行前请配置 XAI_API_KEY, 镜像内不预置任何密钥)"
