#!/bin/bash
# 70-openmausbot.sh — OpenMausBot
#
# 它是个 Electron 桌面应用, 但服务器上不需要图形界面:
#   openmausbot          → 交互式 TUI 引导 (需要终端)
#   openmausbot serve    → 常驻 harness, 供手机/浏览器远程配对
# 所以这里只装 npm 包 + 提供一个"未启用"的 systemd 单元,
# 由使用者填好密钥后再 systemctl enable --now。
#
# 依赖: 需要本机已登录至少一个 agent CLI (claude / codex / grok), 否则打开是空的。
# 版本由 PIN_OPENMAUSBOT 控制 (默认 latest)。
set -euo pipefail
export HOME=/root

command -v node >/dev/null || { echo "ERROR: 需要先执行 40-nodejs.sh"; exit 1; }

VER="${PIN_OPENMAUSBOT:-latest}"
npm install -g "openmausbot@${VER}" --no-audit --no-fund

BIN="$(command -v openmausbot || true)"
[ -n "$BIN" ] || { echo "ERROR: openmausbot 未进入 PATH"; exit 1; }

# 密钥走 EnvironmentFile, 不进镜像、不进 unit 文件
install -d -m 0750 /etc/openmausbot
if [ ! -f /etc/openmausbot/env ]; then
  cat > /etc/openmausbot/env <<'ENVEOF'
# OpenMausBot 运行时配置。权限 0600, 不要提交到任何仓库。
# 示例 (按实际提供商填写):
# ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...
# XAI_API_KEY=xai-...
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

# 故意不 enable: 没有密钥时启起来也只会反复重试
systemctl daemon-reload 2>/dev/null || true

"$BIN" --version 2>/dev/null || echo "(无 --version 输出, 属正常)"
du -sh "$(dirname "$(readlink -f "$BIN")")" 2>/dev/null || true
echo "openmausbot ok (pin=${VER}; 未启用; 填好 /etc/openmausbot/env 后 systemctl enable --now openmausbot)"
