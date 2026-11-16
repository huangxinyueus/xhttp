# xhttp
xhttp多协议组合

curl：

bash <(curl -fsSL https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')



wget：



bash <(wget -qO- https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')






XHTTP Manager V4.8.4-R1
=======================

本修订版以用户提供的 V4.8.4 ZIP 为基线，保留原有三个 Shell 脚本主体功能，并新增一个独立的本地订阅 HTTP 服务程序。

文件
----
xhttp.sh              主程序（V4.8.4，修订版）
core.sh               原 V4.7 核心模块（未修改）
tunnel.sh             V4.8 Tunnel 模块（增加无 Path 输出模式）
local_sub_server.py   本地订阅 HTTP 服务端
README.txt            本说明
TEST-REPORT.txt       本轮测试报告
SHA256SUMS.txt        文件 SHA256

Cloudflare Path 模式
--------------------
安装 Cloudflare Tunnel 节点时增加：
1. 指定 Path 模式：保留原有路径规则提示，适用于按不同 Path 分流到不同本地端口。
2. 无 Path 模式（兼容旧版）：Cloudflare Public Hostname 的 Path 字段留空；Service URL 仍指向本节点的 http://localhost:<端口>。Xray 服务端仍使用已生成的路径，客户端路径不变。

无 Path 模式适合单域名对应单个本地服务。它本身不能把同一 Hostname 的多个节点分流到不同本地端口；多节点同域名仍需指定 Path 路由或另行部署统一反向代理。

本地订阅链接
------------
主菜单 7 的子菜单：
1. 重置安装本地IP订阅链接
2. 更换订阅链接路径密码
3. 更换订阅链接端口
4. 卸载本地IP订阅链接
0. 返回上层

三种订阅共用端口和 UUID 路径密码：
http://本地IP:端口/UUID/clmi.yaml
http://本地IP:端口/UUID/sbox.json
http://本地IP:端口/UUID/jhsub.txt

服务独立运行，使用 Python 3 标准库 HTTP Server；请求必须携带正确 UUID 路径。订阅内容分别取自本实例生成的 Clash Meta/Mihomo YAML、sing-box JSON 和原始协议链接列表。卸载本地订阅只移除本实例专属订阅服务及文件，不卸载 Xray/Tunnel。

使用注意
--------
- 本地订阅监听 0.0.0.0；请确保 VPS 防火墙/云安全组允许所选 TCP 端口访问。
- HTTP 明文传输，UUID 路径是访问凭据；不要公开分享完整订阅地址。需要加密传输时建议在可信 HTTPS 反向代理后使用。
- 更换 UUID 后旧地址立即失效；更换端口后旧端口不再由本服务监听。
- 本地订阅服务仅发布当前管理实例生成的订阅文件，不会自动聚合 VPS 上其他 XHTTP 实例。
- XMUX / Extra JSON 仍默认关闭；没有更改原默认行为。
- 本包不自动修改 Cloudflare 账户中的 Public Hostname 路由。

运行
----
解压后将包内文件放在同一目录，以 root 运行：
  bash xhttp.sh

安装过程中会将本地订阅服务程序复制到当前实例专属 LIB_DIR。升级/部署前请先备份生产环境。
