---
name: claude-guard
description: Claude Code 启动门禁与运行看门狗。出口 IP 白名单、api.anthropic.com 的 TLS/CONNECT、IPv6 不可达、路由/凭据/证书改写始终 fail-closed；hooks、插件和后台能力默认只警告，CLAUDE_GUARD_STRICT_LIFECYCLE=1 才在网络检查后拒绝。doctor 可只读查询 mihomo 并报告 Claude.app。看门狗默认不结束已有会话。当用户需要在保留后台会话的同时锁住出口时使用。
---

# claude-guard — 启动门禁 + 运行看门狗 🚦

## 这是什么

你以为你在跟官方 Claude 说话，其实 settings 里躺着上次调试留下的 `ANTHROPIC_BASE_URL`；
你以为出口 IP 一直没变，其实跑到一半线路悄悄漂了。
**claude-guard 在你发出第一个请求之前就拦住，跑起来之后继续盯着。**

**什么时候用我：**

- 手里同时有官方通道和第三方兼容链路，怕配置串台
- 长任务跑到一半线路漂移，想有据可查
- 不想让 CLI 自动更新在你不知情时换掉客户端内核

## 两道防线

**① 启动门禁（fail-closed，不过就不让启动）**

```text
claude ──▶ [ 门禁 15 项预检 ] ──▶ 通过 ──▶ 真正的 Claude Code
                  │
                  └─ 任一不过 ──▶ 拒绝启动，打印哪一项、为什么
```

检查什么：

| 类别 | 具体项 |
| --- | --- |
| 配置残留 | 官方 settings 是否含 `ANTHROPIC_BASE_URL`、`apiKeyHelper`、`PROXY_MANAGED` 等反代/托管痕迹 |
| 生命周期 | 默认只警告 hooks、插件、后台会话、cron、workflows、Remote Control。`CLAUDE_GUARD_STRICT_LIFECYCLE=1` 时这些缺口在网络检查后拒绝启动。路由、凭据、证书改写始终拒绝 |
| 越权覆盖 | 项目 `.claude/settings.json` 是否试图改写官方路由/凭据/证书/重试；命令行是否用 `--settings`、`--bg`、`remote-control` 绕过守门 |
| 客户端身份 | 版本号、SHA-256、macOS Team ID 与固定指针是否一致；watermark-capable 客户端的激活条件 |
| 网络 | 出口 IPv4 是否在白名单；`api.anthropic.com` 的 HTTP CONNECT 与 TLS issuer；IPv6 是否意外可直连 |
| 插件 | `blocked_plugins` 里已知会 detach 进程的插件是否被启用 |

**② 运行看门狗（dry-run 观测，常驻不打扰）**

```text
Claude 跑着 ──▶ watchdog sidecar（每 5s tick）
                  ├─ 每 60s  查出口 IPv4 是否仍在白名单
                  ├─ 每 180s 查 api.anthropic.com CONNECT/TLS
                  ├─ 连续失败达阈值 ──▶ 记录 "would pause"，进入逻辑降级
                  ├─ 降级后每 30s 成对复检（IP + API 同轮都健康才计数）
                  │   连续两轮通过 ──▶ 记录 "would resume"
                  └─ 检测长时间 sleep/wake gap
```

日志写 `~/.claude-guard/guard.log`（超 1MB 自动轮转），每条带目标 Claude PID，
多会话可归因；「IP 查不到」和「查到了但不在白名单」分开记，不混成 unknown。

> **诚实边界**：看门狗默认是观察模式。它记录「本来会 pause/resume」，并写明已有会话继续运行、新的启动由下一次出口预检拦住。**默认不会暂停或杀掉正在跑的 Claude。** `CLAUDE_GUARD_WATCHDOG_STRICT=1` 才向那棵进程树发 `TERM` 或 `STOP`。它不调模型、不用账号 token、不消耗额度，也不读取凭据或 Keychain。

`doctor` 还可以只读查询 mihomo 控制器（unix socket 或 HTTP `GET`），报告 Anthropic 域名落到哪个组、组里有没有 `DIRECT`、`tun.strict-route` 是否打开，并打印一段**不会写入**的 Clash 片段。同一节报告 Claude.app 和捆绑 claude-code 是否在跑、连接是否经过混合端口。不改 Clash 配置，不改登录项。

## 附带能力：双通道版本治理

官方通道锁定验包过的固定版本（fail-closed 严格）；`claude-cc` 走独立 profile
跟进新版工程能力，保留 background agent / plugin / hook。两条通道互不读取对方的
base URL、token 和 profile，都关闭客户端自动更新——换版本必须先过
「版本验证 → SHA-256 → macOS 签章 → 回归测试」才改固定指针。

保留历史基线的意义：新版出现 TUI / TLS / session resume / 插件回归时，
一份可复现的旧版能一刀切开「客户端变了」还是「网络变了」——排障时最值钱的对照组。

## 三步上手

1. `scripts/install.sh` 装入口，写好 `allowed_ips` / `allowed_cidrs` 白名单和原始 claude 绝对路径
2. 以后照常敲 `claude`，门禁自动前置；`scripts/check.sh` 可单独跑一遍体检
3. 想看运行期发生过什么：`tail -f ~/.claude-guard/guard.log`

## 不做什么（明牌）

不清洗服务端标记、客户端归因或设备指纹；不规避封禁或任何平台保护措施；
不自动重启 Claude；不修改 Clash/Mihomo 配置或订阅；不改登录项；不读取或打印 Claude token，也不读 Keychain。
非 Anthropic 官方项目。

## 项目

MIT · https://github.com/dario-github/claude-guard（自 wetlink/claude-guard 2.1.3 分出）
