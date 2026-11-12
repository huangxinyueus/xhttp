#!/usr/bin/env bash
# XHTTP Manager - Xray core module
# Ubuntu / Debian (systemd), Alpine (OpenRC)

set -Eeuo pipefail

XHTTP_DIR="${XHTTP_DIR:-/etc/xhttp}"
BIN_DIR="/usr/local/bin"
XRAY_BIN="$BIN_DIR/xray"
SERVICE_NAME="xhttp"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
OPENRC_FILE="/etc/init.d/${SERVICE_NAME}"

core_log() {
  printf '\033[1;36m[CORE]\033[0m %s\n' "$*"
}

core_err() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
}

core_os() {
  [[ -r /etc/os-release ]] || {
    core_err "无法读取 /etc/os-release"
    return 1
  }

  . /etc/os-release

  case "${ID:-}" in
    ubuntu|debian)
      OS_FAMILY=systemd
      PKG=apt-get
      ;;
    alpine)
      OS_FAMILY=openrc
      PKG=apk
      ;;
    *)
      core_err "仅支持 Ubuntu、Debian、Alpine；当前：${ID:-unknown}"
      return 1
      ;;
  esac

  ARCH="$(uname -m)"

  case "$ARCH" in
    x86_64|amd64)
      XRAY_ARCH=64
      ;;
    aarch64|arm64)
      XRAY_ARCH=arm64-v8a
      ;;
    armv7l|armv7)
      XRAY_ARCH=arm32-v7a
      ;;
    *)
      core_err "暂不支持 CPU 架构：$ARCH"
      return 1
      ;;
  esac
}

core_deps() {
  core_os

  if [[ "$PKG" == apt-get ]]; then

    apt-get update -y

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      curl \
      ca-certificates \
      unzip \
      jq \
      openssl

  else

    apk add --no-cache \
      curl \
      ca-certificates \
      unzip \
      jq \
      openssl

  fi
}

xray_latest() {
  curl -fsSL --retry 3 \
    https://api.github.com/repos/XTLS/Xray-core/releases/latest |
    sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' |
    head -n1
}

core_install() {
  local requested="${1:-latest}"
  local version url tmp

  core_deps

  version="$requested"

  [[ "$version" == latest ]] &&
    version="$(xray_latest)"

  [[ -n "$version" ]] || {
    core_err "无法取得 Xray 最新版本"
    return 1
  }

  version="${version#v}"

  url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${XRAY_ARCH}.zip"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/xray-install.XXXXXX")"

  trap 'rm -rf "$tmp"' RETURN

  core_log "下载 Xray-core v${version}"

  curl -fL --retry 3 "$url" -o "$tmp/xray.zip"

  unzip -oq "$tmp/xray.zip" xray -d "$tmp"

  install -m 0755 "$tmp/xray" "$XRAY_BIN"

  "$XRAY_BIN" version | head -n2

  mkdir -p "$XHTTP_DIR"

  printf '%s\n' "$version" > "$XHTTP_DIR/xray.version"

  core_log "Xray 安装完成"
}

core_validate() {
  [[ -x "$XRAY_BIN" ]] || {
    core_err "尚未安装 Xray"
    return 1
  }

  "$XRAY_BIN" run -test -config "$XHTTP_DIR/config.json"
}

core_service_install() {
  core_os

  if [[ "$OS_FAMILY" == systemd ]]; then

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=XHTTP Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$XRAY_BIN run -config $XHTTP_DIR/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    systemctl enable "$SERVICE_NAME"

    systemctl restart "$SERVICE_NAME"

  else

    cat > "$OPENRC_FILE" <<'EOF'
#!/sbin/openrc-run

name="xhttp"
description="XHTTP Xray Service"

command="/usr/local/bin/xray"
command_args="run -config /etc/xhttp/config.json"

command_background="yes"
pidfile="/run/xhttp.pid"

output_log="/var/log/xhttp.log"
error_log="/var/log/xhttp.err"

depend() {
  need net
}
EOF

    chmod 0755 "$OPENRC_FILE"

    rc-update add "$SERVICE_NAME" default

    rc-service "$SERVICE_NAME" restart ||
      rc-service "$SERVICE_NAME" start

  fi
}

core_service_stop() {
  core_os || return 0

  if [[ "$OS_FAMILY" == systemd ]]; then

    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true

    rm -f "$SERVICE_FILE"

    systemctl daemon-reload 2>/dev/null || true

  else

    rc-service "$SERVICE_NAME" stop 2>/dev/null || true

    rc-update del "$SERVICE_NAME" default 2>/dev/null || true

    rm -f "$OPENRC_FILE" /run/xhttp.pid

  fi

  pkill -x xray 2>/dev/null || true
}

core_update() {
  core_install "${1:-latest}"

  core_validate

  core_service_install
}