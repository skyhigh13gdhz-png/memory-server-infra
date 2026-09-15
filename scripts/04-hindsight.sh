#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${APP_DIR:-/opt/memory-server-infra/hindsight}"
SOURCE_DIR="${ROOT_DIR}/docker/hindsight"
ENV_FILE="${APP_DIR}/.env"
CODEX_AUTH_DIR_DEFAULT="/var/lib/hindsight/codex"

log(){ printf '\n[INFO] %s\n' "$*"; }
warn(){ printf '\n[WARN] %s\n' "$*" >&2; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行。"
command -v docker >/dev/null 2>&1 || die "未检测到 Docker。"
docker compose version >/dev/null 2>&1 || die "未检测到 Docker Compose plugin。"
systemctl is-active --quiet docker || die "Docker 服务未运行。"
systemctl is-active --quiet xray || die "Xray 服务未运行。"
[[ -f "${SOURCE_DIR}/compose.yml" && -f "${SOURCE_DIR}/.env.example" ]] || die "仓库中的 Hindsight 模板不完整。"

MEM_MB="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
SWAP_MB="$(awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
FREE_MB="$(df -Pm /var/lib/docker 2>/dev/null | awk 'NR==2 {print $4}')"
[[ -n "$FREE_MB" ]] || FREE_MB="$(df -Pm / | awk 'NR==2 {print $4}')"

log "部署前资源：RAM ${MEM_MB} MB / Swap ${SWAP_MB} MB / Docker 所在分区可用约 ${FREE_MB} MB。"
(( MEM_MB >= 4096 )) || warn "RAM 低于 Hindsight 官方建议的 4GB；将依赖低并发 + Swap 做实验性部署。"
(( MEM_MB >= 4096 || SWAP_MB >= 2048 )) || die "低内存机器当前 Swap 也不足 2GB，请先运行 01-system-init.sh。"

mkdir -p "$APP_DIR"
install -m 0644 "${SOURCE_DIR}/compose.yml" "${APP_DIR}/compose.yml"

if [[ ! -f "$ENV_FILE" ]]; then
  install -m 0600 "${SOURCE_DIR}/.env.example" "$ENV_FILE"
  log "已生成服务器本地配置：${ENV_FILE}"
fi
chmod 600 "$ENV_FILE"

get_env(){ local key="$1"; awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$ENV_FILE"; }
PROVIDER="$(get_env HINDSIGHT_API_LLM_PROVIDER)"; PROVIDER="${PROVIDER:-openai-codex}"
API_KEY="$(get_env HINDSIGHT_API_LLM_API_KEY)"

install_codex_cli() {
  if command -v codex >/dev/null 2>&1; then
    log "Codex CLI 已安装：$(codex --version 2>/dev/null || printf 'version unknown')"
    return 0
  fi

  log "未检测到 Codex CLI，开始自动安装 OpenAI Codex CLI。"
  if ! command -v npm >/dev/null 2>&1; then
    die "openai-codex 模式需要 npm 来安装 Codex CLI，但当前未检测到 npm。请先安装 Node.js/npm 后重试。"
  fi

  # npm 安装可能需要访问海外 registry。优先直连；失败后仅对本次命令临时使用宿主机 Xray。
  if npm install -g @openai/codex; then
    :
  else
    warn "Codex CLI 直连安装失败，尝试仅对本次 npm 命令使用 Xray HTTP 代理。"
    HTTP_PROXY=http://127.0.0.1:10809 \
    HTTPS_PROXY=http://127.0.0.1:10809 \
    npm_config_proxy=http://127.0.0.1:10809 \
    npm_config_https_proxy=http://127.0.0.1:10809 \
      npm install -g @openai/codex || die "Codex CLI 自动安装失败。"
  fi

  command -v codex >/dev/null 2>&1 || die "npm 已执行安装，但 codex 命令仍不可用。"
  log "Codex CLI 安装完成：$(codex --version 2>/dev/null || printf 'version unknown')"
}

if [[ "$PROVIDER" == "openai-codex" ]]; then
  install_codex_cli
  CODEX_AUTH_DIR="$(get_env CODEX_HOME)"; CODEX_AUTH_DIR="${CODEX_AUTH_DIR:-$CODEX_AUTH_DIR_DEFAULT}"
  mkdir -p "$CODEX_AUTH_DIR"
  chmod 700 "$CODEX_AUTH_DIR"
  if [[ ! -s "$CODEX_AUTH_DIR/auth.json" ]]; then
    cat <<EOF

[需要一次性授权] 当前 LLM Provider：openai-codex（ChatGPT Plus/Pro OAuth，无需 API Key）
Codex CLI 已准备好。
Hindsight 将使用独立凭据目录：${CODEX_AUTH_DIR}

请执行一次人工 OAuth 登录：
  sudo env CODEX_HOME=${CODEX_AUTH_DIR} codex login --device-auth

按照终端提示，在你自己的浏览器完成 ChatGPT 授权。
授权完成后确认存在：${CODEX_AUTH_DIR}/auth.json
然后重新运行：sudo bash setup.sh

不要把 auth.json 提交 Git，也不要把其中内容发到聊天中。
EOF
    exit 20
  fi
  log "已检测到独立 Codex OAuth 凭据；无需 LLM API Key。"
else
  [[ -n "$API_KEY" ]] || die "当前 Provider=${PROVIDER} 需要 API Key，但 ${ENV_FILE} 中 HINDSIGHT_API_LLM_API_KEY 为空。"
fi

IMAGE_TAG="$(get_env HINDSIGHT_IMAGE_TAG)"; IMAGE_TAG="${IMAGE_TAG:-latest}"
if [[ "$IMAGE_TAG" == "latest" && "$FREE_MB" -lt 12288 ]]; then
  die "Full Hindsight 镜像较大；当前 Docker 分区可用空间约 ${FREE_MB} MB，不足安全阈值 12GB。请先扩容或评估 slim 方案。"
fi

cd "$APP_DIR"
log "拉取 Hindsight 镜像。"; docker compose pull
log "启动 Hindsight。"; docker compose up -d

log "等待 API 启动（最多约 120 秒）。"
ok=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 http://127.0.0.1:8888/ >/dev/null 2>&1 || curl -fsS --max-time 2 http://127.0.0.1:8888/docs >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if (( ok == 0 )); then docker compose ps; docker compose logs --tail=100 hindsight || true; die "Hindsight 容器已启动，但 API 健康检查未在等待时间内通过。"; fi

log "Hindsight API 已可从宿主机 127.0.0.1:8888 访问。"; docker compose ps
echo
printf '%s\n' "注意：当前采用 host network 是为了让 Hindsight 安全访问宿主机仅监听 127.0.0.1 的 Xray。" \
              "这也意味着 Hindsight 8888/9999 的监听范围需要在下一阶段做安全检查，确认不会意外暴露公网。"
