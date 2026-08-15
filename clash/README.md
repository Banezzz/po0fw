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
| 家里 WiFi（Mac、Windows、手机连 WiFi 时都在这个出口下） | **一台始终在家的设备**——常住的台式机（Windows / Mac）最现实，见下 |
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
| **始终在家 WiFi 的那台**（常住的 Windows / Mac / 常开设备）——**只有这一台钉** | `pgnfw_A@0\|pgnfw_B@0` | 家里 WAN 永不被淘汰。这台关机或睡眠也不影响——钉住的行不参与淘汰，只在 WAN IP 真变了时才需要重写 |
| iPhone | `pgnfw_A\|pgnfw_B`（**不加 @**） | 它会移动，钉了反而把家里 WAN 顶掉 |
| Android | `pgnfw_A\|pgnfw_B`（**不加 @**） | 同上 |
| 笔记本（会带出门的 Mac） | 不加 `@` | 同上，除非它其实从不离开家 |

剩下 4 个 slotless 坑位留给蜂窝、公司、临时网络按 FIFO 轮转；被挤掉的设备几分钟内由自己的定时任务补回，会自愈。

> **如果你之前已经给手机钉了槽位，现在要去掉。** 症状很明确：手机和常住机器同在家里 WiFi 时 IP 相同却钉着不同槽位，服务端会返回 **403 槽位冲突**；而手机一出门，它钉的槽位变成蜂窝 IP，家里 WAN 当场消失，电脑立刻失联。把手机的参数从 `pgnfw_A@0|pgnfw_B@1` 改回 `pgnfw_A|pgnfw_B` 即可。

> 同一个槽位号在不同 token 上互不干扰（它们是两台机器各自的白名单），所以同一设备在两个 token 上用同一个号最好记。

## Linux / 常开设备（软路由 / NAS / 树莓派）

> **这台机器上如果跑着 Clash**（软路由尤其常见），先加下面「Clash 规则覆写」那条 DIRECT 规则再往下走，否则请求会被吃进代理，服务端看到的是代理出口 IP。不跑 Clash 的设备可以跳过。

```sh
mkdir -p /opt/po0fw && cd /opt/po0fw
curl -fsSL -o po0fw.sh        https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.sh
curl -fsSL -o po0fw.notify.sh https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.notify.sh
curl -fsSL -o po0fw.conf      https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.conf.example
chmod +x po0fw.sh

vi po0fw.conf     # 填 PO0FW_TOKENS
./po0fw.sh -v     # 先手动跑通，确认没有证书问题

crontab -e        # 加上：
# */10 * * * * /opt/po0fw/po0fw.sh
```

脚本是 POSIX sh，OpenWrt 的 busybox 也能跑，只额外依赖 `curl`（`--pin` 模式另需 `openssl`）。

## macOS（launchd）

Mac 常年连在家里 WiFi 的话，也可以由它来当「家里 WAN 上报者」。用 launchd 而不是 cron——它能同时做定时和**网络变化触发**。

> **Mac 上如果跑着 Clash Verge Rev**，先加下面「Clash 规则覆写」那条 DIRECT 规则再往下走。

```sh
# 1. 装脚本
mkdir -p ~/.po0fw && cd ~/.po0fw
curl -fsSL -o po0fw.sh        https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.sh
curl -fsSL -o po0fw.notify.sh https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.notify.sh
curl -fsSL -o po0fw.conf      https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.conf.example
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

### 系统通知

macOS 默认打开，逻辑跟 Shadowrocket / Surge 模块、以及 Windows / Android 一样：**只在出口 IP 或加白状态较上次变化时弹**（第一次成功、切网换了出口、加白失败，都会响）；例行 10 分钟上报保持安静。没配 token 也会弹。

标题是 `po0 防火墙加白`，和手机上那条一致。

```sh
# 默认就是这个，不写也行
PO0FW_NOTIFY="change"
```

| 值 | 行为 |
|---|---|
| `change` | 出口 IP / 加白状态变了才弹（**默认**，等同手机） |
| `always` | 每次执行都弹（成功 Glass / 失败 Basso） |
| `fail` | 只失败才弹 |
| `off` | 关 |

嫌默认还是吵，设 `off`。通知走系统 `osascript`，改这一行立刻生效，不用重装 launchd。已经装过、还没有 `po0fw.notify.sh` 的，补下这个文件并更新 `po0fw.sh` 即可。

## Windows（任务计划程序）

常住家里的如果是 Windows 那台，就让它来当「家里 WAN 上报者」——它常年开机、常年连同一个 WiFi，是最理想的人选。

用 [`po0fw.ps1`](./po0fw.ps1)，兼容 **Windows PowerShell 5.1**（系统自带）和 PowerShell 7+。全程用**管理员权限**的 PowerShell。

### 第 0 步：先在 Clash 里加 DIRECT 规则 ⚠️

**这台机器跑着 Clash，所以这一步不能跳。** 开了 TUN 模式时所有流量都进 mihomo，脚本的请求会被吃进代理，服务端看到的就是代理出口 IP——加白等于白加。而 `--noproxy` 之类的办法**绕不过 TUN 路由**。

Clash Verge Rev → **订阅 → 全局扩展配置**（Merge 类型）：

```yaml
prepend-rules:
  - IP-CIDR,124.221.69.228/32,DIRECT,no-resolve
```

写在这里订阅更新后不会被冲掉。详见下面的「Clash 规则覆写」。

### 第 1 步：装脚本

```powershell
mkdir C:\po0fw ; cd C:\po0fw
irm https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.ps1          -OutFile po0fw.ps1
irm https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.json.example -OutFile po0fw.json
irm https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw-task.xml     -OutFile po0fw-task.xml
```

### 第 2 步：填 token

```powershell
notepad C:\po0fw\po0fw.json
```

这台是常住机器，**加 `@0`** 把家里 WAN 钉死：

```json
"tokens": "pgnfw_第一个@0|pgnfw_第二个@0",
```

同时记得**把手机上的 `@槽位` 去掉**，否则会 403 冲突——见上面的「槽位策略」。

### 第 3 步：先手动跑一次 ⚠️

**别跳过这步直接注册任务**，证书问题就在这里暴露。

```powershell
cd C:\po0fw
.\po0fw.ps1 -Show
```

成功长这样：

```
po0 加白 2/2 · 出口 x.x.x.0/24
#1 📌0 ✅ 3/5  x.x.x.0/24
#2 📌0 ✅ 3/5  x.x.x.0/24
```

**如果报 SSL / 证书错误**，跑：

```powershell
.\po0fw.ps1 -ShowPin
```

它会打印 `"tls"` 和 `"pin"` 两行，把这两行替换进 `po0fw.json`，然后重跑第 3 步。

### 第 4 步：注册计划任务

```powershell
$xml = (Get-Content C:\po0fw\po0fw-task.xml -Raw) -replace '__PO0FW_DIR__', 'C:\po0fw'
Register-ScheduledTask -TaskName 'po0fw-whitelist' -Xml $xml -Force
```

> 若报 `The task XML is malformed` / `无法切换编码 (1,40)`，说明你手里的模板还是旧版
> （XML 声明里带 `encoding="UTF-8"`）。`Get-Content -Raw` 给出的是 .NET 字符串，
> 内存里是 UTF-16，和声明里写的 UTF-8 对不上。重新下载 `po0fw-task.xml` 即可，
> 或临时在上面那行末尾追加 `` -replace ' encoding="UTF-8"','' ``。

### 第 5 步：验证

```powershell
Start-ScheduledTask -TaskName 'po0fw-whitelist'
Start-Sleep 15
Get-ScheduledTaskInfo -TaskName 'po0fw-whitelist' | Format-List TaskName, LastRunTime, LastTaskResult
```

`LastTaskResult` 为 **`0`** 即成功；为 `1` 说明上报失败，看日志：

```powershell
Get-Content C:\ProgramData\po0fw\po0fw.log -Tail 20
```

最权威的判据还是去 po0 网页面板看白名单里有没有这台的 WAN IP、且带 📌0 标记。

### 系统通知

Windows 默认打开，逻辑跟 Shadowrocket / Surge 模块一样：**只在出口 IP 或加白状态较上次变化时弹**；例行 10 分钟上报保持安静。没配 token 也会弹。标题是 `po0 防火墙加白`。

```json
"notify": "change"
```

| 值 | 行为 |
|---|---|
| `change` | 出口 IP / 加白状态变了才弹（**默认**，等同手机） |
| `always` | 每次执行都弹 |
| `fail` | 只失败才弹 |
| `off` | 关 |

当前任务以 **SYSTEM** 身份跑，通知栏 toast 到不了你正在用的那个账号，脚本会退到 `msg.exe` 弹一条会话消息。想要右下角那种现代 toast：用「只在用户登录时运行」再注册一份当前用户的任务，或手动跑一次 `.\po0fw.ps1 -Show` 看效果。改 `notify` 立刻生效，不用重新注册任务。

### 说明

模板配了三个触发器：**每 10 分钟**、**开机后 1 分钟**、以及 **NetworkProfile 事件 10000（网络已连接）**——最后这个就是 Windows 版的 `network-changed`，带 10 秒延迟等接口稳定。任务以 **SYSTEM** 身份运行：不用存密码、不登录也跑、而且**不会每 10 分钟闪一个黑框**。

日志与状态文件在 `C:\ProgramData\po0fw\`。要改配置直接编辑 `po0fw.json`，不用重新注册任务。卸载：

```powershell
Unregister-ScheduledTask -TaskName 'po0fw-whitelist' -Confirm:$false
```

> **证书指纹在两个平台上不通用。** `po0fw.ps1 -ShowPin` 输出的是**整张证书的 SHA-256**，而 `po0fw.sh --pin` 输出的是 **SPKI 公钥指纹**。安全效果一样（都能挡中间人），但值不同，别互相复制。原因是导出 SPKI 的 API 在 .NET Framework 4.x 上不存在，PowerShell 5.1 用不了。

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

### 推荐：Termux 上报 + MacroDroid 切网

上报和通知交给 Termux 里的 `po0fw.sh`（真正的 `curl`，TLS 完整，跟 Shadowrocket 同一套「变了才弹」）。MacroDroid **只负责在切网时把脚本跑起来**——全程在 APP 里点，不用写代码。

`termux-job-scheduler` 最短 15 分钟、也不能盯切网，所以只拿来当定时兜底，不作为主方案。

#### 第 0 步：装 APP

Termux 这边要装 **三个**，MacroDroid 一个。Termux 三个**必须来自同一个源**，**不要用 Play 商店版 Termux**（已停更多年，`pkg` 装不了东西）。

> ⚠️ **Termux / Termux:API / Termux:Tasker 必须来自同一个源**，F-Droid 和 GitHub 二选一，不能混。
>
> 两边的构建**签名不同**，而它们之间是靠 Android 广播通信、系统会校验签名的。混装的话广播被拒，**所有 `termux-*` 命令都会永远挂着、不报任何错**——这是本节最难查的一种失败，因为它零输出、零报错。
>
> 已经混装了的话：先把其中一个卸载（同包名不同签名，Android 会拒绝直接覆盖安装），再从正确的源重装。

| 源 | Termux | Termux:API | Termux:Tasker |
|---|---|---|---|
| F-Droid | <https://f-droid.org/packages/com.termux/> | <https://f-droid.org/packages/com.termux.api/> | <https://f-droid.org/packages/com.termux.tasker/> |
| GitHub | <https://github.com/termux/termux-app/releases> | <https://github.com/termux/termux-api/releases> | <https://github.com/termux/termux-tasker/releases> |

MacroDroid 从 [官网](https://www.macrodroid.com/) 或应用商店装即可，跟 Termux 不是一家，源不用对齐。

**Termux:API** 给通知（`termux-notification`）。**Termux:Tasker** 是 MacroDroid 的插件，让 MacroDroid 能点选「跑哪个脚本」，不用自己填 Intent。

GitHub 那边按设备架构选 APK（`pkg` 输出里的 `aarch64` 对应 `arm64-v8a`），只有通用 APK 时直接下它。

装完先验一下两个 APP 通不通：

```sh
termux-battery-status
```

打印出一段 JSON 就是通的；**卡住不动**就是上面那个签名不一致的问题。

#### 第 1 步：装 + 配 + 验证（一段粘贴）

**先关掉 WiFi 切到移动数据再跑**，这样才能看到蜂窝的出口 IP。把两处 `pgnfw_你的第N个` 换成真 token，整段粘进 Termux：

```sh
pkg update -y && pkg upgrade -y && pkg install -y curl termux-api
curl -fsSL -o ~/po0fw.sh        https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.sh
curl -fsSL -o ~/po0fw.notify.sh https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.notify.sh
chmod +x ~/po0fw.sh
cat > ~/po0fw.conf <<'EOF'
PO0FW_TOKENS="pgnfw_你的第一个|pgnfw_你的第二个"
PO0FW_TLS="strict"
PO0FW_NOTIFY="change"
EOF
chmod 600 ~/po0fw.conf
~/po0fw.sh -v
```

手机是会移动的设备，**`PO0FW_TOKENS` 不要加 `@槽位`**——理由见上面的「槽位策略」。`chmod 600` 是因为这个文件里有 token。

再开一下外部调用和插件目录（MacroDroid 第 3 步要用）：

```sh
mkdir -p ~/.termux ~/.termux/tasker
grep -q '^allow-external-apps' ~/.termux/termux.properties 2>/dev/null \
  || echo 'allow-external-apps = true' >> ~/.termux/termux.properties
ln -sfn ~/po0fw.sh        ~/.termux/tasker/po0fw.sh
ln -sfn ~/po0fw.conf      ~/.termux/tasker/po0fw.conf
ln -sfn ~/po0fw.notify.sh ~/.termux/tasker/po0fw.notify.sh
```

改完 `termux.properties` 后，在 Termux 里执行一次 `termux-reload-settings`，或把 Termux 从后台划掉再开。

> **`pkg upgrade` 这步不能省。** Termux 的 `pkg update` 只刷新软件源索引、**不升级已装的包**。只跑 `update` 就 `install curl` 会装上最新 curl 却留着旧 openssl，启动时报
> `CANNOT LINK EXECUTABLE "curl": cannot locate symbol "SSL_set_quic_tls_transport_params"`，
> 然后后面每一步都跟着 `No such file or directory`（因为脚本压根没下下来）。
> 已经踩了的话跑 `pkg upgrade -y` 修复即可——它走 apt，不依赖 curl。

#### 第 2 步：肉眼确认出口 IP ⚠️

**这一步不能自动化。** 漏了 FlClash 的 DIRECT 规则时脚本照样报 ✅，只是上报的是代理的 IP——故障完全静默。

| 输出的出口 IP | 含义 |
|---|---|
| 运营商蜂窝段 | ✅ 对了，继续 |
| 家里宽带的段 | ❌ WiFi 没关干净 |
| 代理服务器所在的段 | ❌ DIRECT 规则没生效，回第一节 |

#### 第 3 步：MacroDroid 里点（切网立刻跑）

下面按 MacroDroid 中文界面写，英文界面括号里是对应名字。点完不用写任何代码。

1. 打开 **MacroDroid** → 右下角 **+** 新建宏，名字填 `po0 切网加白`。
2. **触发器（Triggers）** → **+** → **连接（Connectivity）** → **网络类型变化（Network Type Change）**。
   - 勾选 **WiFi** 和 **移动数据 / Cellular**。
   - **不要**勾「无连接 / None」，否则飞行模式也会空跑。
   - 保存触发器。
3. **动作（Actions）** → **+** → **插件（Plugins）** → **Termux**（装了 Termux:Tasker 才会出现这一项）。
   - **Executable / 可执行文件**：选 `po0fw.sh`（就是刚才链到 `~/.termux/tasker/` 的那个）。
   - **Arguments / 参数**：留空。
   - **Working Directory / 工作目录**：留空（脚本会在自己所在目录找 `po0fw.conf`）。
   - **不要**勾「在终端里打开 / Open in terminal」。
   - **Wait for result**：不勾也行。
   - 保存动作。
4. 点右上角保存宏，打开开关。

第一次触发时，系统会问 **「要允许 MacroDroid 在 Termux 里跑命令吗」**——允许。Android 13+ 还要给 **Termux:API** 开通知权限（设置 → 应用 → Termux:API → 通知 → 允许），否则脚本跑了你看不到弹窗。

**系统权限（两个 APP 都要）：**

- 设置 → 应用 → **Termux** → 电池 → **无限制**
- 设置 → 应用 → **MacroDroid** → 电池 → **无限制**，并允许自启动 / 后台运行（各家系统名字不一样，在「应用启动管理」里）

切一次 WiFi ↔ 移动数据，通知栏应弹出 `po0 防火墙加白`。以后同一出口例行上报不会再刷。

如果动作列表里没有 **Termux** 这一项：Termux:Tasker 没装，或跟 Termux 不是同一个源（签名不一致）。回到第 0 步对齐来源。

#### 第 4 步：定时兜底（可选）

MacroDroid 已经盯切网了。再加一个定时，避免某次 Intent 被系统吞掉。三种里选一个：

**A. 还是在 MacroDroid 里点（推荐，不用再记命令）**

同一个宏，再加一个触发器：**日期/时间（Date/Time）** → **间隔定时器（Regular Interval）** → **15 分钟**。一个宏两个触发器，切网和定时都跑同一条动作。

**B. Termux JobScheduler**

```sh
termux-job-scheduler --script ~/po0fw.sh --period-ms 900000 --persisted true --network any
```

周期最短 15 分钟是 Android 硬限制。管理：`termux-job-scheduler -p` 查看，`--cancel-all` 取消。

**C. cron（不依赖 Termux:API / Termux:Tasker）**

Termux:API 实在搞不定时，用 cron 完全绕开它。代价是 Termux 得常驻、比 JobScheduler 费电，通知栏会有常驻提示。

```sh
pkg install -y cronie termux-services
```

**装完必须彻底退出 Termux 再重开**（从后台任务里划掉，不是新开标签页），否则 runit 服务管理器没起来，`sv` 系列命令会找不到服务。重开后：

```sh
sv-enable crond
sv up crond
mkdir -p ~/.po0fw
echo "*/15 * * * * $HOME/po0fw.sh >> $HOME/.po0fw/cron.err 2>&1" | crontab -
termux-wake-lock
```

用 `echo ... | crontab -` 而不是 `crontab -e`，是为了避开在手机上用 vi 编辑。`$HOME` 在写入时展开成绝对路径——crontab 里不能靠 `~`。

验证：

```sh
crontab -l          # 应打印出那一行
sv status crond     # 应显示 run
cat ~/.po0fw/cron.err   # 应为空
```

想立刻确认 cron 真在跑，把周期临时改成 `* * * * *`（每分钟），等两分钟看 `cron.err`，确认无误再改回 `*/15`。

### 不要让 MacroDroid 自己发 HTTP

MacroDroid 也能「动作 → HTTP 请求 → POST」直接打 `https://124.221.69.228/api/firewall/<token>/add`。**别这么干**：裸 IP 的证书它过不去，只能勾「忽略 SSL 错误」，等价于 `insecure`，token 在 URL 里，中间人能看到。通知也会每次切网都弹，对不上手机模块那套安静逻辑。

切网用 MacroDroid，上报和通知留在 Termux 的 `po0fw.sh` 里。

### 系统通知（Android）

默认打开，跟 Shadowrocket 一样：只在出口 IP 或加白状态变了时弹，标题 `po0 防火墙加白`。靠 `termux-notification`，所以要装 Termux:API 并给它通知权限。

```sh
PO0FW_NOTIFY="change"   # 默认，不写也行
# PO0FW_NOTIFY="off"    # 关掉
```

已经装过、还没有 `~/po0fw.notify.sh` 的，补下这个文件即可，不用重做 MacroDroid。

### 别忘了覆写规则

FlClash 是 VPN 模式，**必须**在覆写里加上前面那条 DIRECT 规则，否则请求会走代理，服务端看到的就是代理出口 IP 了。

## 排错

手动跑一次看结果 + 看日志：

```sh
# Linux / macOS / Termux
./po0fw.sh -v
tail -f ~/.po0fw/po0fw.log
```

```powershell
# Windows
C:\po0fw\po0fw.ps1 -Show
Get-Content C:\ProgramData\po0fw\po0fw.log -Tail 20 -Wait
```

**脚本平时是安静的**：只有**出口 IP 或加白状态发生变化**、或者**有失败**时才写日志。所以日志一直没新内容通常是好事，不代表没在跑。

### 共通

| 现象 | 多半是 |
|---|---|
| 请求超时 / 不可达 | API 不可达。**若这台机器跑着 Clash 且开了 TUN，最常见的原因是漏了 DIRECT 规则**，见「Clash 规则覆写」 |
| SSL / 证书错误 | 见「TLS 三档」——先试 `pinned` |
| `加白未生效` | 请求通了但没写进白名单，检查服务端防火墙是否启用 |
| `槽位冲突` / HTTP 403 | 本机 IP 已占用别的槽位——多半是**多台设备都钉了槽位**，见「槽位策略」 |
| HTTP 401 / 404 | token 错了 |

### 按平台

| 现象 | 怎么查 |
|---|---|
| Windows：`LastTaskResult` = 1 | 上报失败。看 `C:\ProgramData\po0fw\po0fw.log` 末尾几行，再对照上表 |
| Windows：`LastTaskResult` = 2 | 配置错误（没填 token、`tls` 拼错、`pinned` 没配 `pin`）。手动跑 `.\po0fw.ps1 -Show` 会直接打印原因 |
| Windows：任务不跑 | `Get-ScheduledTask -TaskName 'po0fw-whitelist'` 看是否注册且 `State` 为 `Ready`；`Get-ScheduledTaskInfo` 看 `LastRunTime` |
| Windows：`irm` 下载报错 | 公司网络或代理拦截，换浏览器手动下载这三个文件到 `C:\po0fw\` |
| macOS：launchd 不跑 | `launchctl print gui/$(id -u)/com.po0fw.whitelist` 看是否注册；`/tmp/po0fw.err.log` 看有没有报错 |
| Android：`CANNOT LINK EXECUTABLE "curl"` / `cannot locate symbol` | Termux 包版本不一致（只跑了 `pkg update` 没跑 `pkg upgrade`）。`pkg upgrade -y` 修复；仍不行再 `pkg install -y --reinstall openssl libngtcp2 curl` |
| Android：`chmod: cannot access ~/po0fw.sh` / `No such file` | 上一条的连带——curl 坏了导致脚本没下下来。先修 curl 再重跑下载 |
| Android：`termux-*` 命令**静默卡住、零输出零报错** | Termux 与 Termux:API 不同源（F-Droid ↔ GitHub 混装），签名不一致导致广播被拒。见「第 0 步」。注意 `pm list packages` 在 Termux 里查不到东西（Android 11+ 的包可见性限制），别拿它当判据——用 `termux-battery-status` 试 |
| Android：Termux 任务不跑 | `termux-job-scheduler -p` 看任务在不在；确认已给 Termux 关掉电池优化 |
| Android：切网没有通知 | 看 `~/.po0fw/po0fw.log` 或脚本旁边的 `po0fw.log`。没新行通常是出口没变（好事）。完全没跑：MacroDroid 宏开关、Termux:Tasker 权限、`allow-external-apps = true`、电池优化 |
| Android：动作里没有 Termux 插件 | Termux:Tasker 没装，或跟 Termux 不同源。见「第 0 步」 |
| Android：脚本跑了但没有通知栏 | 没装 `termux-api`，或没给 Termux:API 开通知权限。`command -v termux-notification` 应能找到 |
| Windows：任务跑了但没看到通知 | 任务以 SYSTEM 跑，toast 到不了当前用户，应出现 `msg.exe` 会话消息。想要 Action Center toast，用当前用户再注册一份任务 |
