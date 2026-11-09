#!/bin/bash
# 70-openmausbot.sh — OpenMausBot
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
export HOME=/root

command -v node >/dev/null || { echo "ERROR: 需要先执行 40-nodejs.sh"; exit 1; }

VER="${PIN_OPENMAUSBOT:-latest}"
if offline_enabled 2>/dev/null && [ -f "$(offline_root)/npm/prefix.tar.gz" ]; then
  echo "offline: 使用已解压/捆绑的 npm prefix (openmausbot pin=$VER)"
  command -v openmausbot >/dev/null || offline_extract_npm_prefix
else
  npm install -g "openmausbot@${VER}" --no-audit --no-fund
fi

BIN="$(command -v openmausbot || true)"
[ -n "$BIN" ] || { echo "ERROR: openmausbot 未进入 PATH"; exit 1; }

install -d -m 0750 /etc/openmausbot
if [ ! -f /etc/openmausbot/env ]; then
  cat > /etc/openmausbot/env <<'ENVEOF'
# OpenMausBot 运行时配置。权限 0600, 不要提交到任何仓库。
ENVEOF
  chmod 0600 /etc/openmausbot/env
fi

cat > /etc/systemd/system/openmausbot.service <<UNIT
[Unit]
Description=OpenMausBot harness
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TARGET_USER:-root}
EnvironmentFile=-/etc/openmausbot/env
ExecStart=${BIN} serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload 2>/dev/null || true
"$BIN" --version 2>/dev/null || echo "(无 --version 输出, 属正常)"
echo "openmausbot ok (pin=${VER}; 未启用; 填好 /etc/openmausbot/env 后 systemctl enable --now openmausbot)"
