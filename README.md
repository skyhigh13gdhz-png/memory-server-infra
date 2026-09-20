# memory-server-infra

**Hindsight 记忆服务器的部署与运维仓库。**

这个仓库不是整套个人 AI 外置记忆系统，也不负责 ChatGPT、Qwen、Claude 等客户端接入；它只负责把整套架构中的 **Memory Server / Hindsight 基础设施层** 在 Ubuntu VPS 上安装好、保护好、备份好，并保证重启和恢复后仍可工作。

```text
完整系统（本仓库只负责 [ ] 内的部分）

ChatGPT / Qwen / WorkBuddy / Claude / Hermes / Codex / future AI
                              ↓
                       Memory Gateway          ← 其他仓库/下一阶段
                              ↓
        ┌─────────────────────────────────────┐
        │ [ memory-server-infra 负责的范围 ] │
        │                                     │
        │             Hindsight               │
        │                 ↓                   │
        │     Hindsight 持久化 / 备份 / 网络   │
        └─────────────────────────────────────┘
                              ↓
        Raw Store / object storage            ← 后续独立数据层
```

换句话说：**这个仓库解决“记忆服务器怎么稳定跑起来”，Memory Gateway 解决“不同 AI 怎么统一访问记忆”。**

当前仓库负责 Ubuntu 环境、Docker、Hindsight、Hindsight 数据持久化、网络出站、安全隔离、健康检查、备份/恢复和灾备验收。它不会把客户端直接绑定到 Hindsight。

> 本仓库是公开部署代码。真实个人记忆、OAuth 凭据、API Key、代理节点信息和备份数据均不进入 Git。

## 它在完整架构中的位置

```text
AI 客户端
   ↓
Memory Gateway          # 稳定的跨客户端入口
   ↓
Hindsight               # 当前语义记忆引擎，本仓库负责部署
   ↓
持久化数据

Raw Store / object storage 会作为长期原始资料层独立建设。
```

因此以后即使更换 AI 客户端，或者未来替换/组合 Hindsight，服务器部署层和 Gateway 的职责仍然可以保持清晰分离。

## 与其他仓库的关系

目前部署链路会用到另一个仓库 `ubuntu-vps-proxy-kit`，但两者职责不同：

```text
ubuntu-vps-proxy-kit
        │
        │ 给中国大陆 VPS 准备可选择性使用的海外网络能力
        │ 例如 GitHub / GHCR / OpenAI / Codex
        ↓
memory-server-infra
        │
        │ Docker + Hindsight + 安全隔离 + 备份恢复
        ↓
Hindsight Memory Server
```

### memory-server-infra（当前仓库）

用途：**部署和维护 Hindsight 记忆服务器。**

GitHub 主仓：

https://github.com/skyhigh13gdhz-png/memory-server-infra

Gitee 中国大陆镜像：

https://gitee.com/skyhigh13/memory-server-infra

### ubuntu-vps-proxy-kit（安装时可能调用的网络工具）

用途：**为中国大陆 Ubuntu VPS 安装和管理 Xray 出站能力。** `memory-server-infra` 本身不保存 VLESS 节点信息；当服务器需要访问 GitHub/GHCR/OpenAI/Codex 等海外资源、又没有现成网络方案时，bootstrap 可以调用这个工具。国内/海外流量的具体分流由 Xray routing 处理。

它是安装辅助依赖，不是 Memory Server 的记忆组件；如果服务器已经有可用的网络方案，就不需要重新安装它。

GitHub 主仓（`mainland_vps_use_proxy` 分支）：

https://github.com/skyhigh13gdhz-png/ubuntu-vps-proxy-kit/tree/mainland_vps_use_proxy

Gitee 中国大陆镜像：

https://gitee.com/skyhigh13/ubuntu-vps-proxy-kit/tree/mainland_vps_use_proxy

## GitHub / Gitee 镜像规则

**GitHub 是唯一可写主仓 / Source of Truth；Gitee 只作为中国大陆部署镜像。**

所有代码修改、版本演进和 commit 只发生在 GitHub。Gitee 只从 GitHub 单向同步，不在 Gitee 单独修改，避免两个仓库产生不同历史。

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

中国大陆 VPS 优先考虑 Gitee；海外 VPS 通常直接使用 GitHub。`bootstrap.sh` 会检测两者可达性并选择可用代码源。

> Gitee 解决的是“安装代码从哪里下载”，不能代替运行时海外网络。GHCR、OpenAI、Codex 等仍可能需要 Xray 或其他海外网络方案。

## 当前已经做到什么

目前已经证明：普通 Ubuntu 服务器可以稳定运行 Hindsight，而且服务器重启、重复安装和数据库恢复之后，记忆服务仍能恢复正常。

当前仓库已经覆盖：Ubuntu/Swap 初始化、Docker、Docker 出站、Hindsight 部署与持久化、Codex OAuth 本地凭据、Hindsight 专属透明代理、本机端口隔离、Retain/Recall/Reflect 验收、备份恢复和灾备时间点回滚。

### Retain 使用智谱、Reflect 保留 Codex

Hindsight 支持按操作选择 LLM。当前推荐先只把高频事实抽取切到智谱，Embedding 保持本地，复杂 Reflect 继续使用 Codex：

```bash
cd /opt/src/memory-server-infra
sudo bash scripts/09-configure-llm-routing.sh zai-retain glm-4.5-air
```

查看所有操作当前实际使用的 Provider、模型、继承关系和 Key 是否已配置（不会显示 Key）：

```bash
sudo bash scripts/09-configure-llm-routing.sh status
```

按操作调整路由：

```bash
# 可选操作：retain / reflect / consolidation / mental-model-refresh
sudo bash scripts/09-configure-llm-routing.sh zai-operation reflect glm-4.5-air

# 删除该操作的独立配置，恢复继承全局 Provider
sudo bash scripts/09-configure-llm-routing.sh inherit-operation reflect
```

同一台服务器上已存在可用的智谱操作配置时，新操作会在 root-only 配置文件内部复用该 Key，不回显、不进入命令历史；没有可复用 Key 时才隐藏提示输入。`Recall` 本身不调用 LLM，Embedding 保持本地配置。每次切换会重建 Hindsight，并自动重绑基于容器 cgroup 的专属透明代理，随后执行 Retain/Recall/Reflect 验收。

脚本会隐藏输入 API Key、写入服务器本地 `0600` 配置、重建 Hindsight 并执行 Retain/Recall/Reflect 验收。首轮 A/B 不启用自动 failover，避免智谱失败后静默切到 Codex 而污染质量结论。查看当前路由或一键回滚：

默认 endpoint 是中国智谱开放平台 `https://open.bigmodel.cn/api/paas/v4`，对应 BigModel 控制台生成的 API Key。若使用国际 z.ai Coding Plan，可显式设置 `ZAI_RETAIN_BASE_URL=https://api.z.ai/api/coding/paas/v4` 后执行。

```bash
sudo bash scripts/09-configure-llm-routing.sh status
sudo bash scripts/09-configure-llm-routing.sh codex-retain
```

## 统一入口：bootstrap.sh

**普通用户只需要记住 `bootstrap.sh`。安装、更新、修复、重复部署都从它进入。**

`setup.sh` 是 bootstrap 内部调用的部署执行器，不是面向普通用户的独立入口。除开发调试外，不需要直接运行 `setup.sh`。

```text
用户
 ↓
bootstrap.sh            ← 唯一推荐入口
 │
 ├─ 检查基础工具与代码下载网络
 ├─ 选择 GitHub / Gitee 代码源
 ├─ 检查 Xray 海外网络
 ├─ 必要时调用 ubuntu-vps-proxy-kit
 ├─ 获取或更新 memory-server-infra
 ↓
setup.sh                ← bootstrap 自动调用
 │
 ├─ 系统 / Swap
 ├─ Docker
 ├─ Docker → Xray
 ├─ Hindsight
 ├─ 安全隔离
 ├─ Hindsight 专属透明代理
 └─ health-check
```

## 快速开始

> 当前建议先在测试环境使用。完整 GPT → Memory Gateway → Memory Server 链路完成后，再进行正式新服务器全新部署验收。

### 中国大陆 VPS：Gitee 入口

```bash
curl -fsSL https://gitee.com/skyhigh13/memory-server-infra/raw/main/bootstrap.sh | sudo bash
```

### 海外 VPS：GitHub 入口

```bash
curl -fsSL https://raw.githubusercontent.com/skyhigh13gdhz-png/memory-server-infra/main/bootstrap.sh | sudo bash
```

两个入口运行同一套 bootstrap 安装逻辑。

部署脚本中的 `systemctl` 状态输出已显式禁用分页器，因此通过 SSH 终端或 `curl | sudo bash` 运行时不会停在 `less` 等待界面。

### 已经 clone 过仓库

仍然运行统一入口，不需要手工 `git pull`，也不要改成直接执行 `setup.sh`：

```bash
cd /opt/src/memory-server-infra
sudo bash bootstrap.sh
```

bootstrap 会负责检查网络并获取/更新 `/opt/src/memory-server-infra` 中的部署代码，然后自动调用内部 `setup.sh`。

源码默认位于 `/opt/src/memory-server-infra`，运行数据位于 `/opt/memory-server-infra`，两者分离。

## 安装后的检查

```bash
sudo bash scripts/health-check.sh
sudo bash scripts/health-check.sh --verbose
sudo bash scripts/07-hindsight-smoke-test.sh
sudo bash scripts/08-backup-restore-test.sh
```

其中灾备测试真实执行：写入备份前数据 → 创建恢复点 → 写入备份后数据 → 恢复 → 验证备份前数据存在 → 验证备份后数据已回滚。

## 给非技术用户看的输出原则

主要入口默认优先回答：现在在做什么、成功还是失败、失败后下一步做什么。Docker volume、iptables、cgroup、systemd、HTTP 状态码等技术信息保留给 `--verbose` 或排障场景。

统一状态：

```text
[✓] 正常 / 已完成
[!] 可以继续，但有需要注意的事项
[✗] 失败，需要处理
[→] 当前正在执行
```

## 备份是什么

`05-backup.sh` 保存的是 Hindsight 底层数据卷快照，用于灾难恢复，不是给人阅读的记忆导出文件。

默认目录：`/opt/memory-server/backups/`。每个恢复点包含 `.tar.gz` 数据和 `.sha256` 完整性校验。

长期会把灾备快照和可读/可迁移 Raw Store 分开。Raw Store 属于完整记忆系统的数据层，不应与本仓库当前的 Hindsight 灾备快照混为一谈。

## 网络与安全设计

Hindsight 使用 Docker host network 访问宿主机 loopback Xray。主机防火墙阻断非 loopback 对 8888/9999 的访问，并通过 systemd 在重启后恢复。

Hindsight 需要海外网络的 TCP 出站由专属透明代理进入 Xray；国内/海外最终分流继续由 Xray routing 决定。

透明代理**按 Hindsight 容器的 cgroup v2 路径匹配，而不是按 Linux UID 匹配**。这是一个重要安全边界：Hindsight 容器内部用户可能恰好与宿主机 `ubuntu` 用户使用相同 UID，如果按 UID 拦截，会把普通 SSH shell 发出的 TCP 也错误送入 Xray。cgroup 匹配只接管 Hindsight 容器自身创建的 socket。

安装脚本还会主动删除历史版本遗留的 `--uid-owner` jump 和重复的 `HINDSIGHT_XRAY` OUTPUT jump，再生成唯一的 cgroup 规则。服务器重启时会重新读取当前 Hindsight 容器 PID/cgroup，而不是依赖上一次启动的 Docker container ID。

### 安装网络和运行网络是两件事

```text
安装代码：GitHub / Gitee
容器镜像：Docker Registry / GHCR
国内 AI：DIRECT
OpenAI / Codex 等：按需要经 Xray
```

因此即使从 Gitee 成功获取本仓库，也仍需验证容器镜像和实际 AI Provider 网络。

## Codex CLI 与 OAuth 凭据

Hindsight 使用 `openai-codex` Provider 时无需把 OpenAI API Key 写入 `.env`。部署脚本在服务器本地准备独立、可写的 Codex 凭据目录，使 OAuth token 刷新状态可以持久化。

如果服务器还没有 Codex CLI，部署脚本会使用 OpenAI 官方独立安装器安装到 `/usr/local/bin`；安装器及其后续 release 下载在直连不可用时会继承本机 Xray。该路径不依赖服务器预装 Node.js/npm。

默认路径：`/var/lib/hindsight/codex/auth.json`。该文件永远不进入 Git。

## Public 仓库安全边界

允许提交：脚本、Compose 模板、`.env.example`、文档、无敏感信息测试逻辑。

禁止提交：真实 `.env`、`auth.json`、API Key、OAuth token、代理凭据、SSH 私钥、真实记忆数据、数据库 dump 和备份文件。

仓库公开前已经使用 Gitleaks 扫描当时完整 Git 历史：46 commits、约 111.75 KB，结果 `no leaks found`。

## 已验证状态

测试环境：Ubuntu 24.04 / amd64 / 约 2GB RAM + Swap / Docker 29.8.0 / Compose v5.5.1。

已真实验证通过：Docker 安装与 Xray 出站、Hindsight 启动和隔离、ChatGPT/Codex Device OAuth、GPT-5.6 Luna、Retain → Recall → Reflect、container restart、整机 reboot、setup 幂等、备份 SHA256，以及 backup → mutate → restore → point-in-time rollback 完整闭环。

> 旧版按 UID 匹配的透明代理曾完成上述功能验收，但发现宿主机用户 UID 与 Hindsight UID 相同时会误代理宿主机 TCP。该实现已经替换为 cgroup v2 匹配；**新版 cgroup 透明代理需要重新完成运行时、幂等和 reboot 回归后再标记为已验证。**

新增的 GitHub/Gitee 双源 bootstrap 和安装前海外网络引导也需要真实回归后再标记为已验证。

仍需长期观察：Codex OAuth 实际 token 刷新周期、长期真实记忆负载 RAM/Swap、embedding/reranking 峰值、数据增长后的备份体积和恢复耗时。

## 下一阶段路线

这里记录的是**与本仓库直接相关的后续工作**。Memory Gateway 本身会作为独立组件建设，而不是塞进 `memory-server-infra`。

```text
1. 回归 cgroup v2 Hindsight 专属透明代理：宿主机直连 / Hindsight 代理 / 幂等 / reboot
2. 回归 GitHub/Gitee 双源 bootstrap + 可选 Xray 安装
3. 完成 setup / health-check / backup / restore 的“小白模式”输出
4. 为 Memory Gateway 准备稳定的本机 Hindsight 接口边界
5. 在旧测试服务器配合 Gateway 完成端到端验收
6. 再到新的干净服务器执行从零正式部署验收
```

完整系统下一阶段则是：Memory Gateway MVP → retain/recall/reflect → 身份认证与 bank 策略 → ChatGPT 接入 → 其他 AI 客户端。
