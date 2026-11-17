#!/usr/bin/env bash
# ============================================================
# XHTTP Manager V4.8.9 - single fixed instance directory and legacy marker repair
# Ubuntu / Debian (systemd), Alpine (OpenRC)
# Uses the unchanged V4.7 core.sh plus the V4.8 tunnel.sh module.
# ============================================================
set -Eeuo pipefail
umask 077
VERSION="4.8.9"
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_ID=""
XHTTP_DIR=""; CONFIG=""; STATE=""; LIB_DIR=""; XRAY_BIN=""; SERVICE_NAME=""; SERVICE_FILE=""; OPENRC_FILE=""; TUNNEL_SERVICE_NAME=""
CORE_FILE="$SELF_DIR/core.sh"; TUNNEL_FILE="$SELF_DIR/tunnel.sh"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PROTOCOL=""; DOMAIN=""; PORT=""; UUID=""; PATH_VALUE=""; PATH_STYLE=legacy; SECURITY=""; TUNNEL=no; TUNNEL_PROTOCOL=auto
XMUX_ENABLED=no; XMUX_MAX_CONCURRENCY="16-32"; XMUX_MAX_CONNECTIONS=0; XMUX_C_REUSE="64-128"; XMUX_H_REQUESTS="600-900"; XMUX_H_SECS="1800-3000"; LOCAL_SUB_URL=""; CF_PATH_MODE="specified"; LOCAL_SUB_PORT=""; LOCAL_SUB_UUID=""
CERT_FILE=""; KEY_FILE=""; REALITY_PRIVATE=""; REALITY_PUBLIC=""; REALITY_SHORT_ID=""; REALITY_SNI="www.microsoft.com"
log(){ printf '%b\n' "${CYAN}[XHTTP]${NC} $*"; }; ok(){ printf '%b\n' "${GREEN}[成功]${NC} $*"; }; warn(){ printf '%b\n' "${YELLOW}[提示]${NC} $*"; }; err(){ printf '%b\n' "${RED}[错误]${NC} $*" >&2; }; die(){ err "$*"; exit 1; }
require_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die '请使用 root 用户运行'; }
RAW_BASE_URL="${XHTTP_RAW_BASE_URL:-https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main}"
BOOTSTRAP_DIR=""
download_to(){
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fLsS --retry 3 --connect-timeout 15 "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$dest" "$url"
  else
    err '缺少 curl 或 wget，无法下载 core.sh / tunnel.sh'; return 1
  fi
  # GitHub files may have CRLF line endings; normalize modules just like the one-line launcher.
  local normalized="${dest}.lf"
  if ! tr -d '\r' < "$dest" > "$normalized" || ! mv -f "$normalized" "$dest"; then
    rm -f -- "$normalized"; return 1
  fi
}
cleanup_bootstrap(){ [[ -n "$BOOTSTRAP_DIR" && -d "$BOOTSTRAP_DIR" ]] && rm -rf -- "$BOOTSTRAP_DIR"; }
load_modules(){
  local c="$SELF_DIR/core.sh" t="$SELF_DIR/tunnel.sh"
  if [[ ! -f "$c" || ! -f "$t" ]] || ! grep -Fq 'XHTTP_MODULE_VERSION="4.7"' "$c" || ! grep -Fq 'XHTTP_MODULE_VERSION="4.8"' "$t"; then
    c="$LIB_DIR/core.sh"; t="$LIB_DIR/tunnel.sh"
  fi
  if [[ ! -f "$c" || ! -f "$t" ]] || ! grep -Fq 'XHTTP_MODULE_VERSION="4.7"' "$c" || ! grep -Fq 'XHTTP_MODULE_VERSION="4.8"' "$t"; then
    BOOTSTRAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xhttp-bootstrap.XXXXXX")" || die '无法创建临时目录'
    trap cleanup_bootstrap EXIT
    c="$BOOTSTRAP_DIR/core.sh"; t="$BOOTSTRAP_DIR/tunnel.sh"
    download_to "$RAW_BASE_URL/core.sh" "$c" || die '下载 core.sh 失败'
    download_to "$RAW_BASE_URL/tunnel.sh" "$t" || die '下载 tunnel.sh 失败'
  fi
  [[ -f "$c" && -f "$t" ]] || die '缺少 core.sh 或 tunnel.sh'
  grep -Fq 'XHTTP_MODULE_VERSION="4.7"' "$c" || die 'core.sh 版本不匹配（本版本保留 V4.7 核心模块）'
  grep -Fq 'XHTTP_MODULE_VERSION="4.8"' "$t" || die 'tunnel.sh 版本不匹配或不是 V4.8'
  CORE_FILE="$c"; TUNNEL_FILE="$t"
  # shellcheck source=/dev/null
  source "$CORE_FILE"
  # shellcheck source=/dev/null
  source "$TUNNEL_FILE"
  [[ "${CORE_MODULE_VERSION:-}" == "4.7" && "${TUNNEL_MODULE_VERSION:-}" == "4.8" ]] || die '模块版本不一致'
  trap cleanup_bootstrap EXIT
}
candidate_is_owned(){
  local id="$1" dir="/etc/$1" marker="/etc/$1/.xhttp-manager-instance"
  local xray="/usr/local/bin/xray-$1" unit="/etc/systemd/system/$1.service" init="/etc/init.d/$1"
  [[ "$id" == xhttp && -f "$marker" ]] || return 1
  grep -Fqx 'XHTTP Manager instance: xhttp' "$marker" || return 1
  [[ -s "$dir/config.json" && -s "$dir/state.json" && -x "$xray" ]] || return 1
  # A stale/incorrect version field (including an OS release string) is tolerated
  # only when the instance marker, private config/state and dedicated Xray agree.
  if [[ -f "$unit" ]]; then
    grep -Fqx "ExecStart=$xray run -config $dir/config.json" "$unit" || return 1
  elif [[ -f "$init" ]]; then
    grep -Fq "command=\"$xray\"" "$init" && grep -Fq "command_args=\"run -config $dir/config.json\"" "$init" || return 1
  fi
  return 0
}
select_instance(){
  INSTANCE_ID=xhttp
  XHTTP_DIR=/etc/xhttp; CONFIG="$XHTTP_DIR/config.json"; STATE="$XHTTP_DIR/state.json"
  LIB_DIR=/usr/local/lib/xhttp; XRAY_BIN=/usr/local/bin/xray-xhttp
  SERVICE_NAME=xhttp; SERVICE_FILE=/etc/systemd/system/xhttp.service; OPENRC_FILE=/etc/init.d/xhttp
  TUNNEL_SERVICE_NAME=xhttp-cloudflared

  # Never fall back to xhttp-2/xhttp-3. If the fixed namespace is occupied by
  # unrelated files/services, stop safely instead of creating another instance.
  local occupied=no
  [[ -e "$XHTTP_DIR" || -e "$LIB_DIR" || -e "$XRAY_BIN" || -e "$SERVICE_FILE" || -e "$OPENRC_FILE" \
     || -e /etc/systemd/system/xhttp-cloudflared.service || -e /etc/init.d/xhttp-cloudflared \
     || -e /usr/local/bin/cloudflared-xhttp ]] && occupied=yes
  if [[ "$occupied" == yes ]] && ! candidate_is_owned xhttp; then
    die '检测到 /etc/xhttp 已被占用，但无法确认完整归属；为避免覆盖其他项目，已停止。请先检查 xhttp.service、/etc/xhttp 和专用 Xray 文件。'
  fi

  # Repair the old marker bug: previous builds could write the OS release as
  # the manager version. The node is adopted only after candidate_is_owned.
  if [[ -f "$XHTTP_DIR/.xhttp-manager-instance" ]]; then
    local marker_tmp
    marker_tmp="$(mktemp "$XHTTP_DIR/.manager-marker.XXXXXX")" || die '无法修复实例标记'
    printf 'XHTTP Manager instance: xhttp\nXHTTP Manager version: %s\n' "$VERSION" > "$marker_tmp"
    chmod 0600 "$marker_tmp"
    mv -f "$marker_tmp" "$XHTTP_DIR/.xhttp-manager-instance" || die '写入实例标记失败'
  fi
  export INSTANCE_ID XHTTP_DIR LIB_DIR XRAY_BIN SERVICE_NAME SERVICE_FILE OPENRC_FILE TUNNEL_SERVICE_NAME
  log "固定单实例目录：$XHTTP_DIR（不再创建 xhttp-2、xhttp-3 等目录）"
}
require_commands(){ local c; for c in curl jq openssl awk grep sed head shuf ss install mktemp; do command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c"; done; }
port_in_use(){
  local port="$1"
  ss -H -lntu 2>/dev/null | awk -v p="$port" '{addr=$5; sub(/^.*:/,"",addr); if (addr==p) found=1} END {exit !found}'
}
random_port(){
  local p n=0
  while ((n < 500)); do
    n=$((n+1)); p="$(shuf -i 20000-59999 -n 1)"
    if ! port_in_use "$p"; then printf '%s' "$p"; return 0; fi
  done
  die '当前 VPS 可用监听端口不足，无法随机分配 20000-59999 范围内的端口'
}
valid_port(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
choose_local_port(){
  local requested
  while true; do
    read -rp '本地监听端口（直接回车随机选择，或输入 1-65535）: ' requested
    if [[ -z "$requested" ]]; then
      PORT="$(random_port)"
      printf '已随机选择本地监听端口：%s\n' "$PORT"
      return 0
    fi
    if ! valid_port "$requested"; then
      warn '端口不合法，请输入 1-65535 的整数'
      continue
    fi
    if port_in_use "$requested"; then
      warn "端口 $requested 已被 TCP 或 UDP 监听占用，请换一个端口"
      continue
    fi
    PORT="$((10#$requested))"
    printf '已选择自定义本地监听端口：%s\n' "$PORT"
    return 0
  done
}
random_path(){ printf '/%s' "$(openssl rand -hex 8)"; }
valid_base_path(){ [[ "$1" =~ ^/[A-Za-z0-9._~/-]+$ && "$1" != *"//"* ]]; }
default_base_path(){
  case "$PROTOCOL" in
    xhttp-*) printf '/xhttp';;
    ws-*) printf '/vless-ws';;
    httpupgrade-tls) printf '/httpupgrade';;
    grpc-tls) printf 'grpc';;
    *) printf '/xhttp';;
  esac
}
choose_path(){
  local choice custom default
  default="$(default_base_path)"
  if [[ "$PROTOCOL" == grpc-tls ]]; then PATH_VALUE=grpc; return 0; fi
  echo; echo '========== 节点路径设置 =========='
  echo "1. 使用默认基础路径（$default）"
  echo '2. 自定义基础路径'
  echo '3. 随机生成基础路径'
  read -rp '请选择 [1]: ' choice
  case "${choice:-1}" in
    1) PATH_VALUE="$default";;
    2)
      while true; do
        read -rp '输入基础路径（必须以 / 开头，不要添加 UUID）: ' custom
        if valid_base_path "$custom"; then PATH_VALUE="$custom"; break; fi
        warn '路径格式不正确；不能包含空格、?、# 或双斜线'
      done;;
    3) PATH_VALUE="$(random_path)";;
    *) warn '无效选择，使用默认基础路径'; PATH_VALUE="$default";;
  esac
}
client_path(){
  if [[ "${PATH_STYLE:-legacy}" != uuid-suffix ]]; then printf '%s' "$PATH_VALUE"; return 0; fi
  case "$PROTOCOL" in
    xhttp-*) printf '%s%s' "$PATH_VALUE" "$UUID";;
    ws-*) printf '%s%s' "$PATH_VALUE" "$UUID";;
    *) printf '%s' "$PATH_VALUE";;
  esac
}
xmux_settings_menu(){
  local choice
  while true; do
    echo; echo '========== XMUX 设置 =========='
    echo "当前状态：$([[ "$XMUX_ENABLED" == yes ]] && echo 开启 || echo 关闭)"
    echo '1. 开启 XMUX（推荐参数）'
    echo '2. 关闭 XMUX'
    echo '3. 查看当前参数'
    echo '0. 返回'
    read -rp '请选择: ' choice
    case "$choice" in
      1) XMUX_ENABLED=yes; XMUX_MAX_CONCURRENCY='16-32'; XMUX_MAX_CONNECTIONS=0; XMUX_C_REUSE='64-128'; XMUX_H_REQUESTS='600-900'; XMUX_H_SECS='1800-3000'; ok 'XMUX 已开启并载入推荐参数';;
      2) XMUX_ENABLED=no; ok 'XMUX 已关闭';;
      3) echo "maxConcurrency=$XMUX_MAX_CONCURRENCY"; echo "maxConnections=$XMUX_MAX_CONNECTIONS"; echo "cMaxReuseTimes=$XMUX_C_REUSE"; echo "hMaxRequestTimes=$XMUX_H_REQUESTS"; echo "hMaxReusableSecs=$XMUX_H_SECS";;
      0) return;; *) warn '无效选择';;
    esac
  done
}
choose_tunnel_transport(){
  local choice
  while true; do
    echo; echo '====== XHTTP 固定隧道优化设置 ======'
    echo '1. XMUX 设置（开启 / 关闭）'
    echo '2. auto'
    echo '3. http2（长期稳定优先）'
    echo '4. quic'
    read -rp '请选择 [3]: ' choice
    case "${choice:-3}" in
      1) xmux_settings_menu;;
      2) TUNNEL_PROTOCOL=auto; return 0;;
      3) TUNNEL_PROTOCOL=http2; return 0;;
      4) TUNNEL_PROTOCOL=quic; return 0;;
      *) warn '无效选择';;
    esac
  done
}
random_uuid(){ if [[ -x "$XRAY_BIN" ]]; then "$XRAY_BIN" uuid; else cat /proc/sys/kernel/random/uuid; fi; }
valid_domain(){ [[ ${#1} -le 253 && "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }
valid_ipv4(){ local ip="$1" a b c d part; [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1; IFS=. read -r a b c d <<< "$ip"; for part in "$a" "$b" "$c" "$d"; do [[ "$part" =~ ^[0-9]{1,3}$ ]] && ((10#$part <= 255)) || return 1; done; }
save_state(){
  install -d -m 0700 "$XHTTP_DIR"; local tmp; tmp="$(mktemp "$XHTTP_DIR/state.XXXXXX")" || return 1
  if ! jq -n --arg PROTOCOL "$PROTOCOL" --arg DOMAIN "$DOMAIN" --arg PORT "$PORT" --arg UUID "$UUID" --arg PATH_VALUE "$PATH_VALUE" --arg PATH_STYLE "$PATH_STYLE" --arg SECURITY "$SECURITY" --arg TUNNEL "$TUNNEL" --arg CERT_FILE "$CERT_FILE" --arg KEY_FILE "$KEY_FILE" --arg REALITY_PRIVATE "$REALITY_PRIVATE" --arg REALITY_PUBLIC "$REALITY_PUBLIC" --arg REALITY_SHORT_ID "$REALITY_SHORT_ID" --arg REALITY_SNI "$REALITY_SNI" --arg TUNNEL_PROTOCOL "${TUNNEL_PROTOCOL:-auto}" --arg LOCAL_SUB_URL "${LOCAL_SUB_URL:-}" --arg CF_PATH_MODE "${CF_PATH_MODE:-specified}" --arg LOCAL_SUB_PORT "${LOCAL_SUB_PORT:-}" --arg LOCAL_SUB_UUID "${LOCAL_SUB_UUID:-}" --arg XMUX_ENABLED "${XMUX_ENABLED:-no}" --arg XMUX_MAX_CONCURRENCY "$XMUX_MAX_CONCURRENCY" --arg XMUX_MAX_CONNECTIONS "$XMUX_MAX_CONNECTIONS" --arg XMUX_C_REUSE "$XMUX_C_REUSE" --arg XMUX_H_REQUESTS "$XMUX_H_REQUESTS" --arg XMUX_H_SECS "$XMUX_H_SECS" '{PROTOCOL:$PROTOCOL,DOMAIN:$DOMAIN,PORT:$PORT,UUID:$UUID,PATH_VALUE:$PATH_VALUE,PATH_STYLE:$PATH_STYLE,SECURITY:$SECURITY,TUNNEL:$TUNNEL,CERT_FILE:$CERT_FILE,KEY_FILE:$KEY_FILE,REALITY_PRIVATE:$REALITY_PRIVATE,REALITY_PUBLIC:$REALITY_PUBLIC,REALITY_SHORT_ID:$REALITY_SHORT_ID,REALITY_SNI:$REALITY_SNI,TUNNEL_PROTOCOL:$TUNNEL_PROTOCOL,LOCAL_SUB_URL:$LOCAL_SUB_URL,CF_PATH_MODE:$CF_PATH_MODE,LOCAL_SUB_PORT:$LOCAL_SUB_PORT,LOCAL_SUB_UUID:$LOCAL_SUB_UUID,XMUX_ENABLED:$XMUX_ENABLED,XMUX_MAX_CONCURRENCY:$XMUX_MAX_CONCURRENCY,XMUX_MAX_CONNECTIONS:$XMUX_MAX_CONNECTIONS,XMUX_C_REUSE:$XMUX_C_REUSE,XMUX_H_REQUESTS:$XMUX_H_REQUESTS,XMUX_H_SECS:$XMUX_H_SECS}' > "$tmp"; then rm -f "$tmp"; return 1; fi
  chmod 0600 "$tmp"; mv -f "$tmp" "$STATE"
}
load_state(){
  [[ -s "$STATE" ]] && jq -e 'type=="object"' "$STATE" >/dev/null 2>&1 || { warn '尚无有效节点状态'; return 1; }
  PROTOCOL="$(jq -r '.PROTOCOL // ""' "$STATE")"; DOMAIN="$(jq -r '.DOMAIN // ""' "$STATE")"; PORT="$(jq -r '.PORT // ""' "$STATE")"; UUID="$(jq -r '.UUID // ""' "$STATE")"; PATH_VALUE="$(jq -r '.PATH_VALUE // ""' "$STATE")"; PATH_STYLE="$(jq -r '.PATH_STYLE // "legacy"' "$STATE")"; SECURITY="$(jq -r '.SECURITY // ""' "$STATE")"; TUNNEL="$(jq -r '.TUNNEL // "no"' "$STATE")"; CERT_FILE="$(jq -r '.CERT_FILE // ""' "$STATE")"; KEY_FILE="$(jq -r '.KEY_FILE // ""' "$STATE")"; REALITY_PRIVATE="$(jq -r '.REALITY_PRIVATE // ""' "$STATE")"; REALITY_PUBLIC="$(jq -r '.REALITY_PUBLIC // ""' "$STATE")"; REALITY_SHORT_ID="$(jq -r '.REALITY_SHORT_ID // ""' "$STATE")"; REALITY_SNI="$(jq -r '.REALITY_SNI // "www.microsoft.com"' "$STATE")"; TUNNEL_PROTOCOL="$(jq -r '.TUNNEL_PROTOCOL // "auto"' "$STATE")"; LOCAL_SUB_URL="$(jq -r '.LOCAL_SUB_URL // ""' "$STATE")"; CF_PATH_MODE="$(jq -r '.CF_PATH_MODE // "specified"' "$STATE")"; LOCAL_SUB_PORT="$(jq -r '.LOCAL_SUB_PORT // ""' "$STATE")"; LOCAL_SUB_UUID="$(jq -r '.LOCAL_SUB_UUID // ""' "$STATE")"; XMUX_ENABLED="$(jq -r '.XMUX_ENABLED // "no"' "$STATE")"; XMUX_MAX_CONCURRENCY="$(jq -r '.XMUX_MAX_CONCURRENCY // "16-32"' "$STATE")"; XMUX_MAX_CONNECTIONS="$(jq -r '.XMUX_MAX_CONNECTIONS // 0' "$STATE")"; XMUX_C_REUSE="$(jq -r '.XMUX_C_REUSE // "64-128"' "$STATE")"; XMUX_H_REQUESTS="$(jq -r '.XMUX_H_REQUESTS // "600-900"' "$STATE")"; XMUX_H_SECS="$(jq -r '.XMUX_H_SECS // "1800-3000"' "$STATE")"
  [[ -n "$PROTOCOL" && -n "$DOMAIN" && -n "$PORT" && -n "$UUID" ]]
}
get_public_ip(){ curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || true; }
ask_domain(){ local detected; detected="$(get_public_ip)"; echo; echo '请输入连接域名或服务器公网 IPv4。'; [[ -n "$detected" ]] && echo "检测到公网 IPv4：$detected"; read -rp '域名/IP（留空使用检测到的 IP）: ' DOMAIN; DOMAIN="${DOMAIN:-$detected}"; [[ -n "$DOMAIN" ]] || die '请手动输入域名或公网 IP'; valid_domain "$DOMAIN" || valid_ipv4 "$DOMAIN" || die '域名或 IPv4 格式不正确'; }
ask_tls_files(){ read -rp 'TLS 证书完整路径: ' CERT_FILE; read -rp 'TLS 私钥完整路径: ' KEY_FILE; [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || die '证书或私钥文件不存在'; openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1 || die 'TLS 证书格式不正确'; openssl pkey -in "$KEY_FILE" -noout >/dev/null 2>&1 || die 'TLS 私钥格式不正确'; }
choose_protocol(){
  echo; echo '========== 选择协议 =========='
  echo '1. VLESS + XHTTP + REALITY'; echo '2. VLESS + XHTTP + TLS'; echo '3. VLESS + XHTTP + Cloudflare Tunnel'; echo '4. VLESS + WS + TLS'; echo '5. VLESS + WS + Cloudflare Tunnel'; echo '6. VLESS + gRPC + TLS'; echo '7. VLESS + HTTPUpgrade + TLS'; echo '0. 返回'
  local choice; read -rp '请选择: ' choice
  case "$choice" in
    1) PROTOCOL=xhttp-reality; SECURITY=reality; TUNNEL=no;; 2) PROTOCOL=xhttp-tls; SECURITY=tls; TUNNEL=no;; 3) PROTOCOL=xhttp-tunnel; SECURITY=none; TUNNEL=yes;; 4) PROTOCOL=ws-tls; SECURITY=tls; TUNNEL=no;; 5) PROTOCOL=ws-tunnel; SECURITY=none; TUNNEL=yes;; 6) PROTOCOL=grpc-tls; SECURITY=tls; TUNNEL=no;; 7) PROTOCOL=httpupgrade-tls; SECURITY=tls; TUNNEL=no;; 0) return 1;; *) warn '无效选择'; return 1;;
  esac
}
make_reality_keys(){
  local output; [[ -x "$XRAY_BIN" ]] || die '专用 Xray 尚未安装，无法生成 REALITY 密钥'
  output="$("$XRAY_BIN" x25519 2>&1)" || { printf '%s\n' "$output"; die '生成 REALITY 密钥失败'; }
  # Xray 26.x prints the public key as "Password (PublicKey):".
  # Match the complete label instead of expecting a colon immediately after Password.
  REALITY_PRIVATE="$(printf '%s\n' "$output" | sed -nE 's/^[[:space:]]*PrivateKey[[:space:]]*:[[:space:]]*([^[:space:]]+).*$/\1/p' | head -n1)"
  REALITY_PUBLIC="$(printf '%s\n' "$output" | sed -nE 's/^[[:space:]]*(Password[[:space:]]*\(PublicKey\)|PublicKey|Public key)[[:space:]]*:[[:space:]]*([^[:space:]]+).*$/\2/p' | head -n1)"
  [[ -n "$REALITY_PRIVATE" && -n "$REALITY_PUBLIC" ]] || { printf '%s\n' "$output"; die '无法解析 Xray REALITY 密钥输出'; }
  REALITY_SHORT_ID="$(openssl rand -hex 4)"; REALITY_SNI=www.microsoft.com
}

build_config(){
  local inbound stream tls_settings='{}' listen_addr=0.0.0.0
  local tmpdir tmp
  [[ "$TUNNEL" == yes ]] && listen_addr=127.0.0.1
  case "$PROTOCOL" in
    xhttp-reality)
      make_reality_keys
      stream="$(jq -n --arg server "$DOMAIN" --arg path "$(client_path)" --arg private "$REALITY_PRIVATE" --arg sni "$REALITY_SNI" --arg sid "$REALITY_SHORT_ID" '{network:"xhttp",security:"reality",xhttpSettings:{host:$server,path:$path,mode:"auto"},realitySettings:{show:false,dest:($sni+":443"),xver:0,serverNames:[$sni],privateKey:$private,shortIds:[$sid]}}')"
      ;;
    xhttp-tls|xhttp-tunnel)
      if [[ "$PROTOCOL" == xhttp-tunnel ]]; then
        stream="$(jq -n --arg server "$DOMAIN" --arg security "$SECURITY" --arg path "$(client_path)" '{network:"xhttp",security:$security,xhttpSettings:{host:$server,path:$path,mode:"packet-up",extra:{scMaxEachPostBytes:1000000,scMinPostsIntervalMs:30}}}')"
      else
        stream="$(jq -n --arg server "$DOMAIN" --arg security "$SECURITY" --arg path "$(client_path)" '{network:"xhttp",security:$security,xhttpSettings:{host:$server,path:$path,mode:"auto"}}')"
      fi
      ;;
    ws-tls|ws-tunnel)
      stream="$(jq -n --arg security "$SECURITY" --arg path "$(client_path)" '{network:"ws",security:$security,wsSettings:{path:$path}}')"
      ;;
    grpc-tls)
      stream='{"network":"grpc","security":"tls","grpcSettings":{"serviceName":"grpc"}}'
      ;;
    httpupgrade-tls)
      stream="$(jq -n --arg security "$SECURITY" --arg path "$PATH_VALUE" '{network:"httpupgrade",security:$security,httpupgradeSettings:{path:$path}}')"
      ;;
    *) die "未知协议：$PROTOCOL" ;;
  esac
  if [[ "$SECURITY" == tls && "$TUNNEL" == no ]]; then
    tls_settings="$(jq -n --arg cert "$CERT_FILE" --arg key "$KEY_FILE" --arg protocol "$PROTOCOL" '{alpn:(if $protocol=="xhttp-tls" then ["h2","http/1.1","h3"] else ["h2","http/1.1"] end),certificates:[{certificateFile:$cert,keyFile:$key}]}')"
  fi
  inbound="$(jq -n --arg listen "$listen_addr" --argjson port "$PORT" --arg uuid "$UUID" --argjson stream "$stream" --argjson tls "$tls_settings" '{listen:$listen,port:$port,protocol:"vless",settings:{clients:[{id:$uuid}],decryption:"none"},streamSettings:($stream+(if $stream.security=="tls" then {tlsSettings:$tls} else {} end)),sniffing:{enabled:true,destOverride:["http","tls"]}}')"
  install -d -m 0700 "$XHTTP_DIR"
  tmpdir="$(mktemp -d "$XHTTP_DIR/.config.XXXXXX")" || return 1
  tmp="$tmpdir/config.json"

  if ! jq -n --argjson inbound "$inbound" '{log:{loglevel:"warning"},inbounds:[$inbound],outbounds:[{protocol:"freedom",tag:"direct"}]}' > "$tmp"; then
    rm -rf -- "$tmpdir"
    return 1
  fi

  chmod 0600 "$tmp"

  if [[ -x "$XRAY_BIN" ]] && ! "$XRAY_BIN" run -test -config "$tmp"; then
    rm -rf -- "$tmpdir"
    die '新配置校验失败，原配置保持不变'
  fi
  if ! mv -f "$tmp" "$CONFIG"; then
    rm -rf -- "$tmpdir"
    die '配置文件替换失败'
  fi

  rmdir "$tmpdir"
}

install_node(){
  local tunnel_token=''
  choose_protocol || return 0
  choose_local_port; ask_domain
  if [[ "$TUNNEL" == yes ]] && ! valid_domain "$DOMAIN"; then die 'Cloudflare Tunnel 必须使用域名，不能使用公网 IPv4'; fi
  UUID="$(random_uuid)"; PATH_STYLE=uuid-suffix; choose_path
  CF_PATH_MODE=specified
  if [[ "$TUNNEL" == yes ]]; then
    echo; echo '========== Cloudflare Path 模式 =========='
    echo '1. 指定 Path 模式（按路径分流）'
    echo '2. 无 Path 模式（兼容旧版，Cloudflare Path 留空）'
    read -rp '请选择 [1]: ' cf_mode_choice
    case "${cf_mode_choice:-1}" in 1) CF_PATH_MODE=specified;; 2) CF_PATH_MODE=none;; *) warn '无效选择，使用指定 Path 模式'; CF_PATH_MODE=specified;; esac
  fi
  CERT_FILE=''; KEY_FILE=''; REALITY_PRIVATE=''; REALITY_PUBLIC=''; REALITY_SHORT_ID=''
  [[ "$PROTOCOL" == grpc-tls ]] && PATH_VALUE=grpc
  if [[ "$SECURITY" == tls && "$TUNNEL" == no ]]; then ask_tls_files; fi
  if [[ "$TUNNEL" == yes ]]; then
    read -rsp 'Cloudflare Tunnel Token: ' tunnel_token; echo
    [[ -n "$tunnel_token" ]] || die 'Tunnel Token 不能为空'
    if [[ "$PROTOCOL" == xhttp-tunnel ]]; then
      XMUX_ENABLED=no
      choose_tunnel_transport
    else
      echo 'Cloudflared 到 Cloudflare 边缘的传输：1.auto 2.http2 3.quic'
      local tunnel_choice
      read -rp '选择 [2]: ' tunnel_choice
      case "${tunnel_choice:-2}" in 1) TUNNEL_PROTOCOL=auto;; 2) TUNNEL_PROTOCOL=http2;; 3) TUNNEL_PROTOCOL=quic;; *) die '无效的 Cloudflared 传输选项';; esac
    fi
  fi
  # Do not create an empty marker merely by opening the manager; prepare the
  # selected instance only after the user has completed the deployment prompts.
  install_modules
  install_persistent_entrypoint
  core_install latest
  if port_in_use "$PORT"; then die "本地端口 $PORT 在安装期间被其他进程占用，请重新安装并选择其他端口"; fi
  build_config
  core_validate
  core_service_install
  if [[ "$TUNNEL" == yes ]]; then tunnel_install "$tunnel_token" "$TUNNEL_PROTOCOL"; tunnel_configure_http "$DOMAIN" "$PORT" "$(client_path)" "${CF_PATH_MODE:-specified}"; fi
  save_state; print_link; ok '安装流程完成'
}


# Cloudflare public HTTPS endpoint is fixed to 443.
CF_PUBLIC_PORT=443
CF_LINKS=()
urlencode(){ jq -rn --arg v "$1" '$v|@uri'; }
# Xray/V2RayN-compatible XHTTP extra payload. XMUX is intentionally opt-in.
xhttp_extra_json(){
  [[ "${XMUX_ENABLED:-no}" == yes ]] || return 1
  jq -cn --arg mc "$XMUX_MAX_CONCURRENCY" --arg mr "$XMUX_C_REUSE" --arg hr "$XMUX_H_REQUESTS" --arg hs "$XMUX_H_SECS" \
    '{scMaxEachPostBytes:1000000,scMinPostsIntervalMs:30,xmux:{maxConcurrency:$mc,maxConnections:0,cMaxReuseTimes:$mr,hMaxRequestTimes:$hr,hMaxReusableSecs:$hs,hKeepAlivePeriod:0}}'
}
clash_xmux_options(){
  [[ "${XMUX_ENABLED:-no}" == yes ]] || return 0
  cat <<YAML
      sc-max-each-post-bytes: 1000000
      sc-min-posts-interval-ms: 30
      reuse-settings:
        max-concurrency: "$XMUX_MAX_CONCURRENCY"
        c-max-reuse-times: "$XMUX_C_REUSE"
        h-max-request-times: "$XMUX_H_REQUESTS"
        h-max-reusable-secs: "$XMUX_H_SECS"
        h-keep-alive-period: 0
YAML
}
cloudflare_path_rule(){ printf '^%s(/.*)?$' "$1"; }
print_tunnel_links(){
  local subdir="$XHTTP_DIR/subscriptions" port mode alpn link name encoded_path
  local xray_out='[]' sing_out='[]' clash_proxies=''
  local qpath client_path_value extra_json extra_query=''
  client_path_value="$(client_path)"
  qpath="$(urlencode "$client_path_value")"
  if [[ "$PROTOCOL" == xhttp-tunnel && "$XMUX_ENABLED" == yes ]]; then
    extra_json="$(xhttp_extra_json)"
    extra_query="&extra=$(urlencode "$extra_json")"
  fi
  CF_LINKS=()
  for mode in h2 h3; do
      port="$CF_PUBLIC_PORT"
      if [[ "$mode" == h2 ]]; then
        alpn='h2,http/1.1'
        name="H2-443"
      else
        alpn='h3'
        name="H3-443"
      fi
      link="vless://${UUID}@${DOMAIN}:${port}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&alpn=$(urlencode "$alpn")&type=xhttp&host=${DOMAIN}&path=${qpath}&mode=packet-up${extra_query}#${name}"
      CF_LINKS+=("$link")
      local alpn_json
      if [[ "$mode" == h2 ]]; then alpn_json='["h2","http/1.1"]'; else alpn_json='["h3"]'; fi
      xray_out="$(jq --arg tag "$name" --arg server "$DOMAIN" --arg uuid "$UUID" --arg path "$client_path_value" --argjson port "$port" --argjson alpn "$alpn_json" --arg xmux_enabled "$XMUX_ENABLED" --arg max_concurrency "$XMUX_MAX_CONCURRENCY" --arg max_connections "$XMUX_MAX_CONNECTIONS" --arg c_reuse "$XMUX_C_REUSE" --arg h_requests "$XMUX_H_REQUESTS" --arg h_secs "$XMUX_H_SECS" \
        '. + [{tag:$tag,protocol:"vless",settings:{vnext:[{address:$server,port:$port,users:[{id:$uuid,encryption:"none"}]}]},streamSettings:{network:"xhttp",security:"tls",tlsSettings:{serverName:$server,alpn:$alpn,fingerprint:"chrome"},xhttpSettings:{host:$server,path:$path,mode:"packet-up",extra:(if $xmux_enabled=="yes" then {scMaxEachPostBytes:1000000,scMinPostsIntervalMs:30,xmux:{maxConcurrency:$max_concurrency,maxConnections:($max_connections|tonumber),cMaxReuseTimes:$c_reuse,hMaxRequestTimes:$h_requests,hMaxReusableSecs:$h_secs,hKeepAlivePeriod:0}} else {scMaxEachPostBytes:1000000,scMinPostsIntervalMs:30} end)}}}]' <<<"$xray_out")"
      sing_out="$(jq --arg tag "$name" --arg server "$DOMAIN" --arg uuid "$UUID" --arg path "$client_path_value" --argjson port "$port" --argjson alpn "$alpn_json" \
        '. + [{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,packet_encoding:"xudp",tls:{enabled:true,server_name:$server,alpn:$alpn,utls:{enabled:true,fingerprint:"chrome"}},transport:{type:"xhttp",host:$server,path:$path,mode:"packet-up"}}]' <<<"$sing_out")"
      clash_proxies+=$'\n'"  - name: ${name}"$'\n'"    type: vless"$'\n'"    server: ${DOMAIN}"$'\n'"    port: ${port}"$'\n'"    uuid: ${UUID}"$'\n'"    encryption: \"\""$'\n'"    udp: true"$'\n'"    network: xhttp"$'\n'"    tls: true"$'\n'"    servername: ${DOMAIN}"$'\n'"    alpn:"$'\n'"      - ${alpn%%,*}"$'\n'"    client-fingerprint: chrome"$'\n'"    xhttp-opts:"$'\n'"      host: ${DOMAIN}"$'\n'"      path: ${client_path_value}"$'\n'"      mode: packet-up"$'\n'
    clash_proxies+="$(clash_xmux_options)"
  done

  install -d -m 0700 "$subdir"
  printf '%s\n' "${CF_LINKS[@]}" > "$subdir/links.txt"
  printf '%s\n' "${CF_LINKS[@]}" | base64 | tr -d '\n' > "$subdir/xray-subscription.b64"
  printf '\n' >> "$subdir/xray-subscription.b64"
  jq -n --argjson outbounds "$xray_out" '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:10808,protocol:"socks",settings:{auth:"noauth",udp:true}},{listen:"127.0.0.1",port:10809,protocol:"http",settings:{}}],outbounds:($outbounds + [{protocol:"freedom",tag:"direct"}]),routing:{domainStrategy:"AsIs"}}' > "$subdir/xray.json" 
  jq -n --argjson outbounds "$sing_out" '{log:{level:"warn"},inbounds:[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:2080}],outbounds:($outbounds + [{type:"direct",tag:"direct"},{type:"selector",tag:"select",outbounds:[$outbounds[].tag],default:$outbounds[0].tag}]),route:{final:"select"}}' > "$subdir/sing-box.json" 
  {
    printf 'mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: warning\nproxies:\n'
    printf '%s' "$clash_proxies"
    printf 'proxy-groups:\n  - name: XHTTP-Argo\n    type: select\n    proxies:\n'
    printf '      - H2-443\n      - H3-443\n'
    printf 'rules:\n  - MATCH,XHTTP-Argo\n'
  } > "$subdir/clash-meta.yaml"
  chmod 0600 "$subdir"/*
  echo
  echo '========== 固定 Argo CF 节点 =========='
    echo "绑定域名：${DOMAIN}"
  echo "节点数量：${#CF_LINKS[@]}（H2、H3）"
  if [[ "$TUNNEL" == yes ]]; then echo "本地监听：127.0.0.1:${PORT}"; else echo "本地监听：0.0.0.0:${PORT}"; fi
  echo "Tunnel Service URL：http://localhost:${PORT}"
  echo "服务端基础路径：${PATH_VALUE}"
  echo "客户端实际路径：${client_path_value}"
  if [[ "${CF_PATH_MODE:-specified}" == none ]]; then echo 'Cloudflare Path 模式：无 Path（Cloudflare 控制台 Path 留空）'; else echo "Cloudflare Path 匹配规则：$(cloudflare_path_rule "$client_path_value")"; fi
  echo "XMUX：$([[ "$XMUX_ENABLED" == yes ]] && echo 开启 || echo 关闭)"
  echo "XHTTP Mode：packet-up"
  echo "提示：H3 需要 Cloudflare 控制台启用 HTTP/3。"
  echo
  printf '%s\n' "${CF_LINKS[@]}"
  echo
  echo '========== 总订阅 / 本地配置 =========='
  echo '已生成本实例订阅文件：Xray Base64、Xray JSON、sing-box JSON、Clash Meta/Mihomo YAML'
  echo '说明：sing-box XHTTP 需使用支持 XHTTP 的扩展版本；官方主线兼容性以客户端版本为准。'
  [[ -n "${LOCAL_SUB_URL:-}" ]] && echo "本地 IP 订阅：${LOCAL_SUB_URL}"
  echo '======================================'
}

print_ws_tunnel_links(){
  local subdir="$XHTTP_DIR/subscriptions" cp link yaml
  cp="$(client_path)"
  link="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&alpn=h2%2Chttp%2F1.1&type=ws&host=${DOMAIN}&path=$(urlencode "$cp")#WS-Tunnel-H2"
  install -d -m 0700 "$subdir"
  printf '%s\n' "$link" > "$subdir/links.txt"
  printf '%s\n' "$link" | base64 | tr -d '\n' > "$subdir/xray-subscription.b64"
  printf '\n' >> "$subdir/xray-subscription.b64"
  jq -n --arg tag 'WS-Tunnel-H2' --arg server "$DOMAIN" --arg uuid "$UUID" --arg path "$cp" '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:10808,protocol:"socks",settings:{auth:"noauth",udp:true}},{listen:"127.0.0.1",port:10809,protocol:"http",settings:{}}],outbounds:[{tag:$tag,protocol:"vless",settings:{vnext:[{address:$server,port:443,users:[{id:$uuid,encryption:"none"}]}]},streamSettings:{network:"ws",security:"tls",tlsSettings:{serverName:$server,alpn:["h2","http/1.1"],fingerprint:"chrome"},wsSettings:{path:$path,headers:{Host:$server}}}},{protocol:"freedom",tag:"direct"}],routing:{domainStrategy:"AsIs"}}' > "$subdir/xray.json"
  jq -n --arg tag 'WS-Tunnel-H2' --arg server "$DOMAIN" --arg uuid "$UUID" --arg path "$cp" '{log:{level:"warn"},inbounds:[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:2080}],outbounds:[{type:"vless",tag:$tag,server:$server,server_port:443,uuid:$uuid,tls:{enabled:true,server_name:$server,alpn:["h2","http/1.1"],utls:{enabled:true,fingerprint:"chrome"}},transport:{type:"ws",path:$path,headers:{Host:$server}}},{type:"direct",tag:"direct"},{type:"selector",tag:"select",outbounds:[$tag,"direct"],default:$tag}],route:{final:"select"}}' > "$subdir/sing-box.json"
  {
    printf 'mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: warning\nproxies:\n  - name: WS-Tunnel-H2\n    type: vless\n    server: %s\n    port: 443\n    uuid: %s\n    encryption: ""\n    tls: true\n    servername: %s\n    alpn:\n      - h2\n    client-fingerprint: chrome\n    network: ws\n    ws-opts:\n      path: %s\n      headers:\n        Host: %s\n' "$DOMAIN" "$UUID" "$DOMAIN" "$cp" "$DOMAIN"
    printf 'proxy-groups:\n  - name: WS-Tunnel\n    type: select\n    proxies:\n      - WS-Tunnel-H2\nrules:\n  - MATCH,WS-Tunnel\n'
  } > "$subdir/clash-meta.yaml"
  chmod 0600 "$subdir"/*
  echo; echo '========== VLESS + WS + Cloudflare Tunnel =========='
  echo "绑定域名：${DOMAIN}"
  echo "本地监听：127.0.0.1:${PORT}"
  echo "Tunnel Service URL：http://localhost:${PORT}"
  echo "服务端基础路径：${PATH_VALUE}"
  echo "客户端实际路径：${cp}"
  echo '已生成单个 WS-H2 节点及 Xray、sing-box、Clash Meta/Mihomo、Base64 订阅'
  printf '%s\n' "$link"
  [[ -n "${LOCAL_SUB_URL:-}" ]] && echo "本地 IP 订阅：${LOCAL_SUB_URL}"
  return 0
}

print_direct_xhttp_links(){
  local h2 h3 subdir="$XHTTP_DIR/subscriptions" xray_out='[]' sing_out='[]' clash_proxies='' mode name alpn port="$PORT" client_path_value
  client_path_value="$(client_path)"
  h2="vless://${UUID}@${DOMAIN}:${PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&alpn=h2%2Chttp%2F1.1&type=xhttp&host=${DOMAIN}&path=$(urlencode "$client_path_value")&mode=auto#XHTTP-TLS-H2"
  h3="vless://${UUID}@${DOMAIN}:${PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&alpn=h3&type=xhttp&host=${DOMAIN}&path=$(urlencode "$client_path_value")&mode=auto#XHTTP-TLS-H3-UDP"
  install -d -m 0700 "$subdir"
  printf '%s\n%s\n' "$h2" "$h3" > "$subdir/links.txt"
  printf '%s\n%s\n' "$h2" "$h3" | base64 | tr -d '\n' > "$subdir/xray-subscription.b64"
  printf '\n' >> "$subdir/xray-subscription.b64"
  for mode in h2 h3; do
    if [[ "$mode" == h2 ]]; then alpn='["h2","http/1.1"]'; name=XHTTP-TLS-H2; else alpn='["h3"]'; name=XHTTP-TLS-H3-UDP; fi
    xray_out="$(jq --arg tag "$name" --arg server "$DOMAIN" --arg uuid "$UUID" --arg path "$client_path_value" --argjson port "$port" --argjson alpn "$alpn" \
      '. + [{tag:$tag,protocol:"vless",settings:{vnext:[{address:$server,port:$port,users:[{id:$uuid,encryption:"none"}]}]},streamSettings:{network:"xhttp",security:"tls",tlsSettings:{serverName:$server,alpn:$alpn,fingerprint:"chrome"},xhttpSettings:{host:$server,path:$path,mode:"auto"}}}]' <<<"$xray_out")"
    sing_out="$(jq --arg tag "$name" --arg server "$DOMAIN" --arg uuid "$UUID" --arg path "$client_path_value" --argjson port "$port" --argjson alpn "$alpn" \
      '. + [{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,tls:{enabled:true,server_name:$server,alpn:$alpn,utls:{enabled:true,fingerprint:"chrome"}},transport:{type:"xhttp",host:$server,path:$path,mode:"auto"}}]' <<<"$sing_out")"
    local yaml_alpn
    [[ "$mode" == h2 ]] && yaml_alpn=h2 || yaml_alpn=h3
    clash_proxies+=$'\n'"  - name: ${name}"$'\n'"    type: vless"$'\n'"    server: ${DOMAIN}"$'\n'"    port: ${PORT}"$'\n'"    uuid: ${UUID}"$'\n'"    encryption: \"\""$'\n'"    udp: true"$'\n'"    tls: true"$'\n'"    servername: ${DOMAIN}"$'\n'"    alpn:"$'\n'"      - ${yaml_alpn}"$'\n'"    client-fingerprint: chrome"$'\n'"    network: xhttp"$'\n'"    xhttp-opts:"$'\n'"      host: ${DOMAIN}"$'\n'"      path: ${client_path_value}"$'\n'"      mode: auto"$'\n'
  done
  jq -n --argjson outbounds "$xray_out" '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:10808,protocol:"socks",settings:{auth:"noauth",udp:true}},{listen:"127.0.0.1",port:10809,protocol:"http",settings:{}}],outbounds:($outbounds + [{protocol:"freedom",tag:"direct"}]),routing:{domainStrategy:"AsIs"}}' > "$subdir/xray.json" 
  jq -n --argjson outbounds "$sing_out" '{log:{level:"warn"},inbounds:[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:2080}],outbounds:($outbounds + [{type:"direct",tag:"direct"},{type:"selector",tag:"select",outbounds:[$outbounds[].tag],default:$outbounds[0].tag}]),route:{final:"select"}}' > "$subdir/sing-box.json" 
  {
    printf 'mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: warning\nproxies:\n'
    printf '%s' "$clash_proxies"
    printf 'proxy-groups:\n  - name: XHTTP-TLS\n    type: select\n    proxies:\n      - XHTTP-TLS-H2\n      - XHTTP-TLS-H3-UDP\nrules:\n  - MATCH,XHTTP-TLS\n'
  } > "$subdir/clash-meta.yaml"
  chmod 0600 "$subdir"/*
  echo; echo '========== XHTTP TLS 直连节点 =========='
  echo "H2 / TCP：$h2"
  echo "H3 / UDP：$h3"
  echo '已生成本实例订阅文件：Xray Base64、Xray JSON、sing-box JSON、Clash Meta/Mihomo YAML'
  echo '说明：sing-box XHTTP 需使用支持 XHTTP 的扩展版本；官方主线兼容性以客户端版本为准。'
  [[ -n "${LOCAL_SUB_URL:-}" ]] && echo "本地 IP 订阅：${LOCAL_SUB_URL}"
  echo '========================================'
}
print_link(){
  if [[ "$PROTOCOL" == xhttp-tls && "$TUNNEL" == no ]]; then
    print_direct_xhttp_links
    return 0
  fi
  if [[ "$TUNNEL" == yes ]]; then
    if [[ "$PROTOCOL" == ws-tunnel ]]; then print_ws_tunnel_links; else print_tunnel_links; fi
    return 0
  fi
  local link='' link_port="$PORT"
  case "$PROTOCOL" in
    xhttp-reality) link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=reality&pbk=${REALITY_PUBLIC}&fp=chrome&sid=${REALITY_SHORT_ID}&sni=${REALITY_SNI}&type=xhttp&path=$(urlencode "$(client_path)")&mode=auto#XHTTP-REALITY";;
    xhttp-tls) link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&alpn=h2%2Chttp%2F1.1&type=xhttp&path=${PATH_VALUE}&mode=auto#XHTTP-TLS-H2";;
    xhttp-tunnel) link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=none&type=xhttp&host=${DOMAIN}&path=${PATH_VALUE}&mode=auto#XHTTP-Argo-HTTP";;
    ws-tls|ws-tunnel) link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=$(urlencode "$(client_path)")#WS-TLS";;
    grpc-tls) link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=grpc&serviceName=grpc#GRPC-TLS";;
    httpupgrade-tls) link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=httpupgrade&path=${PATH_VALUE}#HTTPUpgrade-TLS";;
    *) die '无法生成节点链接';;
  esac
  echo; echo '========== 节点信息 =========='; echo "协议：$PROTOCOL"; echo "地址：$DOMAIN"; echo "本地监听端口：$PORT"; [[ "$TUNNEL" == yes ]] && echo "Tunnel Service URL：http://localhost:${PORT}"; echo "UUID：$UUID"; echo "服务端基础路径：$PATH_VALUE"; echo "客户端实际路径：$(client_path)"
  if [[ "$PROTOCOL" == xhttp-reality ]]; then echo "REALITY SNI：$REALITY_SNI"; echo "REALITY 公钥：$REALITY_PUBLIC"; echo "REALITY Short ID：$REALITY_SHORT_ID"; fi
  echo; printf '%s\n' "$link"; echo '=============================='
}
show_deployed_nodes(){
  local dir marker state id proto domain port uuid base tunnel tunnel_protocol client listen pname count=0
  local -a dirs=()
  shopt -s nullglob
  dirs=(/etc/xhttp /etc/xhttp-*)
  shopt -u nullglob
  echo; echo '========== 已部署节点列表 =========='
  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    marker="$dir/.xhttp-manager-instance"; state="$dir/state.json"
    [[ -r "$marker" && -s "$state" ]] || continue
    id="$(sed -n 's/^XHTTP Manager instance: //p' "$marker" | head -n1)"
    [[ -n "$id" && "/etc/$id" == "$dir" ]] || continue
    # Accept legacy marker versions; the instance identity and valid state are authoritative.
    [[ "$id" == xhttp || "$id" =~ ^xhttp-[0-9]+$ ]] || continue
    proto="$(jq -r '.PROTOCOL // ""' "$state" 2>/dev/null)"
    domain="$(jq -r '.DOMAIN // ""' "$state" 2>/dev/null)"
    port="$(jq -r '.PORT // ""' "$state" 2>/dev/null)"
    uuid="$(jq -r '.UUID // ""' "$state" 2>/dev/null)"
    base="$(jq -r '.PATH_VALUE // ""' "$state" 2>/dev/null)"
    local path_style
    path_style="$(jq -r '.PATH_STYLE // "legacy"' "$state" 2>/dev/null)"
    tunnel="$(jq -r '.TUNNEL // "no"' "$state" 2>/dev/null)"
    tunnel_protocol="$(jq -r '.TUNNEL_PROTOCOL // "auto"' "$state" 2>/dev/null)"
    [[ -n "$proto" && -n "$domain" && -n "$port" && -n "$uuid" ]] || continue
    case "$proto" in
      xhttp-reality) pname='VLESS + XHTTP + REALITY';;
      xhttp-tls) pname='VLESS + XHTTP + TLS';;
      xhttp-tunnel) pname='VLESS + XHTTP + Cloudflare Tunnel';;
      ws-tls) pname='VLESS + WS + TLS';;
      ws-tunnel) pname='VLESS + WS + Cloudflare Tunnel';;
      grpc-tls) pname='VLESS + gRPC + TLS';;
      httpupgrade-tls) pname='VLESS + HTTPUpgrade + TLS';;
      *) pname="$proto";;
    esac
    client="$base"
    if [[ "$path_style" == uuid-suffix ]]; then case "$proto" in xhttp-*|ws-*) client="${base}${uuid}";; esac; fi
    listen=0.0.0.0; [[ "$tunnel" == yes ]] && listen=127.0.0.1
    count=$((count+1))
    echo; echo "节点 ${count}：${pname}"
    echo "实例：${id}"
    echo "本地监听：${listen}:${port}"
    if [[ "$tunnel" == yes ]]; then
      echo "隧道类型：$([[ "$domain" == *.trycloudflare.com ]] && echo 临时隧道 || echo 固定/自定义隧道)"
      echo "隧道传输：${tunnel_protocol}"
      echo "绑定域名：${domain}"
      echo "Tunnel Service URL：http://localhost:${port}"
    else
      echo "连接地址：${domain}"
    fi
    echo "服务端基础路径：${base}"
    echo "客户端实际路径：${client}"
    local security cert_file reality_sni cf_mode
    security="$(jq -r '.SECURITY // "none"' "$state" 2>/dev/null)"
    cert_file="$(jq -r '.CERT_FILE // ""' "$state" 2>/dev/null)"
    reality_sni="$(jq -r '.REALITY_SNI // ""' "$state" 2>/dev/null)"
    case "$security" in
      tls) if [[ -n "$cert_file" && -s "$cert_file" ]]; then echo "TLS/证书：已配置，证书文件存在（$cert_file）"; else echo 'TLS/证书：TLS 已配置，证书文件缺失或未记录'; fi;;
      reality) echo "安全类型：REALITY；伪装 SNI：${reality_sni:-未记录}";;
      *) if [[ "$tunnel" == yes ]]; then echo '安全类型：Cloudflare Tunnel 外层 HTTPS'; else echo '安全类型：未启用 TLS/REALITY'; fi;;
    esac
    if [[ "$tunnel" == yes ]]; then
      cf_mode="$(jq -r '.CF_PATH_MODE // "specified"' "$state" 2>/dev/null)"
      if [[ "$cf_mode" == none ]]; then echo 'Cloudflare Path 模式：无 Path（Cloudflare 控制台 Path 留空）'; else echo "Cloudflare Path 匹配规则：$(cloudflare_path_rule "$client")"; fi
      if [[ "$domain" == *.trycloudflare.com ]]; then echo "Argo 临时域名：$domain"; else echo "Argo 固定/自定义域名：$domain"; fi
    fi
  done
  echo "已部署节点总数：${count}"
  (( count > 0 )) || echo '尚未发现带有效实例标记和节点状态的部署记录'
  echo '===================================='
  if local_sub_is_ready; then
    print_local_subscription_urls
  fi
}
show_status(){
  echo; echo '========== XHTTP 实例状态 =========='
  echo "当前管理实例：${INSTANCE_ID}"
  show_deployed_nodes
  if [[ -x "$XRAY_BIN" ]]; then "$XRAY_BIN" version | head -n2; else echo '当前实例专用 Xray 尚未安装'; fi
  core_os || return 0
  if [[ "$OS_FAMILY" == systemd ]]; then systemctl --no-pager --full status "$SERVICE_NAME" 2>/dev/null | head -n12 || true; else rc-service "$SERVICE_NAME" status 2>/dev/null || true; fi
  tunnel_status || true
}

local_sub_unit(){ printf '%s-local-subscription' "$INSTANCE_ID"; }

get_subscription_host_ip(){
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./ && $i !~ /^169\.254\./){print $i; exit}}')"
  fi
  if [[ -z "$ip" ]]; then ip="$(get_public_ip)"; fi
  printf '%s' "$ip"
}
local_sub_is_ready(){
  local unit osid root
  [[ -n "${LOCAL_SUB_PORT:-}" && "$LOCAL_SUB_PORT" =~ ^[0-9]+$ \
     && -n "${LOCAL_SUB_UUID:-}" && -d "${XHTTP_DIR:-}" ]] || return 1
  root="$(local_sub_dir)"
  [[ -s "$root/www/clmi.yaml" && -s "$root/www/sbox.json" && -s "$root/www/jhsub.txt" ]] || return 1
  unit="$(local_sub_unit)"
  [[ -r /etc/os-release ]] || return 1
  . /etc/os-release
  osid="${ID:-}"
  case "$osid" in
    ubuntu|debian)
      [[ -f "/etc/systemd/system/${unit}.service" ]] || return 1
      grep -Fq 'XHTTP Manager managed local subscription' "/etc/systemd/system/${unit}.service" || return 1
      grep -Fqx "ExecStart=/usr/bin/python3 $LIB_DIR/local_sub_server.py $LOCAL_SUB_PORT $LOCAL_SUB_UUID $root/www" "/etc/systemd/system/${unit}.service" || return 1
      systemctl is-active --quiet "$unit" || return 1
      ;;
    alpine)
      [[ -f "/etc/init.d/${unit}" ]] || return 1
      grep -Fq 'XHTTP Manager managed local subscription' "/etc/init.d/${unit}" || return 1
      grep -Fq "command_args=\"$LIB_DIR/local_sub_server.py $LOCAL_SUB_PORT $LOCAL_SUB_UUID $root/www\"" "/etc/init.d/${unit}" || return 1
      rc-service "$unit" status >/dev/null 2>&1 || return 1
      ;;
    *) return 1;;
  esac
  return 0
}
print_local_subscription_urls(){
  local ip="${1:-}"
  [[ -n "$ip" ]] || ip="$(get_subscription_host_ip)"
  [[ -n "$ip" ]] || return 1
  echo '========== 本地 IP 订阅地址 =========='
  echo "Clash/Mihomo本地IP订阅地址：http://${ip}:${LOCAL_SUB_PORT}/${LOCAL_SUB_UUID}/clmi.yaml"
  echo "Sing-box本地IP订阅地址：http://${ip}:${LOCAL_SUB_PORT}/${LOCAL_SUB_UUID}/sbox.json"
  echo "聚合协议本地IP订阅地址：http://${ip}:${LOCAL_SUB_PORT}/${LOCAL_SUB_UUID}/jhsub.txt"
  echo '===================================='
}
local_sub_dir(){ printf '%s/local-subscription' "$XHTTP_DIR"; }

# Resolve helper programs from the complete local package, the instance library,
# or the same-version raw repository. This also supports `bash <(curl ...)`,
# where SELF_DIR is /dev/fd and the package's adjacent Python files are absent.
ensure_local_sub_helpers(){
  local name tmp="" source_file old_source
  command -v /usr/bin/python3 >/dev/null 2>&1 || { warn '缺少 Python3，无法生成本地订阅'; return 1; }
  install -d -m 0700 "$LIB_DIR" || return 1
  for name in local_sub_builder.py local_sub_server.py; do
    source_file=""
    if [[ "$name" == local_sub_builder.py && -s "$LIB_DIR/$name" ]] \
       && grep -Fq 'def node_from' "$LIB_DIR/$name"; then
      source_file="$LIB_DIR/$name"
    elif [[ "$name" == local_sub_server.py && -s "$LIB_DIR/$name" ]]; then
      source_file="$LIB_DIR/$name"
    elif [[ -s "$SELF_DIR/$name" ]]; then
      source_file="$SELF_DIR/$name"
    else
      tmp="$LIB_DIR/.${name}.download.$$"
      if ! download_to "$RAW_BASE_URL/$name" "$tmp"; then
        rm -f -- "$tmp"
        warn "无法取得 $name；请使用完整 V${VERSION} ZIP 包，或确认仓库 main 已同步辅助文件"
        return 1
      fi
      source_file="$tmp"
    fi

    if ! /usr/bin/python3 -c 'import pathlib,sys; compile(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"),sys.argv[1],"exec")' "$source_file" >/dev/null 2>&1; then
      [[ "$source_file" == "$LIB_DIR/.$name.download.$$" || "$source_file" == "$LIB_DIR/.local_sub_builder.py.patch.$$" ]] && rm -f -- "$source_file"
      warn "$name Python 语法校验失败"
      return 1
    fi
    if [[ "$source_file" != "$LIB_DIR/$name" ]]; then
      install -m 0700 "$source_file" "$LIB_DIR/$name" || return 1
    fi
    [[ "$source_file" == "$LIB_DIR/.$name.download.$$" || "$source_file" == "$LIB_DIR/.local_sub_builder.py.patch.$$" ]] && rm -f -- "$source_file"
  done
  return 0
}
local_sub_start(){
  local root unit ip osid builder stage
  root="$(local_sub_dir)"; unit="$(local_sub_unit)"
  [[ -n "$LOCAL_SUB_PORT" && -n "$LOCAL_SUB_UUID" ]] || return 1
  [[ -x /usr/bin/python3 ]] || { warn '缺少 /usr/bin/python3'; return 1; }
  install -d -m 0700 "$root" "$LIB_DIR"
  ensure_local_sub_helpers || { warn '本地订阅辅助程序未能安装；未启动服务'; return 1; }
  builder="$LIB_DIR/local_sub_builder.py"
  [[ -s "$builder" ]] || { warn '多节点订阅生成程序缺失'; return 1; }
  stage="$(mktemp -d "$root/.build.XXXXXX")" || return 1
  if ! /usr/bin/python3 "$builder" /etc "$stage"; then rm -rf -- "$stage"; return 1; fi
  install -d -m 0700 "$root/www"
  install -m 0600 "$stage/clmi.yaml" "$root/www/clmi.yaml" || { rm -rf -- "$stage"; return 1; }
  install -m 0600 "$stage/sbox.json" "$root/www/sbox.json" || { rm -rf -- "$stage"; return 1; }
  install -m 0600 "$stage/jhsub.txt" "$root/www/jhsub.txt" || { rm -rf -- "$stage"; return 1; }
  rm -rf -- "$stage"
  [[ -s "$LIB_DIR/local_sub_server.py" ]] || { warn '本地订阅服务程序缺失'; return 1; }
  if [[ -r /etc/os-release ]]; then . /etc/os-release; osid="${ID:-}"; else return 1; fi
  case "$osid" in
    ubuntu|debian)
      cat > "/etc/systemd/system/${unit}.service" <<UNIT
# XHTTP Manager managed local subscription
[Unit]
Description=XHTTP Manager local subscription (${INSTANCE_ID})
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 $LIB_DIR/local_sub_server.py $LOCAL_SUB_PORT $LOCAL_SUB_UUID $root/www
Restart=on-failure
RestartSec=3
User=root
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
UNIT
      chmod 0644 "/etc/systemd/system/${unit}.service"
      systemctl daemon-reload && systemctl enable "$unit" >/dev/null && systemctl restart "$unit" || return 1;;
    alpine)
      cat > "/etc/init.d/${unit}" <<RC
#!/sbin/openrc-run
# XHTTP Manager managed local subscription
name="$unit"
command="/usr/bin/python3"
command_args="$LIB_DIR/local_sub_server.py $LOCAL_SUB_PORT $LOCAL_SUB_UUID $root/www"
command_background="yes"
pidfile="/run/${unit}.pid"
RC
      chmod 0755 "/etc/init.d/${unit}"
      rc-update add "$unit" default >/dev/null 2>&1 || true
      rc-service "$unit" restart || rc-service "$unit" start || return 1;;
    *) warn "不支持的系统：$osid"; return 1;;
  esac
  ip="$(get_subscription_host_ip)"
  LOCAL_SUB_URL="http://${ip}:${LOCAL_SUB_PORT}/${LOCAL_SUB_UUID}"
  save_state || return 1
  echo; print_local_subscription_urls "$ip"
}
local_sub_stop(){
  local unit; unit="$(local_sub_unit)"
  [[ -r /etc/os-release ]] && . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) if [[ -f "/etc/systemd/system/${unit}.service" ]] && grep -q 'XHTTP Manager managed local subscription' "/etc/systemd/system/${unit}.service"; then systemctl disable --now "$unit" >/dev/null 2>&1 || true; rm -f "/etc/systemd/system/${unit}.service"; systemctl daemon-reload >/dev/null 2>&1 || true; fi;;
    alpine) if [[ -f "/etc/init.d/${unit}" ]] && grep -q 'XHTTP Manager managed local subscription' "/etc/init.d/${unit}"; then rc-service "$unit" stop >/dev/null 2>&1 || true; rc-update del "$unit" default >/dev/null 2>&1 || true; rm -f "/etc/init.d/${unit}"; fi;;
  esac
  rm -rf -- "$(local_sub_dir)"
}
local_subscription_menu(){
  local choice value ip
  while true; do
    echo; echo '========== 本地订阅链接 =========='
    if local_sub_is_ready; then
      ip="$(get_subscription_host_ip)"
      if [[ -n "$ip" ]]; then print_local_subscription_urls "$ip"; else echo '本地订阅服务已运行，但未能检测到可用 IP'; fi
    else
      echo '当前未安装或未正常运行本地 IP 订阅服务'
    fi
    echo '1. 重置安装本地IP订阅链接'
    echo '2. 更换订阅链接路径密码'
    echo '3. 更换订阅链接端口'
    echo '4. 卸载本地IP订阅链接'
    echo '0. 返回上层'
    read -rp '请选择: ' choice
    case "$choice" in
      1|2|3)
        if [[ "$choice" == 1 || "$choice" == 3 || -z "$LOCAL_SUB_PORT" ]]; then
          read -rp '本地订阅端口（回车随机）: ' value
          if [[ -z "$value" ]]; then LOCAL_SUB_PORT="$(random_port)"; elif valid_port "$value" && ! port_in_use "$value"; then LOCAL_SUB_PORT="$((10#$value))"; else warn '端口无效或已占用'; continue; fi
        fi
        if [[ "$choice" == 1 || "$choice" == 2 || -z "$LOCAL_SUB_UUID" ]]; then
          read -rp '路径密码 UUID（回车随机）: ' value
          if [[ -z "$value" ]]; then LOCAL_SUB_UUID="$(random_uuid)"; elif [[ "$value" =~ ^[A-Fa-f0-9-]{16,64}$ ]]; then LOCAL_SUB_UUID="$value"; else warn '路径密码格式不正确'; continue; fi
        fi
        save_state && local_sub_start && ok '本地 IP 订阅服务已安装'
        ;;
      4)
        read -rp '确认清除本地订阅配置？[y/N] ' value
        if [[ "$value" =~ ^[Yy]$ ]]; then LOCAL_SUB_URL=""; LOCAL_SUB_PORT=""; LOCAL_SUB_UUID=""; local_sub_stop; LOCAL_SUB_URL=""; LOCAL_SUB_PORT=""; LOCAL_SUB_UUID=""; save_state && ok '本地订阅服务已卸载'; fi
        ;;
      0) return;; *) warn '无效选择';;
    esac
  done
}

stop_exact_xhttp_processes(){
  local id="$1" dir="/etc/$1" xray="/usr/local/bin/xray-$1" runner="/usr/local/lib/$1/cloudflared-run.sh" cloud="/usr/local/bin/cloudflared-$1"
  # Match full command lines anchored to this instance's private binary/config paths only.
  command -v pkill >/dev/null 2>&1 || return 0
  pkill -TERM -f "^${xray} run -config ${dir}/config.json$" 2>/dev/null || true
  pkill -TERM -f "^${runner}$" 2>/dev/null || true
  pkill -TERM -f "^/usr/bin/env bash ${runner}$" 2>/dev/null || true
  pkill -TERM -f "^${cloud} tunnel " 2>/dev/null || true
  sleep 1
  pkill -KILL -f "^${xray} run -config ${dir}/config.json$" 2>/dev/null || true
  pkill -KILL -f "^${runner}$" 2>/dev/null || true
  pkill -KILL -f "^/usr/bin/env bash ${runner}$" 2>/dev/null || true
  pkill -KILL -f "^${cloud} tunnel " 2>/dev/null || true
}

uninstall_all(){
  local confirm os_id os_family dir id marker marker_version candidate_path
  local svc_unit svc_init tunnel_unit tunnel_init xray_bin cloudflared_bin runner
  local expected_xray expected_tunnel fragment base found_marker found_service
  local launcher legacy removed=0
  local -a dirs=() libs=() bins=() ids=() scan_units=()
  local -A seen=()
  echo
  warn '将卸载唯一 XHTTP Manager（/etc/xhttp），并清理可验证归属的旧版 xhttp-N 残留。'
  warn '新版只使用 /etc/xhttp；旧版 xhttp-N 仅作为卸载清理对象，不再创建。'
  warn '卸载固定 xhttp 主实例及旧版 xhttp-N 的专属服务/二进制；不按进程名或端口误删。'
  warn '明确保护 sing-box.service、/etc/s-box、/etc/s-box/cloudflared。'
  read -rp '确认卸载全部本项目实例？输入 YES 继续: ' confirm
  [[ "$confirm" == YES ]] || return 0

  [[ -r /etc/os-release ]] || die '无法识别系统，已取消卸载'
  . /etc/os-release
  case "${ID:-}" in ubuntu|debian) os_family=systemd;; alpine) os_family=openrc;; *) die "不支持的系统：${ID:-unknown}，已取消卸载";; esac

  # Discovery A: manager instance directories. A directory alone is not ownership proof.
  shopt -s nullglob
  dirs=(/etc/xhttp /etc/xhttp-[0-9]*)
  libs=(/usr/local/lib/xhttp /usr/local/lib/xhttp-[0-9]*)
  bins=(/usr/local/bin/xray-xhttp /usr/local/bin/xray-xhttp-[0-9]* /usr/local/bin/cloudflared-xhttp /usr/local/bin/cloudflared-xhttp-[0-9]*)
  if [[ "$os_family" == systemd ]]; then
    scan_units=(/etc/systemd/system/xhttp*.service)
  else
    scan_units=(/etc/init.d/xhttp /etc/init.d/xhttp-[0-9]* /etc/init.d/xhttp-cloudflared /etc/init.d/xhttp-[0-9]*-cloudflared)
  fi
  shopt -u nullglob

  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    id="${dir##*/}"
    [[ "$id" =~ ^xhttp(-[0-9]+)?$ ]] || continue
    seen["$id"]=1
  done
  for dir in "${libs[@]}"; do
    [[ -d "$dir" ]] || continue
    id="${dir##*/}"
    [[ "$id" =~ ^xhttp(-[0-9]+)?$ ]] || continue
    seen["$id"]=1
  done
  for dir in "${bins[@]}"; do
    [[ -e "$dir" || -L "$dir" ]] || continue
    base="${dir##*/}"
    id="${base#xray-}"; id="${id#cloudflared-}"
    [[ "$id" =~ ^xhttp(-[0-9]+)?$ ]] && seen["$id"]=1
  done
  for launcher in /usr/local/bin/xhttp /usr/local/bin/xhttp-legacy; do
    [[ -f "$launcher" ]] || continue
    grep -Fq '# XHTTP Manager managed launcher' "$launcher" || continue
    base="$(grep -oE '/usr/local/lib/xhttp(-[0-9]+)?/xhttp\.sh' "$launcher" | head -n1 || true)"
    [[ -n "$base" ]] || continue
    id="${base#/usr/local/lib/}"; id="${id%/xhttp.sh}"
    [[ "$id" =~ ^xhttp(-[0-9]+)?$ ]] && seen["$id"]=1
  done

  # Discovery B: exact manager-owned service definitions can recover an orphan
  # whose /etc instance directory or marker was already removed.
  for svc_unit in "${scan_units[@]}"; do
    [[ -e "$svc_unit" || -L "$svc_unit" ]] || continue
    base="${svc_unit##*/}"
    if [[ "$base" == *-cloudflared ]]; then base="${base%-cloudflared}"; fi
    base="${base%.service}"
    [[ "$base" =~ ^xhttp(-[0-9]+)?$ ]] || continue
    id="$base"
    xray_bin="/usr/local/bin/xray-$id"
    runner="/usr/local/lib/$id/cloudflared-run.sh"
    expected_xray="ExecStart=$xray_bin run -config /etc/$id/config.json"
    expected_tunnel="ExecStart=$runner"
    if [[ "$os_family" == systemd ]]; then
      if [[ "$svc_unit" == *-cloudflared.service ]]; then
        [[ -f "$svc_unit" && ! -L "$svc_unit" ]] || continue
        if grep -Fqx "$expected_tunnel" "$svc_unit"; then seen["$id"]=1; fi
      else
        [[ -f "$svc_unit" && ! -L "$svc_unit" ]] || continue
        if grep -Fqx "$expected_xray" "$svc_unit"; then seen["$id"]=1; fi
      fi
    else
      [[ -f "$svc_unit" && ! -L "$svc_unit" ]] || continue
      if [[ "$svc_unit" == *-cloudflared ]]; then
        if grep -Fq "command=\"$runner\"" "$svc_unit"; then seen["$id"]=1; fi
      else
        if grep -Fq "command=\"$xray_bin\"" "$svc_unit" \
          && grep -Fq "command_args=\"run -config /etc/$id/config.json\"" "$svc_unit"; then seen["$id"]=1; fi
      fi
    fi
  done

  launcher="/usr/local/bin/xhttp"; legacy="/usr/local/bin/xhttp-legacy"
  for id in "${!seen[@]}"; do ids+=("$id"); done
  if (( ${#ids[@]} == 0 )); then
    warn '未发现有效实例标记或可通过专用服务定义验证的孤立实例；未删除任何文件或服务。'
    return 0
  fi

  # Phase 1: preflight every candidate before stopping or deleting anything.
  for id in "${ids[@]}"; do
    dir="/etc/$id"; marker="$dir/.xhttp-manager-instance"
    svc_unit="/etc/systemd/system/$id.service"; svc_init="/etc/init.d/$id"
    tunnel_unit="/etc/systemd/system/$id-cloudflared.service"; tunnel_init="/etc/init.d/$id-cloudflared"
    xray_bin="/usr/local/bin/xray-$id"; cloudflared_bin="/usr/local/bin/cloudflared-$id"
    runner="/usr/local/lib/$id/cloudflared-run.sh"
    expected_xray="ExecStart=$xray_bin run -config $dir/config.json"
    expected_tunnel="ExecStart=$runner"
    found_marker=no; found_service=no

    # Never follow a namespace directory symlink during a full purge. A legacy
    # path that redirects outside the dedicated XHTTP namespace is not safe to remove.
    for candidate_path in "$dir" "/usr/local/lib/$id"; do
      if [[ -L "$candidate_path" ]]; then
        die "$candidate_path 是符号链接；为防止误删其他项目目标，已中止全部卸载"
      fi
    done

    # The user explicitly authorized a full purge of the dedicated xhttp / xhttp-N namespace.
    # A missing, stale or malformed manager marker must not strand an old XHTTP instance.
    if [[ -d "$dir" || -d "/usr/local/lib/$id" || -e "/usr/local/bin/xray-$id" || -e "/usr/local/bin/cloudflared-$id" ]]; then found_marker=yes; fi
    if [[ -f "$launcher" ]] && grep -Fq "/usr/local/lib/$id/xhttp.sh" "$launcher"; then found_marker=yes; fi
    if [[ -f "$legacy" ]] && grep -Fq "/usr/local/lib/$id/xhttp.sh" "$legacy"; then found_marker=yes; fi

    if [[ "$os_family" == systemd ]]; then
      if [[ -e "$svc_unit" || -L "$svc_unit" ]]; then
        [[ -f "$svc_unit" && ! -L "$svc_unit" ]] || die "$svc_unit 不是普通文件；拒绝卸载"
        if ! grep -Fqx "$expected_xray" "$svc_unit" \
           && ! { grep -Eq '^ExecStart=.*xray.*run -config ' "$svc_unit" && grep -Fq "/etc/$id/" "$svc_unit"; }; then
          die "$svc_unit 未引用本实例专属路径；为保护其他服务已中止"
        fi
        found_service=yes
      else
        fragment="$(systemctl show -p FragmentPath --value "$id" 2>/dev/null || true)"
        if [[ -n "$fragment" ]]; then
          [[ -f "$fragment" ]] && grep -Eq '^ExecStart=.*xray.*run -config ' "$fragment" && grep -Fq "/etc/$id/" "$fragment" \
            || die "发现无法验证归属的服务 $id（$fragment）；为保护其他服务已中止"
          found_service=yes
        fi
      fi
      if [[ -e "$tunnel_unit" || -L "$tunnel_unit" ]]; then
        [[ -f "$tunnel_unit" && ! -L "$tunnel_unit" ]] || die "$tunnel_unit 不是普通文件；拒绝卸载"
        if ! grep -Fqx "$expected_tunnel" "$tunnel_unit" \
           && ! { grep -Eq '^ExecStart=.*cloudflared' "$tunnel_unit" && { grep -Fq "/usr/local/lib/$id/" "$tunnel_unit" || grep -Fq "/usr/local/bin/cloudflared-$id" "$tunnel_unit"; }; }; then
          die "$tunnel_unit 未引用本实例专属 Tunnel 路径；为保护其他服务已中止"
        fi
        found_service=yes
      else
        fragment="$(systemctl show -p FragmentPath --value "$id-cloudflared" 2>/dev/null || true)"
        if [[ -n "$fragment" ]]; then
          [[ -f "$fragment" ]] && grep -Eq '^ExecStart=.*cloudflared' "$fragment" \
            && { grep -Fq "/usr/local/lib/$id/" "$fragment" || grep -Fq "/usr/local/bin/cloudflared-$id" "$fragment"; } \
            || die "发现无法验证归属的 Tunnel $id-cloudflared（$fragment）；为保护其他服务已中止"
          found_service=yes
        fi
      fi
    else
      if [[ -e "$svc_init" || -L "$svc_init" ]]; then
        [[ -f "$svc_init" && ! -L "$svc_init" ]] || die "$svc_init 不是普通文件；拒绝卸载"
        if ! { grep -Fq "command=\"$xray_bin\"" "$svc_init" && grep -Fq "command_args=\"run -config $dir/config.json\"" "$svc_init"; } \
           && ! { grep -Eq '^command=.*xray' "$svc_init" && grep -Fq "/etc/$id/" "$svc_init"; }; then
          die "$svc_init 未引用本实例专属 Xray 路径；为保护其他服务已中止"
        fi
        found_service=yes
      fi
      if [[ -e "$tunnel_init" || -L "$tunnel_init" ]]; then
        [[ -f "$tunnel_init" && ! -L "$tunnel_init" ]] || die "$tunnel_init 不是普通文件；拒绝卸载"
        if ! grep -Fq "command=\"$runner\"" "$tunnel_init" \
           && ! { grep -Eq '^command=.*cloudflared' "$tunnel_init" && { grep -Fq "/usr/local/lib/$id/" "$tunnel_init" || grep -Fq "/usr/local/bin/cloudflared-$id" "$tunnel_init"; }; }; then
          die "$tunnel_init 未引用本实例专属 Tunnel 路径；为保护其他服务已中止"
        fi
        found_service=yes
      fi
    fi
    [[ "$found_marker" == yes || "$found_service" == yes ]] || [[ -d "$dir" || -d "/usr/local/lib/$id" || -e "$xray_bin" || -e "$cloudflared_bin" ]] || die "$id 没有可验证的 XHTTP 配置、模块或专用服务；为保护其他项目已中止"
  done

  echo; echo '即将卸载以下已验证实例：'; printf '  - %s
' "${ids[@]}"
  echo '所有候选均已完成归属预检；现在开始逐个停止和清理。'

  # Phase 2: stop and remove only the exact pre-validated instance units/files.
  for id in "${ids[@]}"; do
    dir="/etc/$id"; svc_unit="/etc/systemd/system/$id.service"; svc_init="/etc/init.d/$id"
    tunnel_unit="/etc/systemd/system/$id-cloudflared.service"; tunnel_init="/etc/init.d/$id-cloudflared"
    xray_bin="/usr/local/bin/xray-$id"; cloudflared_bin="/usr/local/bin/cloudflared-$id"
    runner="/usr/local/lib/$id/cloudflared-run.sh"
    # Remove only this instance's explicitly marked local-subscription service.
    if [[ "$os_family" == systemd ]]; then
      local sub_unit_file="/etc/systemd/system/${id}-local-subscription.service"
      if [[ -f "$sub_unit_file" ]] && grep -Fq "ExecStart=/usr/bin/python3 /usr/local/lib/$id/local_sub_server.py " "$sub_unit_file"; then
        systemctl disable --now "${id}-local-subscription.service" >/dev/null 2>&1 || true
        rm -f -- "$sub_unit_file"
      fi
    else
      local sub_init_file="/etc/init.d/${id}-local-subscription"
      if [[ -f "$sub_init_file" ]] && grep -Fq "command="/usr/bin/python3"" "$sub_init_file" \
          && grep -Fq "/usr/local/lib/$id/local_sub_server.py" "$sub_init_file"; then
        rc-service "${id}-local-subscription" stop >/dev/null 2>&1 || true
        rc-update del "${id}-local-subscription" default >/dev/null 2>&1 || true
        rm -f -- "$sub_init_file" "/run/${id}-local-subscription.pid"
      fi
    fi
    if [[ "$os_family" == systemd ]]; then
      if [[ -f "$svc_unit" ]]; then
        systemctl disable --now "$id.service" || { systemctl is-active --quiet "$id.service" && die "停止 $id.service 失败；停止后续清理" || true; }
        rm -f -- "$svc_unit"
      else
        fragment="$(systemctl show -p FragmentPath --value "$id" 2>/dev/null || true)"
        if [[ -n "$fragment" && -f "$fragment" ]] && grep -Eq '^ExecStart=.*xray.*run -config ' "$fragment" && grep -Fq "/etc/$id/" "$fragment"; then
          systemctl disable --now "$id.service" || true; rm -f -- "$fragment"
        fi
      fi
      if [[ -f "$tunnel_unit" ]]; then
        systemctl disable --now "$id-cloudflared.service" || { systemctl is-active --quiet "$id-cloudflared.service" && die "停止 $id-cloudflared.service 失败；停止后续清理" || true; }
        rm -f -- "$tunnel_unit"
      else
        fragment="$(systemctl show -p FragmentPath --value "$id-cloudflared" 2>/dev/null || true)"
        if [[ -n "$fragment" && -f "$fragment" ]] && grep -Eq '^ExecStart=.*cloudflared' "$fragment" \
           && { grep -Fq "/usr/local/lib/$id/" "$fragment" || grep -Fq "/usr/local/bin/cloudflared-$id" "$fragment"; }; then
          systemctl disable --now "$id-cloudflared.service" || true; rm -f -- "$fragment"
        fi
      fi
    else
      if [[ -f "$svc_init" ]]; then
        rc-service "$id" stop || { rc-service "$id" status >/dev/null 2>&1 && die "停止 $id 失败" || true; }
        rc-update del "$id" default 2>/dev/null || true; rm -f -- "$svc_init" "/run/$id.pid" "/var/log/$id.log" "/var/log/$id.err"
      fi
      if [[ -f "$tunnel_init" ]]; then
        rc-service "$id-cloudflared" stop || { rc-service "$id-cloudflared" status >/dev/null 2>&1 && die "停止 $id-cloudflared 失败" || true; }
        rc-update del "$id-cloudflared" default 2>/dev/null || true; rm -f -- "$tunnel_init" "/run/$id-cloudflared.pid" "/var/log/$id-cloudflared.log" "/var/log/$id-cloudflared.err"
      fi
    fi
    # Stop only orphan processes whose full command line points at this exact instance.
    stop_exact_xhttp_processes "$id"
    rm -f -- "$xray_bin" "$cloudflared_bin" \
      "/var/log/$id.log" "/var/log/$id.err" "/var/log/$id-cloudflared.log" "/var/log/$id-cloudflared.err" \
      "/run/$id.pid" "/run/$id-cloudflared.pid"
    # Remove this instance's exact managed `xhttp` launcher before its library path disappears.
    LIB_DIR="/usr/local/lib/$id"
    remove_persistent_entrypoint
    if [[ -d "$dir" ]]; then
      if [[ -f "$dir/state.json" ]]; then INSTANCE_ID="$id"; XHTTP_DIR="$dir"; LIB_DIR="/usr/local/lib/$id"; local_sub_stop 2>/dev/null || true; fi
      rm -rf -- "/usr/local/lib/$id" "$dir"
    elif [[ -d "/usr/local/lib/$id" ]]; then
      rm -rf -- "/usr/local/lib/$id"
    else
      rm -f -- "$dir/config.json" "$dir/state.json" "$dir/cloudflare-token" "$dir/cloudflare-protocol" \
        "$dir/.xhttp-manager-instance" \
        "/usr/local/lib/$id/core.sh" "/usr/local/lib/$id/tunnel.sh" \
        "/usr/local/lib/$id/xhttp.sh" "/usr/local/lib/$id/local_sub_builder.py" \
        "/usr/local/lib/$id/local_sub_server.py" "/usr/local/lib/$id/cloudflared-run.sh"
      rmdir -- "/usr/local/lib/$id" "$dir" 2>/dev/null || true
    fi
    removed=$((removed + 1))
  done

  [[ "$os_family" != systemd ]] || systemctl daemon-reload
  launcher="/usr/local/bin/xhttp"; legacy="/usr/local/bin/xhttp-legacy"
  if [[ -f "$launcher" ]] && grep -Fq '# XHTTP Manager managed launcher' "$launcher" \
     && grep -Eq 'exec /usr/bin/env bash /usr/local/lib/xhttp(-[0-9]+)?/xhttp.sh' "$launcher"; then rm -f -- "$launcher"; fi
  if [[ -f "$legacy" ]] && grep -Fq '# XHTTP Manager managed launcher' "$legacy" \
     && grep -Eq 'exec /usr/bin/env bash /usr/local/lib/xhttp(-[0-9]+)?/xhttp.sh' "$legacy"; then rm -f -- "$legacy"; fi
  ok "已卸载 $removed 个经标记或专用服务定义验证的 XHTTP Manager 实例及其专用文件。"
  ok '未操作 sing-box、/etc/s-box、通用 xray/cloudflared、其他 Tunnel 或归属不明进程。'
  UNINSTALL_COMPLETED=yes
}
install_modules(){
  install -d -m 0755 "$LIB_DIR"
  install -d -m 0700 "$XHTTP_DIR"
  local t1 t2; t1="$(mktemp "$LIB_DIR/core.XXXXXX")"; t2="$(mktemp "$LIB_DIR/tunnel.XXXXXX")"
  if ! install -m 0644 "$CORE_FILE" "$t1" || ! install -m 0644 "$TUNNEL_FILE" "$t2"; then rm -f "$t1" "$t2"; die '安装模块失败'; fi
  mv -f "$t1" "$LIB_DIR/core.sh"; mv -f "$t2" "$LIB_DIR/tunnel.sh"
  if [[ -f "$SELF_DIR/local_sub_server.py" && "$SELF_DIR/local_sub_server.py" != "$LIB_DIR/local_sub_server.py" ]]; then install -m 0700 "$SELF_DIR/local_sub_server.py" "$LIB_DIR/local_sub_server.py"; fi
  if [[ -f "$SELF_DIR/local_sub_builder.py" && "$SELF_DIR/local_sub_builder.py" != "$LIB_DIR/local_sub_builder.py" ]]; then install -m 0700 "$SELF_DIR/local_sub_builder.py" "$LIB_DIR/local_sub_builder.py"; fi
  if [[ -e "$XHTTP_DIR/.xhttp-manager-instance" ]] && ! grep -Fqx "XHTTP Manager instance: $INSTANCE_ID" "$XHTTP_DIR/.xhttp-manager-instance"; then
    die "实例标记冲突：$XHTTP_DIR/.xhttp-manager-instance；拒绝覆盖"
  fi
  {
    printf 'XHTTP Manager instance: %s\n' "$INSTANCE_ID"
    printf 'XHTTP Manager version: %s\n' "$VERSION"
  } > "$XHTTP_DIR/.xhttp-manager-instance"
  chmod 0600 "$XHTTP_DIR/.xhttp-manager-instance"
}
install_persistent_entrypoint(){
  local tmp="$LIB_DIR/xhttp.sh.tmp.$$" launcher="/usr/local/bin/xhttp" launcher_tmp="/usr/local/bin/.xhttp-launcher.$$" legacy="/usr/local/bin/xhttp-legacy" source_file=""
  # Prefer the exact local package script so a same-version remote branch cannot
  # silently replace this revision's fixes. Remote fallback is only for bootstrap use.
  if [[ -r "$SELF_DIR/xhttp.sh" ]] && grep -Fqx "VERSION=\"$VERSION\"" "$SELF_DIR/xhttp.sh"; then
    source_file="$SELF_DIR/xhttp.sh"
  elif [[ -r "${BASH_SOURCE[0]}" ]] && grep -Fqx "VERSION=\"$VERSION\"" "${BASH_SOURCE[0]}"; then
    source_file="${BASH_SOURCE[0]}"
  elif download_to "$RAW_BASE_URL/xhttp.sh" "$tmp" && grep -Fqx "VERSION=\"$VERSION\"" "$tmp"; then
    source_file="$tmp"
  else
    rm -f -- "$tmp"
    warn '无法取得与当前版本一致的 xhttp.sh，暂不创建快捷命令；上传本版本的完整脚本包后重新运行即可'
    return 0
  fi
  install -m 0700 "$source_file" "$LIB_DIR/xhttp.sh" || { rm -f -- "$tmp"; warn '保存管理主程序失败'; return 0; }
  rm -f -- "$tmp"
  if [[ -e "$launcher" || -L "$launcher" ]]; then
    if grep -Fq '# XHTTP Manager managed launcher' "$launcher" \
       && grep -Fqx "exec /usr/bin/env bash $LIB_DIR/xhttp.sh \"\$@\"" "$launcher"; then
      : # already our launcher for this exact instance
    elif grep -Fq '# XHTTP Manager managed launcher' "$launcher" \
         && grep -Fq 'exec /usr/bin/env bash ' "$launcher"; then
      # Preserve the previous manager shortcut once. If a verified managed
      # backup already exists, it is safe to repair the active launcher again.
      if [[ ! -e "$legacy" && ! -L "$legacy" ]]; then
        if ! cp -p -- "$launcher" "$legacy"; then
          warn '无法备份旧 XHTTP 快捷命令；为保护旧实例，未修改快捷命令'
          return 0
        fi
      elif ! grep -Fq '# XHTTP Manager managed launcher' "$legacy"; then
        warn '旧快捷命令备份路径已被其他文件占用，为避免覆盖，未修改快捷命令'
        return 0
      fi
      {
        printf '%s\n' '#!/usr/bin/env bash' '# XHTTP Manager managed launcher'
        printf 'exec /usr/bin/env bash %q "$@"\n' "$LIB_DIR/xhttp.sh"
      } > "$launcher_tmp" || { warn '创建快捷命令失败'; rm -f -- "$launcher_tmp"; return 0; }
      chmod 0755 "$launcher_tmp"
      mv -f -- "$launcher_tmp" "$launcher"
    else
      warn "$launcher 已存在且不是可识别的旧版 XHTTP 管理快捷命令，为避免覆盖其他程序，未修改它"
      return 0
    fi
  else
    {
      printf '%s\n' '#!/usr/bin/env bash' '# XHTTP Manager managed launcher'
      printf 'exec /usr/bin/env bash %q "$@"\n' "$LIB_DIR/xhttp.sh"
    } > "$launcher_tmp" || { warn '创建快捷命令失败'; rm -f -- "$launcher_tmp"; return 0; }
    chmod 0755 "$launcher_tmp"
    if ! mv -n -- "$launcher_tmp" "$launcher"; then rm -f -- "$launcher_tmp"; warn '快捷命令路径发生冲突，未覆盖现有文件'; return 0; fi
  fi
  ok "快捷命令已配置：输入 xhttp 即可管理实例 $INSTANCE_ID"
}

install_manager_runtime_files(){
  local src="${BASH_SOURCE[0]}" target="$LIB_DIR/xhttp.sh" tmp
  install -d -m 0700 "$LIB_DIR" || return 1
  # Persist the exact currently executing manager, including process-substitution runs.
  if [[ -r "$SELF_DIR/xhttp.sh" ]] && grep -Fqx "VERSION=\"$VERSION\"" "$SELF_DIR/xhttp.sh"; then src="$SELF_DIR/xhttp.sh"; fi
  if [[ -r "$src" ]] && grep -Fqx "VERSION=\"$VERSION\"" "$src"; then
    tmp="$LIB_DIR/.xhttp.sh.$$"
    install -m 0700 "$src" "$tmp" && mv -f -- "$tmp" "$target" || { rm -f -- "$tmp"; return 1; }
  elif [[ ! -s "$target" ]] || ! grep -Fqx "VERSION=\"$VERSION\"" "$target"; then
    return 1
  fi
  # load_modules has already resolved exact core/tunnel modules, including bootstrap downloads.
  for pair in "core.sh:$CORE_FILE" "tunnel.sh:$TUNNEL_FILE"; do
    local name="${pair%%:*}" path="${pair#*:}"
    [[ -s "$path" ]] || return 1
    if ! cmp -s "$path" "$LIB_DIR/$name"; then install -m 0644 "$path" "$LIB_DIR/.${name}.$$" && mv -f -- "$LIB_DIR/.${name}.$$" "$LIB_DIR/$name" || return 1; fi
  done
  # Keep the subscription builder/server synchronized with this exact ZIP release.
  local helper
  for helper in local_sub_builder.py local_sub_server.py; do
    if [[ -s "$SELF_DIR/$helper" ]] && ! cmp -s "$SELF_DIR/$helper" "$LIB_DIR/$helper"; then
      install -m 0700 "$SELF_DIR/$helper" "$LIB_DIR/.$helper.$$" && mv -f -- "$LIB_DIR/.$helper.$$" "$LIB_DIR/$helper" || return 1
    fi
  done
  # Reserve this manager namespace so the next `xhttp` invocation selects the
  # same instance instead of incrementing xhttp-2, xhttp-3, ... on each launch.
  install -d -m 0700 "$XHTTP_DIR" || return 1
  if [[ -e "$XHTTP_DIR/.xhttp-manager-instance" ]]; then
    grep -Fqx "XHTTP Manager instance: $INSTANCE_ID" "$XHTTP_DIR/.xhttp-manager-instance" || return 1
  else
    {
      printf 'XHTTP Manager instance: %s\n' "$INSTANCE_ID"
      printf 'XHTTP Manager version: %s\n' "$VERSION"
    } > "$XHTTP_DIR/.xhttp-manager-instance" || return 1
    chmod 0600 "$XHTTP_DIR/.xhttp-manager-instance"
  fi
  return 0
}

remove_persistent_entrypoint(){
  local launcher="/usr/local/bin/xhttp" legacy="/usr/local/bin/xhttp-legacy"
  if [[ -f "$launcher" ]] \
      && grep -Fq '# XHTTP Manager managed launcher' "$launcher" \
      && grep -Fqx "exec /usr/bin/env bash $LIB_DIR/xhttp.sh \"\$@\"" "$launcher"; then
    rm -f -- "$launcher"
  fi
  # Restore the previous manager shortcut after this isolated instance is removed.
  if [[ ! -e "$launcher" && -f "$legacy" ]] \
      && grep -Fq '# XHTTP Manager managed launcher' "$legacy"; then
    mv -- "$legacy" "$launcher"
  fi
  rm -f -- "$LIB_DIR/xhttp.sh" "$LIB_DIR/xhttp.sh.tmp."*
}
UNINSTALL_COMPLETED=no
main_menu(){
  local choice
  while true; do
    echo; echo '===================================='; echo "       XHTTP Manager V${VERSION}"; echo '===================================='
    show_deployed_nodes
    echo '1. 安装 / 配置节点'; echo '2. 查看运行状态'; echo '3. 更新 Xray 内核'; echo '4. Cloudflare Tunnel 管理'; echo '5. 查看当前节点信息'; echo '6. 查看 / 生成节点链接与订阅'; echo '7. 本地订阅链接'; echo '8. 完整卸载 XHTTP Manager（含旧版残留）'; echo '0. 退出'; echo '===================================='
    read -rp '请选择: ' choice
    case "$choice" in
      1) install_node;; 2) show_status;; 3) core_update latest;; 4) tunnel_menu;;
      5) if load_state; then print_link; else warn '尚无当前节点配置'; fi;;
      6) if load_state; then print_link; else warn '尚无当前节点配置'; fi;;
      7) load_state >/dev/null 2>&1 || true; local_subscription_menu;;
      8) uninstall_all; [[ "$UNINSTALL_COMPLETED" == yes ]] && exit 0;;
      0) exit 0;; *) warn '无效选项';;
    esac
  done
}
main(){
  require_root
  select_instance
  load_modules
  core_deps
  require_commands
  if install_manager_runtime_files; then
    install_persistent_entrypoint || warn 'xhttp 快捷命令创建/修复失败；仍可使用当前脚本进入管理菜单'
    ensure_local_sub_helpers || warn '本地订阅辅助程序暂不可用；节点管理和 xhttp 快捷命令仍可使用'
  else
    warn '无法完整安装管理器运行文件；当前菜单仍可继续，但快捷命令可能不可用'
  fi
  load_state >/dev/null 2>&1 || true
  main_menu
}
main "$@"
