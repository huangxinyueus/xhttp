
#!/usr/bin/env bash
# ============================================================
# XHTTP Manager V4.1 - Xray Core Module
# Ubuntu / Debian: systemd
# Alpine: OpenRC
# ============================================================

set -Eeuo pipefail

XHTTP_DIR="${XHTTP_DIR:-/etc/xhttp}"
BIN_DIR="/usr/local/bin"
XRAY_BIN="$BIN_DIR/xray"
SERVICE_NAME="xhttp"
SERVICE_FILE="/etc/systemd/system/xhttp.service"
OPENRC_FILE="/etc/init.d/xhttp"

core_log() {
    printf '\033[0;36m[CORE]\033[0m %s\n' "$*"
}

core_err() {
    printf '\033[0;31m[CORE ERROR]\033[0m %s\n' "$*" >&2
}

core_os() {
    [[ -r /etc/os-release ]] || {
        core_err "无法读取 /etc/os-release"
        return 1
    }

    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID:-}" in
        ubuntu|debian)
            OS_FAMILY="systemd"
            PKG="apt-get"
            ;;
        alpine)
            OS_FAMILY="openrc"
            PKG="apk"
            ;;
        *)
            core_err "不支持的系统：${ID:-unknown}"
            return 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)
            XRAY_ARCH="64"
            ;;
        aarch64|arm64)
            XRAY_ARCH="arm64-v8a"
            ;;
        armv7l|armv7)
            XRAY_ARCH="arm32-v7a"
            ;;
        *)
            core_err "暂不支持的 CPU 架构：$(uname -m)"
            return 1
            ;;
    esac
}

core_deps() {
    core_os

    core_log "安装必要依赖"

    if [[ "$PKG" == "apt-get" ]]; then
        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y

        apt-get install -y \
            curl \
            ca-certificates \
            unzip \
            jq \
            openssl \
            iproute2 \
            coreutils
    else
        apk add --no-cache \
            bash \
            curl \
            ca-certificates \
            unzip \
            jq \
            openssl \
            iproute2 \
            coreutils
    fi
}

xray_latest() {
    local version

    version="$(
        curl -fsSL --retry 3 \
            https://api.github.com/repos/XTLS/Xray-core/releases/latest |
            jq -r '.tag_name // empty' |
            sed 's/^v//'
    )"

    [[ -n "$version" ]] || {
        core_err "获取 Xray 最新版本失败"
        return 1
    }

    printf '%s' "$version"
}

core_install() {
    local requested="${1:-latest}"
    local version
    local url
    local tmp

    core_os
    core_deps

    version="$requested"

    if [[ "$requested" == "latest" ]]; then
        version="$(xray_latest)"
    fi

    version="${version#v}"

    [[ -n "$version" ]] || {
        core_err "Xray 版本号为空"
        return 1
    }

    url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${XRAY_ARCH}.zip"

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/xray-install.XXXXXX")"

    core_cleanup_tmp() {
        rm -rf "$tmp"
    }

    trap core_cleanup_tmp RETURN

    core_log "准备安装 Xray v${version}"
    core_log "下载地址：$url"

    curl -fL --retry 3 --connect-timeout 15 \
        "$url" -o "$tmp/xray.zip"

    unzip -oq "$tmp/xray.zip" xray -d "$tmp"

    [[ -f "$tmp/xray" ]] || {
        core_err "压缩包中没有找到 xray 文件"
        return 1
    }

    install -d -m 0755 "$BIN_DIR"
    install -m 0755 "$tmp/xray" "$XRAY_BIN"

    "$XRAY_BIN" version | head -n 2

    install -d -m 0700 "$XHTTP_DIR"
    printf '%s\n' "$version" > "$XHTTP_DIR/xray.version"
    chmod 0600 "$XHTTP_DIR/xray.version"

    core_log "Xray 安装完成"
}

core_validate() {
    [[ -x "$XRAY_BIN" ]] || {
        core_err "Xray 尚未安装"
        return 1
    }

    [[ -f "$XHTTP_DIR/config.json" ]] || {
        core_err "配置文件不存在：$XHTTP_DIR/config.json"
        return 1
    }

    core_log "检查 Xray 配置"

    "$XRAY_BIN" run -test -config "$XHTTP_DIR/config.json"
}

core_service_install() {
    core_os

    [[ -x "$XRAY_BIN" ]] || {
        core_err "找不到 Xray 可执行文件"
        return 1
    }

    [[ -f "$XHTTP_DIR/config.json" ]] || {
        core_err "找不到 Xray 配置文件"
        return 1
    }

    if [[ "$OS_FAMILY" == "systemd" ]]; then

        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=XHTTP Managed Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config /etc/xhttp/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

        chmod 0644 "$SERVICE_FILE"

        systemctl daemon-reload
        systemctl enable xhttp
        systemctl restart xhttp

    else

        cat > "$OPENRC_FILE" <<'EOF'
#!/sbin/openrc-run

name="xhttp"
description="XHTTP Managed Xray Service"

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

        rc-update add xhttp default
        rc-service xhttp restart ||
            rc-service xhttp start
    fi

    core_log "XHTTP 服务已启动"
}

core_service_stop() {
    core_os || return 0

    if [[ "$OS_FAMILY" == "systemd" ]]; then

        # 只操作本脚本创建的 xhttp 服务。
        systemctl disable --now xhttp 2>/dev/null || true

        rm -f "$SERVICE_FILE"

        systemctl daemon-reload 2>/dev/null || true

    else

        rc-service xhttp stop 2>/dev/null || true

        rc-update del xhttp default 2>/dev/null || true

        rm -f "$OPENRC_FILE"
        rm -f /run/xhttp.pid
    fi

    core_log "XHTTP 服务已停止"
}

core_service_status() {
    core_os

    if [[ "$OS_FAMILY" == "systemd" ]]; then
        systemctl --no-pager status xhttp
    else
        rc-service xhttp status
    fi
}

core_update() {
    local version="${1:-latest}"

    core_log "开始更新 Xray"

    core_install "$version"

    core_validate

    core_service_install

    core_log "Xray 更新完成"
}