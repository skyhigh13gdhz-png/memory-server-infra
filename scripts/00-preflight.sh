#!/usr/bin/env bash
set -Eeuo pipefail

# 只读预检：不安装软件、不创建 Swap、不修改系统配置。

mb_from_kb() { awk -v kb="$1" 'BEGIN { printf "%d", kb / 1024 }'; }

[[ -r /etc/os-release ]] || { echo "[ERROR] 无法读取 /etc/os-release" >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release

MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
SWAP_KB="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
MEM_MB="$(mb_from_kb "$MEM_KB")"
SWAP_MB="$(mb_from_kb "$SWAP_KB")"
ROOT_FREE_MB="$(df -Pm / | awk 'NR==2 {print $4}')"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
ROOT_FS="$(findmnt -n -o FSTYPE / 2>/dev/null || echo unknown)"

xray_state="未安装"
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files xray.service >/dev/null 2>&1; then
  xray_state="$(systemctl is-active xray 2>/dev/null || true)"
fi

docker_state="未安装"
if command -v docker >/dev/null 2>&1; then
  docker_state="$(docker --version 2>/dev/null || echo 已安装)"
fi

cat <<EOF
========== Memory Server 只读预检 ==========
系统          : ${ID:-unknown} ${VERSION_ID:-unknown} (${VERSION_CODENAME:-unknown})
架构          : ${ARCH}
内核          : $(uname -r)
物理内存      : ${MEM_MB} MB
当前 Swap     : ${SWAP_MB} MB
根文件系统    : ${ROOT_FS}
根分区可用    : ${ROOT_FREE_MB} MB
Xray          : ${xray_state}
Docker        : ${docker_state}
============================================
EOF

echo
if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "[FAIL] 当前自动部署目标是 Ubuntu。"
  exit 2
fi

if (( ROOT_FREE_MB < 6144 )); then
  echo "[WARN] 根分区剩余空间低于 6GB，不建议直接创建 4GB 级 Swap 后继续部署 Hindsight。"
else
  echo "[OK] 根分区空间满足当前初始化脚本的最低安全线。"
fi

if (( SWAP_MB >= 4096 )); then
  echo "[OK] 当前 Swap 已达到 4GB 目标，不需要新增 Swap。"
elif (( SWAP_MB > 0 )); then
  echo "[INFO] 已存在 ${SWAP_MB} MB Swap；初始化脚本会按差额补足到约 4GB，而不是额外再加 4GB。"
else
  echo "[INFO] 当前没有 Swap；初始化脚本预计创建约 4GB Swap。"
fi

if (( MEM_MB < 4096 )); then
  echo "[WARN] 物理内存不足 4GB；Hindsight 官方总体最低建议为 4GB RAM。后续必须采用低资源部署并实测稳定性。"
else
  echo "[OK] 物理内存达到 Hindsight 官方最低 RAM 建议。"
fi

echo "[INFO] 本脚本为只读检测，没有修改任何系统配置。"
