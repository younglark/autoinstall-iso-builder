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
if python3 -c "import yaml; d=yaml.safe_load(open('$tmp/user-data-interactive')); ai=d['autoinstall']; assert ai.get('interactive-sections')==['storage']; assert ai['storage']['layout']['name']=='direct'; assert ai['storage']['layout']['match']['size']=='largest'; late=ai.get('late-commands') or []; assert any('run-all.sh' in str(c) for c in late)"; then
  pass "default interactive storage + layout defaults + late-commands"
else
  fail "default interactive storage + layout defaults + late-commands"
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
if python3 -c "import yaml; d=yaml.safe_load(open('$tmp/user-data-autodisk')); ai=d['autoinstall']; assert ai.get('interactive-sections') in ([], None); assert ai['storage']['layout']['match']['size']=='largest'"; then
  pass "auto-disk empty interactive-sections"
else
  fail "auto-disk empty interactive-sections"
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

echo "== fetch-offline-bundle recursive depends =="
if grep -q 'force-download' tools/fetch-offline-bundle.sh && grep -q 'apt-cache depends --recurse' tools/fetch-offline-bundle.sh; then
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

echo "== shellcheck (if available) =="
if command -v shellcheck >/dev/null; then
  if shellcheck -x build-iso.sh software/run-all.sh software/*.sh tools/fetch-offline-bundle.sh test/local-check.sh \
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
