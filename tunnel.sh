#!/usr/bin/env bash
# Cloudflare Tunnel module - token-based named tunnel connector

set -Eeuo pipefail

tunnel_log() {
  printf '\033[1;36m[TUNNEL]\033[0m %s\n' "$*"
}

tunnel_os() {
  . /etc/os-release

  case "${ID:-}" in
    ubuntu|debian)
      T_OS=systemd
      ;;
    alpine)
      T_OS=openrc
      ;;
    *)
      echo "不支持的系统"
      return 1
      ;;
  esac
}

tunnel_install() {
  local token="${1:-}"

  [[ -n "$token" ]] || {
    echo "Tunnel Token 为空"
    return 1
  }

  tunnel_os

  local arch url tmp

  case "$(uname -m)" in
    x86_64)
      arch=amd64
      ;;
    aarch64)
      arch=arm64
      ;;
    armv7l)
      arch=arm
      ;;
    *)
      echo "不支持的架构"
      return 1
      ;;
  esac

  if [[ "$T_OS" == systemd ]]; then

    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"

  else

    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"

  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/cloudflared.XXXXXX")"

  curl -fL --retry 3 "$url" -o "$tmp"

  install -m 0755 "$tmp" /usr/local/bin/cloudflared

  rm -f "$tmp"

  cloudflared --version

  if [[ "$T_OS" == systemd ]]; then

    cloudflared service uninstall >/dev/null 2>&1 || true

    cloudflared service install "$token"

    systemctl enable --now cloudflared

  else

    install -d -m 0700 /etc/cloudflared

    printf '%s\n' "$token" > /etc/cloudflared/token

    chmod 0600 /etc/cloudflared/token

    cat > /etc/init.d/cloudflared-xhttp <<'EOF'
#!/sbin/openrc-run

name="cloudflared-xhttp"

command="/usr/local/bin/cloudflared"

command_args="tunnel run --token $(cat /etc/cloudflared/token)"

command_background="yes"

pidfile="/run/cloudflared-xhttp.pid"

output_log="/var/log/cloudflared-xhttp.log"

error_log="/var/log/cloudflared-xhttp.err"

depend() {
  need net
}
EOF

    chmod 0755 /etc/init.d/cloudflared-xhttp

    rc-update add cloudflared-xhttp default

    rc-service cloudflared-xhttp restart ||
      rc-service cloudflared-xhttp start

  fi

  tunnel_log "cloudflared 已安装并启动"
}

tunnel_configure_http() {
  local hostname="$1"
  local port="$2"

  [[ "$hostname" == *.* && "$hostname" != *'/'* ]] || {
    echo "公网主机名格式不正确"
    return 1
  }

  [[ "$port" =~ ^[0-9]+$ ]] || return 1

  # Public hostname routing must be configured in the Cloudflare dashboard
  # to http://localhost:<port>.
  #
  # Token-only tunnel cannot create DNS/ingress rules.

  tunnel_log "请在 Cloudflare Zero Trust > Networks > Tunnels > 对应隧道 > Public Hostnames 添加："

  echo "Hostname: $hostname"

  echo "Service:  http://localhost:$port"

  echo "不需要在 VPS 开放该源站端口给公网；确保 Xray 监听端口可供 cloudflared 本机访问。"
}

tunnel_status() {
  tunnel_os

  if [[ "$T_OS" == systemd ]]; then

    systemctl --no-pager status cloudflared 2>/dev/null |
      head -n10 || true

  else

    rc-service cloudflared-xhttp status 2>/dev/null || true

  fi
}

tunnel_uninstall() {
  tunnel_os || return 0

  if [[ "$T_OS" == systemd ]]; then

    systemctl disable --now cloudflared 2>/dev/null || true

    cloudflared service uninstall >/dev/null 2>&1 || true

  else

    rc-service cloudflared-xhttp stop 2>/dev/null || true

    rc-update del cloudflared-xhttp default 2>/dev/null || true

    rm -f /etc/init.d/cloudflared-xhttp /run/cloudflared-xhttp.pid

    rm -rf /etc/cloudflared

  fi

  # Only remove cloudflared binary when installed by this script.
  rm -f /usr/local/bin/cloudflared
}

tunnel_menu() {
  while true; do

    echo
    echo "------ Cloudflare Tunnel ------"

    echo "1. 安装/重新绑定 Token"
    echo "2. 查看运行状态"
    echo "3. 停止并卸载本机 cloudflared"
    echo "0. 返回"

    read -rp "选择: " c

    case "$c" in

      1)
        read -rsp "Tunnel Token: " t
        echo

        tunnel_install "$t"

        read -rp "公网主机名: " h

        read -rp "Xray 本地端口: " p

        tunnel_configure_http "$h" "$p"
        ;;

      2)
        tunnel_status
        ;;

      3)
        read -rp "确认卸载本机 cloudflared？[y/N] " y

        [[ "$y" =~ ^[Yy]$ ]] && tunnel_uninstall
        ;;

      0)
        return
        ;;

      *)
        echo "无效选项"
        ;;

    esac

  done
}