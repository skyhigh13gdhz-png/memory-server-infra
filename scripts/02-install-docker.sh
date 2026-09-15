#!/usr/bin/env bash
set -Eeuo pipefail
trap 'rc=$?; printf "\n[ERROR] 02-install-docker.sh 第 %s 行失败，退出码 %s：%s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2; exit "$rc"' ERR

log(){ printf '\n[INFO] %s\n' "$*"; }; warn(){ printf '\n[WARN] %s\n' "$*" >&2; }; die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
require_root(){ [[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行：sudo bash scripts/02-install-docker.sh"; }
read_os(){ [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"; . /etc/os-release; OS_ID="${ID:-unknown}"; OS_VERSION="${VERSION_ID:-unknown}"; OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-unknown}}"; ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"; }
is_docker_healthy(){ command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
report(){ echo "========== Docker 安装前检测 =========="; echo "系统       : ${OS_ID} ${OS_VERSION} (${OS_CODENAME})"; echo "架构       : ${ARCH}"; echo "Docker CLI : $(command -v docker 2>/dev/null || echo 未安装)"; echo "Docker服务 : $(systemctl is-active docker 2>/dev/null || true)"; echo "Compose    : $(docker compose version 2>/dev/null || echo 未安装)"; echo "Xray       : $(systemctl is-active xray 2>/dev/null || true)"; echo "========================================"; }
preflight(){
  [[ "$OS_ID" == ubuntu ]] || die "当前自动安装仅支持 Ubuntu。"; case "$ARCH" in amd64|arm64) ;; *) die "暂只支持 amd64/arm64；检测到 ${ARCH}。";; esac
  if is_docker_healthy; then if docker compose version >/dev/null 2>&1; then log "Docker Engine 与 Compose 均可用，本阶段跳过。"; docker version --format 'Docker Engine: {{.Server.Version}}' 2>/dev/null || true; docker compose version || true; exit 0; else warn "Docker Engine 可用但缺少 Compose，将尝试补齐。"; fi
  elif command -v docker >/dev/null 2>&1; then warn "检测到 docker 命令但 daemon 不健康，先尝试启动。"; systemctl enable --now docker 2>/dev/null || true; is_docker_healthy || die "已有 Docker 安装异常，请检查 systemctl status docker。"; fi
  local conflicts=(); for pkg in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' && conflicts+=("$pkg") || true; done
  if (( ${#conflicts[@]} > 0 )) && ! command -v docker >/dev/null 2>&1; then die "检测到可能冲突的已有包：${conflicts[*]}。脚本不会自动删除。"; fi
}
install_official_docker(){
  log "配置 Docker 官方 apt 仓库。"; apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl; install -m0755 -d /etc/apt/keyrings
  local key_tmp; key_tmp="$(mktemp)"; trap 'rm -f "$key_tmp"' RETURN
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$key_tmp" || die "Docker 官方 GPG key 下载失败。"; install -m0644 "$key_tmp" /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${OS_CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update || die "Docker 官方 apt 仓库不可用。"

  # 不再使用 `apt-cache ... | awk ... exit`：在 set -o pipefail 下，awk 提前退出会让
  # apt-cache 收到 SIGPIPE(141)，从而把“成功读到候选版本”反而判成脚本失败。
  # 先完整收集 apt-cache 输出，再解析；同时固定 C locale，避免中文字段名影响解析。
  local policy_output candidate="" madison_output=""
  policy_output="$(LC_ALL=C apt-cache policy docker-ce 2>/dev/null || true)"
  candidate="$(awk '/Candidate:/ {print $2}' <<<"$policy_output" | sed -n '1p')"
  if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
    madison_output="$(LC_ALL=C apt-cache madison docker-ce 2>/dev/null || true)"
    candidate="$(awk 'NR==1 {gsub(/^ +| +$/, "", $3); print $3}' <<<"$madison_output")"
  fi
  if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
    echo "---- Docker apt 诊断 ----" >&2
    printf '%s\n' "$policy_output" >&2
    [[ -n "$madison_output" ]] || madison_output="$(LC_ALL=C apt-cache madison docker-ce 2>/dev/null || true)"
    printf '%s\n' "$madison_output" | sed -n '1,5p' >&2
    die "Docker 官方仓库已加入，但 apt 仍无法解析 ${OS_CODENAME}/${ARCH} 的 docker-ce 候选版本。"
  fi
  log "检测到 Docker CE 候选版本：${candidate}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}
verify(){ is_docker_healthy || die "Docker 安装后 daemon 验证失败。"; docker compose version >/dev/null 2>&1 || die "Docker Compose 插件验证失败。"; echo; docker version --format 'Docker Engine: {{.Server.Version}}'; docker compose version; systemctl --no-pager --full status docker | sed -n '1,8p' || true; log "Docker Engine 与 Compose 本地验证通过。"; warn "本阶段不运行 hello-world；下一阶段配置 Xray 后验证镜像拉取。"; }
main(){ require_root; read_os; report; preflight; if ! is_docker_healthy || ! docker compose version >/dev/null 2>&1; then install_official_docker; fi; verify; echo; echo "下一阶段：配置 Docker daemon 使用现有 Xray 出站代理，并实际测试镜像拉取。"; }
main "$@"
