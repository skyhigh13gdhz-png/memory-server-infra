#!/usr/bin/env bash
set -Eeuo pipefail

# 配置 Docker daemon 通过宿主机 Xray HTTP 入站拉取海外镜像。
# 注意：这只解决 dockerd 拉镜像等流量；容器自身的出站代理是另一条路径，不在这里全局注入。

XRAY_HTTP_PROXY="${XRAY_HTTP_PROXY:-http://127.0.0.1:10809}"
DROPIN_DIR="/etc/systemd/system/docker.service.d"
DROPIN_FILE="${DROPIN_DIR}/xray-proxy.conf"
NO_PROXY_VALUE="${NO_PROXY_VALUE:-localhost,127.0.0.1,::1}"

log(){ printf '\n[INFO] %s\n' "$*"; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "请使用 sudo/root 运行。"
command -v docker >/dev/null 2>&1 || die "未检测到 Docker，请先运行 02-install-docker.sh。"
systemctl is-active --quiet docker || die "Docker 服务当前不是 active。"
systemctl is-active --quiet xray || die "Xray 服务当前不是 active。"

proxy_host="${XRAY_HTTP_PROXY#http://}"
proxy_host="${proxy_host%%/*}"
proxy_port="${proxy_host##*:}"
[[ "$proxy_port" =~ ^[0-9]+$ ]] || die "无法从 XRAY_HTTP_PROXY 解析端口：${XRAY_HTTP_PROXY}"

if ! ss -lnt | awk '{print $4}' | grep -Eq "(^|:)${proxy_port}$"; then
  die "没有检测到本机 Xray HTTP 代理端口 ${proxy_port} 正在监听。"
fi

log "先直接通过 Xray HTTP 入站验证海外 HTTPS。"
curl --proxy "$XRAY_HTTP_PROXY" -fsSIL --max-time 20 https://registry-1.docker.io/v2/ >/dev/null || \
  die "通过 Xray 访问 Docker Registry 失败，暂不修改 Docker。"

mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_FILE" <<EOF
[Service]
Environment="HTTP_PROXY=${XRAY_HTTP_PROXY}"
Environment="HTTPS_PROXY=${XRAY_HTTP_PROXY}"
Environment="NO_PROXY=${NO_PROXY_VALUE}"
EOF

systemctl daemon-reload
systemctl restart docker
sleep 2
systemctl is-active --quiet docker || die "写入代理后 Docker 重启失败。"

log "Docker daemon 代理环境："
systemctl show --property=Environment docker

log "执行轻量镜像拉取验证。"
# alpine 很小，验证成功后保留镜像供后续诊断使用。
docker pull alpine:latest >/dev/null || die "Docker 通过当前出站配置拉取 alpine 失败。"

log "Docker daemon 出站代理配置完成。"
echo "说明：这里没有给所有容器自动注入 HTTP_PROXY。后续 Hindsight 容器的出站将单独、安全配置。"
