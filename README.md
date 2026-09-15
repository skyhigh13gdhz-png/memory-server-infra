# memory-server-infra

一套面向个人 AI 外置记忆系统的 Ubuntu 服务器基础设施。

目标不是把记忆绑定到某个 AI 客户端，而是在服务器上建立独立、可迁移的记忆基础层：当前以 Hindsight 为记忆引擎，后续由 Memory Gateway 向 ChatGPT、Qwen、Claude、Hermes、Codex 等不同客户端提供统一入口。

> 本仓库是公开的部署代码仓库。真实个人记忆、OAuth 凭据、API Key、代理节点信息和备份数据均不进入 Git。

## 架构

```text
ChatGPT / Qwen / Claude / Hermes / Codex / future AI
                         ↓
                  Memory Gateway
                    （下一阶段）
                         ↓
                     Hindsight
                 API 8888 / UI 9999
                         ↓
              embedded PostgreSQL / pg0
```

网络侧采用选择性出站：国内/本地服务保持直连，需要海外网络的流量由现有 Xray routing 决定。Hindsight 的 Codex 请求通过专属透明代理进入 Xray，不依赖应用是否支持 `HTTP_PROXY`。

## 已实现

- Ubuntu 环境预检与自适应 Swap
- Docker Engine / Docker Compose 自动安装
- Docker daemon 经本机 Xray 拉取境外镜像
- Hindsight 部署与持久化
- ChatGPT / Codex OAuth 登录及独立可刷新凭据目录
- Hindsight 专属透明代理
- 8888/9999 非 loopback IPv4/IPv6 防火墙隔离
- systemd 开机恢复网络规则
- Retain / Recall / Reflect 功能验收
- Hindsight 数据卷备份与恢复脚本
- Public GitHub 一键引导安装

## 快速开始

### 推荐：Public 仓库引导安装

在一台已配置并运行 Xray 的 Ubuntu 服务器上：

```bash
curl -fsSL https://raw.githubusercontent.com/skyhigh13gdhz-png/memory-server-infra/main/bootstrap.sh | sudo bash
```

引导脚本会：

1. 检查并安装 Git；
2. 创建源码目录 `/opt/src`；
3. 通过 HTTPS 拉取/更新本 Public 仓库到 `/opt/src/memory-server-infra`；
4. 执行正式 `setup.sh`；
5. 敏感配置仅在服务器本地生成或读取。

不再需要 GitHub Deploy Key、SSH alias 或私人仓库访问凭据。

### 已经 clone 仓库

```bash
cd /opt/src/memory-server-infra
git pull --ff-only
sudo bash setup.sh
```

部署流程共 8 个阶段：环境预检 → Swap → Docker → Docker/Xray → Hindsight 本机隔离 → Hindsight 部署 → Hindsight 专属透明代理 → 健康检查。

部署完成后建议执行真实功能验收：

```bash
sudo bash scripts/07-hindsight-smoke-test.sh
```

## 源码与运行数据分离

推荐目录：

```text
/opt/
├── src/
│   └── memory-server-infra/      # Git 源码，可随时重新 clone
└── memory-server-infra/          # 部署后的运行配置/状态
    └── hindsight/
```

删除源码目录不应删除真实记忆数据；运行数据、OAuth 凭据和备份也不应反向进入源码仓库。

## 网络与安全设计

Hindsight 当前使用 Docker host network，以便访问宿主机 loopback 上的 Xray。Hindsight 自身可能显示监听 `0.0.0.0:8888` / `0.0.0.0:9999`，因此由 `scripts/04-hindsight-firewall.sh` 在主机 INPUT 层阻断所有非 loopback IPv4/IPv6 访问，并通过 systemd 在重启后恢复。

Codex Provider 的 HTTP 客户端并不依赖 shell 代理环境，因此 `scripts/03-hindsight-transparent-proxy.sh` 只接管 Hindsight 运行 UID 的 TCP 出站，将其送入本机 Xray 透明入口；国内/海外的最终分流继续由 Xray routing 决定。

当前实现按运行 UID 匹配，因此如果宿主机普通用户恰好与 Hindsight 使用相同 UID，该用户主动发起的 TCP 也可能命中该规则。它不会影响入站 SSH；后续可进一步升级为 cgroup/network namespace 级隔离。

## Codex OAuth 凭据

Hindsight 使用 `openai-codex` Provider 时无需把 OpenAI API Key 写入 `.env`。部署脚本会检测容器实际 UID/GID，在服务器本地准备独立 Codex 目录，并以可写方式挂载，使 Hindsight 能持久化 OAuth token 刷新状态。

默认本地路径：

```text
/var/lib/hindsight/codex/auth.json
```

该文件不进入 Git，`.gitignore` 也显式忽略 `auth.json`、`.env`、密钥、secrets、数据库和备份文件。

## Public 仓库安全边界

**允许提交：**脚本、Compose 模板、`.env.example`、文档、无敏感信息的测试逻辑。

**禁止提交：**真实 `.env`、`auth.json`、API Key、OAuth token、VLESS/代理凭据、SSH 私钥、真实记忆数据、数据库 dump、备份文件。

仓库公开前已使用 Gitleaks 对当时完整 Git 历史进行扫描：46 commits、约 111.75 KB，结果 `no leaks found`。这不是未来提交可以放松检查的理由；新增敏感配置仍应坚持只落服务器本地。

## 已验证状态

测试环境：Ubuntu 24.04 / amd64 / 约 2GB RAM + Swap / Docker 29.8.0 / Compose v5.5.1。

已经实际跑通：

- Docker 安装、镜像拉取和 Xray 出站
- Hindsight 启动与本机端口隔离
- ChatGPT / Codex Device OAuth
- GPT-5.6 Luna
- Hindsight 专属透明代理
- Retain → Recall → Reflect
- Docker container restart 后功能恢复
- 整机 reboot 后 Xray、Docker、透明代理和 Hindsight 自动启动
- Public 前完整 Git 历史 Gitleaks 扫描无泄漏

仍需继续验证：

- 整机 reboot 后再次执行 Retain / Recall / Reflect，完成完整功能级重启闭环
- Codex OAuth token 实际刷新周期后的长期稳定性
- 备份 → 写入新数据 → 恢复 → 数据回滚闭环
- 完整 `setup.sh` 重复执行幂等性回归

低配置测试机跑通不代表 2GB RAM 适合长期生产负载。正式服务器仍需持续观察 RAM、Swap、embedding/reranking 峰值和长期稳定性。

## 下一阶段

Memory Gateway 将成为稳定边界：负责客户端身份、认证、bank 隔离/共享策略以及统一的 retain / recall / reflect 语义。Hindsight 是当前记忆引擎，但客户端不直接绑定 Hindsight，从而保留未来替换或组合其他记忆引擎的空间。
