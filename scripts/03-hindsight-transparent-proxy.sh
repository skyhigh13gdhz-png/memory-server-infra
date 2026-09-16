#!/usr/bin/env bash
set -Eeuo pipefail

# 只接管 Hindsight 容器 cgroup 发起的 TCP 出站。
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
TPROXY_PORT="${HINDSIGHT_TRANSPARENT_PORT:-12345}"
CHAIN="HINDSIGHT_XRAY"
SERVICE="hindsight-transparent-proxy.service"
BACKUP_DIR="/var/lib/memory-server-infra/xray-backups"
RULE_HELPER="/usr/local/sbin/hindsight-transparent-proxy-rules"

ok(){ printf '\n[✓] %s\n' "$*"; }
info(){ printf '\n[→] %s\n' "$*"; }
die(){ printf '\n[✗] %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行。"
for cmd in xray iptables python3 systemctl docker; do command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"; done
[[ -f "$XRAY_CONFIG" ]] || die "未找到 Xray 配置：$XRAY_CONFIG"
[[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)" == "cgroup2fs" ]] || die "当前服务器不是 cgroup v2。"
iptables -m cgroup -h >/dev/null 2>&1 || die "当前 iptables 不支持 cgroup 匹配。"

resolve_hindsight_cgroup(){ local pid path i; for i in $(seq 1 60); do pid="$(docker inspect -f '{{.State.Pid}}' hindsight 2>/dev/null || true)"; if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [[ -r "/proc/$pid/cgroup" ]]; then path="$(awk -F: '$1=="0" {print $3; exit}' "/proc/$pid/cgroup")"; path="${path#/}"; [[ -n "$path" ]] && { printf '%s\n' "$path"; return 0; }; fi; sleep 2; done; die "120 秒内没有找到正在运行的 Hindsight 容器 cgroup。"; }

install_xray_inbound(){ mkdir -p "$BACKUP_DIR"; local backup="$BACKUP_DIR/config.$(date +%Y%m%d-%H%M%S).json"; cp -a "$XRAY_CONFIG" "$backup"; python3 - "$XRAY_CONFIG" "$TPROXY_PORT" <<'PY'
import json,sys
p,port=sys.argv[1],int(sys.argv[2]); cfg=json.load(open(p)); ins=cfg.setdefault('inbounds',[]); tag='hindsight-transparent'
new={'tag':tag,'listen':'127.0.0.1','port':port,'protocol':'dokodemo-door','settings':{'network':'tcp','followRedirect':True},'sniffing':{'enabled':True,'destOverride':['http','tls']}}
for i,x in enumerate(ins):
    if x.get('tag')==tag: ins[i]=new; break
else: ins.append(new)
with open(p,'w') as f: json.dump(cfg,f,ensure_ascii=False,indent=2); f.write('\n')
PY
if ! xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then cp -a "$backup" "$XRAY_CONFIG"; die "新增透明入口后 Xray 配置校验失败，已恢复原配置。"; fi; systemctl enable xray >/dev/null 2>&1 || true; systemctl restart xray; systemctl is-active --quiet xray || die "Xray 重启失败。"; ok "Xray 本机透明入口已准备：127.0.0.1:${TPROXY_PORT}"; }

# 不再尝试把 `iptables -S` 的引号文本反向拼成删除命令。
# 直接按 OUTPUT 中指向专用 chain 的规则编号，从后往前删除，兼容 --path 输出中的引号。
cleanup_output_jumps(){ local nums n; nums="$(iptables -t nat -L OUTPUT --line-numbers -n 2>/dev/null | awk -v c="$CHAIN" '$2==c {print $1}' | sort -rn)"; while read -r n; do [[ -n "$n" ]] || continue; iptables -t nat -D OUTPUT "$n"; done <<<"$nums"; }
build_chain(){ iptables -t nat -N "$CHAIN" 2>/dev/null || true; iptables -t nat -F "$CHAIN"; for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do iptables -t nat -A "$CHAIN" -d "$cidr" -j RETURN; done; iptables -t nat -A "$CHAIN" -p tcp -j REDIRECT --to-ports "$TPROXY_PORT"; }
apply_rules(){ local cgroup="$1"; cleanup_output_jumps; build_chain; iptables -t nat -A OUTPUT -p tcp -m cgroup --path "$cgroup" -j "$CHAIN"; info "Hindsight cgroup：$cgroup"; }

write_helper(){ cat >"$RULE_HELPER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
CHAIN="HINDSIGHT_XRAY"; PORT="${HINDSIGHT_TRANSPARENT_PORT:-12345}"
cleanup(){ local nums n; nums="$(iptables -t nat -L OUTPUT --line-numbers -n 2>/dev/null | awk -v c="$CHAIN" '$2==c {print $1}' | sort -rn)"; while read -r n; do [[ -n "$n" ]] || continue; iptables -t nat -D OUTPUT "$n"; done <<<"$nums"; }
resolve(){ local pid path i; for i in $(seq 1 60); do pid="$(docker inspect -f '{{.State.Pid}}' hindsight 2>/dev/null || true)"; if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [[ -r "/proc/$pid/cgroup" ]]; then path="$(awk -F: '$1=="0" {print $3; exit}' "/proc/$pid/cgroup")"; path="${path#/}"; [[ -n "$path" ]] && { printf '%s\n' "$path"; return; }; fi; sleep 2; done; exit 1; }
CGROUP_PATH="$(resolve)"; cleanup; iptables -t nat -N "$CHAIN" 2>/dev/null || true; iptables -t nat -F "$CHAIN"
for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do iptables -t nat -A "$CHAIN" -d "$cidr" -j RETURN; done
iptables -t nat -A "$CHAIN" -p tcp -j REDIRECT --to-ports "$PORT"; iptables -t nat -A OUTPUT -p tcp -m cgroup --path "$CGROUP_PATH" -j "$CHAIN"
EOF
chmod 0755 "$RULE_HELPER"; }
write_service(){ cat >"/etc/systemd/system/$SERVICE" <<EOF
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
systemctl daemon-reload; systemctl enable "$SERVICE" >/dev/null; }
verify_install(){ local cgroup="$1" jump_count uid_count; systemctl is-enabled --quiet "$SERVICE" || die "透明代理服务没有设置为开机自动恢复。"; systemctl is-active --quiet "$SERVICE" || die "透明代理服务当前没有正常运行。"; ss -lnt 2>/dev/null | grep -qE "127\\.0\\.0\\.1:${TPROXY_PORT}\\b" || die "Xray 透明入口未监听。"; jump_count="$(iptables -t nat -S OUTPUT 2>/dev/null | grep -F -- "-j $CHAIN" | wc -l)"; uid_count="$(iptables -t nat -S OUTPUT 2>/dev/null | grep -F -- "-j $CHAIN" | grep -c -- '--uid-owner' || true)"; [[ "$jump_count" == "1" ]] || die "OUTPUT 中 Hindsight 透明代理 jump 数量异常：${jump_count}（期望 1）。"; [[ "$uid_count" == "0" ]] || die "仍发现旧版 --uid-owner 透明代理规则。"; iptables -t nat -S OUTPUT 2>/dev/null | grep -F -- "--path \"$cgroup\"" | grep -Fq -- "-j $CHAIN" || die "没有找到当前 Hindsight cgroup 对应的 OUTPUT 规则。"; ok "Hindsight 专属透明代理服务：当前运行正常，且已设置开机自动恢复"; ok "透明代理规则：当前 cgroup jump 唯一，未发现旧版 UID jump"; }
remove_rules(){ cleanup_output_jumps; iptables -t nat -F "$CHAIN" 2>/dev/null || true; iptables -t nat -X "$CHAIN" 2>/dev/null || true; systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true; rm -f "/etc/systemd/system/$SERVICE" "$RULE_HELPER"; systemctl daemon-reload; ok "Hindsight 透明代理规则已移除"; }
status(){ local cgroup="$(resolve_hindsight_cgroup)"; printf 'Hindsight cgroup: %s\n' "$cgroup"; systemctl is-active "$SERVICE" 2>/dev/null || true; iptables -t nat -S OUTPUT | grep -F "$CHAIN" || true; }
case "${1:-install}" in install) info "正在把旧版 UID 透明代理迁移为 Hindsight 容器专属 cgroup 规则……"; cgroup="$(resolve_hindsight_cgroup)"; install_xray_inbound; apply_rules "$cgroup"; write_helper; write_service; info "正在启动并验证 Hindsight 专属透明代理服务……"; systemctl restart "$SERVICE"; verify_install "$cgroup"; ok "Hindsight 专属海外网络已安装";; remove) remove_rules;; status) status;; *) die "用法：$0 [install|remove|status]";; esac
