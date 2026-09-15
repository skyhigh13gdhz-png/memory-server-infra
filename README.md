# memory-server-infra

个人 AI 外置记忆系统的服务器基础设施仓库。

这个仓库负责把一台干净的 Ubuntu 服务器自动化配置成可运行个人记忆服务的基础环境，后续将逐步包含：

- 系统初始化与 Swap 配置
- Docker / Docker Compose 安装
- Docker 出站代理配置
- Hindsight 部署与持久化
- 健康检查
- 备份与恢复
- 服务升级与卸载

## 设计原则

1. **自动化优先**：尽量通过脚本完成安装、检查、升级和卸载，避免依赖手工操作。
2. **可重复执行**：安装脚本应尽量保持幂等，多次执行不会破坏已有环境。
3. **敏感信息不进入 Git**：API Key、数据库密码、VLESS 信息、真实记忆数据等全部通过服务器本地配置注入。
4. **数据与代码分离**：仓库只保存部署代码和模板，真实数据放在服务器持久化目录或对象存储中。
5. **中文优先**：README、脚本提示和运维说明优先使用中文，代码变量和标准技术术语保留英文。

## 计划目录

```text
memory-server-infra/
├── setup.sh
├── scripts/
│   ├── 01-system-init.sh
│   ├── 02-install-docker.sh
│   ├── 03-docker-proxy.sh
│   ├── 04-hindsight.sh
│   ├── 05-backup.sh
│   └── health-check.sh
├── docker/
├── config/
├── backup/
├── uninstall.sh
└── README.md
```

## 当前状态

仓库已初始化。下一阶段从服务器基础环境开始：

1. 系统检查
2. Swap 配置
3. Docker 安装
4. Docker 对接现有 Xray 出站代理
5. Hindsight 最小化部署与验证

> 注意：本仓库不存放任何真实个人记忆数据和密钥。
