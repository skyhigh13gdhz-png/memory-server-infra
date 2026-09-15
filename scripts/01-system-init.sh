#!/usr/bin/env bash
set -Eeuo pipefail
trap 'rc=$?; printf "\n[ERROR] 01-system-init.sh 第 %s 行执行失败，退出码 %s：%s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2; exit "$rc"' ERR

SWAP_FILE="${SWAP_FILE:-/swapfile-memory-infra}"
SWAPPINESS="${SWAPPINESS:-10}"
DISK_RESERVE_MB="${DISK_RESERVE_MB:-4096}"
log(){ printf '\n[INFO] %s\n' "$*"; }; warn(){ printf '\n[WARN] %s\n' "$*" >&2; }; die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
require_root(){ [[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行：sudo bash scripts/01-system-init.sh"; }
read_os(){ [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"; . /etc/os-release; OS_ID="${ID:-unknown}"; OS_VERSION="${VERSION_ID:-unknown}"; OS_CODENAME="${VERSION_CODENAME:-unknown}"; }
mb_from_kb(){ awk -v kb="$1" 'BEGIN { printf "%d", kb / 1024 }'; }

collect_environment(){
  read_os
  ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  KERNEL="$(uname -r)"
  MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"; SWAP_KB="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
  MEM_MB="$(mb_from_kb "$MEM_KB")"; SWAP_MB="$(mb_from_kb "$SWAP_KB")"
  ROOT_FREE_MB="$(df -Pm / | awk 'NR==2 {print $4}')"; ROOT_FS="$(findmnt -n -o FSTYPE / 2>/dev/null || printf unknown)"
  XRAY_STATE="not-installed"
  if command -v systemctl >/dev/null 2>&1 && systemctl cat xray.service >/dev/null 2>&1; then
    XRAY_STATE="$(systemctl is-active xray 2>/dev/null || printf inactive)"
  fi
  DOCKER_STATE="not-installed"; if command -v docker >/dev/null 2>&1; then DOCKER_STATE="installed"; fi
}

choose_swap_policy(){
  if [[ -n "${TARGET_SWAP_MB:-}" ]]; then [[ "$TARGET_SWAP_MB" =~ ^[0-9]+$ ]] || die "TARGET_SWAP_MB 必须是非负整数（MB）。"; SWAP_POLICY="manual override"; return; fi
  if (( MEM_MB < 4096 )); then TARGET_SWAP_MB=4096; SWAP_POLICY="RAM < 4GB：低内存保护，目标 4GB Swap"
  elif (( MEM_MB < 8192 )); then TARGET_SWAP_MB=2048; SWAP_POLICY="RAM 4–8GB：目标 2GB 应急 Swap"
  elif (( MEM_MB < 16384 )); then TARGET_SWAP_MB=1024; SWAP_POLICY="RAM 8–16GB：目标 1GB 应急 Swap"
  else TARGET_SWAP_MB=0; SWAP_POLICY="RAM >= 16GB：默认不主动创建 Swap"; fi
}

print_report(){ cat <<EOF

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

preflight(){
  [[ "$OS_ID" == ubuntu ]] || die "当前只自动支持 Ubuntu；检测到：${OS_ID}。"
  case "$ARCH" in amd64|arm64) ;; *) warn "当前架构 ${ARCH} 尚未作为主测试目标。";; esac
  if (( MEM_MB < 1800 )); then warn "物理内存低于约 2GB，Swap 只能缓冲峰值。"; elif (( MEM_MB < 4096 )); then warn "物理内存不足 4GB，后续 Hindsight 应采用低资源/低并发配置。"; fi
}

ensure_swap(){
  if (( TARGET_SWAP_MB == 0 )); then (( SWAP_MB > 0 )) && log "物理内存充足；已有 ${SWAP_MB} MB Swap，保留不删除。" || log "物理内存充足且无 Swap，本次不创建。"; return 0; fi
  if (( SWAP_MB >= TARGET_SWAP_MB )); then log "当前总 Swap ${SWAP_MB} MB 已达到策略目标 ${TARGET_SWAP_MB} MB，不做修改。"; return 0; fi
  local need_mb=$((TARGET_SWAP_MB-SWAP_MB)) required_mb=$((need_mb+DISK_RESERVE_MB))
  if [[ -e "$SWAP_FILE" ]]; then
    if ! swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAP_FILE"; then chmod 600 "$SWAP_FILE"; swapon "$SWAP_FILE" || die "已有 Swap 文件启用失败。"; fi
    SWAP_MB="$(mb_from_kb "$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)")"
    (( SWAP_MB >= TARGET_SWAP_MB )) && { log "恢复已有 Swap 后已达到 ${SWAP_MB} MB。"; return 0; }
    die "${SWAP_FILE} 已存在，但总 Swap 仍不足；为避免覆盖已有资源，停止。"
  fi
  (( ROOT_FREE_MB >= required_mb )) || die "磁盘空间不足：需要新增约 ${need_mb} MB Swap，并保留 ${DISK_RESERVE_MB} MB。"
  log "新增约 ${need_mb} MB Swap。"
  if command -v fallocate >/dev/null 2>&1; then fallocate -l "${need_mb}M" "$SWAP_FILE" || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$need_mb" status=progress; else dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$need_mb" status=progress; fi
  chmod 600 "$SWAP_FILE"; mkswap "$SWAP_FILE" >/dev/null; swapon "$SWAP_FILE"
  grep -Fq "$SWAP_FILE none swap" /etc/fstab || printf '%s none swap sw 0 0\n' "$SWAP_FILE" >>/etc/fstab
}

configure_vm(){ printf '# Managed by memory-server-infra\nvm.swappiness=%s\n' "$SWAPPINESS" >/etc/sysctl.d/99-memory-server-infra.conf; sysctl -w "vm.swappiness=${SWAPPINESS}" >/dev/null; log "已设置 vm.swappiness=${SWAPPINESS}。"; }
verify(){ local final; final="$(mb_from_kb "$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)")"; free -h; echo; swapon --show || true; log "系统内存初始化检查通过。RAM ${MEM_MB} MB，Swap 约 ${final} MB。"; }
main(){ require_root; collect_environment; choose_swap_policy; print_report; preflight; ensure_swap; configure_vm; verify; echo; echo "下一阶段：Docker 安装与 Docker 出站代理配置。"; }
main "$@"
