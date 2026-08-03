# Clash 系客户端（Clash Verge Rev / FlClash）怎么加白

## 先说结论：做不成模块，也不需要做成模块

Clash Verge Rev 和 FlClash 共用 **mihomo（Clash.Meta）** 内核，而 **mihomo 没有 cron / event 脚本这个扩展点**。这不是"难做"，是没有插孔：

- Verge Rev 的「Script」配置类型是 `function main(config) { return config }`，只在**生成配置时跑一次**，用来改配置对象，没有网络能力也没有定时能力；
- FlClash 的「覆写」同理，纯配置变换；
- mihomo 的 `script:` 只是规则匹配用的表达式快捷方式（如 `network == 'udp' and dst_port == 443`），不能发请求。

看到「脚本」两个字先别高兴，都不是 Surge 那个脚本。

好消息是这件事本来就不必在代理客户端里做。整个模块剥掉客户端兼容层之后实质只有一句 `POST /api/firewall/<token>/add`。iOS 上做成 Surge 模块，纯粹是因为 iOS 不给你别的方式跑后台定时任务；Mac / Android / Linux 都有正经的系统调度器。

## 谁来上报：按 C 段（/24）算账

服务端**按 C 段（/24）加白**，所以**同一个出口 IP 下只需要一台设备上报**，同一 WAN 出口下的其它机器一行配置都不用加。

| 出口 | 谁来上报 |
|---|---|
| 家里 WiFi（Mac、Windows、手机连 WiFi 时都在这个出口下） | **一台始终在家的设备**——Mac 最现实，见下 |
| iPhone 蜂窝 | iPhone 自己（Shadowrocket 模块，见仓库根目录） |
| Android 蜂窝 | Android 自己（Termux，见下） |

### 关于路由器

**零售消费级路由器基本做不了**，别在这上面耗时间。这类固件（中兴问天、小米、华为等）通常没有 SSH、没有用户 shell、没有 cron、没有包管理器。就算翻出 telnet，后面还有三道坎，第一道基本是死路：

1. **TLS**——固件里的 busybox `wget` 常常**根本不支持 HTTPS**，也没有 `curl`。API 是 HTTPS，到此为止。
2. **持久化**——没有可写分区放脚本，重启就没了。
3. **固件升级**——升一次全清空。

有 OpenWrt / 爱快 / iStoreOS 这类开放固件的软路由则完全没问题，按下面「Linux / 常开设备」一节装即可。

## 槽位策略：只让一台设备钉

白名单**上限 5 个**，写满按写入时间 **FIFO 淘汰**。`@槽位` 能把 IP 钉死、永不被淘汰——但**钉错了比不钉更糟**。

钉槽位的语义是「把**本机当前** IP 钉在槽位 N」，于是有三个坑：

- **会移动的设备不能钉。** iPhone 钉了槽位后，它在家时该槽位是家里 WAN，**一出门就变成蜂窝 IP，家里 WAN 当场从白名单消失**，Mac 和 Windows 立刻失联。
- **两台设备钉同一个槽位** → 互相行级顶替，谁后写谁赢。
- **两台设备 IP 相同却钉不同槽位**（比如都在家 WiFi）→ 服务端返回 **403「本机 IP 已在其它槽位」**。

所以正确的做法是：

| 设备 | 配置 | 理由 |
|---|---|---|
| **始终在家 WiFi 的那台**（Mac / 常开设备） | `pgnfw_A@0\|pgnfw_B@0` | 家里 WAN 永不被淘汰。这台睡眠也不影响——钉住的行不参与淘汰，只在 WAN IP 真变了时才需要重写 |
| iPhone | `pgnfw_A\|pgnfw_B`（**不加 @**） | 它会移动，钉了反而把家里 WAN 顶掉 |
| Android | `pgnfw_A\|pgnfw_B`（**不加 @**） | 同上 |

剩下 4 个 slotless 坑位留给蜂窝、公司、临时网络按 FIFO 轮转；被挤掉的设备几分钟内由自己的定时任务补回，会自愈。

> 同一个槽位号在不同 token 上互不干扰（它们是两台机器各自的白名单），所以同一设备在两个 token 上用同一个号最好记。

## Linux / 常开设备（软路由 / NAS / 树莓派）

```sh
mkdir -p /opt/po0fw && cd /opt/po0fw
curl -fsSL -o po0fw.sh   https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.sh
curl -fsSL -o po0fw.conf https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.conf.example
chmod +x po0fw.sh

vi po0fw.conf     # 填 PO0FW_TOKENS
./po0fw.sh -v     # 先手动跑通，确认没有证书问题

crontab -e        # 加上：
# */10 * * * * /opt/po0fw/po0fw.sh
```

脚本是 POSIX sh，OpenWrt 的 busybox 也能跑，只额外依赖 `curl`（`--pin` 模式另需 `openssl`）。

## macOS（launchd）

Mac 常年连在家里 WiFi，是最现实的「家里 WAN 上报者」。用 launchd 而不是 cron——它能同时做定时和**网络变化触发**。

```sh
# 1. 装脚本
mkdir -p ~/.po0fw && cd ~/.po0fw
curl -fsSL -o po0fw.sh   https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.sh
curl -fsSL -o po0fw.conf https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.conf.example
chmod +x po0fw.sh
vi po0fw.conf                      # PO0FW_TOKENS="pgnfw_A@0|pgnfw_B@0"
./po0fw.sh -v                      # 先手动跑通

# 2. 装 LaunchAgent（把模板里的 __PO0FW_DIR__ 换成实际绝对路径）
curl -fsSL https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/com.po0fw.whitelist.plist \
  | sed "s|__PO0FW_DIR__|$HOME/.po0fw|g" > ~/Library/LaunchAgents/com.po0fw.whitelist.plist

# 3. 加载
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.po0fw.whitelist.plist

# 4. 确认已注册
launchctl print gui/$(id -u)/com.po0fw.whitelist | head -20
```

改完 plist 要重新加载：

```sh
launchctl bootout gui/$(id -u)/com.po0fw.whitelist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.po0fw.whitelist.plist
```

模板里配了三件事：`StartInterval 600`（每 10 分钟）、`RunAtLoad`（登录即跑一次）、`WatchPaths` 盯 `/etc/resolv.conf` 与 `SystemConfiguration`——切 WiFi、重新拨号、换 DHCP 租约时这些路径会被系统重写，等效于 Surge 的 `network-changed`。`ThrottleInterval 30` 防止网络抖动时连续触发。

Mac 睡眠期间不跑，唤醒后补一次。**但因为槽位是钉住的，睡眠期间白名单里那条也不会被淘汰**，所以不影响 Windows 用。

## TLS 三档（裸 IP 的 HTTPS 一定会碰到）

先探一下：

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://124.221.69.228/
```

| 结果 | 用哪档 | 配置 |
|---|---|---|
| 正常返回状态码 | `strict` | 保持默认，什么都不用改 |
| 报证书错误 | **`pinned`（推荐）** | 跑 `./po0fw.sh --pin`，把打印出来的两行贴进 `po0fw.conf` |
| pinned 也不行 | `insecure` | `PO0FW_TLS="insecure"` |

**为什么推荐 pinned**：`--pin` 会取服务端证书的公钥算 SHA-256 指纹，之后每次连接都校验这个指纹。自签证书过不了 CA 链校验，但钉住公钥同样能挡住中间人。

**为什么 `insecure` 是下策**：token 是放在 **URL 路径**里的（`/api/firewall/<token>/add`），关掉校验等于把 token 拱手交给中间人。真要用的话，至少别在公共 WiFi 上跑。

> 服务端换证书后 pinned 的指纹会失效，重新跑一次 `--pin` 即可。

## Clash 规则覆写（只有自己要上报的机器才需要）

TUN / VPN 模式下所有流量都进 mihomo，`curl --noproxy` **绕不过去**——它只能绕开环境变量里的代理，绕不开 TUN 路由。必须让 mihomo 自己把这个目标判成 DIRECT：

```yaml
prepend-rules:
  - IP-CIDR,124.221.69.228/32,DIRECT,no-resolve
```

- **Clash Verge Rev**：订阅 → 「全局扩展配置」（Merge 类型）→ 粘进去。写在这里订阅更新后不会被冲掉。
- **FlClash**：设置 → 覆写 → 规则，直接追加那条 `IP-CIDR` 规则（不用 `prepend-rules` 这层包装）。

完整片段见 [`override.yaml`](./override.yaml)。

如果某台机器自己不发请求（靠别人覆盖），那台**可以不加**这条。

## Android 蜂窝（FlClash）

这是唯一没法靠家里那台覆盖的场景——用移动数据时出口 IP 和家里完全无关。

### 推荐：Termux + termux-job-scheduler

比自动化 App 靠谱的关键原因：**Termux 自带真正的 `curl`，TLS 完整，`pinned` 模式能用**，证书问题一次性解决；而且直接复用同一个 `po0fw.sh`，不用维护第二套逻辑。

```sh
# 1. 从 F-Droid 装 Termux 和 Termux:API（不要用 Play 商店版，已停更多年）
#    https://f-droid.org/packages/com.termux/
#    https://f-droid.org/packages/com.termux.api/

# 2. 在 Termux 里
pkg update && pkg install curl termux-api

curl -fsSL -o ~/po0fw.sh   https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.sh
curl -fsSL -o ~/po0fw.conf https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.conf.example
chmod +x ~/po0fw.sh
nano ~/po0fw.conf          # PO0FW_TOKENS 不加 @槽位

# 3. 手动跑通
~/po0fw.sh -v

# 4. 交给系统调度（--persisted 开机自启，--network any 要求有网才跑）
termux-job-scheduler --script ~/po0fw.sh --period-ms 900000 --persisted true --network any
```

管理：

```sh
termux-job-scheduler -p            # 列出已注册的任务
termux-job-scheduler --cancel-all  # 全部取消
```

两个注意点：

- **周期最短 15 分钟**（`--period-ms 900000`）。这是 Android JobScheduler 的硬限制，不是脚本的问题，比 iOS 那边的 10 分钟略长，可以接受。
- **必须给 Termux 关掉电池优化**（设置 → 应用 → Termux → 电池 → 无限制），否则会被系统掐掉。

### 备选：MacroDroid / Tasker

优势是能做**网络类型变化的即时触发**，这一点 JobScheduler 做不到（它只能定周期）。劣势是 TLS 控制弱——裸 IP 的证书多半过不去，只能开「忽略 SSL 错误」，等价于 `insecure`，token 会暴露给中间人。

配置：触发器「连接 → 网络类型变化」+「定时」，动作「HTTP 请求 → POST」到 `https://124.221.69.228/api/firewall/<token>/add`。

**想两者兼得**：Termux 管定时兜底（TLS 安全），MacroDroid 只负责在网络变化时通过 `RUN_COMMAND` intent 去调 Termux 里的 `po0fw.sh`。这样即时性和证书安全都有了，代价是配置复杂一些。

### 别忘了覆写规则

FlClash 是 VPN 模式，**必须**在覆写里加上前面那条 DIRECT 规则，否则请求会走代理，服务端看到的就是代理出口 IP 了。

## 排错

```sh
./po0fw.sh -v          # 手动跑，直接看结果
tail -f ~/.po0fw/po0fw.log
```

脚本平时是安静的：只有**出口 IP 或加白状态发生变化**、或者**有失败**时才写日志。所以日志一直没新内容通常是好事。

| 现象 | 多半是 |
|---|---|
| `❌ 请求失败: curl: (60) SSL certificate problem` | 证书校验，见「TLS 三档」 |
| `❌ 请求失败: curl: (28) timed out` | API 不可达。若在 TUN 模式下，多半是漏了 DIRECT 规则 |
| `❌ 加白未生效` | 请求通了但没写进白名单，检查服务端防火墙是否启用 |
| `❌ 槽位冲突` | 本机 IP 已占用别的槽位——多半是多台设备都钉了槽位，见「槽位策略」 |
| `❌ HTTP 401/404` | token 错了 |
| launchd 不跑 | `launchctl print gui/$(id -u)/com.po0fw.whitelist` 看是否注册；`/tmp/po0fw.err.log` 看有没有报错 |
| Termux 任务不跑 | `termux-job-scheduler -p` 看任务在不在；确认已关掉电池优化 |
