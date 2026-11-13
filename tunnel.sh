#!/usr/bin/env bash
# Dedicated Cloudflare Tunnel module. Does not touch generic cloudflared.
set -Eeuo pipefail
XHTTP_DIR="${XHTTP_DIR:-/etc/xhttp}"
TUNNEL_TOKEN_FILE="$XHTTP_DIR/cloudflare-token"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared-xhttp"
CLOUDFLARED_RUN="/usr/local/lib/xhttp/cloudflared-run.sh"
TUNNEL_SYSTEMD="/etc/systemd/system/xhttp-cloudflared.service"
TUNNEL_OPENRC="/etc/init.d/xhttp-cloudflared"

tunnel_log(){ printf '[TUNNEL] %s\n' "$*"; }
tunnel_err(){ printf '[TUNNEL错误] %s\n' "$*" >&2; }
tunnel_os(){
  [[ -r /etc/os-release ]] || return 1
  . /etc/os-release
  case "${ID:-}" in ubuntu|debian) T_OS=systemd ;; alpine) T_OS=openrc ;; *) tunnel_err "不支持系统：${ID:-unknown}"; return 1 ;; esac
}
tunnel_arch(){
  case "$(uname -m)" in x86_64|amd64) T_ARCH=amd64 ;; aarch64|arm64) T_ARCH=arm64 ;; armv7l|armv7) T_ARCH=arm ;; *) tunnel_err "不支持架构：$(uname -m)"; return 1 ;; esac
}
tunnel_install_binary(){
  local url tmp
  tunnel_arch || return 1
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${T_ARCH}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/cloudflared-xhttp.XXXXXX")" || return 1
  if ! curl -fL --retry 3 --connect-timeout 15 "$url" -o "$tmp"; then rm -f "$tmp"; tunnel_err '下载 cloudflared 失败'; return 1; fi
  install -m 0755 "$tmp" "$CLOUDFLARED_BIN"
  rm -f "$tmp"
  "$CLOUDFLARED_BIN" --version
}
tunnel_write_runner(){
  install -d -m 0755 /usr/local/lib/xhttp
  cat > "$CLOUDFLARED_RUN" <<'EOF2'
#!/usr/bin/env bash
set -Eeuo pipefail
TOKEN_FILE="/etc/xhttp/cloudflare-token"
BIN="/usr/local/bin/cloudflared-xhttp"
[[ -x "$BIN" && -s "$TOKEN_FILE" ]] || exit 1
TOKEN="$(cat "$TOKEN_FILE")"
[[ -n "$TOKEN" ]] || exit 1
exec "$BIN" tunnel --no-autoupdate run --token "$TOKEN"
EOF2
  chmod 0700 "$CLOUDFLARED_RUN"
}
tunnel_install_service(){
  tunnel_os || return 1
  tunnel_write_runner
  if [[ "$T_OS" == systemd ]]; then
    cat > "$TUNNEL_SYSTEMD" <<EOF2
[Unit]
Description=XHTTP Dedicated Cloudflare Tunnel
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStart=$CLOUDFLARED_RUN
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF2
    chmod 0644 "$TUNNEL_SYSTEMD"
    systemctl daemon-reload
    systemctl enable xhttp-cloudflared
    systemctl restart xhttp-cloudflared
    systemctl is-active --quiet xhttp-cloudflared || { tunnel_err 'Tunnel 服务启动失败'; journalctl -u xhttp-cloudflared -n 30 --no-pager 2>/dev/null || true; return 1; }
  else
    cat > "$TUNNEL_OPENRC" <<EOF2
#!/sbin/openrc-run
name="xhttp-cloudflared"
description="XHTTP Dedicated Cloudflare Tunnel"
command="$CLOUDFLARED_RUN"
command_background="yes"
pidfile="/run/xhttp-cloudflared.pid"
output_log="/var/log/xhttp-cloudflared.log"
error_log="/var/log/xhttp-cloudflared.err"
depend() { need net; }
EOF2
    chmod 0755 "$TUNNEL_OPENRC"
    rc-update add xhttp-cloudflared default
    rc-service xhttp-cloudflared restart 2>/dev/null || rc-service xhttp-cloudflared start
    rc-service xhttp-cloudflared status >/dev/null 2>&1 || { tunnel_err 'Tunnel 服务启动失败'; return 1; }
  fi
  tunnel_log 'Cloudflare Tunnel 服务已启动'
}
tunnel_install(){
  local token="${1:-}"
  [[ -n "$token" ]] || { tunnel_err 'Token 不能为空'; return 1; }
  tunnel_os || return 1
  install -d -m 0700 "$XHTTP_DIR"
  printf '%s\n' "$token" > "$TUNNEL_TOKEN_FILE"
  chmod 0600 "$TUNNEL_TOKEN_FILE"
  tunnel_install_binary || return 1
  tunnel_install_service
}
tunnel_configure_http(){
  local hostname="${1:-}" port="${2:-}"
  [[ "$hostname" == *.* && "$hostname" != */* ]] || { tunnel_err '主机名格式不正确'; return 1; }
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || { tunnel_err '端口必须为 1-65535'; return 1; }
  echo
  echo 'Cloudflare Zero Trust → Networks → Connectors → Cloudflare Tunnels'
  echo '选择对应 Tunnel → Public Hostnames → Add a public hostname'
  echo "Hostname：$hostname"
  echo "Service： http://localhost:$port"
  echo '保存后等待 Tunnel 状态显示 Healthy。'
  echo '注意：Tunnel 只负责转发；客户端域名、DNS 和 Public Hostname 必须在 Cloudflare 后台配置。'
}
tunnel_status(){
  tunnel_os || return 0
  if [[ "$T_OS" == systemd ]]; then systemctl --no-pager --full status xhttp-cloudflared 2>/dev/null | head -n 18 || true; else rc-service xhttp-cloudflared status 2>/dev/null || true; fi
}
tunnel_stop(){
  tunnel_os || return 0
  if [[ "$T_OS" == systemd ]]; then systemctl stop xhttp-cloudflared 2>/dev/null || true; else rc-service xhttp-cloudflared stop 2>/dev/null || true; fi
}
tunnel_uninstall(){
  tunnel_os || return 0
  if [[ "$T_OS" == systemd ]]; then
    systemctl disable --now xhttp-cloudflared 2>/dev/null || true
    rm -f "$TUNNEL_SYSTEMD"
    systemctl daemon-reload 2>/dev/null || true
  else
    rc-service xhttp-cloudflared stop 2>/dev/null || true
    rc-update del xhttp-cloudflared default 2>/dev/null || true
    rm -f "$TUNNEL_OPENRC" /run/xhttp-cloudflared.pid
  fi
  rm -f "$CLOUDFLARED_RUN" "$CLOUDFLARED_BIN" "$TUNNEL_TOKEN_FILE"
  rm -f /var/log/xhttp-cloudflared.log /var/log/xhttp-cloudflared.err
  tunnel_log '已清理本脚本 Tunnel；未触碰其他 cloudflared 配置和服务'
}
tunnel_menu(){
  local choice token hostname port answer
  while true; do
    echo; echo '====== Cloudflare Tunnel 管理 ======'
    echo '1. 安装 / 重新绑定 Token'; echo '2. 查看状态'; echo '3. 停止'; echo '4. 卸载本脚本 Tunnel'; echo '0. 返回'
    read -rp '请选择：' choice
    case "$choice" in
      1) read -rsp 'Tunnel Token：' token; echo; tunnel_install "$token" && { read -rp '公网主机名（如 x.example.com）：' hostname; read -rp 'Xray 本地端口：' port; tunnel_configure_http "$hostname" "$port"; } ;;
      2) tunnel_status ;;
      3) tunnel_stop ;;
      4) read -rp '确认卸载？输入 YES：' answer; [[ "$answer" == YES ]] && tunnel_uninstall ;;
      0) return ;;
      *) echo '无效选项' ;;
    esac
  done
}
