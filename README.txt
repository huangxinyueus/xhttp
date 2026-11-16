bash <(curl -fsSL https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')



wget：



bash <(wget -qO- https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')




XHTTP Manager V4.8.6 修订版
===========================

本 ZIP 以用户上传的 XHTTP_Manager_V4.8.5 完整压缩包为基线修改。
不需要 GitHub 授权。本次没有登录/修改 GitHub，也没有连接或修改 VPS。

包含文件
--------
- xhttp.sh：管理主程序
- core.sh：V4.8.5 原核心模块（未修改）
- tunnel.sh：V4.8.5 原 Tunnel 模块（未修改）
- local_sub_builder.py：本地订阅生成器（新增 V4.8.6 标记识别）
- local_sub_server.py：V4.8.5 原本地订阅 HTTP 服务（未修改）
- README.txt：本说明
- TEST-REPORT.txt：本次测试报告
- SHA256SUMS.txt：五个程序文件的 SHA256

安装和启动
----------
1. 将 ZIP 上传到 VPS 并解压。
2. 进入 XHTTP_Manager_V4.8.6 目录。
3. 使用 root 执行：bash xhttp.sh
4. 通过菜单 1 安装/配置节点。
5. 安装流程会尝试创建 /usr/local/bin/xhttp 快捷命令；以后可直接输入 xhttp。
   如果该路径已被非本项目程序占用，脚本会保留现有文件，不强行覆盖。

菜单
----
主菜单：
1 安装/配置节点
2 查看运行状态
3 更新 Xray 内核
4 Cloudflare Tunnel 管理
5 查看当前节点信息
6 查看/生成节点链接与订阅
7 本地订阅链接
8 完整卸载全部本项目实例
0 退出

本地订阅菜单：
1 重置安装本地 IP 订阅链接
2 更换订阅链接路径密码
3 更换订阅链接端口
4 卸载本地 IP 订阅链接
0 返回上层

订阅地址形式（仅在本地服务确实就绪时显示）
------------------------------------------
http://本机IP:端口/UUID/clmi.yaml
http://本机IP:端口/UUID/sbox.json
http://本机IP:端口/UUID/jhsub.txt

三种订阅共用端口与 UUID 路径密码。没有有效节点、订阅文件或运行服务时，
主界面不会显示虚假的可用地址。节点安装/配置后，如本地订阅已设置，会尝试刷新。

卸载范围与保护
--------------
菜单 8 会要求输入 YES。目标是清理本项目 xhttp、xhttp-N 专属命名空间及
经专属路径验证的对应 Xray、Cloudflared Tunnel、本地订阅服务和快捷命令。
对符号链接命名空间、无法验证归属的服务定义会中止清理，以避免误删其他项目。

保护范围：
- /etc/s-box/ 及其内容
- sing-box.service
- 通用 cloudflared.service 和不属于本项目专属命名空间的 Cloudflared
- 其他项目的配置、服务和进程

注意
----
本次只完成本地静态/语法和订阅生成模拟检查；未在你的 VPS 实机安装、连接或卸载。
因此不能把本地测试说成 VPS 实测。正式全量卸载前，建议先备份 VPS 配置。
