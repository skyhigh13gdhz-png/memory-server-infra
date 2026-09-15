#!/usr/bin/env bash
set -Eeuo pipefail

# memory-server-infra / 第一阶段：服务器环境检测与 Swap 初始化
# 原则：根据物理 RAM、已有 Swap 和磁盘空间自适应决策；不机械固定 4GB，也不自动删除已有 Swap。

SWAP_FILE="${SWAP_FILE:-/swapfile-memory-infra}"
SWAPPINESS="${SWAPPINESS:-10}"
DISK_RESERVE_MB="${DISK_RESERVE_MB:-4096}"

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

mb_from_kb() { awk -v kb="$1" 'BEGIN { printf "%d", kb / 1024 }'; }

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
  command -v docker >/dev/null 2>&1 && DOCKER_STATE="installed"
}

choose_swap_policy() {
  # 可通过 TARGET_SWAP_MB 显式覆盖自动策略；适合特殊工作负载或人工调优。
  if [[ -n "${TARGET_SWAP_MB:-}" ]]; then
    [[ "$TARGET_SWAP_MB" =~ ^[0-9]+$ ]] || die "TARGET_SWAP_MB 必须是非负整数（MB）。"
    SWAP_POLICY="manual override"
    return
  fi

  # 面向本项目的保守策略：小内存机器提供明显缓冲；配置越高越少主动干预。
  if (( MEM_MB < 4096 )); then
    TARGET_SWAP_MB=4096
    SWAP_POLICY="RAM < 4GB：低内存保护，目标 4GB Swap"
  elif (( MEM_MB < 8192 )); then
    TARGET_SWAP_MB=2048
    SWAP_POLICY="RAM 4–8GB：目标 2GB 应急 Swap"
  elif (( MEM_MB < 16384 )); then
    TARGET_SWAP_MB=1024
    SWAP_POLICY="RAM 8–16GB：目标 1GB 应急 Swap"
  else
    TARGET_SWAP_MB=0
    SWAP_POLICY="RAM >= 16GB：默认不主动创建 Swap"
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
Swap 策略        : ${SWAP_POLICY}
目标最低 Swap    : ${TARGET_SWAP_MB} MB
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
    warn "物理内存低于约 2GB。Hindsight 属于明显受限环境，Swap 只能缓冲峰值，不能替代真实 RAM。"
  elif (( MEM_MB < 4096 )); then
    warn "物理内存不足 4GB。后续 Hindsight 应采用低资源/低并发配置。"
  fi
}

ensure_swap() {
  if (( TARGET_SWAP_MB == 0 )); then
    if (( SWAP_MB > 0 )); then
      log "当前物理内存充足，自动策略不要求新增 Swap；检测到已有 ${SWAP_MB} MB Swap，将保留，不做删除。"
    else
      log "当前物理内存充足且没有 Swap，本次不创建。"
    fi
    return 0
  fi

  if (( SWAP_MB >= TARGET_SWAP_MB )); then
    log "当前总 Swap ${SWAP_MB} MB 已达到本机策略目标 ${TARGET_SWAP_MB} MB，不做修改。"
    return 0
  fi

  local need_mb=$(( TARGET_SWAP_MB - SWAP_MB ))
  local required_mb=$(( need_mb + DISK_RESERVE_MB ))

  if [[ -e "$SWAP_FILE" ]]; then
    if ! swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAP_FILE"; then
      log "检测到本项目已有 ${SWAP_FILE} 但未启用，优先恢复。"
      chmod 600 "$SWAP_FILE"
      swapon "$SWAP_FILE" || die "已有 Swap 文件启用失败，请检查 ${SWAP_FILE}。"
    fi
    SWAP_KB="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
    SWAP_MB="$(mb_from_kb "$SWAP_KB")"
    if (( SWAP_MB >= TARGET_SWAP_MB )); then
      log "恢复已有 Swap 后，总 Swap 已达到 ${SWAP_MB} MB。"
      return 0
    fi
    die "${SWAP_FILE} 已存在且启用，但总 Swap 仍低于策略目标。为避免覆盖已有资源，脚本停止。"
  fi

  if (( ROOT_FREE_MB < required_mb )); then
    die "磁盘空间不足：新增约 ${need_mb} MB Swap 后还需至少保留 ${DISK_RESERVE_MB} MB；当前仅有 ${ROOT_FREE_MB} MB 可用。"
  fi

  log "将新增约 ${need_mb} MB Swap，使总量达到本机策略目标约 ${TARGET_SWAP_MB} MB。"
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${need_mb}M" "$SWAP_FILE" || {
      warn "fallocate 失败，改用 dd。"
      dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$need_mb" status=progress
    }
  else
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$need_mb" status=progress
  fi

  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE" >/dev/null
  swapon "$SWAP_FILE"
  if ! grep -Fq "$SWAP_FILE none swap" /etc/fstab; then
    printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab
  fi
  log "Swap 已创建、启用并写入 /etc/fstab。"
}

configure_vm() {
  # 即使高配机器已有历史 Swap，也只降低其主动使用倾向，不删除资源。
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

  if (( TARGET_SWAP_MB > 0 && final_swap_mb < TARGET_SWAP_MB - 64 )); then
    warn "最终 Swap ${final_swap_mb} MB，低于策略目标 ${TARGET_SWAP_MB} MB，请检查上方输出。"
  else
    log "系统内存初始化检查通过。物理 RAM ${MEM_MB} MB，当前 Swap 约 ${final_swap_mb} MB。"
  fi
}

main() {
  require_root
  collect_environment
  choose_swap_policy
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
