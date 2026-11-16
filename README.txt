bash <(curl -fsSL https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')



wget：



bash <(wget -qO- https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')




XHTTP Manager V4.8.7
====================

本版本以用户提供的两个 V4.8.6 包为依据整合：保留可建节点版本的安装主流程，并合入可完整卸载版本的卸载逻辑。不是 V4.8.5 衍生版。

主要修复：
1. 版本号升级为 4.8.7，便于与两个 V4.8.6 包区分。
2. 修复 Xray 26.x REALITY 公钥输出 `Password (PublicKey):` 的解析。
3. 合入 V4.8.6 修改版的实例发现、卸载预检、专用进程清理和旧实例清理逻辑。
4. 识别旧版 V4.8.6 实例标记。
5. 保留 V4.8.6 可建节点版本的安装流程、7 种协议、Tunnel 管理、快捷命令和本地订阅菜单。
6. 保留本地订阅三种格式：Clash/Mihomo、Sing-box、聚合订阅。

安装使用：
- 将 ZIP 解压到服务器目录。
- 在解压目录中以 root 执行：bash xhttp.sh
- 建议不要用 `bash <(curl ...)` 方式启动；快捷命令需要完整包内的 xhttp.sh/core.sh/tunnel.sh 和订阅辅助文件。
- 完整卸载前请确认输入 YES；卸载仅针对 xhttp / xhttp-N 专属命名空间及其专属服务。

安全提醒：
- 不会主动删除 /etc/s-box/ 或 sing-box.service。
- 不会按通用进程名、端口或通用 cloudflared 服务名进行清理。
- 如果检测到符号链接或无法验证归属的服务，会中止卸载以避免误删。

验证范围：本包已做静态语法、Python 编译、密钥解析样例和 ZIP 完整性检查。尚未在真实 Ubuntu/Debian/Alpine VPS 上做端到端安装、重启、客户端连接及卸载验证；不能将本地模拟测试等同于 VPS 实测。
