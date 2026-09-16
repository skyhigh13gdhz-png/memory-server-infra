#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="${HINDSIGHT_BASE_URL:-http://127.0.0.1:8888}"
BANK_ID="${HINDSIGHT_BACKUP_TEST_BANK:-infra-backup-restore-test}"
BACKUP_DIR="${BACKUP_DIR:-/opt/memory-server/backups}"
DEPLOY_DIR="${HINDSIGHT_DEPLOY_DIR:-/opt/memory-server-infra/hindsight}"
RUN_ID="$(date +%Y%m%d%H%M%S)"
BEFORE="灾备验收 ${RUN_ID} 的恢复基准状态是 BEFORE-BACKUP。"
AFTER="灾备验收 ${RUN_ID} 的备份后状态是 AFTER-BACKUP。"

ok(){ printf '[✓] %s\n' "$*"; }
log(){ printf '\n[→] %s\n' "$*"; }
die(){ printf '\n[✗] %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行。"
command -v curl >/dev/null 2>&1 || die "缺少 curl。"
command -v python3 >/dev/null 2>&1 || die "缺少 python3。"
[[ -f "${ROOT_DIR}/scripts/05-backup.sh" ]] || die "缺少 05-backup.sh"
[[ -f "${ROOT_DIR}/scripts/06-restore.sh" ]] || die "缺少 06-restore.sh"
[[ -f "${DEPLOY_DIR}/compose.yml" ]] || die "找不到 Hindsight compose：${DEPLOY_DIR}/compose.yml"

wait_api(){
  local i
  for i in $(seq 1 60); do
    if curl -fsS --max-time 3 "${BASE_URL}/docs" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

retain(){
  local text="$1" body
  body=$(python3 -c 'import json,sys; print(json.dumps({"items":[{"content":sys.argv[1]}]}, ensure_ascii=False))' "$text")
  curl -fsS --max-time 180 -H 'Content-Type: application/json' \
    -X POST "${BASE_URL}/v1/default/banks/${BANK_ID}/memories" -d "$body" >/dev/null
}

recall_json(){
  local query="$1" out="$2" body
  body=$(python3 -c 'import json,sys; print(json.dumps({"query":sys.argv[1]}, ensure_ascii=False))' "$query")
  curl -fsS --max-time 120 -H 'Content-Type: application/json' \
    -X POST "${BASE_URL}/v1/default/banks/${BANK_ID}/memories/recall" -d "$body" >"$out"
}

contains(){
  local file="$1" needle="$2"
  python3 - "$file" "$needle" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data=json.load(f)
needle=sys.argv[2]
def strings(x):
    if isinstance(x,str): yield x
    elif isinstance(x,dict):
        for v in x.values(): yield from strings(v)
    elif isinstance(x,list):
        for v in x: yield from strings(v)
text='\n'.join(strings(data))
raise SystemExit(0 if needle in text else 1)
PY
}

wait_api || die "Hindsight API 当前不可访问。"
printf '该测试会创建临时测试记忆、生成新备份，并真实执行一次 volume 恢复。输入 TEST-RESTORE 确认：'
read -r CONFIRM
[[ "$CONFIRM" == "TEST-RESTORE" ]] || die "已取消。"

log "1/7 写入备份前基准记忆"
retain "$BEFORE" || die "写入 BEFORE-BACKUP 失败。"
recall_json "${RUN_ID} BEFORE-BACKUP" /tmp/hindsight-br-before.json || die "Recall BEFORE-BACKUP 失败。"
contains /tmp/hindsight-br-before.json "BEFORE-BACKUP" || die "备份前无法找回 BEFORE-BACKUP。"
ok "备份前基准记忆可 Recall"

log "2/7 创建新的灾难恢复备份"
BEFORE_LIST=$(mktemp)
AFTER_LIST=$(mktemp)
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'hindsight-*.tar.gz' -printf '%f\n' 2>/dev/null | sort >"$BEFORE_LIST" || true
BACKUP_DIR="$BACKUP_DIR" bash "${ROOT_DIR}/scripts/05-backup.sh"
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'hindsight-*.tar.gz' -printf '%f\n' 2>/dev/null | sort >"$AFTER_LIST" || true
BACKUP_NAME=$(comm -13 "$BEFORE_LIST" "$AFTER_LIST" | tail -n1)
rm -f "$BEFORE_LIST" "$AFTER_LIST"
[[ -n "$BACKUP_NAME" ]] || die "无法确定本轮新生成的备份文件。"
BACKUP_FILE="${BACKUP_DIR}/${BACKUP_NAME}"
[[ -s "$BACKUP_FILE" && -f "${BACKUP_FILE}.sha256" ]] || die "本轮备份或 SHA256 文件不存在。"
ok "本轮恢复点：${BACKUP_FILE}"

wait_api || die "备份完成后 Hindsight 未恢复可用。"

log "3/7 写入仅存在于备份之后的记忆"
retain "$AFTER" || die "写入 AFTER-BACKUP 失败。"
recall_json "${RUN_ID} AFTER-BACKUP" /tmp/hindsight-br-after.json || die "Recall AFTER-BACKUP 失败。"
contains /tmp/hindsight-br-after.json "AFTER-BACKUP" || die "恢复前无法找回 AFTER-BACKUP。"
ok "确认 AFTER-BACKUP 在恢复前存在"

log "4/7 恢复刚创建的备份"
printf 'RESTORE\n' | bash "${ROOT_DIR}/scripts/06-restore.sh" "$BACKUP_FILE"

log "5/7 重新启动 Hindsight 并等待 API"
(cd "$DEPLOY_DIR" && docker compose up -d)
wait_api || die "恢复后 Hindsight API 未在 120 秒内恢复。"
ok "恢复后 Hindsight API 可访问"

log "6/7 验证备份前数据仍存在"
recall_json "${RUN_ID} BEFORE-BACKUP" /tmp/hindsight-br-restored-before.json || die "恢复后 Recall BEFORE-BACKUP 失败。"
contains /tmp/hindsight-br-restored-before.json "BEFORE-BACKUP" || die "恢复后 BEFORE-BACKUP 丢失。"
ok "恢复后 BEFORE-BACKUP 仍存在"

log "7/7 验证备份后数据已经回滚"
recall_json "${RUN_ID} AFTER-BACKUP" /tmp/hindsight-br-restored-after.json || die "恢复后 Recall AFTER-BACKUP 失败。"
if contains /tmp/hindsight-br-restored-after.json "AFTER-BACKUP"; then
  cat /tmp/hindsight-br-restored-after.json
  die "恢复后仍找到 AFTER-BACKUP，时间点回滚失败。"
fi
ok "恢复后 AFTER-BACKUP 已不存在"

printf '\n========== Hindsight 灾备闭环验收 ==========\n'
printf '[✓] 备份前数据可检索\n'
printf '[✓] 备份文件与 SHA256 已生成\n'
printf '[✓] 备份后数据在恢复前可检索\n'
printf '[✓] volume 恢复成功\n'
printf '[✓] 恢复后服务自动重新拉起并可访问\n'
printf '[✓] 备份前数据保留\n'
printf '[✓] 备份后数据已回滚\n'
printf '[✓] 恢复点：%s\n' "$BACKUP_FILE"
printf '\n结果：backup → mutate → restore → verify 闭环通过。\n'
printf '==============================================\n'