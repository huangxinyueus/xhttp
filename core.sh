#!/usr/bin/env bash
# XHTTP Manager V4.7 - isolated Xray core module
set -Eeuo pipefail
umask 077
XHTTP_MODULE_VERSION="4.7"
CORE_MODULE_VERSION="$XHTTP_MODULE_VERSION"
INSTANCE_ID="${INSTANCE_ID:-xhttp}"
XHTTP_DIR="${XHTTP_DIR:-/etc/$INSTANCE_ID}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/$INSTANCE_ID}"
BIN_DIR="/usr/local/bin"
XRAY_BIN="${XRAY_BIN:-$BIN_DIR/xray-$INSTANCE_ID}"
SERVICE_NAME="${SERVICE_NAME:-$INSTANCE_ID}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/$SERVICE_NAME.service}"
OPENRC_FILE="${OPENRC_FILE:-/etc/init.d/$SERVICE_NAME}"
OS_FAMILY=""; PKG=""; XRAY_ARCH=""

core_log(){ printf '[CORE] %s\n' "$*"; }
core_err(){ printf '[CORE ERROR] %s\n' "$*" >&2; }
core_os(){
  [[ -r /etc/os-release ]] || { core_err '无法读取 /etc/os-release'; return 1; }
  . /etc/os-release
  case "${ID:-}" in ubuntu|debian) OS_FAMILY=systemd; PKG=apt-get;; alpine) OS_FAMILY=openrc; PKG=apk;; *) core_err "不支持的系统：${ID:-unknown}"; return 1;; esac
  case "$(uname -m)" in x86_64|amd64) XRAY_ARCH=64;; aarch64|arm64) XRAY_ARCH=arm64-v8a;; armv7l|armv7) XRAY_ARCH=arm32-v7a;; *) core_err "不支持的 CPU 架构：$(uname -m)"; return 1;; esac
}
core_deps(){
  core_os || return 1
  local missing=no cmd
  for cmd in curl jq openssl unzip ss; do
    command -v "$cmd" >/dev/null 2>&1 || missing=yes
  done
  [[ "$missing" == yes ]] || return 0
  if [[ "$PKG" == apt-get ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y bash curl ca-certificates unzip jq openssl iproute2 coreutils
  else
    apk add --no-cache bash curl ca-certificates unzip jq openssl iproute2 coreutils
  fi
}
xray_latest(){ curl -fsSL --retry 3 https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -er '.tag_name | ltrimstr("v")'; }
core_install(){
  local requested="${1:-latest}" version url tmp candidate
  core_os || return 1
  [[ "$PKG" == apt-get ]] || :
  version="$requested"; [[ "$version" == latest ]] && version="$(xray_latest)"
  version="${version#v}"; [[ -n "$version" ]] || { core_err 'Xray 版本号为空'; return 1; }
  url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${XRAY_ARCH}.zip"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/xhttp-xray.XXXXXX")" || return 1
  if ! curl -fL --retry 3 --connect-timeout 15 "$url" -o "$tmp/xray.zip"; then rm -rf -- "$tmp"; core_err '下载 Xray 失败'; return 1; fi
  if ! unzip -oq "$tmp/xray.zip" xray -d "$tmp" || [[ ! -s "$tmp/xray" ]]; then rm -rf -- "$tmp"; core_err 'Xray 压缩包无有效二进制'; return 1; fi
  chmod 0755 "$tmp/xray"
  if ! "$tmp/xray" version >/dev/null 2>&1; then rm -rf -- "$tmp"; core_err '下载的 Xray 无法执行'; return 1; fi
  install -d -m 0755 "$BIN_DIR" "$XHTTP_DIR"
  candidate="$BIN_DIR/.${INSTANCE_ID}-xray.new.$$"
  if ! install -m 0755 "$tmp/xray" "$candidate"; then rm -rf -- "$tmp" "$candidate"; return 1; fi
  if ! "$candidate" version >/dev/null 2>&1; then rm -f "$candidate"; rm -rf -- "$tmp"; core_err '候选 Xray 验证失败'; return 1; fi
  local version_tmp
  version_tmp="$(mktemp "$XHTTP_DIR/version.XXXXXX")" || { rm -f "$candidate"; rm -rf -- "$tmp"; return 1; }
  if ! printf '%s\n' "$version" > "$version_tmp"; then rm -f "$version_tmp" "$candidate"; rm -rf -- "$tmp"; return 1; fi
  chmod 0600 "$version_tmp"
  if ! mv -f "$candidate" "$XRAY_BIN"; then rm -f "$version_tmp" "$candidate"; rm -rf -- "$tmp"; return 1; fi
  if ! mv -f "$version_tmp" "$XHTTP_DIR/xray.version"; then rm -f "$version_tmp"; rm -rf -- "$tmp"; core_err 'Xray 已安装，但版本记录写入失败'; return 1; fi
  rm -rf -- "$tmp"
  core_log "专用 Xray 安装完成：$XRAY_BIN (v$version)"
}
core_validate(){
  [[ -x "$XRAY_BIN" ]] || { core_err "专用 Xray 不存在：$XRAY_BIN"; return 1; }
  [[ -s "$XHTTP_DIR/config.json" ]] || { core_err 'XHTTP 配置不存在'; return 1; }
  "$XRAY_BIN" run -test -config "$XHTTP_DIR/config.json"
}
core_check_service_owner(){
  if [[ "$OS_FAMILY" == systemd ]]; then
    if [[ -f "$SERVICE_FILE" ]]; then
      if ! { grep -q 'XHTTP Manager managed service' "$SERVICE_FILE" && grep -Fq "ExecStart=$XRAY_BIN run -config $XHTTP_DIR/config.json" "$SERVICE_FILE"; }; then
        core_err "$SERVICE_FILE 已存在且无法确认属于本项目，拒绝操作"; return 1
      fi
    elif command -v systemctl >/dev/null 2>&1; then
      local fragment
      fragment="$(systemctl show -p FragmentPath --value "$SERVICE_NAME" 2>/dev/null || true)"
      if [[ -n "$fragment" && "$fragment" != "$SERVICE_FILE" ]]; then
        core_err "检测到其他来源的 $SERVICE_NAME 服务（$fragment），拒绝操作"; return 1
      fi
    fi
  elif [[ "$OS_FAMILY" == openrc && -f "$OPENRC_FILE" ]]; then
    if ! { grep -q 'XHTTP Manager managed service' "$OPENRC_FILE" && grep -Fq "command=\"$XRAY_BIN\"" "$OPENRC_FILE" && grep -Fq "command_args=\"run -config $XHTTP_DIR/config.json\"" "$OPENRC_FILE"; }; then
      core_err "$OPENRC_FILE 已存在且无法确认属于本项目，拒绝操作"; return 1
    fi
  fi
}
core_service_install(){
  core_os || return 1; [[ -x "$XRAY_BIN" ]] || { core_err '专用 Xray 未安装'; return 1; }; core_validate || return 1
  core_check_service_owner || return 1
  if [[ "$OS_FAMILY" == systemd ]]; then
    cat > "$SERVICE_FILE" <<UNIT
# XHTTP Manager managed service
[Unit]
Description=XHTTP Manager isolated Xray service ($INSTANCE_ID)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStart=$XRAY_BIN run -config $XHTTP_DIR/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
UNIT
    chmod 0644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    systemctl is-active --quiet "$SERVICE_NAME" || { core_err 'XHTTP 服务启动失败'; journalctl -u "$SERVICE_NAME" -n 40 --no-pager 2>/dev/null || true; return 1; }
  else
    cat > "$OPENRC_FILE" <<RC
#!/sbin/openrc-run
# XHTTP Manager managed service
name="$SERVICE_NAME"
description="XHTTP Manager isolated Xray service ($INSTANCE_ID)"
command="$XRAY_BIN"
command_args="run -config $XHTTP_DIR/config.json"
command_background="yes"
pidfile="/run/$SERVICE_NAME.pid"
output_log="/var/log/$SERVICE_NAME.log"
error_log="/var/log/$SERVICE_NAME.err"
depend(){ need net; }
RC
    chmod 0755 "$OPENRC_FILE"
    rc-update add "$SERVICE_NAME" default
    rc-service "$SERVICE_NAME" restart || rc-service "$SERVICE_NAME" start
    rc-service "$SERVICE_NAME" status >/dev/null 2>&1 || { core_err 'XHTTP 服务启动失败'; return 1; }
  fi
  core_log 'XHTTP 服务已启动'
}
core_service_stop(){
  core_os || return 0
  core_check_service_owner || return 1
  if [[ "$OS_FAMILY" == systemd ]]; then
    if [[ -f "$SERVICE_FILE" ]] && grep -q 'XHTTP Manager managed service' "$SERVICE_FILE" && grep -Fq "ExecStart=$XRAY_BIN run -config $XHTTP_DIR/config.json" "$SERVICE_FILE"; then systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true; rm -f "$SERVICE_FILE"; systemctl daemon-reload 2>/dev/null || true; fi
  else
    if [[ -f "$OPENRC_FILE" ]] && grep -q 'XHTTP Manager managed service' "$OPENRC_FILE" && grep -Fq "command=\"$XRAY_BIN\"" "$OPENRC_FILE" && grep -Fq "command_args=\"run -config $XHTTP_DIR/config.json\"" "$OPENRC_FILE"; then rc-service "$SERVICE_NAME" stop 2>/dev/null || true; rc-update del "$SERVICE_NAME" default 2>/dev/null || true; rm -f "$OPENRC_FILE" "/run/$SERVICE_NAME.pid" "/var/log/$SERVICE_NAME.log" "/var/log/$SERVICE_NAME.err"; fi
  fi
}
core_service_status(){
  core_os || return 1
  core_check_service_owner || return 1
  if [[ "$OS_FAMILY" == systemd ]]; then systemctl --no-pager --full status "$SERVICE_NAME"; else rc-service "$SERVICE_NAME" status; fi
}
core_update(){
  local version="${1:-latest}" backup="" version_backup="" had_old=no had_version=no
  if [[ -x "$XRAY_BIN" ]]; then
    backup="$(mktemp "${TMPDIR:-/tmp}/xhttp-xray-backup.XXXXXX")" || return 1
    if ! cp -p "$XRAY_BIN" "$backup"; then rm -f "$backup"; return 1; fi
    had_old=yes
  fi
  if [[ -s "$XHTTP_DIR/xray.version" ]]; then
    version_backup="$(mktemp "${TMPDIR:-/tmp}/xhttp-version-backup.XXXXXX")" || { [[ -n "$backup" ]] && rm -f "$backup"; return 1; }
    cp -p "$XHTTP_DIR/xray.version" "$version_backup" || { rm -f "$backup" "$version_backup"; return 1; }
    had_version=yes
  fi
  if core_install "$version" && core_validate && core_service_install; then
    [[ -n "$backup" ]] && rm -f "$backup"
    [[ -n "$version_backup" ]] && rm -f "$version_backup"
    core_log 'Xray 更新完成'
    return 0
  fi
  core_err '更新或配置验证失败，正在回滚专用 Xray 二进制'
  if [[ "$had_old" == yes ]]; then
    install -m 0755 "$backup" "$XRAY_BIN"
    rm -f "$backup"
    if [[ "$had_version" == yes ]]; then install -m 0600 "$version_backup" "$XHTTP_DIR/xray.version"; else rm -f "$XHTTP_DIR/xray.version"; fi
    core_validate || core_err '回滚后配置验证仍失败，请检查配置文件'
    core_service_install || true
  else
    rm -f "$XRAY_BIN" "$XHTTP_DIR/xray.version"
    [[ -n "$version_backup" ]] && rm -f "$version_backup"
  fi
  return 1
}
