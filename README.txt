# xhttp
xhttp多协议组合

curl：

bash <(curl -fsSL https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')



wget：



bash <(wget -qO- https://raw.githubusercontent.com/huangxinyueus/xhttp/refs/heads/main/xhttp.sh | tr -d '\r')







XHTTP Manager V4.8.3 - Uninstall Fix

Package contents
- xhttp.sh: V4.8.3 main script with revised all-instance uninstall discovery.
- core.sh: unchanged V4.7 core module.
- tunnel.sh: unchanged V4.8 Cloudflare Tunnel module.

Uninstall changes
1. Finds valid marked instances under /etc/xhttp and /etc/xhttp-N.
2. Also recognizes orphaned systemd/OpenRC service definitions only when the
   XHTTP Manager ownership comment and exact instance-specific command path match.
3. Performs preflight validation for every candidate before stopping or deleting.
4. For marker-owned instances, removes the instance-scoped directories.
5. For service-recovered instances without a marker, removes only known manager
   files and uses rmdir; unknown files are preserved.
6. Does not search by process name or port, and does not touch /etc/s-box,
   sing-box.service, generic xray/cloudflared, or unknown processes/services.
7. Opening the manager no longer creates a fresh empty instance marker; the
   marker/modules/launcher are prepared only after the user completes the
   deployment prompts and starts an installation.

Important
- This package has NOT been run on the user's VPS.
- Back up the current files before replacing anything.
- Review the displayed candidate instance list before confirming uninstall.
- Unknown or conflicting service definitions cause the whole preflight to abort.
