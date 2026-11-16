# xhttp
xhttp多协议组合

curl：

bash <(curl -fsSL https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')



wget：



bash <(wget -qO- https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')







XHTTP Manager V4.8.4
====================

本包基于用户此前保存的 V4.8.3 三脚本基线制作，包含：
- xhttp.sh（主程序 V4.8.4）
- core.sh（保留原 V4.7 核心模块）
- tunnel.sh（保留原 V4.8 Tunnel 模块并更新路由说明）

本次改动
--------
1. 单域名多节点路径路由辅助：
   - 每个 Tunnel 节点显示客户端实际路径、Cloudflare Path 正则和对应 Service URL。
   - 不同节点可使用相同 Hostname、不同 Path、不同 localhost 端口。
   - 多节点必须绑定同一个 Cloudflare Tunnel（同一 Tunnel Token）。每个节点的路径路由需要在 Cloudflare Tunnel 配置中分别添加；本脚本不会擅自调用 Cloudflare API，也不会自动更改用户 Cloudflare 账户。
   - 路由必须保留完整原始请求路径，不能剥离 UUID。Path 示例：^/xhttp<UUID>(/.*)?$；Service 示例：http://localhost:10001。
   - 如果所用控制台界面不提供 Path 匹配，请使用支持 path ingress 的 Tunnel 配置/API；不要把所有节点都配置到同一个 localhost 端口。

2. Extra JSON / XMUX：
   - 仍默认关闭（XMUX_ENABLED=no）。
   - 用户在安装 XHTTP Tunnel 节点时主动开启 XMUX 后，Xray JSON 和 VLESS 分享链接会携带 extra JSON；Mihomo YAML 会输出 xhttp-opts.reuse-settings。
   - Mihomo reuse-settings 需要 Mihomo v1.19.23 或更新版本；旧版可能忽略该字段。
   - v2rayN 的 extra= JSON 参数需要使用支持 XHTTP extra 的版本。分享链接包含该字段不等于客户端一定解析/生效，必须导入后检查客户端生成配置。
   - max-concurrency 与 max-connections 互斥；本包选择 max-concurrency，并将 max-connections 设为 0/不写入 Mihomo YAML。

3. 保留 V4.8.3 已有完整卸载识别/预检逻辑、主菜单 7 本地订阅链接、8 完整卸载（最后一项）及 sing-box 保护边界。

安装/使用
--------
解压 ZIP，将三个 .sh 文件放在同一目录后运行：
  bash xhttp.sh

不要只上传 ZIP 文件到 GitHub 仓库根目录；若需更新仓库，请将三个同名 .sh 文件分别替换仓库根目录的对应文件。

重要验证边界
------------
本包已做 Bash 语法和静态/隔离检查；未在用户 VPS 上运行，也未验证 Cloudflare 账户端配置、v2rayN 实际导入解析或 Mihomo 实际连接成功。不要在生产 VPS 上覆盖安装前跳过备份。
