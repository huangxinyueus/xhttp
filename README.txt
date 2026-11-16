# xhttp
xhttp多协议组合

curl：

bash <(curl -fsSL https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')



wget：



bash <(wget -qO- https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')








XHTTP Manager V4.8.6
===================

本包以用户上传的 XHTTP_Manager_V4.8.5.zip 为唯一正式开发基线进行最小增量修改。
不以 GitHub main 替换源码；core.sh 与 tunnel.sh 保持 V4.8.5 包内原文件不变。

文件
----
xhttp.sh                 主菜单、节点管理、卸载与本地订阅管理
core.sh                  原 V4.7 核心模块（未修改）
tunnel.sh                原 V4.8 Tunnel 模块（未修改）
local_sub_server.py      本地订阅 HTTP 服务（未修改）
local_sub_builder.py     多实例订阅汇总生成器（仅增加 V4.8.6 标记兼容）
TEST-REPORT.txt          本次本地测试报告
SHA256SUMS.txt           本包文件 SHA256

V4.8.6 修复
-----------
1. 主菜单编号保持：7 本地订阅链接；8 完整卸载；0 退出。
2. 本地订阅子菜单返回上层仍为 0；没有改成 5。
3. 安装快捷命令时不再硬编码检查 V4.8.5，而是检查当前 VERSION；V4.8.6 完整包运行安装流程时可安装 /usr/local/bin/xhttp。
4. 完整卸载逐个实例清理前，调用快捷命令专用清理函数；仅当 /usr/local/bin/xhttp 内容精确指向该实例的项目脚本且带项目标记时才删除，并按原逻辑恢复 xhttp-legacy。不会覆盖或删除无法确认归属的同名命令。
5. 主界面节点列表后追加三条本地订阅地址。只有本地订阅服务专用 unit/init 脚本存在、带 XHTTP Manager 专用标记、运行状态正常，且三份订阅文件均非空时才显示；否则不显示虚假可用地址。
6. 本地订阅显示优先获取主路由 IPv4，其次取主机非回环 IPv4，最后尝试公网 IPv4。
7. 订阅生成器新增识别 V4.8.6 实例标记，确保 V4.8.6 节点能被多节点订阅扫描。
8. 保留原实例隔离及卸载保护逻辑；不主动删除 /etc/s-box，不停止 sing-box.service，不清理通用 Cloudflared 或其他项目文件。

订阅 URL 格式说明
-----------------
服务实际监听配置的 TCP 端口，因此标准可访问 URL 格式为：
  http://IP:PORT/UUID/clmi.yaml
  http://IP:PORT/UUID/sbox.json
  http://IP:PORT/UUID/jhsub.txt

注意：端口必须写在主机名后的冒号位置（:PORT），不是 URL 路径段 /PORT。
服务绑定 0.0.0.0:<PORT>；如需从其他设备访问，请在 VPS 防火墙/云安全组放行该 TCP 端口。
三种订阅共用同一端口和 UUID 路径密码。

安装
----
1. 将本 ZIP 解压到独立目录。
2. 确认同一目录存在 xhttp.sh、core.sh、tunnel.sh、local_sub_server.py、local_sub_builder.py。
3. 以 root 执行：bash xhttp.sh
4. 完成节点安装后，运行 xhttp，进入 7 本地订阅链接安装服务。
5. 返回主菜单后，主界面会在节点列表末尾显示三条地址。

升级前请备份 VPS 上现有 XHTTP Manager 配置。不要只上传 xhttp.sh 单文件。

测试边界
--------
本次测试报告明确区分本地静态/模拟测试与 VPS 实机测试。没有连接或修改 GitHub、VPS、Cloudflare 账户或远端服务。
