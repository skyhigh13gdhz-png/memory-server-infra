#!/usr/bin/env bash
set -Eeuo pipefail

GITHUB_REPO="${MEMORY_INFRA_GITHUB_REPO:-https://github.com/skyhigh13gdhz-png/memory-server-infra.git}"
GITEE_REPO="${MEMORY_INFRA_GITEE_REPO:-https://gitee.com/skyhigh13/memory-server-infra.git}"
GITEE_PROXY_SCRIPT="${MEMORY_PROXY_GITEE_SCRIPT:-https://gitee.com/skyhigh13/ubuntu-vps-proxy-kit/raw/mainland_vps_use_proxy/setup-xray-vless.sh}"
INSTALL_DIR="${MEMORY_INFRA_SOURCE_DIR:-/opt/src/memory-server-infra}"
INSTALL_PARENT="$(dirname "$INSTALL_DIR")"
SELECTED_REPO=""

ok(){ printf '[✓] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*"; }
info(){ printf '[→] %s\n' "$*"; }
die(){ printf '[✗] %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die '请使用 sudo/root 运行。'

can_https(){ curl -fsSI --connect-timeout 4 --max-time 8 "$1" >/dev/null 2>&1; }
has_xray(){ systemctl is-active --quiet xray 2>/dev/null && ss -lnt 2>/dev/null | grep -qE '127\.0\.0\.1:10809\b'; }
has_tty(){ [[ -r /dev/tty && -w /dev/tty ]]; }

install_base_tools(){
  if command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then return; fi
  info '正在准备安装所需的基础工具……'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git curl ca-certificates
}

choose_source(){
  printf '\n========== 代码下载网络检查 ==========\n\n'
  local github_ok=0 gitee_ok=0
  can_https 'https://github.com' && github_ok=1 || true
  can_https 'https://gitee.com' && gitee_ok=1 || true
  (( github_ok == 1 )) && ok 'GitHub：可以访问' || warn 'GitHub：当前访问不稳定或不可用'
  (( gitee_ok == 1 )) && ok 'Gitee 国内镜像：可以访问' || warn 'Gitee 国内镜像：当前访问不稳定或不可用'

  if (( github_ok == 1 )); then
    SELECTED_REPO="$GITHUB_REPO"
    ok '代码来源：GitHub 主仓'
  elif (( gitee_ok == 1 )); then
    SELECTED_REPO="$GITEE_REPO"
    ok '代码来源：已自动切换到 Gitee 国内镜像'
  else
    die 'GitHub 和 Gitee 当前都无法访问，请先检查服务器基础网络。'
  fi
}

prepare_overseas_network(){
  printf '\n========== 海外网络能力检查 ==========\n\n'
  if has_xray; then
    ok '已检测到可用的 Xray 海外网络通道，将直接复用'
    return
  fi

  warn '当前没有检测到本项目可直接复用的 Xray 海外网络通道'
  cat <<'EOF'

这不会阻止你下载 Gitee 上的代码，但后续可能影响：
- GitHub / GitHub Container Registry (GHCR)
- OpenAI / ChatGPT / Codex
- 其他需要海外网络的 AI 服务

如果你只使用国内 AI，或者已经有自己的网络方案，可以暂时跳过。
EOF

  if ! has_tty; then
    die '当前没有可用的控制终端，无法安全读取网络配置。请在 SSH/终端中交互运行 bootstrap.sh。'
  fi

  local choice
  while true; do
    printf '\n是否现在配置本项目推荐的海外网络？\n'
    printf '  1. 配置（使用 ubuntu-vps-proxy-kit）\n'
    printf '  2. 暂时不配置，我只使用国内 AI\n'
    printf '  3. 暂时不配置，我已有其他网络方案\n'
    read -r -p '请选择 [1/2/3]：' choice </dev/tty
    case "$choice" in
      1)
        can_https 'https://gitee.com' || die '当前无法访问 Gitee，无法获取国内镜像中的网络安装器。'
        local tmp='/tmp/setup-xray-vless.sh'
        info '正在从 Gitee 国内镜像获取海外网络安装器……'
        curl -fsSL "$GITEE_PROXY_SCRIPT" -o "$tmp"
        chmod 700 "$tmp"
        bash "$tmp" </dev/tty
        rm -f "$tmp"
        has_xray || die '海外网络安装脚本已结束，但没有检测到预期的 Xray HTTP 代理，请先检查后再继续。'
        ok '海外网络通道已经准备完成'
        return
        ;;
      2) warn '已选择仅使用国内 AI；OpenAI / Codex 等海外服务可能不可用'; return ;;
      3) warn '已保留你现有的网络方案；后续脚本不会在这里替你修改它'; return ;;
      *) warn '请输入 1、2 或 3。' ;;
    esac
  done
}

prepare_source(){
  mkdir -p "$INSTALL_PARENT"
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info '检测到已有源码，正在从当前选定的镜像更新……'
    git -C "$INSTALL_DIR" remote set-url origin "$SELECTED_REPO"
    git -C "$INSTALL_DIR" fetch --prune origin
    git -C "$INSTALL_DIR" checkout main
    git -C "$INSTALL_DIR" pull --ff-only origin main
  else
    [[ ! -e "$INSTALL_DIR" || -z "$(ls -A "$INSTALL_DIR" 2>/dev/null || true)" ]] || die "安装目录已存在且不是 Git 仓库：$INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
    info '正在获取 Memory Server 安装代码……'
    git clone --depth=1 "$SELECTED_REPO" "$INSTALL_DIR"
  fi
  ok "安装代码已准备：$INSTALL_DIR"
}

main(){
  printf '========== AI 记忆服务器安装引导 ==========\n\n'
  printf '本引导会先检查代码下载和海外 AI 网络，再进入正式安装。\n'
  printf 'GitHub 是唯一开发主仓；Gitee 仅作为中国大陆部署镜像。\n'
  install_base_tools
  ok '基础安装工具：已准备'
  choose_source
  prepare_overseas_network
  prepare_source
  printf '\n'
  info '开始正式部署 Memory Server。敏感配置只保存在服务器本地，不会写入 Git。'
  exec bash "$INSTALL_DIR/setup.sh"
}

main "$@"
