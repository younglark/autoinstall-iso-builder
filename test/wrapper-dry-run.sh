#!/usr/bin/env bash
# =============================================================================
# wrapper-dry-run.sh — 不需要 docker: 用 aib.sh --dry-run 断言参数/路径改写/平台选择
#   bash test/wrapper-dry-run.sh            (macOS 上用 /bin/bash 3.2 跑, 覆盖老 bash)
# =============================================================================
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
AIB="$ROOT/scripts/aib.sh"
FAIL=0
pass() { printf '[pass] %s\n' "$*"; }
fail() { printf '[fail] %s\n' "$*" >&2; FAIL=1; }
expect() { # name haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1: 缺少 [$3] in: $2"; fi
}
reject() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1: 不应出现 [$3] in: $2"; fi
}

unset AIB_IMAGE AIB_PLATFORM AIB_DOCKER_ARGS AIB_BUILD_ARGS APT_MIRROR
work="$(mktemp -d -t aib-dry-XXXXXX)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/proj" "$work/isos dir"
cd "$work/proj"
# 用 pwd -P 之前的逻辑路径; macOS /var -> /private/var 不影响 (词法处理)
proj="$(pwd)"

out="$(bash "$AIB" --dry-run build --iso "../isos dir/u.iso" --out out/n1.iso \
  --password 'p@ss word' --gitea-admin-password 'g1tea secret' --jenkins-admin-password 'j3nkins secret' --ssh-authorized-keys "$work/isos dir/k.pub" --hostname n1)"
expect "cwd 挂到 /work" "$out" "source=$proj,target=/work"
expect "cwd 外 ISO 父目录挂载" "$out" "source=$work/isos dir,target=/mnt/aib1"
expect "ISO 参数改写" "$out" "/mnt/aib1/u.iso"
expect "同目录复用挂载" "$out" "/mnt/aib1/k.pub"
reject "不重复挂载" "$out" "/mnt/aib2"
expect "--out 相对路径" "$out" "--out /work/out/n1.iso"
expect "默认本地镜像" "$out" "autoinstall-iso-builder:local build"
expect "默认打印自动构建命令" "$out" "docker build -t autoinstall-iso-builder:local --build-arg UBUNTU_VERSION=24.04"
reject "无 ghcr 默认" "$out" "ghcr.io"
expect "明文密码打码" "$out" "--password '***'"
reject "明文密码不泄露" "$out" "p@ss"
expect "Gitea 密码打码" "$out" "--gitea-admin-password '***'"
reject "Gitea 密码不泄露" "$out" "g1tea"
expect "Jenkins 密码打码" "$out" "--jenkins-admin-password '***'"
reject "Jenkins 密码不泄露" "$out" "j3nkins"
reject "build 不强制平台" "$out" "--platform"
if [[ -d "$work/proj/out" ]]; then fail "dry-run 不应创建目录"; else pass "dry-run 不创建目录"; fi

out="$(AIB_BUILD_ARGS="--network=host" APT_MIRROR=http://mirrors.example/ubuntu bash "$AIB" --dry-run fetch-offline --release 22.04 --out "$work/bundles/jammy")"
expect "fetch 强制 amd64" "$out" "--platform linux/amd64"
expect "jammy 本地变体" "$out" "autoinstall-iso-builder:local-jammy"
expect "jammy 用 22.04 构建" "$out" "UBUNTU_VERSION=22.04 --platform linux/amd64"
expect "APT_MIRROR 透传给 docker build" "$out" "--build-arg APT_MIRROR=http://mirrors.example/ubuntu --network=host"
expect "fetch --out 改写" "$out" "--out /mnt/aib1/jammy"

out="$(bash "$AIB" --dry-run build --iso u.iso --out o.iso --wayland --vnc-password 'vnc s3cret')"
expect "--wayland 透传" "$out" "--wayland --vnc-password"
expect "VNC 密码打码" "$out" "--vnc-password '***'"
reject "VNC 密码不泄露" "$out" "s3cret"

out="$(bash "$AIB" --dry-run build --iso u.iso --out o.iso --remote-desktop rustdesk --rustdesk-password 'rd s3cret' --rustdesk-server rd.example.com)"
expect "--remote-desktop 透传" "$out" "--remote-desktop rustdesk --rustdesk-password"
expect "RustDesk 密码打码" "$out" "--rustdesk-password '***'"
reject "RustDesk 密码不泄露" "$out" "s3cret"
expect "--rustdesk-server 透传" "$out" "--rustdesk-server rd.example.com"
reject "--rustdesk-server 不当路径改写" "$out" "/work/rd.example.com"

out="$(PIN_NVIDIA_DRIVER=580 bash "$AIB" --dry-run build --iso u.iso --out o.iso --no-nvidia-driver --nvidia-driver-version 580 --nvidia-kernel-flavour generic)"
expect "--no-nvidia-driver 透传" "$out" "--no-nvidia-driver --nvidia-driver-version 580 --nvidia-kernel-flavour generic"
expect "PIN_NVIDIA_DRIVER 透传" "$out" "-e PIN_NVIDIA_DRIVER=580"

out="$(bash "$AIB" --dry-run build --iso u.iso --out o.iso --hostname node07 --service-url-host 192.168.1.20)"
expect "--service-url-host 透传" "$out" "--hostname node07 --service-url-host 192.168.1.20"
reject "--service-url-host 不当路径改写" "$out" "/work/192.168.1.20"

out="$(bash "$AIB" --dry-run fetch-offline --release noble --apt-cache "$work/debcache" --prune-apt-cache)"
expect "--apt-cache cwd 外挂载并改写" "$out" "--apt-cache /mnt/aib1/debcache"
expect "--prune-apt-cache 透传" "$out" "--prune-apt-cache"

out="$(bash "$AIB" --dry-run fetch-offline --release noble)"
expect "noble 用默认变体" "$out" "autoinstall-iso-builder:local"
reject "noble 不用 jammy" "$out" "local-jammy"

out="$(bash "$AIB" --dry-run build --iso ubuntu-22.04.5-live-server-amd64.iso --out o.iso --fetch-offline)"
expect "build --fetch-offline 强制 amd64" "$out" "--platform linux/amd64"
expect "22.04 ISO 选 jammy 变体" "$out" "autoinstall-iso-builder:local-jammy"

out="$(bash "$AIB" --dry-run --local --rebuild check-iso ../x.iso)"
expect "--rebuild 先构建" "$out" "# --rebuild"
expect "--local 兼容无操作" "$out" "autoinstall-iso-builder:local check-iso /mnt/aib1/x.iso"
if bash "$AIB" --dry-run --rebuild --image x/y:1 version >/dev/null 2>&1; then fail "--rebuild + --image 应报错"; else pass "--rebuild + --image 报错"; fi
if bash "$AIB" --dry-run --tag v1 version >/dev/null 2>&1; then fail "--tag 已移除应报错"; else pass "--tag 已移除"; fi

out="$(AIB_IMAGE=example.org/me/aib bash "$AIB" --dry-run --platform linux/arm64 build --iso a.iso --out b.iso)"
expect "AIB_IMAGE 覆盖 (原样使用)" "$out" "example.org/me/aib build"
reject "--image 不自动构建" "$out" "docker build"
expect "--platform 覆盖" "$out" "--platform linux/arm64"

if [[ "$(uname -s)" == "Linux" && "$(id -u)" -ne 0 ]]; then
  expect "Linux 传 AIB_UID" "$out" "AIB_UID=$(id -u)"
else
  reject "非 Linux 不传 AIB_UID" "$out" "AIB_UID="
fi

out="$(AIB_DOCKER_ARGS="--network=host -e HTTPS_PROXY=http://p:3128" bash "$AIB" --dry-run --docker-arg --dns=1.1.1.1 local-check)"
expect "AIB_DOCKER_ARGS 透传" "$out" "--network=host -e HTTPS_PROXY=http://p:3128 --dns=1.1.1.1 autoinstall-iso-builder:local local-check"

if bash "$AIB" --dry-run --bogus build >/dev/null 2>&1; then fail "未知包装选项应报错"; else pass "未知包装选项报错"; fi

if [[ "$FAIL" -ne 0 ]]; then echo "wrapper dry-run: FAILED" >&2; exit 1; fi
echo "wrapper dry-run: ALL PASS"
