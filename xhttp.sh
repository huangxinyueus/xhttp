#!/usr/bin/env bash
# XHTTP Manager V4 - main menu / protocol config / install / uninstall
set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Installed copies keep modules beside the launcher in /usr/local/lib/xhttp.
if [[ -f "$SELF_DIR/core.sh" ]]; then
  MODULE_DIR="$SELF_DIR"
elif [[ -f /usr/local/lib/xhttp/core.sh ]]; then
  MODULE_DIR=/usr/local/lib/xhttp
else
  echo "找不到 core.sh。请将 xhttp.sh、core.sh、tunnel.sh 放在同一目录。" >&2
  exit 1
fi

source "$MODULE_DIR/core.sh"
source "$MODULE_DIR/tunnel.sh"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

CONFIG="$XHTTP_DIR/config.json"
STATE="$XHTTP_DIR/state"

mkdir -p "$XHTTP_DIR"

[[ $EUID -eq 0 ]] || {
  echo "请使用 root 运行"
  exit 1
}

# state is sourced only after validating that it is a root-owned local file.
load_state() {
  if [[ -f "$STATE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE"
  else
    PROTO="xhttp-reality"
    DOMAIN=""
    PORT=""
    UUID="$(cat /proc/sys/kernel/random/uuid)"
    PATH_ID="$(openssl rand -hex 12 2>/dev/null || date +%s)"
    CERT_FILE=""
    KEY_FILE=""
    REALITY_DEST="www.microsoft.com:443"
    REALITY_SNI="www.microsoft.com"
    REALITY_SHORT="$(openssl rand -hex 4 2>/dev/null || echo 01234567)"
    REALITY_PUBLIC=""
    TUNNEL_HOST=""
    TUNNEL_TOKEN=""
  fi
}

save_state() {
  umask 077

  cat > "$STATE" <<EOF
PROTO=$(printf %q "$PROTO")
DOMAIN=$(printf %q "$DOMAIN")
PORT=$(printf %q "$PORT")
UUID=$(printf %q "$UUID")
PATH_ID=$(printf %q "$PATH_ID")
CERT_FILE=$(printf %q "$CERT_FILE")
KEY_FILE=$(printf %q "$KEY_FILE")
REALITY_DEST=$(printf %q "$REALITY_DEST")
REALITY_SNI=$(printf %q "$REALITY_SNI")
REALITY_SHORT=$(printf %q "$REALITY_SHORT")
REALITY_PUBLIC=$(printf %q "${REALITY_PUBLIC:-}")
TUNNEL_HOST=$(printf %q "$TUNNEL_HOST")
EOF
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] &&
    (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

random_port() {
  local p

  while :; do
    p=$((20000 + RANDOM % 40000))

    if ! ss -lnt 2>/dev/null |
      awk '{print $4}' |
      grep -Eq "[:.]${p}$"; then
      echo "$p"
      return
    fi
  done
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少命令 $1"
    return 1
  }
}

ask_domain() {
  read -rp "域名（没有域名直接回车，公网 IP/REALITY 可跳过）: " DOMAIN
}

protocol_menu() {
  echo
  echo "选择协议（全部使用 Xray-core）"

  echo "1) VLESS + XHTTP + REALITY（VPS 直连）"
  echo "2) VLESS + XHTTP + TLS（自备证书直连）"
  echo "3) VLESS + XHTTP + TLS（Cloudflare Tunnel TLS 终止）"
  echo "4) VLESS + WS + TLS（自备证书直连）"
  echo "5) VLESS + WS + TLS（Cloudflare Tunnel）"
  echo "6) VLESS + gRPC + TLS（自备证书直连）"
  echo "7) VLESS + HTTPUpgrade + TLS（自备证书直连）"

  read -rp "编号 [1-7]: " n

  case "$n" in
    1) PROTO=xhttp-reality ;;
    2) PROTO=xhttp-tls ;;
    3) PROTO=xhttp-tunnel ;;
    4) PROTO=ws-tls ;;
    5) PROTO=ws-tunnel ;;
    6) PROTO=grpc-tls ;;
    7) PROTO=httpupgrade-tls ;;
    *)
      echo "无效选择"
      return 1
      ;;
  esac

  read -rp "服务端口（回车随机）: " p

  if [[ -z "$p" ]]; then
    PORT="$(random_port)"
  elif valid_port "$p"; then
    PORT="$p"
  else
    echo "端口无效"
    return 1
  fi

  read -rp "UUID（回车自动生成）: " u

  [[ -n "$u" ]] &&
    UUID="$u" ||
    UUID="$(cat /proc/sys/kernel/random/uuid)"

  read -rp "传输路径（回车随机）: " pth

  [[ -n "$pth" ]] &&
    PATH_ID="${pth#/}" ||
    PATH_ID="$(openssl rand -hex 12)"

  if [[ "$PROTO" == *tls || "$PROTO" == *tunnel ]]; then
    ask_domain
  fi

  if [[ "$PROTO" == *tls && "$PROTO" != *tunnel ]]; then
    [[ -n "$DOMAIN" ]] || {
      echo "TLS 直连必须填写域名"
      return 1
    }

    read -rp "证书 fullchain 路径: " CERT_FILE
    read -rp "私钥路径: " KEY_FILE
  fi

  if [[ "$PROTO" == xhttp-reality ]]; then
    read -rp "REALITY 目标（默认 www.microsoft.com:443）: " v

    [[ -n "$v" ]] && REALITY_DEST="$v"

    REALITY_SNI="${REALITY_DEST%:*}"

    read -rp "REALITY SNI（默认 $REALITY_SNI）: " v

    [[ -n "$v" ]] && REALITY_SNI="$v"
  fi

  if [[ "$PROTO" == *tunnel ]]; then
    [[ -n "$DOMAIN" ]] || {
      echo "Tunnel 必须填写已在 Cloudflare 配置的公网主机名"
      return 1
    }

    read -rsp "Cloudflare Tunnel Token（输入不回显）: " TUNNEL_TOKEN
    echo

    TUNNEL_HOST="$DOMAIN"
  fi

  save_state

  echo "配置已保存：$PROTO，端口 $PORT"
}

write_config() {
  local network security stream cert key

  network=xhttp

  [[ "$PROTO" == ws-* ]] && network=ws
  [[ "$PROTO" == grpc-tls ]] && network=grpc
  [[ "$PROTO" == httpupgrade-tls ]] && network=httpupgrade

  security=none

  local listen_addr="0.0.0.0"

  [[ "$PROTO" == *tunnel ]] && listen_addr="127.0.0.1"

  if [[ "$PROTO" == xhttp-reality ]]; then
    cat > "$CONFIG" <<EOF
{
 "log":{"loglevel":"warning"},
 "inbounds":[{"listen":"$listen_addr","port":$PORT,"protocol":"vless",
 "settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},
 "streamSettings":{"network":"xhttp","security":"reality",
 "realitySettings":{"show":false,"dest":"$REALITY_DEST","xver":0,"serverNames":["$REALITY_SNI"],"privateKey":"__REALITY_PRIVATE_KEY__","shortIds":["$REALITY_SHORT"]},
 "xhttpSettings":{"path":"/$PATH_ID","mode":"auto"}}}],
 "outbounds":[{"protocol":"freedom"}]
}
EOF

    echo "注意：REALITY 私钥尚未生成，下面安装步骤会自动生成并写入。"
    return
  fi

  if [[ "$PROTO" == *tunnel ]]; then
    security=none
  else
    [[ -r "$CERT_FILE" && -r "$KEY_FILE" ]] || {
      echo "证书或私钥不存在/不可读"
      return 1
    }

    security=tls
  fi

  local transport_json

  case "$network" in
    xhttp)
      transport_json='"xhttpSettings":{"path":"/'"$PATH_ID"'","mode":"auto"}'
      ;;
    ws)
      transport_json='"wsSettings":{"path":"/'"$PATH_ID"'","headers":{"Host":"'"$DOMAIN"'"}}'
      ;;
    grpc)
      transport_json='"grpcSettings":{"serviceName":"'"$PATH_ID"'"}'
      ;;
    httpupgrade)
      transport_json='"httpupgradeSettings":{"path":"/'"$PATH_ID"'","host":"'"$DOMAIN"'"}'
      ;;
  esac

  if [[ "$security" == tls ]]; then
    stream='"network":"'"$network"'","security":"tls","tlsSettings":{"certificates":[{"certificateFile":"'"$CERT_FILE"'","keyFile":"'"$KEY_FILE"'"}]},'"$transport_json"
  else
    stream='"network":"'"$network"'","security":"none",'"$transport_json"
  fi

  cat > "$CONFIG" <<EOF
{
 "log":{"loglevel":"warning"},
 "inbounds":[{"listen":"$listen_addr","port":$PORT,"protocol":"vless",
 "settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},
 "streamSettings":{$stream}}],
 "outbounds":[{"protocol":"freedom"}]
}
EOF
}

setup_reality_key() {
  local keys priv pub

  keys="$("$XRAY_BIN" x25519)"

  priv="$(printf '%s\n' "$keys" |
    awk -F': ' '/Private key/{print $2}')"

  pub="$(printf '%s\n' "$keys" |
    awk -F': ' '/Public key/{print $2}')"

  [[ -n "$priv" && -n "$pub" ]] || {
    echo "无法生成 REALITY 密钥"
    return 1
  }

  sed -i "s|__REALITY_PRIVATE_KEY__|$priv|" "$CONFIG"

  REALITY_PUBLIC="$pub"

  save_state
}

open_firewall() {
  local p="$1"

  if command -v ufw >/dev/null 2>&1 &&
    ufw status 2>/dev/null | grep -q active; then

    ufw allow "$p"/tcp || true

  elif command -v firewall-cmd >/dev/null 2>&1; then

    firewall-cmd --permanent --add-port="$p"/tcp &&
      firewall-cmd --reload || true

  elif command -v iptables >/dev/null 2>&1; then

    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null ||
      iptables -I INPUT -p tcp --dport "$p" -j ACCEPT

  fi
}

install_node() {
  core_os

  core_install latest

  if [[ "$PROTO" == *tunnel ]]; then

    # Cloudflare terminates public TLS and forwards HTTP to local Xray.
    PORT="${PORT:-$(random_port)}"

    write_config

    tunnel_install "$TUNNEL_TOKEN"

    tunnel_configure_http "$TUNNEL_HOST" "$PORT"

  else

    write_config

    if [[ "$PROTO" == xhttp-reality ]]; then
      setup_reality_key
    fi

    open_firewall "$PORT"

  fi

  core_validate

  core_service_install

  install -d -m 0755 /usr/local/lib/xhttp

  install -m 0755 "$SELF_DIR/xhttp.sh" /usr/local/bin/xhttp

  install -m 0644 "$MODULE_DIR/core.sh" /usr/local/lib/xhttp/core.sh

  install -m 0644 "$MODULE_DIR/tunnel.sh" /usr/local/lib/xhttp/tunnel.sh

  save_state

  echo
  echo -e "${GREEN}安装完成。服务状态：${RESET}"

  core_status

  print_link
}

print_link() {
  local addr security q

  addr="$DOMAIN"

  [[ -z "$addr" ]] &&
    addr="$(curl -4fsS --max-time 5 https://api.ipify.org || echo VPS_PUBLIC_IP)"

  security=tls

  [[ "$PROTO" == xhttp-reality ]] && security=reality

  [[ "$PROTO" == *tunnel ]] && addr="$TUNNEL_HOST"

  case "$PROTO" in

    xhttp-reality)
      q="encryption=none&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$REALITY_PUBLIC&sid=$REALITY_SHORT&type=xhttp&path=%2F$PATH_ID&mode=auto"
      ;;

    xhttp*)
      q="encryption=none&security=$security&sni=$DOMAIN&type=xhttp&host=$DOMAIN&path=%2F$PATH_ID&mode=auto"
      ;;

    ws*)
      q="encryption=none&security=tls&sni=$DOMAIN&type=ws&host=$DOMAIN&path=%2F$PATH_ID"
      ;;

    grpc*)
      q="encryption=none&security=tls&sni=$DOMAIN&type=grpc&serviceName=$PATH_ID"
      ;;

    httpupgrade*)
      q="encryption=none&security=tls&sni=$DOMAIN&type=httpupgrade&host=$DOMAIN&path=%2F$PATH_ID"
      ;;

  esac

  local outport="$PORT"

  [[ "$PROTO" == *tunnel ]] && outport=443

  echo "节点链接："

  echo "vless://${UUID}@${addr}:${outport}?${q}#XHTTP-Manager"

  [[ "$PROTO" == xhttp-reality ]] &&
    echo "REALITY 公钥：${REALITY_PUBLIC:-请重新安装/生成密钥}"
}

core_status() {
  core_os

  if [[ "$OS_FAMILY" == systemd ]]; then
    systemctl --no-pager --full status xhttp 2>/dev/null |
      head -n12 || true
  else
    rc-service xhttp status 2>/dev/null || true
  fi
}

kernel_menu() {
  echo "1) 更新到最新版  2) 指定版本"

  read -rp "选择: " c

  case "$c" in
    1)
      core_update latest
      ;;
    2)
      read -rp "版本号（例如 26.1.0）: " v
      core_update "$v"
      ;;
    *)
      return
      ;;
  esac
}

uninstall_all() {
  echo "将删除本脚本创建的 Xray 服务、配置和模块；不会卸载系统公共依赖。"

  read -rp "确认彻底卸载？输入 YES: " c

  [[ "$c" == YES ]] || {
    echo "已取消"
    return
  }

  core_service_stop

  tunnel_uninstall

  rm -f "$XRAY_BIN" /usr/local/bin/xhttp

  rm -rf "$XHTTP_DIR" /usr/local/lib/xhttp

  rm -f /var/log/xhttp.log /var/log/xhttp.err

  echo "卸载清理完成。请检查上游 Cloudflare DNS/隧道仪表板，脚本不会删除账户侧资源。"
}

main() {
  load_state

  while true; do

    echo
    echo "========== XHTTP Manager V4 =========="

    echo "系统：${ID:-unknown} / $(uname -m)"

    echo "协议：${PROTO:-未选择} | 端口：${PORT:-未设置}"

    echo "域名：${DOMAIN:-未设置} | Tunnel：${TUNNEL_HOST:-未配置}"

    echo "1. 选择/修改协议和参数"
    echo "2. 安装/重新部署节点"
    echo "3. 查看服务状态"
    echo "4. 更新 Xray 内核"
    echo "5. Cloudflare Tunnel 管理"
    echo "6. 显示节点链接"
    echo "7. 彻底卸载"
    echo "0. 退出"

    read -rp "请选择: " n

    case "$n" in
      1) protocol_menu ;;
      2) install_node ;;
      3) core_status ;;
      4) kernel_menu ;;
      5) tunnel_menu ;;
      6) print_link ;;
      7) uninstall_all ;;
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac

  done
}

main "$@"