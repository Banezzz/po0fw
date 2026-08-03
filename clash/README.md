# Clash 系客户端（Clash Verge Rev / FlClash）怎么加白

## 先说结论：做不成模块，也不需要做成模块

Clash Verge Rev 和 FlClash 共用 **mihomo（Clash.Meta）** 内核，而 **mihomo 没有 cron / event 脚本这个扩展点**。这不是"难做"，是没有插孔：

- Verge Rev 的「Script」配置类型是 `function main(config) { return config }`，只在**生成配置时跑一次**，用来改配置对象，没有网络能力也没有定时能力；
- FlClash 的「覆写」同理，纯配置变换；
- mihomo 的 `script:` 只是规则匹配用的表达式快捷方式（如 `network == 'udp' and dst_port == 443`），不能发请求。

看到「脚本」两个字先别高兴，都不是 Surge 那个脚本。

好消息是这件事本来就不必在代理客户端里做。整个模块剥掉客户端兼容层之后实质只有一句 `POST /api/firewall/<token>/add`。iOS 上做成 Surge 模块，纯粹是因为 iOS 不给你别的方式跑后台定时任务；Mac / Windows / Android / 路由器都有正经的系统调度器。

## 架构：一台常开设备覆盖一整个出口

服务端**按 C 段（/24）加白**，所以**同一个出口 IP 下只需要一台设备上报**。

于是只需要两件事：

| 场景 | 谁来上报 |
|---|---|
| 家里 / 公司固定网络（Mac、Windows、手机连 WiFi 时都在这个出口下） | **常开设备**挂一条 10 分钟 cron，一次覆盖全部 |
| 手机用蜂窝、笔记本带出门连陌生网络 | 设备自己上报 |

先把第一行做掉，工作量就少了一大半——那些机器上一行配置都不用加。

## 一、常开设备（软路由 / NAS / 树莓派 / 常开主机）

```sh
# 1. 放到常开设备上
mkdir -p /opt/po0fw && cd /opt/po0fw
curl -fsSL -o po0fw.sh https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.sh
curl -fsSL -o po0fw.conf https://raw.githubusercontent.com/Banezzz/po0fw/main/clash/po0fw.conf.example
chmod +x po0fw.sh

# 2. 填 token
vi po0fw.conf     # PO0FW_TOKENS="pgnfw_第一台@0,pgnfw_第二台@1"

# 3. 先手动跑一次看结果
./po0fw.sh -v

# 4. 挂 cron，每 10 分钟一次
crontab -e
# 加上这行：
*/10 * * * * /opt/po0fw/po0fw.sh
```

脚本是 POSIX sh，OpenWrt 的 busybox 也能跑，只额外依赖 `curl`（`--pin` 模式另需 `openssl`）。

**先解决证书**：API 是裸 IP 的 HTTPS，`curl` 会严格校验证书，多半过不了。第 3 步要是报证书错，按下面的「TLS 三档」处理。

## 二、TLS 三档（裸 IP 的 HTTPS 一定会碰到）

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

## 三、Clash 规则覆写（只有自己要上报的机器才需要）

TUN / VPN 模式下所有流量都进 mihomo，`curl --noproxy` **绕不过去**——它只能绕开环境变量里的代理，绕不开 TUN 路由。必须让 mihomo 自己把这个目标判成 DIRECT：

```yaml
prepend-rules:
  - IP-CIDR,124.221.69.228/32,DIRECT,no-resolve
```

- **Clash Verge Rev**：订阅 → 「全局扩展配置」（Merge 类型）→ 粘进去。写在这里订阅更新后不会被冲掉。
- **FlClash**：设置 → 覆写 → 规则，直接追加那条 `IP-CIDR` 规则（不用 `prepend-rules` 这层包装）。

完整片段见 [`override.yaml`](./override.yaml)。

如果你是靠常开设备统一上报、Mac/Windows 自己不发请求，**那两台可以不加这条**。

## 四、Android 蜂窝（FlClash）

这是唯一没法靠常开设备覆盖的场景——手机用移动数据时出口 IP 和家里完全无关。

Android 没有系统 cron，推荐用自动化 App：

| 方案 | 说明 |
|---|---|
| **MacroDroid**（推荐） | 免费版够用。触发器：「连接」→ 网络类型变化 + 「定时」→ 每 10 分钟；动作：「HTTP 请求」→ POST `https://124.221.69.228/api/firewall/<token>/add` |
| **Tasker** | 同样思路，Profile: Network / Time → Task: HTTP Request |
| Termux + cronie | 能做，但要保活、后台限制多、耗电，不推荐 |

两个注意点：

1. FlClash 是 VPN 模式，**必须**在覆写里加上第三节那条 DIRECT 规则，否则请求会走代理，API 看到的就是代理出口 IP 了。
2. 这些 App 通常也会卡在证书校验上。MacroDroid 的 HTTP 请求动作有「忽略 SSL 错误」选项——同样要意识到 token 在 URL 里的风险。

## 五、坑位会被抢爆，记得钉槽位

白名单**上限 5 个**，写满按写入时间 **FIFO 淘汰**。设备一多（两台机器 × 家里/公司/蜂窝几个出口）就会出现「这台把那台挤掉、那台补回来又挤掉这台」的循环，谁都连不稳。

给稳定出口钉固定槽位，它就**永不被淘汰**：

```
PO0FW_TOKENS="pgnfw_第一台@0,pgnfw_第二台@1"
```

留下的坑位给移动网络去抢即可。

## 六、排错

```sh
./po0fw.sh -v          # 手动跑，直接看结果
tail -f ~/.po0fw/po0fw.log
```

脚本平时是安静的：只有**出口 IP 或加白状态发生变化**、或者**有失败**时才写日志。所以日志一直没新内容通常是好事。

| 现象 | 多半是 |
|---|---|
| `❌ 请求失败: curl: (60) SSL certificate problem` | 证书校验，见第二节 |
| `❌ 请求失败: curl: (28) timed out` | API 不可达。若在 TUN 模式下，多半是漏了第三节的 DIRECT 规则 |
| `❌ 加白未生效` | 请求通了但没写进白名单，检查服务端防火墙是否启用 |
| `❌ 槽位冲突` | 本机 IP 已占用别的槽位，去 UI 删掉旧的那条 |
| `❌ HTTP 401/404` | token 错了 |
