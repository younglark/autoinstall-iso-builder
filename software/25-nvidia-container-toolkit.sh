#!/bin/bash
# 25-nvidia-container-toolkit.sh — NVIDIA Container Toolkit (不含 GPU 驱动)
# 官方: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
# 依赖 20-docker.sh 先写入 /etc/docker/daemon.json；本脚本用 nvidia-ctk 合并 nvidia runtime，不覆盖日志轮转等已有项。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
export DEBIAN_FRONTEND=noninteractive

if offline_enabled 2>/dev/null && offline_apt_ready 2>/dev/null; then
  echo "offline: 从本地 apt 安装 nvidia-container-toolkit (不添加 nvidia.github.io)"
  offline_apt_install nvidia-container-toolkit
else
  ARCH="$(dpkg --print-architecture)"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    -o /etc/apt/keyrings/nvidia-container-toolkit.asc
  chmod a+r /etc/apt/keyrings/nvidia-container-toolkit.asc
  # 官方 list 用 $(ARCH) 占位；这里写成明确 arch，与 docker 脚本一致
  printf 'deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.asc] https://nvidia.github.io/libnvidia-container/stable/deb/%s /\n' \
    "$ARCH" > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y --no-install-recommends nvidia-container-toolkit
fi

# 合并 nvidia runtime 进 daemon.json（保留 20-docker 的 log-opts 等）；chroot 内不重启 dockerd
if [ ! -f /etc/docker/daemon.json ]; then
  echo "ERROR: /etc/docker/daemon.json 不存在 — 请先跑 20-docker.sh"
  exit 1
fi
nvidia-ctk runtime configure --runtime=docker

nvidia-ctk --version
grep -q '"nvidia"' /etc/docker/daemon.json || {
  echo "ERROR: daemon.json 未写入 nvidia runtime"
  cat /etc/docker/daemon.json
  exit 1
}
echo "nvidia-container-toolkit ok (未安装 GPU 驱动；有 GPU 的机器需另行装驱动后可用 --gpus)"
