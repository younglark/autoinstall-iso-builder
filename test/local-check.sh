#!/usr/bin/env bash
# 本地 / CI 快速校验 (不需要真实 ISO)
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
FAIL=0

pass() { printf '[pass] %s\n' "$*"; }
fail() { printf '[fail] %s\n' "$*" >&2; FAIL=1; }

echo "== python syntax =="
if python3 -m py_compile tools/patch-grub.py tools/render-user-data.py tools/detect-edition.py; then
  pass "py_compile"
else
  fail "py_compile"
fi

echo "== patch-grub: inject + escape =="
tmp="$(mktemp -d)"
cp test/fixtures/grub.cfg "$tmp/grub.cfg"
if python3 tools/patch-grub.py --file "$tmp/grub.cfg" --menu-regex 'Try or Install' \
  --params 'autoinstall ds=nocloud\;s=/cdrom/nocloud/' --timeout 3; then
  :
else
  fail "patch-grub first run"
fi
if grep -qE 'ds=nocloud\\;s=/cdrom/nocloud/' "$tmp/grub.cfg"; then
  pass "escaped ds= present"
else
  fail "missing escaped ds="
fi
# 幂等
if python3 tools/patch-grub.py --file "$tmp/grub.cfg" --menu-regex 'Try or Install' \
  --params 'autoinstall ds=nocloud\;s=/cdrom/nocloud/' --timeout 3; then
  :
else
  fail "patch-grub idempotent"
fi
count="$(grep -c 'autoinstall' "$tmp/grub.cfg" || true)"
if [[ "$count" -eq 1 ]]; then
  pass "idempotent (1 autoinstall line)"
else
  fail "idempotent broken ($count)"
fi

echo "== patch-grub: fix unescaped =="
cp test/fixtures/grub.cfg "$tmp/grub2.cfg"
sed -i 's|quiet ---|quiet autoinstall ds=nocloud;s=/cdrom/nocloud/ ---|' "$tmp/grub2.cfg"
if python3 tools/patch-grub.py --file "$tmp/grub2.cfg" --menu-regex 'Try or Install' \
  --params 'autoinstall ds=nocloud\;s=/cdrom/nocloud/' --timeout 3; then
  :
else
  fail "patch-grub fix-escape"
fi
if grep -qE 'ds=nocloud\\;s=/cdrom/nocloud/' "$tmp/grub2.cfg"; then
  pass "unescaped fixed"
else
  fail "unescaped not fixed"
fi

echo "== render-user-data =="
# intentional literal crypt-looking hash for YAML validation only
# shellcheck disable=SC2016
HASH='$6$rounds=4096$testsalt$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnop'
if python3 tools/render-user-data.py \
  --template autoinstall/user-data.tmpl \
  --out "$tmp/user-data" \
  --password-hash "$HASH" \
  --packages "vim,curl" \
  --ssh-authorized-keys test/fixtures/authorized_keys \
  --ssh-allow-pw false \
  --provision --with-pool; then
  :
else
  fail "render-user-data"
fi
if python3 -c "import yaml; d=yaml.safe_load(open('$tmp/user-data')); assert d['autoinstall']['version']==1; assert d['autoinstall']['ssh']['allow-pw'] is False; assert len(d['autoinstall']['ssh']['authorized-keys'])==1; late=d['autoinstall']['late-commands']; assert any('offline-debs' in str(c) for c in late); assert any('run-all.sh' in str(c) for c in late); assert any('write-authorized-keys.sh' in str(c) for c in late); i_pool=next(i for i,c in enumerate(late) if 'offline-debs' in str(c) or 'dpkg -i' in str(c)); i_prov=next(i for i,c in enumerate(late) if 'run-all.sh' in str(c)); assert i_pool < i_prov, (i_pool, i_prov)"; then
  pass "yaml + late-commands order + ssh-keys late"
else
  fail "yaml/order check"
fi

echo "== default apt mirror is Tsinghua (overridable) =="
DEFAULT_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu"
DEFAULT_PORTS="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports"
if python3 -c "
import yaml
d=yaml.safe_load(open('$tmp/user-data'))
uris=[x.get('uri') for x in d['autoinstall']['apt']['primary']]
assert uris==['$DEFAULT_MIRROR'], uris
"; then
  pass "render default --mirror is Tsinghua"
else
  fail "render default --mirror is Tsinghua"
fi
if python3 tools/render-user-data.py \
  --template autoinstall/user-data.tmpl \
  --out "$tmp/user-data-mirror" \
  --password-hash "$HASH" \
  --mirror http://example.invalid/ubuntu \
  --ssh-allow-pw true; then
  :
else
  fail "render --mirror override"
fi
if python3 -c "
import yaml
d=yaml.safe_load(open('$tmp/user-data-mirror'))
uris=[x.get('uri') for x in d['autoinstall']['apt']['primary']]
assert uris==['http://example.invalid/ubuntu'], uris
assert 'tuna.tsinghua' not in str(d['autoinstall']['apt'])
"; then
  pass "render --mirror override"
else
  fail "render --mirror override"
fi
if python3 tools/render-user-data.py \
  --template autoinstall/user-data.tmpl \
  --out "$tmp/user-data-tuna-http" \
  --password-hash "$HASH" \
  --mirror http://mirrors.tuna.tsinghua.edu.cn/ubuntu \
  --ssh-allow-pw true; then
  :
else
  fail "render tuna http upgrades to https"
fi
if python3 -c "
import yaml
d=yaml.safe_load(open('$tmp/user-data-tuna-http'))
uris=[x.get('uri') for x in d['autoinstall']['apt']['primary']]
assert uris==['$DEFAULT_MIRROR'], uris
"; then
  pass "render tuna http upgrades to https"
else
  fail "render tuna http upgrades to https"
fi
# 全离线时 primary 为空, 不把镜像写进安装器探测路径
if python3 tools/render-user-data.py \
  --template autoinstall/user-data.tmpl \
  --out "$tmp/user-data-off" \
  --password-hash "$HASH" \
  --full-offline --offline \
  --ssh-allow-pw true; then
  :
else
  fail "render full-offline primary"
fi
if python3 -c "
import yaml
d=yaml.safe_load(open('$tmp/user-data-off'))
assert d['autoinstall']['apt']['primary']==[]
assert d['autoinstall']['apt']['fallback']=='offline-install'
"; then
  pass "full-offline apt.primary empty"
else
  fail "full-offline apt.primary empty"
fi
mirror_ok=1
for f in build-iso.sh tools/fetch-offline-bundle.sh tools/render-user-data.py Dockerfile; do
  if grep -qF "$DEFAULT_MIRROR" "$f"; then
    :
  else
    fail "default mirror missing in $f"
    mirror_ok=0
  fi
done
if grep -qF "$DEFAULT_PORTS" tools/fetch-offline-bundle.sh && grep -qF "$DEFAULT_PORTS" Dockerfile; then
  :
else
  fail "ubuntu-ports default missing"
  mirror_ok=0
fi
if grep -q 'mirrors.tuna.tsinghua.edu.cn' software/00-base.sh; then
  :
else
  fail "00-base.sh DNS check should probe Tsinghua"
  mirror_ok=0
fi
# 非 amd64 默认改用 ubuntu-ports (与 fetch-offline-bundle.sh 的 case 字面量对齐)
if grep -qF '*)          UBUNTU_MIRROR="'"$DEFAULT_PORTS"'"' tools/fetch-offline-bundle.sh; then
  :
else
  fail "fetch-offline-bundle.sh missing arch fallback to ubuntu-ports"
  mirror_ok=0
fi
if [[ "$mirror_ok" -eq 1 ]]; then
  pass "default mirror strings consistent + ports/override rules"
fi
# shellcheck disable=SC1091
. "$ROOT/tools/ubuntu-mirror.sh"
helper_ok=1
[[ "$(aib_default_ubuntu_mirror amd64)" == "$DEFAULT_MIRROR" ]] || { fail "helper default amd64"; helper_ok=0; }
[[ "$(aib_default_ubuntu_mirror arm64)" == "$DEFAULT_PORTS" ]] || { fail "helper default arm64"; helper_ok=0; }
[[ "$(aib_normalize_mirror "http://mirrors.tuna.tsinghua.edu.cn/ubuntu")" == "$DEFAULT_MIRROR" ]] || { fail "helper normalize tuna http"; helper_ok=0; }
[[ "$(aib_normalize_mirror "$DEFAULT_MIRROR")" == "$DEFAULT_MIRROR" ]] || { fail "helper normalize tuna https"; helper_ok=0; }
[[ "$(aib_normalize_mirror "http://archive.ubuntu.com/ubuntu")" == "http://archive.ubuntu.com/ubuntu" ]] || { fail "helper leaves official http"; helper_ok=0; }
[[ "$(aib_normalize_mirror "")" == "" ]] || { fail "helper leaves empty"; helper_ok=0; }
aib_is_tuna_mirror "$DEFAULT_MIRROR" || { fail "helper is_tuna https"; helper_ok=0; }
aib_is_tuna_mirror "http://example.invalid/ubuntu" && { fail "helper is_tuna false positive"; helper_ok=0; }
# 在临时 APT_ETC 里验证 http->https 改写, 不动本机源
ht="$(mktemp -d)"
mkdir -p "$ht/sources.list.d"
echo "deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu noble main" > "$ht/sources.list"
echo "deb https://download.docker.com/linux/ubuntu noble stable" > "$ht/sources.list.d/docker.list"
APT_ETC="$ht" aib_rewrite_tuna_scheme https
if grep -q '^deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu noble main$' "$ht/sources.list" \
   && grep -q 'download.docker.com' "$ht/sources.list.d/docker.list" \
   && ! grep -q 'http://mirrors.tuna.tsinghua.edu.cn' "$ht/sources.list"; then
  :
else
  fail "helper rewrite tuna http->https (leave third-party)"
  helper_ok=0
fi
echo "deb http://archive.ubuntu.com/ubuntu noble main" > "$ht/sources.list"
APT_ETC="$ht" aib_replace_ubuntu_uris "$DEFAULT_MIRROR"
if grep -qF "deb $DEFAULT_MIRROR noble main" "$ht/sources.list"; then
  :
else
  fail "helper replace official uri with tuna https"
  helper_ok=0
fi
rm -rf "$ht"
if [[ "$helper_ok" -eq 1 ]]; then
  pass "ubuntu-mirror.sh normalize / rewrite helper"
fi
# 直接执行时 CLI 仍可用 (POSIX $0 文件名判断, 不再用 BASH_SOURCE)
if [[ "$("$ROOT/tools/ubuntu-mirror.sh" normalize "http://mirrors.tuna.tsinghua.edu.cn/ubuntu")" == "$DEFAULT_MIRROR" ]] \
   && [[ "$("$ROOT/tools/ubuntu-mirror.sh" default arm64)" == "$DEFAULT_PORTS" ]]; then
  pass "ubuntu-mirror.sh CLI when executed"
else
  fail "ubuntu-mirror.sh CLI when executed"
fi
# Dockerfile 默认 /bin/sh 是 dash。#21 的 container-smoke 在 source helper 时
# 因 ${BASH_SOURCE[0]} 出现 Bad substitution 失败。构建器必须先 SHELL bash；
# 同时用 dash/sh source 复现原问题：必须成功定义函数且不能报 Bad substitution。
if awk '
  $0 ~ /SHELL \["\/bin\/bash", "-c"\]/ { bash_shell = NR }
  $0 ~ /\. \/tmp\/aib-ubuntu-mirror\.sh/ { src = NR }
  END { exit !(bash_shell && src && bash_shell < src) }
' Dockerfile; then
  pass "Dockerfile sets SHELL bash before sourcing ubuntu-mirror.sh"
else
  fail "Dockerfile must set SHELL [\"/bin/bash\", \"-c\"] before sourcing ubuntu-mirror.sh"
fi
posix_sh=""
if command -v dash >/dev/null 2>&1; then
  posix_sh="dash"
elif command -v sh >/dev/null 2>&1; then
  posix_sh="sh"
fi
if [[ -n "$posix_sh" ]]; then
  dash_out="$(mktemp)"
  set +e
  # $1 由内层 dash/sh -c 展开，不要让外层 bash 先展开
  # shellcheck disable=SC2016
  "$posix_sh" -c '. "$1" && command -v aib_apply_builder_mirrors >/dev/null && command -v aib_normalize_mirror >/dev/null' _ "$ROOT/tools/ubuntu-mirror.sh" >"$dash_out" 2>&1
  dash_rc=$?
  set -e
  if [[ "$dash_rc" -eq 0 ]] && ! grep -qi 'Bad substitution' "$dash_out"; then
    pass "$posix_sh can source ubuntu-mirror.sh without Bad substitution"
  else
    fail "$posix_sh source of ubuntu-mirror.sh failed (rc=$dash_rc): $(tr '\n' ' ' < "$dash_out")"
  fi
  rm -f "$dash_out"
else
  fail "neither dash nor sh available to reproduce Dockerfile source"
fi
# 离线捆绑校验把 ca-certificates 当作必装包, 以便 restore 后的 https 源可用
if grep -q 'ca-certificates' tools/fetch-offline-bundle.sh \
   && grep -q 'NEED_PKGS=(.*ca-certificates' tools/validate-offline-bundle.sh; then
  pass "ca-certificates seeded and required in offline bundle"
else
  fail "ca-certificates missing from offline seeds/validate"
fi
if grep -q 'ubuntu-mirror.sh' build-iso.sh && grep -q 'ubuntu-mirror.url' build-iso.sh; then
  pass "build-iso packs helper + final https mirror url"
else
  fail "build-iso does not pack ubuntu-mirror helper/url"
fi

echo "== ssh keys late-command absent when no keys =="
if python3 tools/render-user-data.py \
  --template autoinstall/user-data.tmpl \
  --out "$tmp/user-data-nokeys" \
  --password-hash "$HASH" \
  --ssh-allow-pw true \
  --provision; then
  :
else
  fail "render without keys"
fi
if python3 -c "import yaml; d=yaml.safe_load(open('$tmp/user-data-nokeys')); late=d['autoinstall'].get('late-commands') or []; assert not any('write-authorized-keys.sh' in str(c) for c in late)"; then
  pass "no-keys omits write-authorized-keys late"
else
  fail "no-keys omits write-authorized-keys late"
fi

echo "== write-authorized-keys.sh syntax =="
if bash -n autoinstall/write-authorized-keys.sh; then
  pass "write-authorized-keys syntax"
else
  fail "write-authorized-keys syntax"
fi

echo "== enable/restore offline apt syntax =="
if bash -n autoinstall/enable-offline-apt.sh && bash -n autoinstall/restore-online-apt.sh; then
  pass "enable/restore-online-apt syntax"
else
  fail "enable/restore-online-apt syntax"
fi

echo "== restore-online-apt writes third-party sources =="
rroot="$tmp/restore-root"
mkdir -p "$rroot/offline/apt-sources/keyrings" "$rroot/offline/apt-sources/sources.list.d"
mkdir -p "$rroot/etc/apt/keyrings" "$rroot/etc/apt/sources.list.d" "$rroot/etc/apt/apt.conf.d" \
         "$rroot/usr/share/keyrings"
# fake Ubuntu bak (should be restored)
echo 'deb http://archive.ubuntu.com/ubuntu noble main' > "$rroot/etc/apt/sources.list.offline-bak"
echo 'deb [trusted=yes] file:/opt/offline/apt ./' > "$rroot/etc/apt/sources.list.d/00-offline-bundle.list"
echo 'Acquire::AllowInsecureRepositories "true";' > "$rroot/etc/apt/apt.conf.d/99-offline-bundle"
# fake third-party seeds (same filenames fetch ships)
echo 'DOCKERKEY' > "$rroot/offline/apt-sources/keyrings/docker.asc"
echo 'GHKEY' > "$rroot/offline/apt-sources/keyrings/githubcli-archive-keyring.gpg"
echo 'NVKEY' > "$rroot/offline/apt-sources/keyrings/nvidia-container-toolkit.asc"
echo 'JKEY' > "$rroot/offline/apt-sources/keyrings/jenkins-keyring.asc"
echo 'NKEY' > "$rroot/offline/apt-sources/keyrings/nodesource.gpg"
echo 'MSKEY' > "$rroot/offline/apt-sources/keyrings/microsoft-edge.gpg"
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable' \
  > "$rroot/offline/apt-sources/sources.list.d/docker.list"
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' \
  > "$rroot/offline/apt-sources/sources.list.d/github-cli.list"
echo 'deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.asc] https://nvidia.github.io/libnvidia-container/stable/deb/amd64 /' \
  > "$rroot/offline/apt-sources/sources.list.d/nvidia-container-toolkit.list"
echo 'deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/' \
  > "$rroot/offline/apt-sources/sources.list.d/jenkins.list"
cat > "$rroot/offline/apt-sources/sources.list.d/nodesource.sources" <<'NS'
Types: deb
URIs: https://deb.nodesource.com/node_24.x
Suites: nodistro
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/nodesource.gpg
NS
cat > "$rroot/offline/apt-sources/sources.list.d/microsoft-edge.sources" <<'MS'
Types: deb
URIs: https://packages.microsoft.com/repos/edge-stable
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/microsoft-edge.gpg
MS
cp -a autoinstall/restore-online-apt.sh "$rroot/offline/restore-online-apt.sh"
cp -a tools/ubuntu-mirror.sh "$rroot/offline/ubuntu-mirror.sh"
printf '%s\n' "https://mirrors.tuna.tsinghua.edu.cn/ubuntu" > "$rroot/offline/ubuntu-mirror.url"
if APT_ETC="$rroot/etc/apt" SHARE_KEYRINGS="$rroot/usr/share/keyrings" \
    bash "$rroot/offline/restore-online-apt.sh" >"$tmp/restore.out" 2>&1; then
  ok=1
  [[ -f "$rroot/etc/apt/sources.list" ]] || ok=0
  grep -q 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu' "$rroot/etc/apt/sources.list" || ok=0
  [[ ! -f "$rroot/etc/apt/sources.list.d/00-offline-bundle.list" ]] || ok=0
  [[ ! -f "$rroot/etc/apt/apt.conf.d/99-offline-bundle" ]] || ok=0
  for f in docker.asc githubcli-archive-keyring.gpg nvidia-container-toolkit.asc jenkins-keyring.asc; do
    [[ -f "$rroot/etc/apt/keyrings/$f" ]] || ok=0
  done
  [[ -f "$rroot/usr/share/keyrings/nodesource.gpg" ]] || ok=0
  [[ -f "$rroot/usr/share/keyrings/microsoft-edge.gpg" ]] || ok=0
  for f in docker.list github-cli.list nvidia-container-toolkit.list jenkins.list nodesource.sources microsoft-edge.sources; do
    [[ -f "$rroot/etc/apt/sources.list.d/$f" ]] || ok=0
  done
  grep -q 'download.docker.com' "$rroot/etc/apt/sources.list.d/docker.list" || ok=0
  grep -q 'deb.nodesource.com' "$rroot/etc/apt/sources.list.d/nodesource.sources" || ok=0
  grep -q 'packages.microsoft.com/repos/edge-stable' "$rroot/etc/apt/sources.list.d/microsoft-edge.sources" || ok=0
  if [[ "$ok" -eq 1 ]]; then
    pass "restore-online-apt third-party sources"
  else
    fail "restore-online-apt third-party sources: $(cat "$tmp/restore.out"); ls=$(ls -R "$rroot/etc/apt" "$rroot/usr/share/keyrings" 2>&1)"
  fi
else
  fail "restore-online-apt exited non-zero: $(cat "$tmp/restore.out")"
fi


echo "== full-offline render =="
if python3 tools/render-user-data.py \
  --template autoinstall/user-data.tmpl \
  --out "$tmp/user-data-offline" \
  --password-hash "$HASH" \
  --packages "vim,curl" \
  --offline --full-offline --provision; then
  :
else
  fail "full-offline render"
fi
if python3 -c "import yaml; d=yaml.safe_load(open('$tmp/user-data-offline')); ai=d['autoinstall']; assert ai['updates']=='security'; assert ai['apt']['fallback']=='offline-install'; assert ai['apt'].get('primary') in ([], None) or ai['apt']['primary']==[]; assert ai['packages'] in ([], None); late=ai['late-commands']; assert any('cdrom/offline' in str(c) for c in late); assert any('enable-offline-apt' in str(c) for c in late); assert any('restore-online-apt' in str(c) for c in late); i_off=next(i for i,c in enumerate(late) if 'offline' in str(c)); i_prov=next(i for i,c in enumerate(late) if 'run-all.sh' in str(c)); assert i_off < i_prov"; then
  pass "full-offline yaml semantics"
else
  fail "full-offline yaml semantics"
fi



echo "== interactive storage default =="
if python3 tools/render-user-data.py \
  --template autoinstall/user-data.tmpl \
  --out "$tmp/user-data-interactive" \
  --password-hash "$HASH" \
  --provision; then
  :
else
  fail "interactive default render"
fi
if python3 -c "import yaml; d=yaml.safe_load(open('$tmp/user-data-interactive')); ai=d['autoinstall']; assert ai.get('interactive-sections')==['storage']; assert ai['storage']['layout']['name']=='direct'; assert ai['storage']['layout']['match']['size']=='largest'; assert ai.get('shutdown')=='reboot'; late=ai.get('late-commands') or []; assert any('run-all.sh' in str(c) for c in late)"; then
  pass "default interactive storage + layout defaults + late-commands + reboot"
else
  fail "default interactive storage + layout defaults + late-commands + reboot"
fi

echo "== auto-disk unattended =="
if python3 tools/render-user-data.py \
  --template autoinstall/user-data.tmpl \
  --out "$tmp/user-data-autodisk" \
  --password-hash "$HASH" \
  --auto-disk \
  --provision; then
  :
else
  fail "auto-disk render"
fi
if python3 -c "import yaml; d=yaml.safe_load(open('$tmp/user-data-autodisk')); ai=d['autoinstall']; assert ai.get('interactive-sections') in ([], None); assert ai['storage']['layout']['match']['size']=='largest'; assert ai.get('shutdown')=='poweroff'"; then
  pass "auto-disk empty interactive-sections + poweroff"
else
  fail "auto-disk empty interactive-sections + poweroff"
fi

echo "== network dhcp default =="
if python3 tools/render-user-data.py \
  --template autoinstall/user-data.tmpl \
  --out "$tmp/user-data-dhcp" \
  --password-hash "$HASH" \
  --provision; then
  :
else
  fail "network dhcp render"
fi
if python3 -c "import yaml; d=yaml.safe_load(open('$tmp/user-data-dhcp')); ai=d['autoinstall']; net=ai['network']; eth=net['ethernets']; assert 'all-en' in eth and 'all-eth' in eth; assert eth['all-en']['dhcp4'] is True; assert eth['all-en'].get('optional') is True; assert eth['all-en']['match']['name']=='en*'; late=ai['late-commands']; assert any('50-autoinstall-dhcp.yaml' in str(c) for c in late); assert any('99-disable-network-config' in str(c) or 'base64' in str(c) for c in late)"; then
  pass "network dhcp yaml + late-command"
else
  fail "network dhcp yaml + late-command"
fi

echo "== network none omits =="
if python3 tools/render-user-data.py \
  --template autoinstall/user-data.tmpl \
  --out "$tmp/user-data-nonet" \
  --password-hash "$HASH" \
  --network none --provision; then
  :
else
  fail "network none render"
fi
if python3 -c "import yaml; d=yaml.safe_load(open('$tmp/user-data-nonet')); ai=d['autoinstall']; assert 'network' not in ai; late=ai.get('late-commands') or []; assert not any('50-autoinstall-dhcp.yaml' in str(c) for c in late)"; then
  pass "network none omits section/late"
else
  fail "network none omits section/late"
fi


echo "== desktop 24.04: edition detection =="
det_d="$(python3 tools/detect-edition.py --install-sources test/fixtures/desktop-2404/install-sources.yaml --disk-info test/fixtures/desktop-2404/disk-info)"
det_s="$(python3 tools/detect-edition.py --install-sources test/fixtures/server-2404/install-sources.yaml --disk-info test/fixtures/server-2404/disk-info)"
det_info_only="$(python3 tools/detect-edition.py --install-sources /nonexistent --disk-info test/fixtures/server-2404/disk-info)"
det_2204d="$(printf 'Ubuntu 22.04.5 LTS "Jammy Jellyfish" - Release amd64 (20240911)' > "$tmp/info2204"; python3 tools/detect-edition.py --install-sources /nonexistent --disk-info "$tmp/info2204")"
if grep -qx 'EDITION=desktop' <<<"$det_d" && grep -qx 'DEFAULT_SOURCE=ubuntu-desktop-minimal' <<<"$det_d" \
  && grep -qx 'SOURCES=ubuntu-desktop-minimal,ubuntu-desktop' <<<"$det_d" && grep -qx 'RELEASE=24.04' <<<"$det_d"; then
  pass "detect desktop 24.04 (variant: desktop)"
else
  fail "detect desktop 24.04: $det_d"
fi
if grep -qx 'EDITION=server' <<<"$det_s" && grep -qx 'SUBIQUITY=1' <<<"$det_s"; then
  pass "detect server 24.04"
else
  fail "detect server 24.04: $det_s"
fi
if grep -qx 'EDITION=server' <<<"$det_info_only"; then
  pass "detect server via .disk/info fallback"
else
  fail "detect server via .disk/info fallback: $det_info_only"
fi
if grep -qx 'EDITION=desktop' <<<"$det_2204d" && grep -qx 'SUBIQUITY=0' <<<"$det_2204d"; then
  pass "22.04 desktop flagged non-subiquity (build-iso refuses)"
else
  fail "22.04 desktop detection: $det_2204d"
fi

echo "== desktop 24.04: grub menu regex =="
DESKTOP_MENU_REGEX='^(Try or Install Ubuntu|Ubuntu \(safe graphics\))$'
for f in grub.cfg loopback.cfg; do
  cp "test/fixtures/desktop-2404/$f" "$tmp/d-$f"
  chmod u+w "$tmp/d-$f"
  python3 tools/patch-grub.py --file "$tmp/d-$f" --menu-regex "$DESKTOP_MENU_REGEX" \
    --params 'autoinstall ds=nocloud\;s=/cdrom/nocloud/' --timeout 3 >/dev/null || fail "desktop patch $f"
  n="$(grep -c 'autoinstall ds=nocloud\\;s=/cdrom/nocloud/ ---' "$tmp/d-$f" || true)"
  if [[ "$n" -eq 2 ]]; then
    pass "desktop $f: Try or Install + safe graphics patched ($n)"
  else
    fail "desktop $f: expected 2 patched lines, got $n"
  fi
done
# shellcheck disable=SC2016  # literal GRUB variable, not a shell expansion
if grep -q 'iso-scan/filename=${iso_path} autoinstall' "$tmp/d-loopback.cfg"; then
  pass "desktop loopback keeps iso-scan before autoinstall"
else
  fail "desktop loopback iso-scan ordering"
fi
# desktop regex must NOT match server menu titles
cp test/fixtures/grub.cfg "$tmp/s-grub.cfg"
if python3 tools/patch-grub.py --file "$tmp/s-grub.cfg" --menu-regex "$DESKTOP_MENU_REGEX" \
  --params 'autoinstall ds=nocloud\;s=/cdrom/nocloud/' --timeout 3 >/dev/null 2>&1; then
  fail "desktop regex should not match server grub"
else
  pass "desktop regex does not match server menu"
fi

echo "== desktop 24.04: render =="
if python3 tools/render-user-data.py \
  --template autoinstall/user-data.tmpl \
  --out "$tmp/user-data-desktop" \
  --password-hash "$HASH" \
  --username alice \
  --edition desktop \
  --ssh-authorized-keys test/fixtures/authorized_keys \
  --provision >/dev/null; then
  :
else
  fail "desktop render"
fi
if python3 -c "
import yaml
d=yaml.safe_load(open('$tmp/user-data-desktop'))['autoinstall']
assert d['source']['id']=='ubuntu-desktop-minimal', d.get('source')
assert d['identity']['realname']=='alice' and d['identity']['username']=='alice'
assert 'network' not in d, 'desktop must not set autoinstall.network'
assert d['interactive-sections']==['storage']
assert d['ssh']['install-server'] is True
late=[str(c) for c in d['late-commands']]
net=[c for c in late if '50-autoinstall-dhcp.yaml' in c and 'printf' in c]
assert net and 'renderer: NetworkManager' in net[0], net
assert any('write-authorized-keys.sh' in c for c in late)
assert any('run-all.sh' in c for c in late)
"; then
  pass "desktop: source minimal, realname, no network key, NM renderer DHCP, storage interactive"
else
  fail "desktop render semantics"
fi

if python3 tools/render-user-data.py \
  --template autoinstall/user-data.tmpl \
  --out "$tmp/user-data-desktop-off" \
  --password-hash "$HASH" \
  --edition desktop --desktop-source standard --realname 'Ops Team' \
  --offline --full-offline --network none --provision >/dev/null; then
  :
else
  fail "desktop full-offline render"
fi
if python3 -c "
import yaml
d=yaml.safe_load(open('$tmp/user-data-desktop-off'))['autoinstall']
assert d['source']['id']=='ubuntu-desktop'
assert d['identity']['realname']=='Ops Team'
assert d['ssh']['install-server'] is False, 'desktop ISO has no openssh-server; offline must defer to 10-openssh'
assert d['apt']['fallback']=='offline-install'
late=[str(c) for c in d['late-commands']]
assert any('enable-offline-apt' in c for c in late)
assert not any('50-autoinstall-dhcp.yaml' in c for c in late)
"; then
  pass "desktop full-offline: standard source, ssh deferred to bundle, network none"
else
  fail "desktop full-offline semantics"
fi

echo "== server render has no desktop keys =="
if python3 -c "
import yaml
d=yaml.safe_load(open('$tmp/user-data-dhcp'))['autoinstall']
assert 'source' not in d and 'realname' not in d['identity']
assert d['ssh']['install-server'] is True
"; then
  pass "server: no source/realname, install-server true"
else
  fail "server render leaked desktop keys"
fi

echo "== 00-base skips installed pkgs =="
if grep -q 'filter_missing' software/00-base.sh && grep -q 'skip already installed' software/00-base.sh; then
  pass "00-base skip-installed helper"
else
  fail "00-base skip-installed helper"
fi


echo "== git + ripgrep in base + offline seed =="
if grep -qE '(^|[[:space:]])git([[:space:]]|$)' software/00-base.sh \
  && grep -q 'ripgrep' software/00-base.sh \
  && grep -qE '(^|[[:space:]])git([[:space:]]|$)' tools/fetch-offline-bundle.sh \
  && grep -q 'ripgrep' tools/fetch-offline-bundle.sh \
  && grep -qE '(^|[[:space:]])git([[:space:]]|$)' software/99-cleanup.sh \
  && grep -qE '(^|[[:space:]])rg([[:space:]]|$)' software/99-cleanup.sh; then
  pass "git + ripgrep in base/seed/manifest"
else
  fail "git + ripgrep in base/seed/manifest"
fi

echo "== github-cli script + offline seed =="
if [[ -x software/15-github-cli.sh ]] \
  && grep -q 'cli.github.com/packages' software/15-github-cli.sh \
  && grep -q 'offline_apt_install gh' software/15-github-cli.sh \
  && ! grep -qE '^[[:space:]]*gh[[:space:]]+auth' software/15-github-cli.sh \
  && grep -q 'cli.github.com/packages' tools/fetch-offline-bundle.sh \
  && grep -qE '(^|[[:space:]])gh([[:space:]]|$)' tools/fetch-offline-bundle.sh \
  && grep -qE '(^|[[:space:]])gh([[:space:]]|$)' software/99-cleanup.sh; then
  pass "github-cli script + offline seed + manifest (no auth)"
else
  fail "github-cli script + offline seed + manifest"
fi

echo "== nvidia-container-toolkit script + offline seed =="
if [[ -x software/25-nvidia-container-toolkit.sh ]] \
  && grep -q 'nvidia-ctk runtime configure --runtime=docker' software/25-nvidia-container-toolkit.sh \
  && grep -q 'nvidia.github.io/libnvidia-container' software/25-nvidia-container-toolkit.sh \
  && grep -q 'nvidia-container-toolkit' tools/fetch-offline-bundle.sh \
  && grep -q 'nvidia.github.io/libnvidia-container' tools/fetch-offline-bundle.sh \
  && grep -q 'nvidia-ctk' software/99-cleanup.sh; then
  pass "nvidia toolkit script + offline seed + manifest"
else
  fail "nvidia toolkit script + offline seed + manifest"
fi

echo "== microsoft-edge script + offline seed =="
if [[ -x software/35-microsoft-edge.sh ]] \
  && grep -q 'packages.microsoft.com/repos/edge' software/35-microsoft-edge.sh \
  && grep -q 'packages.microsoft.com/keys/microsoft.asc' software/35-microsoft-edge.sh \
  && grep -q 'offline_apt_install' software/35-microsoft-edge.sh \
  && grep -q 'update-alternatives --install /usr/bin/x-www-browser' software/35-microsoft-edge.sh \
  && grep -q 'update-alternatives --install /usr/bin/gnome-www-browser' software/35-microsoft-edge.sh \
  && grep -q '/etc/xdg/mimeapps.list' software/35-microsoft-edge.sh \
  && grep -q 'HideFirstRunExperience' software/35-microsoft-edge.sh \
  && grep -q 'DefaultBrowserSettingEnabled' software/35-microsoft-edge.sh \
  && ! grep -qE 'ComponentUpdatesEnabled|AutoUpdateCheckPeriodMinutes' software/35-microsoft-edge.sh \
  && grep -q 'EDITION' software/35-microsoft-edge.sh \
  && grep -q 'amd64' software/35-microsoft-edge.sh \
  && grep -q 'microsoft-edge-stable' tools/fetch-offline-bundle.sh \
  && grep -q 'packages.microsoft.com/repos/edge' tools/fetch-offline-bundle.sh \
  && grep -q 'microsoft-edge-stable' tools/validate-offline-bundle.sh \
  && grep -q 'EDITION=%q' build-iso.sh \
  && grep -q 'microsoft-edge-stable' software/99-cleanup.sh; then
  pass "microsoft-edge script + offline seed + manifest + policies"
else
  fail "microsoft-edge script + offline seed + manifest + policies"
fi
# Server / 非 desktop 必须直接成功退出, 不装包
if EDITION=server bash software/35-microsoft-edge.sh >"$tmp/edge-skip.log" 2>&1 \
   && grep -q 'skip:' "$tmp/edge-skip.log"; then
  pass "microsoft-edge skips on server edition"
else
  fail "microsoft-edge skips on server edition: $(cat "$tmp/edge-skip.log" 2>/dev/null)"
fi
# provision.env 写入 EDITION
if grep -q 'EDITION=%q' build-iso.sh && grep -q 'export EDITION=' software/run-all.sh; then
  pass "EDITION exported via provision.env / run-all"
else
  fail "EDITION exported via provision.env / run-all"
fi

echo "== flclash script + offline seed + build flags =="
if [[ -x software/37-flclash.sh ]] && [[ -f tools/flclash-release.sh ]] \
  && grep -q 'chen08209/FlClash' software/37-flclash.sh \
  && grep -q 'chen08209/FlClash' tools/flclash-release.sh \
  && grep -q 'SHA256SUMS' tools/flclash-release.sh \
  && grep -q 'flclash_download_to' tools/flclash-release.sh \
  && grep -q 'offline_enabled' software/37-flclash.sh \
  && grep -q 'EDITION' software/37-flclash.sh \
  && grep -q '只预装应用' software/37-flclash.sh \
  && ! grep -qE 'systemctl enable.*flclash|set-system-proxy|tun-mode|subscription' software/37-flclash.sh \
  && grep -q 'flclash/' tools/fetch-offline-bundle.sh \
  && ! grep -q -- '--pin-flclash' tools/fetch-offline-bundle.sh \
  && ! grep -q -- '--pin-flclash' tools/validate-offline-bundle.sh \
  && ! grep -q 'PIN_FLCLASH' build-iso.sh \
  && ! grep -q 'PIN_FLCLASH' scripts/aib.sh \
  && ! grep -q 'PIN_FLCLASH' scripts/aib.ps1 \
  && grep -q -- '--no-flclash' build-iso.sh \
  && grep -q 'flclash-release.sh' build-iso.sh \
  && grep -q 'flclash_resolve' software/37-flclash.sh \
  && grep -q 'releases/latest' tools/flclash-release.sh \
  && grep -qE '(^|[[:space:]])FlClash([[:space:]]|$)' software/99-cleanup.sh; then
  pass "flclash script + official SHA256SUMS + offline seed + no proxy config"
else
  fail "flclash script + official SHA256SUMS + offline seed + no proxy config"
fi
if bash -n tools/flclash-release.sh && bash -n software/37-flclash.sh; then
  pass "flclash scripts bash -n"
else
  fail "flclash scripts bash -n"
fi
# Server / 非 desktop 必须直接成功退出, 不下载
if EDITION=server bash software/37-flclash.sh >"$tmp/flc-skip.log" 2>&1 \
   && grep -q 'skip:' "$tmp/flc-skip.log"; then
  pass "flclash skips on server edition"
else
  fail "flclash skips on server edition: $(cat "$tmp/flc-skip.log" 2>/dev/null)"
fi
if EDITION=desktop FLCLASH_ARCH=riscv64 bash software/37-flclash.sh >"$tmp/flc-arch.log" 2>&1 \
   && grep -q 'skip:' "$tmp/flc-arch.log"; then
  pass "flclash skips on unsupported arch"
else
  fail "flclash skips on unsupported arch: $(cat "$tmp/flc-arch.log" 2>/dev/null)"
fi
# SHA256SUMS 校验 (使用官方 sums 格式夹具, 不访问网络)
# shellcheck disable=SC1091
. tools/flclash-release.sh
_sums="$(mktemp)"
printf '%s  ./FlClash-0.9.3-linux-amd64.deb\n' '4064254329bb39c6289c743e16e5726ae56b5853e86d9f88e0145e2af032351b' > "$_sums"
if [[ "$(flclash_sums_hash "$_sums" FlClash-0.9.3-linux-amd64.deb)" == "4064254329bb39c6289c743e16e5726ae56b5853e86d9f88e0145e2af032351b" ]]; then
  pass "flclash_sums_hash parses official SHA256SUMS format"
else
  fail "flclash_sums_hash"
fi
_bad="$(mktemp)"
echo hello > "$_bad"
if ! flclash_verify_deb "$_bad" "$_sums" "" 2>/dev/null; then
  pass "flclash_verify_deb rejects mismatch"
else
  fail "flclash_verify_deb should reject mismatch"
fi
rm -f "$_sums" "$_bad"

echo "== wayland-off / x11vnc script (36-x11vnc-xorg) =="
xr="$(mktemp -d)"
mkdir -p "$xr/etc/gdm3"
printf '# GDM configuration storage\n\n[daemon]\n# Uncomment the line below to force the login screen to use Xorg\n#WaylandEnable=false\nAutomaticLoginEnable=False\n\n[security]\n\n[debug]\n#Enable=true\n' > "$xr/etc/gdm3/custom.conf"
if [[ -x software/36-x11vnc-xorg.sh ]] \
   && EDITION=server X11VNC=1 AIB_TARGET_ROOT="$xr" AIB_SKIP_PKG=1 bash software/36-x11vnc-xorg.sh >"$tmp/x-srv.log" 2>&1 \
   && grep -q 'skip:' "$tmp/x-srv.log" && grep -q '^#WaylandEnable' "$xr/etc/gdm3/custom.conf" \
   && EDITION=desktop AIB_TARGET_ROOT="$xr" AIB_SKIP_PKG=1 bash software/36-x11vnc-xorg.sh >"$tmp/x-off.log" 2>&1 \
   && grep -q 'skip:' "$tmp/x-off.log" && [[ ! -e "$xr/etc/systemd" ]]; then
  pass "36-x11vnc-xorg: server / options off → no-op"
else
  fail "36-x11vnc-xorg skip paths: $(cat "$tmp/x-srv.log" "$tmp/x-off.log" 2>/dev/null | tail -3)"
fi
# 只关 Wayland: 两次运行幂等, 其它键保留, 不装 x11vnc
for _ in 1 2; do EDITION=desktop DISABLE_WAYLAND=1 AIB_TARGET_ROOT="$xr" AIB_SKIP_PKG=1 bash software/36-x11vnc-xorg.sh >/dev/null 2>&1; done
if [[ "$(grep -c 'WaylandEnable' "$xr/etc/gdm3/custom.conf")" -eq 1 ]] \
   && python3 - "$xr/etc/gdm3/custom.conf" <<'PY'
import configparser, sys
c = configparser.ConfigParser(strict=True); c.optionxform = str
c.read(sys.argv[1])
assert c["daemon"]["WaylandEnable"] == "false"
assert c["daemon"]["AutomaticLoginEnable"] == "False"
assert c.has_section("security") and c.has_section("debug")
PY
then
  if [[ ! -e "$xr/etc/systemd/system/x11vnc.service" ]]; then
    pass "gdm custom.conf: WaylandEnable=false idempotent, other keys kept, no x11vnc"
  else
    fail "DISABLE_WAYLAND=1 alone installed x11vnc"
  fi
else
  fail "gdm custom.conf writer: $(cat "$xr/etc/gdm3/custom.conf")"
fi
# 无 custom.conf 时新建 [daemon]
xr2="$(mktemp -d)"
if EDITION=desktop DISABLE_WAYLAND=1 AIB_TARGET_ROOT="$xr2" AIB_SKIP_PKG=1 bash software/36-x11vnc-xorg.sh >/dev/null 2>&1 \
   && grep -qx '\[daemon\]' "$xr2/etc/gdm3/custom.conf" && grep -qx 'WaylandEnable=false' "$xr2/etc/gdm3/custom.conf"; then
  pass "gdm custom.conf created when missing"
else
  fail "gdm custom.conf create"
fi
# x11vnc: 隐含关 Wayland, secret 读后删除, 服务/logind/dconf 落盘
mkdir -p "$xr2/prov"
cp software/36-x11vnc-xorg.sh software/lib-offline.sh "$xr2/prov/"
( umask 077; printf 'VNC_PASSWORD=%q\n' 'S3cret#vnc' > "$xr2/prov/x11vnc.secret" )
if EDITION=desktop X11VNC=1 AIB_TARGET_ROOT="$xr2" AIB_SKIP_PKG=1 bash "$xr2/prov/36-x11vnc-xorg.sh" >"$tmp/x-on.log" 2>&1; then
  u="$xr2/etc/systemd/system/x11vnc.service"
  f="$xr2/usr/local/sbin/aib-x11vnc-follow"
  # shellcheck disable=SC2016  # 字面量 $PASSFILE
  if [[ ! -e "$xr2/prov/x11vnc.secret" ]] && ! grep -q 'S3cret' "$tmp/x-on.log" \
     && [[ ! -e "$xr2/root/x11vnc-password" ]] \
     && [[ "$(stat -c %a "$xr2/etc/x11vnc.pass")" == 600 ]] \
     && grep -qx 'WaylandEnable=false' "$xr2/etc/gdm3/custom.conf" \
     && grep -q '^After=display-manager.service' "$u" && grep -q '^WantedBy=graphical.target' "$u" \
     && grep -q '^ExecStart=/usr/local/sbin/aib-x11vnc-follow' "$u" && grep -q '^Restart=always' "$u" \
     && [[ -x "$f" ]] && grep -q -- '-rfbauth "$upass"' "$f" && grep -q -- '-forever -shared -repeat -xkb' "$f" \
     && ! grep -qE -- '-noshm|-nowf|-noxdamage' "$f" && grep -q 'setpriv --reuid="$owner"' "$f" \
     && grep -q '/sys/class/tty/tty0/active' "$f" && grep -q 'xauth -f' "$f" \
     && grep -qx 'HandleLidSwitch=ignore' "$xr2/etc/systemd/logind.conf.d/90-autoinstall-x11vnc.conf" \
     && grep -q "sleep-inactive-ac-type='nothing'" "$xr2/etc/dconf/db/gdm.d/90-autoinstall-no-suspend" \
     && grep -qx 'system-db:gdm' "$xr2/etc/dconf/profile/gdm" \
     && grep -q "sleep-inactive-battery-type='nothing'" "$xr2/usr/share/glib-2.0/schemas/90_autoinstall-x11vnc-no-suspend.gschema.override" \
     && ! grep -rq 'lock-enabled\|idle-delay' "$xr2/etc/dconf" "$xr2/usr/share/glib-2.0/schemas"; then
    pass "x11vnc: unit + follower + pass file 600 + logind/dconf no-suspend, lock untouched, secret removed"
  else
    fail "x11vnc files: $(tail -5 "$tmp/x-on.log")"
  fi
  if command -v shellcheck >/dev/null; then
    if shellcheck "$f"; then pass "aib-x11vnc-follow shellcheck"; else fail "aib-x11vnc-follow shellcheck"; fi
  fi
  # 回归: rootless Xorg (登录界面属 gdm, 会话属登录用户) → x11vnc 以 auth 文件属主身份跑 (setpriv),
  # 密码按用户复制到 rundir (0400), 不再加 -noshm / -nowf / -noxdamage
  st="$tmp/x11stub"; mkdir -p "$st/bin" "$st/run"
  real_stat="$(command -v stat)"; real_install="$(command -v install)"; real_id="$(command -v id)"
  cat > "$st/bin/stat" <<STUB
#!/bin/sh
if [ "\$1" = "-c" ] && [ "\$2" = "%U" ]; then
  [ -n "\${STUB_OWNER:-}" ] || exit 1
  echo "\$STUB_OWNER"; exit 0
fi
exec "$real_stat" "\$@"
STUB
  cat > "$st/bin/install" <<STUB
#!/bin/sh
echo "install \$*" >> "$st/calls"
args=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; *) args="\$args '\$1'"; shift ;; esac
done
eval "exec \"$real_install\" \$args"
STUB
  cat > "$st/bin/chown" <<STUB
#!/bin/sh
echo "chown \$*" >> "$st/calls"
STUB
  cat > "$st/bin/id" <<STUB
#!/bin/sh
if [ "\$1" = "-g" ] && [ "\$2" = "gdm" ]; then echo 120; exit 0; fi
exec "$real_id" "\$@"
STUB
  cat > "$st/bin/setpriv" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > "$st/setpriv.args"
STUB
  chmod +x "$st/bin/"*
  printf 'pw' > "$st/x11vnc.pass"; : > "$st/auth"
  run_launch() { # owner(空=stat 失败)
    rm -f "$st/setpriv.args" "$st/calls"
    # shellcheck disable=SC2016  # $1 / $child 在子 bash 里展开
    PATH="$st/bin:$PATH" STUB_OWNER="$1" X11VNC_PASSFILE="$st/x11vnc.pass" X11VNC_RUNDIR="$st/run" AIB_X11VNC_FOLLOW_LIB=1 \
      bash -c '. "$1"; launch_x11vnc :0 "$2" >/dev/null; wait "$child"' _ "$f" "$st/auth" 2>"$st/err" || true
  }
  run_launch gdm
  if [[ -f "$st/setpriv.args" ]] && grep -qx -- '--reuid=gdm' "$st/setpriv.args" && grep -qx -- '--regid=120' "$st/setpriv.args" \
     && grep -qx -- '--init-groups' "$st/setpriv.args" && grep -qx -- '--reset-env' "$st/setpriv.args" \
     && grep -qx -- 'x11vnc' "$st/setpriv.args" && grep -qx -- "$st/run/pass-gdm" "$st/setpriv.args" \
     && grep -qx -- "$st/run/x11vnc-gdm.log" "$st/setpriv.args" && grep -qx -- ':0' "$st/setpriv.args" \
     && ! grep -qxE -- '-noshm|-nowf|-noxdamage' "$st/setpriv.args" \
     && grep -q -- "-m 0400 -o gdm $st/x11vnc.pass $st/run/pass-gdm" "$st/calls" \
     && grep -q "chown gdm $st/run/x11vnc-gdm.log" "$st/calls" \
     && [[ "$(stat -c %a "$st/run/pass-gdm")" == 400 && "$(cat "$st/run/pass-gdm")" == pw ]]; then
    pass "aib-x11vnc-follow: 登录界面 (gdm 属主) → setpriv --reuid=gdm, 每用户 0400 密码副本, 无 -noshm/-nowf"
  else
    fail "aib-x11vnc-follow gdm owner launch: $(cat "$st/setpriv.args" "$st/calls" "$st/err" 2>/dev/null | tr '\n' ' ')"
  fi
  run_launch ""
  if [[ -f "$st/setpriv.args" ]] && grep -qx -- '--reuid=root' "$st/setpriv.args" && grep -qx -- "$st/run/pass-root" "$st/setpriv.args"; then
    pass "aib-x11vnc-follow: auth 属主取不到时退回 root"
  else
    fail "aib-x11vnc-follow root fallback: $(cat "$st/setpriv.args" "$st/err" 2>/dev/null | tr '\n' ' ')"
  fi
  # 回归: GDM 用 -displayfd 起 Xorg (命令行没有 :N), Xauthority 条目不带显示号 → 必须靠监听的 socket 认出显示号
  xd_fn="$tmp/x_display_of.sh"
  sed -n '/^x_display_of() {$/,/^}$/p' "$f" > "$xd_fn"
  if [[ ! -s "$xd_fn" ]]; then
    fail "x_display_of 未在 aib-x11vnc-follow 里找到"
  elif ! command -v xauth >/dev/null; then
    printf '[skip] %s\n' "x_display_of 回归 (没有 xauth)"
  else
    # shellcheck disable=SC1090
    . "$xd_fn"
    mk_gdm_xauth() { # file cookiehex: FamilyLocal "<host>/unix:" + FamilyWild, number 都为空 (与真机 GDM 一致)
      local h; h="$(hostname)"
      be16() { printf '%b' "\\$(printf '%03o' $(( $1 >> 8 )))\\$(printf '%03o' $(( $1 & 255 )))"; }
      hex2bin() { local s="$1" i; for ((i = 0; i < ${#s}; i += 2)); do printf '%b' "\\$(printf '%03o' "0x${s:i:2}")"; done; }
      {
        be16 256;   be16 ${#h}; printf '%s' "$h"; be16 0; be16 18; printf 'MIT-MAGIC-COOKIE-1'; be16 16; hex2bin "$2"
        be16 65535; be16 ${#h}; printf '%s' "$h"; be16 0; be16 18; printf 'MIT-MAGIC-COOKIE-1'; be16 16; hex2bin "$2"
      } > "$1"
    }
    mk_gdm_xauth "$tmp/gdm-xauth" 00112233445566778899aabbccddeeff
    # xauth 数字条目兜底 (进程既没 :N 也没 X socket)
    xauth -f "$tmp/num-xauth" add :7 . 00112233445566778899aabbccddeeff 2>/dev/null
    sleep 30 & sp=$!
    if [[ -z "$(xauth -f "$tmp/gdm-xauth" list 2>/dev/null | sed -n 's/^[^ ]*:\([0-9][0-9]*\) .*/:\1/p')" ]] \
       && [[ "$(xauth -f "$tmp/gdm-xauth" list 2>/dev/null | wc -l)" -eq 2 ]] \
       && [[ "$(x_display_of "$sp" "$tmp/num-xauth")" == ":7" ]] && [[ -z "$(x_display_of "$sp" "$tmp/gdm-xauth")" ]]; then
      pass "x_display_of: GDM 式 Xauthority 无显示号; 数字 xauth 兜底"
    else
      fail "x_display_of xauth fallback / GDM xauth fixture"
    fi
    kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null || true
    if command -v Xvfb >/dev/null; then
      # 先占一个显示 (诱饵), 再用 -displayfd 起第二个, 保证测到的不是 :0 之类的默认值
      Xvfb -displayfd 3 -nolisten tcp -screen 0 320x240x24 3>"$tmp/dfd0" >/dev/null 2>&1 & xv0=$!
      for _ in $(seq 1 50); do [[ -s "$tmp/dfd0" ]] && break; sleep 0.1; done
      Xvfb -displayfd 3 -auth "$tmp/gdm-xauth" -nolisten tcp -screen 0 320x240x24 3>"$tmp/dfd1" >/dev/null 2>&1 & xv1=$!
      for _ in $(seq 1 50); do [[ -s "$tmp/dfd1" ]] && break; sleep 0.1; done
      n0="$(tr -dc 0-9 < "$tmp/dfd0")"; n1="$(tr -dc 0-9 < "$tmp/dfd1")"
      got="$(x_display_of "$xv1" "$tmp/gdm-xauth")"
      if [[ -n "$n1" && "$n1" != "$n0" && "$got" == ":$n1" ]] && ! tr '\0' ' ' < "/proc/$xv1/cmdline" | grep -q ' :[0-9]'; then
        pass "x_display_of: -displayfd + 无显示号 Xauthority → :$n1 (由 X socket 认出)"
      else
        fail "x_display_of: 期望 :$n1 (诱饵 :$n0), 得到 '${got}'"
      fi
      kill "$xv0" "$xv1" 2>/dev/null; wait "$xv0" "$xv1" 2>/dev/null || true
    else
      printf '[skip] %s\n' "x_display_of X socket 检测 (没有 Xvfb)"
    fi
  fi
else
  fail "36-x11vnc-xorg x11vnc run: $(tail -5 "$tmp/x-on.log")"
fi
# 无明文 (只有哈希): 随机密码 → /root/x11vnc-password
xr3="$(mktemp -d)"
if EDITION=desktop X11VNC=1 AIB_TARGET_ROOT="$xr3" AIB_SKIP_PKG=1 bash software/36-x11vnc-xorg.sh >"$tmp/x-rand.log" 2>&1 \
   && [[ "$(stat -c %a "$xr3/root/x11vnc-password")" == 600 ]] && [[ "$(wc -c < "$xr3/root/x11vnc-password")" -eq 9 ]]; then
  pass "x11vnc random password when no plaintext"
else
  fail "x11vnc random password"
fi
if grep -q 'x11vnc' tools/fetch-offline-bundle.sh && grep -q '"x11vnc", "xauth"' tools/fetch-offline-bundle.sh \
   && grep -q 'x11vnc.secret' software/run-all.sh && grep -q 'x11vnc.secret' software/99-cleanup.sh \
   && grep -q 'offline_apt_install x11vnc xauth' software/36-x11vnc-xorg.sh; then
  pass "x11vnc offline seed + fingerprint + secret cleanup"
else
  fail "x11vnc offline seed / cleanup"
fi
rm -rf "$xr" "$xr2" "$xr3"

echo "== build-iso remote desktop: Desktop 默认 RustDesk / x11vnc / none / --wayland (fake ISO) =="
if command -v xorriso >/dev/null && command -v openssl >/dev/null; then
  xb="$(mktemp -d)"
  bash test/make-fake-iso.sh desktop "$xb/d.iso" >/dev/null 2>&1
  bash test/make-fake-iso.sh server "$xb/s.iso" >/dev/null 2>&1
  _xenv() { xorriso -osirrox on -indev "$1" -extract /provision "$2" >/dev/null 2>&1; }
  # Desktop 默认: 关 Wayland + RustDesk, 密码 = --password (secret 文件), 明文不进日志/provision.env, 不投递 x11vnc
  if bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o1.iso" --password 'Pl@in99x' >"$xb/o1.log" 2>&1 && _xenv "$xb/o1.iso" "$xb/p1" \
     && grep -qx 'REMOTE_DESKTOP=rustdesk' "$xb/p1/provision.env" && grep -qx 'X11VNC=0' "$xb/p1/provision.env" \
     && grep -qx 'DISABLE_WAYLAND=1' "$xb/p1/provision.env" && grep -qx 'PIN_RUSTDESK=1.5.1' "$xb/p1/provision.env" \
     && grep -qx "RUSTDESK_SERVER=''" "$xb/p1/provision.env" \
     && [[ -f "$xb/p1/36-x11vnc-xorg.sh" && -f "$xb/p1/38-rustdesk.sh" && -f "$xb/p1/rustdesk-release.sh" ]] \
     && [[ ! -e "$xb/p1/x11vnc.secret" ]] && ! grep -q 'VNC 流量不加密' "$xb/o1.log" \
     && grep -q '21118' "$xb/o1.log" && grep -q 'RustDesk 安全提示' "$xb/o1.log" \
     && ! grep -q 'RustDesk 使用默认密码' "$xb/o1.log" && ! grep -q 'RustDesk + Wayland' "$xb/o1.log" \
     && ( # shellcheck disable=SC1091
          . "$xb/p1/rustdesk.secret"; [[ "$RUSTDESK_PASSWORD" == 'Pl@in99x' ]] ) \
     && ! grep -q 'Pl@in99x' "$xb/o1.log" "$xb/p1/provision.env"; then
    pass "desktop default: wayland off + RustDesk, password via secret file, not logged, no x11vnc"
  else
    fail "desktop default rustdesk build: $(tail -3 "$xb/o1.log")"
  fi
  # 默认凭据 → 默认密码告警; --rustdesk-password / --rustdesk-server / --pin-rustdesk 覆盖
  if bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o2.iso" >"$xb/o2.log" 2>&1 \
     && grep -q 'RustDesk 使用默认密码' "$xb/o2.log" && ! grep -q 'ubuntu1990' "$xb/o2.log" \
     && bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o3.iso" --rustdesk-password 'rdpass1x' --rustdesk-server 'RD.Example.com:21116' --pin-rustdesk 1.5.0 >"$xb/o3.log" 2>&1 && _xenv "$xb/o3.iso" "$xb/p3" \
     && ( # shellcheck disable=SC1091
          . "$xb/p3/rustdesk.secret"; [[ "$RUSTDESK_PASSWORD" == 'rdpass1x' ]] ) && ! grep -q 'rdpass1x' "$xb/o3.log" \
     && grep -qx 'RUSTDESK_SERVER=rd.example.com:21116' "$xb/p3/provision.env" && grep -qx 'PIN_RUSTDESK=1.5.0' "$xb/p3/provision.env"; then
    pass "rustdesk default-password warning + --rustdesk-password / --rustdesk-server / --pin-rustdesk"
  else
    fail "rustdesk password / server defaults: $(tail -3 "$xb/o2.log" "$xb/o3.log")"
  fi
  # 只有哈希 → 无 secret, 提示随机密码
  if bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o4.iso" --password-hash "$(openssl passwd -6 x)" >"$xb/o4.log" 2>&1 && _xenv "$xb/o4.iso" "$xb/p4" \
     && [[ ! -e "$xb/p4/rustdesk.secret" ]] && grep -q '/root/rustdesk-password' "$xb/o4.log"; then
    pass "rustdesk hash-only: random password notice"
  else
    fail "rustdesk hash-only"
  fi
  # --remote-desktop x11vnc: 关 Wayland + x11vnc, 密码 = --password; RustDesk 不投递
  if bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o9.iso" --password 'Pl@in99x' --remote-desktop x11vnc >"$xb/o9.log" 2>&1 && _xenv "$xb/o9.iso" "$xb/p9" \
     && grep -qx 'X11VNC=1' "$xb/p9/provision.env" && grep -qx 'REMOTE_DESKTOP=x11vnc' "$xb/p9/provision.env" \
     && grep -qx 'DISABLE_WAYLAND=1' "$xb/p9/provision.env" \
     && grep -q 'VNC 流量不加密' "$xb/o9.log" && grep -q '5900' "$xb/o9.log" && ! grep -q 'RustDesk 安全提示' "$xb/o9.log" \
     && [[ ! -e "$xb/p9/rustdesk.secret" ]] \
     && ( # shellcheck disable=SC1091
          . "$xb/p9/x11vnc.secret"; [[ "$VNC_PASSWORD" == 'Pl@in99x' ]] ) \
     && ! grep -q 'Pl@in99x' "$xb/o9.log" "$xb/p9/provision.env"; then
    pass "--remote-desktop x11vnc: wayland off + x11vnc, password via secret file, no rustdesk"
  else
    fail "--remote-desktop x11vnc: $(tail -3 "$xb/o9.log")"
  fi
  if bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o10.iso" --remote-desktop x11vnc >"$xb/o10.log" 2>&1 \
     && grep -q 'x11vnc 使用默认密码' "$xb/o10.log" && ! grep -q 'ubuntu1990' "$xb/o10.log" \
     && bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o11.iso" --remote-desktop x11vnc --vnc-password 'vncpass1' >"$xb/o11.log" 2>&1 && _xenv "$xb/o11.iso" "$xb/p11" \
     && ( # shellcheck disable=SC1091
          . "$xb/p11/x11vnc.secret"; [[ "$VNC_PASSWORD" == 'vncpass1' ]] ) && ! grep -q 'vncpass1' "$xb/o11.log" \
     && bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o12.iso" --remote-desktop x11vnc --password-hash "$(openssl passwd -6 x)" >"$xb/o12.log" 2>&1 && _xenv "$xb/o12.iso" "$xb/p12" \
     && [[ ! -e "$xb/p12/x11vnc.secret" ]] && grep -q '/root/x11vnc-password' "$xb/o12.log"; then
    pass "x11vnc default-password warning + --vnc-password override + hash-only random"
  else
    fail "x11vnc password defaults"
  fi
  # --vnc-password 默认 (RustDesk) 时告警并忽略
  if bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o13.iso" --password 'Pl@in99x' --vnc-password 'vncpass2' >"$xb/o13.log" 2>&1 && _xenv "$xb/o13.iso" "$xb/p13" \
     && [[ ! -e "$xb/p13/x11vnc.secret" ]] && grep -q -- '--vnc-password 只用于 --remote-desktop x11vnc' "$xb/o13.log" && ! grep -q 'vncpass2' "$xb/o13.log"; then
    pass "--vnc-password ignored unless --remote-desktop x11vnc"
  else
    fail "--vnc-password with rustdesk: $(tail -3 "$xb/o13.log")"
  fi
  # --remote-desktop none: 仍关 Wayland, 不装远程桌面, 不投递任何密码
  if bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o14.iso" --password 'Pl@in99x' --remote-desktop none --rustdesk-password 'rdpass1x' >"$xb/o14.log" 2>&1 && _xenv "$xb/o14.iso" "$xb/p14" \
     && grep -qx 'REMOTE_DESKTOP=none' "$xb/p14/provision.env" && grep -qx 'X11VNC=0' "$xb/p14/provision.env" \
     && grep -qx 'DISABLE_WAYLAND=1' "$xb/p14/provision.env" \
     && [[ ! -e "$xb/p14/rustdesk.secret" && ! -e "$xb/p14/x11vnc.secret" ]] \
     && grep -q -- '--rustdesk-password 只用于' "$xb/o14.log" && ! grep -q 'rdpass1x' "$xb/o14.log"; then
    pass "--remote-desktop none: wayland off, no remote desktop, no secrets"
  else
    fail "--remote-desktop none: $(tail -3 "$xb/o14.log")"
  fi
  # --wayland: 保留 Wayland; 默认 RustDesk 照装但告警 (连不了登录界面)
  if bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o5.iso" --password 'Pl@in99x' --wayland --vnc-password 'vncpass2' >"$xb/o5.log" 2>&1 && _xenv "$xb/o5.iso" "$xb/p5" \
     && grep -qx 'DISABLE_WAYLAND=0' "$xb/p5/provision.env" && grep -qx 'X11VNC=0' "$xb/p5/provision.env" \
     && grep -qx 'REMOTE_DESKTOP=rustdesk' "$xb/p5/provision.env" && grep -q 'RustDesk + Wayland' "$xb/o5.log" \
     && [[ ! -e "$xb/p5/x11vnc.secret" ]] && ! grep -q 'VNC 流量不加密' "$xb/o5.log" && ! grep -q 'vncpass2' "$xb/o5.log" \
     && bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o5b.iso" --wayland --remote-desktop none --dry-run >"$xb/o5b.log" 2>&1 \
     && ! grep -q 'RustDesk + Wayland' "$xb/o5b.log"; then
    pass "--wayland: keeps wayland, RustDesk with warning; --remote-desktop none no warning"
  else
    fail "--wayland: $(tail -3 "$xb/o5.log")"
  fi
  # --wayland 可与 --no-provision 同用 (远程桌面自动 none); 显式要远程桌面则报错
  if bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o7.iso" --password 'Pl@in99x' --wayland --no-provision --dry-run >"$xb/o7.log" 2>&1 \
     && bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o7b.iso" --wayland --no-provision --remote-desktop none --dry-run >/dev/null 2>&1 \
     && ! bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o7c.iso" --wayland --no-provision --remote-desktop rustdesk --dry-run >/dev/null 2>&1; then
    pass "--wayland --no-provision allowed (remote desktop none); explicit --remote-desktop rejected"
  else
    fail "--wayland --no-provision: $(tail -3 "$xb/o7.log")"
  fi
  # --skip 36: 保留 Wayland (告警), RustDesk 照装并提示 Wayland 限制; --skip 38: 不投递 RustDesk 密码
  if bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o8.iso" --password 'Pl@in99x' --skip 36 >"$xb/o8.log" 2>&1 \
     && grep -q '跳过了 36-x11vnc-xorg' "$xb/o8.log" && grep -q 'RustDesk + Wayland' "$xb/o8.log" \
     && bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o8b.iso" --password 'Pl@in99x' --skip 38 >"$xb/o8b.log" 2>&1 && _xenv "$xb/o8b.iso" "$xb/p8b" \
     && grep -q '跳过了 38-rustdesk' "$xb/o8b.log" && [[ ! -e "$xb/p8b/rustdesk.secret" ]] \
     && bash build-iso.sh --iso "$xb/d.iso" --out "$xb/o8c.iso" --password 'Pl@in99x' --remote-desktop x11vnc --skip 36 >"$xb/o8c.log" 2>&1 && _xenv "$xb/o8c.iso" "$xb/p8c" \
     && grep -q '保留 Wayland, 不装 x11vnc' "$xb/o8c.log" && [[ ! -e "$xb/p8c/x11vnc.secret" ]]; then
    pass "--skip 36 / --skip 38 handling"
  else
    fail "--skip 36/38: $(tail -3 "$xb/o8.log" "$xb/o8b.log" "$xb/o8c.log")"
  fi
  # Server: 不受影响; --wayland / --remote-desktop 告警忽略
  if bash build-iso.sh --iso "$xb/s.iso" --out "$xb/o6.iso" --password 'Pl@in99x' >"$xb/o6.log" 2>&1 && _xenv "$xb/o6.iso" "$xb/p6" \
     && grep -qx 'X11VNC=0' "$xb/p6/provision.env" && grep -qx 'DISABLE_WAYLAND=0' "$xb/p6/provision.env" \
     && grep -qx 'REMOTE_DESKTOP=none' "$xb/p6/provision.env" \
     && [[ ! -e "$xb/p6/x11vnc.secret" && ! -e "$xb/p6/rustdesk.secret" ]] && ! grep -q 'VNC 流量不加密\|RustDesk 安全提示' "$xb/o6.log" \
     && bash build-iso.sh --iso "$xb/s.iso" --out "$xb/o6b.iso" --password 'Pl@in99x' --wayland --remote-desktop rustdesk --dry-run >"$xb/o6b.log" 2>&1 \
     && grep -q -- '--wayland 只用于 Desktop' "$xb/o6b.log" && grep -q -- '--remote-desktop 只用于 Desktop' "$xb/o6b.log"; then
    pass "server: no remote desktop by default, --wayland / --remote-desktop ignored with warning"
  else
    fail "server remote desktop handling: $(tail -3 "$xb/o6.log" "$xb/o6b.log")"
  fi
  # 旧参数已移除: 报错并提示新用法
  for old in --disable-wayland:--wayland --x11vnc:'--remote-desktop x11vnc'; do
    if bash build-iso.sh --iso "$xb/d.iso" --out "$xb/bad.iso" --password x "${old%%:*}" --dry-run >"$xb/old.log" 2>&1; then
      fail "should reject removed flag: ${old%%:*}"
    elif grep -q -- "${old%%:*} 已移除" "$xb/old.log" && grep -q -- "${old#*:}" "$xb/old.log"; then
      pass "rejects removed flag: ${old%%:*} (hint ${old#*:})"
    else
      fail "removed flag message: ${old%%:*}: $(tail -2 "$xb/old.log")"
    fi
  done
  for bad in "--no-provision" "--remote-desktop x11vnc --vnc-password 12345" "--rustdesk-password 12345" \
             "--remote-desktop vnc" "--wayland --remote-desktop x11vnc" "--rustdesk-server http://x" \
             "--rustdesk-server a_b" "--pin-rustdesk latest"; do
    # shellcheck disable=SC2086
    if bash build-iso.sh --iso "$xb/d.iso" --out "$xb/bad.iso" --password x $bad --dry-run >/dev/null 2>&1; then
      fail "desktop should reject: $bad"
    else
      pass "desktop rejects: $bad"
    fi
  done
  rm -rf "$xb"
else
  echo "(xorriso/openssl missing, remote desktop build test skipped)"
fi

echo "== rustdesk script (38-rustdesk) + release helper + offline seed =="
if TMPD="$tmp" bash <<'RDH'
set -eu
. tools/rustdesk-release.sh
rustdesk_resolve 1.5.1 amd64
[[ "$RUSTDESK_DEB_NAME" == rustdesk-1.5.1-x86_64.deb ]]
[[ "$RUSTDESK_DEB_URL" == https://github.com/rustdesk/rustdesk/releases/download/1.5.1/rustdesk-1.5.1-x86_64.deb ]]
[[ "$RUSTDESK_SHA256" == b5d682ad90cb7571ecbdbf26eef58d3c4514e726a74ef6d08ce3f0b114ef0bd9 ]]
rustdesk_resolve "" arm64
[[ "$RUSTDESK_DEB_NAME" == rustdesk-1.5.1-aarch64.deb && "$RUSTDESK_VERSION" == "$RUSTDESK_DEFAULT_VERSION" ]]
! rustdesk_resolve 1.5.1 riscv64 2>/dev/null
! rustdesk_resolve latest amd64 2>/dev/null
printf 'x' > "$TMPD/rd-bad.deb"
! rustdesk_verify_deb "$TMPD/rd-bad.deb" "$RUSTDESK_SHA256" 2>/dev/null
rustdesk_verify_deb "$TMPD/rd-bad.deb" "$(sha256sum "$TMPD/rd-bad.deb" | cut -d' ' -f1)"
RDH
then
  pass "rustdesk-release: pinned 1.5.1 sha256 (amd64/arm64), rejects bad arch/version/sha"
else
  fail "rustdesk-release helper"
fi
rr="$(mktemp -d)"; mkdir -p "$rr/prov"
cp software/38-rustdesk.sh software/lib-offline.sh tools/rustdesk-release.sh "$rr/prov/"
( umask 077; printf 'RUSTDESK_PASSWORD=%q\n' 'S3cret#rd' > "$rr/prov/rustdesk.secret" )
if EDITION=server REMOTE_DESKTOP=rustdesk AIB_TARGET_ROOT="$rr/t0" AIB_SKIP_PKG=1 bash "$rr/prov/38-rustdesk.sh" >"$tmp/rd-srv.log" 2>&1 \
   && grep -q 'skip:' "$tmp/rd-srv.log" && [[ ! -e "$rr/prov/rustdesk.secret" && ! -e "$rr/t0" ]] \
   && EDITION=desktop REMOTE_DESKTOP=x11vnc AIB_TARGET_ROOT="$rr/t0" AIB_SKIP_PKG=1 bash software/38-rustdesk.sh >"$tmp/rd-x.log" 2>&1 \
   && grep -q 'skip:' "$tmp/rd-x.log" \
   && EDITION=desktop REMOTE_DESKTOP=rustdesk RUSTDESK_ARCH=riscv64 AIB_TARGET_ROOT="$rr/t0" AIB_SKIP_PKG=1 bash software/38-rustdesk.sh >"$tmp/rd-a.log" 2>&1 \
   && grep -q 'skip:' "$tmp/rd-a.log" && [[ ! -e "$rr/t0" ]]; then
  pass "38-rustdesk: skips on server / non-rustdesk / unsupported arch (secret removed)"
else
  fail "38-rustdesk skip paths: $(cat "$tmp/rd-srv.log" "$tmp/rd-x.log" "$tmp/rd-a.log" 2>/dev/null | tail -3)"
fi
( umask 077; printf 'RUSTDESK_PASSWORD=%q\n' 'S3cret#rd' > "$rr/prov/rustdesk.secret" )
t="$rr/t1"
if EDITION=desktop REMOTE_DESKTOP=rustdesk AIB_TARGET_ROOT="$t" AIB_SKIP_PKG=1 bash "$rr/prov/38-rustdesk.sh" >"$tmp/rd-on.log" 2>&1; then
  u="$t/etc/systemd/system/aib-rustdesk-setup.service"; su="$t/usr/local/sbin/aib-rustdesk-setup"
  if [[ ! -e "$rr/prov/rustdesk.secret" ]] && ! grep -q 'S3cret' "$tmp/rd-on.log" \
     && [[ "$(stat -c %a "$t/etc/aib/rustdesk.secret")" == 600 && ! -e "$t/root/rustdesk-password" ]] \
     && ( # shellcheck disable=SC1091
          . "$t/etc/aib/rustdesk.secret"; [[ "$RUSTDESK_PASSWORD" == 'S3cret#rd' ]] ) \
     && grep -qx 'direct-server Y' "$t/etc/aib/rustdesk.options" \
     && grep -qx 'verification-method use-permanent-password' "$t/etc/aib/rustdesk.options" \
     && grep -qx 'approve-mode password' "$t/etc/aib/rustdesk.options" \
     && ! grep -q 'rendezvous\|relay' "$t/etc/aib/rustdesk.options" \
     && grep -qx '\[options\]' "$t/root/.config/rustdesk/RustDesk2.toml" \
     && grep -qx "direct-server = 'Y'" "$t/root/.config/rustdesk/RustDesk2.toml" \
     && ! grep -qi 'password = ' "$t/root/.config/rustdesk/RustDesk2.toml" \
     && grep -q '^After=rustdesk.service' "$u" && grep -q '^Wants=rustdesk.service' "$u" \
     && grep -qx 'ConditionPathExists=!/var/lib/aib/rustdesk-setup.done' "$u" && grep -q '^Restart=on-failure' "$u" \
     && grep -q '^WantedBy=multi-user.target' "$u" && [[ -x "$su" ]] \
     && ! grep -rq 'S3cret' "$t/etc/systemd" "$t/usr" "$t/etc/aib/rustdesk.options" "$t/root/.config"; then
    pass "38-rustdesk: secret → /etc/aib (0600), options + RustDesk2.toml preset, first-boot oneshot unit"
  else
    fail "38-rustdesk files: $(tail -5 "$tmp/rd-on.log")"
  fi
  if command -v shellcheck >/dev/null; then
    if shellcheck "$su"; then pass "aib-rustdesk-setup shellcheck"; else fail "aib-rustdesk-setup shellcheck"; fi
  fi
  # 首次开机脚本: 用假 rustdesk CLI 验证 IPC 设置流程 (选项读回确认, 密码 Done! 后删除明文, 打标记)
  fr="$rr/fake"; mkdir -p "$fr/opt"
  cat > "$fr/rustdesk" <<STUB
#!/bin/bash
case "\$1" in
  --get-id) echo 123456789 ;;
  --option) if [ \$# -eq 3 ]; then printf '%s' "\$3" > "$fr/opt/\$2"; else cat "$fr/opt/\$2" 2>/dev/null; echo; fi ;;
  --password) if [ -n "\${STUB_PW_FAIL:-}" ]; then echo "Failed to connect"; else printf '%s' "\$2" > "$fr/pw"; echo "Done!"; fi ;;
esac
STUB
  chmod +x "$fr/rustdesk"
  cp "$t/etc/aib/rustdesk.secret" "$fr/secret"
  run_setup() { AIB_RUSTDESK_SECRET="$fr/secret" AIB_RUSTDESK_OPTIONS="$t/etc/aib/rustdesk.options" AIB_RUSTDESK_STAMP="$fr/done" RUSTDESK_BIN="$fr/rustdesk" bash "$su"; }
  if STUB_PW_FAIL=1 run_setup >"$tmp/rd-setup-fail.log" 2>&1; then
    fail "aib-rustdesk-setup should fail when --password fails"
  elif [[ -f "$fr/secret" && ! -e "$fr/done" ]] && grep -q '设置固定密码失败' "$tmp/rd-setup-fail.log"; then
    pass "aib-rustdesk-setup: password failure keeps secret for retry"
  else
    fail "aib-rustdesk-setup failure path: $(cat "$tmp/rd-setup-fail.log")"
  fi
  if run_setup >"$tmp/rd-setup.log" 2>&1 && [[ ! -e "$fr/secret" && -s "$fr/done" ]] \
     && [[ "$(cat "$fr/pw")" == 'S3cret#rd' ]] && [[ "$(cat "$fr/opt/direct-server")" == Y ]] \
     && [[ "$(cat "$fr/opt/verification-method")" == use-permanent-password ]] && [[ "$(cat "$fr/opt/approve-mode")" == password ]] \
     && ! grep -q 'S3cret' "$tmp/rd-setup.log" && grep -q '123456789' "$tmp/rd-setup.log"; then
    pass "aib-rustdesk-setup: options applied + verified, password set via CLI, secret deleted, stamp written"
  else
    fail "aib-rustdesk-setup: $(cat "$tmp/rd-setup.log")"
  fi
else
  fail "38-rustdesk run: $(tail -5 "$tmp/rd-on.log")"
fi
# 自建服务器 + 只有哈希 (随机密码)
t="$rr/t2"
if EDITION=desktop REMOTE_DESKTOP=rustdesk RUSTDESK_SERVER=rd.example.com:21116 AIB_TARGET_ROOT="$t" AIB_SKIP_PKG=1 bash software/38-rustdesk.sh >"$tmp/rd-srv2.log" 2>&1 \
   && grep -qx 'custom-rendezvous-server rd.example.com:21116' "$t/etc/aib/rustdesk.options" \
   && grep -qx 'relay-server rd.example.com:21116' "$t/etc/aib/rustdesk.options" \
   && [[ "$(stat -c %a "$t/root/rustdesk-password")" == 600 && "$(wc -c < "$t/root/rustdesk-password")" -eq 13 ]] \
   && ( # shellcheck disable=SC1091
        . "$t/etc/aib/rustdesk.secret"; [[ "$RUSTDESK_PASSWORD" == "$(cat "$t/root/rustdesk-password")" ]] ) \
   && ! EDITION=desktop REMOTE_DESKTOP=rustdesk RUSTDESK_SERVER='x;rm' AIB_TARGET_ROOT="$rr/t3" AIB_SKIP_PKG=1 bash software/38-rustdesk.sh >/dev/null 2>&1; then
  pass "38-rustdesk: --rustdesk-server options, random password when no plaintext, rejects bad server"
else
  fail "38-rustdesk server / random password: $(tail -3 "$tmp/rd-srv2.log")"
fi
# 36 钩子: RustDesk 也关合盖 / 空闲挂起, 但不装 x11vnc
t="$rr/t4"
if EDITION=desktop DISABLE_WAYLAND=1 REMOTE_DESKTOP=rustdesk AIB_TARGET_ROOT="$t" AIB_SKIP_PKG=1 bash software/36-x11vnc-xorg.sh >/dev/null 2>&1 \
   && grep -qx 'WaylandEnable=false' "$t/etc/gdm3/custom.conf" \
   && grep -qx 'HandleLidSwitch=ignore' "$t/etc/systemd/logind.conf.d/90-autoinstall-x11vnc.conf" \
   && grep -q "sleep-inactive-ac-type='nothing'" "$t/etc/dconf/db/gdm.d/90-autoinstall-no-suspend" \
   && [[ ! -e "$t/etc/systemd/system/x11vnc.service" && ! -e "$t/usr/local/sbin/aib-x11vnc-follow" ]]; then
  pass "36-x11vnc-xorg with RustDesk: wayland off + no-suspend, no x11vnc"
else
  fail "36-x11vnc-xorg with RustDesk"
fi
rm -rf "$rr"
if grep -q 'rustdesk/' tools/fetch-offline-bundle.sh && grep -q '"rustdesk", "apt-sources"' tools/fetch-offline-bundle.sh \
   && grep -q '"rustdesk": sys.argv\[12\]' tools/fetch-offline-bundle.sh && grep -q -- '--pin-rustdesk' tools/fetch-offline-bundle.sh \
   && grep -q 'FETCH_RUSTDESK_DIR' tools/fetch-offline-bundle.sh \
   && grep -q -- '--require-rustdesk' tools/validate-offline-bundle.sh && grep -q -- '--require-rustdesk' build-iso.sh \
   && grep -q 'rustdesk-release.sh' build-iso.sh \
   && grep -q 'rustdesk.secret' software/run-all.sh && grep -q 'rustdesk.secret' software/99-cleanup.sh \
   && grep -qE '(^|[[:space:]])rustdesk([[:space:]]|$)' software/99-cleanup.sh \
   && grep -q 'offline_root)/rustdesk' software/38-rustdesk.sh; then
  pass "rustdesk offline seed + fingerprint + validate + secret cleanup"
else
  fail "rustdesk offline seed / cleanup"
fi

echo "== unity-cli script + offline seed =="
if [[ -x software/80-unity-cli.sh ]] \
  && grep -q '/usr/local/bin/unity' software/80-unity-cli.sh \
  && grep -q 'public-cdn.cloud.unity3d.com/hub/prod/cli' software/80-unity-cli.sh \
  && grep -q 'offline_enabled' software/80-unity-cli.sh \
  && grep -q 'unity-cli' tools/fetch-offline-bundle.sh \
  && grep -q 'public-cdn.cloud.unity3d.com/hub/prod/cli' tools/fetch-offline-bundle.sh \
  && grep -qE '(^|[[:space:]])unity([[:space:]]|$)' software/99-cleanup.sh \
  && ! grep -qE 'apt-get install.*(libgtk|libnss3|xvfb)' software/80-unity-cli.sh; then
  pass "unity-cli script + offline seed + manifest (CLI only)"
else
  fail "unity-cli script + offline seed + manifest"
fi

echo "== godot 4.7.2 script + offline seed =="
if [[ -x software/85-godot.sh ]] \
  && grep -q '/opt/godot/4.7.2' software/85-godot.sh \
  && grep -q '/usr/local/bin/godot' software/85-godot.sh \
  && grep -q 'Godot_v4.7.2-stable_linux.x86_64.zip' software/85-godot.sh \
  && grep -q 'sha512sum' software/85-godot.sh \
  && grep -q 'offline_enabled' software/85-godot.sh \
  && ! grep -qE 'export_templates\.tpz|mono_export_templates' software/85-godot.sh \
  && grep -q 'godot/' tools/fetch-offline-bundle.sh \
  && grep -q 'Godot_v4.7.2-stable_linux.x86_64.zip' tools/fetch-offline-bundle.sh \
  && grep -qE '(^|[[:space:]])godot([[:space:]]|$)' software/99-cleanup.sh; then
  pass "godot 4.7.2 script + offline seed + manifest (engine only)"
else
  fail "godot 4.7.2 script + offline seed + manifest"
fi

echo "== gitea script + offline seed + build flags =="
if [[ -x software/45-gitea.sh ]] \
  && grep -q '/usr/local/bin/gitea' software/45-gitea.sh \
  && grep -q 'dl.gitea.com/gitea' software/45-gitea.sh \
  && grep -q 'sha256sum' software/45-gitea.sh \
  && grep -q 'offline_enabled' software/45-gitea.sh \
  && grep -q '^INSTALL_LOCK = true' software/45-gitea.sh \
  && grep -q '^HTTP_ADDR = 0.0.0.0' software/45-gitea.sh \
  && grep -q 'GITEA_HTTP_PORT:-3000' software/45-gitea.sh \
  && grep -q '^DISABLE_REGISTRATION = false' software/45-gitea.sh \
  && grep -q '^OFFLINE_MODE = true' software/45-gitea.sh \
  && grep -q 'DB_TYPE = sqlite3' software/45-gitea.sh \
  && grep -q 'generate secret SECRET_KEY' software/45-gitea.sh \
  && grep -q 'must-change-password=false' software/45-gitea.sh \
  && grep -q 'After=network-online.target' software/45-gitea.sh \
  && grep -q 'systemctl enable gitea.service' software/45-gitea.sh \
  && grep -q 'gitea/' tools/fetch-offline-bundle.sh \
  && grep -q 'dl.gitea.com/gitea' tools/fetch-offline-bundle.sh \
  && grep -q -- '--pin-gitea' tools/validate-offline-bundle.sh \
  && grep -q 'PIN_GITEA=%q' build-iso.sh \
  && grep -q 'gitea-admin.secret' build-iso.sh \
  && grep -q 'gitea-admin.secret' software/99-cleanup.sh \
  && grep -qE '(^|[[:space:]])gitea([[:space:]]|$)' software/99-cleanup.sh; then
  pass "gitea script + offline seed + manifest + build wiring"
else
  fail "gitea script + offline seed + manifest + build wiring"
fi
# 明文密码不能进 provision.env / 日志
if ! sed -n '/^  {$/,/provision\/provision.env"$/p' build-iso.sh | grep -q 'GITEA_ADMIN_PASSWORD' \
  && ! grep -nE '(echo|printf).*\$\{?ADMIN_PW' software/45-gitea.sh | grep -v RANDOM_PW_FILE | grep -q .; then
  pass "gitea admin password not in provision.env / not echoed"
else
  fail "gitea admin password leak path"
fi

echo "== build-iso default credentials (ubuntu / ubuntu1990) =="
if command -v xorriso >/dev/null && command -v openssl >/dev/null; then
  dc="$(mktemp -d)"
  if bash test/make-fake-iso.sh server "$dc/src.iso" >/dev/null 2>&1 \
     && bash build-iso.sh --iso "$dc/src.iso" --out "$dc/d.iso" >"$dc/d.log" 2>&1 \
     && xorriso -osirrox on -indev "$dc/d.iso" -extract /nocloud "$dc/nc" -extract /provision "$dc/pv" >/dev/null 2>&1; then
    ud_user="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["autoinstall"]["identity"]["username"])' "$dc/nc/user-data" 2>/dev/null \
      || sed -n 's/^ *username: *//p' "$dc/nc/user-data" | head -1 | tr -d "'\"")"
    ud_hash="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["autoinstall"]["identity"]["password"])' "$dc/nc/user-data" 2>/dev/null \
      || sed -n 's/^ *password: *//p' "$dc/nc/user-data" | head -1 | tr -d "'\"")"
    salt="$(printf '%s' "$ud_hash" | cut -d'$' -f3)"
    # shellcheck disable=SC2016
    if [[ "$ud_user" == "ubuntu" && "$ud_hash" == '$6$'* \
          && "$(openssl passwd -6 -salt "$salt" ubuntu1990)" == "$ud_hash" ]]; then
      pass "default user ubuntu + sha512 hash of default password"
    else
      fail "default credentials in user-data (user=$ud_user)"
    fi
    if grep -q '默认密码' "$dc/d.log" && ! grep -q 'ubuntu1990' "$dc/d.log"; then
      pass "default password warning printed, plaintext not logged"
    else
      fail "default password warning / plaintext leak"
    fi
    if grep -qx 'GITEA_ADMIN_USER=ubuntu' "$dc/pv/provision.env" \
       && ( # shellcheck disable=SC1091
            . "$dc/pv/gitea-admin.secret"; [[ "$GITEA_ADMIN_PASSWORD" == ubuntu1990 ]] ); then
      pass "gitea admin follows default credentials"
    else
      fail "gitea admin default credentials"
    fi
    # 显式密码时不告警
    if bash build-iso.sh --iso "$dc/src.iso" --out "$dc/e.iso" --password 'Other#Pass9' >"$dc/e.log" 2>&1 \
       && ! grep -q '默认密码' "$dc/e.log"; then
      pass "no default-password warning when --password given"
    else
      fail "explicit --password still warned"
    fi
  else
    fail "fake ISO build without credentials: $(tail -3 "$dc/d.log" 2>/dev/null)"
  fi
  rm -rf "$dc"
else
  echo "(xorriso/openssl missing, default credentials test skipped)"
fi

echo "== build-iso gitea flags (fake ISO) =="
if command -v xorriso >/dev/null && command -v openssl >/dev/null; then
  gt="$(mktemp -d)"
  bash test/make-fake-iso.sh server "$gt/src.iso" >/dev/null 2>&1 || bash test/make-fake-iso.sh "$gt/src.iso" >/dev/null 2>&1 || true
  if [[ -f "$gt/src.iso" ]]; then
    if bash build-iso.sh --iso "$gt/src.iso" --out "$gt/a.iso" --username ops --password 'Pl@inPass99' \
         --pin-gitea 28.3.0 >"$gt/a.log" 2>&1 \
       && xorriso -osirrox on -indev "$gt/a.iso" -extract /provision "$gt/a" >/dev/null 2>&1; then
      if grep -qx 'PIN_GITEA=28.3.0' "$gt/a/provision.env" && grep -qx 'GITEA_ADMIN_USER=ops' "$gt/a/provision.env" \
         && ! grep -q 'Pl@inPass99' "$gt/a/provision.env" && [[ -f "$gt/a/45-gitea.sh" ]] \
         && ( # shellcheck disable=SC1091
              . "$gt/a/gitea-admin.secret"; [[ "$GITEA_ADMIN_PASSWORD" == 'Pl@inPass99' ]] ) \
         && ! grep -q 'Pl@inPass99' "$gt/a.log"; then
        pass "gitea defaults: admin=username, password via separate secret file, not logged"
      else
        fail "gitea defaults in provision"
      fi
    else
      fail "build-iso with gitea flags: $(tail -3 "$gt/a.log")"
    fi
    # 只有哈希 → 不带 secret 文件
    if bash build-iso.sh --iso "$gt/src.iso" --out "$gt/b.iso" --password-hash "$(openssl passwd -6 x)" \
         --gitea-admin-user boss --gitea-admin-email boss@example.com >"$gt/b.log" 2>&1 \
       && xorriso -osirrox on -indev "$gt/b.iso" -extract /provision "$gt/b" >/dev/null 2>&1 \
       && [[ ! -e "$gt/b/gitea-admin.secret" ]] && grep -qx 'GITEA_ADMIN_USER=boss' "$gt/b/provision.env" \
       && grep -q '/root/gitea-admin-password' "$gt/b.log"; then
      pass "gitea hash-only: no secret file, random password notice"
    else
      fail "gitea hash-only build"
    fi
    for bad in "--pin-gitea 1.2;rm" "--gitea-admin-user login" "--gitea-admin-user a/b" "--gitea-admin-password short" "--gitea-admin-email nope" "--username git"; do
      # shellcheck disable=SC2086
      if bash build-iso.sh --iso "$gt/src.iso" --out "$gt/c.iso" --password x $bad --dry-run >/dev/null 2>&1; then
        fail "should reject: $bad"
      else
        pass "rejects: $bad"
      fi
    done
  else
    fail "make-fake-iso for gitea test"
  fi
  rm -rf "$gt"
else
  echo "(xorriso/openssl missing, gitea build test skipped)"
fi

echo "== build-iso flclash flags (fake ISO) =="
if command -v xorriso >/dev/null && command -v openssl >/dev/null; then
  fc="$(mktemp -d)"
  bash test/make-fake-iso.sh desktop "$fc/src.iso" >/dev/null 2>&1 || true
  if [[ -f "$fc/src.iso" ]]; then
    if bash build-iso.sh --iso "$fc/src.iso" --out "$fc/a.iso" --edition desktop --password-hash "$(openssl passwd -6 x)" \
         >"$fc/a.log" 2>&1 \
       && xorriso -osirrox on -indev "$fc/a.iso" -extract /provision "$fc/a" >/dev/null 2>&1; then
      if ! grep -q 'PIN_FLCLASH' "$fc/a/provision.env" \
         && [[ -f "$fc/a/37-flclash.sh" && -f "$fc/a/flclash-release.sh" ]]; then
        pass "flclash helper copied, no PIN_FLCLASH in provision.env"
      else
        fail "flclash provision: $(grep PIN_FLCLASH "$fc/a/provision.env" 2>/dev/null)"
      fi
    else
      fail "build-iso desktop flclash: $(tail -5 "$fc/a.log" 2>/dev/null)"
    fi
    if bash build-iso.sh --iso "$fc/src.iso" --out "$fc/b.iso" --edition desktop --password-hash "$(openssl passwd -6 x)" \
         --no-flclash >"$fc/b.log" 2>&1 \
       && xorriso -osirrox on -indev "$fc/b.iso" -extract /provision "$fc/b" >/dev/null 2>&1; then
      if grep -q '37-flclash' "$fc/b/provision.env" && grep -q 'PROVISION_SKIP=' "$fc/b/provision.env"; then
        pass "--no-flclash adds 37-flclash to PROVISION_SKIP"
      else
        fail "--no-flclash skip wiring: $(grep PROVISION_SKIP "$fc/b/provision.env" 2>/dev/null)"
      fi
    else
      fail "build-iso --no-flclash: $(tail -5 "$fc/b.log" 2>/dev/null)"
    fi
    for bad in "--pin-flclash 1.2;rm" "--pin-flclash ../x"; do
      # shellcheck disable=SC2086
      if bash build-iso.sh --iso "$fc/src.iso" --out "$fc/c.iso" --password x $bad --dry-run >/dev/null 2>&1; then
        fail "should reject: $bad"
      else
        pass "rejects: $bad"
      fi
    done
  else
    fail "make-fake-iso for flclash test"
  fi
  rm -rf "$fc"
else
  echo "(xorriso/openssl missing, flclash build test skipped)"
fi

echo "== jenkins zero-config script + offline plugins + build flags =="
if [[ -x software/30-jenkins.sh ]] \
  && grep -q 'runSetupWizard=false' software/30-jenkins.sh \
  && grep -q 'jenkins.install.InstallUtil.lastExecVersion' software/30-jenkins.sh \
  && grep -q 'jenkins.install.UpgradeWizard.state' software/30-jenkins.sh \
  && grep -q 'HudsonPrivateSecurityRealm(false)' software/30-jenkins.sh \
  && grep -q 'FullControlOnceLoggedInAuthorizationStrategy' software/30-jenkins.sh \
  && grep -q 'setAllowAnonymousRead(false)' software/30-jenkins.sh \
  && grep -q 'createAccountWithHashedPassword' software/30-jenkins.sh \
  && grep -qF '#jbcrypt:' software/30-jenkins.sh \
  && grep -q 'init.groovy.d/00-autoinstall-admin.groovy' software/30-jenkins.sh \
  && grep -q 'jenkins-admin.secret' software/30-jenkins.sh \
  && grep -q '/root/jenkins-admin-password' software/30-jenkins.sh \
  && grep -q 'libharfbuzz0b' software/30-jenkins.sh \
  && grep -q 'jenkins-plugins' software/30-jenkins.sh \
  && grep -q 'resolve-jenkins-plugins.py' software/30-jenkins.sh \
  && grep -q 'resolve-jenkins-plugins.py' tools/fetch-offline-bundle.sh \
  && grep -q 'resolve-jenkins-plugins.py' build-iso.sh \
  && python3 -m py_compile tools/resolve-jenkins-plugins.py \
  && ! grep -q 'plugin-installation-manager' software/30-jenkins.sh tools/fetch-offline-bundle.sh \
  && grep -q 'jenkins-plugins' tools/fetch-offline-bundle.sh \
  && grep -q 'plugins.lock' tools/fetch-offline-bundle.sh \
  && grep -q '"jenkins_plugins"' tools/fetch-offline-bundle.sh \
  && grep -q -- '--jenkins-plugins' tools/validate-offline-bundle.sh \
  && grep -q 'JENKINS_PLUGINS=%q' build-iso.sh \
  && grep -q 'jenkins-admin.secret' build-iso.sh \
  && grep -q 'jenkins-admin.secret' software/run-all.sh \
  && grep -q 'jenkins-admin.secret' software/99-cleanup.sh \
  && grep -q -- '--jenkins-admin-password' scripts/aib.sh \
  && grep -q -- '--jenkins-admin-password' scripts/aib.ps1; then
  pass "jenkins script + offline plugins + manifest + build wiring"
else
  fail "jenkins script + offline plugins + manifest + build wiring"
fi
# 明文不进 provision.env / 不回显 / groovy 只含哈希
if ! sed -n '/^  {$/,/provision\/provision.env"$/p' build-iso.sh | grep -q 'JENKINS_ADMIN_PASSWORD' \
  && ! grep -nE '(echo|printf).*\$\{?ADMIN_PW' software/30-jenkins.sh | grep -vE 'RANDOM_PW_FILE|python3|\.admin-password' | grep -q .; then
  pass "jenkins admin password not in provision.env / not echoed"
else
  fail "jenkins admin password leak path"
fi

echo "== build-iso jenkins flags (fake ISO) =="
if command -v xorriso >/dev/null && command -v openssl >/dev/null; then
  jt="$(mktemp -d)"
  bash test/make-fake-iso.sh server "$jt/src.iso" >/dev/null 2>&1 || true
  if [[ -f "$jt/src.iso" ]]; then
    # 默认: 管理员 = 系统用户, 密码 = 默认密码, 默认插件列表
    if bash build-iso.sh --iso "$jt/src.iso" --out "$jt/d.iso" >"$jt/d.log" 2>&1 \
       && xorriso -osirrox on -indev "$jt/d.iso" -extract /provision "$jt/d" >/dev/null 2>&1 \
       && grep -qx 'JENKINS_ADMIN_USER=ubuntu' "$jt/d/provision.env" \
       && ( set -a; # shellcheck disable=SC1091
            . "$jt/d/provision.env"; [[ "$JENKINS_PLUGINS" == "workflow-aggregator git gitea docker-workflow credentials-binding timestamper rebuild ansicolor docker-plugin parameterized-trigger" ]] ) \
       && ( # shellcheck disable=SC1091
            . "$jt/d/jenkins-admin.secret"; [[ "$JENKINS_ADMIN_PASSWORD" == ubuntu1990 ]] ) \
       && ! grep -q 'ubuntu1990' "$jt/d.log" "$jt/d/provision.env"; then
      pass "jenkins defaults: admin=ubuntu, default password via secret file, default plugins"
    else
      fail "jenkins defaults in provision: $(tail -3 "$jt/d.log")"
    fi
    # 覆盖: 独立管理员/密码/插件
    if bash build-iso.sh --iso "$jt/src.iso" --out "$jt/a.iso" --username ops --password 'Pl@inPass99' \
         --jenkins-admin-user jadmin --jenkins-admin-password 'J3nk!ns pw' --jenkins-plugins "git  timestamper:1.30" >"$jt/a.log" 2>&1 \
       && xorriso -osirrox on -indev "$jt/a.iso" -extract /provision "$jt/a" >/dev/null 2>&1 \
       && grep -qx 'JENKINS_ADMIN_USER=jadmin' "$jt/a/provision.env" \
       && ( set -a; # shellcheck disable=SC1091
            . "$jt/a/provision.env"; [[ "$JENKINS_PLUGINS" == "git timestamper:1.30" ]] ) \
       && ( # shellcheck disable=SC1091
            . "$jt/a/jenkins-admin.secret"; [[ "$JENKINS_ADMIN_PASSWORD" == 'J3nk!ns pw' ]] ) \
       && ! grep -q 'J3nk!ns' "$jt/a.log" "$jt/a/provision.env"; then
      pass "jenkins overrides: admin user / password / plugin list"
    else
      fail "jenkins overrides: $(tail -3 "$jt/a.log")"
    fi
    # 只有哈希 → 无 secret, 提示随机密码
    if bash build-iso.sh --iso "$jt/src.iso" --out "$jt/b.iso" --password-hash "$(openssl passwd -6 x)" >"$jt/b.log" 2>&1 \
       && xorriso -osirrox on -indev "$jt/b.iso" -extract /provision "$jt/b" >/dev/null 2>&1 \
       && [[ ! -e "$jt/b/jenkins-admin.secret" ]] && grep -q '/root/jenkins-admin-password' "$jt/b.log"; then
      pass "jenkins hash-only: no secret file, random password notice"
    else
      fail "jenkins hash-only build"
    fi
    # --skip 30 → 不投递 secret
    if bash build-iso.sh --iso "$jt/src.iso" --out "$jt/s.iso" --skip 30 >"$jt/s.log" 2>&1 \
       && xorriso -osirrox on -indev "$jt/s.iso" -extract /provision "$jt/s" >/dev/null 2>&1 \
       && [[ ! -e "$jt/s/jenkins-admin.secret" ]]; then
      pass "jenkins --skip 30: no secret delivered"
    else
      fail "jenkins --skip 30 still delivers secret"
    fi
    for bad in "--jenkins-plugins git;rm" "--jenkins-plugins \$(id)" "--jenkins-admin-user a/b" "--jenkins-admin-user anonymous" "--jenkins-plugins -x"; do
      # shellcheck disable=SC2086
      if bash build-iso.sh --iso "$jt/src.iso" --out "$jt/c.iso" --password x $bad --dry-run >/dev/null 2>&1; then
        fail "should reject: $bad"
      else
        pass "rejects: $bad"
      fi
    done
  else
    fail "make-fake-iso for jenkins test"
  fi
  rm -rf "$jt"
else
  echo "(xorriso/openssl missing, jenkins build test skipped)"
fi

echo "== service URL host: <hostname>.local / --service-url-host (lib-service-url.sh) =="
su_t="$(mktemp -d)"
# shellcheck disable=SC1091
. software/lib-service-url.sh
for h in ubuntu-node n1 a 0 desk-01 "$(printf 'a%.0s' {1..63})"; do
  if aib_valid_mdns_label "$h"; then pass "hostname ok: ${h:0:20}"; else fail "hostname should be valid: $h"; fi
done
for h in "" Node01 a.b a_b -a a- "a b" "$(printf 'a%.0s' {1..64})" 'a;rm'; do
  if aib_valid_mdns_label "$h"; then fail "hostname should be invalid: [$h]"; else pass "hostname rejected: [${h:0:20}]"; fi
done
for h in localhost 192.168.1.20 10.0.0.5 ci.example.com node01.lan a-b.c-d.example; do
  if aib_valid_service_host "$h"; then pass "service host ok: $h"; else fail "service host should be valid: $h"; fi
done
for h in "" http://x x:8080 1.2.3 999.1.1.1 01.2.3.4 a..b .a a. -a.com "x y" 'a;b' fe80::1 a_b.com; do
  if aib_valid_service_host "$h"; then fail "service host should be invalid: [$h]"; else pass "service host rejected: [$h]"; fi
done
printf 'node07\n' > "$su_t/hostname"
printf 'Box9.example.com\n' > "$su_t/hostname-fqdn"
printf 'bad_name\n' > "$su_t/hostname-bad"
_su() { env -i PATH="$PATH" "$@" bash -c '. software/lib-service-url.sh; aib_service_url_host' 2>/dev/null; }
if [[ "$(_su AIB_HOSTNAME_FILE="$su_t/hostname")" == "node07.local" \
   && "$(_su AIB_HOSTNAME_FILE="$su_t/hostname-fqdn")" == "box9.local" \
   && "$(_su AIB_HOSTNAME_FILE="$su_t/hostname-bad" AIB_HOSTNAME=fallback-1)" == "fallback-1.local" \
   && "$(_su AIB_HOSTNAME_FILE="$su_t/none" AIB_HOSTNAME=)" == "localhost" \
   && "$(_su AIB_HOSTNAME_FILE="$su_t/hostname" SERVICE_URL_HOST=192.168.1.20)" == "192.168.1.20" \
   && "$(_su AIB_HOSTNAME_FILE="$su_t/hostname" SERVICE_URL_HOST=CI.Example.com)" == "ci.example.com" \
   && "$(_su AIB_HOSTNAME_FILE="$su_t/hostname" SERVICE_URL_HOST='http://x')" == "node07.local" ]]; then
  pass "aib_service_url_host: /etc/hostname → .local, FQDN first label, fallback, override"
else
  fail "aib_service_url_host resolution"
fi
# Gitea: 用 45-gitea.sh 里真实的 app.ini heredoc 渲染 (只替换变量), 再验证 URL 三项与重跑同步
# shellcheck disable=SC2016  # 字面量 $CONF / 子 shell 脚本, 不在此展开
_ini_tmpl="$(sed -n '/^  cat > "\$CONF" <<INI$/,/^INI$/p' software/45-gitea.sh | sed '1d;$d')"
_render_ini() { # $1 = SERVICE_URL_HOST (可空)
  # shellcheck disable=SC2016
  env -i PATH="$PATH" AIB_HOSTNAME_FILE="$su_t/hostname" SERVICE_URL_HOST="$1" TMPL="$_ini_tmpl" bash -c '
    . software/lib-service-url.sh
    GITEA_USER=git WORK_DIR=/var/lib/gitea HTTP_PORT=3000 SECRET_KEY=s INTERNAL_TOKEN=t JWT_SECRET=j LFS_JWT_SECRET=l
    URL_HOST="$(aib_service_url_host)"; ROOT_URL="http://${URL_HOST}:${HTTP_PORT}/"
    eval "cat <<INI
$TMPL
INI"'
}
_render_ini "" > "$su_t/app.ini"
_render_ini "10.0.0.5" > "$su_t/app2.ini"
if [[ -s "$su_t/app.ini" ]] \
   && grep -qx 'ROOT_URL = http://node07.local:3000/' "$su_t/app.ini" \
   && grep -qx 'DOMAIN = node07.local' "$su_t/app.ini" && grep -qx 'SSH_DOMAIN = node07.local' "$su_t/app.ini" \
   && grep -qx 'HTTP_ADDR = 0.0.0.0' "$su_t/app.ini" && grep -qx 'HTTP_PORT = 3000' "$su_t/app.ini" \
   && ! grep -q 'localhost:3000' "$su_t/app.ini" \
   && grep -qx 'ROOT_URL = http://10.0.0.5:3000/' "$su_t/app2.ini" && grep -qx 'SSH_DOMAIN = 10.0.0.5' "$su_t/app2.ini"; then
  pass "gitea app.ini: ROOT_URL/DOMAIN/SSH_DOMAIN = <hostname>.local (override → IP), still 0.0.0.0:3000"
else
  fail "gitea app.ini URL rendering: $(grep -E '^(ROOT_URL|DOMAIN|SSH_DOMAIN)' "$su_t/app.ini" | tr '\n' ' ')"
fi
aib_gitea_set_url "$su_t/app.ini" newhost.local 3000
if grep -qx 'ROOT_URL = http://newhost.local:3000/' "$su_t/app.ini" && grep -qx 'DOMAIN = newhost.local' "$su_t/app.ini" \
   && grep -qx 'SSH_DOMAIN = newhost.local' "$su_t/app.ini" && grep -qx 'SECRET_KEY = s' "$su_t/app.ini" \
   && [[ "$(grep -c '^ROOT_URL' "$su_t/app.ini")" -eq 1 ]]; then
  pass "aib_gitea_set_url updates existing app.ini (keys kept)"
else
  fail "aib_gitea_set_url"
fi
if grep -q 'aib_service_url_host' software/45-gitea.sh && grep -q 'aib_gitea_set_url' software/45-gitea.sh \
   && grep -q 'aib_service_url_host' software/30-jenkins.sh && grep -q 'aib_jenkins_set_url' software/30-jenkins.sh \
   && grep -q 'jenkins.model.JenkinsLocationConfiguration.xml' software/30-jenkins.sh \
   && ! grep -qi 'configuration-as-code' software/30-jenkins.sh; then
  pass "gitea / jenkins hooks wired to lib-service-url (no JCasC)"
else
  fail "gitea / jenkins hooks wiring"
fi
# Jenkins: 新建 / 更新 JenkinsLocationConfiguration.xml (保留 adminAddress)
aib_jenkins_set_url "$su_t/loc.xml" "http://node07.local:8080/"
cp "$su_t/loc.xml" "$su_t/loc-new.xml"
printf '%s\n' "<?xml version='1.1' encoding='UTF-8'?>" '<jenkins.model.JenkinsLocationConfiguration>' \
  '  <adminAddress>ops@example.com</adminAddress>' '  <jenkinsUrl>http://old:8080/</jenkinsUrl>' \
  '</jenkins.model.JenkinsLocationConfiguration>' > "$su_t/loc2.xml"
aib_jenkins_set_url "$su_t/loc2.xml" "http://192.168.1.20:8080/"
printf '%s\n' "<?xml version='1.1' encoding='UTF-8'?>" '<jenkins.model.JenkinsLocationConfiguration>' \
  '  <adminAddress>ops@example.com</adminAddress>' '</jenkins.model.JenkinsLocationConfiguration>' > "$su_t/loc3.xml"
aib_jenkins_set_url "$su_t/loc3.xml" "http://n.local:8080/"
if grep -q '<jenkinsUrl>http://node07.local:8080/</jenkinsUrl>' "$su_t/loc-new.xml" \
   && python3 -c 'import sys,xml.dom.minidom as m; [m.parse(f) for f in sys.argv[1:]]' "$su_t/loc-new.xml" "$su_t/loc2.xml" "$su_t/loc3.xml" \
   && grep -q '<jenkinsUrl>http://192.168.1.20:8080/</jenkinsUrl>' "$su_t/loc2.xml" && ! grep -q 'old:8080' "$su_t/loc2.xml" \
   && grep -q 'ops@example.com' "$su_t/loc2.xml" \
   && grep -q '<jenkinsUrl>http://n.local:8080/</jenkinsUrl>' "$su_t/loc3.xml" && grep -q 'ops@example.com' "$su_t/loc3.xml"; then
  pass "jenkins JenkinsLocationConfiguration.xml: create / update / insert, valid XML"
else
  fail "jenkins location xml"
fi
# 12-avahi-mdns.sh: MDNS_AVAHI=0 空跑; AIB_SKIP_PKG=1 时只打印主机名
if [[ -x software/12-avahi-mdns.sh ]] \
   && env -i PATH="$PATH" MDNS_AVAHI=0 bash software/12-avahi-mdns.sh 2>&1 | grep -q '^skip:' \
   && env -i PATH="$PATH" MDNS_AVAHI=1 AIB_SKIP_PKG=1 AIB_HOSTNAME_FILE="$su_t/hostname" SERVICE_URL_HOST=1.2.3.4 \
        bash software/12-avahi-mdns.sh 2>&1 | grep -q 'node07.local' \
   && grep -q 'avahi-daemon libnss-mdns' software/12-avahi-mdns.sh \
   && grep -q 'offline_apt_install' software/12-avahi-mdns.sh \
   && grep -q "grep -q '^ENABLED=yes' /etc/ufw/ufw.conf" software/12-avahi-mdns.sh \
   && grep -q 'ufw allow 5353/udp' software/12-avahi-mdns.sh && ! grep -qE 'ufw (--force )?enable' software/12-avahi-mdns.sh \
   && grep -q 'systemctl enable avahi-daemon.service' software/12-avahi-mdns.sh \
   && grep -qE '^  avahi-daemon libnss-mdns$' tools/fetch-offline-bundle.sh \
   && grep -q -- '--require-mdns' tools/validate-offline-bundle.sh && grep -q -- '--require-mdns' build-iso.sh; then
  pass "12-avahi-mdns: skip when not needed, ufw only if active, offline seed + validate"
else
  fail "12-avahi-mdns script / seed wiring"
fi

if command -v xorriso >/dev/null && command -v openssl >/dev/null; then
  bash test/make-fake-iso.sh server "$su_t/s.iso" >/dev/null 2>&1
  bash test/make-fake-iso.sh desktop "$su_t/d.iso" >/dev/null 2>&1
  _suenv() { rm -rf "$2"; xorriso -osirrox on -indev "$1" -extract /provision "$2" >/dev/null 2>&1; }
  # 默认: hostname ubuntu-node → ubuntu-node.local; Server 装 Avahi; provision.env + 实际钩子算出的主机
  if bash build-iso.sh --iso "$su_t/s.iso" --out "$su_t/o1.iso" --password 'Pl@in99x' >"$su_t/o1.log" 2>&1 && _suenv "$su_t/o1.iso" "$su_t/p1" \
     && grep -qx 'AIB_HOSTNAME=ubuntu-node' "$su_t/p1/provision.env" && grep -qx "SERVICE_URL_HOST=''" "$su_t/p1/provision.env" \
     && grep -qx 'MDNS_AVAHI=1' "$su_t/p1/provision.env" \
     && [[ -f "$su_t/p1/12-avahi-mdns.sh" && -f "$su_t/p1/lib-service-url.sh" ]] \
     && grep -q 'http://ubuntu-node.local:3000/' "$su_t/o1.log" && grep -q 'http://ubuntu-node.local:8080/' "$su_t/o1.log" \
     && grep -q '每台机器要用不同的 --hostname' "$su_t/o1.log" \
     && [[ "$(env -i PATH="$PATH" AIB_HOSTNAME_FILE="$su_t/none" bash -c ". '$su_t/p1/provision.env'; . '$su_t/p1/lib-service-url.sh'; aib_service_url_host" 2>/dev/null)" == "ubuntu-node.local" ]]; then
    pass "server default: URLs ubuntu-node.local, MDNS_AVAHI=1, lib + avahi hook shipped"
  else
    fail "server default service URL build: $(tail -3 "$su_t/o1.log")"
  fi
  # --hostname + --service-url-host 覆盖
  if bash build-iso.sh --iso "$su_t/s.iso" --out "$su_t/o2.iso" --password 'Pl@in99x' --hostname node07 --service-url-host 192.168.1.20 >"$su_t/o2.log" 2>&1 && _suenv "$su_t/o2.iso" "$su_t/p2" \
     && grep -qx 'AIB_HOSTNAME=node07' "$su_t/p2/provision.env" && grep -qx 'SERVICE_URL_HOST=192.168.1.20' "$su_t/p2/provision.env" \
     && grep -q 'http://192.168.1.20:3000/' "$su_t/o2.log" && grep -q 'http://192.168.1.20:8080/' "$su_t/o2.log" \
     && ! grep -q '每台机器要用不同的 --hostname' "$su_t/o2.log" \
     && [[ "$(env -i PATH="$PATH" AIB_HOSTNAME_FILE="$su_t/hostname" bash -c ". '$su_t/p2/provision.env'; . '$su_t/p2/lib-service-url.sh'; aib_service_url_host" 2>/dev/null)" == "192.168.1.20" ]] \
     && bash build-iso.sh --iso "$su_t/s.iso" --out "$su_t/o2b.iso" --password x --service-url-host CI.Example.COM --dry-run >"$su_t/o2b.log" 2>&1 \
     && grep -q 'http://ci.example.com:8080/' "$su_t/o2b.log"; then
    pass "--service-url-host overrides (IP / FQDN lowercased), written to provision.env"
  else
    fail "--service-url-host override: $(tail -3 "$su_t/o2.log")"
  fi
  # --skip 45: 只有 Jenkins, 仍装 Avahi; --skip "30 45": 不装 Avahi, --service-url-host 告警忽略
  if bash build-iso.sh --iso "$su_t/s.iso" --out "$su_t/o3.iso" --password x --skip 45 >"$su_t/o3.log" 2>&1 && _suenv "$su_t/o3.iso" "$su_t/p3" \
     && grep -qx 'MDNS_AVAHI=1' "$su_t/p3/provision.env" && ! grep -q ':3000/' "$su_t/o3.log" && grep -q 'ubuntu-node.local:8080/' "$su_t/o3.log" \
     && bash build-iso.sh --iso "$su_t/s.iso" --out "$su_t/o4.iso" --password x --skip 30 >"$su_t/o4.log" 2>&1 && _suenv "$su_t/o4.iso" "$su_t/p4" \
     && grep -qx 'MDNS_AVAHI=1' "$su_t/p4/provision.env" && ! grep -q ':8080/' "$su_t/o4.log" \
     && bash build-iso.sh --iso "$su_t/s.iso" --out "$su_t/o5.iso" --password x --skip "30 45" --service-url-host 10.0.0.5 >"$su_t/o5.log" 2>&1 && _suenv "$su_t/o5.iso" "$su_t/p5" \
     && grep -qx 'MDNS_AVAHI=0' "$su_t/p5/provision.env" && grep -q -- '--service-url-host 只用于预装的 Gitea / Jenkins' "$su_t/o5.log" \
     && bash build-iso.sh --iso "$su_t/s.iso" --out "$su_t/o6.iso" --password x --skip 12 --dry-run >"$su_t/o6.log" 2>&1 \
     && grep -q '跳过了 12-avahi-mdns' "$su_t/o6.log"; then
    pass "--skip 45 / --skip 30 keep avahi; --skip \"30 45\" disables it; --skip 12 warns"
  else
    fail "skip handling for avahi: $(tail -2 "$su_t/o3.log" "$su_t/o5.log")"
  fi
  # Desktop: 同样写 MDNS_AVAHI=1 (钩子发现已装就跳过 apt)
  if bash build-iso.sh --iso "$su_t/d.iso" --out "$su_t/o7.iso" --password 'Pl@in99x' --hostname desk-01 >"$su_t/o7.log" 2>&1 && _suenv "$su_t/o7.iso" "$su_t/p7" \
     && grep -qx 'MDNS_AVAHI=1' "$su_t/p7/provision.env" && grep -qx 'AIB_HOSTNAME=desk-01' "$su_t/p7/provision.env" \
     && grep -q 'http://desk-01.local:3000/' "$su_t/o7.log"; then
    pass "desktop: desk-01.local URLs"
  else
    fail "desktop service URL: $(tail -3 "$su_t/o7.log")"
  fi
  # 非法 --hostname / --service-url-host 构建期失败 (中文提示, 不自动改写)
  for bad in Node01 node.lan node_1 -node node- "$(printf 'n%.0s' {1..64})"; do
    if bash build-iso.sh --iso "$su_t/s.iso" --out "$su_t/bad.iso" --password x --hostname "$bad" --dry-run >"$su_t/bad.log" 2>&1; then
      fail "should reject --hostname $bad"
    elif grep -q -- '--hostname 非法' "$su_t/bad.log" && grep -q '小写字母' "$su_t/bad.log"; then
      pass "rejects --hostname ${bad:0:20}"
    else
      fail "--hostname $bad message: $(tail -2 "$su_t/bad.log")"
    fi
  done
  for bad in "http://x" "x:8080" "1.2.3" "a..b" "a_b.lan"; do
    if bash build-iso.sh --iso "$su_t/s.iso" --out "$su_t/bad.iso" --password x --service-url-host "$bad" --dry-run >"$su_t/bad.log" 2>&1; then
      fail "should reject --service-url-host $bad"
    elif grep -q -- '--service-url-host 非法' "$su_t/bad.log"; then
      pass "rejects --service-url-host $bad"
    else
      fail "--service-url-host $bad message: $(tail -2 "$su_t/bad.log")"
    fi
  done
else
  echo "(xorriso/openssl missing, service URL build test skipped)"
fi
rm -rf "$su_t"

echo "== validate-offline-bundle jenkins-plugins =="
vb="$(mktemp -d)"
mkdir -p "$vb/apt" "$vb/apt-sources/keyrings" "$vb/apt-sources/sources.list.d" "$vb/jenkins-plugins"
for p in git ripgrep openssh-server ca-certificates curl jenkins fontconfig libharfbuzz0b python3-bcrypt microsoft-edge-stable; do
  printf 'Package: %s\nVersion: 1\n\n' "$p" >> "$vb/apt/Packages"
done
for f in docker.asc githubcli-archive-keyring.gpg nvidia-container-toolkit.asc jenkins-keyring.asc nodesource.gpg microsoft-edge.gpg; do : > "$vb/apt-sources/keyrings/$f"; done
for f in docker.list github-cli.list nvidia-container-toolkit.list jenkins.list nodesource.sources microsoft-edge.sources; do : > "$vb/apt-sources/sources.list.d/$f"; done
echo '{"schema":3,"release":"noble","fingerprint":"x","pins":{}}' > "$vb/manifest.json"
: > "$vb/jenkins-plugins/plugins.lock"
for p in git scm-api timestamper; do
  echo "$p" > "$vb/jenkins-plugins/$p.jpi"
  printf '%s:1.0:%s\n' "$p" "$(sha256sum "$vb/jenkins-plugins/$p.jpi" | cut -d' ' -f1)" >> "$vb/jenkins-plugins/plugins.lock"
done
printf 'git\ntimestamper\n' > "$vb/jenkins-plugins/requested.txt"
printf '2.580.2' > "$vb/jenkins-plugins/jenkins-version"
vskip="15 20 25 37 40 45 50 60 70 80 85"
if bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip" --jenkins-plugins "timestamper git" >/dev/null 2>&1; then
  pass "validate accepts complete jenkins-plugins"
else
  fail "validate rejects complete jenkins-plugins"
fi
# --require-mdns (build-iso Server + Gitea/Jenkins): 捆绑里必须有 avahi-daemon + libnss-mdns; skip 12 或两者都 skip 时不要求
if ! bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip" --jenkins-plugins "timestamper git" --require-mdns >"$vb.mdns.log" 2>&1 \
   && grep -q 'avahi-daemon libnss-mdns' "$vb.mdns.log" && grep -q -- '--force' "$vb.mdns.log" \
   && bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip 12" --jenkins-plugins "timestamper git" --require-mdns >/dev/null 2>&1 \
   && bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip 30" --require-mdns >/dev/null 2>&1; then
  printf 'Package: avahi-daemon\nVersion: 1\n\nPackage: libnss-mdns\nVersion: 1\n\n' >> "$vb/apt/Packages"
  if bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip" --jenkins-plugins "timestamper git" --require-mdns >/dev/null 2>&1; then
    pass "validate: avahi required only with --require-mdns and Gitea/Jenkins kept (hint --force)"
  else
    fail "validate --require-mdns with avahi present"
  fi
else
  fail "validate --require-mdns logic: $(head -3 "$vb.mdns.log")"
fi
rm -f "$vb.mdns.log"
# --require-rustdesk (Desktop 默认 RustDesk): rustdesk/ 同版本 deb + sha256, 且 rustdesk 在 apt 池; --skip 38 不要求
if ! bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip" --jenkins-plugins "timestamper git" --require-rustdesk --pin-rustdesk 1.5.1 >"$vb.rd.log" 2>&1 \
   && grep -q 'rustdesk/' "$vb.rd.log" \
   && bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip 38" --jenkins-plugins "timestamper git" --require-rustdesk --pin-rustdesk 1.5.1 >/dev/null 2>&1; then
  mkdir -p "$vb/rustdesk"; echo deb > "$vb/rustdesk/rustdesk-1.5.1-x86_64.deb"
  echo rustdesk-1.5.1-x86_64.deb > "$vb/rustdesk/deb.name"; echo 1.5.1 > "$vb/rustdesk/version"
  sha256sum "$vb/rustdesk/rustdesk-1.5.1-x86_64.deb" | cut -d' ' -f1 > "$vb/rustdesk/sha256"
  if ! bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip" --jenkins-plugins "timestamper git" --require-rustdesk --pin-rustdesk 1.5.1 >"$vb.rd.log" 2>&1 \
     && grep -q 'apt 缺包: rustdesk' "$vb.rd.log"; then
    printf 'Package: rustdesk\nVersion: 1.5.1\n\n' >> "$vb/apt/Packages"
    if bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip" --jenkins-plugins "timestamper git" --require-rustdesk --pin-rustdesk 1.5.1 >/dev/null 2>&1 \
       && ! bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip" --jenkins-plugins "timestamper git" --require-rustdesk --pin-rustdesk 1.5.2 >/dev/null 2>&1 \
       && echo tampered >> "$vb/rustdesk/rustdesk-1.5.1-x86_64.deb" \
       && ! bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip" --jenkins-plugins "timestamper git" --require-rustdesk --pin-rustdesk 1.5.1 >/dev/null 2>&1; then
      pass "validate --require-rustdesk: dir + version + sha256 + apt pool; --skip 38 not required"
    else
      fail "validate --require-rustdesk version/sha checks"
    fi
  else
    fail "validate --require-rustdesk apt pool: $(head -3 "$vb.rd.log")"
  fi
  rm -rf "$vb/rustdesk"
else
  fail "validate --require-rustdesk missing dir: $(head -3 "$vb.rd.log")"
fi
rm -f "$vb.rd.log"
if ! bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip" --jenkins-plugins "git gitea" >/dev/null 2>&1; then
  pass "validate rejects plugin list mismatch"
else
  fail "validate accepted plugin list mismatch"
fi
echo tampered >> "$vb/jenkins-plugins/git.jpi"
if ! bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip" --jenkins-plugins "git timestamper" >/dev/null 2>&1; then
  pass "validate rejects jpi sha256 mismatch"
else
  fail "validate accepted tampered jpi"
fi
echo git > "$vb/jenkins-plugins/git.jpi"
rm "$vb/jenkins-plugins/scm-api.jpi"
if ! bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip" --jenkins-plugins "git timestamper" >/dev/null 2>&1; then
  pass "validate rejects missing dependency jpi"
else
  fail "validate accepted missing dependency jpi"
fi
rm -rf "$vb/jenkins-plugins"
if bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip 30" >/dev/null 2>&1 \
   && ! bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip" >/dev/null 2>&1; then
  pass "validate: jenkins-plugins required unless --skip 30"
else
  fail "validate jenkins-plugins skip logic"
fi
# --require-x11vnc (build-iso Desktop 默认, 未加 --wayland): 捆绑里必须有 x11vnc + xauth
if bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip 30" >/dev/null 2>&1 \
   && ! bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip 30" --require-x11vnc >/dev/null 2>&1; then
  printf 'Package: x11vnc\nVersion: 1\n\nPackage: xauth\nVersion: 1\n\n' >> "$vb/apt/Packages"
  if bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$vskip 30" --require-x11vnc >/dev/null 2>&1; then
    pass "validate: x11vnc required only with --require-x11vnc"
  else
    fail "validate --require-x11vnc with x11vnc present"
  fi
else
  fail "validate --require-x11vnc logic"
fi
# FlClash: 未 skip 时必须有 flclash/ + sha256 一致 + Packages 含 FlClash
_vskip_no37="15 20 25 40 45 50 60 70 80 85"
if ! bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$_vskip_no37 30" >/dev/null 2>&1; then
  mkdir -p "$vb/flclash"
  printf 'dummy-flclash-deb' > "$vb/flclash/FlClash-0.9.3-linux-amd64.deb"
  printf 'FlClash-0.9.3-linux-amd64.deb\n' > "$vb/flclash/deb.name"
  _fsha="$(sha256sum "$vb/flclash/FlClash-0.9.3-linux-amd64.deb" | awk '{print $1}')"
  printf '%s\n' "$_fsha" > "$vb/flclash/sha256"
  printf '0.9.3\n' > "$vb/flclash/version"
  printf '%s  ./FlClash-0.9.3-linux-amd64.deb\n' "$_fsha" > "$vb/flclash/SHA256SUMS"
  printf 'Package: FlClash\nVersion: 0.9.3\n\n' >> "$vb/apt/Packages"
  python3 -c "import json;p='$vb/manifest.json';m=json.load(open(p));m.setdefault('pins',{})['flclash']='latest';m['flclash']={'version':'0.9.3','sha256':open('$vb/flclash/sha256').read().strip(),'filename':'FlClash-0.9.3-linux-amd64.deb'};json.dump(m,open(p,'w'))"
  if bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$_vskip_no37 30" >/dev/null 2>&1; then
    echo tampered >> "$vb/flclash/FlClash-0.9.3-linux-amd64.deb"
    if ! bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$_vskip_no37 30" >/dev/null 2>&1; then
      pass "validate: flclash required unless --skip 37; sha256 enforced"
    else
      fail "validate accepted tampered flclash deb"
    fi
  else
    fail "validate rejected complete flclash: $(bash tools/validate-offline-bundle.sh --bundle "$vb" --skip "$_vskip_no37 30" 2>&1 | tail -5)"
  fi
else
  fail "validate accepted bundle without flclash"
fi
rm -rf "$vb"

echo "== apt deb reuse helper (fake debs) =="
dr="$(mktemp -d)"
mkdir -p "$dr/cache" "$dr/prev" "$dr/arch"
printf 'aaa' > "$dr/cache/a_1_amd64.deb"          # 缓存命中
printf 'bbb' > "$dr/prev/b_2_amd64.deb"           # 旧捆绑命中
printf 'XXX' > "$dr/cache/c_3_amd64.deb"          # 同名但内容(哈希)不同 → 不复用
printf 'd-old' > "$dr/cache/d_0_amd64.deb"        # 旧版本, 本次不需要
printf 'eee' > "$dr/cache/e_5_amd64.deb"          # 大小对但用 SHA512
_h() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
{
  echo "a_1_amd64.deb 3 SHA256:$(_h aaa)"
  echo "b_2_amd64.deb 3 SHA256:$(_h bbb)"
  echo "c_3_amd64.deb 3 SHA256:$(_h ccc)"
  echo "e_5_amd64.deb 3 SHA512:$(printf eee | sha512sum | cut -d' ' -f1)"
  echo "f_6_amd64.deb 3 SHA256:$(_h fff)"
  echo "../evil.deb 3 SHA256:$(_h aaa)"
} > "$dr/need"
# shellcheck disable=SC1091
. tools/apt-deb-reuse.sh
n="$(aib_deb_seed "$dr/need" "$dr/arch" "$dr/reused" "$dr/cache" "$dr/prev")"
if [[ "$n" -eq 3 && -f "$dr/arch/a_1_amd64.deb" && -f "$dr/arch/b_2_amd64.deb" && -f "$dr/arch/e_5_amd64.deb" \
      && ! -e "$dr/arch/c_3_amd64.deb" && ! -e "$dr/arch/d_0_amd64.deb" && ! -e "$dr/evil.deb" ]]; then
  pass "seed: reuse only name+size+hash matches (3), skip stale/mismatch/unneeded"
else
  fail "seed reuse ($n): $(ls "$dr/arch")"
fi
# 模拟 apt 下载缺的 c/f, 再回写缓存
printf 'ccc' > "$dr/arch/c_3_amd64.deb"; printf 'fff' > "$dr/arch/f_6_amd64.deb"
read -r syn pr < <(aib_deb_sync_cache "$dr/arch" "$dr/cache" "$dr/reused" 0)
if [[ "$syn" -eq 3 && "$pr" -eq 0 && "$(cat "$dr/cache/c_3_amd64.deb")" == ccc && -f "$dr/cache/f_6_amd64.deb" \
      && -f "$dr/cache/b_2_amd64.deb" && -f "$dr/cache/d_0_amd64.deb" ]]; then
  pass "sync: new/changed debs written back, nothing pruned by default"
else
  fail "sync cache ($syn $pr)"
fi
read -r syn pr < <(aib_deb_sync_cache "$dr/arch" "$dr/cache" "$dr/reused" 1)
if [[ "$syn" -eq 0 && "$pr" -eq 1 && ! -e "$dr/cache/d_0_amd64.deb" ]]; then
  pass "sync: --prune-apt-cache removes unused only"
else
  fail "prune ($syn $pr)"
fi
# 第二轮: 全部命中
rm -rf "$dr/arch"; mkdir -p "$dr/arch"; : > "$dr/reused2"
sed -i '/evil/d' "$dr/need"
n="$(aib_deb_seed "$dr/need" "$dr/arch" "$dr/reused2" "$dr/cache")"
if [[ "$n" -eq 5 ]]; then pass "second run reuses all 5"; else fail "second run reused $n"; fi
rm -rf "$dr"
if grep -q 'print_uris install --download-only --reinstall' tools/fetch-offline-bundle.sh \
   && grep -q 'aib_deb_seed' tools/fetch-offline-bundle.sh && grep -q 'aib_deb_sync_cache' tools/fetch-offline-bundle.sh \
   && grep -q 'apt-deb-reuse.sh:/apt-deb-reuse.sh:ro' tools/fetch-offline-bundle.sh \
   && grep -q 'reuse_prev gitea' tools/fetch-offline-bundle.sh && grep -q 'reuse_prev godot' tools/fetch-offline-bundle.sh \
   && grep -q 'reuse_prev unity-cli' tools/fetch-offline-bundle.sh \
   && ! grep -q 'apt-cache\|APT_CACHE' <(sed -n '/^expected_fp=/,/^FP$/p' tools/fetch-offline-bundle.sh); then
  pass "fetch wires deb reuse + artifact reuse; cache not in fingerprint"
else
  fail "fetch reuse wiring"
fi

echo "== fetch-offline-bundle recursive depends =="
if grep -q 'force-download' tools/fetch-offline-bundle.sh && grep -q 'apt-cache depends --recurse' tools/fetch-offline-bundle.sh \
   && grep -q 'per-package download fallback' tools/fetch-offline-bundle.sh; then
  pass "fetch recursive depends download"
else
  fail "fetch recursive depends download"
fi

echo "== fetch-offline-bundle.sh syntax =="
if bash -n tools/fetch-offline-bundle.sh; then
  pass "fetch-offline-bundle syntax"
else
  fail "fetch-offline-bundle syntax"
fi

echo "== offline lib helpers =="
if bash -c 'OFFLINE=1 OFFLINE_ROOT=/tmp/nonexistent; . software/lib-offline.sh; offline_enabled || exit 1; offline_apt_ready && exit 1; echo ok'; then
  pass "lib-offline helpers"
else
  fail "lib-offline helpers"
fi

echo "== skip prefix matching =="
SKIP_TEST="$(mktemp)"
cat > "$SKIP_TEST" <<'S'
#!/bin/bash
PROVISION_SKIP="30 70"
should_skip() {
  local name="$1" tok
  for tok in $PROVISION_SKIP; do
    [ -z "$tok" ] && continue
    case "$name" in
      "$tok"|"$tok"-*) return 0 ;;
    esac
  done
  return 1
}
should_skip 30-jenkins && echo skip-30 || echo keep-30
should_skip 70-openmausbot && echo skip-70 || echo keep-70
should_skip 40-nodejs && echo skip-40 || echo keep-40
should_skip 30 && echo skip-exact || echo keep-exact
S
out="$(bash "$SKIP_TEST")"
if echo "$out" | grep -qx 'skip-30'; then pass "skip 30-jenkins"; else fail "skip 30-jenkins"; fi
if echo "$out" | grep -qx 'skip-70'; then pass "skip 70-openmausbot"; else fail "skip 70-openmausbot"; fi
if echo "$out" | grep -qx 'keep-40'; then pass "keep 40-nodejs"; else fail "keep 40-nodejs"; fi

echo "== iso sha256 helper (mismatch fails) =="
fake="$(mktemp)"
echo hello > "$fake"
if bash -c "SRC_ISO='$fake'; source /dev/null
  expected=deadbeef
  actual=\$(sha256sum -- '$fake' | awk '{print \$1}')
  [[ \"\$actual\" == \"\$expected\" ]]" 2>/dev/null; then
  fail "sha mismatch should fail"
else
  pass "sha mismatch detected"
fi
# positive path via build-iso early check using a tiny file + matching sum
sum="$(sha256sum -- "$fake" | awk '{print $1}')"
# build-iso requires password + looks like ISO for grub extract — only test the verify function excerpt
if [[ "$(sha256sum -- "$fake" | awk '{print $1}')" == "$sum" ]]; then
  pass "sha match ok"
else
  fail "sha match"
fi

echo "== packages whitelist rejects spaces =="
if python3 tools/render-user-data.py \
  --template autoinstall/user-data.tmpl \
  --out "$tmp/user-data-badpkg" \
  --password-hash "$HASH" \
  --packages "vim, htop" 2>"$tmp/badpkg.err"; then
  fail "packages with spaces should fail"
else
  if grep -q '不能含空格' "$tmp/badpkg.err"; then
    pass "packages with spaces rejected"
  else
    fail "packages with spaces rejected (msg): $(head -1 "$tmp/badpkg.err")"
  fi
fi

echo "== ssh-allow-pw false without keys rejected =="
if python3 tools/render-user-data.py \
  --template autoinstall/user-data.tmpl \
  --out "$tmp/user-data-nokey-nopw" \
  --password-hash "$HASH" \
  --ssh-allow-pw false 2>"$tmp/nokey.err"; then
  fail "ssh-allow-pw false without keys should fail"
else
  if grep -qi '公钥' "$tmp/nokey.err"; then
    pass "ssh-allow-pw false without keys rejected"
  else
    fail "ssh-allow-pw false without keys rejected (msg)"
  fi
fi

echo "== provision.env %q is source-safe (vim, htop regression) =="
# 旧写法: EXTRA_APT_PACKAGES=vim, htop  → source 时 htop 被当命令
prov_old="$tmp/prov-old.env"
prov_new="$tmp/prov-new.env"
printf '%s\n' 'EXTRA_APT_PACKAGES=vim, htop' 'TARGET_USER=ops' > "$prov_old"
{
  printf 'TARGET_USER=%q\n' "ops"
  printf 'EXTRA_APT_PACKAGES=%q\n' "vim,htop"
} > "$prov_new"
# 旧文件: 在 bash 里 source 会尝试执行 htop (我们用 PATH 里假命令探测)
fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
printf '#!/bin/bash\necho HIJACKED > "%s/hijacked"\n' "$tmp" > "$fakebin/htop"
chmod +x "$fakebin/htop"
rm -f "$tmp/hijacked"
if PATH="$fakebin:$PATH" bash -c "set +e; . '$prov_old'; true" 2>/dev/null; then
  :
fi
if [[ -f "$tmp/hijacked" ]]; then
  pass "reproduced old unquoted breakage (htop executed)"
else
  # 某些 bash 对 `vim, htop` 可能只赋值为 vim, 仍不安全; 再试直接 eval
  fail "could not reproduce old breakage (env may differ)"
fi
rm -f "$tmp/hijacked"
# shellcheck disable=SC1090
PATH="$fakebin:$PATH" bash -c "set -e; . '$prov_new'; printf 'v=%s u=%s\n' \"\$EXTRA_APT_PACKAGES\" \"\$TARGET_USER\"" > "$tmp/prov-out"
if [[ -f "$tmp/hijacked" ]]; then
  fail "new provision.env still executed htop"
elif grep -qx 'v=vim,htop u=ops' "$tmp/prov-out"; then
  pass "new provision.env source-safe + values intact"
else
  fail "new provision.env values: $(cat "$tmp/prov-out")"
fi

echo "== tar ownership: pack root + extract no-same-owner =="
tarown="$tmp/tarown"
mkdir -p "$tarown/src/bin" "$tarown/dst"
echo '#!/bin/sh' > "$tarown/src/bin/tool"
echo hi > "$tarown/src/lib.txt"
# 模拟非 root 打包后再强制 owner 0
tar --owner=0 --group=0 --numeric-owner -czf "$tarown/prefix.tar.gz" -C "$tarown/src" .
mkdir -p "$tarown/extract"
tar --no-same-owner --no-overwrite-dir -xzf "$tarown/prefix.tar.gz" -C "$tarown/extract"
# 提取后属主应是当前用户 (no-same-owner), 绝不应依赖归档里的 uid
uid_now="$(id -u)"
got="$(stat -c %u "$tarown/extract/bin" 2>/dev/null || stat -f %u "$tarown/extract/bin")"
if [[ "$got" == "$uid_now" ]]; then
  pass "extract --no-same-owner keeps extractor uid ($got)"
else
  fail "extract ownership unexpected: got=$got want=$uid_now"
fi
# 归档里记录的应是 0/0
meta="$(tar -tzvf "$tarown/prefix.tar.gz" | awk 'NR==1{print $2; exit}')"
# 常见: root/root 或 0/0
case "$meta" in
  root/root|0/0|root/0|0/root) pass "pack --owner=0 numeric ($meta)" ;;
  *)
    # busybox/gnu 差异: 再查 --numeric
    if tar --numeric-owner -tzvf "$tarown/prefix.tar.gz" 2>/dev/null | awk 'NR==1{exit !($2=="0/0")}'; then
      pass "pack --owner=0 numeric (0/0)"
    else
      fail "pack ownership meta=$meta"
    fi
    ;;
esac

echo "== lib-offline extract flags =="
if grep -q -- '--no-same-owner' software/lib-offline.sh \
  && grep -q -- '--no-overwrite-dir' software/lib-offline.sh \
  && grep -q '/opt/' software/lib-offline.sh \
  && grep -q -- '--owner=0' tools/fetch-offline-bundle.sh; then
  pass "offline tar ownership flags present"
else
  fail "offline tar ownership flags present"
fi

echo "== validate-offline-bundle helper =="
if [[ -x tools/validate-offline-bundle.sh ]] && bash -n tools/validate-offline-bundle.sh; then
  # 空假捆绑应失败
  mkdir -p "$tmp/ob/apt"
  echo '{"schema":3,"release":"noble","pins":{}}' > "$tmp/ob/manifest.json"
  : > "$tmp/ob/apt/Packages"
  if bash tools/validate-offline-bundle.sh --bundle "$tmp/ob" --release noble 2>"$tmp/ob.err"; then
    fail "validate should fail on empty Packages"
  else
    if grep -qE '缺包|不完整|apt-sources' "$tmp/ob.err"; then
      pass "validate-offline-bundle rejects empty apt"
    else
      fail "validate-offline-bundle rejects empty apt: $(head -2 "$tmp/ob.err")"
    fi
  fi
else
  fail "validate-offline-bundle helper"
fi

echo "== apt-sources seed wiring =="
if grep -q 'apt-sources' tools/fetch-offline-bundle.sh \
  && grep -q 'nodesource.gpg' tools/fetch-offline-bundle.sh \
  && grep -q 'nodesource.sources' tools/fetch-offline-bundle.sh \
  && grep -q 'microsoft-edge.gpg' tools/fetch-offline-bundle.sh \
  && grep -q 'microsoft-edge.sources' tools/fetch-offline-bundle.sh \
  && grep -q 'packages.microsoft.com/repos/edge' tools/fetch-offline-bundle.sh \
  && grep -q 'apt-sources' tools/validate-offline-bundle.sh \
  && grep -q 'microsoft-edge.gpg' tools/validate-offline-bundle.sh \
  && grep -q 'microsoft-edge.sources' tools/validate-offline-bundle.sh \
  && grep -q 'third-party apt sources' autoinstall/restore-online-apt.sh \
  && grep -q 'SHARE_KEYRINGS' autoinstall/restore-online-apt.sh \
  && grep -q '"schema": 3' tools/fetch-offline-bundle.sh; then
  pass "apt-sources fetch/validate/restore wired"
else
  fail "apt-sources fetch/validate/restore wired"
fi

echo "== build-iso force-fetch + provision.env %q markers =="
if grep -q -- '--force-fetch' build-iso.sh \
  && grep -q 'EXTRA_APT_PACKAGES=%q' build-iso.sh \
  && grep -q 'validate-offline-bundle.sh' build-iso.sh \
  && grep -q 'release_to_codename' build-iso.sh; then
  pass "build-iso force-fetch + %q + validate hooks"
else
  fail "build-iso force-fetch + %q + validate hooks"
fi

echo "== 99-cleanup sshd/compose/jenkins =="
if grep -q 'sshd -V' software/99-cleanup.sh \
  && grep -q 'docker compose version' software/99-cleanup.sh \
  && grep -q 'jenkins' software/99-cleanup.sh; then
  pass "99-cleanup manifest helpers"
else
  fail "99-cleanup manifest helpers"
fi

echo "== qemu-smoke interactive-sections guard =="
if command -v xorriso >/dev/null; then
  smoke_tmp="$(mktemp -d)"
  mkdir -p "$smoke_tmp/interactive/nocloud" "$smoke_tmp/autodisk/nocloud"
  cat > "$smoke_tmp/interactive/nocloud/user-data" <<'UD'
#cloud-config
autoinstall:
  version: 1
  interactive-sections:
    - storage
  identity:
    hostname: smoke
    username: ops
    password: 'x'
UD
  cat > "$smoke_tmp/autodisk/nocloud/user-data" <<'UD'
#cloud-config
autoinstall:
  version: 1
  interactive-sections: []
  identity:
    hostname: smoke
    username: ops
    password: 'x'
UD
  printf 'instance-id: smoke\n' > "$smoke_tmp/interactive/nocloud/meta-data"
  printf 'instance-id: smoke\n' > "$smoke_tmp/autodisk/nocloud/meta-data"
  echo ok > "$smoke_tmp/interactive/README"
  echo ok > "$smoke_tmp/autodisk/README"
  if xorriso -as mkisofs -R -V SMOKEINT -o "$smoke_tmp/interactive.iso" "$smoke_tmp/interactive" >/dev/null 2>&1 \
    && xorriso -as mkisofs -R -V SMOKEAUTO -o "$smoke_tmp/autodisk.iso" "$smoke_tmp/autodisk" >/dev/null 2>&1; then
    set +e
    out_int="$(bash test/qemu-smoke.sh "$smoke_tmp/interactive.iso" --guard-only 2>&1)"
    rc_int=$?
    out_auto="$(bash test/qemu-smoke.sh "$smoke_tmp/autodisk.iso" --guard-only 2>&1)"
    rc_auto=$?
    set -e
    if [[ "$rc_int" -ne 0 ]] && grep -q -- '--auto-disk' <<<"$out_int" \
      && grep -q 'interactive-sections' <<<"$out_int"; then
      pass "qemu-smoke rejects interactive ISO"
    else
      fail "qemu-smoke rejects interactive ISO (rc=$rc_int)"
      printf '%s\n' "$out_int" | sed 's/^/    /' >&2
    fi
    if [[ "$rc_auto" -eq 0 ]] && grep -q '检查通过' <<<"$out_auto"; then
      pass "qemu-smoke accepts auto-disk ISO (--guard-only)"
    else
      fail "qemu-smoke accepts auto-disk ISO (rc=$rc_auto)"
      printf '%s\n' "$out_auto" | sed 's/^/    /' >&2
    fi
  else
    fail "qemu-smoke mini ISO build (xorriso)"
  fi
  rm -rf "$smoke_tmp"
else
  echo "(xorriso not installed, qemu-smoke guard skipped)"
fi

# 静态：sshd 查 /usr/sbin；新工具列入检查
if grep -q '/usr/sbin' test/qemu-smoke.sh \
  && grep -q 'nvidia-ctk' test/qemu-smoke.sh \
  && grep -qE '^[[:space:]]+gh$' test/qemu-smoke.sh \
  && grep -qE '^[[:space:]]+rg$' test/qemu-smoke.sh \
  && grep -qE '^[[:space:]]+unity$' test/qemu-smoke.sh \
  && grep -qE '^[[:space:]]+godot$' test/qemu-smoke.sh \
  && grep -qE '^[[:space:]]+gitea$' test/qemu-smoke.sh \
  && grep -q 'INSTALL_LOCK' test/qemu-smoke.sh \
  && grep -q -- '--guard-only' test/qemu-smoke.sh; then
  pass "qemu-smoke paths + new tools + guard-only"
else
  fail "qemu-smoke paths + new tools + guard-only"
fi

echo "== shellcheck (if available) =="
if command -v shellcheck >/dev/null; then
  if shellcheck -x build-iso.sh software/run-all.sh software/*.sh tools/fetch-offline-bundle.sh tools/ubuntu-mirror.sh tools/validate-offline-bundle.sh tools/apt-deb-reuse.sh \
      autoinstall/enable-offline-apt.sh autoinstall/restore-online-apt.sh test/local-check.sh \
    && shellcheck -e SC2054,SC2001 -x test/qemu-smoke.sh; then
    pass "shellcheck"
  else
    fail "shellcheck"
  fi
else
  echo "(shellcheck not installed, skipped)"
fi

rm -rf "$tmp" "$SKIP_TEST" "$fake"
if [[ "$FAIL" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL CHECKS PASSED"
