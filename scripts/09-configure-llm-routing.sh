#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${APP_DIR:-/opt/memory-server-infra/hindsight}"
ENV_FILE="${APP_DIR}/.env"
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_SCRIPT="${SOURCE_ROOT}/scripts/07-hindsight-smoke-test.sh"
PROXY_SCRIPT="${SOURCE_ROOT}/scripts/03-hindsight-transparent-proxy.sh"
DEFAULT_ZAI_MODEL="${ZAI_RETAIN_MODEL:-glm-4.5-air}"
DEFAULT_ZAI_BASE_URL="${ZAI_RETAIN_BASE_URL:-https://open.bigmodel.cn/api/paas/v4}"

log(){ printf '\n[INFO] %s\n' "$*"; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行。"
[[ -f "$ENV_FILE" ]] || die "找不到 Hindsight 配置：$ENV_FILE"

get_env(){ awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$ENV_FILE"; }
write_env_value(){ local key="$1" value="$2" tmp; tmp="$(mktemp)"; awk -F= -v k="$key" -v v="$value" 'BEGIN{done=0} $1==k {print k "=" v; done=1; next} {print} END{if(!done) print k "=" v}' "$ENV_FILE" >"$tmp"; install -m 0600 "$tmp" "$ENV_FILE"; rm -f "$tmp"; }
delete_env_value(){ local key="$1" tmp; tmp="$(mktemp)"; awk -F= -v k="$key" '$1!=k {print}' "$ENV_FILE" >"$tmp"; install -m 0600 "$tmp" "$ENV_FILE"; rm -f "$tmp"; }

operation_prefix(){
  case "$1" in
    retain) printf RETAIN ;;
    reflect) printf REFLECT ;;
    consolidation) printf CONSOLIDATION ;;
    mental-model-refresh) printf MENTAL_MODEL_REFRESH ;;
    *) die "未知操作：$1（可用：retain / reflect / consolidation / mental-model-refresh）" ;;
  esac
}

show_operation(){
  local label="$1" prefix="$2" global_provider="$3" global_model="$4" provider model base key source
  provider="$(get_env "HINDSIGHT_API_${prefix}_LLM_PROVIDER" || true)"
  model="$(get_env "HINDSIGHT_API_${prefix}_LLM_MODEL" || true)"
  base="$(get_env "HINDSIGHT_API_${prefix}_LLM_BASE_URL" || true)"
  key="$(get_env "HINDSIGHT_API_${prefix}_LLM_API_KEY" || true)"
  if [[ -z "$provider" ]]; then provider="$global_provider"; model="$global_model"; source=inherited; else source=override; fi
  printf '%-22s provider=%-14s model=%-18s source=%-9s key=%s' "$label" "$provider" "$model" "$source" "$([[ -n "$key" ]] && printf configured || printf inherited)"
  [[ -z "$base" ]] || printf ' base_url=%s' "$base"
  printf '\n'
}

show_status(){
  local global_provider global_model embedding
  global_provider="$(get_env HINDSIGHT_API_LLM_PROVIDER)"
  global_model="$(get_env HINDSIGHT_API_LLM_MODEL)"
  embedding="$(get_env HINDSIGHT_API_EMBEDDINGS_PROVIDER || true)"
  printf 'Global default         provider=%s model=%s\n' "$global_provider" "$global_model"
  show_operation Retain RETAIN "$global_provider" "$global_model"
  show_operation Reflect REFLECT "$global_provider" "$global_model"
  show_operation Consolidation CONSOLIDATION "$global_provider" "$global_model"
  show_operation 'Mental model refresh' MENTAL_MODEL_REFRESH "$global_provider" "$global_model"
  printf '%-22s %s\n' Recall '不调用 LLM（向量/结构化检索）'
  printf '%-22s provider=%s\n' Embedding "${embedding:-local/内置配置}"
}

restart_and_verify(){
  cd "$APP_DIR"
  docker compose up -d --force-recreate
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 2 http://127.0.0.1:8888/docs >/dev/null 2>&1; then
      [[ -x "$PROXY_SCRIPT" || -f "$PROXY_SCRIPT" ]] || die "找不到透明代理脚本：$PROXY_SCRIPT"
      bash "$PROXY_SCRIPT" install
      log "透明代理已绑定当前容器；重启同一容器，让 Provider 启动验证也走正确出站。"
      docker restart hindsight >/dev/null
      for _ in $(seq 1 60); do
        if curl -fsS --max-time 2 http://127.0.0.1:8888/docs >/dev/null 2>&1; then
          log "Hindsight 已通过代理恢复；开始 Retain/Recall/Reflect 功能验收。"
          bash "$SMOKE_SCRIPT"
          return
        fi
        sleep 2
      done
      docker compose logs --tail=100 hindsight || true
      die "透明代理绑定后，Hindsight 未在 120 秒内恢复。"
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
  zai-operation|zai-retain)
    if [[ "$1" == zai-retain ]]; then operation=retain; shift; else operation="${2:-}"; shift 2; fi
    prefix="$(operation_prefix "$operation")"
    model="${1:-$DEFAULT_ZAI_MODEL}"
    api_key="${ZAI_API_KEY:-}"
    api_key_source="environment"
    if [[ -z "$api_key" ]]; then
      for existing_prefix in RETAIN REFLECT CONSOLIDATION MENTAL_MODEL_REFRESH; do
        if [[ "$(get_env "HINDSIGHT_API_${existing_prefix}_LLM_PROVIDER" || true)" == zai ]]; then
          api_key="$(get_env "HINDSIGHT_API_${existing_prefix}_LLM_API_KEY" || true)"
          if [[ -n "$api_key" ]]; then api_key_source="existing ${existing_prefix,,} route"; break; fi
        fi
      done
    fi
    if [[ -z "$api_key" ]]; then
      read -r -s -p "请输入智谱 z.ai API Key（不会回显）: " api_key
      echo
      api_key_source="interactive input"
    fi
    [[ -n "$api_key" && -n "$model" ]] || die "API Key 和模型不能为空。"
    write_env_value "HINDSIGHT_API_${prefix}_LLM_PROVIDER" zai
    write_env_value "HINDSIGHT_API_${prefix}_LLM_MODEL" "$model"
    write_env_value "HINDSIGHT_API_${prefix}_LLM_API_KEY" "$api_key"
    write_env_value "HINDSIGHT_API_${prefix}_LLM_BASE_URL" "$DEFAULT_ZAI_BASE_URL"
    write_env_value "HINDSIGHT_API_${prefix}_LLM_TIMEOUT" 60
    write_env_value "HINDSIGHT_API_${prefix}_LLM_MAX_RETRIES" 0
    unset api_key ZAI_API_KEY
    log "已配置 ${operation} → z.ai/${model} (${DEFAULT_ZAI_BASE_URL})；Key 来源=${api_key_source}（内容未输出）；其他未覆盖操作继续继承全局 Provider。"
    restart_and_verify
    show_status
    ;;
  inherit-operation|codex-retain)
    if [[ "$1" == codex-retain ]]; then operation=retain; else operation="${2:-}"; fi
    prefix="$(operation_prefix "$operation")"
    for suffix in PROVIDER MODEL API_KEY BASE_URL TIMEOUT MAX_RETRIES; do
      key="HINDSIGHT_API_${prefix}_LLM_${suffix}"
      delete_env_value "$key"
    done
    log "已取消 ${operation} override；该操作恢复继承全局 Provider。"
    restart_and_verify
    show_status
    ;;
  *)
    die "用法：$0 status | zai-operation <retain|reflect|consolidation|mental-model-refresh> [model] | inherit-operation <操作>"
    ;;
esac
