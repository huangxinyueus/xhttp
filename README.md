# xhttp
xhttp多协议组合

curl：

bash <(curl -fsSL https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')



wget：



bash <(wget -qO- https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')


# XHTTP Manager V4.8

本包基于用户上传的 VPS V4.7 实际运行文件制作。仅更新主脚本和 Cloudflare Tunnel 模块；`core.sh` 保持与原始 V4.7 完全一致。

## 文件

- `xhttp.sh` — V4.8 主菜单、节点生成与本地订阅导出
- `tunnel.sh` — V4.8 固定 Cloudflare Tunnel 模块
- `core.sh` — 原始 V4.7 核心管理模块，未改动

## 固定 Argo XHTTP 节点

固定隧道部署时：

1. Xray 继续使用随机本地监听端口，绑定 `127.0.0.1`。
2. Cloudflared 使用该实例自己的 Token、服务文件和运行脚本。
3. Cloudflare Public Hostname 的 Service 目标应设置为脚本显示的 `http://127.0.0.1:<随机本地端口>`。
4. Cloudflared connector transport 可选 `auto`、`http2`、`quic`。这是 cloudflared 到 Cloudflare 网络这一段的传输方式，不等同于客户端 ALPN。
5. 节点链接使用固定域名的 TLS 边缘入口，按 Cloudflare 默认支持的 HTTPS 端口生成：
   `443, 2053, 2083, 2087, 2096, 8443`。
6. 每个端口生成 H2/TCP 与 H3/UDP 两种 ALPN 链接，共 12 个链接。每个节点都单独打印，并生成聚合订阅。

Cloudflare 端必须启用 HTTP/3，才能使用 H3 节点。HTTP/3 是客户端到 Cloudflare Edge 的连接；Cloudflare 官方说明 HTTP/3 到源站目前不支持。Cloudflare Tunnel 的 connector transport 是独立的一层。

## 本地订阅文件

部署完成后保存在：

`/etc/<实例名>/subscriptions/`

- `links.txt` — 所有节点原始链接，一行一个
- `xray-subscription.b64` — Base64 聚合 VLESS 链接
- `xray.json` — Xray 客户端 JSON 出站配置
- `sing-box.json` — XHTTP 扩展分支使用的 sing-box 风格 JSON
- `clash-meta.yaml` — Clash Meta / Mihomo 配置

**兼容性说明：**当前官方主线 sing-box 尚不支持 XHTTP 传输；`sing-box.json` 仅供明确支持 XHTTP 的第三方扩展分支使用，不能当作官方 sing-box 通用配置。Xray 与当前支持 XHTTP 的 Mihomo/Clash Meta 配置分别导出。

## XHTTP TLS 直连

选择 `VLESS + XHTTP + TLS` 时，脚本会输出：

- H2 / TCP 直连节点
- H3 / UDP 直连节点

并保存对应的本地订阅文件。

## 重要保护

- 不会覆盖、停止或删除原有 `xhttp.service`。
- 不会删除旧的 `/etc/xhttp`。
- 不会操作其他 Cloudflare Tunnel 项目。
- 不会改变实例隔离策略。
- 保留随机本地监听端口。
- 不将临时 Tunnel 混入固定 Tunnel。
- 保留 `/usr/local/bin/xhttp` 快捷命令逻辑和原 GitHub Raw 一键安装入口。

## 发布前检查

本包执行过：

- `bash -n`：三个脚本语法检查
- 核心模块 SHA-256 对比：与上传 ZIP 中 `core.sh` 完全一致
- 节点生成函数测试：固定隧道输出 12 条链接
- Xray / sing-box JSON 语法解析
- Clash Meta YAML 解析
- 直连 XHTTP TLS 输出 H2/H3 两条节点测试

这些是静态与生成器测试，不等同于真实 VPS、Cloudflare Zone、Token 和客户端环境下的端到端连通性测试。首次部署后仍需在 Cloudflare Dashboard 配置 Public Hostname，并实测 H2/H3。

