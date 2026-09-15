#!/usr/bin/env bash
set -Eeuo pipefail
PASS=0; WARN=0; FAIL=0
ok(){ printf '[ OK ] %s\n' "$*"; PASS=$((PASS+1)); }; warn(){ printf '[WARN] %s\n' "$*"; WARN=$((WARN+1)); }; fail(){ printf '[FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
check_service(){ local svc="$1"; systemctl is-active --quiet "$svc" 2>/dev/null && ok "$svc 服务运行中" || fail "$svc 服务未运行"; }
check_http_any(){ local name="$1"; shift; local url; for url in "$@"; do if curl -fsS --max-time 8 "$url" >/dev/null 2>&1; then ok "$name 可访问：$url"; return; fi; done; warn "$name 暂不可访问：$*"; }
main(){
  echo '========== memory-server-infra 健康检查 =========='
  local mem_mb swap_mb free_mb listeners firewall4=0 firewall6=0
  mem_mb=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo); swap_mb=$(awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo); free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
  printf 'RAM: %s MB | Swap: %s MB | 根分区可用: %s MB\n' "$mem_mb" "$swap_mb" "$free_mb"
  (( free_mb >= 4096 )) && ok '根分区剩余空间 >= 4GB' || warn '根分区剩余空间低于 4GB'
  check_service xray
  ss -lnt 2>/dev/null | grep -qE '127\.0\.0\.1:10809\b' && ok 'Xray HTTP 代理仅在 127.0.0.1:10809 监听' || fail '未检测到 127.0.0.1:10809 的 Xray HTTP 代理'
  if command -v docker >/dev/null 2>&1; then ok "Docker 已安装：$(docker --version 2>/dev/null || true)"; check_service docker; docker compose version >/dev/null 2>&1 && ok 'Docker Compose plugin 可用' || fail 'Docker Compose plugin 不可用'; else fail 'Docker 未安装'; fi
  [[ -f /etc/systemd/system/docker.service.d/xray-proxy.conf ]] && ok 'Docker daemon Xray 代理配置存在' || warn '未发现 Docker daemon Xray 代理配置'
  docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq hindsight && ok 'Hindsight 容器运行中' || warn 'Hindsight 容器未运行或尚未部署'
  check_http_any 'Hindsight API' 'http://127.0.0.1:8888/' 'http://127.0.0.1:8888/docs'
  check_http_any 'Hindsight Web UI' 'http://127.0.0.1:9999/'

  # host-network 是有意保留的：Hindsight 需要访问宿主机 loopback Xray。
  # 因此不能仅凭 ss 的 0.0.0.0 判失败，必须同时确认 INPUT 链的持久化 DROP 规则。
  iptables -C INPUT ! -i lo -p tcp -m multiport --dports 8888,9999 -m comment --comment memory-server-hindsight-local-only -j DROP >/dev/null 2>&1 && firewall4=1 || true
  if command -v ip6tables >/dev/null 2>&1; then ip6tables -C INPUT ! -i lo -p tcp -m multiport --dports 8888,9999 -m comment --comment memory-server-hindsight-local-only -j DROP >/dev/null 2>&1 && firewall6=1 || true; else firewall6=1; fi
  systemctl is-enabled --quiet hindsight-local-only.service 2>/dev/null && systemctl is-active --quiet hindsight-local-only.service 2>/dev/null && ok 'Hindsight 本机隔离规则已设置为开机自动恢复' || fail 'Hindsight 本机隔离 systemd 服务未启用或未运行'

  listeners=$(ss -lntp 2>/dev/null | grep -E ':(8888|9999)\b' || true)
  [[ -n "$listeners" ]] && printf '\nHindsight 端口监听：\n%s\n' "$listeners" || warn '没有检测到 8888/9999 TCP 监听'
  if (( firewall4 == 1 && firewall6 == 1 )); then ok '8888/9999 的非 loopback IPv4/IPv6 入站已由主机防火墙拒绝'; else (( firewall4 == 1 )) || fail '缺少 8888/9999 非 loopback IPv4 DROP 规则'; (( firewall6 == 1 )) || fail '缺少 8888/9999 非 loopback IPv6 DROP 规则'; fi

  printf '\n========== 结果：OK=%d WARN=%d FAIL=%d ==========\n' "$PASS" "$WARN" "$FAIL"
  (( FAIL == 0 )) || { echo '存在失败项，请先修复后再进入 Memory Gateway 阶段。'; exit 1; }
  echo '基础健康检查通过。WARN 项仍建议人工确认。'
}
main "$@"
