#!/usr/bin/env bash
set -Eeuo pipefail

PASS=0; WARN=0; FAIL=0
VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

ok(){ printf '[✓] %s\n' "$*"; PASS=$((PASS+1)); }
warn(){ printf '[!] %s\n' "$*"; WARN=$((WARN+1)); }
fail(){ printf '[✗] %s\n' "$*"; FAIL=$((FAIL+1)); }
detail(){ (( VERBOSE == 1 )) && printf '    技术信息：%s\n' "$*" || true; }

service_active(){ systemctl is-active --quiet "$1" 2>/dev/null; }
http_ok(){ local url; for url in "$@"; do curl -fsS --max-time 8 "$url" >/dev/null 2>&1 && return 0; done; return 1; }

main(){
  local mem_mb swap_mb free_mb listeners firewall4=0 firewall6=0
  local docker_version compose_version

  printf '========== 记忆服务器健康检查 ==========\n\n'
  printf '正在检查这台服务器是否具备正常运行个人 AI 记忆服务的条件。\n'
  (( VERBOSE == 1 )) && printf '当前模式：详细模式（会显示 Docker、端口、防火墙等技术信息）\n'
  printf '\n'

  mem_mb=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
  swap_mb=$(awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
  free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
  if (( free_mb >= 4096 )); then
    ok '服务器磁盘空间：正常'
  else
    warn '服务器磁盘空间偏少，暂时可以继续，但建议尽快清理'
  fi
  detail "RAM=${mem_mb}MB，Swap=${swap_mb}MB，根分区可用=${free_mb}MB"

  if service_active xray && ss -lnt 2>/dev/null | grep -qE '127\.0\.0\.1:10809\b'; then
    ok '海外网络通道：正常'
  else
    fail '海外网络通道：异常，Hindsight 可能无法访问需要代理的 AI 服务'
  fi
  detail "Xray service=$(systemctl is-active xray 2>/dev/null || true)，期望 HTTP 代理监听 127.0.0.1:10809"

  if command -v docker >/dev/null 2>&1 && service_active docker && docker compose version >/dev/null 2>&1; then
    ok '应用运行环境 Docker：正常'
  else
    fail '应用运行环境 Docker：异常，Hindsight 无法可靠运行'
  fi
  docker_version=$(docker --version 2>/dev/null || echo '不可用')
  compose_version=$(docker compose version 2>/dev/null || echo '不可用')
  detail "$docker_version；$compose_version"

  if [[ -f /etc/systemd/system/docker.service.d/xray-proxy.conf ]]; then
    ok 'Docker 下载境外组件的网络配置：已准备'
  else
    warn '没有发现 Docker 的 Xray 出站配置；如果镜像已经存在可以继续，否则以后拉取镜像可能失败'
  fi
  detail '配置文件：/etc/systemd/system/docker.service.d/xray-proxy.conf'

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq hindsight; then
    ok 'Hindsight 记忆服务：正在运行'
  else
    fail 'Hindsight 记忆服务：没有运行'
  fi
  detail "容器状态：$(docker ps --filter name=hindsight --format '{{.Names}} {{.Status}}' 2>/dev/null || true)"

  if http_ok 'http://127.0.0.1:8888/' 'http://127.0.0.1:8888/docs'; then
    ok '记忆读写接口：可以访问'
  else
    fail '记忆读写接口：暂时无法访问，AI 当前不能正常读写 Hindsight'
  fi
  detail 'Hindsight API：http://127.0.0.1:8888'

  if http_ok 'http://127.0.0.1:9999/'; then
    ok 'Hindsight 管理界面：可以访问'
  else
    warn 'Hindsight 管理界面暂时无法访问；如果记忆读写接口正常，不影响 AI 的核心记忆功能'
  fi
  detail 'Hindsight UI：http://127.0.0.1:9999'

  iptables -C INPUT ! -i lo -p tcp -m multiport --dports 8888,9999 -m comment --comment memory-server-hindsight-local-only -j DROP >/dev/null 2>&1 && firewall4=1 || true
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C INPUT ! -i lo -p tcp -m multiport --dports 8888,9999 -m comment --comment memory-server-hindsight-local-only -j DROP >/dev/null 2>&1 && firewall6=1 || true
  else
    firewall6=1
  fi

  if (( firewall4 == 1 && firewall6 == 1 )); then
    ok 'Hindsight 公网保护：已启用，8888/9999 不允许外部直接访问'
  else
    fail 'Hindsight 公网保护：不完整，请不要把当前服务器作为正式记忆服务使用'
  fi
  detail "IPv4 DROP=${firewall4}，IPv6 DROP=${firewall6}"

  if systemctl is-enabled --quiet hindsight-local-only.service 2>/dev/null && systemctl is-active --quiet hindsight-local-only.service 2>/dev/null; then
    ok '安全规则重启自动恢复：已启用'
  else
    fail '安全规则重启自动恢复：异常，服务器重启后可能失去端口保护'
  fi
  detail "hindsight-local-only.service active=$(systemctl is-active hindsight-local-only.service 2>/dev/null || true)，enabled=$(systemctl is-enabled hindsight-local-only.service 2>/dev/null || true)"

  if systemctl is-enabled --quiet hindsight-transparent-proxy.service 2>/dev/null && systemctl is-active --quiet hindsight-transparent-proxy.service 2>/dev/null; then
    ok 'Hindsight 专属海外 AI 网络：已启用，并会在重启后自动恢复'
  else
    fail 'Hindsight 专属海外 AI 网络：异常，Codex/OpenAI 请求可能无法正常发送'
  fi
  detail "hindsight-transparent-proxy.service active=$(systemctl is-active hindsight-transparent-proxy.service 2>/dev/null || true)，enabled=$(systemctl is-enabled hindsight-transparent-proxy.service 2>/dev/null || true)"

  if (( VERBOSE == 1 )); then
    listeners=$(ss -lntp 2>/dev/null | grep -E ':(8888|9999|10809|12345)\b' || true)
    printf '\n---------- 技术细节：关键端口监听 ----------\n%s\n' "${listeners:-未检测到相关监听}"
  fi

  printf '\n========== 检查结果 ==========\n'
  printf '[✓] 正常：%d 项\n' "$PASS"
  (( WARN > 0 )) && printf '[!] 提醒：%d 项\n' "$WARN"
  (( FAIL > 0 )) && printf '[✗] 失败：%d 项\n' "$FAIL"
  printf '\n'

  if (( FAIL > 0 )); then
    printf '当前状态：记忆服务器存在需要处理的问题。\n'
    printf '这不一定意味着数据丢失，但不建议继续接入 AI 客户端。\n\n'
    if (( VERBOSE == 0 )); then
      printf '下一步：运行详细检查，把技术信息用于排障：\n'
      printf '  sudo bash scripts/health-check.sh --verbose\n'
    else
      printf '下一步：根据上面的 [✗] 项和技术信息进行修复，然后重新运行本检查。\n'
    fi
    exit 1
  fi

  if (( WARN > 0 )); then
    printf '当前状态：核心记忆服务正常，可以继续；有 %d 项提醒建议后续处理。\n' "$WARN"
  else
    printf '当前状态：一切正常，可以继续使用记忆服务。\n'
  fi
  if (( VERBOSE == 0 )); then
    printf '\n如需查看 Docker、端口、防火墙等技术细节：\n'
    printf '  sudo bash scripts/health-check.sh --verbose\n'
  fi
}

main "$@"
