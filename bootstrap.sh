#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${MEMORY_INFRA_REPO_URL:-https://github.com/skyhigh13gdhz-png/memory-server-infra.git}"
INSTALL_DIR="${MEMORY_INFRA_SOURCE_DIR:-/opt/src/memory-server-infra}"
INSTALL_PARENT="$(dirname "$INSTALL_DIR")"

ok(){ printf '[✓] %s\n' "$*"; }
info(){ printf '[→] %s\n' "$*"; }
die(){ printf '[✗] %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行。"

printf '========== Memory Server 安装引导 ==========\n'
printf '代码来源：%s\n安装目录：%s\n\n' "$REPO_URL" "$INSTALL_DIR"

if ! command -v git >/dev/null 2>&1; then
  info "未检测到 Git，正在安装。"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git ca-certificates
fi
ok "Git 已就绪"

mkdir -p "$INSTALL_PARENT"

if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "检测到已有源码，正在更新。"
  git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL"
  git -C "$INSTALL_DIR" fetch --prune origin
  git -C "$INSTALL_DIR" checkout main
  git -C "$INSTALL_DIR" pull --ff-only origin main
else
  [[ ! -e "$INSTALL_DIR" || -z "$(ls -A "$INSTALL_DIR" 2>/dev/null || true)" ]] || die "安装目录已存在且不是 Git 仓库：$INSTALL_DIR"
  rm -rf "$INSTALL_DIR"
  info "正在从 Public GitHub 仓库获取代码。"
  git clone --depth=1 "$REPO_URL" "$INSTALL_DIR"
fi

ok "源码已准备：$INSTALL_DIR"
info "开始执行正式部署。后续敏感配置只保存在服务器本地，不会写入 Git。"
exec bash "$INSTALL_DIR/setup.sh"
