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
# 可选: 国内构建镜像时换源, 例如 --build-arg APT_MIRROR=http://mirrors.aliyun.com/ubuntu
ARG APT_MIRROR=

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
# 冒烟/校验: shellcheck 不装 (CI 单独跑), file/jq 方便排查
RUN if [ -n "$APT_MIRROR" ]; then \
      sed -i "s#http://archive.ubuntu.com/ubuntu#${APT_MIRROR}#g; s#http://security.ubuntu.com/ubuntu#${APT_MIRROR}#g" \
        /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list 2>/dev/null || true; \
    fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl gnupg xorriso python3 python3-yaml openssl \
      dpkg-dev apt-utils xz-utils unzip jq file tar gzip coreutils findutils util-linux \
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
