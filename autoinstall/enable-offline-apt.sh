#!/bin/bash
# Enable the file:/ offline apt bundle inside the target.
# Lives as a real script on the ISO so find \( \) is safe (unlike nested sh -c).
set -euo pipefail

OFFLINE_ROOT="${OFFLINE_ROOT:-/opt/offline}"
APT_DIR="${OFFLINE_ROOT}/apt"
LOG_DIR=/var/log/autoinstall
mkdir -p "$LOG_DIR"

if [ ! -f "$APT_DIR/Packages" ] && [ ! -f "$APT_DIR/Packages.gz" ]; then
  echo "ERROR: offline apt index missing under $APT_DIR" | tee -a "$LOG_DIR/offline-apt-update.log"
  exit 1
fi

# _apt drops privileges; ISO/cp -a trees must be traversable/readable.
chmod -R a+rX "$OFFLINE_ROOT" 2>/dev/null || true

mkdir -p /etc/apt/sources.list.d.offline-bak
if [ -f /etc/apt/sources.list ]; then
  mv /etc/apt/sources.list /etc/apt/sources.list.offline-bak
fi

# Move every sources entry aside (*.list and DEB822 *.sources).
find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) \
  -exec mv {} /etc/apt/sources.list.d.offline-bak/ \;

cat > /etc/apt/apt.conf.d/99-offline-bundle <<'CONF'
Acquire::AllowInsecureRepositories "true";
Acquire::AllowDowngradeToInsecureRepositories "true";
CONF

echo "deb [trusted=yes allow-insecure=yes] file:${APT_DIR} ./" \
  > /etc/apt/sources.list.d/00-offline-bundle.list

set +e
apt-get update -y 2>&1 | tee "$LOG_DIR/offline-apt-update.log"
rc=${PIPESTATUS[0]}
set -e
exit "$rc"
