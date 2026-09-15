#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="${HINDSIGHT_BASE_URL:-http://127.0.0.1:8888}"
BANK_ID="${HINDSIGHT_SMOKE_BANK:-infra-smoke-test}"
MARKER="memory-infra-smoke-$(date +%Y%m%d%H%M%S)"
FACT="部署验收标记 ${MARKER}：Memory Gateway 是 Hindsight 的受控入口层。"

log(){ printf '\n[INFO] %s\n' "$*"; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "缺少 curl。"
curl -fsS --max-time 10 "${BASE_URL}/docs" >/dev/null || die "Hindsight API 不可访问：${BASE_URL}"

log "执行 Hindsight Retain：bank=${BANK_ID}"
retain_body=$(printf '{"items":[{"content":"%s"}]}' "$FACT")
curl -fsS --max-time 180 \
  -H 'Content-Type: application/json' \
  -X POST "${BASE_URL}/v1/default/banks/${BANK_ID}/memories" \
  -d "$retain_body" >/tmp/hindsight-smoke-retain.json \
  || die "Retain 调用失败。查看容器日志：sudo docker logs --tail=150 hindsight"

log "执行 Hindsight Recall：查询唯一标记 ${MARKER}"
recall_body=$(printf '{"query":"%s"}' "$MARKER")
curl -fsS --max-time 120 \
  -H 'Content-Type: application/json' \
  -X POST "${BASE_URL}/v1/default/banks/${BANK_ID}/memories/recall" \
  -d "$recall_body" >/tmp/hindsight-smoke-recall.json \
  || die "Recall 调用失败。"

grep -Fq "$MARKER" /tmp/hindsight-smoke-recall.json \
  || { cat /tmp/hindsight-smoke-recall.json; die "Recall 返回中没有找到刚写入的唯一标记。"; }

log "执行 Hindsight Reflect：验证 LLM + Codex OAuth 实际推理链路"
reflect_body=$(printf '{"query":"请只回答这条部署验收记录中的 Memory Gateway 是什么角色？并包含标记 %s。"}' "$MARKER")
curl -fsS --max-time 180 \
  -H 'Content-Type: application/json' \
  -X POST "${BASE_URL}/v1/default/banks/${BANK_ID}/reflect" \
  -d "$reflect_body" >/tmp/hindsight-smoke-reflect.json \
  || die "Reflect 调用失败。查看容器日志：sudo docker logs --tail=150 hindsight"

grep -Fq "$MARKER" /tmp/hindsight-smoke-reflect.json \
  || { cat /tmp/hindsight-smoke-reflect.json; die "Reflect 成功返回，但没有引用唯一验收标记。"; }

printf '\n========== Hindsight 功能验收通过 ==========\n'
printf 'Bank   : %s\n' "$BANK_ID"
printf 'Marker : %s\n' "$MARKER"
printf 'Retain : PASS\nRecall : PASS\nReflect: PASS\n'
printf '=============================================\n'
