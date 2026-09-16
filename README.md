# memory-server-infra

一套面向个人 AI 外置记忆系统的 Ubuntu 服务器基础设施。

目标不是把记忆绑定到某个 AI 客户端，而是在服务器上建立独立、可迁移的记忆基础层：当前以 Hindsight 为记忆引擎，后续由 Memory Gateway 向 ChatGPT、Qwen、WorkBuddy、Claude、Hermes、Codex 等不同客户端提供统一入口。

> 本仓库是公开的部署代码仓库。真实个人记忆、OAuth 凭据、API Key、代理节点信息和备份数据均不进入 Git。

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

Memory Gateway 是稳定边界；Hindsight 是当前记忆引擎。客户端不直接绑定 Hindsight，因此以后可以替换或组合其他记忆引擎，而不需要重做所有客户端。

当前 `memory-server-infra` 主要负责图中 Hindsight 及其服务器基础设施。Memory Gateway 与客户端接入属于下一阶段。

## 当前已经做到什么

用非技术语言概括：目前已经证明“一台普通 Ubuntu 服务器可以稳定运行 Hindsight，而且服务器重启、重复安装和数据库恢复之后，记忆服务仍能恢复正常”。

已经实现：

- Ubuntu 环境检查和低内存机器 Swap 自动配置
- Docker Engine / Docker Compose 自动安装
- Docker 经本机 Xray 拉取境外镜像
- Hindsight 自动部署和数据持久化
- ChatGPT / Codex OAuth 登录及独立可刷新凭据目录
- Hindsight 专属透明代理
- Hindsight API/UI 默认不向公网开放
- 网络规则重启后自动恢复
- Retain / Recall / Reflect 真实功能测试
- Hindsight 数据备份、完整性校验和恢复
- 灾备时间点回滚自动验收
- Public GitHub 引导安装

## 快速开始

> 当前建议先在测试环境使用。完整的 GPT → Memory Gateway → Memory Server 链路完成后，再进行正式新服务器的全新部署验收。

### Public 仓库引导安装

在已经配置并运行 Xray 的 Ubuntu 服务器上：

```bash
curl -fsSL https://raw.githubusercontent.com/skyhigh13gdhz-png/memory-server-infra/main/bootstrap.sh | sudo bash
```

它会自动拉取本仓库到：

```text
/opt/src/memory-server-infra
```

然后执行正式安装流程。不需要 GitHub Deploy Key、SSH alias 或私人仓库访问凭据。

### 已经 clone 仓库

```bash
cd /opt/src/memory-server-infra
git pull --ff-only
sudo bash setup.sh
```

当前部署流程共 8 个阶段：

```text
服务器检查
  ↓
内存 / Swap
  ↓
Docker
  ↓
Docker 网络
  ↓
Hindsight 本机安全隔离
  ↓
Hindsight 部署
  ↓
Hindsight 专属透明代理
  ↓
整体健康检查
```

安装完成后可以运行真实记忆功能测试：

```bash
sudo bash scripts/07-hindsight-smoke-test.sh
```

灾难恢复闭环测试：

```bash
sudo bash scripts/08-backup-restore-test.sh
```

该测试会真实执行：写入备份前数据 → 创建恢复点 → 写入备份后数据 → 恢复 → 验证备份前数据仍存在 → 验证备份后数据已回滚。

## 给非技术用户看的输出原则

这个仓库不仅要“脚本能跑”，还要让没有 Linux / Docker 背景的人知道当前发生了什么。

后续所有主要入口脚本统一采用两层输出：

```text
========== Hindsight 网络检查 ==========
[✓] 记忆服务访问海外 AI 的网络：正常
[✓] Hindsight 本机安全隔离：正常
[✓] 重启后自动恢复：已启用

当前状态：正常，可以继续使用记忆服务。
```

默认输出优先回答三个问题：

1. **现在在做什么？**
2. **成功还是失败？**
3. **失败后用户下一步应该做什么？**

Docker volume、iptables chain、UID、systemd unit、HTTP 状态码等技术信息不删除，但默认降级为辅助信息；需要排障时再通过详细模式查看。

统一状态符号：

```text
[✓] 正常 / 已完成
[!] 可以继续，但有需要注意的事项
[✗] 失败，需要处理
[→] 当前正在执行
```

## 源码、运行数据和个人记忆分离

推荐目录：

```text
/opt/
├── src/
│   └── memory-server-infra/      # Git 源码，可重新下载
└── memory-server-infra/          # 部署后的运行配置
    └── hindsight/
```

Hindsight 的 Docker volume、OAuth 凭据和备份独立保存。删除 Git 源码不应删除真实记忆数据。

长期架构还会增加 Raw Store：原始记录由可读、可迁移的数据层保存；Hindsight 负责事实抽取、语义检索和 Reflection。这样未来即使替换 Hindsight，个人原始记忆仍然存在并可以重新导入。

## 备份是什么

当前 `05-backup.sh` 保存的是 Hindsight 底层数据卷快照，用途是**灾难恢复**，不是给人阅读的记忆导出文件。

备份默认位于：

```text
/opt/memory-server/backups/
```

每个恢复点包含：

```text
hindsight-YYYYMMDD-HHMMSS.tar.gz
hindsight-YYYYMMDD-HHMMSS.tar.gz.sha256
```

`.tar.gz` 是完整恢复数据，`.sha256` 用于检查备份有没有损坏。

后续会把“灾难恢复备份”和“人可以阅读/迁移的记忆导出”分成两套能力；Raw Store 才是长期个人数据的 source of truth。

## 网络与安全设计

Hindsight 当前使用 Docker host network，以便访问宿主机 loopback 上的 Xray。Hindsight 自身可能显示监听 `0.0.0.0:8888` / `0.0.0.0:9999`，因此由主机防火墙阻断所有非 loopback IPv4/IPv6 访问，并通过 systemd 在重启后恢复。

Codex Provider 的 HTTP 客户端不能依赖普通 shell 代理环境，因此 Hindsight 的相关 TCP 出站由专属透明代理送入本机 Xray；国内/海外的最终分流继续由 Xray routing 决定。

当前透明代理按 Hindsight 运行 UID 匹配。如果宿主机普通用户恰好使用同一 UID，其主动发起的 TCP 也可能命中规则。它不影响入站 SSH；未来可以升级到 cgroup/network namespace 级隔离。

## Codex OAuth 凭据

Hindsight 使用 `openai-codex` Provider 时无需把 OpenAI API Key 写入 `.env`。部署脚本会检测容器实际 UID/GID，在服务器本地准备独立 Codex 目录，并以可写方式挂载，使 Hindsight 能持久化 OAuth token 刷新状态。

默认路径：

```text
/var/lib/hindsight/codex/auth.json
```

该文件永远不进入 Git。

## Public 仓库安全边界

允许提交：脚本、Compose 模板、`.env.example`、文档、无敏感信息的测试逻辑。

禁止提交：真实 `.env`、`auth.json`、API Key、OAuth token、代理凭据、SSH 私钥、真实记忆数据、数据库 dump 和备份文件。

仓库公开前已经使用 Gitleaks 扫描当时完整 Git 历史：46 commits、约 111.75 KB，结果 `no leaks found`。

## 已验证状态

测试环境：Ubuntu 24.04 / amd64 / 约 2GB RAM + Swap / Docker 29.8.0 / Compose v5.5.1。

### 已真实验证通过

- Docker 自动安装、镜像拉取和 Xray 出站
- Hindsight 启动与本机端口隔离
- ChatGPT / Codex Device OAuth
- GPT-5.6 Luna
- Hindsight 专属透明代理
- Retain → Recall → Reflect
- Docker container restart 后功能恢复
- 整机 reboot 后 Xray、Docker、透明代理和 Hindsight 自动恢复
- reboot 后 Retain / Recall / Reflect 功能链路恢复
- 完整 `setup.sh` 重复执行，最终健康检查无 WARN / FAIL
- 备份文件和 SHA256 生成
- backup → 写入新数据 → restore → 数据时间点回滚完整闭环
- Public 前完整 Git 历史 Gitleaks 扫描无泄漏

灾备闭环中已经真实验证：备份前数据恢复后仍存在，备份后才写入的数据恢复后消失。因此当前备份不是仅验证“压缩包能生成”，而是已经完成实际 point-in-time rollback 验收。

### 仍需长期观察

- Codex OAuth token 经实际过期/刷新周期后的长期稳定性
- 长时间真实记忆负载下的 RAM / Swap 使用
- embedding / reranking 峰值资源
- 长期数据增长后的备份体积和恢复耗时

低配置测试机跑通不代表约 2GB RAM 适合长期生产负载。

## 下一阶段路线

当前服务器基础记忆层已经完成第一轮可靠性验收。下一阶段优先级不是立刻迁移正式服务器，而是先把完整产品链路打通：

```text
ChatGPT
   ↓
Memory Gateway
   ↓
Hindsight / Memory Server
```

具体顺序：

```text
1. 优化 setup / health-check / backup / restore 等脚本的“小白模式”输出
2. 建立 Memory Gateway 最小可用版本
3. Gateway 实现统一 retain / recall / reflect
4. 加入客户端身份、认证和 bank 策略
5. 先接通 ChatGPT → Gateway → Hindsight
6. 在旧测试服务器完成真实端到端记忆测试
7. 再用 Public bootstrap 在新的干净服务器进行从零部署验收
8. 最后逐步接入 Qwen / WorkBuddy / Claude / Hermes / Codex 等其他客户端
```

这样新服务器承担的是已经打通后的“正式环境迁移 + 全新机器验收”，而不是继续承担架构探索和脚本调试。
