
#!/usr/bin/env bash
# ============================================================
# XHTTP Manager V4.1 - Cloudflare Tunnel Module
# Dedicated service: xhttp-cloudflared
# Does not remove generic Cloudflare Tunnel configuration.
# ============================================================

set -Eeuo pipefail

XHTTP_DIR="/etc/xhttp"
TUNNEL_TOKEN_FILE="$XHTTP_DIR/cloudflare-token"

CLOUDFLARED_BIN="/usr/local/bin/cloudflared-xhttp"
CLOUDFLARED_RUN="/usr/local/lib/xhttp/cloudflared-run.sh"

TUNNEL_SYSTEMD="/etc/systemd/system/xhttp-cloudflared.service"
TUNNEL_OPENRC="/etc/init.d/xhttp-cloudflared"

tunnel_log() {
    printf '\033[0;36m[TUNNEL]\033[0m %s\n' "$*"
}

tunnel_err() {
    printf '\033[0;31m[TUNNEL ERROR]\033[0m %s\n' "$*" >&2
}

tunnel_os() {
    [[ -r /etc/os-release ]] || {
        tunnel_err "无法读取系统信息"
        return 1
    }

    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID:-}" in
        ubuntu|debian)
            T_OS="systemd"
            ;;
        alpine)
            T_OS="openrc"
            ;;
        *)
            tunnel_err "不支持的系统：${ID:-unknown}"
            return 1
            ;;
    esac
}

tunnel_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            T_ARCH="amd64"
            ;;
        aarch64|arm64)
            T_ARCH="arm64"
            ;;
        armv7l|armv7)
            T_ARCH="arm"
            ;;
        *)
            tunnel_err "不支持的 CPU 架构：$(uname -m)"
            return 1
            ;;
    esac
}

tunnel_install_binary() {
    local url
    local tmp

    tunnel_arch

    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${T_ARCH}"

    tmp="$(mktemp "${TMPDIR:-/tmp}/cloudflared-xhttp.XXXXXX")"

    tunnel_log "下载 Cloudflare cloudflared"

    if ! curl -fL --retry 3 --connect-timeout 15 "$url" -o "$tmp"; then
        rm -f "$tmp"
        tunnel_err "下载 cloudflared 失败"
        return 1
    fi

    install -m 0755 "$tmp" "$CLOUDFLARED_BIN"

    rm -f "$tmp"

    "$CLOUDFLARED_BIN" --version
}

tunnel_write_runner() {
    install -d -m 0755 /usr/local/lib/xhttp

    cat > "$CLOUDFLARED_RUN" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

TOKEN_FILE="/etc/xhttp/cloudflare-token"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared-xhttp"

[[ -x "$CLOUDFLARED_BIN" ]] || exit 1
[[ -r "$TOKEN_FILE" ]] || exit 1

TOKEN="$(cat "$TOKEN_FILE")"

[[ -n "$TOKEN" ]] || exit 1

exec "$CLOUDFLARED_BIN" tunnel \
    --no-autoupdate \
    run \
    --token "$TOKEN"
EOF

    chmod 0700 "$CLOUDFLARED_RUN"
}

tunnel_install_service() {
    tunnel_os

    tunnel_write_runner

    if [[ "$T_OS" == "systemd" ]]; then

        cat > "$TUNNEL_SYSTEMD" <<EOF
[Unit]
Description=XHTTP Managed Cloudflare Tunnel
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
EOF

        chmod 0644 "$TUNNEL_SYSTEMD"

        systemctl daemon-reload
        systemctl enable xhttp-cloudflared
        systemctl restart xhttp-cloudflared

    else

        cat > "$TUNNEL_OPENRC" <<'EOF'
#!/sbin/openrc-run

name="xhttp-cloudflared"
description="XHTTP Managed Cloudflare Tunnel"

command="/usr/local/lib/xhttp/cloudflared-run.sh"

command_background="yes"
pidfile="/run/xhttp-cloudflared.pid"

output_log="/var/log/xhttp-cloudflared.log"
error_log="/var/log/xhttp-cloudflared.err"

depend() {
    need net
}
EOF

        chmod 0755 "$TUNNEL_OPENRC"

        rc-update add xhttp-cloudflared default

        rc-service xhttp-cloudflared restart ||
            rc-service xhttp-cloudflared start
    fi

    tunnel_log "Cloudflare Tunnel 服务已启动"
}

tunnel_install() {
    local token="${1:-}"

    [[ -n "$token" ]] || {
        tunnel_err "Tunnel Token 不能为空"
        return 1
    }

    tunnel_os

    install -d -m 0700 "$XHTTP_DIR"

    # Only write the token managed by this script.
    printf '%s\n' "$token" > "$TUNNEL_TOKEN_FILE"
    chmod 0600 "$TUNNEL_TOKEN_FILE"

    tunnel_install_binary

    tunnel_install_service
}

tunnel_configure_http() {
    local hostname="${1:-}"
    local port="${2:-}"

    [[ -n "$hostname" ]] || {
        tunnel_err "公网主机名不能为空"
        return 1
    }

    [[ "$hostname" == *.* && "$hostname" != *'/'* ]] || {
        tunnel_err "公网主机名格式不正确"
        return 1
    }

    [[ "$port" =~ ^[0-9]+$ ]] || {
        tunnel_err "端口格式不正确"
        return 1
    }

    (( 10#$port >= 1 && 10#$port <= 65535 )) || {
        tunnel_err "端口范围必须为 1-65535"
        return 1
    }

    echo
    echo "========== Cloudflare 后台设置 =========="
    echo
    echo "打开 Cloudflare Zero Trust 控制台："
    echo "Networks > Connectors > Cloudflare Tunnels"
    echo
    echo "选择你刚才使用 Token 连接的 Tunnel。"
    echo "进入 Public Hostnames，添加以下配置："
    echo
    echo "Hostname:"
    echo "$hostname"
    echo
    echo "Service:"
    echo "http://localhost:$port"
    echo
    echo "========================================="
    echo
    tunnel_log "请在 Cloudflare 后台保存以上 Public Hostname 配置"
}

tunnel_status() {
    tunnel_os || return 0

    echo
    echo "========== Cloudflare Tunnel 状态 =========="

    if [[ "$T_OS" == "systemd" ]]; then

        systemctl --no-pager --full status \
            xhttp-cloudflared 2>/dev/null |
            head -n 15 || true

    else

        rc-service xhttp-cloudflared status 2>/dev/null || true

    fi

    echo
}

tunnel_stop() {
    tunnel_os || return 0

    if [[ "$T_OS" == "systemd" ]]; then

        systemctl stop xhttp-cloudflared 2>/dev/null || true

    else

        rc-service xhttp-cloudflared stop 2>/dev/null || true

    fi
}

tunnel_uninstall() {
    tunnel_os || return 0

    tunnel_log "停止本脚本管理的 Cloudflare Tunnel"

    if [[ "$T_OS" == "systemd" ]]; then

        systemctl disable --now xhttp-cloudflared 2>/dev/null || true

        rm -f "$TUNNEL_SYSTEMD"

        systemctl daemon-reload 2>/dev/null || true

    else

        rc-service xhttp-cloudflared stop 2>/dev/null || true

        rc-update del xhttp-cloudflared default 2>/dev/null || true

        rm -f "$TUNNEL_OPENRC"
        rm -f /run/xhttp-cloudflared.pid
    fi

    # Remove only files owned by this module.
    rm -f "$CLOUDFLARED_RUN"
    rm -f "$CLOUDFLARED_BIN"
    rm -f "$TUNNEL_TOKEN_FILE"

    rm -f /var/log/xhttp-cloudflared.log
    rm -f /var/log/xhttp-cloudflared.err

    tunnel_log "本脚本管理的 Tunnel 服务及文件已清理"
    tunnel_log "没有删除 /etc/cloudflared，也没有卸载其他 Tunnel 服务"
}

tunnel_menu() {
    while true; do

        echo
        echo "================================"
        echo "      Cloudflare Tunnel"
        echo "================================"
        echo "1. 安装 / 重新绑定 Token"
        echo "2. 查看 Tunnel 状态"
        echo "3. 停止本脚本 Tunnel"
        echo "4. 卸载本脚本 Tunnel"
        echo "0. 返回"
        echo "================================"

        read -rp "请选择: " choice

        case "$choice" in

            1)
                read -rsp "Cloudflare Tunnel Token: " token
                echo

                if tunnel_install "$token"; then
                    read -rp "公网主机名，例如 x.example.com: " hostname
                    read -rp "Xray 本地监听端口: " port

                    tunnel_configure_http "$hostname" "$port"
                fi
                ;;

            2)
                tunnel_status
                ;;

            3)
                tunnel_stop
                ;;

            4)
                read -rp "确认卸载本脚本 Tunnel？[y/N] " answer

                if [[ "$answer" =~ ^[Yy]$ ]]; then
                    tunnel_uninstall
                fi
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