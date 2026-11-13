#!/usr/bin/env bash
# XHTTP Manager V5.0 - Ubuntu / Debian / Alpine
set -Eeuo pipefail
VERSION=5.0
XHTTP_DIR=/etc/xhttp
CONFIG="$XHTTP_DIR/config.json"
STATE="$XHTTP_DIR/state.json"
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR=/usr/local/lib/xhttp
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
PROTOCOL= DOMAIN= PORT= UUID= PATH_VALUE= SECURITY= TUNNEL=no CERT_FILE= KEY_FILE=
REALITY_PRIVATE= REALITY_PUBLIC= REALITY_SHORT_ID= REALITY_SNI=www.microsoft.com
log(){ printf "${CYAN}[XHTTP]${NC} %s\n" "$*"; }
ok(){ printf "${GREEN}[成功]${NC} %s\n" "$*"; }
warn(){ printf "${YELLOW}[提示]${NC} %s\n" "$*"; }
err(){ printf "${RED}[错误]${NC} %s\n" "$*" >&2; }
die(){ err "$*"; exit 1; }
require_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die '请使用 root 用户运行'; }
load_modules(){
  local c="$SELF_DIR/core.sh" t="$SELF_DIR/tunnel.sh"
  if [[ ! -f "$c" || ! -f "$t" ]]; then c="$LIB_DIR/core.sh"; t="$LIB_DIR/tunnel.sh"; fi
  [[ -f "$c" && -f "$t" ]] || die '缺少 core.sh 或 tunnel.sh，请把三个文件放在同一目录'
  # shellcheck source=/dev/null
  source "$c"; source "$t"
  install -d -m 0755 "$LIB_DIR"
  install -m 0644 "$c" "$LIB_DIR/core.sh"
  install -m 0644 "$t" "$LIB_DIR/tunnel.sh"
}
require_commands(){ local x; for x in curl jq openssl awk grep sed head shuf base64 ss; do command -v "$x" >/dev/null 2>&1 || die "缺少命令：$x"; done; }
random_port(){
  local p i
  for ((i=0;i<300;i++)); do
    p="$(shuf -i 20000-59999 -n 1)"
    if ! ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$"; then printf '%s' "$p"; return 0; fi
  done
  die '无法找到空闲端口'
}
random_path(){ printf '/%s' "$(openssl rand -hex 8)"; }
random_uuid(){ if [[ -x "$XRAY_BIN" ]]; then "$XRAY_BIN" uuid; else cat /proc/sys/kernel/random/uuid; fi; }
valid_port(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1>=1 && 10#$1<=65535)); }
valid_domain(){ [[ ${#1} -le 253 && "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }
valid_ipv4(){
  local ip="$1" a b c d part
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r a b c d <<< "$ip"
  for part in "$a" "$b" "$c" "$d"; do [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1; ((10#$part<=255)) || return 1; done
}
get_public_ip(){ curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || true; }
ask_domain(){
  local ip; ip="$(get_public_ip)"
  echo; [[ -n "$ip" ]] && echo "检测到公网 IPv4：$ip"
  read -rp '连接域名或公网 IPv4（留空使用检测值）：' DOMAIN
  [[ -n "$DOMAIN" ]] || DOMAIN="$ip"
  [[ -n "$DOMAIN" ]] || die '未检测到公网 IP，请手动输入'
  valid_domain "$DOMAIN" || valid_ipv4 "$DOMAIN" || die '域名或 IPv4 格式不正确'
}
ask_tls_files(){
  read -rp 'TLS 证书完整路径：' CERT_FILE
  read -rp 'TLS 私钥完整路径：' KEY_FILE
  [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || die '证书或私钥文件不存在'
  openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1 || die 'TLS 证书格式不正确'
  openssl pkey -in "$KEY_FILE" -noout >/dev/null 2>&1 || die 'TLS 私钥格式不正确'
}
choose_protocol(){
  echo; echo '========== 选择协议 =========='
  echo '1. VLESS + XHTTP + REALITY'; echo '2. VLESS + XHTTP + TLS'; echo '3. VLESS + XHTTP + Cloudflare Tunnel'
  echo '4. VLESS + WS + TLS'; echo '5. VLESS + WS + Cloudflare Tunnel'; echo '6. VLESS + gRPC + TLS'; echo '7. VLESS + HTTPUpgrade + TLS'; echo '0. 返回'
  read -rp '请选择：' choice
  case "$choice" in
    1) PROTOCOL=xhttp-reality; SECURITY=reality; TUNNEL=no ;;
    2) PROTOCOL=xhttp-tls; SECURITY=tls; TUNNEL=no ;;
    3) PROTOCOL=xhttp-tunnel; SECURITY=none; TUNNEL=yes ;;
    4) PROTOCOL=ws-tls; SECURITY=tls; TUNNEL=no ;;
    5) PROTOCOL=ws-tunnel; SECURITY=none; TUNNEL=yes ;;
    6) PROTOCOL=grpc-tls; SECURITY=tls; TUNNEL=no ;;
    7) PROTOCOL=httpupgrade-tls; SECURITY=tls; TUNNEL=no ;;
    0) return 1 ;;
    *) warn '无效选择'; return 1 ;;
  esac
}
make_reality_keys(){
  local out
  out="$("$XRAY_BIN" x25519 2>&1)" || { printf '%s\n' "$out"; die 'REALITY 密钥生成失败'; }
  REALITY_PRIVATE="$(printf '%s\n' "$out" | sed -nE 's/.*Private(Key| key):[[:space:]]*([^[:space:]]+).*/\2/p' | head -n1)"
  REALITY_PUBLIC="$(printf '%s\n' "$out" | sed -nE 's/.*(Password|PublicKey|Public key):[[:space:]]*([^[:space:]]+).*/\2/p' | head -n1)"
  [[ -n "$REALITY_PRIVATE" && -n "$REALITY_PUBLIC" ]] || { printf '%s\n' "$out"; die '无法解析 Xray REALITY 密钥输出'; }
  REALITY_SHORT_ID="$(openssl rand -hex 4)"
}
build_config(){
  local stream inbound listen_addr=0.0.0.0 tls='{}'
  [[ "$TUNNEL" == yes ]] && listen_addr=127.0.0.1
  case "$PROTOCOL" in
    xhttp-reality)
      make_reality_keys
      stream="$(jq -n --arg path "$PATH_VALUE" --arg pk "$REALITY_PRIVATE" --arg sni "$REALITY_SNI" --arg sid "$REALITY_SHORT_ID" '{network:"xhttp",security:"reality",xhttpSettings:{path:$path,mode:"auto"},realitySettings:{show:false,dest:($sni+":443"),xver:0,serverNames:[$sni],privateKey:$pk,shortIds:[$sid]}}')" ;;
    xhttp-tls|xhttp-tunnel)
      stream="$(jq -n --arg sec "$SECURITY" --arg path "$PATH_VALUE" '{network:"xhttp",security:$sec,xhttpSettings:{path:$path,mode:"auto"}}')" ;;
    ws-tls|ws-tunnel)
      stream="$(jq -n --arg sec "$SECURITY" --arg path "$PATH_VALUE" '{network:"ws",security:$sec,wsSettings:{path:$path}}')" ;;
    grpc-tls) PATH_VALUE=grpc; stream='{"network":"grpc","security":"tls","grpcSettings":{"serviceName":"grpc"}}' ;;
    httpupgrade-tls)
      stream="$(jq -n --arg path "$PATH_VALUE" '{network:"httpupgrade",security:"tls",httpupgradeSettings:{path:$path}}')" ;;
    *) die "未知协议：$PROTOCOL" ;;
  esac
  if [[ "$SECURITY" == tls && "$TUNNEL" == no ]]; then
    tls="$(jq -n --arg cert "$CERT_FILE" --arg key "$KEY_FILE" '{certificates:[{certificateFile:$cert,keyFile:$key}]}')"
  fi
  inbound="$(jq -n --arg listen "$listen_addr" --argjson port "$PORT" --arg uuid "$UUID" --argjson stream "$stream" --argjson tls "$tls" '{listen:$listen,port:$port,protocol:"vless",settings:{clients:[{id:$uuid}],decryption:"none"},streamSettings:($stream+(if $stream.security=="tls" then {tlsSettings:$tls} else {} end)),sniffing:{enabled:true,destOverride:["http","tls"]}}')"
  install -d -m 0700 "$XHTTP_DIR"
  jq -n --argjson inbound "$inbound" '{log:{loglevel:"warning"},inbounds:[$inbound],outbounds:[{protocol:"freedom",tag:"direct"}]}' > "$CONFIG"
  chmod 0600 "$CONFIG"
}
save_state(){
  local tmp; tmp="$(mktemp "$XHTTP_DIR/state.XXXXXX")"
  jq -n --arg PROTOCOL "$PROTOCOL" --arg DOMAIN "$DOMAIN" --arg PORT "$PORT" --arg UUID "$UUID" --arg PATH_VALUE "$PATH_VALUE" --arg SECURITY "$SECURITY" --arg TUNNEL "$TUNNEL" --arg CERT_FILE "$CERT_FILE" --arg KEY_FILE "$KEY_FILE" --arg REALITY_PRIVATE "$REALITY_PRIVATE" --arg REALITY_PUBLIC "$REALITY_PUBLIC" --arg REALITY_SHORT_ID "$REALITY_SHORT_ID" --arg REALITY_SNI "$REALITY_SNI" '{PROTOCOL:$PROTOCOL,DOMAIN:$DOMAIN,PORT:$PORT,UUID:$UUID,PATH_VALUE:$PATH_VALUE,SECURITY:$SECURITY,TUNNEL:$TUNNEL,CERT_FILE:$CERT_FILE,KEY_FILE:$KEY_FILE,REALITY_PRIVATE:$REALITY_PRIVATE,REALITY_PUBLIC:$REALITY_PUBLIC,REALITY_SHORT_ID:$REALITY_SHORT_ID,REALITY_SNI:$REALITY_SNI}' > "$tmp"
  chmod 0600 "$tmp"; mv -f "$tmp" "$STATE"
}
load_state(){
  [[ -s "$STATE" ]] || return 1
  jq -e 'type=="object"' "$STATE" >/dev/null 2>&1 || { warn 'state.json 格式错误'; return 1; }
  PROTOCOL="$(jq -r '.PROTOCOL // empty' "$STATE")"; DOMAIN="$(jq -r '.DOMAIN // empty' "$STATE")"; PORT="$(jq -r '.PORT // empty' "$STATE")"; UUID="$(jq -r '.UUID // empty' "$STATE")"; PATH_VALUE="$(jq -r '.PATH_VALUE // empty' "$STATE")"; SECURITY="$(jq -r '.SECURITY // empty' "$STATE")"; TUNNEL="$(jq -r '.TUNNEL // "no"' "$STATE")"; CERT_FILE="$(jq -r '.CERT_FILE // empty' "$STATE")"; KEY_FILE="$(jq -r '.KEY_FILE // empty' "$STATE")"; REALITY_PRIVATE="$(jq -r '.REALITY_PRIVATE // empty' "$STATE")"; REALITY_PUBLIC="$(jq -r '.REALITY_PUBLIC // empty' "$STATE")"; REALITY_SHORT_ID="$(jq -r '.REALITY_SHORT_ID // empty' "$STATE")"; REALITY_SNI="$(jq -r '.REALITY_SNI // "www.microsoft.com"' "$STATE")"
  [[ -n "$PROTOCOL" && -n "$DOMAIN" && -n "$PORT" && -n "$UUID" ]]
}
print_link(){
  local p="$PORT" link
  [[ "$TUNNEL" == yes ]] && p=443
  case "$PROTOCOL" in
    xhttp-reality) link="vless://${UUID}@${DOMAIN}:${p}?encryption=none&security=reality&pbk=${REALITY_PUBLIC}&fp=chrome&sid=${REALITY_SHORT_ID}&sni=${REALITY_SNI}&type=xhttp&path=${PATH_VALUE}&mode=auto#XHTTP-REALITY" ;;
    xhttp-tls|xhttp-tunnel) link="vless://${UUID}@${DOMAIN}:${p}?encryption=none&security=tls&sni=${DOMAIN}&type=xhttp&path=${PATH_VALUE}&mode=auto#XHTTP-TLS" ;;
    ws-tls|ws-tunnel) link="vless://${UUID}@${DOMAIN}:${p}?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${PATH_VALUE}#WS-TLS" ;;
    grpc-tls) link="vless://${UUID}@${DOMAIN}:${p}?encryption=none&security=tls&sni=${DOMAIN}&type=grpc&serviceName=grpc#GRPC-TLS" ;;
    httpupgrade-tls) link="vless://${UUID}@${DOMAIN}:${p}?encryption=none&security=tls&sni=${DOMAIN}&type=httpupgrade&path=${PATH_VALUE}#HTTPUpgrade-TLS" ;;
    *) die '当前状态无法生成节点链接' ;;
  esac
  echo; echo '========== 节点信息 =========='; echo "协议：$PROTOCOL"; echo "地址：$DOMAIN"; echo "端口：$p"; [[ "$TUNNEL" == yes ]] && echo "Xray 本地端口：$PORT"; echo "UUID：$UUID"; echo "路径/服务名：$PATH_VALUE"; [[ "$PROTOCOL" == xhttp-reality ]] && { echo "REALITY SNI：$REALITY_SNI"; echo "REALITY 公钥：$REALITY_PUBLIC"; echo "Short ID：$REALITY_SHORT_ID"; }; echo; printf '%s\n' "$link"; echo '=============================='
}
install_node(){
  local token=''
  choose_protocol || return 0
  ask_domain
  PORT="$(random_port)"; UUID="$(random_uuid)"; PATH_VALUE="$(random_path)"
  CERT_FILE= KEY_FILE= REALITY_PRIVATE= REALITY_PUBLIC= REALITY_SHORT_ID=
  [[ "$PROTOCOL" == grpc-tls ]] && PATH_VALUE=grpc
  if [[ "$SECURITY" == tls && "$TUNNEL" == no ]]; then ask_tls_files; fi
  if [[ "$TUNNEL" == yes ]]; then read -rsp 'Cloudflare Tunnel Token：' token; echo; [[ -n "$token" ]] || die 'Token 不能为空'; fi
  core_deps
  core_install latest
  build_config
  core_validate
  core_service_install
  if [[ "$TUNNEL" == yes ]]; then
    if ! tunnel_install "$token"; then warn 'Tunnel 安装失败；Xray 服务已启动，可进入 Tunnel 管理重新绑定 Token'; fi
    tunnel_configure_http "$DOMAIN" "$PORT"
  fi
  save_state
  print_link
  ok '安装流程完成'
}
show_status(){
  echo; echo '========== XHTTP 状态 =========='
  [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version | head -n 2 || echo '独立 Xray 尚未安装'
  core_service_status 2>/dev/null || true
  tunnel_status || true
}
uninstall_all(){
  local answer
  warn '只删除本脚本创建的 xhttp 服务、Tunnel 服务及 /etc/xhttp 配置。'
  read -rp '确认卸载？输入 YES：' answer
  [[ "$answer" == YES ]] || return 0
  core_service_stop || true
  tunnel_uninstall || true
  rm -rf "$XHTTP_DIR"
  rm -f "$LIB_DIR/core.sh" "$LIB_DIR/tunnel.sh"
  rmdir "$LIB_DIR" 2>/dev/null || true
  # Dedicated binary only; never touch /usr/local/bin/xray.
  rm -f "$XRAY_BIN"
  ok '本脚本管理的 XHTTP/Tunnel 已卸载；其他 Xray/cloudflared 服务未触碰'
}
main_menu(){
  local choice
  while true; do
    echo; echo '================================'; echo "       XHTTP Manager V$VERSION"; echo '================================'
    echo '1. 安装 / 配置节点'; echo '2. 查看运行状态'; echo '3. 更新 Xray 内核'; echo '4. Cloudflare Tunnel 管理'; echo '5. 查看当前节点信息'; echo '6. 卸载本脚本服务'; echo '0. 退出'
    read -rp '请选择：' choice
    case "$choice" in
      1) install_node ;;
      2) show_status ;;
      3) core_update latest ;;
      4) tunnel_menu ;;
      5) load_state && print_link || warn '尚无可用节点配置' ;;
      6) uninstall_all ;;
      0) exit 0 ;;
      *) warn '无效选项' ;;
    esac
  done
}
main(){
  require_root
  load_modules
  core_deps
  require_commands
  main_menu
}
main "$@"
