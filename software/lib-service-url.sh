#!/bin/bash
# lib-service-url.sh — Gitea / Jenkins / OpenCode Web 对外 URL 的主机部分 (由 30-jenkins / 45-gitea / 60-opencode / 12-avahi-mdns source)
#
# 优先级:
#   1. SERVICE_URL_HOST (build-iso --service-url-host: IP / FQDN / localhost) 原样使用
#   2. 目标系统 /etc/hostname (chroot 内; 通常 = 构建时 --hostname) → <主机名>.local (mDNS / Avahi)
#   3. provision.env 的 AIB_HOSTNAME → <主机名>.local
#   4. 都不可用 → localhost
# 测试钩子: AIB_HOSTNAME_FILE 覆盖 /etc/hostname 路径。
#
# v1 不做自动同步: 装完改主机名 / Avahi 因重名改成 xxx-2.local 时, URL 不会跟着变 (见 README)。

# RFC 1123 单标签 (mDNS 主机名): 小写字母数字, 中间可有连字符, 1-63 位
aib_valid_mdns_label() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

# --service-url-host: localhost / IPv4 / 主机名或 FQDN (每段 RFC 1123 标签, 总长 ≤253)
aib_valid_service_host() {
  local h="$1" label
  [ -n "$h" ] && [ "${#h}" -le 253 ] || return 1
  if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    local IFS=. o
    for o in $h; do
      [[ "$o" =~ ^(0|[1-9][0-9]{0,2})$ ]] && [ "$o" -le 255 ] || return 1
    done
    return 0
  fi
  [[ "$h" != *. && "$h" != .* && "$h" != *..* ]] || return 1
  local IFS=.
  for label in $h; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  done
  # 纯数字点分但不是合法 IPv4 (如 1.2.3 / 999.1.1.1) 视为非法
  [[ ! "$h" =~ ^[0-9.]+$ ]]
}

# 输出 URL 主机部分 (不含协议 / 端口)
aib_service_url_host() {
  local h="" f="${AIB_HOSTNAME_FILE:-/etc/hostname}"
  if [ -n "${SERVICE_URL_HOST:-}" ]; then
    h="$(printf '%s' "$SERVICE_URL_HOST" | tr '[:upper:]' '[:lower:]')"
    if aib_valid_service_host "$h"; then
      printf '%s\n' "$h"
      return 0
    fi
    echo "warn: SERVICE_URL_HOST=$SERVICE_URL_HOST 非法, 忽略" >&2
  fi
  if [ -r "$f" ]; then
    h="$(head -n1 "$f" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    h="${h%%.*}"
  fi
  if ! aib_valid_mdns_label "$h"; then
    h="$(printf '%s' "${AIB_HOSTNAME:-}" | tr '[:upper:]' '[:lower:]')"
    h="${h%%.*}"
  fi
  if aib_valid_mdns_label "$h"; then
    printf '%s.local\n' "$h"
  else
    echo "warn: 无法确定主机名 (/etc/hostname / AIB_HOSTNAME), URL 用 localhost" >&2
    printf 'localhost\n'
  fi
}

# Gitea app.ini: 同步 [server] ROOT_URL / DOMAIN / SSH_DOMAIN (其它内容与密钥不动)
# 用法: aib_gitea_set_url <app.ini> <host> <port>
aib_gitea_set_url() {
  local conf="$1" host="$2" port="$3"
  sed -i -E \
    -e "s|^ROOT_URL[[:space:]]*=.*|ROOT_URL = http://${host}:${port}/|" \
    -e "s|^DOMAIN[[:space:]]*=.*|DOMAIN = ${host}|" \
    -e "s|^SSH_DOMAIN[[:space:]]*=.*|SSH_DOMAIN = ${host}|" "$conf"
}

# Jenkins: 写 $JENKINS_HOME/jenkins.model.JenkinsLocationConfiguration.xml 的 jenkinsUrl
# (Jenkins 启动时读取, 等价于 系统管理 → 系统配置 → Jenkins URL; 不需要 JCasC 插件)
# 已有文件则只替换/补上 jenkinsUrl, 保留 adminAddress 等其它字段。
# 用法: aib_jenkins_set_url <xml 路径> <url>
aib_jenkins_set_url() {
  local xml="$1" url="$2"
  if [ -s "$xml" ] && grep -q '<jenkins.model.JenkinsLocationConfiguration>' "$xml"; then
    if grep -q '<jenkinsUrl>' "$xml"; then
      sed -i -E "s|<jenkinsUrl>[^<]*</jenkinsUrl>|<jenkinsUrl>${url}</jenkinsUrl>|" "$xml"
    else
      sed -i -E "s|(<jenkins.model.JenkinsLocationConfiguration>)|\\1\\n  <jenkinsUrl>${url}</jenkinsUrl>|" "$xml"
    fi
  else
    cat > "$xml" <<XML
<?xml version='1.1' encoding='UTF-8'?>
<jenkins.model.JenkinsLocationConfiguration>
  <jenkinsUrl>${url}</jenkinsUrl>
</jenkins.model.JenkinsLocationConfiguration>
XML
  fi
}
