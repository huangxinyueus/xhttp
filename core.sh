#!/usr/bin/env bash
# XHTTP Core module - Ubuntu / Debian / Alpine
set -Eeuo pipefail

XHTTP_DIR="${XHTTP_DIR:-/etc/xhttp}"
XRAY_BIN="/usr/local/bin/xray-xhttp"
CORE_SERVICE="xhttp"
CORE_SYSTEMD="/etc/systemd/system/xhttp.service"
CORE_OPENRC="/etc/init.d/xhttp"

core_log(){ printf '[CORE] %s\n' "$*"; }
core_err(){ printf '[CORE错误] %s\n' "$*" >&2; }

core_os(){
  [[ -r /etc/os-release ]] || { core_err '无法读取 /etc/os-release'; return 1; }
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) OS_FAMILY=systemd; PKG=apt-get ;;
    alpine) OS_FAMILY=openrc; PKG=apk ;;
    *) core_err "不支持的系统：${ID:-unknown}（仅 Ubuntu/Debian/Alpine）"; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) XRAY_ARCH=64 ;;
    aarch64|arm64) XRAY_ARCH=arm64-v8a ;;
    armv7l|armv7) XRAY_ARCH=arm32-v7a ;;
    *) core_err "不支持的 CPU 架构：$(uname -m)"; return 1 ;;
  esac
}

core_deps(){
  core_os || return 1
  core_log '检查并安装依赖'
  if [[ "$PKG" == apt-get ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates unzip jq openssl iproute2 coreutils bash
  else
    apk add --no-cache bash curl ca-certificates unzip jq openssl iproute2 coreutils
  fi
}

core_latest_version(){
  curl -fsSL --retry 3 https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -er '.tag_name | ltrimstr("v")'
}

core_install(){
  local requested="${1:-latest}" version url tmp
  core_os || return 1
  if [[ "$requested" == latest ]]; then
    version="$(core_latest_version)" || { core_err '获取最新版本号失败'; return 1; }
  else
    version="${requested#v}"
  fi
  [[ -n "$version" ]] || { core_err '无法确定 Xray 版本'; return 1; }
  url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${XRAY_ARCH}.zip"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/xhttp-xray.XXXXXX")" || return 1
  if ! curl -fL --retry 3 --connect-timeout 15 "$url" -o "$tmp/xray.zip"; then
    rm -rf "$tmp"; core_err '下载 Xray 失败'; return 1
  fi
  if ! unzip -oq "$tmp/xray.zip" xray -d "$tmp" || [[ ! -s "$tmp/xray" ]]; then
    rm -rf "$tmp"; core_err '解压 Xray 失败或压缩包内没有 xray'; return 1
  fi
  install -d -m 0755 /usr/local/bin "$XHTTP_DIR"
  install -m 0755 "$tmp/xray" "$XRAY_BIN"
  rm -rf "$tmp"
  "$XRAY_BIN" version | head -n 2
  printf '%s\n' "$version" > "$XHTTP_DIR/xray.version"
  chmod 0600 "$XHTTP_DIR/xray.version"
  core_log "独立 Xray 安装完成：$XRAY_BIN"
}

core_validate(){
  [[ -x "$XRAY_BIN" ]] || { core_err "找不到 $XRAY_BIN"; return 1; }
  [[ -s "$XHTTP_DIR/config.json" ]] || { core_err '配置文件不存在'; return 1; }
  "$XRAY_BIN" run -test -config "$XHTTP_DIR/config.json"
}

core_service_install(){
  core_os || return 1
  [[ -x "$XRAY_BIN" && -s "$XHTTP_DIR/config.json" ]] || { core_err 'Xray 或配置文件不存在'; return 1; }
  if [[ "$OS_FAMILY" == systemd ]]; then
    cat > "$CORE_SYSTEMD" <<EOF2
[Unit]
Description=XHTTP Dedicated Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$XRAY_BIN run -config $XHTTP_DIR/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF2
    chmod 0644 "$CORE_SYSTEMD"
    systemctl daemon-reload
    systemctl enable xhttp
    systemctl restart xhttp
    systemctl is-active --quiet xhttp || { core_err 'xhttp 服务启动失败'; journalctl -u xhttp -n 40 --no-pager 2>/dev/null || true; return 1; }
  else
    cat > "$CORE_OPENRC" <<EOF2
#!/sbin/openrc-run
name="xhttp"
description="XHTTP Dedicated Xray Service"
command="$XRAY_BIN"
command_args="run -config $XHTTP_DIR/config.json"
command_background="yes"
pidfile="/run/xhttp.pid"
output_log="/var/log/xhttp.log"
error_log="/var/log/xhttp.err"
depend() { need net; }
EOF2
    chmod 0755 "$CORE_OPENRC"
    rc-update add xhttp default
    rc-service xhttp restart 2>/dev/null || rc-service xhttp start
    rc-service xhttp status >/dev/null 2>&1 || { core_err 'xhttp 服务启动失败'; return 1; }
  fi
  core_log 'XHTTP 服务已启动'
}

core_service_stop(){
  core_os || return 0
  if [[ "$OS_FAMILY" == systemd ]]; then
    systemctl disable --now xhttp 2>/dev/null || true
    rm -f "$CORE_SYSTEMD"
    systemctl daemon-reload 2>/dev/null || true
  else
    rc-service xhttp stop 2>/dev/null || true
    rc-update del xhttp default 2>/dev/null || true
    rm -f "$CORE_OPENRC" /run/xhttp.pid
  fi
  core_log '已停止并移除本脚本的 xhttp 服务'
}

core_service_status(){
  core_os || return 1
  if [[ "$OS_FAMILY" == systemd ]]; then systemctl --no-pager --full status xhttp; else rc-service xhttp status; fi
}

core_update(){
  core_install "${1:-latest}"
  core_validate
  core_service_install
}
