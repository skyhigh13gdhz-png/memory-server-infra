#!/usr/bin/env bash
set -Eeuo pipefail

# memory-server-infra / 第二阶段：Docker Engine 安装
# 使用 Docker 官方 apt 仓库；先检测现状，再决定跳过、停止或安装。

log()  { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() { [[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行：sudo bash scripts/02-install-docker.sh"; }

read_os() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
  OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-unknown}}"
  ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
}

is_docker_healthy() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

report() {
  echo "========== Docker 安装前检测 =========="
  echo "系统       : ${OS_ID} ${OS_VERSION} (${OS_CODENAME})"
  echo "架构       : ${ARCH}"
  echo "Docker CLI : $(command -v docker 2>/dev/null || echo 未安装)"
  echo "Docker服务 : $(systemctl is-active docker 2>/dev/null || echo 未安装/未运行)"
  echo "Compose    : $(docker compose version 2>/dev/null || echo 未安装)"
  echo "Xray       : $(systemctl is-active xray 2>/dev/null || echo 未安装/未运行)"
  echo "========================================"
}

preflight() {
  [[ "$OS_ID" == ubuntu ]] || die "当前自动安装仅支持 Ubuntu。"
  case "$ARCH" in amd64|arm64) ;; *) die "当前项目自动部署暂只支持 amd64/arm64；检测到 ${ARCH}。" ;; esac

  # 已经存在可用 Docker 时不擅自替换来源或升级大版本。
  if is_docker_healthy; then
    if docker compose version >/dev/null 2>&1; then
      log "检测到 Docker Engine 与 Compose 均可正常使用，本阶段无需安装。"
      docker version --format 'Docker Engine: {{.Server.Version}}' 2>/dev/null || true
      docker compose version || true
      exit 0
    fi
    warn "Docker Engine 已可用，但缺少 docker compose 插件；将尝试通过官方仓库补齐 Compose。"
  elif command -v docker >/dev/null 2>&1; then
    warn "检测到 docker 命令，但 Docker daemon 不健康。为避免覆盖已有环境，先尝试启动服务。"
    systemctl enable --now docker 2>/dev/null || true
    is_docker_healthy || die "已有 Docker 安装异常。脚本不会自动卸载/覆盖，请先检查：systemctl status docker"
  fi

  # 不自动卸载已有 containerd/runc/docker.io，避免破坏已有容器环境。
  local conflicts=()
  for pkg in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' && conflicts+=("$pkg") || true
  done
  if (( ${#conflicts[@]} > 0 )) && ! command -v docker >/dev/null 2>&1; then
    die "检测到可能与 Docker CE 冲突的已有包：${conflicts[*]}。为避免自动删除已有环境，本脚本停止。"
  fi
}

install_official_docker() {
  log "配置 Docker 官方 apt 仓库。"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings

  # key 文件使用临时文件 + 原子替换，避免下载失败留下半截文件。
  local key_tmp
  key_tmp="$(mktemp)"
  trap 'rm -f "$key_tmp"' RETURN
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$key_tmp" || die "Docker 官方 GPG key 下载失败。后续会在代理阶段解决网络问题；本次未修改现有 key。"
  install -m 0644 "$key_tmp" /etc/apt/keyrings/docker.asc

  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${OS_CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update || die "Docker 官方 apt 仓库不可用。未继续安装 Docker。"

  # 先确认当前系统/架构确实有 docker-ce 候选版本，再安装。
  local candidate
  candidate="$(apt-cache policy docker-ce | awk '/Candidate:/ {print $2}')"
  [[ -n "$candidate" && "$candidate" != "(none)" ]] || die "Docker 官方仓库没有适用于 ${OS_CODENAME}/${ARCH} 的 docker-ce 候选版本。"
  log "检测到 Docker CE 候选版本：${candidate}"

  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
}

verify() {
  is_docker_healthy || die "Docker 安装后 daemon 验证失败。"
  docker compose version >/dev/null 2>&1 || die "Docker Compose 插件验证失败。"

  echo
  docker version --format 'Docker Engine: {{.Server.Version}}'
  docker compose version
  systemctl --no-pager --full status docker | sed -n '1,8p' || true

  log "Docker Engine 与 Compose 本地验证通过。"
  warn "本阶段故意不运行 hello-world：国内服务器拉 Docker Hub 镜像的网络路径将在下一阶段配置 Xray 后统一验证。"
}

main() {
  require_root
  read_os
  report
  preflight

  if ! is_docker_healthy || ! docker compose version >/dev/null 2>&1; then
    install_official_docker
  fi
  verify

  cat <<'EOF'

下一阶段：配置 Docker daemon 使用现有 Xray 出站代理，并实际测试镜像拉取。
注意：Docker daemon 的代理与容器内部访问宿主机 Xray 是两个不同问题，下一阶段分别处理。
EOF
}

main "$@"
