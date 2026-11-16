
# xhttp
xhttp多协议组合

curl：

bash <(curl -fsSL https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')



wget：



bash <(wget -qO- https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')




XHTTP Manager V4.8.5
===================

本包基于 V4.8.4-R1 现有代码进行增量修改，保留 core.sh / tunnel.sh 模块版本及现有节点部署架构。

文件
----
xhttp.sh                 主菜单、节点管理、本地订阅服务管理
core.sh                  原 V4.7 核心模块（保持不变）
tunnel.sh                原 V4.8 Tunnel 模块（保持不变）
local_sub_server.py      本地订阅 HTTP 服务
local_sub_builder.py     多实例订阅汇总生成器

V4.8.5 变更
-----------
1. 版本号更新为 4.8.5；兼容识别已有 4.8.1、4.8.2-candidate、4.8.3、4.8.4 实例标记。
2. 主菜单每次显示时列出有效部署节点及总数；补充 TLS/证书文件状态、REALITY SNI、Argo 临时/固定域名、Cloudflare Path 模式。
3. 本地订阅安装不再要求当前实例预先生成三份订阅文件。生成器扫描 /etc/xhttp 和 /etc/xhttp-N 下具有匹配项目标记及有效 state.json 的实例。
4. 汇总支持 XHTTP REALITY、XHTTP TLS、XHTTP Tunnel、WS TLS、WS Tunnel、gRPC TLS、HTTPUpgrade TLS；按节点状态生成聚合 URI、Sing-box JSON、Mihomo/Clash YAML；XHTTP TLS/Tunnel 保留 H2/H3 两种客户端节点。
5. 三个地址共用同一端口及 UUID 路径密码：/UUID/clmi.yaml、/UUID/sbox.json、/UUID/jhsub.txt。
6. 无有效节点时清楚提示并拒绝生成空订阅。
7. 完整卸载在确认并完成后退出管理菜单；取消确认不会退出。卸载时仅处理带项目注释且启动路径匹配的本实例本地订阅服务。
8. 保留原主菜单编号：7 本地订阅链接；8 完整卸载，仍为卸载项且位于最后一个功能项。
9. XMUX/Extra JSON 仍默认关闭；只有节点状态显式启用 XMUX 时，才向支持的 XHTTP URI、Xray JSON、Mihomo 配置传递参数。

安装/升级提示
--------------
请先备份 VPS 上现有 XHTTP Manager 配置。将 ZIP 解压到单独目录，确认包含全部文件后，以 root 执行：
  bash xhttp.sh

不要只上传 xhttp.sh 单文件；主程序需要同目录的 core.sh、tunnel.sh、local_sub_server.py、local_sub_builder.py。

本地订阅服务由当前管理实例托管，服务端监听 0.0.0.0:<订阅端口>。请在防火墙/安全组中仅开放需要访问的端口，并妥善保管 UUID 路径密码。订阅链接包含节点凭据，不要公开分享。

重要验证边界
------------
本包完成了本地静态/模拟测试；未在用户 VPS 上实机安装，未验证真实 Cloudflare Tunnel、真实证书环境、v2rayN 或 Mihomo/Sing-box 客户端导入与连通性。Sing-box 的 XHTTP transport 支持情况取决于用户使用的具体版本/构建。
