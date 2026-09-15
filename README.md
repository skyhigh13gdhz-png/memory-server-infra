# memory-server-infra

个人 AI 外置记忆系统的服务器基础设施仓库。

这个仓库负责把一台干净的 Ubuntu 服务器自动化配置成可运行个人记忆服务的基础环境。目前已经在一台低配置 Ubuntu 测试服务器上完整跑通基础记忆层部署。

## 当前架构

```text
AI / Memory Gateway（下一阶段）
             ↓
        Hindsight
     API 8888 / UI 9999
             ↓
   embedded PostgreSQL / pg0

Hindsight 出站
     ↓ HTTP_PROXY
127.0.0.1:10809（Xray）
     ↓
   海外网络
```

仓库当前负责：

- 系统环境预检与 Swap 策略
- Docker Engine / Docker Compose 安装
- Docker daemon 经本机 Xray 出站
- Hindsight 部署与持久化
- ChatGPT / Codex OAuth 认证
- Hindsight 8888/9999 本机访问隔离
- 健康检查
- Hindsight 数据备份与恢复

## 设计原则

1. **自动化优先**：尽量通过脚本完成安装、检查、升级和恢复，避免依赖手工操作。
2. **可重复执行**：安装脚本保持幂等，多次执行不应破坏已有环境。
3. **敏感信息不进入 Git**：API Key、OAuth 凭据、数据库密码、VLESS 信息、真实记忆数据等只保存在服务器本地。
4. **数据与代码分离**：仓库保存部署代码和模板，真实数据放在持久化卷或后续对象存储中。
5. **默认不暴露服务**：Hindsight API/UI 不应直接暴露公网，后续统一由 Memory Gateway 提供受控访问入口。
6. **中文优先**：README、脚本提示和运维说明优先使用中文，代码变量和标准技术术语保留英文。

## 目录

```text
memory-server-infra/
├── setup.sh
├── scripts/
│   ├── 00-preflight.sh
│   ├── 01-system-init.sh
│   ├── 02-install-docker.sh
│   ├── 03-docker-proxy.sh
│   ├── 04-hindsight-firewall.sh
│   ├── 04-hindsight.sh
│   ├── 05-backup.sh
│   ├── 06-restore.sh
│   └── health-check.sh
├── docker/
│   └── hindsight/
│       ├── compose.yml
│       └── .env.example
└── README.md
```

## Hindsight 网络与安全设计

### 为什么当前使用 host network

服务器上的 Xray HTTP 入站只监听：

```text
127.0.0.1:10809
```

Hindsight 需要通过该代理访问外部 LLM 服务。当前使用 Docker `host network`，使容器能够直接访问宿主机 loopback 上的 Xray，而不需要把 Xray 代理开放到 Docker bridge 或 `0.0.0.0`。

代价是 Hindsight 自身默认会在宿主机所有地址监听：

```text
0.0.0.0:8888   Hindsight API
0.0.0.0:9999   Hindsight Web UI
```

因此不能仅根据 `ss` 中的监听地址判断服务已经安全。

### 8888 / 9999 的隔离方式

`scripts/04-hindsight-firewall.sh` 会建立主机 INPUT 防火墙规则：

- loopback (`lo`) 访问 8888/9999：允许
- 非 loopback IPv4 访问 8888/9999：DROP
- 非 loopback IPv6 访问 8888/9999：DROP
- 规则通过 `hindsight-local-only.service` 在开机后自动恢复

因此当前模型为：

```text
本机 / Memory Gateway
        ↓
127.0.0.1:8888 / 9999
        ↓
     Hindsight

公网 / 其他网卡
        ↓
   主机防火墙 DROP
```

健康检查会同时验证防火墙规则及 systemd 持久化状态。即使进程仍显示监听 `0.0.0.0:8888/9999`，只要非 loopback INPUT DROP 规则存在且持久化检查通过，就视为已完成主机层隔离。

> 后续 Memory Gateway 不应通过开放 Hindsight 8888/9999 实现远程访问，而应作为独立、可认证的入口层。

## Codex OAuth 凭据设计

Hindsight 使用 `openai-codex` Provider 时，不要求把 LLM API Key 写入 `.env`。

服务器使用独立的 Codex OAuth 目录：

```text
/var/lib/hindsight/codex/auth.json
```

原始 OAuth 凭据保持严格权限，不直接放宽给容器用户。部署脚本会：

1. 自动读取 Hindsight 镜像实际运行 UID/GID；
2. 在服务器本地准备 Hindsight 专用凭据副本；
3. 按容器实际 UID/GID 设置最小读取权限；
4. 只把该文件挂载进 Hindsight；
5. 凭据文件和内容永不提交 Git。

这样避免为了修复容器 `Permission denied` 而把原始 OAuth 文件改成全局可读。

## 一键部署

在已经配置好本机 Xray 的服务器上：

```bash
git pull
sudo bash setup.sh
```

当前流程依次执行：

1. 环境预检
2. 内存与 Swap 初始化
3. Docker 安装/验证
4. Docker → Xray 出站验证
5. Hindsight 8888/9999 本机隔离
6. Hindsight 部署
7. 整体健康检查

全部通过时应看到：

```text
结果：OK=... WARN=0 FAIL=0
基础健康检查通过。
```

## 已实测环境

基础部署链路已在以下测试环境完整跑通：

- Ubuntu 24.04 (noble)
- amd64
- Docker Engine 29.8.0
- Docker Compose v5.5.1
- 约 2GB 物理 RAM
- 约 10GB Swap
- ext4
- 本机 Xray HTTP 代理 `127.0.0.1:10809`
- Hindsight `latest`
- Codex CLI 0.154.0
- ChatGPT / Codex Device OAuth

最终健康检查实测达到 `WARN=0 / FAIL=0`。

### 低内存机器说明

Hindsight 官方总体最低建议高于当前测试机的约 2GB 物理 RAM，因此这里的成功结果只代表**安装、启动、认证、代理与网络隔离链路已跑通**，不代表 2GB RAM 已被验证适合长期生产负载。

正式服务器仍应继续观察：

- 实际记忆写入/检索时的 RAM 与 Swap 使用；
- embedding / reranking 时的峰值资源；
- 长时间运行稳定性；
- 重启后的自动恢复；
- 备份与恢复实测。

## 当前验证状态

已经实测通过：

- Docker 自动安装与重复执行
- Docker daemon 经 Xray 拉取镜像
- Hindsight 镜像拉取与启动
- Codex Device OAuth 经 Xray 完成授权
- Hindsight 非 root 用户读取专用 OAuth 凭据
- Hindsight API `127.0.0.1:8888/docs`
- Hindsight Web UI `127.0.0.1:9999`
- 8888/9999 非 loopback IPv4/IPv6 主机防火墙隔离
- 防火墙规则 systemd 开机恢复配置
- 一键部署最终健康检查 `WARN=0 / FAIL=0`

仍需继续做真实验证：

- 服务器重启后的完整恢复
- Hindsight retain / recall / reflect 实际调用
- Codex OAuth token 刷新后的长期稳定性
- 备份与恢复闭环
- `setup.sh` 再次重复执行的幂等性回归

完成这些验证后，再把这套基础设施迁移到正式新服务器，并进入 Memory Gateway 接入阶段。

> 本仓库不存放任何真实个人记忆数据、认证凭据或代理密钥。
