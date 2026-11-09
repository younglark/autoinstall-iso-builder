#!/bin/bash
# 30-jenkins.sh — Jenkins LTS + OpenJDK
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
export DEBIAN_FRONTEND=noninteractive

if offline_enabled 2>/dev/null && offline_apt_ready 2>/dev/null; then
  echo "offline: 从本地 apt 安装 Jenkins/OpenJDK (不访问 pkg.jenkins.io)"
  JAVA_PKG="openjdk-21-jre-headless"
  if [ -f "$(offline_root)/java-package.txt" ]; then
    JAVA_PKG="$(cat "$(offline_root)/java-package.txt")"
  fi
  offline_apt_install "$JAVA_PKG"
  offline_apt_install jenkins || echo "warn: jenkins postinst 返回非零 (chroot 下正常)"
else
  install -m 0755 -d /etc/apt/keyrings
  KEY_OK=0
  for url in \
    https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key \
    https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key ; do
    if curl -fsSL "$url" -o /etc/apt/keyrings/jenkins-keyring.asc 2>/dev/null; then
      KEY_OK=1; echo "使用签名密钥: $url"; break
    fi
  done
  [ "$KEY_OK" -eq 1 ] || { echo "ERROR: Jenkins 仓库签名密钥全部获取失败"; exit 1; }
  chmod a+r /etc/apt/keyrings/jenkins-keyring.asc
  printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/' \
    > /etc/apt/sources.list.d/jenkins.list
  apt-get update
  JAVA_PKG=""
  for p in openjdk-21-jre-headless openjdk-17-jre-headless; do
    if apt-cache show "$p" >/dev/null 2>&1; then JAVA_PKG="$p"; break; fi
  done
  [ -n "$JAVA_PKG" ] || { echo "ERROR: 找不到 Java 21 或 17"; exit 1; }
  echo "安装 $JAVA_PKG"
  apt-get install -y --no-install-recommends "$JAVA_PKG"
  apt-get install -y jenkins || echo "warn: jenkins postinst 返回非零 (chroot 下正常)"
fi

dpkg -s jenkins >/dev/null 2>&1 || { echo "ERROR: jenkins 包未安装成功"; exit 1; }
systemctl enable jenkins.service 2>/dev/null || true
if getent group docker >/dev/null && id jenkins >/dev/null 2>&1; then
  usermod -aG docker jenkins || true
fi
java -version 2>&1 | head -1
ls -1 /usr/share/java/jenkins.war >/dev/null 2>&1 && echo "jenkins.war 就位"
echo "jenkins ok (初始管理员密码: /var/lib/jenkins/secrets/initialAdminPassword)"
