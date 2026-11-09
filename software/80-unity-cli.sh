#!/bin/bash
# 80-unity-cli.sh — Unity CLI only (`unity` 命令；不含 Editor / 登录 / 许可证)
# 官方: https://docs.unity.com/en-us/unity-cli/use-unity-cli
# 安装器参考: https://unity.com/install.sh
# CDN: https://public-cdn.cloud.unity3d.com/hub/prod/cli/
#
# 系统级安装到 /usr/local/bin/unity，避免只落在 /root/.local/bin。
# 不跑官方 install.sh 的 skill install / shell rc 改写；不装 Editor 运行时依赖。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"

CDN_BASE="${UNITY_CLI_CDN_BASE:-https://public-cdn.cloud.unity3d.com/hub/prod/cli/}"
INSTALL_BIN="/usr/local/bin/unity"
PLATFORM="linux-x64"
PIN="${PIN_UNITY_CLI:-}"

json_field() {
  # usage: json_field <json> <python-expr-on-obj>
  local json="$1" expr="$2"
  python3 -c "import json,sys; o=json.loads(sys.argv[1]); print($expr)" "$json"
}

verify_and_install() {
  local src="$1" expect_sha="$2"
  [ -f "$src" ] || { echo "ERROR: 缺少二进制 $src"; return 1; }
  local actual
  actual="$(sha256sum "$src" | awk '{print $1}')"
  if [ -n "$expect_sha" ] && [ "$actual" != "$expect_sha" ]; then
    echo "ERROR: Unity CLI sha256 不匹配"
    echo "  expect: $expect_sha"
    echo "  actual: $actual"
    return 1
  fi
  install -d -m 0755 /usr/local/bin
  install -m 0755 "$src" "$INSTALL_BIN"
}

install_offline() {
  local dir name sha src
  dir="$(offline_root)/unity-cli"
  [ -d "$dir" ] || {
    echo "ERROR: 离线捆绑缺少 unity-cli/ — 请用 --force 重建: ./tools/fetch-offline-bundle.sh --force ..."
    return 1
  }
  if [ -f "$dir/binary.name" ]; then
    name="$(cat "$dir/binary.name")"
  else
    name="unity"
  fi
  src="$dir/$name"
  [ -f "$src" ] || src="$dir/unity"
  [ -f "$src" ] || {
    echo "ERROR: 离线捆绑 unity-cli/ 内无二进制 (期望 $name 或 unity)"
    ls -la "$dir" || true
    return 1
  }
  sha=""
  [ -f "$dir/sha256" ] && sha="$(tr -d '[:space:]' < "$dir/sha256")"
  echo "offline: 安装 Unity CLI 自 $src (version=$(cat "$dir/version" 2>/dev/null || echo unknown))"
  verify_and_install "$src" "$sha"
}

resolve_manifest() {
  # sets: VERSION FILENAME SHA256
  local manifest="" url
  if [ -n "$PIN" ]; then
    url="${CDN_BASE}${PIN}/latest.json"
    echo "使用 PIN_UNITY_CLI=$PIN → $url"
    manifest="$(curl -fsSL "$url")" || {
      echo "ERROR: 无法拉取版本清单 $url"
      return 1
    }
  else
    url="${CDN_BASE}latest.json"
    if manifest="$(curl -fsSL "$url" 2>/dev/null)"; then
      echo "使用 stable 清单 $url"
    else
      url="${CDN_BASE}latest-beta.json"
      echo "stable 不可用，回退 beta: $url"
      manifest="$(curl -fsSL "$url")" || {
        echo "ERROR: 无法拉取 Unity CLI 清单 ($url)"
        return 1
      }
    fi
  fi
  VERSION="$(json_field "$manifest" 'o["version"]')"
  FILENAME="$(json_field "$manifest" "o['binaries']['${PLATFORM}']['filename']")"
  SHA256="$(json_field "$manifest" "o['binaries']['${PLATFORM}']['sha256']")"
  if [ -z "$VERSION" ] || [ -z "$FILENAME" ] || [ -z "$SHA256" ]; then
    echo "ERROR: 清单字段不完整 version=$VERSION filename=$FILENAME"
    return 1
  fi
  if [ -n "$PIN" ] && [ "$VERSION" != "$PIN" ]; then
    echo "ERROR: 版本清单不匹配: 请求 $PIN 但得到 $VERSION"
    return 1
  fi
}

install_online() {
  local tmp url
  resolve_manifest
  url="${CDN_BASE}${VERSION}/${FILENAME}"
  echo "下载 Unity CLI $VERSION ($FILENAME)"
  tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  curl -fsSL "$url" -o "$tmp" || {
    echo "ERROR: 下载失败 $url"
    return 1
  }
  verify_and_install "$tmp" "$SHA256"
  echo "Unity CLI $VERSION → $INSTALL_BIN"
}

if offline_enabled 2>/dev/null; then
  install_offline
else
  install_online
fi

hash -r 2>/dev/null || true
command -v unity >/dev/null || { echo "ERROR: unity 未进入 PATH"; exit 1; }
[ -x "$INSTALL_BIN" ] || { echo "ERROR: 缺少 $INSTALL_BIN"; exit 1; }
# 拒绝只装在 root 家目录的情况
case "$(command -v unity)" in
  /root/*)
    echo "ERROR: unity 仅在 /root 下 ($(command -v unity))，系统级安装失败"
    exit 1
    ;;
esac

unity --version
# 若指定了 TARGET_USER，确认该用户也能找到（/usr/local/bin 通常在 PATH）
if [ -n "${TARGET_USER:-}" ] && [ "${TARGET_USER}" != "root" ] && id "$TARGET_USER" >/dev/null 2>&1; then
  if ! su - "$TARGET_USER" -c 'command -v unity >/dev/null && unity --version' 2>/dev/null; then
    echo "warn: TARGET_USER=$TARGET_USER 当前登录 PATH 可能不含 /usr/local/bin；二进制已在 $INSTALL_BIN"
  fi
fi
echo "unity-cli ok (仅 CLI；登录/许可证/Editor 请装机后手动: unity auth login / unity install <ver>)"
