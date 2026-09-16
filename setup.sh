#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"
CURRENT_STEP="启动"
CURRENT_FILE=""

log(){ printf '\n========== %s ==========\n' "$*"; }
die(){ printf '\n[✗] %s\n' "$*" >&2; exit 1; }

collect_diagnostics(){
  local rc="$1"
  printf '\n========== 失败诊断信息 ==========\n' >&2
  printf '阶段：%s\n脚本：%s\n退出码：%s\n' "$CURRENT_STEP" "${CURRENT_FILE:-未知}" "$rc" >&2
  printf '\n-- 关键服务状态 --\n' >&2
  for svc in xray docker hindsight-local-only.service hindsight-transparent-proxy.service; do
    printf '%s: active=%s enabled=%s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || true)" "$(systemctl is-enabled "$svc" 2>/dev/null || true)" >&2
  done
  printf '\n-- Hindsight 容器 --\n' >&2
  docker ps -a --filter name=hindsight --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null >&2 || true
  printf '\n-- 关键端口 --\n' >&2
  ss -lntp 2>/dev/null | grep -E ':(8888|9999|10809|12345)\b' >&2 || true
  printf '\n-- Hindsight 透明代理 OUTPUT 规则 --\n' >&2
  iptables -t nat -S OUTPUT 2>/dev/null | grep -E 'HINDSIGHT_XRAY|uid-owner|cgroup' >&2 || true
  printf '\n-- Hindsight 透明代理服务日志（最近 30 行） --\n' >&2
  journalctl -u hindsight-transparent-proxy.service -n 30 --no-pager 2>/dev/null >&2 || true
  printf '========== 失败诊断结束 ==========\n' >&2
}

on_error(){
  local rc="$1" line="$2" command="$3"
  trap - ERR
  collect_diagnostics "$rc"
  printf '\n[✗] 部署失败\n阶段：%s\n总入口行号：%s\n命令：%s\n退出码：%s\n\n[→] 上面已自动抓取关键技术信息。修复后请重新运行统一入口 bootstrap.sh；它会复用已完成步骤并继续部署。\n' "$CURRENT_STEP" "$line" "$command" "$rc" >&2
  exit "$rc"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
[[ ${EUID} -eq 0 ]] || die "请使用统一入口运行：sudo bash bootstrap.sh"

run_step(){
  local file="$1" title="$2"
  shift 2
  CURRENT_STEP="$title"
  CURRENT_FILE="$file"
  [[ -f "$file" ]] || die "缺少脚本：$file"
  log "$title"
  bash "$file" "$@"
}

main(){
cat <<'EOF'
memory-server-infra 内部部署执行器

说明：普通安装、更新、修复统一使用 bootstrap.sh。
setup.sh 由 bootstrap 自动调用，一般不需要用户直接运行。

本执行器会根据当前服务器环境自适应执行：
1. 只读环境检查
2. 根据 RAM / 已有 Swap / 磁盘空间决定是否配置 Swap
3. 安装或验证 Docker Engine + Compose
4. 验证现有 Xray，并配置 Docker daemon 出站代理
5. 限制 Hindsight 8888/9999 仅本机可访问
6. 准备并启动 Hindsight
7. 为 Hindsight 配置专属透明代理
8. 执行详细整体健康检查

如果某个阶段失败，会在退出前自动抓取关键服务、端口、容器、透明代理规则和相关日志，减少二次手工排障。
不会把 API Key、OAuth 凭据、VLESS、真实记忆数据写入 Git。
EOF
run_step "${SCRIPTS_DIR}/00-preflight.sh" "1/8 环境预检"
run_step "${SCRIPTS_DIR}/01-system-init.sh" "2/8 内存与 Swap 初始化"
run_step "${SCRIPTS_DIR}/02-install-docker.sh" "3/8 Docker 安装/验证"
run_step "${SCRIPTS_DIR}/03-docker-proxy.sh" "4/8 Docker → Xray 出站"
run_step "${SCRIPTS_DIR}/04-hindsight-firewall.sh" "5/8 Hindsight 本机隔离"
run_step "${SCRIPTS_DIR}/04-hindsight.sh" "6/8 Hindsight 部署"
run_step "${SCRIPTS_DIR}/03-hindsight-transparent-proxy.sh" "7/8 Hindsight 专属透明代理" install
run_step "${SCRIPTS_DIR}/health-check.sh" "8/8 整体健康检查" --verbose
CURRENT_STEP="完成"
CURRENT_FILE=""
log "部署流程完成"
printf '[✓] 服务器基础记忆层部署完成。\n[→] 建议继续运行：sudo bash scripts/07-hindsight-smoke-test.sh\n'
}
main "$@"
