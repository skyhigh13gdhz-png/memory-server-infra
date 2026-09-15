#!/usr/bin/env bash
set -Eeuo pipefail

PASS=0
WARN=0
FAIL=0

ok()   { printf '[ OK ] %s\n' "$*"; PASS=$((PASS+1)); }
warn() { printf '[WARN] %s\n' "$*"; WARN=$((WARN+1)); }
fail() { printf '[FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }

check_service() {
  local svc="$1"
  if systemctl is-active --quiet "$svc" 2>/dev/null; then ok "$svc 服务运行中"; else fail "$svc 服务未运行"; fi
}

check_http_local() {
  local name="$1" url="$2"
  if curl -fsS --max-time 8 "$url" >/dev/null 2>&1; then ok "$name 可访问：$url"; else warn "$name 暂不可访问：$url"; fi
}

main() {
  echo '========== memory-server-infra 健康检查 =========='

  local mem_mb swap_mb free_mb
  mem_mb=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
  swap_mb=$(awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
  free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
  printf 'RAM: %s MB | Swap: %s MB | 根分区可用: %s MB\n' "$mem_mb" "$swap_mb" "$free_mb"

  (( free_mb >= 4096 )) && ok '根分区剩余空间 >= 4GB' || warn '根分区剩余空间低于 4GB'

  check_service xray
  if ss -lnt 2>/dev/null | grep -qE '127\.0\.0\.1:10809\b'; then ok 'Xray HTTP 代理仅在 127.0.0.1:10809 监听'; else fail '未检测到 127.0.0.1:10809 的 Xray HTTP 代理'; fi

  if command -v docker >/dev/null 2>&1; then
    ok "Docker 已安装：$(docker --version 2>/dev/null || true)"
    check_service docker
    docker compose version >/dev/null 2>&1 && ok 'Docker Compose plugin 可用' || fail 'Docker Compose plugin 不可用'
  else
    fail 'Docker 未安装'
  fi

  if [[ -f /etc/systemd/system/docker.service.d/xray-proxy.conf ]]; then
    ok 'Docker daemon Xray 代理配置存在'
  else
    warn '未发现 Docker daemon Xray 代理配置'
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq hindsight; then
    ok 'Hindsight 容器运行中'
  else
    warn 'Hindsight 容器未运行或尚未部署'
  fi

  # Hindsight 官方默认 API/UI 端口。这里只从本机测试，不把可访问性等同于公网安全。
  check_http_local 'Hindsight API' 'http://127.0.0.1:8888/'
  check_http_local 'Hindsight Web UI' 'http://127.0.0.1:9999/'

  # host network 下必须检查真实监听地址；如果 8888/9999 对所有 IPv4 地址监听，明确报风险。
  local listeners
  listeners=$(ss -lntp 2>/dev/null | grep -E ':(8888|9999)\b' || true)
  if [[ -z "$listeners" ]]; then
    warn '没有检测到 8888/9999 TCP 监听'
  else
    printf '\nHindsight 端口监听：\n%s\n' "$listeners"
    if grep -Eq '(^|[[:space:]])0\.0\.0\.0:(8888|9999)|(^|[[:space:]])\*:(8888|9999)' <<<"$listeners"; then
      fail 'Hindsight 8888/9999 存在全 IPv4 地址监听；在确认云防火墙/主机防火墙前不要视为安全部署'
    elif grep -Eq '\[::\]:(8888|9999)' <<<"$listeners"; then
      fail 'Hindsight 8888/9999 存在全 IPv6 地址监听；需要进一步限制访问'
    else
      ok '未发现 Hindsight 8888/9999 的明显全地址监听'
    fi
  fi

  printf '\n========== 结果：OK=%d WARN=%d FAIL=%d ==========\n' "$PASS" "$WARN" "$FAIL"
  if (( FAIL > 0 )); then
    echo '存在失败项，请先修复后再进入 Memory Gateway 阶段。'
    exit 1
  fi
  echo '基础健康检查通过。WARN 项仍建议人工确认。'
}

main "$@"
