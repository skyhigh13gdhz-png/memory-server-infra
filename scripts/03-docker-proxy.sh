#!/usr/bin/env bash
set -Eeuo pipefail
trap 'rc=$?; printf "\n[ERROR] 03-docker-proxy.sh 第 %s 行失败，退出码 %s：%s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2; exit "$rc"' ERR

# 配置 Docker daemon 通过宿主机 Xray HTTP 入站拉取海外镜像。
# 注意：Docker Registry 的 /v2/ 对匿名请求正常会返回 HTTP 401；
# 401 反而证明 DNS/TCP/TLS/HTTP 已经成功穿过代理到达 Registry。

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

log "通过 Xray HTTP 入站验证 Docker Registry 连通性。"
# 不使用 curl -f：registry-1.docker.io/v2/ 对未认证请求预期返回 401。
# 只要得到任意有效 HTTP 状态码，就说明代理已经完成 DNS/TCP/TLS/HTTP 链路；
# 对这个端点 200 或 401 都是明确的成功结果。
http_code="$(curl --proxy "$XRAY_HTTP_PROXY" -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 https://registry-1.docker.io/v2/ || true)"
case "$http_code" in
  200|401) log "Xray → Docker Registry 连通正常（HTTP ${http_code}，401 为匿名 Registry 的预期响应）。" ;;
  000|'') die "通过 Xray 未能与 Docker Registry 建立有效 HTTP 连接。" ;;
  *) die "通过 Xray 到达 Docker Registry，但返回异常 HTTP ${http_code}；暂不修改 Docker。" ;;
esac

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
docker pull alpine:latest >/dev/null || die "Docker 通过当前出站配置拉取 alpine 失败。"

log "Docker daemon 出站代理配置完成。"
echo "说明：这里没有给所有容器自动注入 HTTP_PROXY。后续 Hindsight 容器的出站将单独、安全配置。"
