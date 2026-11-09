#!/bin/bash
# Remove temporary offline apt pin and restore installer-written Ubuntu sources.
set -euo pipefail

rm -f /etc/apt/sources.list.d/00-offline-bundle.list
rm -f /etc/apt/apt.conf.d/99-offline-bundle
if [ -f /etc/apt/sources.list.offline-bak ]; then
  mv /etc/apt/sources.list.offline-bak /etc/apt/sources.list
fi
if [ -d /etc/apt/sources.list.d.offline-bak ]; then
  shopt -s nullglob
  for f in /etc/apt/sources.list.d.offline-bak/*; do
    mv "$f" /etc/apt/sources.list.d/
  done
  shopt -u nullglob
  rmdir /etc/apt/sources.list.d.offline-bak 2>/dev/null || true
fi
