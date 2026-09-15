#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SCRIPTS_DIR="${ROOT_DIR}/scripts"; CURRENT_STEP="启动"
log(){ printf '\n========== %s ==========\n' "$*"; }; die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "\n[ERROR] 部署失败\n阶段：%s\n总入口行号：%s\n命令：%s\n退出码：%s\n\n修复后可直接重新执行 sudo bash setup.sh；已完成步骤应保持幂等。\n" "$CURRENT_STEP" "$LINENO" "$BASH_COMMAND" "$rc" >&2; exit "$rc"' ERR
[[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行：sudo bash setup.sh"
run_step(){ local file="$1" title="$2"; CURRENT_STEP="$title"; [[ -f "$file" ]] || die "缺少脚本：$file"; log "$title"; bash "$file"; }
main(){
cat <<'EOF'
memory-server-infra 一键部署

本脚本会根据当前服务器环境自适应执行：
1. 只读环境检查
2. 根据 RAM / 已有 Swap / 磁盘空间决定是否配置 Swap
3. 安装或验证 Docker Engine + Compose
4. 验证现有 Xray，并配置 Docker daemon 出站代理
5. 准备并启动 Hindsight
6. 执行整体健康检查

不会把 API Key、VLESS、真实记忆数据写入 Git。
EOF
run_step "${SCRIPTS_DIR}/00-preflight.sh" "1/6 环境预检"
run_step "${SCRIPTS_DIR}/01-system-init.sh" "2/6 内存与 Swap 初始化"
run_step "${SCRIPTS_DIR}/02-install-docker.sh" "3/6 Docker 安装/验证"
run_step "${SCRIPTS_DIR}/03-docker-proxy.sh" "4/6 Docker → Xray 出站"
run_step "${SCRIPTS_DIR}/04-hindsight.sh" "5/6 Hindsight 部署"
run_step "${SCRIPTS_DIR}/health-check.sh" "6/6 整体健康检查"
CURRENT_STEP="完成"; log "部署流程完成"; echo "如果健康检查全部通过，服务器基础记忆层已经具备继续接入 Memory Gateway 的条件。"
}
main "$@"
