#!/bin/bash
# 30-jenkins.sh — Jenkins LTS + OpenJDK
#
# 两个坑:
#   1. Jenkins 2.4xx 起要求 Java 17 或 21, 有些机器会装成 11 然后启动失败。
#      这里优先 21, 退到 17, 都不行就直接报错。
#   2. postinst 会尝试 systemctl daemon-reload / start, chroot 下必然失败。
#      靠 00-base.sh 的 policy-rc.d 拦住, 并用 dpkg -s 校验包确实装上了。
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

install -m 0755 -d /etc/apt/keyrings

# 上游换过 key 文件名, 按顺序回退
KEY_OK=0
for url in \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
  https://pkg.jenkins.io/debian/jenkins.io-2023.key ; do
  if curl -fsSL "$url" | gpg --dearmor -o /etc/apt/keyrings/jenkins.gpg 2>/dev/null; then
    KEY_OK=1; echo "使用签名密钥: $url"; break
  fi
done
[ "$KEY_OK" -eq 1 ] || { echo "ERROR: Jenkins 仓库签名密钥全部获取失败"; exit 1; }
chmod a+r /etc/apt/keyrings/jenkins.gpg

cat > /etc/apt/sources.list.d/jenkins.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/jenkins.gpg] https://pkg.jenkins.io/debian-stable binary/
EOF

apt-get update

JAVA_PKG=""
for p in openjdk-21-jre-headless openjdk-17-jre-headless; do
  if apt-cache show "$p" >/dev/null 2>&1; then JAVA_PKG="$p"; break; fi
done
[ -n "$JAVA_PKG" ] || { echo "ERROR: 找不到 Java 21 或 17"; exit 1; }
echo "安装 $JAVA_PKG"
apt-get install -y --no-install-recommends "$JAVA_PKG"

# jenkins postinst 在 chroot 下可能返回非零, 这里以包状态为准
apt-get install -y jenkins || echo "warn: jenkins postinst 返回非零 (chroot 下正常)"
dpkg -s jenkins >/dev/null 2>&1 || { echo "ERROR: jenkins 包未安装成功"; exit 1; }

systemctl enable jenkins.service 2>/dev/null || true

# Jenkins 要能在流水线里 docker build
if getent group docker >/dev/null && id jenkins >/dev/null 2>&1; then
  usermod -aG docker jenkins || true
fi

java -version 2>&1 | head -1
ls -1 /usr/share/java/jenkins.war >/dev/null 2>&1 && echo "jenkins.war 就位"
echo "jenkins ok (初始管理员密码: /var/lib/jenkins/secrets/initialAdminPassword)"
