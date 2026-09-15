#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/memory-server/backups}"
VOLUME="${HINDSIGHT_VOLUME:-hindsight-data}"
KEEP_DAYS="${KEEP_DAYS:-14}"
STAMP="$(date +%Y%m%d-%H%M%S)"
FILE="${BACKUP_DIR}/hindsight-${STAMP}.tar.gz"

[[ ${EUID} -eq 0 ]] || { echo '[ERROR] 请使用 sudo/root 运行。' >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo '[ERROR] Docker 不存在。' >&2; exit 1; }
docker volume inspect "$VOLUME" >/dev/null 2>&1 || { echo "[ERROR] Docker volume 不存在：$VOLUME" >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# 这是文件级 volume 备份。为获得一致性，默认短暂停止 Hindsight；备份后恢复原运行状态。
WAS_RUNNING=0
if docker ps --format '{{.Names}}' | grep -Fxq hindsight; then
  WAS_RUNNING=1
  echo '[INFO] 为保证 embedded PostgreSQL 文件一致性，短暂停止 Hindsight。'
  docker stop hindsight >/dev/null
fi

restore_service() {
  if (( WAS_RUNNING == 1 )); then docker start hindsight >/dev/null 2>&1 || true; fi
}
trap restore_service EXIT

echo "[INFO] 备份 volume ${VOLUME} → ${FILE}"
docker run --rm -v "${VOLUME}:/source:ro" -v "${BACKUP_DIR}:/backup" alpine:latest \
  sh -c "cd /source && tar -czf /backup/$(basename "$FILE") ."

[[ -s "$FILE" ]] || { echo '[ERROR] 备份文件为空。' >&2; exit 1; }
sha256sum "$FILE" > "${FILE}.sha256"
chmod 600 "$FILE" "${FILE}.sha256"

# 只清理本脚本命名的历史备份，不碰其他文件。
find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'hindsight-*.tar.gz' -o -name 'hindsight-*.tar.gz.sha256' \) -mtime "+${KEEP_DAYS}" -delete

echo '[OK] 备份完成：'
ls -lh "$FILE" "${FILE}.sha256"
