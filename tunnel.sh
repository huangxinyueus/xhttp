#!/usr/bin/env bash
# XHTTP Manager V4.5 - isolated Cloudflare Tunnel module
set -Eeuo pipefail
umask 077
XHTTP_MODULE_VERSION="4.5"
TUNNEL_MODULE_VERSION="$XHTTP_MODULE_VERSION"
XHTTP_DIR="${XHTTP_DIR:-/etc/xhttp}"
LIB_DIR="/usr/local/lib/xhttp"
TUNNEL_TOKEN_FILE="$XHTTP_DIR/cloudflare-token"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared-xhttp"
CLOUDFLARED_RUN="$LIB_DIR/cloudflared-run.sh"
TUNNEL_SYSTEMD="/etc/systemd/system/xhttp-cloudflared.service"
TUNNEL_OPENRC="/etc/init.d/xhttp-cloudflared"
T_OS=""; T_ARCH=""
tunnel_log(){ printf '[TUNNEL] %s\n' "$*"; }
tunnel_err(){ printf '[TUNNEL ERROR] %s\n' "$*" >&2; }
tunnel_os(){ [[ -r /etc/os-release ]] || return 1; . /etc/os-release; case "${ID:-}" in ubuntu|debian) T_OS=systemd;; alpine) T_OS=openrc;; *) tunnel_err "不支持的系统：${ID:-unknown}"; return 1;; esac; }
tunnel_arch(){ case "$(uname -m)" in x86_64|amd64) T_ARCH=amd64;; aarch64|arm64) T_ARCH=arm64;; armv7l|armv7) T_ARCH=arm;; *) tunnel_err "不支持的 CPU 架构：$(uname -m)"; return 1;; esac; }
tunnel_check_owner(){
  if [[ "$T_OS" == systemd ]]; then
    if [[ -f "$TUNNEL_SYSTEMD" ]]; then
      if ! { grep -q 'XHTTP Manager managed tunnel' "$TUNNEL_SYSTEMD" && grep -Fq 'ExecStart=/usr/local/lib/xhttp/cloudflared-run.sh' "$TUNNEL_SYSTEMD"; }; then
        tunnel_err '现有 xhttp-cloudflared.service 无法确认属于本项目，拒绝操作'; return 1
      fi
    elif command -v systemctl >/dev/null 2>&1; then
      local fragment
      fragment="$(systemctl show -p FragmentPath --value xhttp-cloudflared 2>/dev/null || true)"
      if [[ -n "$fragment" && "$fragment" != "$TUNNEL_SYSTEMD" ]]; then
        tunnel_err "检测到其他来源的 xhttp-cloudflared 服务（$fragment），拒绝操作"; return 1
      fi
    fi
  elif [[ "$T_OS" == openrc && -f "$TUNNEL_OPENRC" ]]; then
    if ! { grep -q 'XHTTP Manager managed tunnel' "$TUNNEL_OPENRC" && grep -Fq 'command="/usr/local/lib/xhttp/cloudflared-run.sh"' "$TUNNEL_OPENRC"; }; then
      tunnel_err '现有 xhttp-cloudflared 服务无法确认属于本项目，拒绝操作'; return 1
    fi
  fi
}
tunnel_install_binary(){
  local url tmp candidate
  tunnel_arch || return 1
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${T_ARCH}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/cloudflared-xhttp.XXXXXX")" || return 1
  if ! curl -fL --retry 3 --connect-timeout 15 "$url" -o "$tmp"; then rm -f -- "$tmp"; tunnel_err '下载 cloudflared 失败'; return 1; fi
  chmod 0755 "$tmp"
  if ! "$tmp" --version >/dev/null 2>&1; then rm -f -- "$tmp"; tunnel_err '下载的 cloudflared 无法执行'; return 1; fi
  install -d -m 0755 /usr/local/bin
  candidate="/usr/local/bin/.cloudflared-xhttp.new.$$"
  if ! install -m 0755 "$tmp" "$candidate" || ! mv -f "$candidate" "$CLOUDFLARED_BIN"; then
    rm -f -- "$tmp" "$candidate"; tunnel_err '安装 cloudflared 二进制失败'; return 1
  fi
  rm -f -- "$tmp" "$candidate"
  return 0
}
tunnel_write_runner(){
  install -d -m 0755 "$LIB_DIR"
  cat > "$CLOUDFLARED_RUN" <<'RUN'
#!/usr/bin/env bash
set -Eeuo pipefail
TOKEN_FILE="/etc/xhttp/cloudflare-token"
BIN="/usr/local/bin/cloudflared-xhttp"
[[ -x "$BIN" && -r "$TOKEN_FILE" ]] || exit 1
TOKEN="$(<"$TOKEN_FILE")"
[[ -n "$TOKEN" ]] || exit 1
exec "$BIN" tunnel --no-autoupdate run --token "$TOKEN"
RUN
  chmod 0700 "$CLOUDFLARED_RUN"
}
tunnel_install_service(){
  tunnel_os || return 1; tunnel_check_owner || return 1; tunnel_write_runner
  if [[ "$T_OS" == systemd ]]; then
    cat > "$TUNNEL_SYSTEMD" <<'UNIT'
# XHTTP Manager managed tunnel
[Unit]
Description=XHTTP Manager isolated Cloudflare Tunnel
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/lib/xhttp/cloudflared-run.sh
Restart=on-failure
RestartSec=5
User=root
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
UNIT
    chmod 0644 "$TUNNEL_SYSTEMD"; systemctl daemon-reload; systemctl enable xhttp-cloudflared; systemctl restart xhttp-cloudflared
  else
    cat > "$TUNNEL_OPENRC" <<'RC'
#!/sbin/openrc-run
# XHTTP Manager managed tunnel
name="xhttp-cloudflared"
description="XHTTP Manager isolated Cloudflare Tunnel"
command="/usr/local/lib/xhttp/cloudflared-run.sh"
command_background="yes"
pidfile="/run/xhttp-cloudflared.pid"
output_log="/var/log/xhttp-cloudflared.log"
error_log="/var/log/xhttp-cloudflared.err"
depend(){ need net; }
RC
    chmod 0755 "$TUNNEL_OPENRC"; rc-update add xhttp-cloudflared default; rc-service xhttp-cloudflared restart || rc-service xhttp-cloudflared start
  fi
}
tunnel_install(){
  local token="${1:-}" tmp
  [[ -n "$token" ]] || { tunnel_err 'Tunnel Token 不能为空'; return 1; }
  tunnel_os && tunnel_check_owner || return 1
  install -d -m 0700 "$XHTTP_DIR"
  tmp="$(mktemp "$XHTTP_DIR/token.XXXXXX")" || return 1
  printf '%s\n' "$token" > "$tmp"; chmod 0600 "$tmp"
  if ! tunnel_install_binary; then rm -f "$tmp"; return 1; fi
  if ! mv -f "$tmp" "$TUNNEL_TOKEN_FILE"; then rm -f "$tmp"; tunnel_err '保存 Tunnel Token 失败'; return 1; fi
  tunnel_install_service
}
tunnel_configure_http(){
  local hostname="${1:-}" port="${2:-}"
  [[ "$hostname" == *.* && "$hostname" != */* ]] || { tunnel_err '公网主机名格式不正确'; return 1; }
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || { tunnel_err '端口范围必须为 1-65535'; return 1; }
  printf '\nCloudflare Zero Trust > Networks > Connectors > Cloudflare Tunnels > Public Hostnames\nHostname: %s\nService: http://localhost:%s\n' "$hostname" "$port"
}
tunnel_status(){ tunnel_os || return 1; tunnel_check_owner || return 1; echo '========== 本项目 Cloudflare Tunnel =========='; if [[ "$T_OS" == systemd ]]; then systemctl --no-pager --full status xhttp-cloudflared 2>/dev/null || true; else rc-service xhttp-cloudflared status 2>/dev/null || true; fi; }
tunnel_stop(){ tunnel_os || return 0; tunnel_check_owner || return 1; if [[ "$T_OS" == systemd ]]; then systemctl stop xhttp-cloudflared 2>/dev/null || true; else rc-service xhttp-cloudflared stop 2>/dev/null || true; fi; }
tunnel_uninstall(){
  tunnel_os || return 0
  tunnel_check_owner || return 1
  if [[ "$T_OS" == systemd ]]; then
    if [[ -f "$TUNNEL_SYSTEMD" ]] && grep -q 'XHTTP Manager managed tunnel' "$TUNNEL_SYSTEMD" && grep -Fq 'ExecStart=/usr/local/lib/xhttp/cloudflared-run.sh' "$TUNNEL_SYSTEMD"; then systemctl disable --now xhttp-cloudflared 2>/dev/null || true; rm -f "$TUNNEL_SYSTEMD"; systemctl daemon-reload 2>/dev/null || true; fi
  else
    if [[ -f "$TUNNEL_OPENRC" ]] && grep -q 'XHTTP Manager managed tunnel' "$TUNNEL_OPENRC" && grep -Fq 'command="/usr/local/lib/xhttp/cloudflared-run.sh"' "$TUNNEL_OPENRC"; then rc-service xhttp-cloudflared stop 2>/dev/null || true; rc-update del xhttp-cloudflared default 2>/dev/null || true; rm -f "$TUNNEL_OPENRC" /run/xhttp-cloudflared.pid; fi
  fi
  rm -f "$CLOUDFLARED_RUN" "$CLOUDFLARED_BIN" "$TUNNEL_TOKEN_FILE" /var/log/xhttp-cloudflared.log /var/log/xhttp-cloudflared.err
  tunnel_log '本项目 Tunnel 文件已清理；未触碰其他 Tunnel 配置'
}
tunnel_menu(){
  local choice token hostname port answer
  while true; do
    echo; echo '====== Cloudflare Tunnel ======'; echo '1. 安装 / 重新绑定 Token'; echo '2. 查看状态'; echo '3. 停止'; echo '4. 卸载'; echo '0. 返回'
    read -rp '请选择: ' choice
    case "$choice" in
      1) read -rsp 'Cloudflare Tunnel Token: ' token; echo; if tunnel_install "$token"; then read -rp '公网主机名，例如 x.example.com: ' hostname; read -rp 'Xray 本地监听端口: ' port; tunnel_configure_http "$hostname" "$port"; fi; unset token;;
      2) tunnel_status;; 3) tunnel_stop;;
      4) read -rp '确认卸载本项目 Tunnel？[y/N] ' answer; [[ "$answer" =~ ^[Yy]$ ]] && tunnel_uninstall;;
      0) return;; *) echo '无效选项';;
    esac
  done
}
