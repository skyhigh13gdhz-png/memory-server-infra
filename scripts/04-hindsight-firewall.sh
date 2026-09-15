#!/usr/bin/env bash
set -Eeuo pipefail

UNIT=/etc/systemd/system/hindsight-local-only.service
RULE_TAG=memory-server-hindsight-local-only

log(){ printf '\n[INFO] %s\n' "$*"; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行。"
command -v iptables >/dev/null 2>&1 || die "未检测到 iptables。"

# Hindsight 当前使用 host network，原因是容器必须访问宿主机仅监听
# 127.0.0.1:10809 的 Xray。Hindsight 自身会监听 0.0.0.0:8888/9999，
# 因此在主机 INPUT 链明确拒绝所有非 loopback 的这两个端口。
cat >"$UNIT" <<'EOF'
[Unit]
Description=Keep Hindsight API and UI local-only
After=network-online.target docker.service
Wants=network-online.target
Before=memory-server-infra.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/usr/sbin/iptables -C INPUT ! -i lo -p tcp -m multiport --dports 8888,9999 -m comment --comment memory-server-hindsight-local-only -j DROP 2>/dev/null || /usr/sbin/iptables -I INPUT 1 ! -i lo -p tcp -m multiport --dports 8888,9999 -m comment --comment memory-server-hindsight-local-only -j DROP'
ExecStart=/bin/sh -c 'if [ -x /usr/sbin/ip6tables ]; then /usr/sbin/ip6tables -C INPUT ! -i lo -p tcp -m multiport --dports 8888,9999 -m comment --comment memory-server-hindsight-local-only -j DROP 2>/dev/null || /usr/sbin/ip6tables -I INPUT 1 ! -i lo -p tcp -m multiport --dports 8888,9999 -m comment --comment memory-server-hindsight-local-only -j DROP; fi'
ExecStop=/bin/sh -c '/usr/sbin/iptables -D INPUT ! -i lo -p tcp -m multiport --dports 8888,9999 -m comment --comment memory-server-hindsight-local-only -j DROP 2>/dev/null || true'
ExecStop=/bin/sh -c 'if [ -x /usr/sbin/ip6tables ]; then /usr/sbin/ip6tables -D INPUT ! -i lo -p tcp -m multiport --dports 8888,9999 -m comment --comment memory-server-hindsight-local-only -j DROP 2>/dev/null || true; fi'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hindsight-local-only.service >/dev/null
iptables -C INPUT ! -i lo -p tcp -m multiport --dports 8888,9999 -m comment --comment "$RULE_TAG" -j DROP >/dev/null 2>&1 || die "IPv4 Hindsight 隔离规则未生效。"
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -C INPUT ! -i lo -p tcp -m multiport --dports 8888,9999 -m comment --comment "$RULE_TAG" -j DROP >/dev/null 2>&1 || die "IPv6 Hindsight 隔离规则未生效。"
fi
log "Hindsight 8888/9999 已限制为仅 loopback 可达；规则由 systemd 在重启后自动恢复。"
