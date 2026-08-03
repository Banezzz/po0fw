# po0fw — po0 防火墙自动加白 Surge 模块

自动把设备当前出口 IP 加入 po0 防火墙白名单，加白后才能连上开启了防火墙的 po0 机器。

📖 **图文教程 / 一键安装：<https://po0fw.rlyio.com/>**

## 特性

- **多机器**：`tokens` 参数分割多个 `pgnfw_` token（逗号；Shadowrocket/QX 模块参数须用 `|`），一台机器一个。
- **无脑 POST**：每次直接上报当前出口 IP，服务端对重复 IP 幂等（不重复占坑、不推进淘汰）。白名单上限 5 个、写满按写入时间先进先出自动淘汰。
- **C 段加白**：服务端按 /24 段加白并回显（`x.x.x.0/24`），同段内换 IP 不消耗新坑位；脚本匹配兼容精确 IP 与 /24 段混杂格式。
- **自动自愈**：被 FIFO 淘汰挤出白名单的设备，由其自身 cron/事件在几分钟内自动补回；蜂窝写入的 IP 在面板上有 📶 标记。
- **即时响应**：network-changed 事件即时触发 + 每 10 分钟 cron 兜底。事件触发后先等 2 秒让接口稳定再上报，避免第一发就撞上切网。
- **抗切网**：单次请求带 12 秒硬超时，传输失败按 2s/4s 退避重试（最多 3 次），切网瞬间被隧道重建掐断的请求会自动补发。每个 token 独立成败，一个卡住不影响另一个上报。任何异常都会在面板与通知里明确报错并收尾，不会静默吊死到被客户端 timeout 杀掉。
- **面板**：显示白名单 IP 与坑位占用（不显示 token），蜂窝加白的 IP 标 📶，当前出口标 ←。
- **安静**：KV 记录状态，仅在失败、限频或消耗新坑位时通知。

## 支持的客户端

| 客户端 | 载体 | token 配置 |
|---|---|---|
| Surge | `po0-firewall-whitelist.sgmodule` | 模块参数 `tokens` |
| Egern | `egern/po0-firewall-whitelist.yaml`（原生模块） | 模块参数 `tokens` |
| Shadowrocket | `shadowrocket/po0-firewall-whitelist.srmodule` | 模块 → 编辑参数 → `tokens`（多 token 用 `\|` 分割） |
| Loon | `loon/po0-firewall-whitelist.plugin` | 插件设置 `API tokens` |
| Stash | `stash/po0-firewall-whitelist.stoverride` | 覆写内 `argument: tokens=` |
| Quantumult X | `quantumultx/po0-firewall-whitelist.snippet` | 存储 key `po0fw_tokens`（BoxJs）或脚本内 `INLINE_TOKENS` |

Surge/Loon/Stash/Shadowrocket/Quantumult X 共用 `scripts/po0-firewall-whitelist.js`，内置环境兼容层（`$httpClient`/`$task.fetch`、`$persistentStore`/`$prefs`、`$notification`/`$notify`）。不支持 `$network` 的客户端按非蜂窝处理；不支持面板的客户端仅少一个手动刷新入口。**Egern** 运行模型不同（`export default async function(ctx)`，无 `$` 全局），用独立的 `egern/po0-firewall-whitelist.js`（`ctx.http`/`ctx.storage`/`ctx.notify`/`ctx.env`/`ctx.device`），业务逻辑与共享脚本一致。

一键安装入口见教程页 <https://po0fw.rlyio.com/>。token 只保存在你自己的客户端配置里，本仓库不包含、不上传任何 token。

> **给 Shadowrocket 改模块的人注意**：不要往 `.srmodule` 里加 `type=generic` 脚本或 `[Panel]` 段。两者都是 Surge 的概念，Shadowrocket 遇到不认识的脚本类型会让**整个 `[Script]` 段失效**，cron 与 event 一起不注册。故障表现是脚本完全不被派发——PacketTunnel 日志里一行 `script` 都没有，比脚本卡死更难排查。Shadowrocket 上想手动触发，切换一次网络即可（会触发 `network-changed`）。

## Clash 系（Clash Verge Rev / FlClash）

**做不成模块**：两者共用的 mihomo 内核没有 cron / event 脚本这个扩展点（Verge Rev 的「Script」和 FlClash 的「覆写」都只是生成配置时跑一次的配置变换，没有网络与定时能力）。

改用系统调度器跑 [`clash/po0fw.sh`](./clash/po0fw.sh)（POSIX sh，只依赖 `curl`，busybox 可跑）。又因为服务端按 C 段（/24）加白，**同一出口 IP 下只需一台设备上报**，同 WAN 出口下的其它机器一行配置都不用加。

| 平台 | 脚本 | 调度 |
|---|---|---|
| Linux / 软路由 / NAS | [`clash/po0fw.sh`](./clash/po0fw.sh) | `crontab` 每 10 分钟 |
| Windows | [`clash/po0fw.ps1`](./clash/po0fw.ps1)（PowerShell 5.1 / 7+ 均可） | [`clash/po0fw-task.xml`](./clash/po0fw-task.xml) —— 任务计划程序，每 10 分钟 + 开机 + NetworkProfile 事件 10000（网络已连接） |
| macOS | `clash/po0fw.sh` | [`clash/com.po0fw.whitelist.plist`](./clash/com.po0fw.whitelist.plist) —— launchd，定时 + `WatchPaths` 网络变化触发 |
| Android | `clash/po0fw.sh` | Termux + `termux-job-scheduler` 定周期兜底（≤15 分钟），加 MacroDroid 在网络变化时秒级上报——JobScheduler 没有「网络变化」触发器，两者搭配才完整 |

零售消费级路由器（无 SSH / 无 cron / busybox `wget` 常不支持 HTTPS）基本做不了，别耗时间；开放固件的软路由没问题。

安装、TLS 证书处理与 Clash 规则覆写见 [`clash/README.md`](./clash/README.md)。

### 槽位策略：只让一台设备钉

`@槽位` 能让 IP 永不被 FIFO 淘汰，但**钉错了比不钉更糟**——它钉的是「本机**当前**的 IP」：

- **会移动的设备不要钉。** 手机钉了槽位后，一出门该槽位就变成蜂窝 IP，**家里 WAN 当场从白名单消失**，同网络的电脑立刻失联。
- 两台设备钉同一槽位会互相顶替；两台设备 IP 相同却钉不同槽位会收到 **403**。

正确做法是**只给始终待在同一出口的那台设备钉**（如常年连家里 WiFi 的 Mac 或常开设备），手机一律不加 `@`，让它们在剩余的 slotless 坑位里按 FIFO 轮转、被挤掉后自愈。
