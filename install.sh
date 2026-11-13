#!/usr/bin/env bash
# proxy-oneclick：一键安装 GOST 代理（HTTP + SOCKS5，账号密码 / IP 白名单，systemd 开机自启）
# 全部逻辑都在函数里，最后一行才调用 main：用 curl | bash 执行时，没下载完不会跑半截。
set -euo pipefail

GOST_VERSION="3.3.3"
# 官方 checksums.txt 里的值：不管从 GitHub 还是镜像下载，文件都必须对得上才装
declare -A GOST_SHA256=(
  [amd64]="f4c1255dc892a7014c0ad6e5f1c3573108f7bea4403f04f21873406ab58aa666"
  [arm64]="4c704c92df6eeea8a3b08d0de4fd3c44343095a20136b3b6cf334f98d2f174ab"
  [armv7]="721343061accae0003c380eec61188dda75f5d324ce9ffdd733c4251cb9d2210"
  [386]="e7f6c18813cf6a1be78e563affa5e481622f1bd8d5916f3c15c54fed6b857813"
)
# GitHub 直连失败后依次试的加速前缀（国内服务器常连不上 GitHub）
DEFAULT_MIRRORS="https://ghfast.top https://gh-proxy.com"

BIN=/usr/local/bin/gost
MANAGER=/usr/local/bin/gost-proxy
CONF_DIR=/etc/gost
CONF_YML=/etc/gost/gost.yml
CONF_ENV=/etc/gost/proxy.env
UNIT=/etc/systemd/system/gost.service
SVC_USER=gost
IPV4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
CIDR4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
CIDR6_RE='^[0-9A-Fa-f:]+(/[0-9]{1,3})?$'

say()  { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法：bash install.sh [选项]      （装好后可以直接用 gost-proxy [选项]）

  --user NAME          用户名（缺省 proxy；字母、数字、. _ -）
  --pass PASS          密码（缺省随机 16 位；字母、数字、. _ ~ -，6-64 位）
  --new-pass           重新生成随机密码
  --http-port N        HTTP 代理端口（缺省 8080，0 = 不开）
  --socks-port N       SOCKS5 代理端口（缺省 1080，0 = 不开）
  --no-auth            不要账号密码（必须同时给 --allow）
  --auth               重新开启账号密码
  --allow IP[,IP...]   只允许这些来源 IP / 网段连接，none = 取消限制
  --file PATH          用本地的 gost 压缩包，不下载
  --mirror URL         再加一个 GitHub 加速前缀（也可以设环境变量 GH_PROXY）
  --no-service         只装程序和配置，不动 systemd 和防火墙（容器里用）
  --show               显示当前的代理地址和账号
  --uninstall          卸载
  -h, --help           显示帮助

再次运行会沿用上次的设置，只改你这次给的选项。
EOF
}

# ---------- 选项 ----------

# 命令行选项：空 = 这次没给，沿用上次保存的设置
init_flags() {
  ACTION=install
  F_USER='' F_PASS='' F_NEW_PASS=0 F_HTTP='' F_SOCKS='' F_AUTH='' F_ALLOW=''
  F_FILE='' F_MIRROR='' F_SERVICE=''
}

need_val() { [[ $2 -ge 2 ]] || die "$1 后面要跟一个值"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --user)       need_val "$1" $#; F_USER=$2; shift 2 ;;
      --pass)       need_val "$1" $#; F_PASS=$2; shift 2 ;;
      --new-pass)   F_NEW_PASS=1; shift ;;
      --http-port)  need_val "$1" $#; F_HTTP=$2; shift 2 ;;
      --socks-port) need_val "$1" $#; F_SOCKS=$2; shift 2 ;;
      --no-auth)    F_AUTH=0; shift ;;
      --auth)       F_AUTH=1; shift ;;
      --allow)      need_val "$1" $#; F_ALLOW=$2; shift 2 ;;
      --file)       need_val "$1" $#; F_FILE=$2; shift 2 ;;
      --mirror)     need_val "$1" $#; F_MIRROR=$2; shift 2 ;;
      --no-service) F_SERVICE=0; shift ;;
      --show)       ACTION=show; shift ;;
      --uninstall)  ACTION=uninstall; shift ;;
      -h|--help)    usage; exit 0 ;;
      *)            die "不认识的选项：$1（--help 看用法）" ;;
    esac
  done
}

# 上次保存的设置（root 600 文件，由 write_state 用 %q 写出）
load_state() {
  PROXY_USER='' PROXY_PASS='' HTTP_PORT='' SOCKS_PORT='' AUTH='' ALLOW='' SERVICE=''
  if [[ -f $CONF_ENV ]]; then
    # shellcheck disable=SC1090
    . "$CONF_ENV" || die "读不了 $CONF_ENV"
  fi
}

random_pass() {
  local s=''
  while (( ${#s} < 16 )); do
    s+=$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 256 /dev/urandom))
  done
  printf '%s' "${s:0:16}"
}

# 优先级：这次的选项 > 上次保存的 > 缺省
resolve_opts() {
  O_USER=${F_USER:-${PROXY_USER:-proxy}}
  O_HTTP=${F_HTTP:-${HTTP_PORT:-8080}}
  O_SOCKS=${F_SOCKS:-${SOCKS_PORT:-1080}}
  O_AUTH=${F_AUTH:-${AUTH:-1}}
  O_ALLOW=${F_ALLOW:-$ALLOW}
  O_SERVICE=${F_SERVICE:-${SERVICE:-1}}
  O_FILE=$F_FILE
  O_MIRROR=$F_MIRROR
  if [[ $O_ALLOW == none ]]; then O_ALLOW=''; fi
  if [[ -n $F_PASS ]]; then
    O_PASS=$F_PASS
  elif [[ $F_NEW_PASS == 1 || -z $PROXY_PASS ]]; then
    O_PASS=$(random_pass)
  else
    O_PASS=$PROXY_PASS
  fi
}

valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 <= 65535 )); }

# 白名单：逗号或空格分隔，校验后规整成逗号分隔
normalize_allow() {
  [[ -n $O_ALLOW ]] || return 0
  local items ip
  read -ra items <<< "${O_ALLOW//,/ }"
  for ip in "${items[@]}"; do
    [[ $ip =~ $CIDR4_RE || $ip =~ $CIDR6_RE ]] || die "--allow 里的「$ip」不是 IP 或网段"
  done
  O_ALLOW=$(IFS=,; printf '%s' "${items[*]}")
}

validate_opts() {
  [[ $O_USER =~ ^[A-Za-z0-9._-]{1,32}$ ]] || die "用户名只能用字母、数字和 . _ -（1-32 位）"
  [[ $O_PASS =~ ^[A-Za-z0-9._~-]{6,64}$ ]] \
    || die "密码只能用字母、数字和 . _ ~ -（6-64 位），这样放进代理地址里不用转义"
  valid_port "$O_HTTP" || die "--http-port 要是 0-65535 的数字"
  valid_port "$O_SOCKS" || die "--socks-port 要是 0-65535 的数字"
  O_HTTP=$((10#$O_HTTP)); O_SOCKS=$((10#$O_SOCKS))
  (( O_HTTP + O_SOCKS > 0 )) || die "HTTP 和 SOCKS5 至少要开一个"
  if (( O_HTTP > 0 && O_HTTP == O_SOCKS )); then die "HTTP 和 SOCKS5 不能用同一个端口"; fi
  normalize_allow
  if [[ $O_AUTH == 0 && -z $O_ALLOW ]]; then
    die "--no-auth 必须配 --allow（不然就是谁都能用的开放代理，很快会被扫到滥用）；确实只靠安全组限制的话，写 --allow 0.0.0.0/0"
  fi
}

preflight() {
  local t
  for t in tar sha256sum; do command -v "$t" >/dev/null 2>&1 || die "缺少命令 $t"; done
  if [[ -z $O_FILE ]] && ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "没有 curl 也没有 wget，没法下载"
  fi
  if [[ $O_SERVICE == 1 ]]; then
    [[ -d /run/systemd/system ]] || die "这台机器没跑 systemd；加 --no-service 只装程序，再自己运行 $BIN -C $CONF_YML"
    command -v useradd >/dev/null 2>&1 || die "缺少命令 useradd"
  fi
}

# ---------- 安装 gost ----------

detect_arch() {
  case $(uname -m) in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7*)        echo armv7 ;;
    i386|i686)     echo 386 ;;
    *)             die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

fetch() {  # fetch 地址 保存到
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --speed-limit 10240 --speed-time 20 --max-time 300 -o "$2" "$1"
  else
    wget -q --timeout=20 -O "$2" "$1"
  fi
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

download_gost() {  # download_gost 文件名 保存到 sha256
  local url="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/$1"
  local prefix src
  for prefix in "" ${GH_PROXY:-} $O_MIRROR $DEFAULT_MIRRORS; do
    if [[ -z $prefix ]]; then src=$url; else src="${prefix%/}/$url"; fi
    say "下载 $src"
    if ! fetch "$src" "$2"; then warn "下载失败，换下一个源"; continue; fi
    if [[ $(sha256_of "$2") == "$3" ]]; then return 0; fi
    warn "文件校验对不上（没下完或被镜像改过），换下一个源"
  done
  die "所有下载源都失败了。可以在能上 GitHub 的电脑下载 $url ，传到服务器后加 --file 指定"
}

install_gost() {
  if [[ -x $BIN && $("$BIN" -V 2>/dev/null || true) == *"v${GOST_VERSION}"* ]]; then
    say "gost v${GOST_VERSION} 已装好，跳过下载"
    return 0
  fi
  local arch name want
  arch=$(detect_arch)
  name="gost_${GOST_VERSION}_linux_${arch}.tar.gz"
  want=${GOST_SHA256[$arch]}
  TMP_DIR=$(mktemp -d)
  if [[ -n $O_FILE ]]; then
    [[ -f $O_FILE ]] || die "找不到文件 $O_FILE"
    cp "$O_FILE" "$TMP_DIR/gost.tgz"
    [[ $(sha256_of "$TMP_DIR/gost.tgz") == "$want" ]] || die "$O_FILE 校验对不上，要的是 $name"
  else
    download_gost "$name" "$TMP_DIR/gost.tgz" "$want"
  fi
  tar -xzf "$TMP_DIR/gost.tgz" -C "$TMP_DIR" gost || die "压缩包里没有 gost 程序"
  install -m 0755 "$TMP_DIR/gost" "$BIN"
  say "已安装 $("$BIN" -V 2>/dev/null || echo gost)"
}

# ---------- 配置 ----------

ensure_user() {
  if id -u "$SVC_USER" >/dev/null 2>&1; then return 0; fi
  local nologin
  nologin=$(command -v nologin || echo /bin/false)
  useradd --system --no-create-home --shell "$nologin" "$SVC_USER" || die "建系统用户 $SVC_USER 失败"
}

# 不是本脚本装的同名配置 / 服务，先改名留着，不直接覆盖
backup_foreign() {
  if [[ -f $CONF_ENV ]]; then return 0; fi
  local f ts
  ts=$(date +%Y%m%d%H%M%S)
  for f in "$CONF_YML" "$UNIT"; do
    if [[ -f $f ]]; then
      mv "$f" "$f.bak.$ts"
      warn "已有的 $f 不是本脚本装的，已改名为 $f.bak.$ts"
    fi
  done
}

service_yaml() {  # service_yaml 类型 端口
  printf -- '- name: %s\n  addr: ":%s"\n' "$1" "$2"
  if [[ -n $O_ALLOW ]]; then printf '  admission: allow\n'; fi
  printf '  handler:\n    type: %s\n' "$1"
  if [[ $O_AUTH == 1 ]]; then
    printf '    auth:\n      username: "%s"\n      password: "%s"\n' "$O_USER" "$O_PASS"
  fi
  printf '  listener:\n    type: tcp\n'
}

write_config() {
  install -d -m 0755 "$CONF_DIR"
  local group=root ip
  if [[ $O_SERVICE == 1 ]]; then group=$SVC_USER; fi
  {
    echo "# 由 proxy-oneclick 生成。改设置请运行 gost-proxy --help，手改会在下次运行时被覆盖"
    if [[ -n $O_ALLOW ]]; then
      printf 'admissions:\n- name: allow\n  whitelist: true\n  matchers:\n'
      # 本机地址总在白名单里，安装后的自测要用
      for ip in 127.0.0.1 ::1 ${O_ALLOW//,/ }; do printf '  - "%s"\n' "$ip"; done
    fi
    echo "services:"
    if (( O_HTTP > 0 )); then service_yaml http "$O_HTTP"; fi
    if (( O_SOCKS > 0 )); then service_yaml socks5 "$O_SOCKS"; fi
  } > "$CONF_YML.tmp"
  chown "root:$group" "$CONF_YML.tmp"
  chmod 0640 "$CONF_YML.tmp"
  mv -f "$CONF_YML.tmp" "$CONF_YML"
}

write_state() {
  printf 'PROXY_USER=%q\nPROXY_PASS=%q\nHTTP_PORT=%q\nSOCKS_PORT=%q\nAUTH=%q\nALLOW=%q\nSERVICE=%q\n' \
    "$O_USER" "$O_PASS" "$O_HTTP" "$O_SOCKS" "$O_AUTH" "$O_ALLOW" "$O_SERVICE" > "$CONF_ENV.tmp"
  chmod 0600 "$CONF_ENV.tmp"
  mv -f "$CONF_ENV.tmp" "$CONF_ENV"
}

# 把本脚本（常量 + 全部函数）存成 gost-proxy 命令，之后改设置不用再连 GitHub
install_manager() {
  {
    echo '#!/usr/bin/env bash'
    echo '# proxy-oneclick 管理命令（安装脚本生成）：gost-proxy --help'
    echo 'set -euo pipefail'
    declare -p GOST_VERSION GOST_SHA256 DEFAULT_MIRRORS BIN MANAGER CONF_DIR CONF_YML CONF_ENV \
      UNIT SVC_USER IPV4_RE CIDR4_RE CIDR6_RE
    declare -f
    echo 'main "$@"'
  } > "$MANAGER.tmp"
  chmod 0755 "$MANAGER.tmp"
  mv -f "$MANAGER.tmp" "$MANAGER"
}

# ---------- 服务 ----------

install_service() {
  cat > "$UNIT" <<EOF
[Unit]
Description=GOST proxy (proxy-oneclick)
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
ExecStart=$BIN -C $CONF_YML
Restart=always
RestartSec=3
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$UNIT"
  systemctl daemon-reload
  systemctl enable gost >/dev/null 2>&1 || die "systemctl enable gost 失败"
  systemctl restart gost || die "gost 启动失败，看日志：journalctl -u gost -n 50"
}

enabled_ports() {
  local ports=()
  if (( O_HTTP > 0 )); then ports+=("$O_HTTP"); fi
  if (( O_SOCKS > 0 )); then ports+=("$O_SOCKS"); fi
  printf '%s' "${ports[*]}"
}

open_firewall() {
  local p ports
  ports=$(enabled_ports)
  if command -v ufw >/dev/null 2>&1 && [[ $(ufw status 2>/dev/null || true) == *"Status: active"* ]]; then
    for p in $ports; do ufw allow "$p/tcp" >/dev/null || warn "ufw 放行 $p 失败"; done
    say "已在 ufw 放行 TCP $ports"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in $ports; do firewall-cmd --permanent --add-port="$p/tcp" >/dev/null || warn "firewalld 放行 $p 失败"; done
    firewall-cmd --reload >/dev/null || warn "firewalld 重载失败"
    say "已在 firewalld 放行 TCP $ports"
  fi
}

proxy_url() {  # proxy_url 协议 主机 端口
  if [[ $O_AUTH == 1 ]]; then
    printf '%s://%s:%s@%s:%s' "$1" "$O_USER" "$O_PASS" "$2" "$3"
  else
    printf '%s://%s:%s' "$1" "$2" "$3"
  fi
}

test_one() {  # test_one 代理地址 名称
  local i code=000
  for i in 1 2 3 4 5; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -x "$1" http://www.baidu.com || true)
    if [[ $code =~ ^[23] ]]; then say "自测通过：$2 代理能访问 www.baidu.com"; return 0; fi
    sleep 1
  done
  warn "自测没通过：$2 代理访问 www.baidu.com 失败（HTTP $code）。看日志：journalctl -u gost -n 50"
}

self_test() {
  if ! command -v curl >/dev/null 2>&1; then warn "没有 curl，跳过自测"; return 0; fi
  sleep 1
  if ! systemctl is-active --quiet gost; then
    warn "gost 没在运行（端口被占用？）。看日志：journalctl -u gost -n 50"
    return 0
  fi
  if (( O_HTTP > 0 )); then test_one "$(proxy_url http 127.0.0.1 "$O_HTTP")" HTTP; fi
  if (( O_SOCKS > 0 )); then test_one "$(proxy_url socks5h 127.0.0.1 "$O_SOCKS")" SOCKS5; fi
}

# ---------- 输出 ----------

public_ip() {
  local u ip
  if command -v curl >/dev/null 2>&1; then
    for u in https://4.ipw.cn https://ip.3322.net https://ifconfig.me/ip; do
      ip=$(curl -s --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)
      if [[ $ip =~ $IPV4_RE ]]; then printf '%s' "$ip"; return 0; fi
    done
  fi
  printf '服务器IP'
}

print_info() {
  local host test_url
  host=$(public_ip)
  echo
  say "代理信息（gost v${GOST_VERSION}）"
  if (( O_HTTP > 0 )); then echo "  HTTP   : $(proxy_url http "$host" "$O_HTTP")"; fi
  if (( O_SOCKS > 0 )); then echo "  SOCKS5 : $(proxy_url socks5 "$host" "$O_SOCKS")"; fi
  if [[ $O_AUTH == 1 ]]; then
    echo "  用户名 : $O_USER"
    echo "  密码   : $O_PASS"
  else
    echo "  认证   : 无"
  fi
  if [[ -n $O_ALLOW ]]; then echo "  白名单 : $O_ALLOW（另加本机）"; fi
  if (( O_HTTP > 0 )); then test_url=$(proxy_url http "$host" "$O_HTTP"); else test_url=$(proxy_url socks5h "$host" "$O_SOCKS"); fi
  echo "  测试   : curl -x $test_url -I https://www.baidu.com"
  echo
  echo "  记得在云厂商安全组放行 TCP $(enabled_ports)"
  echo "  再看一次 / 换密码 / 卸载：gost-proxy --show | --new-pass | --uninstall（gost-proxy --help）"
}

show_info() {
  [[ -f $CONF_ENV ]] || die "还没用本脚本装过代理"
  resolve_opts
  if [[ $O_SERVICE == 1 ]]; then
    say "服务状态：$(systemctl is-active gost 2>/dev/null || true)"
  fi
  print_info
}

uninstall() {
  [[ -f $CONF_ENV ]] || die "没找到 proxy-oneclick 的安装记录（$CONF_ENV），不动任何文件"
  if [[ -d /run/systemd/system ]]; then
    systemctl disable --now gost >/dev/null 2>&1 || true
    rm -f "$UNIT"
    systemctl daemon-reload || true
  fi
  rm -f "$BIN" "$MANAGER"
  rm -rf "$CONF_DIR"
  if id -u "$SVC_USER" >/dev/null 2>&1; then userdel "$SVC_USER" 2>/dev/null || true; fi
  say "已卸载。防火墙 / 安全组里放行的端口请自己关掉"
}

do_install() {
  resolve_opts
  validate_opts
  preflight
  install_gost
  if [[ $O_SERVICE == 1 ]]; then ensure_user; fi
  backup_foreign
  write_config
  write_state
  install_manager
  if [[ $O_SERVICE == 1 ]]; then
    install_service
    open_firewall
    self_test
  else
    say "没装成服务（--no-service），手动运行：$BIN -C $CONF_YML"
  fi
  print_info
}

main() {
  init_flags
  parse_args "$@"
  [[ $(id -u) == 0 ]] || die "请用 root 运行（先 sudo -i，或用 | sudo bash -s --）"
  umask 077
  TMP_DIR=''
  trap 'if [[ -n ${TMP_DIR:-} ]]; then rm -rf "$TMP_DIR"; fi' EXIT
  load_state
  case $ACTION in
    show)      show_info ;;
    uninstall) uninstall ;;
    *)         do_install ;;
  esac
}

main "$@"
