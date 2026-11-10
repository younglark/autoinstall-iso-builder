# syntax=docker/dockerfile:1
# =============================================================================
# autoinstall-iso-builder — 跨平台构建镜像 (macOS / Windows / Linux 均用 Docker 运行)
#
#   推荐用包装脚本: scripts/aib.sh (macOS/Linux) / scripts/aib.ps1 (Windows),
#   首次运行会自动 docker build 本镜像 (tag autoinstall-iso-builder:local), 不依赖任何 registry。
#   手动: docker build -t autoinstall-iso-builder:local . &&
#         docker run --rm -v "$PWD:/work" autoinstall-iso-builder:local build --iso ... --out ...
#
# 变体: UBUNTU_VERSION=24.04 (默认, tag :local)
#       UBUNTU_VERSION=22.04 (tag :local-jammy; 只在给 22.04 抓离线捆绑时需要)
# 架构: amd64 / arm64 均可本机构建。ISO 重打包与架构无关;
#       抓离线捆绑 (apt 解析 + npm) 必须 linux/amd64 (包装脚本自动加 --platform)。
# =============================================================================
ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ARG NODE_MAJOR=24
ARG TARGETARCH
ARG AIB_VERSION=dev
ARG VCS_REF=unknown
# 默认清华源 https (含 -security)。缺 CA 时先走 http 装 ca-certificates 再切回 https。
# 空值 (--build-arg APT_MIRROR=) 保留镜像自带官方源。arm64 等 ports 架构用 APT_PORTS_MIRROR。
ARG APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ubuntu
ARG APT_PORTS_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports

LABEL org.opencontainers.image.title="autoinstall-iso-builder" \
      org.opencontainers.image.description="Bake Ubuntu autoinstall + preinstalled software into Ubuntu Server/Desktop ISOs (runs on macOS/Windows/Linux via Docker)" \
      org.opencontainers.image.source="https://github.com/younglark/autoinstall-iso-builder" \
      org.opencontainers.image.version="${AIB_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    AIB_HOME=/opt/aib \
    AIB_IN_CONTAINER=1 \
    AIB_VERSION=${AIB_VERSION} \
    PYTHONPYCACHEPREFIX=/tmp/pycache \
    AIB_APT_RUNNER=direct \
    OFFLINE_CACHE_ROOT=/work/cache/offline-bundles

# 构建 ISO: xorriso python3(+yaml) openssl; 抓捆绑: curl gnupg dpkg-dev xz-utils;
# Windows: wimtools (wimlib-imagex 列 install.wim 版本) p7zip-full (读 Windows ISO 的 UDF) libxml2-utils (xmllint);
# 冒烟/校验: shellcheck 不装 (CI 单独跑), file/jq 方便排查
# Ubuntu 基础镜像 /bin/sh 是 dash。下面要 source 一份 bash helper，必须先把
# SHELL 改成 bash，否则会忽略 shebang，在 ${BASH_SOURCE[0]} 处 Bad substitution。
SHELL ["/bin/bash", "-c"]
# 先只拷 helper, 以免改仓库其它文件时让 apt 层缓存失效
COPY tools/ubuntu-mirror.sh /tmp/aib-ubuntu-mirror.sh
RUN . /tmp/aib-ubuntu-mirror.sh \
 && aib_apply_builder_mirrors "$APT_MIRROR" "$APT_PORTS_MIRROR" \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl gnupg xorriso python3 python3-yaml openssl \
      dpkg-dev apt-utils xz-utils unzip jq file tar gzip coreutils findutils util-linux \
      wimtools p7zip-full libxml2-utils \
 && rm -rf /var/lib/apt/lists/*

# Node.js (官方 tarball, 校验 SHASUMS256): 抓离线捆绑时 npm 打包全局 CLI 用
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) NARCH=x64 ;; arm64) NARCH=arm64 ;; *) echo "unsupported arch ${TARGETARCH}"; exit 1 ;; \
    esac; \
    base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x"; \
    curl -fsSL "$base/SHASUMS256.txt" -o /tmp/SHASUMS256.txt; \
    tarball="$(grep -oE "node-v[0-9.]+-linux-${NARCH}\.tar\.xz" /tmp/SHASUMS256.txt | head -1)"; \
    curl -fsSL "$base/$tarball" -o "/tmp/$tarball"; \
    (cd /tmp && grep " $tarball\$" SHASUMS256.txt | sha256sum -c -); \
    tar -xJf "/tmp/$tarball" -C /usr/local --strip-components=1 --no-same-owner \
      --exclude='*/CHANGELOG.md' --exclude='*/README.md' --exclude='*/LICENSE'; \
    rm -f /tmp/SHASUMS256.txt "/tmp/$tarball"; \
    node --version; npm --version

COPY . /opt/aib
RUN chmod +x /opt/aib/docker/entrypoint.sh /opt/aib/build-iso.sh /opt/aib/tools/*.sh /opt/aib/test/*.sh \
 && ln -s /opt/aib/docker/entrypoint.sh /usr/local/bin/aib \
 && mkdir -p /work && chmod 1777 /work \
 && rm -rf /tmp/pycache /tmp/* /root/.npm

WORKDIR /work
ENTRYPOINT ["/opt/aib/docker/entrypoint.sh"]
CMD ["help"]
