#!/usr/bin/env bash
set -Eeuo pipefail

VOLUME="${HINDSIGHT_VOLUME:-hindsight-data}"
BACKUP_FILE="${1:-}"

[[ ${EUID} -eq 0 ]] || { echo '[ERROR] 请使用 sudo/root 运行。' >&2; exit 1; }
[[ -n "$BACKUP_FILE" ]] || { echo '用法：sudo bash scripts/06-restore.sh /opt/memory-server/backups/hindsight-YYYYMMDD-HHMMSS.tar.gz' >&2; exit 1; }
[[ -f "$BACKUP_FILE" ]] || { echo "[ERROR] 找不到备份：$BACKUP_FILE" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo '[ERROR] Docker 不存在。' >&2; exit 1; }

if [[ -f "${BACKUP_FILE}.sha256" ]]; then
  echo '[INFO] 校验 SHA256...'
  (cd "$(dirname "$BACKUP_FILE")" && sha256sum -c "$(basename "${BACKUP_FILE}.sha256")")
else
  echo '[WARN] 没有对应 .sha256 文件，无法验证备份完整性。'
fi

if docker ps --format '{{.Names}}' | grep -Fxq hindsight; then
  echo '[INFO] 停止 Hindsight。'
  docker stop hindsight >/dev/null
fi

docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME" >/dev/null

# 恢复是破坏性操作，必须显式确认，避免一键脚本误覆盖现有记忆。
printf '即将清空 Docker volume [%s] 并恢复备份。输入 RESTORE 确认：' "$VOLUME"
read -r CONFIRM
[[ "$CONFIRM" == 'RESTORE' ]] || { echo '已取消。'; exit 1; }

DIR="$(cd "$(dirname "$BACKUP_FILE")" && pwd)"
BASE="$(basename "$BACKUP_FILE")"

echo '[INFO] 清空目标 volume 并恢复...'
docker run --rm -v "${VOLUME}:/target" alpine:latest sh -c 'find /target -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'
docker run --rm -v "${VOLUME}:/target" -v "${DIR}:/backup:ro" alpine:latest \
  sh -c "cd /target && tar -xzf /backup/${BASE}"

echo '[OK] 数据恢复完成。'
echo '请使用部署目录中的 docker compose 启动 Hindsight，然后运行 scripts/health-check.sh。'
