#!/usr/bin/env bash
set -Eeuo pipefail

# 只接管 Hindsight 容器 cgroup 发起的 TCP 出站。
# 不再按 UID 匹配：容器 UID 可能与宿主机 ubuntu 用户相同，按 UID 会误伤宿主机流量。
# 国内/海外最终分流仍由现有 Xray routing 决定。

XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
TPROXY_PORT="${HINDSIGHT_TRANSPARENT_PORT:-12345}"
CHAIN="HINDSIGHT_XRAY"
SERVICE="hindsight-transparent-proxy.service"
BACKUP_DIR="/var/lib/memory-server-infra/xray-backups"
RULE_HELPER="/usr/local/sbin/hindsight-transparent-proxy-rules"

ok(){ printf '\n[✓] %s\n' "$*"; }
info(){ printf '\n[→] %s\n' "$*"; }
warn(){ printf '\n[!] %s\n' "$*" >&2; }
die(){ printf '\n[✗] %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行。"

for cmd in xray iptables python3 systemctl docker; do command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"; done
[[ -f "$XRAY_CONFIG" ]] || die "未找到 Xray 配置：$XRAY_CONFIG"
[[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)" == "cgroup2fs" ]] || die "当前服务器不是 cgroup v2，暂不能安全启用 Hindsight 专属透明代理。"
iptables -m cgroup -h >/dev/null 2>&1 || die "当前 iptables 不支持 cgroup 匹配，无法安全隔离 Hindsight 网络。"

resolve_hindsight_cgroup(){
  local pid path i
  for i in $(seq 1 60); do
    pid="$(docker inspect -f '{{.State.Pid}}' hindsight 2>/dev/null || true)"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [[ -r "/proc/$pid/cgroup" ]]; then
      path="$(awk -F: '$1=="0" {print $3; exit}' "/proc/$pid/cgroup")"
      path="${path#/}"
      if [[ -n "$path" ]]; then printf '%s\n' "$path"; return 0; fi
    fi
    sleep 2
  done
  die "120 秒内没有找到正在运行的 Hindsight 容器 cgroup。"
}

install_xray_inbound(){
  mkdir -p "$BACKUP_DIR"
  local backup="$BACKUP_DIR/config.$(date +%Y%m%d-%H%M%S).json"
  cp -a "$XRAY_CONFIG" "$backup"
  python3 - "$XRAY_CONFIG" "$TPROXY_PORT" <<'PY'
import json, sys
p, port = sys.argv[1], int(sys.argv[2])
with open(p, 'r', encoding='utf-8') as f:
    cfg = json.load(f)
inbounds = cfg.setdefault('inbounds', [])
tag = 'hindsight-transparent'
new = {
    'tag': tag,
    'listen': '127.0.0.1',
    'port': port,
    'protocol': 'dokodemo-door',
    'settings': {'network': 'tcp', 'followRedirect': True},
    'sniffing': {'enabled': True, 'destOverride': ['http', 'tls']}
}
for i, item in enumerate(inbounds):
    if item.get('tag') == tag:
        inbounds[i] = new
        break
else:
    inbounds.append(new)
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
  if ! xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
    cp -a "$backup" "$XRAY_CONFIG"
    die "新增透明入口后 Xray 配置校验失败，已恢复原配置。"
  fi
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  systemctl is-active --quiet xray || { cp -a "$backup" "$XRAY_CONFIG"; systemctl restart xray || true; die "Xray 重启失败，已尝试恢复原配置。"; }
  ok "Xray 本机透明入口已准备：127.0.0.1:${TPROXY_PORT}"
}

cleanup_output_jumps(){
  # 删除所有历史 jump，包括旧版 --uid-owner 规则和重复规则。
  while read -r rule; do
    [[ -n "$rule" ]] || continue
    local del="${rule/-A OUTPUT/-D OUTPUT}"
    # shellcheck disable=SC2086
    iptables -t nat $del 2>/dev/null || true
  done < <(iptables -t nat -S OUTPUT 2>/dev/null | grep -F -- "-j $CHAIN" || true)
}

build_chain(){
  iptables -t nat -N "$CHAIN" 2>/dev/null || true
  iptables -t nat -F "$CHAIN"
  for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    iptables -t nat -A "$CHAIN" -d "$cidr" -j RETURN
  done
  iptables -t nat -A "$CHAIN" -p tcp -j REDIRECT --to-ports "$TPROXY_PORT"
}

apply_rules(){
  local cgroup="$1"
  cleanup_output_jumps
  build_chain
  iptables -t nat -A OUTPUT -p tcp -m cgroup --path "$cgroup" -j "$CHAIN"
  ok "透明代理已限定到 Hindsight 容器，不再按宿主机 UID 匹配"
  info "Hindsight cgroup：$cgroup"
}

write_helper(){
  cat >"$RULE_HELPER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
CHAIN="HINDSIGHT_XRAY"
PORT="${HINDSIGHT_TRANSPARENT_PORT:-12345}"
cleanup(){
  while read -r rule; do
    [[ -n "$rule" ]] || continue
    del="${rule/-A OUTPUT/-D OUTPUT}"
    # shellcheck disable=SC2086
    iptables -t nat $del 2>/dev/null || true
  done < <(iptables -t nat -S OUTPUT 2>/dev/null | grep -F -- "-j $CHAIN" || true)
}
resolve(){
  local pid path i
  for i in $(seq 1 60); do
    pid="$(docker inspect -f '{{.State.Pid}}' hindsight 2>/dev/null || true)"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [[ -r "/proc/$pid/cgroup" ]]; then
      path="$(awk -F: '$1=="0" {print $3; exit}' "/proc/$pid/cgroup")"
      path="${path#/}"
      [[ -n "$path" ]] && { printf '%s\n' "$path"; return; }
    fi
    sleep 2
  done
  echo "Hindsight cgroup not found after 120 seconds" >&2
  exit 1
}
[[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)" == "cgroup2fs" ]]
iptables -m cgroup -h >/dev/null 2>&1
CGROUP_PATH="$(resolve)"
cleanup
iptables -t nat -N "$CHAIN" 2>/dev/null || true
iptables -t nat -F "$CHAIN"
for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
  iptables -t nat -A "$CHAIN" -d "$cidr" -j RETURN
done
iptables -t nat -A "$CHAIN" -p tcp -j REDIRECT --to-ports "$PORT"
iptables -t nat -A OUTPUT -p tcp -m cgroup --path "$CGROUP_PATH" -j "$CHAIN"
EOF
  chmod 0755 "$RULE_HELPER"
}

write_service(){
  cat >"/etc/systemd/system/$SERVICE" <<EOF
[Unit]
Description=Scoped transparent proxy rules for Hindsight cgroup
After=network-online.target xray.service docker.service
Wants=network-online.target
Requires=xray.service docker.service

[Service]
Type=oneshot
ExecStart=$RULE_HELPER
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
}

remove_rules(){
  cleanup_output_jumps
  iptables -t nat -F "$CHAIN" 2>/dev/null || true
  iptables -t nat -X "$CHAIN" 2>/dev/null || true
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$SERVICE" "$RULE_HELPER"
  systemctl daemon-reload
  ok "Hindsight 透明代理规则已移除"
}

status(){
  local cgroup="$(resolve_hindsight_cgroup)"
  printf 'Hindsight cgroup: %s\n' "$cgroup"
  printf 'Transparent port: %s\n' "$TPROXY_PORT"
  systemctl is-active xray || true
  systemctl is-enabled "$SERVICE" 2>/dev/null || true
  iptables -t nat -S OUTPUT | grep -F "$CHAIN" || true
  iptables -t nat -S "$CHAIN" 2>/dev/null || true
  ss -lntp | grep ":${TPROXY_PORT} " || true
}

case "${1:-install}" in
  install)
    info "正在把旧版 UID 透明代理迁移为 Hindsight 容器专属 cgroup 规则……"
    cgroup="$(resolve_hindsight_cgroup)"
    install_xray_inbound
    apply_rules "$cgroup"
    write_helper
    write_service
    ok "Hindsight 专属海外网络已安装；宿主机 ubuntu 用户不会再因 UID 相同被误代理"
    info "下一步建议运行：sudo bash scripts/03-hindsight-transparent-proxy.sh status"
    ;;
  remove) remove_rules ;;
  status) status ;;
  *) die "用法：$0 [install|remove|status]" ;;
esac
