#!/usr/bin/env bash
# ====================================================================
# Project Name: xhttp (Xray-core & sing-box Dual-Core Multi-Version Manager)
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
        ACTIVE_CORE="sing-box"
        ACTIVE_VERSION="latest"
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
ACTIVE_CORE="$ACTIVE_CORE"
ACTIVE_VERSION="$ACTIVE_VERSION"
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
    es}
}

install_dependencies() {
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt-get update -y && apt-get install -y curl wget jq tar ufw python3 unzip
    elif [ "$PKG_MANAGER" = "apk" ]; then
        apk update && apk add curl wget jq tar ufw iptables python3 unzip
    fi
}

get_latest_version() {
    if [ "$ACTIVE_CORE" = "xray" ]; then
        TAG=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
        [ -z "$TAG" ] && TAG="25.x (获取失败)"
    else
        TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
        [ -z "$TAG" ] && TAG="1.10.x (获取失败)"
    fi
    echo "$TAG"
}

# 安装或切换指定的内核及版本
install_core_version() {
    CORE_TYPE="$1" # xray 或 sing-box
    VERSION_TAG="$2" # 具体版本号或 latest

    check_os
    install_dependencies

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) 
            XRAY_ARCH="64"
            SB_ARCH="amd64" 
            ;;
        aarch64) 
            XRAY_ARCH="arm64-v8a"
            SB_ARCH="arm64" 
            ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}" && exit 1 ;;
    es}

    echo -e "${BLUE}正在部署 ${CORE_TYPE} 内核 (版本: ${VERSION_TAG})...${PLAIN}"

    if [ "$CORE_TYPE" = "xray" ]; then
        if [ "$VERSION_TAG" = "latest" ]; then
            DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"
        else
            DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/v${VERSION_TAG}/Xray-linux-${XRAY_ARCH}.zip"
        fi

        curl -L -o xray.zip "$DOWNLOAD_URL"
        unzip -qo xray.zip -d /tmp/xray
        mv /tmp/xray/xray /usr/local/bin/xray
        chmod +x /usr/local/bin/xray
        rm -rf xray.zip /tmp/xray
        
        # 配置 systemd / openrc 服务指向 xray
        setup_xray_service
        ACTIVE_CORE="xray"
        ACTIVE_VERSION="$VERSION_TAG"

    elif [ "$CORE_TYPE" = "sing-box" ]; then
        if [ "$VERSION_TAG" = "latest" ]; then
            TAG_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
            [ -z "$TAG_VER" ] && TAG_VER="1.10.0"
            DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${TAG_VER}/sing-box-${TAG_VER}-linux-${SB_ARCH}.tar.gz"
            VERSION_TAG="$TAG_VER"
        else
            DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION_TAG}/sing-box-${VERSION_TAG}-linux-${SB_ARCH}.tar.gz"
        fi

        curl -L -o sing-box.tar.gz "$DOWNLOAD_URL"
        tar -xzf sing-box.tar.gz
        mv sing-box-${VERSION_TAG}-linux-${SB_ARCH}/sing-box /usr/local/bin/sing-box
        chmod +x /usr/local/bin/sing-box
        rm -rf sing-box.tar.gz sing-box-${VERSION_TAG}-linux-${SB_ARCH}

        setup_singbox_service
        ACTIVE_CORE="sing-box"
        ACTIVE_VERSION="$VERSION_TAG"
    fi

    save_status
    echo -e "${GREEN}${CORE_TYPE} (v${VERSION_TAG}) 内核安装成功！${PLAIN}"
}

setup_xray_service() {
    if [ "$PKG_MANAGER" = "apt" ]; then
        cat <<EOF > /etc/systemd/system/xhttp.service
[Unit]
Description=xhttp Xray-core service
After=network.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/xray run -c /etc/xhttp/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable xhttp && systemctl restart xhttp
    fi
}

setup_singbox_service() {
    if [ "$PKG_MANAGER" = "apt" ]; then
        cat <<EOF > /etc/systemd/system/xhttp.service
[Unit]
Description=xhttp sing-box service
After=network.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/xhttp/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable xhttp && systemctl restart xhttp
    fi
}

generate_config() {
    mkdir -p /etc/xhttp
    cat <<EOF > /etc/xhttp/config.json
{
  "log": { "loglevel": "info" },
  "inbounds": [
    {
      "port": ${CUSTOM_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "xhttpSettings": {
          "path": "/${UUID}-argo",
          "mode": "auto"
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "direct" }]
}
EOF
}

get_links() {
    LOCAL_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
    [ -z "$LOCAL_IP" ] && LOCAL_IP="127.0.0.1"

    if [ -n "$TUNNEL_DOMAIN" ]; then
        SNI_HOST="$TUNNEL_DOMAIN"
    else
        SNI_HOST="$LOCAL_IP"
    fi

    XHTTP_PATH="/${UUID}-argo"
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
            3) SELECTED_PROTOCOL="Vless-xhttp-tls-UDP" ;;
            4) SELECTED_PROTOCOL="Vless-xhttp-tls-TCP/UDP" ;;
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

    generate_config
    install_core_version "$ACTIVE_CORE" "$ACTIVE_VERSION"

    cp "$0" /usr/local/bin/xhttp
    chmod +x /usr/local/bin/xhttp

    generate_sub_files
    SUB_ENABLED="1"
    save_status

    clear
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "${GREEN}  xhttp 安装成功！全局指令 'xhttp' 已生效               ${PLAIN}🥣"
    echo -e "${GREEN}======================================================${PLAIN}"
    echo -e "当前使用内核 : ${BLUE}${ACTIVE_CORE} (v${ACTIVE_VERSION})${PLAIN}"
    echo -e "当前协议组合 : ${BLUE}${SELECTED_PROTOCOL}${PLAIN}"
    echo -e "服务监听端口 : ${BLUE}${CUSTOM_PORT}${PLAIN}"
    echo -e "Argo 隧道域名: ${BLUE}${TUNNEL_DOMAIN:-未绑定}${PLAIN}"
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
    read -p "确认要完全卸载 xhttp 吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        systemctl stop xhttp 2>/dev/null
        systemctl disable xhttp 2>/dev/null
        rm -f /etc/systemd/system/xhttp.service
        systemctl daemon-reload
        rm -rf /usr/local/bin/xray /usr/local/bin/sing-box /etc/xhttp /usr/local/bin/xhttp
        echo -e "${GREEN}xhttp 及相关内核已完全卸载。${PLAIN}"
    else
        echo -e "${YELLOW}已取消卸载。${PLAIN}"
    fi
    read -p "按回车键返回主菜单..."
}

# 菜单 5：内核版本多版本选择与降级
kernel_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== 内核版本选择与双核切换管理 ===${PLAIN}"
        echo -e "当前运行内核 : ${GREEN}${ACTIVE_CORE} (当前版本: v${ACTIVE_VERSION})${PLAIN}"
        echo -e "----------------------------------------"
        echo -e " 1. Xray-core 内核版本管理 (推荐稳定/支持XHTTP)"
        echo -e " 2. sing-box 内核版本管理 (官方多协议原生支持)"
        echo -e " 0. 返回上一层主菜单"
        echo -e "========================================"
        read -p "请选择操作 [0-2]: " k_choice

        case "$k_choice" in
            1)
                clear
                echo -e "${BLUE}=== Xray-core 版本列表 ===${PLAIN}"
                echo -e " [🔥 最新版本建议] 官方最新稳定版 (Latest)"
                echo -e " [📌 经典历史版本] v1.8.24 (高稳定性版)"
                echo -e " [📌 历史版本]     v1.8.23"
                echo -e "----------------------------------------"
                read -p "请输入要安装的 Xray 版本号 (直接输入版本号如 1.8.24 或输入 latest): " x_ver
                [ -z "$x_ver" ] && x_ver="latest"
                install_core_version "xray" "$x_ver"
                read -p "按回车键继续..."
                ;;
            2)
                clear
                echo -e "${BLUE}=== sing-box 版本列表 ===${PLAIN}"
                echo -e " [🔥 最新版本建议] 官方最新稳定版 (Latest)"
                echo -e " [📌 经典历史版本] 1.10.2 (广泛兼容版)"
                echo -e " [📌 历史版本]     1.9.8"
                echo -e "----------------------------------------"
                read -p "请输入要安装的 sing-box 版本号 (如 1.10.2 或输入 latest): " s_ver
                [ -z "$s_ver" ] && s_ver="latest"
                install_core_version "sing-box" "$s_ver"
                read -p "按回车键继续..."
                ;;
            0) return ;;
            *) echo -e "${RED}无效选项！${PLAIN}"; sleep 1 ;;
        esac
    done
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
    while true; do
        clear
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e "${BLUE}       xhttp 一键管理脚本 v3.0          ${PLAIN}"
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e " ${YELLOW}【系统状态看板】${PLAIN}"
        echo -e " • 当前活跃内核     : ${GREEN}${ACTIVE_CORE} (版本: v${ACTIVE_VERSION})${PLAIN}"
        echo -e " • 当前协议组合     : ${GREEN}${SELECTED_PROTOCOL:-未配置}${PLAIN}"
        echo -e " • 监听服务端口     : ${GREEN}${CUSTOM_PORT}${PLAIN}"
        echo -e " • 固定隧道域名     : ${GREEN}${TUNNEL_DOMAIN:-未绑定}${PLAIN}"
        if [ "$SUB_ENABLED" = "1" ]; then
            echo -e " • 本地订阅服务     : ${GREEN}运行中 (端口: ${SUB_PORT}) [路径: /${SUB_PATH}/]${PLAIN}"
        else
            echo -e " • 本地订阅服务     : ${YELLOW}未开启${PLAIN}"
        fi
        echo -e "----------------------------------------"
        echo -e " 1. 配置并选择协议组合与隧道"
        echo -e " 2. 确认安装 xhttp 节点 (自动生成内核与订阅)"
        echo -e " 3. 卸载脚本及内核"
        echo -e " 4. 设置本地IP订阅分享链接"
        echo -e " 5. 内核版本选择与双核切换管理 (支持新老版本降级)"
        echo -e " 0. 退出脚本"
        echo -e "========================================"
        read -p "请选择操作 [0-5]: " main_choice

        case "$main_choice" in
            1) protocol_menu ;;
            2) do_install ;;
            3) do_uninstall ;;
            4) sub_menu ;;
            5) kernel_menu ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项，请输入 0-5！${PLAIN}"; sleep 1 ;;
        esac
    done
}

main_menu
