#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"
CURRENT_STEP="启动"

log(){ printf '\n========== %s ==========\n' "$*"; }
die(){ printf '\n[✗] %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "\n[✗] 部署失败\n阶段：%s\n总入口行号：%s\n命令：%s\n退出码：%s\n\n[→] 修复后可直接重新执行 sudo bash setup.sh；已完成步骤应保持幂等。\n" "$CURRENT_STEP" "$LINENO" "$BASH_COMMAND" "$rc" >&2; exit "$rc"' ERR
[[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行：sudo bash setup.sh"

run_step(){
  local file="$1" title="$2"
  shift 2
  CURRENT_STEP="$title"
  [[ -f "$file" ]] || die "缺少脚本：$file"
  log "$title"
  bash "$file" "$@"
}

main(){
cat <<'EOF'
memory-server-infra 一键部署

本脚本会根据当前服务器环境自适应执行：
1. 只读环境检查
2. 根据 RAM / 已有 Swap / 磁盘空间决定是否配置 Swap
3. 安装或验证 Docker Engine + Compose
4. 验证现有 Xray，并配置 Docker daemon 出站代理
5. 限制 Hindsight 8888/9999 仅本机可访问
6. 准备并启动 Hindsight
7. 为 Hindsight 配置专属透明代理
8. 执行整体健康检查

不会把 API Key、OAuth 凭据、VLESS、真实记忆数据写入 Git。
EOF
run_step "${SCRIPTS_DIR}/00-preflight.sh" "1/8 环境预检"
run_step "${SCRIPTS_DIR}/01-system-init.sh" "2/8 内存与 Swap 初始化"
run_step "${SCRIPTS_DIR}/02-install-docker.sh" "3/8 Docker 安装/验证"
run_step "${SCRIPTS_DIR}/03-docker-proxy.sh" "4/8 Docker → Xray 出站"
run_step "${SCRIPTS_DIR}/04-hindsight-firewall.sh" "5/8 Hindsight 本机隔离"
run_step "${SCRIPTS_DIR}/04-hindsight.sh" "6/8 Hindsight 部署"
run_step "${SCRIPTS_DIR}/03-hindsight-transparent-proxy.sh" "7/8 Hindsight 专属透明代理" install
run_step "${SCRIPTS_DIR}/health-check.sh" "8/8 整体健康检查"
CURRENT_STEP="完成"
log "部署流程完成"
printf '[✓] 服务器基础记忆层部署完成。\n[→] 建议继续运行：sudo bash scripts/07-hindsight-smoke-test.sh\n'
}
main "$@"
