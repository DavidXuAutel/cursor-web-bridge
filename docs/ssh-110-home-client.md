# 公网访问 10.229.20.110（a26125）

## 架构（与 125 相同）

```
Mac → cloudflared Access SSH → ssh-110.david-x.com
    → Cloudflare Tunnel (on 125)
    → 10.229.20.110:22 (a26125)
```

- Tunnel: `cursor-web-bridge`（跑在 125）
- 公网主机名: `ssh-110.david-x.com`
- 用户: `a26125`（小写）

## 本机用法

```bash
# 直连公网（需 Access 应用已创建）
ssh a26125-110-public

# 临时备用：经 125 跳转（Access 未建时可用）
ssh a26125-110-via-125

# 公司局域网
ssh a26125-110
```

## Access 应用（须在 Zero Trust 建一次）

API token 无 Access 写权限，需在控制台创建：

1. https://one.dash.cloudflare.com/ → **Access** → **Applications** → **Add** → **Self-hosted**
2. Application name: `ssh-110`
3. Public hostname: `ssh-110.david-x.com`
4. Session duration: `24 hours`
5. Policy **Allow**，邮箱：
   - `xudazhong@autel.com`
   - `13238077823@163.com`

建好后：

```bash
~/Projects/cursor-web-bridge/bin/cloudflared access login ssh-110.david-x.com
ssh a26125-110-public
```

## 维护

```bash
cd ~/Projects/cursor-web-bridge
./scripts/setup-ssh-110-access.sh
```

## 记录

| 项 | 值 |
|----|-----|
| IP | 10.229.20.110 |
| Hostname | a25689-B760-DS3H |
| User | a26125 |
| Password | Autel123（备用；Mac 公钥已写入 authorized_keys） |
| Alias | a26125-110-public / a26125-110 / a26125-110-via-125 |
