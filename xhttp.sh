#!/usr/bin/env bash
# ============================================================
# XHTTP Manager V4.7 - main menu / protocol configuration
# Ubuntu / Debian (systemd), Alpine (OpenRC)
# Requires core.sh and tunnel.sh from the same V4.7 release.
# ============================================================
set -Eeuo pipefail
umask 077
VERSION="4.7"
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_ID=""
XHTTP_DIR=""; CONFIG=""; STATE=""; LIB_DIR=""; XRAY_BIN=""; SERVICE_NAME=""; SERVICE_FILE=""; OPENRC_FILE=""; TUNNEL_SERVICE_NAME=""
CORE_FILE="$SELF_DIR/core.sh"; TUNNEL_FILE="$SELF_DIR/tunnel.sh"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PROTOCOL=""; DOMAIN=""; PORT=""; UUID=""; PATH_VALUE=""; SECURITY=""; TUNNEL=no
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
  if [[ ! -f "$c" || ! -f "$t" ]] || ! grep -Fq 'XHTTP_MODULE_VERSION="4.7"' "$c" || ! grep -Fq 'XHTTP_MODULE_VERSION="4.7"' "$t"; then
    c="$LIB_DIR/core.sh"; t="$LIB_DIR/tunnel.sh"
  fi
  if [[ ! -f "$c" || ! -f "$t" ]] || ! grep -Fq 'XHTTP_MODULE_VERSION="4.7"' "$c" || ! grep -Fq 'XHTTP_MODULE_VERSION="4.7"' "$t"; then
    BOOTSTRAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xhttp-bootstrap.XXXXXX")" || die '无法创建临时目录'
    trap cleanup_bootstrap EXIT
    c="$BOOTSTRAP_DIR/core.sh"; t="$BOOTSTRAP_DIR/tunnel.sh"
    download_to "$RAW_BASE_URL/core.sh" "$c" || die '下载 core.sh 失败'
    download_to "$RAW_BASE_URL/tunnel.sh" "$t" || die '下载 tunnel.sh 失败'
  fi
  [[ -f "$c" && -f "$t" ]] || die '缺少 core.sh 或 tunnel.sh'
  grep -Fq 'XHTTP_MODULE_VERSION="4.7"' "$c" || die 'core.sh 版本不匹配或不是 V4.7'
  grep -Fq 'XHTTP_MODULE_VERSION="4.7"' "$t" || die 'tunnel.sh 版本不匹配或不是 V4.7'
  CORE_FILE="$c"; TUNNEL_FILE="$t"
  # shellcheck source=/dev/null
  source "$CORE_FILE"
  # shellcheck source=/dev/null
  source "$TUNNEL_FILE"
  [[ "${CORE_MODULE_VERSION:-}" == "$VERSION" && "${TUNNEL_MODULE_VERSION:-}" == "$VERSION" ]] || die '模块版本不一致'
  trap cleanup_bootstrap EXIT
}
candidate_is_owned(){
  local id="$1" dir="/etc/$1" lib="/usr/local/lib/$1" bin="/usr/local/bin/xray-$1" svc="$1" unit="/etc/systemd/system/$1.service" init="/etc/init.d/$1"
  local marker="$dir/.xhttp-manager-instance" expected="ExecStart=$bin run -config $dir/config.json"
  # A marker alone is NOT proof that the service belongs to this manager.
  # Require the exact manager unit/command before reusing an existing instance.
  if [[ -f "$unit" ]]; then
    [[ -f "$marker" ]] && grep -Fqx "XHTTP Manager instance: $id" "$marker" \
      && grep -q 'XHTTP Manager managed service' "$unit" \
      && grep -Fqx "$expected" "$unit" && return 0
    return 1
  fi
  if [[ -f "$init" ]]; then
    [[ -f "$marker" ]] && grep -Fqx "XHTTP Manager instance: $id" "$marker" \
      && grep -q 'XHTTP Manager managed service' "$init" \
      && grep -Fq "command=\"$bin\"" "$init" \
      && grep -Fq "command_args=\"run -config $dir/config.json\"" "$init" && return 0
    return 1
  fi
  # During first-run/upgrade, an instance without a service unit may be reused
  # only when its marker and both versioned manager modules agree.
  if [[ -f "$marker" && -f "$lib/core.sh" && -f "$lib/tunnel.sh" ]] \
      && grep -Fqx "XHTTP Manager instance: $id" "$marker" \
      && grep -Fq 'XHTTP_MODULE_VERSION="4.7"' "$lib/core.sh" \
      && grep -Fq 'XHTTP_MODULE_VERSION="4.7"' "$lib/tunnel.sh"; then
    if command -v systemctl >/dev/null 2>&1; then
      local fragment
      fragment="$(systemctl show -p FragmentPath --value "$svc" 2>/dev/null || true)"
      [[ -z "$fragment" ]] || return 1
    fi
    return 0
  fi
  return 1
}
candidate_is_occupied(){
  local id="$1" dir="/etc/$1" lib="/usr/local/lib/$1" bin="/usr/local/bin/xray-$1" svc="$1" unit="/etc/systemd/system/$1.service" init="/etc/init.d/$1" tunnel_unit="/etc/systemd/system/$1-cloudflared.service" tunnel_init="/etc/init.d/$1-cloudflared"
  [[ -e "$dir" || -e "$lib" || -e "$bin" || -e "$unit" || -e "$init" || -e "$tunnel_unit" || -e "$tunnel_init" || -e "/usr/local/bin/cloudflared-$id" ]] && return 0
  if command -v systemctl >/dev/null 2>&1; then
    local frag
    frag="$(systemctl show -p FragmentPath --value "$svc" 2>/dev/null || true)"
    [[ -n "$frag" ]] && return 0
    frag="$(systemctl show -p FragmentPath --value "$id-cloudflared" 2>/dev/null || true)"
    [[ -n "$frag" ]] && return 0
  fi
  return 1
}
select_instance(){
  local n=1 id
  while (( n < 100 )); do
    if (( n == 1 )); then id=xhttp; else id="xhttp-$n"; fi
    if candidate_is_owned "$id"; then
      INSTANCE_ID="$id"; break
    elif ! candidate_is_occupied "$id"; then
      INSTANCE_ID="$id"; break
    fi
    n=$((n+1))
  done
  [[ -n "$INSTANCE_ID" ]] || die '无法找到安全的独立安装名称（已尝试 99 个实例名）'
  XHTTP_DIR="/etc/$INSTANCE_ID"; CONFIG="$XHTTP_DIR/config.json"; STATE="$XHTTP_DIR/state.json"
  LIB_DIR="/usr/local/lib/$INSTANCE_ID"; XRAY_BIN="/usr/local/bin/xray-$INSTANCE_ID"
  SERVICE_NAME="$INSTANCE_ID"; SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"; OPENRC_FILE="/etc/init.d/$SERVICE_NAME"
  TUNNEL_SERVICE_NAME="$INSTANCE_ID-cloudflared"
  export INSTANCE_ID XHTTP_DIR LIB_DIR XRAY_BIN SERVICE_NAME SERVICE_FILE OPENRC_FILE TUNNEL_SERVICE_NAME
  log "当前独立实例：$INSTANCE_ID（配置：$XHTTP_DIR；服务：$SERVICE_NAME）"
}
require_commands(){ local c; for c in curl jq openssl awk grep sed head shuf ss install mktemp; do command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c"; done; }
random_port(){ local p n=0; while ((n < 300)); do n=$((n+1)); p="$(shuf -i 20000-59999 -n 1)"; if ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$"; then printf '%s' "$p"; return 0; fi; done; die '无法找到可用端口'; }
random_path(){ printf '/%s' "$(openssl rand -hex 8)"; }
random_uuid(){ if [[ -x "$XRAY_BIN" ]]; then "$XRAY_BIN" uuid; else cat /proc/sys/kernel/random/uuid; fi; }
valid_port(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_domain(){ [[ ${#1} -le 253 && "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }
valid_ipv4(){ local ip="$1" a b c d part; [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1; IFS=. read -r a b c d <<< "$ip"; for part in "$a" "$b" "$c" "$d"; do [[ "$part" =~ ^[0-9]{1,3}$ ]] && ((10#$part <= 255)) || return 1; done; }
save_state(){
  install -d -m 0700 "$XHTTP_DIR"; local tmp; tmp="$(mktemp "$XHTTP_DIR/state.XXXXXX")" || return 1
  if ! jq -n --arg PROTOCOL "$PROTOCOL" --arg DOMAIN "$DOMAIN" --arg PORT "$PORT" --arg UUID "$UUID" --arg PATH_VALUE "$PATH_VALUE" --arg SECURITY "$SECURITY" --arg TUNNEL "$TUNNEL" --arg CERT_FILE "$CERT_FILE" --arg KEY_FILE "$KEY_FILE" --arg REALITY_PRIVATE "$REALITY_PRIVATE" --arg REALITY_PUBLIC "$REALITY_PUBLIC" --arg REALITY_SHORT_ID "$REALITY_SHORT_ID" --arg REALITY_SNI "$REALITY_SNI" '{PROTOCOL:$PROTOCOL,DOMAIN:$DOMAIN,PORT:$PORT,UUID:$UUID,PATH_VALUE:$PATH_VALUE,SECURITY:$SECURITY,TUNNEL:$TUNNEL,CERT_FILE:$CERT_FILE,KEY_FILE:$KEY_FILE,REALITY_PRIVATE:$REALITY_PRIVATE,REALITY_PUBLIC:$REALITY_PUBLIC,REALITY_SHORT_ID:$REALITY_SHORT_ID,REALITY_SNI:$REALITY_SNI}' > "$tmp"; then rm -f "$tmp"; return 1; fi
  chmod 0600 "$tmp"; mv -f "$tmp" "$STATE"
}
load_state(){
  [[ -s "$STATE" ]] && jq -e 'type=="object"' "$STATE" >/dev/null 2>&1 || { warn '尚无有效节点状态'; return 1; }
  PROTOCOL="$(jq -r '.PROTOCOL // ""' "$STATE")"; DOMAIN="$(jq -r '.DOMAIN // ""' "$STATE")"; PORT="$(jq -r '.PORT // ""' "$STATE")"; UUID="$(jq -r '.UUID // ""' "$STATE")"; PATH_VALUE="$(jq -r '.PATH_VALUE // ""' "$STATE")"; SECURITY="$(jq -r '.SECURITY // ""' "$STATE")"; TUNNEL="$(jq -r '.TUNNEL // "no"' "$STATE")"; CERT_FILE="$(jq -r '.CERT_FILE // ""' "$STATE")"; KEY_FILE="$(jq -r '.KEY_FILE // ""' "$STATE")"; REALITY_PRIVATE="$(jq -r '.REALITY_PRIVATE // ""' "$STATE")"; REALITY_PUBLIC="$(jq -r '.REALITY_PUBLIC // ""' "$STATE")"; REALITY_SHORT_ID="$(jq -r '.REALITY_SHORT_ID // ""' "$STATE")"; REALITY_SNI="$(jq -r '.REALITY_SNI // "www.microsoft.com"' "$STATE")"
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
  REALITY_PRIVATE="$(printf '%s\n' "$output" | sed -nE 's/.*(PrivateKey|Private key):[[:space:]]*([^[:space:]]+).*/\2/p' | head -n1)"
  REALITY_PUBLIC="$(printf '%s\n' "$output" | sed -nE 's/.*(Password|PublicKey|Public key):[[:space:]]*([^[:space:]]+).*/\2/p' | head -n1)"
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
      stream="$(jq -n --arg path "$PATH_VALUE" --arg private "$REALITY_PRIVATE" --arg sni "$REALITY_SNI" --arg sid "$REALITY_SHORT_ID" '{network:"xhttp",security:"reality",xhttpSettings:{path:$path,mode:"auto"},realitySettings:{show:false,dest:($sni+":443"),xver:0,serverNames:[$sni],privateKey:$private,shortIds:[$sid]}}')"
      ;;
    xhttp-tls|xhttp-tunnel)
      stream="$(jq -n --arg security "$SECURITY" --arg path "$PATH_VALUE" '{network:"xhttp",security:$security,xhttpSettings:{path:$path,mode:"auto"}}')"
      ;;
    ws-tls|ws-tunnel)
      stream="$(jq -n --arg security "$SECURITY" --arg path "$PATH_VALUE" '{network:"ws",security:$security,wsSettings:{path:$path}}')"
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
    tls_settings="$(jq -n --arg cert "$CERT_FILE" --arg key "$KEY_FILE" '{certificates:[{certificateFile:$cert,keyFile:$key}]}')"
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
  choose_protocol || return 0; ask_domain
  if [[ "$TUNNEL" == yes ]] && ! valid_domain "$DOMAIN"; then die 'Cloudflare Tunnel 必须使用域名，不能使用公网 IPv4'; fi
  PORT="$(random_port)"; UUID="$(random_uuid)"; PATH_VALUE="$(random_path)"
  CERT_FILE=''; KEY_FILE=''; REALITY_PRIVATE=''; REALITY_PUBLIC=''; REALITY_SHORT_ID=''
  [[ "$PROTOCOL" == grpc-tls ]] && PATH_VALUE=grpc
  if [[ "$SECURITY" == tls && "$TUNNEL" == no ]]; then ask_tls_files; fi
  if [[ "$TUNNEL" == yes ]]; then read -rsp 'Cloudflare Tunnel Token: ' tunnel_token; echo; [[ -n "$tunnel_token" ]] || die 'Tunnel Token 不能为空'; fi
  core_install latest
  build_config
  core_validate
  core_service_install
  if [[ "$TUNNEL" == yes ]]; then tunnel_install "$tunnel_token"; tunnel_configure_http "$DOMAIN" "$PORT"; fi
  save_state; print_link; ok '安装流程完成'
}

print_link(){
  local link='' link_port="$PORT"
  [[ "$TUNNEL" == yes ]] && link_port=443
  case "$PROTOCOL" in
    xhttp-reality) link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=reality&pbk=${REALITY_PUBLIC}&fp=chrome&sid=${REALITY_SHORT_ID}&sni=${REALITY_SNI}&type=xhttp&path=${PATH_VALUE}&mode=auto#XHTTP-REALITY";;
    xhttp-tls|xhttp-tunnel) link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=tls&sni=${DOMAIN}&type=xhttp&path=${PATH_VALUE}&mode=auto#XHTTP-TLS";;
    ws-tls|ws-tunnel) link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${PATH_VALUE}#WS-TLS";;
    grpc-tls) link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=tls&sni=${DOMAIN}&type=grpc&serviceName=grpc#GRPC-TLS";;
    httpupgrade-tls) link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=tls&sni=${DOMAIN}&type=httpupgrade&path=${PATH_VALUE}#HTTPUpgrade-TLS";;
    *) die '无法生成节点链接';;
  esac
  echo; echo '========== 节点信息 =========='; echo "协议：$PROTOCOL"; echo "地址：$DOMAIN"; echo "公网端口：$link_port"; [[ "$TUNNEL" == yes ]] && echo "Xray 本地端口：$PORT"; echo "UUID：$UUID"; echo "路径/服务名：$PATH_VALUE"
  if [[ "$PROTOCOL" == xhttp-reality ]]; then echo "REALITY SNI：$REALITY_SNI"; echo "REALITY 公钥：$REALITY_PUBLIC"; echo "REALITY Short ID：$REALITY_SHORT_ID"; fi
  echo; printf '%s\n' "$link"; echo '=============================='
}
show_status(){
  echo; echo '========== XHTTP 状态 =========='
  if [[ -x "$XRAY_BIN" ]]; then "$XRAY_BIN" version | head -n2; else echo '专用 Xray 尚未安装'; fi
  core_os || return 0
  if [[ "$OS_FAMILY" == systemd ]]; then systemctl --no-pager --full status "$SERVICE_NAME" 2>/dev/null | head -n12 || true; else rc-service "$SERVICE_NAME" status 2>/dev/null || true; fi
  tunnel_status || true
}
uninstall_all(){
  local confirm; echo; warn '只卸载本项目管理的 XHTTP 服务、专用二进制和配置，不操作系统其他 Xray/Tunnel。'; read -rp '确认卸载 XHTTP？输入 YES 继续: ' confirm; [[ "$confirm" == YES ]] || return 0
  core_os || die '无法识别系统，已取消卸载'
  core_check_service_owner || die '检测到非本项目 XHTTP 服务，已取消卸载；未删除任何文件'
  tunnel_os || die '无法识别系统，已取消卸载'
  tunnel_check_owner || die '检测到非本项目 Cloudflare Tunnel 服务，已取消卸载；未删除任何文件'
  core_service_stop || die '停止 XHTTP 服务失败，已取消卸载'
  tunnel_uninstall || die '卸载 Cloudflare Tunnel 失败'
  rm -f "$XRAY_BIN" "$XHTTP_DIR/config.json" "$XHTTP_DIR/state.json" "$XHTTP_DIR/xray.version" "$XHTTP_DIR/cloudflare-token" "$XHTTP_DIR/.xhttp-manager-instance"
  remove_persistent_entrypoint
  rm -f "$LIB_DIR/core.sh" "$LIB_DIR/tunnel.sh" "$LIB_DIR/cloudflared-run.sh"; rmdir "$LIB_DIR" 2>/dev/null || true
  # Remove remaining project-owned state only; leave directory if unrelated files exist.
  rmdir "$XHTTP_DIR" 2>/dev/null || true
  ok '本项目服务和专用文件已清理；未删除通用 xray 或其他 Tunnel'
}
install_modules(){
  install -d -m 0755 "$LIB_DIR"
  install -d -m 0700 "$XHTTP_DIR"
  local t1 t2; t1="$(mktemp "$LIB_DIR/core.XXXXXX")"; t2="$(mktemp "$LIB_DIR/tunnel.XXXXXX")"
  if ! install -m 0644 "$CORE_FILE" "$t1" || ! install -m 0644 "$TUNNEL_FILE" "$t2"; then rm -f "$t1" "$t2"; die '安装模块失败'; fi
  mv -f "$t1" "$LIB_DIR/core.sh"; mv -f "$t2" "$LIB_DIR/tunnel.sh"
  if [[ -e "$XHTTP_DIR/.xhttp-manager-instance" ]] && ! grep -Fqx "XHTTP Manager instance: $INSTANCE_ID" "$XHTTP_DIR/.xhttp-manager-instance"; then
    die "实例标记冲突：$XHTTP_DIR/.xhttp-manager-instance；拒绝覆盖"
  fi
  printf 'XHTTP Manager instance: %s\n' "$INSTANCE_ID" > "$XHTTP_DIR/.xhttp-manager-instance"
  chmod 0600 "$XHTTP_DIR/.xhttp-manager-instance"
}
install_persistent_entrypoint(){
  local tmp="$LIB_DIR/xhttp.sh.tmp.$$" launcher="/usr/local/bin/xhttp" launcher_tmp="/usr/local/bin/.xhttp-launcher.$$" source_file=""
  # Prefer the published main script (the one-line curl/wget bootstrap may be /dev/fd).
  if download_to "$RAW_BASE_URL/xhttp.sh" "$tmp" && grep -Fqx 'VERSION="4.7"' "$tmp"; then
    source_file="$tmp"
  elif [[ -r "$SELF_DIR/xhttp.sh" ]] && grep -Fqx 'VERSION="4.7"' "$SELF_DIR/xhttp.sh"; then
    source_file="$SELF_DIR/xhttp.sh"
  else
    rm -f -- "$tmp"
    warn '无法取得与当前版本一致的 xhttp.sh，暂不创建快捷命令；上传 V4.7 三个文件后重新运行即可'
    return 0
  fi
  install -m 0700 "$source_file" "$LIB_DIR/xhttp.sh" || { rm -f -- "$tmp"; warn '保存管理主程序失败'; return 0; }
  rm -f -- "$tmp"
  if [[ -e "$launcher" || -L "$launcher" ]]; then
    if grep -Fq '# XHTTP Manager managed launcher' "$launcher" \
       && grep -Fqx "exec /usr/bin/env bash $LIB_DIR/xhttp.sh \"\$@\"" "$launcher"; then
      : # already our launcher for this exact instance
    else
      warn "$launcher 已存在且不是本实例创建的快捷命令，为避免覆盖其他程序，未修改它"
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
remove_persistent_entrypoint(){
  local launcher="/usr/local/bin/xhttp"
  if [[ -f "$launcher" ]] \
      && grep -Fq '# XHTTP Manager managed launcher' "$launcher" \
      && grep -Fqx "exec /usr/bin/env bash $LIB_DIR/xhttp.sh \"\$@\"" "$launcher"; then
    rm -f -- "$launcher"
  fi
  rm -f -- "$LIB_DIR/xhttp.sh" "$LIB_DIR/xhttp.sh.tmp."*
}
main_menu(){
  local choice
  while true; do
    echo; echo '===================================='; echo "       XHTTP Manager V${VERSION}"; echo '===================================='; echo '1. 安装 / 配置节点'; echo '2. 查看运行状态'; echo '3. 更新 Xray 内核'; echo '4. Cloudflare Tunnel 管理'; echo '5. 查看当前节点信息'; echo '6. 卸载 XHTTP 服务及配置'; echo '0. 退出'; echo '===================================='
    read -rp '请选择: ' choice
    case "$choice" in 1) install_node;; 2) show_status;; 3) core_update latest;; 4) tunnel_menu;; 5) if load_state; then print_link; else warn '尚无节点配置'; fi;; 6) uninstall_all;; 0) exit 0;; *) warn '无效选项';; esac
  done
}
main(){ require_root; select_instance; load_modules; core_deps; require_commands; install_modules; install_persistent_entrypoint; main_menu; }
main "$@"
