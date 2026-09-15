#!/usr/bin/env bash
set -Eeuo pipefail

# 只接管 Hindsight 运行 UID 发起的 TCP 出站。
# Xray 自身以 root 运行，因此不会再次命中该规则，不会形成代理回环。
# 国内/海外最终分流仍由现有 Xray routing 决定。

XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
TPROXY_PORT="${HINDSIGHT_TRANSPARENT_PORT:-12345}"
HINDSIGHT_UID="${HINDSIGHT_UID:-}"
CHAIN="HINDSIGHT_XRAY"
SERVICE="hindsight-transparent-proxy.service"
BACKUP_DIR="/var/lib/memory-server-infra/xray-backups"

log(){ printf '\n[INFO] %s\n' "$*"; }
warn(){ printf '\n[WARN] %s\n' "$*" >&2; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行。"

for cmd in xray iptables python3 systemctl; do command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"; done
[[ -f "$XRAY_CONFIG" ]] || die "未找到 Xray 配置：$XRAY_CONFIG"

resolve_hindsight_uid(){
  if [[ -n "$HINDSIGHT_UID" ]]; then printf '%s\n' "$HINDSIGHT_UID"; return; fi
  if docker inspect hindsight >/dev/null 2>&1; then
    local uid
    uid="$(docker exec hindsight id -u 2>/dev/null || true)"
    [[ "$uid" =~ ^[0-9]+$ ]] && { printf '%s\n' "$uid"; return; }
  fi
  local image
  image="$(docker inspect hindsight --format '{{.Config.Image}}' 2>/dev/null || true)"
  [[ -n "$image" ]] || image="ghcr.io/vectorize-io/hindsight:latest"
  local uid
  uid="$(docker run --rm --entrypoint sh "$image" -c 'id -u' 2>/dev/null || true)"
  [[ "$uid" =~ ^[0-9]+$ ]] || die "无法确定 Hindsight 运行 UID。可显式设置 HINDSIGHT_UID。"
  printf '%s\n' "$uid"
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
    die "新增透明入口后 Xray 配置校验失败，已自动恢复原配置。"
  fi
  systemctl restart xray
  systemctl is-active --quiet xray || { cp -a "$backup" "$XRAY_CONFIG"; systemctl restart xray || true; die "Xray 重启失败，已尝试恢复原配置。"; }
  log "Xray 已新增本机透明入口 127.0.0.1:${TPROXY_PORT}。"
}

apply_rules(){
  local uid="$1"
  iptables -t nat -N "$CHAIN" 2>/dev/null || true
  iptables -t nat -F "$CHAIN"
  # 本地、私网、链路本地和组播永不进入透明代理。
  for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    iptables -t nat -A "$CHAIN" -d "$cidr" -j RETURN
  done
  iptables -t nat -A "$CHAIN" -p tcp -j REDIRECT --to-ports "$TPROXY_PORT"
  iptables -t nat -D OUTPUT -p tcp -m owner --uid-owner "$uid" -j "$CHAIN" 2>/dev/null || true
  iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner "$uid" -j "$CHAIN"
  log "仅 UID=${uid} 的 TCP 出站会进入 Xray；root/Xray、SSH、Docker daemon 不受影响。"
}

write_service(){
  local uid="$1"
  cat >"/usr/local/sbin/hindsight-transparent-proxy-rules" <<EOF
#!/usr/bin/env bash
set -e
CHAIN="$CHAIN"
PORT="$TPROXY_PORT"
UID_TARGET="$uid"
iptables -t nat -N "\$CHAIN" 2>/dev/null || true
iptables -t nat -F "\$CHAIN"
for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do iptables -t nat -A "\$CHAIN" -d "\$cidr" -j RETURN; done
iptables -t nat -A "\$CHAIN" -p tcp -j REDIRECT --to-ports "\$PORT"
iptables -t nat -D OUTPUT -p tcp -m owner --uid-owner "\$UID_TARGET" -j "\$CHAIN" 2>/dev/null || true
iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner "\$UID_TARGET" -j "\$CHAIN"
EOF
  chmod 0755 /usr/local/sbin/hindsight-transparent-proxy-rules
  cat >"/etc/systemd/system/$SERVICE" <<EOF
[Unit]
Description=Scoped transparent proxy rules for Hindsight
After=network-online.target xray.service docker.service
Wants=network-online.target
Requires=xray.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hindsight-transparent-proxy-rules
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
}

remove_rules(){
  local uid="${1:-}"
  if [[ -n "$uid" ]]; then iptables -t nat -D OUTPUT -p tcp -m owner --uid-owner "$uid" -j "$CHAIN" 2>/dev/null || true; fi
  while iptables -t nat -C OUTPUT -j "$CHAIN" 2>/dev/null; do iptables -t nat -D OUTPUT -j "$CHAIN" || true; done
  iptables -t nat -F "$CHAIN" 2>/dev/null || true
  iptables -t nat -X "$CHAIN" 2>/dev/null || true
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$SERVICE" /usr/local/sbin/hindsight-transparent-proxy-rules
  systemctl daemon-reload
  log "透明代理 iptables 规则与持久化服务已移除。Xray inbound 保留但仅监听 loopback，不对外暴露。"
}

status(){
  local uid; uid="$(resolve_hindsight_uid)"
  echo "Hindsight UID: $uid"
  echo "Transparent port: $TPROXY_PORT"
  systemctl is-active xray || true
  systemctl is-enabled "$SERVICE" 2>/dev/null || true
  iptables -t nat -S OUTPUT | grep -F "$CHAIN" || true
  iptables -t nat -S "$CHAIN" 2>/dev/null || true
  ss -lntp | grep ":${TPROXY_PORT} " || true
}

case "${1:-install}" in
  install)
    uid="$(resolve_hindsight_uid)"
    install_xray_inbound
    apply_rules "$uid"
    write_service "$uid"
    log "安装完成。先运行本脚本 status，再执行 07-hindsight-smoke-test.sh。"
    ;;
  remove) remove_rules "$(resolve_hindsight_uid 2>/dev/null || true)" ;;
  status) status ;;
  *) die "用法：$0 [install|remove|status]" ;;
esac
