#!/usr/bin/env bash
set -Eeuo pipefail

# memory-server-infra / 第一阶段：服务器环境检测与 Swap 初始化
# 目标环境：Ubuntu 64 位服务器。
# 默认策略不是“无脑再创建 4G Swap”，而是根据物理内存和已有 Swap 计算目标总 Swap。

TARGET_SWAP_MB="${TARGET_SWAP_MB:-4096}"
MIN_DISK_FREE_MB="${MIN_DISK_FREE_MB:-6144}"
SWAP_FILE="${SWAP_FILE:-/swapfile-memory-infra}"
SWAPPINESS="${SWAPPINESS:-10}"

log()  { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行：sudo bash scripts/01-system-init.sh"
}

read_os() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
  OS_CODENAME="${VERSION_CODENAME:-unknown}"
}

mb_from_kb() {
  awk -v kb="$1" 'BEGIN { printf "%d", kb / 1024 }'
}

collect_environment() {
  read_os
  ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  KERNEL="$(uname -r)"
  MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  SWAP_KB="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
  MEM_MB="$(mb_from_kb "$MEM_KB")"
  SWAP_MB="$(mb_from_kb "$SWAP_KB")"
  ROOT_FREE_MB="$(df -Pm / | awk 'NR==2 {print $4}')"
  ROOT_FS="$(findmnt -n -o FSTYPE / 2>/dev/null || echo unknown)"
  XRAY_STATE="not-installed"
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files xray.service >/dev/null 2>&1; then
    XRAY_STATE="$(systemctl is-active xray 2>/dev/null || true)"
  fi
  DOCKER_STATE="not-installed"
  if command -v docker >/dev/null 2>&1; then
    DOCKER_STATE="installed"
  fi
}

print_report() {
  cat <<EOF

========== memory-server-infra 环境检测 ==========
系统             : ${OS_ID} ${OS_VERSION} (${OS_CODENAME})
架构             : ${ARCH}
内核             : ${KERNEL}
物理内存         : ${MEM_MB} MB
当前 Swap        : ${SWAP_MB} MB
根分区文件系统   : ${ROOT_FS}
根分区可用空间   : ${ROOT_FREE_MB} MB
Xray 服务        : ${XRAY_STATE}
Docker           : ${DOCKER_STATE}
目标总 Swap      : ${TARGET_SWAP_MB} MB
=================================================
EOF
}

preflight() {
  [[ "$OS_ID" == "ubuntu" ]] || die "当前只自动支持 Ubuntu；检测到：${OS_ID}。"

  case "$ARCH" in
    amd64|arm64) ;;
    *) warn "当前架构 ${ARCH} 尚未作为主测试目标，后续 Docker/Hindsight 阶段需要再次确认镜像支持。" ;;
  esac

  if (( MEM_MB < 1800 )); then
    warn "物理内存低于约 2GB。Hindsight 官方总体建议至少 4GB RAM；这台机器只能按低资源实验方案部署。"
  elif (( MEM_MB < 4096 )); then
    warn "物理内存不足 4GB。后续 Hindsight 将采用低并发配置，并依赖 Swap 缓冲峰值内存。"
  fi
}

ensure_swap() {
  if (( SWAP_MB >= TARGET_SWAP_MB )); then
    log "当前总 Swap 已有 ${SWAP_MB} MB，达到目标 ${TARGET_SWAP_MB} MB，不创建新的 Swap。"
    return 0
  fi

  local need_mb=$(( TARGET_SWAP_MB - SWAP_MB ))
  local reserve_mb=2048
  local required_mb=$(( need_mb + reserve_mb ))

  if [[ -e "$SWAP_FILE" ]]; then
    # 如果脚本自己的 swapfile 已存在但当前没有启用，优先尝试恢复，而不是覆盖。
    if ! swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAP_FILE"; then
      log "检测到已有 ${SWAP_FILE}，尝试启用。"
      chmod 600 "$SWAP_FILE"
      swapon "$SWAP_FILE" || die "已有 Swap 文件启用失败，请先人工检查 ${SWAP_FILE}。"
    fi
    SWAP_KB="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
    SWAP_MB="$(mb_from_kb "$SWAP_KB")"
    if (( SWAP_MB >= TARGET_SWAP_MB )); then
      log "恢复已有 Swap 后，总 Swap 已达到 ${SWAP_MB} MB。"
      return 0
    fi
    die "${SWAP_FILE} 已存在且已启用，但总 Swap 仍不足目标。为避免覆盖已有配置，脚本停止。"
  fi

  if (( ROOT_FREE_MB < MIN_DISK_FREE_MB || ROOT_FREE_MB < required_mb )); then
    die "磁盘空间不足以安全创建约 ${need_mb} MB Swap。当前根分区可用 ${ROOT_FREE_MB} MB；脚本要求至少保留约 ${reserve_mb} MB 余量。"
  fi

  log "当前 Swap ${SWAP_MB} MB；将补充约 ${need_mb} MB，使总 Swap 接近 ${TARGET_SWAP_MB} MB。"

  if command -v fallocate >/dev/null 2>&1; then
    if ! fallocate -l "${need_mb}M" "$SWAP_FILE"; then
      warn "fallocate 失败，改用 dd 创建 Swap 文件。"
      dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$need_mb" status=progress
    fi
  else
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$need_mb" status=progress
  fi

  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE" >/dev/null
  swapon "$SWAP_FILE"

  if ! grep -Eq "^[[:space:]]*${SWAP_FILE//\//\\/}[[:space:]]" /etc/fstab; then
    printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab
  fi

  log "Swap 已创建并启用。"
}

configure_vm() {
  cat > /etc/sysctl.d/99-memory-server-infra.conf <<EOF
# Managed by memory-server-infra
vm.swappiness=${SWAPPINESS}
EOF
  sysctl --system >/dev/null
  log "已设置 vm.swappiness=${SWAPPINESS}。"
}

verify() {
  local final_swap_kb final_swap_mb
  final_swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
  final_swap_mb="$(mb_from_kb "$final_swap_kb")"

  echo
  free -h
  echo
  swapon --show || true

  if (( final_swap_mb < TARGET_SWAP_MB - 64 )); then
    warn "最终 Swap ${final_swap_mb} MB，略低于目标 ${TARGET_SWAP_MB} MB，请检查上方输出。"
  else
    log "系统初始化检查通过：当前总 Swap 约 ${final_swap_mb} MB。"
  fi
}

main() {
  require_root
  collect_environment
  print_report
  preflight
  ensure_swap
  configure_vm
  verify

  cat <<'EOF'

下一阶段：Docker 安装与 Docker 出站代理配置。
本脚本不会安装 Docker，也不会修改现有 Xray 节点配置。
EOF
}

main "$@"
