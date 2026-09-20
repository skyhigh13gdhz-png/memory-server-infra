#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${APP_DIR:-/opt/memory-server-infra/hindsight}"
ENV_FILE="${APP_DIR}/.env"
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_SCRIPT="${SOURCE_ROOT}/scripts/07-hindsight-smoke-test.sh"
DEFAULT_ZAI_MODEL="${ZAI_RETAIN_MODEL:-glm-4.5-air}"
DEFAULT_ZAI_BASE_URL="${ZAI_RETAIN_BASE_URL:-https://open.bigmodel.cn/api/paas/v4}"

log(){ printf '\n[INFO] %s\n' "$*"; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行。"
[[ -f "$ENV_FILE" ]] || die "找不到 Hindsight 配置：$ENV_FILE"

get_env(){ awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$ENV_FILE"; }
write_env_value(){ local key="$1" value="$2" tmp; tmp="$(mktemp)"; awk -F= -v k="$key" -v v="$value" 'BEGIN{done=0} $1==k {print k "=" v; done=1; next} {print} END{if(!done) print k "=" v}' "$ENV_FILE" >"$tmp"; install -m 0600 "$tmp" "$ENV_FILE"; rm -f "$tmp"; }
delete_env_value(){ local key="$1" tmp; tmp="$(mktemp)"; awk -F= -v k="$key" '$1!=k {print}' "$ENV_FILE" >"$tmp"; install -m 0600 "$tmp" "$ENV_FILE"; rm -f "$tmp"; }

show_status(){
  local retain_key
  retain_key="$(get_env HINDSIGHT_API_RETAIN_LLM_API_KEY || true)"
  printf 'Global/Reflect: provider=%s model=%s\n' "$(get_env HINDSIGHT_API_LLM_PROVIDER)" "$(get_env HINDSIGHT_API_LLM_MODEL)"
  printf 'Retain override: provider=%s model=%s base_url=%s key=%s\n' \
    "$(get_env HINDSIGHT_API_RETAIN_LLM_PROVIDER || true)" \
    "$(get_env HINDSIGHT_API_RETAIN_LLM_MODEL || true)" \
    "$(get_env HINDSIGHT_API_RETAIN_LLM_BASE_URL || true)" \
    "$([[ -n "$retain_key" ]] && printf configured || printf inherited)"
  printf 'Embedding: provider=%s\n' "$(get_env HINDSIGHT_API_EMBEDDINGS_PROVIDER || true)"
}

restart_and_verify(){
  cd "$APP_DIR"
  docker compose up -d --force-recreate
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 2 http://127.0.0.1:8888/docs >/dev/null 2>&1; then
      log "Hindsight 已恢复；开始 Retain/Recall/Reflect 功能验收。"
      bash "$SMOKE_SCRIPT"
      return
    fi
    sleep 2
  done
  docker compose logs --tail=100 hindsight || true
  die "Hindsight 未在 120 秒内恢复。"
}

case "${1:-status}" in
  status)
    show_status
    ;;
  zai-retain)
    model="${2:-$DEFAULT_ZAI_MODEL}"
    api_key="${ZAI_API_KEY:-}"
    if [[ -z "$api_key" ]]; then
      read -r -s -p "请输入智谱 z.ai API Key（不会回显）: " api_key
      echo
    fi
    [[ -n "$api_key" && -n "$model" ]] || die "API Key 和模型不能为空。"
    write_env_value HINDSIGHT_API_RETAIN_LLM_PROVIDER zai
    write_env_value HINDSIGHT_API_RETAIN_LLM_MODEL "$model"
    write_env_value HINDSIGHT_API_RETAIN_LLM_API_KEY "$api_key"
    write_env_value HINDSIGHT_API_RETAIN_LLM_BASE_URL "$DEFAULT_ZAI_BASE_URL"
    write_env_value HINDSIGHT_API_RETAIN_LLM_TIMEOUT 60
    write_env_value HINDSIGHT_API_RETAIN_LLM_MAX_RETRIES 0
    unset api_key ZAI_API_KEY
    log "已配置 Retain → z.ai/${model} (${DEFAULT_ZAI_BASE_URL})；Reflect 与其他操作继续继承全局 Codex。"
    restart_and_verify
    show_status
    ;;
  codex-retain)
    for key in HINDSIGHT_API_RETAIN_LLM_PROVIDER HINDSIGHT_API_RETAIN_LLM_MODEL HINDSIGHT_API_RETAIN_LLM_API_KEY HINDSIGHT_API_RETAIN_LLM_BASE_URL HINDSIGHT_API_RETAIN_LLM_TIMEOUT HINDSIGHT_API_RETAIN_LLM_MAX_RETRIES; do
      delete_env_value "$key"
    done
    log "已取消 Retain override；Retain 恢复继承全局 Codex。"
    restart_and_verify
    show_status
    ;;
  *)
    die "用法：$0 [status | zai-retain [model] | codex-retain]"
    ;;
esac
