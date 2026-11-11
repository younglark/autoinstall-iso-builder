#!/bin/bash
# 30-jenkins.sh — Jenkins LTS + OpenJDK, 装机即零配置可用
#
#   * 跳过安装向导: systemd drop-in JAVA_OPTS=-Djenkins.install.runSetupWizard=false,
#     并写 jenkins.install.InstallUtil.lastExecVersion / UpgradeWizard.state
#   * 管理员: init.groovy.d 脚本 (只含 bcrypt 哈希 "#jbcrypt:$2a$...", 不含明文) 首次启动时创建,
#     HudsonPrivateSecurityRealm(禁止自助注册) + FullControlOnceLoggedIn(匿名不可读); 成功后自删
#   * 插件: 默认 Pipeline / git / gitea / docker-workflow / credentials-binding / timestamper
#     (+ 全部必需依赖)。在线用 resolve-jenkins-plugins.py (纯 Python 标准库) 按本机 Jenkins 版本的
#     update center 解析并 sha256 校验; 离线直接拷贝捆绑 jenkins-plugins/ (fetch 时用同一脚本按同一版本解析)
#   * 监听 0.0.0.0:8080 (默认), 不改防火墙
#   * Jenkins URL = http://<主机名>.local:8080/ (mDNS, 主机名取目标机 /etc/hostname; 构建时
#     --service-url-host 可改成 IP / FQDN / localhost): 写 jenkins.model.JenkinsLocationConfiguration.xml
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$HERE/lib-offline.sh" ] && . "$HERE/lib-offline.sh"
# shellcheck disable=SC1091
. "$HERE/lib-service-url.sh"
export DEBIAN_FRONTEND=noninteractive

JENKINS_HOME_DIR="/var/lib/jenkins"
PLUGIN_DIR="$JENKINS_HOME_DIR/plugins"
INIT_DIR="$JENKINS_HOME_DIR/init.groovy.d"
ADMIN_GROOVY="$INIT_DIR/00-autoinstall-admin.groovy"
DROPIN_DIR="/etc/systemd/system/jenkins.service.d"
SECRET_FILE="$HERE/jenkins-admin.secret"
RANDOM_PW_FILE="/root/jenkins-admin-password"
DEFAULT_PLUGINS="workflow-aggregator git gitea docker-workflow credentials-binding timestamper rebuild ansicolor docker-plugin parameterized-trigger"
JENKINS_PLUGINS="${JENKINS_PLUGINS:-$DEFAULT_PLUGINS}"
RESOLVER="$HERE/resolve-jenkins-plugins.py"

# 插件名白名单 (name 或 name:version)
for p in $JENKINS_PLUGINS; do
  [[ "$p" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(:[A-Za-z0-9._-]+)?$ ]] || { echo "ERROR: 非法插件名: $p"; exit 1; }
done

# ---------------------------------------------------------------- 安装 Jenkins / JDK / bcrypt
if offline_enabled 2>/dev/null && offline_apt_ready 2>/dev/null; then
  echo "offline: 从本地 apt 安装 Jenkins/OpenJDK (不访问 pkg.jenkins.io)"
  JAVA_PKG="openjdk-21-jre-headless"
  if [ -f "$(offline_root)/java-package.txt" ]; then
    JAVA_PKG="$(cat "$(offline_root)/java-package.txt")"
  fi
  offline_apt_install "$JAVA_PKG"
  # Jenkins 启动时 AWT 字体初始化需要 (headless JRE 不带, 缺了会 AWTProblem 启动失败)
  offline_apt_install fontconfig libharfbuzz0b
  offline_apt_install jenkins || echo "warn: jenkins postinst 返回非零 (chroot 下正常)"
  offline_apt_install python3-bcrypt || echo "warn: python3-bcrypt 不在捆绑里 (旧捆绑?), 管理员密码将在首次启动时哈希"
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
  # Jenkins 启动时 AWT 字体初始化需要 (headless JRE 不带, 缺了会 AWTProblem 启动失败)
  apt-get install -y --no-install-recommends fontconfig libharfbuzz0b
  apt-get install -y jenkins || echo "warn: jenkins postinst 返回非零 (chroot 下正常)"
  apt-get install -y --no-install-recommends python3-bcrypt \
    || echo "warn: python3-bcrypt 安装失败, 管理员密码将在首次启动时哈希"
fi

dpkg -s jenkins >/dev/null 2>&1 || { echo "ERROR: jenkins 包未安装成功"; exit 1; }
id jenkins >/dev/null 2>&1 || { echo "ERROR: 缺少 jenkins 用户"; exit 1; }
JENKINS_VERSION="$(dpkg-query -W -f='${Version}' jenkins)"
JENKINS_VERSION="${JENKINS_VERSION%%-*}"
WAR="/usr/share/java/jenkins.war"
[ -f "$WAR" ] || { echo "ERROR: 缺少 $WAR"; exit 1; }
echo "Jenkins $JENKINS_VERSION ($JAVA_PKG)"

install -d -m 0755 -o jenkins -g jenkins "$JENKINS_HOME_DIR"
install -d -m 0755 -o jenkins -g jenkins "$PLUGIN_DIR"
install -d -m 0750 -o jenkins -g jenkins "$INIT_DIR"

# ---------------------------------------------------------------- 跳过安装向导
install -d -m 0755 "$DROPIN_DIR"
cat > "$DROPIN_DIR/50-autoinstall.conf" <<'UNIT'
# 由 autoinstall software/30-jenkins.sh 生成: 跳过安装向导 (管理员与插件已在装机时就绪)
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false"
UNIT
chmod 0644 "$DROPIN_DIR/50-autoinstall.conf"
for f in jenkins.install.InstallUtil.lastExecVersion jenkins.install.UpgradeWizard.state; do
  printf '%s' "$JENKINS_VERSION" > "$JENKINS_HOME_DIR/$f"
  chown jenkins:jenkins "$JENKINS_HOME_DIR/$f"
done

# ---------------------------------------------------------------- Jenkins URL
# 不写的话首页会提示 "Jenkins URL 未配置", 构建链接 / Webhook 回调地址也不对
JENKINS_HTTP_PORT="${JENKINS_HTTP_PORT:-8080}"
JENKINS_URL_VALUE="http://$(aib_service_url_host):${JENKINS_HTTP_PORT}/"
LOCATION_XML="$JENKINS_HOME_DIR/jenkins.model.JenkinsLocationConfiguration.xml"
aib_jenkins_set_url "$LOCATION_XML" "$JENKINS_URL_VALUE"
chown jenkins:jenkins "$LOCATION_XML"
chmod 0644 "$LOCATION_XML"
echo "Jenkins URL = $JENKINS_URL_VALUE ($LOCATION_XML)"

# ---------------------------------------------------------------- 插件
if offline_enabled 2>/dev/null; then
  PDIR="$(offline_root)/jenkins-plugins"
  [ -d "$PDIR" ] || { echo "ERROR: 离线捆绑缺少 jenkins-plugins/ — 请用 --force 重建"; exit 1; }
  # shellcheck disable=SC2086
  want="$(printf '%s\n' $JENKINS_PLUGINS | sort -u | tr '\n' ' ')"
  have="$(sort -u < "$PDIR/requested.txt" 2>/dev/null | tr '\n' ' ')"
  [ "$want" = "$have" ] || { echo "ERROR: 捆绑插件列表 ($have) 与要求 ($want) 不一致 — 请用 --force 重建"; exit 1; }
  bundle_jv="$(cat "$PDIR/jenkins-version" 2>/dev/null || true)"
  [ "$bundle_jv" = "$JENKINS_VERSION" ] || echo "warn: 插件按 Jenkins $bundle_jv 解析, 实际安装 $JENKINS_VERSION"
  n=0
  for f in "$PDIR"/*.jpi "$PDIR"/*.hpi; do
    [ -e "$f" ] || continue
    install -m 0644 -o jenkins -g jenkins "$f" "$PLUGIN_DIR/$(basename "${f%.*}").jpi"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { echo "ERROR: jenkins-plugins/ 内没有插件"; exit 1; }
  install -m 0644 -o jenkins -g jenkins "$PDIR/plugins.lock" "$JENKINS_HOME_DIR/plugins.lock"
  echo "offline: 已安装 $n 个 Jenkins 插件 (lock: $JENKINS_HOME_DIR/plugins.lock)"
else
  [ -f "$RESOLVER" ] || { echo "ERROR: 缺少 $RESOLVER"; exit 1; }
  command -v python3 >/dev/null || apt-get install -y --no-install-recommends python3
  # shellcheck disable=SC2086
  python3 "$RESOLVER" --jenkins-version "$JENKINS_VERSION" --out "$PLUGIN_DIR" \
    --lock "$JENKINS_HOME_DIR/plugins.lock" $JENKINS_PLUGINS
  chown -R jenkins:jenkins "$PLUGIN_DIR" "$JENKINS_HOME_DIR/plugins.lock"
  echo "已下载 $(find "$PLUGIN_DIR" -maxdepth 1 -name '*.jpi' | wc -l) 个 Jenkins 插件 (含依赖)"
fi

# ---------------------------------------------------------------- 管理员 (init.groovy.d)
ADMIN_USER="${JENKINS_ADMIN_USER:-${TARGET_USER:-}}"
[ -n "$ADMIN_USER" ] && [ "$ADMIN_USER" != "root" ] || ADMIN_USER="jenkins-admin"
[[ "$ADMIN_USER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { echo "ERROR: 非法 Jenkins 管理员名"; exit 1; }
ADMIN_PW=""
if [ -f "$SECRET_FILE" ]; then
  # shellcheck disable=SC1090
  ADMIN_PW="$(. "$SECRET_FILE"; printf '%s' "${JENKINS_ADMIN_PASSWORD:-}")"
fi
PW_SOURCE="build"
if [ -z "$ADMIN_PW" ]; then
  ADMIN_PW="$(openssl rand -base64 18 2>/dev/null | tr -d '/+=\n' | cut -c1-20)"
  [ "${#ADMIN_PW}" -ge 16 ] || ADMIN_PW="$(head -c 64 /dev/urandom | sha256sum | cut -c1-24)"
  PW_SOURCE="random"
fi

HASH=""
if python3 -c 'import bcrypt' 2>/dev/null; then
  # shellcheck disable=SC2016
  # 明文经 stdin 传入, 不出现在命令行/日志; jBCrypt 认 $2a$ ($2b$/$2y$ 算法相同)
  HASH="$(printf '%s' "$ADMIN_PW" | python3 -c 'import sys,bcrypt; h=bcrypt.hashpw(sys.stdin.buffer.read(), bcrypt.gensalt(10)).decode(); print("$2a$"+h[4:])')"
fi

if [ -n "$HASH" ]; then
  CREATE_LINE="realm.createAccountWithHashedPassword(user, '#jbcrypt:${HASH}')"
  PW_FILE_LINE=""
else
  # 兜底: 首次启动时由 Jenkins 自己哈希; 明文仅存在于 jenkins 0600 文件, 用后删除
  umask 077
  printf '%s' "$ADMIN_PW" > "$INIT_DIR/.admin-password"
  umask 022
  chown jenkins:jenkins "$INIT_DIR/.admin-password"
  chmod 0600 "$INIT_DIR/.admin-password"
  CREATE_LINE="realm.createAccount(user, pwFile.text)"
  PW_FILE_LINE="def pwFile = new File(Jenkins.get().rootDir, 'init.groovy.d/.admin-password')"
fi

cat > "$ADMIN_GROOVY" <<GROOVY
// 由 autoinstall software/30-jenkins.sh 生成; 首次启动创建管理员后自删
import jenkins.model.Jenkins
import hudson.security.HudsonPrivateSecurityRealm
import hudson.security.FullControlOnceLoggedInAuthorizationStrategy

def j = Jenkins.get()
def user = '${ADMIN_USER}'
${PW_FILE_LINE}
def realm = (j.securityRealm instanceof HudsonPrivateSecurityRealm) ? j.securityRealm : new HudsonPrivateSecurityRealm(false)
if (realm.allowsSignup()) {
  realm = new HudsonPrivateSecurityRealm(false)
}
if (realm.getUser(user) == null) {
  ${CREATE_LINE}
}
j.setSecurityRealm(realm)
def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
j.setAuthorizationStrategy(strategy)
j.save()
new File(j.rootDir, 'init.groovy.d/.admin-password').delete()
new File(j.rootDir, 'init.groovy.d/00-autoinstall-admin.groovy').delete()
println('autoinstall: Jenkins admin ready: ' + user)
GROOVY
chown jenkins:jenkins "$ADMIN_GROOVY"
chmod 0600 "$ADMIN_GROOVY"

if [ "$PW_SOURCE" = "random" ]; then
  umask 077
  printf '%s\n' "$ADMIN_PW" > "$RANDOM_PW_FILE"
  umask 022
  chmod 0600 "$RANDOM_PW_FILE"
  echo "Jenkins 管理员 $ADMIN_USER: 随机密码写入 $RANDOM_PW_FILE (root 0600)"
else
  echo "Jenkins 管理员 $ADMIN_USER: 密码 = 构建时 --password / --jenkins-admin-password"
fi
ADMIN_PW=""
rm -f "$SECRET_FILE"

# ---------------------------------------------------------------- 服务
systemctl enable jenkins.service 2>/dev/null || true
if getent group docker >/dev/null; then
  usermod -aG docker jenkins || true
fi
java -version 2>&1 | head -1
grep -q 'runSetupWizard=false' "$DROPIN_DIR/50-autoinstall.conf"
[ -f "$ADMIN_GROOVY" ]
grep -qF "<jenkinsUrl>${JENKINS_URL_VALUE}</jenkinsUrl>" "$LOCATION_XML"
echo "jenkins ok: ${JENKINS_URL_VALUE} (也可 http://<本机IP>:${JENKINS_HTTP_PORT}/, 监听 0.0.0.0:${JENKINS_HTTP_PORT}); 管理员 $ADMIN_USER; 插件: $JENKINS_PLUGINS"
