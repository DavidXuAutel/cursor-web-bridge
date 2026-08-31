# Cursor 工作上下文迁移到 125

**日期：** 2026-07-24  
**状态：** 已批准

## 目标

在不覆盖 125 现有 Cursor Desktop 数据的前提下，把当前项目和必要工作上下文迁移到 125，并通过运行在 125 上的 Cursor CLI 继续工作，使 Cursor 请求从 125 的网络发出。

## 迁移范围

- 同步当前 `cursor-web-bridge` 工作区，包括未提交文件和修改。
- 在仓库中写入不含凭据的工作交接文档。
- 保留项目级 `.cursor` 配置；如后续出现用户级配置需求，再逐项迁移。
- 在 125 安装或验证官方 Cursor CLI，并由用户完成登录。

## 不迁移

- 不复制 macOS 的 `~/Library/Application Support/Cursor`。
- 不覆盖 125 的 `~/.config/Cursor` 或 `~/.cursor`。
- 不复制 Access token、Cursor token、SSH 私钥、`.env` 或 Cloudflare 凭据。
- 不保证当前 Desktop 聊天可由 CLI 直接恢复；以交接文档作为稳定上下文。

## 数据流

1. 本机仓库作为迁移源。
2. 同步前检查 125 目标目录并创建时间戳备份。
3. 使用排除规则同步工作树到 `/home/yao/Projects/cursor-web-bridge`。
4. 125 上的 CLI 从该目录启动并读取交接文档。

## 成功标准

1. 125 上可读取与本机一致的项目文件和交接文档。
2. 125 原有 Cursor Desktop 配置目录未被覆盖。
3. `agent` 在 125 可执行，并能完成认证或明确停在用户登录步骤。
4. CLI 能在迁移后的仓库目录中识别项目与交接文档。
