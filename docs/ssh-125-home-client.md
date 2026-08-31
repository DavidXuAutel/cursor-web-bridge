# 公网访问 125 上的 Cursor Agent

## 已启用

- SSH 公网入口：`ssh-125.david-x.com`（Cloudflare Access + SSH）
- HTTP Bridge：`https://cursor.david-x.com`
- 125 上 Cursor CLI：已登录 `xudazhong@autel.com`
- 推荐模型：`composer-2.5-fast`（避免 Auto Balance 触发 limit）

## 一键启动（家里 / 公网）

```bash
cd /Users/xudazhong/Projects/cursor-web-bridge
./scripts/start-agent-125.sh
```

## 手动 SSH

```
Host cursor-125-public
  HostName ssh-125.david-x.com
  User yao
  IdentityFile ~/.ssh/cursor_webbridge_125
  IdentitiesOnly yes
  ProxyCommand /Users/xudazhong/Projects/cursor-web-bridge/bin/cloudflared access ssh --hostname %h
```

```bash
ssh cursor-125-public
cd ~/Projects/cursor-web-bridge
export PATH="$HOME/.local/bin:$PATH"
agent --trust --model composer-2.5-fast
```

Access 允许邮箱：
- `xudazhong@autel.com`
- `13238077823@163.com`

## 公司局域网

在公司内仍可用 `ssh cursor-125`；Cursor Desktop 优先用 **当前 Mac**。

## 恢复 / 维护公网 SSH

```bash
./scripts/setup-ssh-125-access.sh
```
