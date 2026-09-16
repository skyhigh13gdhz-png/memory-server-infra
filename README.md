# memory-server-infra

一套面向个人 AI 外置记忆系统的 Ubuntu 服务器基础设施。

目标不是把记忆绑定到某个 AI 客户端，而是在服务器上建立独立、可迁移的记忆基础层：当前以 Hindsight 为记忆引擎，后续由 Memory Gateway 向 ChatGPT、Qwen、WorkBuddy、Claude、Hermes、Codex 等不同客户端提供统一入口。

> 本仓库是公开部署代码。真实个人记忆、OAuth 凭据、API Key、代理节点信息和备份数据均不进入 Git。

## 最终目标

```text
ChatGPT / Qwen / WorkBuddy / Claude / Hermes / Codex / future AI
                              ↓
                       Memory Gateway
                              ↓
                         Hindsight
                              ↓
                Raw Store / PostgreSQL / object storage
```

Memory Gateway 是稳定边界；Hindsight 是当前记忆引擎。客户端不直接绑定 Hindsight。

## 代码仓与镜像规则

**GitHub 是唯一可写主仓 / Source of Truth；Gitee 是只读的中国大陆部署镜像。**

代码修改、版本演进和提交只发生在 GitHub。Gitee 仓库只从 GitHub 单向同步，不在 Gitee 单独修改代码，避免双仓分叉。

### memory-server-infra

GitHub 主仓：

https://github.com/skyhigh13gdhz-png/memory-server-infra

Gitee 大陆镜像：

https://gitee.com/skyhigh13/memory-server-infra

### ubuntu-vps-proxy-kit

GitHub 主仓：

https://github.com/skyhigh13gdhz-png/ubuntu-vps-proxy-kit/tree/mainland_vps_use_proxy

Gitee 大陆镜像：

https://gitee.com/skyhigh13/ubuntu-vps-proxy-kit/tree/mainland_vps_use_proxy

约定：

```text
开发 / Codex / ChatGPT 修改
            ↓
       GitHub 主仓
            ↓
        单向同步
            ↓
       Gitee 镜像
            ↓
     中国大陆 VPS
```

中国大陆 VPS 可以优先从 Gitee 获取安装代码；海外 VPS 可以直接使用 GitHub。新的 `bootstrap.sh` 会检测 GitHub/Gitee 可达性并选择可用代码源。

> Gitee 解决的是“安装代码从哪里下载”，不能代替运行时海外网络。GHCR、OpenAI、Codex 等仍可能需要 Xray 或其他合适的海外网络方案。

## 当前已经做到什么

目前已经证明：普通 Ubuntu 服务器可以稳定运行 Hindsight，而且服务器重启、重复安装和数据库恢复之后，记忆服务仍能恢复正常。

已经实现：Ubuntu/Swap 初始化、Docker、Xray 出站、Hindsight 部署与持久化、Codex OAuth、专属透明代理、本机端口隔离、Retain/Recall/Reflect 验收、备份恢复和灾备时间点回滚。

## 快速开始

> 当前建议先在测试环境使用。完整 GPT → Memory Gateway → Memory Server 链路完成后，再进行正式新服务器全新部署验收。

### 中国大陆 VPS：Gitee 入口

如果服务器访问 GitHub 不稳定，推荐从 Gitee 获取第一份 bootstrap：

```bash
curl -fsSL https://gitee.com/skyhigh13/memory-server-infra/raw/main/bootstrap.sh | sudo bash
```

### 海外 VPS：GitHub 入口

```bash
curl -fsSL https://raw.githubusercontent.com/skyhigh13gdhz-png/memory-server-infra/main/bootstrap.sh | sudo bash
```

两个入口运行的是同一套安装逻辑。bootstrap 启动后会：

```text
检查基础工具
    ↓
检测 GitHub / Gitee
    ↓
选择可用代码源
    ↓
检查现有 Xray 海外网络
    ↓
没有 Xray时询问用户是否需要配置
    ↓
如选择配置，从 Gitee 获取 ubuntu-vps-proxy-kit 安装器
    ↓
获取 memory-server-infra
    ↓
进入正式 setup
```

如果已经 clone 仓库：

```bash
cd /opt/src/memory-server-infra
git pull --ff-only
sudo bash setup.sh
```

源码默认位于 `/opt/src/memory-server-infra`，运行数据位于 `/opt/memory-server-infra`，两者分离。

## 安装后的检查

普通健康检查：

```bash
sudo bash scripts/health-check.sh
```

需要排障时：

```bash
sudo bash scripts/health-check.sh --verbose
```

真实记忆功能验收：

```bash
sudo bash scripts/07-hindsight-smoke-test.sh
```

灾难恢复闭环测试：

```bash
sudo bash scripts/08-backup-restore-test.sh
```

灾备测试真实执行：写入备份前数据 → 创建恢复点 → 写入备份后数据 → 恢复 → 验证备份前数据存在 → 验证备份后数据已回滚。

## 给非技术用户看的输出原则

主要入口默认优先回答：现在在做什么、成功还是失败、失败后下一步做什么。Docker volume、iptables、UID、systemd、HTTP 状态码等技术信息保留给 `--verbose` 或排障场景。

统一状态：

```text
[✓] 正常 / 已完成
[!] 可以继续，但有需要注意的事项
[✗] 失败，需要处理
[→] 当前正在执行
```

## 备份是什么

`05-backup.sh` 保存的是 Hindsight 底层数据卷快照，用于灾难恢复，不是给人阅读的记忆导出文件。

默认目录：`/opt/memory-server/backups/`。

每个恢复点包含 `.tar.gz` 数据和 `.sha256` 完整性校验。长期会把灾备快照和可读/可迁移 Raw Store 分开；Raw Store 才是长期个人数据的 source of truth。

## 网络与安全设计

Hindsight 使用 Docker host network 访问宿主机 loopback Xray。主机防火墙阻断非 loopback 对 8888/9999 的访问，并通过 systemd 在重启后恢复。

Hindsight 需要海外网络的 TCP 出站由专属透明代理进入 Xray；国内/海外最终分流继续由 Xray routing 决定。当前按 Hindsight 运行 UID 匹配，未来可升级为 cgroup/network namespace 隔离。

### 安装网络和运行网络是两件事

```text
安装代码：GitHub / Gitee
容器镜像：Docker Registry / GHCR
国内 AI：DIRECT
OpenAI / Codex 等：按需要经 Xray
```

因此即使从 Gitee 成功安装代码，也仍需验证容器镜像和实际 AI Provider 的网络。

## Codex OAuth 凭据

Hindsight 使用 `openai-codex` Provider 时无需把 OpenAI API Key 写入 `.env`。部署脚本在服务器本地准备独立、可写的 Codex 凭据目录，使 OAuth token 刷新状态可以持久化。

默认路径：`/var/lib/hindsight/codex/auth.json`。该文件永远不进入 Git。

## Public 仓库安全边界

允许提交：脚本、Compose 模板、`.env.example`、文档、无敏感信息测试逻辑。

禁止提交：真实 `.env`、`auth.json`、API Key、OAuth token、代理凭据、SSH 私钥、真实记忆数据、数据库 dump 和备份文件。

仓库公开前已经使用 Gitleaks 扫描当时完整 Git 历史：46 commits、约 111.75 KB，结果 `no leaks found`。

## 已验证状态

测试环境：Ubuntu 24.04 / amd64 / 约 2GB RAM + Swap / Docker 29.8.0 / Compose v5.5.1。

已真实验证通过：Docker 安装与 Xray 出站、Hindsight 启动和隔离、ChatGPT/Codex Device OAuth、GPT-5.6 Luna、透明代理、Retain → Recall → Reflect、container restart、整机 reboot、reboot 后功能恢复、setup 幂等、备份 SHA256，以及 backup → mutate → restore → point-in-time rollback 完整闭环。

仍需长期观察：Codex OAuth 实际 token 刷新周期、长期真实记忆负载 RAM/Swap、embedding/reranking 峰值、数据增长后的备份体积和恢复耗时。

> 新增的 GitHub/Gitee 双源 bootstrap 和安装前海外网络引导尚需在测试服务器/干净服务器上完成真实回归后，才能标记为“已验证”。

## 下一阶段路线

```text
1. 完成 setup / health-check / backup / restore 等“小白模式”输出
2. 回归 GitHub/Gitee 双源 bootstrap + 可选 Xray 安装
3. 建立 Memory Gateway 最小可用版本
4. Gateway 实现统一 retain / recall / reflect
5. 加入客户端身份、认证和 bank 策略
6. 打通 ChatGPT → Gateway → Hindsight
7. 在旧测试服务器完成端到端测试
8. 再到新的干净服务器执行从零正式部署验收
9. 逐步接入 Qwen / WorkBuddy / Claude / Hermes / Codex
```

新服务器承担的是成熟链路的正式环境迁移与从零验收，而不是继续承担架构探索。
