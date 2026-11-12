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

SELECTED_PROTOCOL=""
CUSTOM_PORT="443"
DOMAIN=""
UUID=$(cat /proc/sys/kernel/random/uuid)

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
        apt-get update -y && apt-get install -y curl wget jq tar ufw
    elif [ "$PKG_MANAGER" = "apk" ]; then
        apk update && apk add curl wget jq tar ufw iptables
    fi
}

install_singbox() {
    echo -e "${BLUE}正在获取最新官方 sing-box 内核...${PLAIN}"
    TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    [ -z "$TAG" ] && TAG="1.10.0"

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}" && exit 1 ;;
    esac

    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${TAG}/sing-box-${TAG}-linux-${ARCH}.tar.gz"
    curl -L -o sing-box.tar.gz "$DOWNLOAD_URL"
    tar -xzf sing-box.tar.gz
    mv sing-box-${TAG}-linux-${ARCH}/sing-box /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box.tar.gz sing-box-${TAG}-linux-${ARCH}
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

protocol_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== xhttp 协议组合选择菜单 ===${PLAIN}"
        echo -e "当前已选协议: ${GREEN}${SELECTED_PROTOCOL:-未选择}${PLAIN}"
        echo -e "当前端口设定: ${GREEN}${CUSTOM_PORT}${PLAIN}"
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
        echo -e "${GREEN}当前端口已确认设为: $CUSTOM_PORT${PLAIN}"
        read -p "按回车键返回主菜单..."
        break
    done
}

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

    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}  xhttp 安装成功！                      ${PLAIN}"
    echo -e "${GREEN}  当前组合: ${SELECTED_PROTOCOL}        ${PLAIN}"
    echo -e "${GREEN}  监听端口: ${CUSTOM_PORT}              ${PLAIN}"
    echo -e "${GREEN}  节点 UUID: ${UUID}                    ${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
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
        rm -rf /usr/local/bin/sing-box /etc/sing-box
        echo -e "${GREEN}xhttp 已完全卸载。${PLAIN}"
    else
        echo -e "${YELLOW}已取消卸载。${PLAIN}"
    fi
    read -p "按回车键返回主菜单..."
}

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e "${BLUE}       xhttp 一键管理脚本 v1.0          ${PLAIN}"
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e " 1. 配置并选择协议组合 (当前: ${GREEN}${SELECTED_PROTOCOL:-未选择}${PLAIN})"
        echo -e " 2. 确认安装 xhttp 节点"
        echo -e " 3. 卸载脚本及内核"
        echo -e " 0. 退出脚本"
        echo -e "----------------------------------------"
        read -p "请选择操作 [0-3]: " main_choice

        case "$main_choice" in
            1) protocol_menu ;;
            2) do_install ;;
            3) do_uninstall ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项，请输入 0-3！${PLAIN}"; sleep 1 ;;
        esac
    done
}

main_menu
