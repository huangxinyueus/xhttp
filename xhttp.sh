
#!/usr/bin/env bash
# ============================================================
# XHTTP Manager V4.2
# Main menu / protocol configuration / install / uninstall
# Supported: Ubuntu, Debian, Alpine
# Requires: core.sh and tunnel.sh
# ============================================================

set -Eeuo pipefail

VERSION="4.2"
XHTTP_DIR="/etc/xhttp"
CONFIG="$XHTTP_DIR/config.json"
STATE="$XHTTP_DIR/state.json"
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib/xhttp"

CORE_FILE=""
TUNNEL_FILE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PROTOCOL=""
DOMAIN=""
PORT=""
UUID=""
PATH_VALUE=""
SECURITY=""
TUNNEL="no"
CERT_FILE=""
KEY_FILE=""
REALITY_PRIVATE=""
REALITY_PUBLIC=""
REALITY_SHORT_ID=""
REALITY_SNI="www.microsoft.com"

log() {
    printf '%b\n' "${CYAN}[XHTTP]${NC} $*"
}

ok() {
    printf '%b\n' "${GREEN}[成功]${NC} $*"
}

warn() {
    printf '%b\n' "${YELLOW}[提示]${NC} $*"
}

err() {
    printf '%b\n' "${RED}[错误]${NC} $*" >&2
}

die() {
    err "$*"
    exit 1
}

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 用户运行"
}

require_commands() {
    local cmd
    for cmd in curl jq openssl awk grep sed head shuf base64; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"
    done
}

load_modules() {
    CORE_FILE="$SELF_DIR/core.sh"
    TUNNEL_FILE="$SELF_DIR/tunnel.sh"

    if [[ ! -f "$CORE_FILE" || ! -f "$TUNNEL_FILE" ]]; then
        CORE_FILE="$LIB_DIR/core.sh"
        TUNNEL_FILE="$LIB_DIR/tunnel.sh"
    fi

    [[ -f "$CORE_FILE" ]] || die "找不到 core.sh，请将三个文件放在同一目录"
    [[ -f "$TUNNEL_FILE" ]] || die "找不到 tunnel.sh，请将三个文件放在同一目录"

    # shellcheck source=/dev/null
    source "$CORE_FILE"

    # shellcheck source=/dev/null
    source "$TUNNEL_FILE"
}

random_port() {
    local p
    local attempts=0

    while (( attempts < 300 )); do
        attempts=$((attempts + 1))
        p="$(shuf -i 20000-59999 -n 1)"

        if ! ss -lnt 2>/dev/null |
            awk '{print $4}' |
            grep -Eq "[:.]${p}$"; then
            printf '%s' "$p"
            return 0
        fi
    done

    die "无法找到可用端口"
}

random_path() {
    printf '/%s' "$(openssl rand -hex 8)"
}

random_uuid() {
    if command -v xray >/dev/null 2>&1; then
        xray uuid
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        die "无法生成 UUID"
    fi
}

valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_domain() {
    local value="$1"

    [[ ${#value} -le 253 ]] || return 1

    [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

valid_ipv4() {
    local ip="$1"
    local a b c d

    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1

    IFS='.' read -r a b c d <<< "$ip"

    for part in "$a" "$b" "$c" "$d"; do
        [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$part <= 255 )) || return 1
    done
}

save_state() {
    install -d -m 0700 "$XHTTP_DIR"
    chmod 0700 "$XHTTP_DIR"

    local tmp
    tmp="$(mktemp "$XHTTP_DIR/state.XXXXXX")"

    jq -n \
        --arg PROTOCOL "$PROTOCOL" \
        --arg DOMAIN "$DOMAIN" \
        --arg PORT "$PORT" \
        --arg UUID "$UUID" \
        --arg PATH_VALUE "$PATH_VALUE" \
        --arg SECURITY "$SECURITY" \
        --arg TUNNEL "$TUNNEL" \
        --arg CERT_FILE "$CERT_FILE" \
        --arg KEY_FILE "$KEY_FILE" \
        --arg REALITY_PRIVATE "$REALITY_PRIVATE" \
        --arg REALITY_PUBLIC "$REALITY_PUBLIC" \
        --arg REALITY_SHORT_ID "$REALITY_SHORT_ID" \
        --arg REALITY_SNI "$REALITY_SNI" \
        '{
            PROTOCOL:$PROTOCOL,
            DOMAIN:$DOMAIN,
            PORT:$PORT,
            UUID:$UUID,
            PATH_VALUE:$PATH_VALUE,
            SECURITY:$SECURITY,
            TUNNEL:$TUNNEL,
            CERT_FILE:$CERT_FILE,
            KEY_FILE:$KEY_FILE,
            REALITY_PRIVATE:$REALITY_PRIVATE,
            REALITY_PUBLIC:$REALITY_PUBLIC,
            REALITY_SHORT_ID:$REALITY_SHORT_ID,
            REALITY_SNI:$REALITY_SNI
        }' > "$tmp"

    chmod 0600 "$tmp"
    mv -f "$tmp" "$STATE"
}

load_state() {
    [[ -s "$STATE" ]] || return 1

    jq -e 'type == "object"' "$STATE" >/dev/null 2>&1 || {
        warn "配置文件格式不正确"
        return 1
    }

    PROTOCOL="$(jq -r '.PROTOCOL // ""' "$STATE")"
    DOMAIN="$(jq -r '.DOMAIN // ""' "$STATE")"
    PORT="$(jq -r '.PORT // ""' "$STATE")"
    UUID="$(jq -r '.UUID // ""' "$STATE")"
    PATH_VALUE="$(jq -r '.PATH_VALUE // ""' "$STATE")"
    SECURITY="$(jq -r '.SECURITY // ""' "$STATE")"
    TUNNEL="$(jq -r '.TUNNEL // "no"' "$STATE")"
    CERT_FILE="$(jq -r '.CERT_FILE // ""' "$STATE")"
    KEY_FILE="$(jq -r '.KEY_FILE // ""' "$STATE")"
    REALITY_PRIVATE="$(jq -r '.REALITY_PRIVATE // ""' "$STATE")"
    REALITY_PUBLIC="$(jq -r '.REALITY_PUBLIC // ""' "$STATE")"
    REALITY_SHORT_ID="$(jq -r '.REALITY_SHORT_ID // ""' "$STATE")"
    REALITY_SNI="$(jq -r '.REALITY_SNI // "www.microsoft.com"' "$STATE")"

    [[ -n "$PROTOCOL" && -n "$DOMAIN" && -n "$PORT" && -n "$UUID" ]] || {
        warn "节点配置不完整"
        return 1
    }

    return 0
}

get_public_ip() {
    local ip=""

    ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"

    if [[ -z "$ip" ]]; then
        ip="$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    fi

    printf '%s' "$ip"
}

ask_domain() {
    local default_ip

    default_ip="$(get_public_ip)"

    echo
    echo "请输入连接域名或服务器公网 IPv4。"

    [[ -n "$default_ip" ]] && echo "检测到公网 IPv4：$default_ip"

    read -rp "域名/IP（留空使用检测到的 IP）: " DOMAIN

    [[ -n "$DOMAIN" ]] || DOMAIN="$default_ip"
    [[ -n "$DOMAIN" ]] || die "没有获取到公网 IP，请手动输入"

    if ! valid_domain "$DOMAIN" && ! valid_ipv4 "$DOMAIN"; then
        die "域名或 IPv4 格式不正确"
    fi
}

ask_tls_files() {
    echo
    read -rp "TLS 证书完整路径: " CERT_FILE
    read -rp "TLS 私钥完整路径: " KEY_FILE

    [[ -f "$CERT_FILE" ]] || die "证书文件不存在"
    [[ -f "$KEY_FILE" ]] || die "私钥文件不存在"

    openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1 ||
        die "TLS 证书格式不正确"

    openssl pkey -in "$KEY_FILE" -noout >/dev/null 2>&1 ||
        die "TLS 私钥格式不正确"
}

choose_protocol() {
    echo
    echo "========== 选择协议 =========="
    echo "1. VLESS + XHTTP + REALITY"
    echo "2. VLESS + XHTTP + TLS"
    echo "3. VLESS + XHTTP + Cloudflare Tunnel"
    echo "4. VLESS + WS + TLS"
    echo "5. VLESS + WS + Cloudflare Tunnel"
    echo "6. VLESS + gRPC + TLS"
    echo "7. VLESS + HTTPUpgrade + TLS"
    echo "0. 返回"
    echo "=============================="

    read -rp "请选择: " choice

    case "$choice" in
        1)
            PROTOCOL="xhttp-reality"
            SECURITY="reality"
            TUNNEL="no"
            ;;
        2)
            PROTOCOL="xhttp-tls"
            SECURITY="tls"
            TUNNEL="no"
            ;;
        3)
            PROTOCOL="xhttp-tunnel"
            SECURITY="none"
            TUNNEL="yes"
            ;;
        4)
            PROTOCOL="ws-tls"
            SECURITY="tls"
            TUNNEL="no"
            ;;
        5)
            PROTOCOL="ws-tunnel"
            SECURITY="none"
            TUNNEL="yes"
            ;;
        6)
            PROTOCOL="grpc-tls"
            SECURITY="tls"
            TUNNEL="no"
            ;;
        7)
            PROTOCOL="httpupgrade-tls"
            SECURITY="tls"
            TUNNEL="no"
            ;;
        0)
            return 1
            ;;
        *)
            warn "无效选择"
            return 1
            ;;
    esac
}

make_reality_keys() {
    local output

    command -v xray >/dev/null 2>&1 || die "Xray 尚未安装，无法生成 REALITY 密钥"

    output="$(xray x25519 2>&1)" || {
        printf '%s\n' "$output"
        die "生成 REALITY 密钥失败"
    }

    REALITY_PRIVATE="$(
        printf '%s\n' "$output" |
        sed -nE 's/.*(PrivateKey|Private key):[[:space:]]*([^[:space:]]+).*/\2/p' |
        head -n1
    )"

    REALITY_PUBLIC="$(
        printf '%s\n' "$output" |
        sed -nE 's/.*(Password|PublicKey|Public key):[[:space:]]*([^[:space:]]+).*/\2/p' |
        head -n1
    )"

    [[ -n "$REALITY_PRIVATE" ]] || {
        printf '%s\n' "$output"
        die "无法识别 Xray 私钥输出格式"
    }

    [[ -n "$REALITY_PUBLIC" ]] ||
        die "无法识别 Xray 公钥输出格式"

    REALITY_SHORT_ID="$(openssl rand -hex 4)"
    REALITY_SNI="www.microsoft.com"
}

build_config() {
    local inbound stream security_settings
    local listen_addr="0.0.0.0"

    [[ "$TUNNEL" == "yes" ]] && listen_addr="127.0.0.1"

    case "$PROTOCOL" in
        xhttp-reality)
            make_reality_keys

            stream="$(jq -n \
                --arg path "$PATH_VALUE" \
                --arg private "$REALITY_PRIVATE" \
                --arg sni "$REALITY_SNI" \
                --arg sid "$REALITY_SHORT_ID" \
                '{
                    network:"xhttp",
                    security:"reality",
                    xhttpSettings:{
                        path:$path,
                        mode:"auto"
                    },
                    realitySettings:{
                        show:false,
                        dest:($sni + ":443"),
                        xver:0,
                        serverNames:[$sni],
                        privateKey:$private,
                        shortIds:[$sid]
                    }
                }')"
            ;;

        xhttp-tls|xhttp-tunnel)
            stream="$(jq -n \
                --arg security "$SECURITY" \
                --arg path "$PATH_VALUE" \
                '{
                    network:"xhttp",
                    security:$security,
                    xhttpSettings:{
                        path:$path,
                        mode:"auto"
                    }
                }')"
            ;;

        ws-tls|ws-tunnel)
            stream="$(jq -n \
                --arg security "$SECURITY" \
                --arg path "$PATH_VALUE" \
                '{
                    network:"ws",
                    security:$security,
                    wsSettings:{
                        path:$path
                    }
                }')"
            ;;

        grpc-tls)
            stream='{
                "network":"grpc",
                "security":"tls",
                "grpcSettings":{
                    "serviceName":"grpc"
                }
            }'
            ;;

        httpupgrade-tls)
            stream="$(jq -n \
                --arg security "$SECURITY" \
                --arg path "$PATH_VALUE" \
                '{
                    network:"httpupgrade",
                    security:$security,
                    httpupgradeSettings:{
                        path:$path
                    }
                }')"
            ;;

        *)
            die "未知协议：$PROTOCOL"
            ;;
    esac

    security_settings='{}'

    if [[ "$SECURITY" == "tls" && "$TUNNEL" == "no" ]]; then
        security_settings="$(jq -n \
            --arg cert "$CERT_FILE" \
            --arg key "$KEY_FILE" \
            '{
                certificates:[{
                    certificateFile:$cert,
                    keyFile:$key
                }]
            }')"
    fi

    inbound="$(jq -n \
        --arg listen "$listen_addr" \
        --argjson port "$PORT" \
        --arg uuid "$UUID" \
        --argjson stream "$stream" \
        --argjson tls "$security_settings" \
        '{
            listen:$listen,
            port:$port,
            protocol:"vless",
            settings:{
                clients:[{id:$uuid}],
                decryption:"none"
            },
            streamSettings:(
                $stream +
                (if $stream.security=="tls"
                 then {tlsSettings:$tls}
                 else {}
                 end)
            ),
            sniffing:{
                enabled:true,
                destOverride:["http","tls"]
            }
        }')"

    install -d -m 0700 "$XHTTP_DIR"

    jq -n \
        --argjson inbound "$inbound" \
        '{
            log:{loglevel:"warning"},
            inbounds:[$inbound],
            outbounds:[{
                protocol:"freedom",
                tag:"direct"
            }]
        }' > "$CONFIG"

    chmod 0600 "$CONFIG"
}

install_node() {
    local tunnel_token=""

    choose_protocol || return 0

    ask_domain

    PORT="$(random_port)"
    UUID="$(random_uuid)"
    PATH_VALUE="$(random_path)"

    CERT_FILE=""
    KEY_FILE=""
    REALITY_PRIVATE=""
    REALITY_PUBLIC=""
    REALITY_SHORT_ID=""

    if [[ "$SECURITY" == "tls" && "$TUNNEL" == "no" ]]; then
        ask_tls_files
    fi

    if [[ "$PROTOCOL" == "grpc-tls" ]]; then
        PATH_VALUE="grpc"
    fi

    if [[ "$TUNNEL" == "yes" ]]; then
        echo
        read -rsp "Cloudflare Tunnel Token: " tunnel_token
        echo

        [[ -n "$tunnel_token" ]] || die "Tunnel Token 不能为空"
    fi

    core_install latest

    build_config
    core_validate
    core_service_install

    if [[ "$TUNNEL" == "yes" ]]; then
        tunnel_install "$tunnel_token"
        tunnel_configure_http "$DOMAIN" "$PORT"
    fi

    save_state
    print_link

    ok "安装流程完成"
}

print_link() {
    local link=""
    local link_port="$PORT"
    local security_query=""

    if [[ "$TUNNEL" == "yes" ]]; then
        link_port="443"
    fi

    case "$PROTOCOL" in
        xhttp-reality)
            security_query="security=reality&pbk=${REALITY_PUBLIC}&fp=chrome&sid=${REALITY_SHORT_ID}&sni=${REALITY_SNI}"

            link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&${security_query}&type=xhttp&path=${PATH_VALUE}&mode=auto#XHTTP-REALITY"
            ;;

        xhttp-tls|xhttp-tunnel)
            link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=tls&sni=${DOMAIN}&type=xhttp&path=${PATH_VALUE}&mode=auto#XHTTP-TLS"
            ;;

        ws-tls|ws-tunnel)
            link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${PATH_VALUE}#WS-TLS"
            ;;

        grpc-tls)
            link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=tls&sni=${DOMAIN}&type=grpc&serviceName=grpc#GRPC-TLS"
            ;;

        httpupgrade-tls)
            link="vless://${UUID}@${DOMAIN}:${link_port}?encryption=none&security=tls&sni=${DOMAIN}&type=httpupgrade&path=${PATH_VALUE}#HTTPUpgrade-TLS"
            ;;

        *)
            die "无法生成节点链接"
            ;;
    esac

    echo
    echo "========== 节点信息 =========="
    echo "协议：$PROTOCOL"
    echo "地址：$DOMAIN"
    echo "公网端口：$link_port"

    if [[ "$TUNNEL" == "yes" ]]; then
        echo "Xray 本地端口：$PORT"
    fi

    echo "UUID：$UUID"
    echo "路径/服务名：$PATH_VALUE"

    if [[ "$PROTOCOL" == "xhttp-reality" ]]; then
        echo "REALITY SNI：$REALITY_SNI"
        echo "REALITY 公钥：$REALITY_PUBLIC"
        echo "REALITY Short ID：$REALITY_SHORT_ID"
    fi

    echo
    echo "$link"
    echo "=============================="
}

show_status() {
    echo
    echo "========== XHTTP 状态 =========="

    if command -v xray >/dev/null 2>&1; then
        xray version | head -n2
    else
        echo "Xray 尚未安装"
    fi

    core_os || return 0

    if [[ "$OS_FAMILY" == "systemd" ]]; then
        systemctl --no-pager --full status xhttp 2>/dev/null |
            head -n12 || true
    else
        rc-service xhttp status 2>/dev/null || true
    fi

    tunnel_status || true
}

uninstall_all() {
    local confirm

    echo
    warn "此操作只清理本脚本管理的 XHTTP 服务及配置。"

    read -rp "确认卸载 XHTTP？输入 YES 继续: " confirm

    [[ "$confirm" == "YES" ]] || return 0

    core_service_stop || true
    tunnel_uninstall || true

    rm -rf "$XHTTP_DIR"

    # 只删除本脚本安装的模块文件，不清空整个目录。
    rm -f "$LIB_DIR/core.sh" "$LIB_DIR/tunnel.sh"
    rmdir "$LIB_DIR" 2>/dev/null || true

    ok "XHTTP 配置和本脚本服务已清理"
    warn "没有删除系统 Xray 二进制，避免影响其他项目。"
}

install_modules() {
    install -d -m 0755 "$LIB_DIR"

    install -m 0644 "$CORE_FILE" "$LIB_DIR/core.sh"
    install -m 0644 "$TUNNEL_FILE" "$LIB_DIR/tunnel.sh"
}

main_menu() {
    while true; do
        echo
        echo "===================================="
        echo "       XHTTP Manager V${VERSION}"
        echo "===================================="
        echo "1. 安装 / 配置节点"
        echo "2. 查看运行状态"
        echo "3. 更新 Xray 内核"
        echo "4. Cloudflare Tunnel 管理"
        echo "5. 查看当前节点信息"
        echo "6. 卸载 XHTTP 服务及配置"
        echo "0. 退出"
        echo "===================================="

        read -rp "请选择: " choice

        case "$choice" in
            1)
                install_node
                ;;
            2)
                show_status
                ;;
            3)
                core_update latest
                ;;
            4)
                tunnel_menu
                ;;
            5)
                if load_state; then
                    print_link
                else
                    warn "尚无节点配置"
                fi
                ;;
            6)
                uninstall_all
                ;;
            0)
                exit 0
                ;;
            *)
                warn "无效选项"
                ;;
        esac
    done
}

main() {
    require_root
    load_modules

    core_deps
    require_commands

    install_modules
    main_menu
}

main "$@"