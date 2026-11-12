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

# 配置文件与状态存储路径
CONFIG_DIR="/etc/xhttp"
STATUS_FILE="$CONFIG_DIR/status.conf"

mkdir -p "$CONFIG_DIR"

# 加载或初始化状态
load_status() {
    if [ -f "$STATUS_FILE" ]; then
        source "$STATUS_FILE"
    else
        SELECTED_PROTOCOL=""
        CUSTOM_PORT="443"
        DOMAIN=""
        TUNNEL_TYPE="未绑定"
        TUNNEL_TARGET=""
        UUID=$(cat /proc/sys/kernel/random/uuid)
        SUB_PORT="11111"
        SUB_PATH="$UUID"
        SUB_ENABLED="0"
    fi
}

save_status() {
    cat <<EOF > "$STATUS_FILE"
SELECTED_PROTOCOL="$SELECTED_PROTOCOL"
CUSTOM_PORT="$CUSTOM_PORT"
DOMAIN="$DOMAIN"
TUNNEL_TYPE="$TUNNEL_TYPE"
TUNNEL_TARGET="$TUNNEL_TARGET"
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
    es}
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
    [ -z "$TAG" ] && TAG="1.10.0 (获取失败或本地离线)"
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
    es}

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
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "transport": {
        "type": "xhttp",
        "path": "/xhttp"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
}

generate_sub_files() {
    SUB_DIR="$CONFIG_DIR/sub"
    mkdir -p "$SUB_DIR/$SUB_PATH"
    
    LOCAL_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
    [ -z "$LOCAL_IP" ] && LOCAL_IP="127.0.0.1"

    # 生成 Clash/Mihomo 配置
    cat <<EOF > "$SUB_DIR/$SUB_PATH/clmi.yaml"
proxies:
  - name: "xhttp-${SELECTED_PROTOCOL}"
    type: vless
    server: ${LOCAL_IP}
    port: ${CUSTOM_PORT}
    uuid: ${UUID}
    network: xhttp
    xhttp:
      path: "/xhttp"
    tls: true
    flow: xtls-rprx-vision
    skip-cert-verify: true
EOF

    # 生成 Sing-box 配置
    cat <<EOF > "$SUB_DIR/$SUB_PATH/sbox.json"
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "xhttp-node",
      "server": "${LOCAL_IP}",
      "server_port": ${CUSTOM_PORT},
      "uuid": "${UUID}",
      "flow": "xtls-rprx-vision",
      "packet_encoding": "xudp",
      "transport": {
        "type": "xhttp",
        "path": "/xhttp"
      },
      "tls": {
        "enabled": true,
        "insecure": true
      }
    }
  ]
}
EOF

    # 生成聚合协议文本
    cat <<EOF > "$SUB_DIR/$SUB_PATH/jhsub.txt"
vless://${UUID}@${LOCAL_IP}:${CUSTOM_PORT}?encryption=none&flow=xtls-rprx-vision&security=tls&type=xhttp&path=%2Fxhttp#xhttp-%E8%81%9A%E5%90%88%E8%AE%A2%E9%98%85
EOF

    # 启动一个简易 Python HTTP 服务器用于本地订阅托管
    pkill -f "python3 -m http.server $SUB_PORT" 2>/dev/null
    cd "$SUB_DIR" && nohup python3 -m http.server "$SUB_PORT" >/dev/null 2>&1 &
    cd - >/dev/null
}

# 菜单 1：协议组合选择与隧道设置
protocol_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== xhttp 协议组合与隧道配置菜单 ===${PLAIN}"
        echo -e "当前已选协议: ${GREEN}${SELECTED_PROTOCOL:-未选择}${PLAIN}"
        echo -e "当前端口设定: ${GREEN}${CUSTOM_PORT}${PLAIN}"
        echo -e "当前隧道状态: ${GREEN}${TUNNEL_TYPE} (${TUNNEL_TARGET:-无})${PLAIN}"
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
            1)
                SELECTED_PROTOCOL="Vless-xhttp-reality-enc"
                echo -e "${GREEN}已选择: Vless-xhttp-reality-enc${PLAIN}"
                ;;
            2)
                SELECTED_PROTOCOL="Vless-xhttp-enc"
                echo -e "${GREEN}已选择: Vless-xhttp-enc${PLAIN}"
                ;;
            3)
                SELECTED_PROTOCOL="Vless-xhttp-tls-UDP"
                echo -e "${GREEN}已选择: Vless-xhttp-tls-UDP (需要绑定域名)${PLAIN}"
                read -p "请输入您的合法域名 (直接回车跳过): " input_domain
                [ -n "$input_domain" ] && DOMAIN="$input_domain"
                ;;
            4)
                SELECTED_PROTOCOL="Vless-xhttp-tls-TCP/UDP"
                echo -e "${GREEN}已选择: Vless-xhttp-tls-TCP/UDP (需要绑定域名)${PLAIN}"
                read -p "请输入您的合法域名 (直接回车跳过): " input_domain
                [ -n "$input_domain" ] && DOMAIN="$input_domain"
                ;;
            0)
                save_status
                return
                ;;
            "")
                echo -e "${YELLOW}保持当前选择，进入下一步设置...${PLAIN}"
                ;;
            *)
                echo -e "${RED}无效的选择，请重新输入！${PLAIN}"
                sleep 1
                continue
                ;;
        esac

        read -p "请输入自定义端口 [默认 443，直接回车下一步]: " input_port
        if [ -n "$input_port" ]; then
            CUSTOM_PORT="$input_port"
        fi

        # 针对 1 和 2 协议支持隧道配置询问
        if [[ "$SELECTED_PROTOCOL" == *"reality"* || "$SELECTED_PROTOCOL" == *"enc"* ]]; then
            echo -e "----------------------------------------"
            read -p "是否需要配置固定隧道 / Cloudflare Tunnel Token? [y/N]: " configure_tunnel
            if [[ "$configure_tunnel" =~ ^[Yy]$ ]]; then
                read -p "请输入隧道类型 (例如: cloudflare/argo): " TUNNEL_TYPE
                read -p "请输入隧道域名或 Token 密钥: " TUNNEL_TARGET
                echo -e "${GREEN}隧道参数已记录！${PLAIN}"
            else
                TUNNEL_TYPE="未绑定"
                TUNNEL_TARGET=""
            fi
        fi

        save_status
        echo -e "${GREEN}配置已保存！${PLAIN}"
        read -p "按回车键返回主菜单..."
        break
    done
}

# 菜单 2：确认安装
do_install() {
    if [ -z "$SELECTED_PROTOCOL" ]; then
        echo -e "${RED}错误：您尚未在菜单 1 中选择任何协议组合！请先选择协议。${PLAIN}"
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

    # 注册全局快捷指令 "xhttp"
    if [ -f /usr/local/bin/hxttp.sh ]; then
        ln -sf /usr/local/bin/hxttp.sh /usr/local/bin/xhttp
    else
        # 将当前脚本复制到全局 bin
        cp "$0" /usr/local/bin/xhttp
        chmod +x /usr/local/bin/xhttp
    fi

    save_status
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}  xhttp 安装成功！全局指令 'xhttp' 已生效 ${PLAIN}"
    echo -e "${GREEN}  当前组合: ${SELECTED_PROTOCOL}        ${PLAIN}"
    echo -e "${GREEN}  监听端口: ${CUSTOM_PORT}              ${PLAIN}"
    echo -e "${GREEN}  节点 UUID: ${UUID}                    ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    read -p "按回车键返回主菜单..."
}

# 菜单 3：卸载脚本及内核
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

# 菜单 4：设置本地IP订阅分享链接 (对应您的子菜单需求)
sub_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== 设置本地IP订阅分享链接 ===${PLAIN}"
        echo -e " 1: 重置安装本地 IP 订阅链接"
        echo -e " 2: 更换订阅链接路径密码"
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
                echo -e "${GREEN}本地 IP 订阅链接已成功生成并挂载！${PLAIN}"
                echo -e "----------------------------------------"
                echo -e "Clash/Mihomo本地IP订阅地址：http://${LOCAL_IP}:${SUB_PORT}/${SUB_PATH}/clmi.yaml"
                echo -e "Sing-box本地IP订阅地址：http://${LOCAL_IP}:${SUB_PORT}/${SUB_PATH}/sbox.json"
                echo -e "聚合协议本地IP订阅地址：http://${LOCAL_IP}:${SUB_PORT}/${SUB_PATH}/jhsub.txt"
                echo -e "----------------------------------------"
                read -p "按回车键继续..."
                ;;
            2)
                read -p "请输入新的路径密码 (UUID 格式或自定义字符串): " new_path
                [ -n "$new_path" ] && SUB_PATH="$new_path"
                generate_sub_files
                save_status
                echo -e "${GREEN}订阅路径密码已更新！${PLAIN}"
                read -p "按回车键继续..."
                ;;
            3)
                read -p "请输入新的订阅端口 [默认 11111]: " new_port
                [ -n "$new_port" ] && SUB_PORT="$new_port"
                generate_sub_files
                save_status
                echo -e "${GREEN}订阅端口已更新！${PLAIN}"
                read -p "按回车键继续..."
                ;;
            4)
                SUB_ENABLED="0"
                pkill -f "python3 -m http.server $SUB_PORT" 2>/dev/null
                save_status
                echo -e "${GREEN}本地 IP 订阅链接已卸载关闭。${PLAIN}"
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项！${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

# 主菜单循环
main_menu() {
    LATEST_VER=$(get_latest_version)
    LOCAL_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
    [ -z "$LOCAL_IP" ] && LOCAL_IP="127.0.0.1"

    while true; do
        clear
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e "${BLUE}       xhttp 一键管理脚本 v2.0          ${PLAIN}"
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e " ${YELLOW}【系统状态看板】${PLAIN}"
        echo -e " • 官方最新内核版本 : ${GREEN}v${LATEST_VER}${PLAIN}"
        echo -e " • 当前协议组合     : ${GREEN}${SELECTED_PROTOCOL:-未配置}${PLAIN}"
        echo -e " • 监听服务端口     : ${GREEN}${CUSTOM_PORT}${PLAIN}"
        echo -e " • 隧道绑定状态     : ${GREEN}${TUNNEL_TYPE} (${TUNNEL_TARGET:-无})${PLAIN}"
        if [ "$SUB_ENABLED" = "1" ]; then
            echo -e " • 本地订阅服务     : ${GREEN}运行中 (端口: ${SUB_PORT})${PLAIN}"
        else
            echo -e " • 本地订阅服务     : ${YELLOW}未开启${PLAIN}"
        fi
        echo -e "----------------------------------------"
        echo -e " 1. 配置并选择协议组合与隧道"
        echo -e " 2. 确认安装 xhttp 节点 (注册快捷指令 'xhttp')"
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
