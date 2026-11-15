# xhttp
xhttp多协议组合

curl：

bash <(curl -fsSL https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')



wget：



bash <(wget -qO- https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')








XHTTP Manager V4.8.1
====================

文件版本关系
------------
- core.sh: V4.7（与上传的 V4.7 原始备份一致，保持不变）
- tunnel.sh: V4.8（保留实例隔离，修正 Tunnel 管理菜单和 Service URL 显示）
- xhttp.sh: V4.8.1（端口选择、订阅节点和实例状态修改）

主要修改
--------
1. 每次选择协议后选择本地监听端口：回车随机选择，输入数字使用自定义端口。
2. 校验端口范围，并同时检查 TCP / UDP 监听占用；冲突时重新选择。
3. Xray 本地监听、Tunnel Service URL、实例状态共用选定的本地端口。
4. Cloudflare Tunnel 公网端口固定为 443，只生成 H2-443 和 H3-443 两个节点。
5. 两个 Tunnel 节点共用 UUID 和路径；节点链接不再添加 01、02 等序号。
6. 保留 Xray、sing-box、Clash Meta / Mihomo 和 Base64 订阅生成。
7. 未配置本地 IP 订阅 URL 时，不在节点输出中显示订阅文件绝对路径；设置 LOCAL_SUB_URL 后才显示该 URL。
8. 菜单 6 完整清理当前已标记实例；旧 /etc/xhttp、旧 xhttp.service 和其他 Tunnel 项目按实例归属检查保护。
9. 保留原 GitHub RAW_BASE_URL 和 README 一键安装入口；旧版管理快捷命令会备份为 xhttp-legacy。

GitHub
------
https://github.com/huangxinyueus/xhttp

原始一键安装入口仍使用仓库 main 分支的 xhttp.sh。需要先将本包的三个脚本发布到仓库 main，之后该入口才会获取 V4.8.1。
本包没有执行 GitHub 上传，也没有提供 VPS 直接覆盖 / 升级命令。

端口说明
--------
- Tunnel 模式：Xray 本地监听端口 = Tunnel Service URL 的回源端口。
- Tunnel 公网订阅端口固定为 443（H2-443 / H3-443）。
- 直连模式：订阅节点使用用户选定的本地监听端口。

测试范围
--------
已完成 bash -n、端口选择与占用检测、Xray 本地入站配置端口、Tunnel Service URL、两节点订阅生成、JSON/YAML 解析、Base64 解码、实例隔离、菜单 6 模拟卸载及快捷命令迁移测试。
未在真实 VPS 上启动服务或验证 Cloudflare 网络连通性。
