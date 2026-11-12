#!/usr/bin/env bash
# ====================================================================
# Project Name: xhttp (Official sing-box core multi-protocol manager)
# Supported OS: Ubuntu, Debian, Alpine Linux
# ====================================================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请以 root 用户运行此脚本！${PLAIN}" && exit 1

CONFIG_DIR="/etc/xhttp"
STATUS_FILE="$CONFIG_DIR/status.conf"

mkdir -p "$CONFIG_DIR"

load_status() {
    if [ -f "$STATUS_FILE" ]; then
        source "$STATUS_FILE"
    else
        SELECTED_PROTOCOL="Vless-xhttp-enc"
        CUSTOM_PORT=$((RANDOM % 50000 + 10000))
        DOMAIN=""
        TUNNEL_STATUS="未绑定"
        TUNNEL_DOMAIN=""
        TUNNEL_TOKEN=""
        UUID=$(cat /proc/sys/kernel/random/uuid)
        SUB_PORT=$((RANDOM % 40000 + 10000))
        SUB_PATH="$UUID"
        SUB_ENABLED="0"
    fi
}

save_status() {
    cat <<EOF > "$STATUS_FILE"
SELECTED_PROTOCOL="$SELECTED_PROTOCOL"
CUSTOM_PORT="$CUSTOM_PORT"
DOMAIN="$DOMAIN"
TUNNEL_STATUS="$TUNNEL_STATUS"
TUNNEL_DOMAIN="$TUNNEL_DOMAIN"
TUNNEL_TOKEN="$TUNNEL_TOKEN"
UUID="$UUID"
SUB_PORT="$SUB_PORT"
SUB_PATH="$SUB_PATH"
SUB_ENABLED="$SUB_ENABLED"
EOF
}

load_status

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        echo -e "${RED}无法检测当前系统类型！${PLAIN}" && exit 1
    fi

    case "$OS" in
        ubuntu|debian) PKG_MANAGER="apt" ;;
        alpine) PKG_MANAGER="apk" ;;
        *) echo -e "${RED}暂不支持的系统: $OS。仅支持 Ubuntu, Debian, Alpine。${PLAIN}" && exit 1 ;;
    esac
}

install_dependencies() {
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get update -y && apt-get install -y curl wget jq tar ufw python3
    elif [ "$PKG_MANAGER" = "apk" ]; then
        apk update && apk add curl wget jq tar ufw iptables python3
    fi
}

get_latest_version() {
    TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    [ -z "$TAG" ] && TAG="1.10.0"
    echo "$TAG"
}

install_singbox() {
    echo -e "${BLUE}正在获取最新官方 sing-box 内核...${PLAIN}"
    TAG_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    [ -z "$TAG_VER" ] && TAG_VER="1.10.0"

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}" && exit 1 ;;
    esac

    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${TAG_VER}/sing-box-${TAG_VER}-linux-${ARCH}.tar.gz"
    curl -L -o sing-box.tar.gz "$DOWNLOAD_URL"
    tar -xzf sing-box.tar.gz
    mv sing-box-${TAG_VER}-linux-${ARCH}/sing-box /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box.tar.gz sing-box-${TAG_VER}-linux-${ARCH}
}

setup_service() {
    if [ "$PKG_MANAGER" = "apt" ]; then
        cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=xhttp sing-box service
After=network.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable sing-box
    elif [ "$PKG_MANAGER" = "apk" ]; then
        cat <<EOF > /etc/init.d/sing-box
#!/sbin/openrc-run
name="sing-box"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/sing-box.pid"
command_background="yes"
depend() { need net; }
EOF
        chmod +x /etc/init.d/sing-box && rc-update add sing-box default
    fi
}

generate_config() {
    mkdir -p /etc/sing-box
    cat <<EOF > /etc/sing-box/config.json
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "xhttp-inbound",
      "listen": "::",
      "listen_port": ${CUSTOM_PORT},
      "users": [
        {
          "name": "xhttp-user",
          "uuid": "$UUID"
        }
      ],
      "transport": {
        "type": "xhttp",
        "path": "/${UUID}-argo",
        "mode": "auto"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
}

get_links() {
    LOCAL_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
    [ -z "$LOCAL_IP" ] && LOCAL_IP="127.0.0.1"

    # 严格匹配您提供的标准模板：地址使用优质CDN节点，SNI/Host 指向 Argo 隧道域名
    if [ -n "$TUNNEL_DOMAIN" ]; then
        SNI_HOST="$TUNNEL_DOMAIN"
    else
        SNI_HOST="$LOCAL_IP"
    fi

    XHTTP_PATH="/${UUID}-argo"
    
    # 完全对齐您提供的 H2 和 H3 标准格式
    H2_ADDR="www.visa.com.hk"
    H3_ADDR="www.teamviewer.com"

    TCP_LINK="vless://${UUID}@${H2_ADDR}:443?encryption=none&security=tls&sni=${SNI_HOST}&fp=chrome&alpn=h2&type=xhttp&host=${SNI_HOST}&path=${XHTTP_PATH}&mode=auto#%E1%B4%9C%EA%9C%B1%20H2-Argo%20XHTTP%20%E1%B4%87%EA%9C%B1%EA%9C%B1"
    UDP_LINK="vless://${UUID}@${H3_ADDR}:443?encryption=none&security=tls&sni=${SNI_HOST}&fp=chrome&alpn=h3&type=xhttp&host=${SNI_HOST}&path=${XHTTP_PATH}&mode=auto#%E1%B4%9C%EA%9C%B1%20H3-Argo%20XHTTP%20%E1%B4%87%EA%9C%B1%EA%9C%B1"
}

generate_sub_files() {
    SUB_DIR="$CONFIG_DIR/sub"
    mkdir -p "$SUB_DIR/$SUB_PATH"
    get_links

    cat <<EOF > "$SUB_DIR/$SUB_PATH/clmi.yaml"
proxies:
  - name: "Ṝ H2-Argo XHTTP ᴱṜṜ"
    type: vless
    server: ${H2_ADDR}
    port: 443
    uuid: ${UUID}
    network: xhttp
    xhttp:
      path: "${XHTTP_PATH}"
      mode: "auto"
      host: "${SNI_HOST}"
    tls: true
    sni: ${SNI_HOST}
    alpn: [h2]
    client-fingerprint: chrome
    skip-cert-verify: true
  - name: "Ṝ H3-Argo XHTTP ᴱṜṜ"
    type: vless
    server: ${H3_ADDR}
    port: 443
    uuid: ${UUID}
    network: xhttp
    xhttp:
      path: "${XHTTP_PATH}"
      mode: "auto"
      host: "${SNI_HOST}"
    tls: true
    sni: ${SNI_HOST}
    alpn: [h3]
    client-fingerprint: chrome
    skip-cert-verify: true
EOF

    cat <<EOF > "$SUB_DIR/$SUB_PATH/sbox.json"
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "H2-Argo-XHTTP",
      "server": "${H2_ADDR}",
      "server_port": 443,
      "uuid": "${UUID}",
      "transport": {
        "type": "xhttp",
        "path": "${XHTTP_PATH}",
        "mode": "auto",
        "host": "${SNI_HOST}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${SNI_HOST}",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "alpn": ["h2"],
        "insecure": true
      }
    },
    {
      "type": "vless",
      "tag": "H3-Argo-XHTTP",
      "server": "${H3_ADDR}",
      "server_port": 443,
      "uuid": "${UUID}",
      "transport": {
        "type": "xhttp",
        "path": "${XHTTP_PATH}",
        "mode": "auto",
        "host": "${SNI_HOST}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${SNI_HOST}",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "alpn": ["h3"],
        "insecure": true
      }
    }
  ]
}
EOF

    cat <<EOF > "$SUB_DIR/$SUB_PATH/jhsub.txt"
${TCP_LINK}
${UDP_LINK}
EOF

    pkill -f "python3 -m http.server $SUB_PORT" 2>/dev/null
    (cd "$SUB_DIR" && nohup python3 -m http.server "$SUB_PORT" >/dev/null 2>&1 &)
}

protocol_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== xhttp 协议组合与 Argo 隧道配置菜单 ===${PLAIN}"
        echo -e "当前已选协议: ${GREEN}${SELECTED_PROTOCOL:-未选择}${PLAIN}"
        echo -e "当前端口设定: ${GREEN}${CUSTOM_PORT}${PLAIN}"
        echo -e "固定隧道域名: ${GREEN}${TUNNEL_DOMAIN:-未绑定}${PLAIN}"
        echo -e "----------------------------------------"
        echo -e "1. Vless-xhttp-reality-enc        (支持固定隧道，无须域名)"
        echo -e "2. Vless-xhttp-enc                (原生加密流控，支持隧道)"
        echo -e "3. Vless-xhttp-tls-UDP            (标准 TLS 传输，需域名)"
        echo -e "4. Vless-xhttp-tls-TCP/UDP        (全双工 TLS 传输，需域名)"
        echo -e "----------------------------------------"
        echo -e "0. 返回上一层主菜单"
        echo -e "========================================"
        read -p "请选择协议编号 [1-4] (直接回车可保持/跳过): " proto_choice

        case "$proto_choice" in
            1) SELECTED_PROTOCOL="Vless-xhttp-reality-enc" ;;
            2) SELECTED_PROTOCOL="Vless-xhttp-enc" ;;
            3) 
                SELECTED_PROTOCOL="Vless-xhttp-tls-UDP"
                read -p "请输入您的合法域名 (直接回车跳过): " input_domain
                [ -n "$input_domain" ] && DOMAIN="$input_domain"
                ;;
            4) 
                SELECTED_PROTOCOL="Vless-xhttp-tls-TCP/UDP"
                read -p "请输入您的合法域名 (直接回车跳过): " input_domain
                [ -n "$input_domain" ] && DOMAIN="$input_domain"
                ;;
            0) save_status; return ;;
            "") ;;
            *) echo -e "${RED}无效选择！${PLAIN}"; sleep 1; continue ;;
        esac

        read -p "请输入自定义端口 [留空则保持随机端口 ${CUSTOM_PORT}]: " input_port
        [ -n "$input_port" ] && CUSTOM_PORT="$input_port"

        if [[ "$SELECTED_PROTOCOL" == *"reality"* || "$SELECTED_PROTOCOL" == *"enc"* ]]; then
            echo -e "----------------------------------------"
            read -p "是否需要配置 Argo 固定隧道？[y/N]: " configure_tunnel
            if [[ "$configure_tunnel" =~ ^[Yy]$ ]]; then
                read -p "请输入 Argo 隧道域名 (如 111.nvren.de5.net): " TUNNEL_DOMAIN
                read -p "请输入 Argo 隧道 Token 密钥: " TUNNEL_TOKEN
                TUNNEL_STATUS="已绑定"
            else
                TUNNEL_STATUS="未绑定"
                TUNNEL_DOMAIN=""
                TUNNEL_TOKEN=""
            fi
        fi

        save_status
        echo -e "${GREEN}配置已保存！${PLAIN}"
        read -p "按回车键返回主菜单..."
        break
    done
}

do_install() {
    if [ -z "$SELECTED_PROTOCOL" ]; then
        echo -e "${RED}错误：请先在菜单 1 中选择协议组合！${PLAIN}"
        sleep 2
        return
    fi

    check_os
    echo -e "${BLUE}开始安装环境与官方内核...${PLAIN}"
    install_dependencies
    install_singbox
    generate_config
    setup_service

    if [ "$PKG_MANAGER" = "apt" ]; then
        systemctl restart sing-box
    elif [ "$PKG_MANAGER" = "apk" ]; then
        rc-service sing-box restart
    fi

    cp "$0" /usr/local/bin/xhttp
    chmod +x /usr/local/bin/xhttp

    generate_sub_files
    SUB_ENABLED="1"
    save_status

    clear
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "${GREEN}  xhttp 安装成功！全局指令 'xhttp' 已生效               ${PLAIN}"
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "当前协议组合 : ${BLUE}${SELECTED_PROTOCOL}${PLAIN}"
    echo -e "服务监听端口 : ${BLUE}${CUSTOM_PORT}${PLAIN}"
    echo -e "Argo 隧道域名: ${BLUE}${TUNNEL_DOMAIN:-未绑定}${PLAIN}"
    echo -e "节点 UUID    : ${BLUE}${UUID}${PLAIN}"
    echo -e "------------------------------------------------------"
    echo -e "${YELLOW}【H2-Argo XHTTP 节点链接】${PLAIN}"
    echo -e "${GREEN}${TCP_LINK}${PLAIN}"
    echo -e "------------------------------------------------------"
    echo -e "${YELLOW}【H3-Argo XHTTP 节点链接】${PLAIN}"
    echo -e "${GREEN}${UDP_LINK}${PLAIN}"
    echo -e "======================================================${PLAIN}"
    read -p "按回车键返回主菜单..."
}

do_uninstall() {
    read -p "确认要完全卸载 xhttp (sing-box) 吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        check_os
        if [ "$PKG_MANAGER" = "apt" ]; then
            systemctl stop sing-box 2>/dev/null
            systemctl disable sing-box 2>/dev/null
            rm -f /etc/systemd/system/sing-box.service
            systemctl daemon-reload
        elif [ "$PKG_MANAGER" = "apk" ]; then
            rc-service sing-box stop 2>/dev/null
            rc-update del sing-box default 2>/dev/null
            rm -f /etc/init.d/sing-box
        fi
        rm -rf /usr/local/bin/sing-box /etc/sing-box /etc/xhttp /usr/local/bin/xhttp
        echo -e "${GREEN}xhttp 已完全卸载。${PLAIN}"
    else
        echo -e "${YELLOW}已取消卸载。${PLAIN}"
    fi
    read -p "按回车键返回主菜单..."
}

sub_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== 设置本地IP订阅分享链接 ===${PLAIN}"
        echo -e " 1: 重置安装/生成本地 IP 订阅链接"
        echo -e " 2: 更换订阅链接路径密码 (默认与UUID同路径)"
        echo -e " 3: 更换订阅链接端口"
        echo -e " 4: 卸载本地 IP 订阅链接"
        echo -e " 0: 返回上一层"
        echo -e "----------------------------------------"
        read -p "请选择子菜单操作 [0-4]: " sub_choice

        case "$sub_choice" in
            1)
                SUB_ENABLED="1"
                generate_sub_files
                LOCAL_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
                [ -z "$LOCAL_IP" ] && LOCAL_IP="127.0.0.1"
                save_status
                clear
                echo -e "${GREEN}本地 IP 订阅与标准 Argo 节点链接已成功生成！${PLAIN}"
                echo -e "----------------------------------------"
                echo -e "${YELLOW}【H2-Argo 节点链接】${PLAIN}${GREEN}${TCP_LINK}${PLAIN}"
                echo -e "${YELLOW}【H3-Argo 节点链接】${PLAIN}${GREEN}${UDP_LINK}${PLAIN}"
                echo -e "----------------------------------------"
                echo -e "Clash/Mihomo 订阅地址: http://${LOCAL_IP}:${SUB_PORT}/${SUB_PATH}/clmi.yaml"
                echo -e "Sing-box 订阅地址   : http://${LOCAL_IP}:${SUB_PORT}/${SUB_PATH}/sbox.json"
                echo -e "聚合协议 订阅地址   : http://${LOCAL_IP}:${SUB_PORT}/${SUB_PATH}/jhsub.txt"
                echo -e "----------------------------------------"
                read -p "按回车键继续..."
                ;;
            2)
                read -p "请输入新的路径密码 (直接回车恢复默认UUID): " new_path
                [ -n "$new_path" ] && SUB_PATH="$new_path" || SUB_PATH="$UUID"
                generate_sub_files
                save_status
                echo -e "${GREEN}订阅路径已更新为: ${SUB_PATH}${PLAIN}"
                read -p "按回车键继续..."
                ;;
            3)
                read -p "请输入新的订阅端口 [留空则随机]: " new_port
                [ -n "$new_port" ] && SUB_PORT="$new_port" || SUB_PORT=$((RANDOM % 40000 + 10000))
                generate_sub_files
                save_status
                echo -e "${GREEN}订阅端口已更新为: ${SUB_PORT}${PLAIN}"
                read -p "按回车键继续..."
                ;;
            4)
                SUB_ENABLED="0"
                pkill -f "python3 -m http.server $SUB_PORT" 2>/dev/null
                save_status
                echo -e "${GREEN}本地 IP 订阅服务已关闭。${PLAIN}"
                read -p "按回车键继续..."
                ;;
            0) return ;;
            *) echo -e "${RED}无效选项！${PLAIN}"; sleep 1 ;;
        esac
    done
}

main_menu() {
    LATEST_VER=$(get_latest_version)

    while true; do
        clear
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e "${BLUE}       xhttp 一键管理脚本 v2.7          ${PLAIN}"
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e " ${YELLOW}【系统状态看板】${PLAIN}"
        echo -e " • 官方最新内核版本 : ${GREEN}v${LATEST_VER}${PLAIN}"
        echo -e " • 当前协议组合     : ${GREEN}${SELECTED_PROTOCOL:-未配置}${PLAIN}"
        echo -e " • 监听服务端口     : ${GREEN}${CUSTOM_PORT}${PLAIN}"
        echo -e " • 固定隧道域名     : ${GREEN}${TUNNEL_DOMAIN:-未绑定}${PLAIN}"
        echo -e " • 隧道Token状态    : ${GREEN}${TUNNEL_STATUS}${PLAIN}"
        if [ "$SUB_ENABLED" = "1" ]; then
            echo -e " • 本地订阅服务     : ${GREEN}运行中 (端口: ${SUB_PORT}) [路径: /${SUB_PATH}/]${PLAIN}"
        else
            echo -e " • 本地订阅服务     : ${YELLOW}未开启${PLAIN}"
        fi
        echo -e "----------------------------------------"
        echo -e " 1. 配置并选择协议组合与隧道"
        echo -e " 2. 确认安装 xhttp 节点 (生成标准 Argo H2/H3 节点与订阅)"
        echo -e " 3. 卸载脚本及内核"
        echo -e " 4. 设置本地IP订阅分享链接"
        echo -e " 0. 退出脚本"
        echo -e "========================================"
        read -p "请选择操作 [0-4]: " main_choice

        case "$main_choice" in
            1) protocol_menu ;;
            2) do_install ;;
            3) do_uninstall ;;
            4) sub_menu ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项，请输入 0-4！${PLAIN}"; sleep 1 ;;
        esac
    done
}

main_menu
