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

work="$(mktemp -d -t aib-dry-XXXXXX)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/proj" "$work/isos dir"
cd "$work/proj"
# 用 pwd -P 之前的逻辑路径; macOS /var -> /private/var 不影响 (词法处理)
proj="$(pwd)"

out="$(bash "$AIB" --dry-run build --iso "../isos dir/u.iso" --out out/n1.iso \
  --password 'p@ss word' --ssh-authorized-keys "$work/isos dir/k.pub" --hostname n1)"
expect "cwd 挂到 /work" "$out" "source=$proj,target=/work"
expect "cwd 外 ISO 父目录挂载" "$out" "source=$work/isos dir,target=/mnt/aib1"
expect "ISO 参数改写" "$out" "/mnt/aib1/u.iso"
expect "同目录复用挂载" "$out" "/mnt/aib1/k.pub"
reject "不重复挂载" "$out" "/mnt/aib2"
expect "--out 相对路径" "$out" "--out /work/out/n1.iso"
expect "默认镜像" "$out" "ghcr.io/younglark/autoinstall-iso-builder:latest build"
expect "明文密码打码" "$out" "--password '***'"
reject "明文密码不泄露" "$out" "p@ss"
reject "build 不强制平台" "$out" "--platform"
if [[ -d "$work/proj/out" ]]; then fail "dry-run 不应创建目录"; else pass "dry-run 不创建目录"; fi

out="$(bash "$AIB" --dry-run --tag v1.2.3 fetch-offline --release 22.04 --out "$work/bundles/jammy")"
expect "fetch 强制 amd64" "$out" "--platform linux/amd64"
expect "jammy 变体" "$out" "autoinstall-iso-builder:v1.2.3-jammy fetch-offline"
expect "fetch --out 改写" "$out" "--out /mnt/aib1/jammy"

out="$(bash "$AIB" --dry-run fetch-offline --release noble)"
expect "noble 用默认变体" "$out" "autoinstall-iso-builder:latest fetch-offline"

out="$(bash "$AIB" --dry-run build --iso ubuntu-22.04.5-live-server-amd64.iso --out o.iso --fetch-offline)"
expect "build --fetch-offline 强制 amd64" "$out" "--platform linux/amd64"
expect "22.04 ISO 选 jammy 变体" "$out" ":latest-jammy build"

out="$(AIB_IMAGE=example.org/me/aib bash "$AIB" --dry-run --local check-iso ../x.iso)"
expect "--local 先 docker build" "$out" "docker build -t autoinstall-iso-builder:local"
expect "--local 用本地 tag" "$out" "autoinstall-iso-builder:local check-iso /mnt/aib1/x.iso"

out="$(AIB_IMAGE=example.org/me/aib bash "$AIB" --dry-run --platform linux/arm64 build --iso a.iso --out b.iso)"
expect "AIB_IMAGE 覆盖" "$out" "example.org/me/aib:latest"
expect "--platform 覆盖" "$out" "--platform linux/arm64"

if [[ "$(uname -s)" == "Linux" && "$(id -u)" -ne 0 ]]; then
  expect "Linux 传 AIB_UID" "$out" "AIB_UID=$(id -u)"
else
  reject "非 Linux 不传 AIB_UID" "$out" "AIB_UID="
fi

out="$(AIB_DOCKER_ARGS="--network=host -e HTTPS_PROXY=http://p:3128" bash "$AIB" --dry-run --docker-arg --dns=1.1.1.1 local-check)"
expect "AIB_DOCKER_ARGS 透传" "$out" "--network=host -e HTTPS_PROXY=http://p:3128 --dns=1.1.1.1 ghcr.io/younglark/autoinstall-iso-builder:latest local-check"

if bash "$AIB" --dry-run --bogus build >/dev/null 2>&1; then fail "未知包装选项应报错"; else pass "未知包装选项报错"; fi

if [[ "$FAIL" -ne 0 ]]; then echo "wrapper dry-run: FAILED" >&2; exit 1; fi
echo "wrapper dry-run: ALL PASS"
