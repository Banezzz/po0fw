<#
  po0 防火墙自动加白 · Windows PowerShell 版

  给 Clash 系客户端（Clash Verge Rev / FlClash）用户准备：mihomo 内核没有
  cron / event 脚本这个扩展点，所以改由任务计划程序驱动本脚本。

  服务端按 C 段（/24）加白，因此同一出口 IP 下只需要一台设备上报。常住家里
  的那台机器挂上本脚本，同 WAN 出口下的所有设备就都被覆盖了。

  用法：
    .\po0fw.ps1              正常上报（任务计划程序里用这个）
    .\po0fw.ps1 -Show        上报并把结果打到控制台（手动排错用）
    .\po0fw.ps1 -ShowPin     打印服务端证书的 SHA-256 指纹，用于配置 pin

  配置：同目录的 po0fw.json，见 po0fw.json.example。

  退出码：0 全部成功；1 有失败；2 配置错误。

  兼容性：Windows PowerShell 5.1 与 PowerShell 7+ 均可。
    - 5.1 没有 -SkipCertificateCheck，7 又会忽略 ServicePointManager 的
      全局回调，所以这里统一走 HttpWebRequest 的每请求证书回调。
    - 指纹用「整张证书的 SHA-256」而不是 curl --pinnedpubkey 的 SPKI 公钥
      指纹，因为导出 SPKI 的 API 在 .NET Framework 4.x 上没有。安全效果
      相同（都能挡中间人），但**这个值和 po0fw.sh --pin 输出的不是一回事**，
      不要互相套用。
#>

[CmdletBinding()]
param(
  [switch]$Show,
  [switch]$ShowPin,
  [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# 5.1 默认可能还在用 TLS 1.0/1.1，显式抬到 1.2+
try {
  [System.Net.ServicePointManager]::SecurityProtocol =
    [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11
} catch { }

# 证书校验必须用编译出来的 C# 委托，不能用 PowerShell ScriptBlock。
# 回调是在没有 Runspace 的 IO 线程上触发的，ScriptBlock 到那里会抛
# "There is no Runspace available to run scripts in this thread"，
# 表现为握手直接失败——连 insecure 都连不上。5.1 上那个经典的
# ServicePointManager + {$true} 写法在 PowerShell 7 上失效就是这个原因。
if (-not ('Po0FwCert' -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
public static class Po0FwCert {
    public static string Mode = "strict";          // strict | pinned | insecure
    public static string Pin  = "";                // 整张证书的 SHA-256（base64）
    public static string LastFingerprint = "";     // 每次握手都记下来，供 -ShowPin 用
    public static bool Validate(object s, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
        if (cert != null) {
            using (var sha = SHA256.Create())
                LastFingerprint = Convert.ToBase64String(sha.ComputeHash(cert.GetRawCertData()));
        }
        if (Mode == "insecure") return true;
        if (Mode == "pinned")   return cert != null && string.Equals(LastFingerprint, Pin, StringComparison.Ordinal);
        return errors == SslPolicyErrors.None;
    }
}
"@
}
$script:CertCallback = [System.Net.Security.RemoteCertificateValidationCallback]([Po0FwCert]::"Validate")

# ---------- 配置 ----------

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptDir 'po0fw.json' }

$cfg = @{
  tokens       = ''
  api          = 'https://124.221.69.228/api/firewall'
  tls          = 'strict'      # strict | pinned | insecure
  pin          = ''
  timeoutSec   = 12
  maxAttempts  = 3
  retryBaseSec = 2
  stateDir     = ''
}

if (Test-Path -LiteralPath $ConfigPath) {
  try {
    $json = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in @($cfg.Keys)) {
      if ($json.PSObject.Properties.Name -contains $k -and $null -ne $json.$k -and "$($json.$k)" -ne '') {
        $cfg[$k] = $json.$k
      }
    }
  } catch {
    Write-Host "[po0fw] 配置文件解析失败：$ConfigPath -- $($_.Exception.Message)"
    exit 2
  }
}

if (-not $cfg.stateDir) {
  $base = if ($env:ProgramData) { $env:ProgramData } else { $env:TEMP }
  $cfg.stateDir = Join-Path $base 'po0fw'
}
$null = New-Item -ItemType Directory -Force -Path $cfg.stateDir -ErrorAction SilentlyContinue
$logPath = Join-Path $cfg.stateDir 'po0fw.log'

# 交给 C# 校验器（回调线程上读不到 PowerShell 变量，只能走静态字段）
[Po0FwCert]::Mode = [string]$cfg.tls
[Po0FwCert]::Pin = ([string]$cfg.pin) -replace '^sha256//', ''

function Write-Log {
  param([string]$Message)
  $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch { }
  if ($Show) { Write-Host $Message }
}

# 日志别无限长：超过 256KB 就只留最后 200 行
try {
  if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 262144) {
    $tail = Get-Content -LiteralPath $logPath -Tail 200
    Set-Content -LiteralPath $logPath -Value $tail -Encoding UTF8
  }
} catch { }

# ---------- HTTP ----------

# 返回 @{ code = <int或0>; body = <string>; error = <string> }
# code 为 0 表示传输层失败（连不上 / 超时 / 证书不过），调用方会重试。
function Invoke-Po0Post {
  param([string]$Url)

  $result = @{ code = 0; body = ''; error = '' }
  try {
    $req = [System.Net.HttpWebRequest]::CreateHttp($Url)
    $req.Method = 'POST'
    $req.ContentType = 'application/json'
    $req.Timeout = [int]$cfg.timeoutSec * 1000
    $req.ReadWriteTimeout = [int]$cfg.timeoutSec * 1000
    $req.AllowAutoRedirect = $false
    $req.UserAgent = 'po0fw-ps'
    # 绕过系统代理。注意 TUN 模式绕不过去，那要靠 Clash 里的
    # IP-CIDR ... DIRECT 规则（见 override.yaml）。
    $req.Proxy = $null
    # 三种模式的判断都在 C# 校验器里，strict 也走它（返回 errors == None）
    $req.ServerCertificateValidationCallback = $script:CertCallback

    $req.ContentLength = 0
    $reqStream = $req.GetRequestStream()
    $reqStream.Close()

    $resp = $req.GetResponse()
    try {
      $result.code = [int]$resp.StatusCode
      $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
      try { $result.body = $sr.ReadToEnd() } finally { $sr.Dispose() }
    } finally { $resp.Close() }
  } catch [System.Net.WebException] {
    $we = $_.Exception
    if ($we.Response) {
      # 非 2xx 也会抛 WebException，但这是服务端的明确答复，不该重试
      try {
        $result.code = [int]$we.Response.StatusCode
        $sr = New-Object System.IO.StreamReader($we.Response.GetResponseStream())
        try { $result.body = $sr.ReadToEnd() } finally { $sr.Dispose() }
      } catch { $result.error = $we.Message }
      finally { try { $we.Response.Close() } catch { } }
    } else {
      $result.error = $we.Message
    }
  } catch {
    $result.error = $_.Exception.Message
  }
  return $result
}

# 只对传输层失败重试；服务端给了明确答复（含 403 槽位冲突）就不再试
function Invoke-Po0PostWithRetry {
  param([string]$Url)
  $attempt = 1
  while ($true) {
    $r = Invoke-Po0Post -Url $Url
    if ($r.code -ne 0) { return $r }
    if ($attempt -ge [int]$cfg.maxAttempts) { return $r }
    Start-Sleep -Seconds ([int]$cfg.retryBaseSec * $attempt)
    $attempt++
  }
}

# ---------- -ShowPin ----------

if ($ShowPin) {
  $probe = ([string]$cfg.api) -replace '/api/firewall/?$', '/'
  [Po0FwCert]::Mode = 'insecure'      # 取指纹时先放行，否则自签证书连不上
  [Po0FwCert]::LastFingerprint = ''
  try {
    $req = [System.Net.HttpWebRequest]::CreateHttp($probe)
    $req.Method = 'HEAD'
    $req.Timeout = 15000
    $req.Proxy = $null
    $req.ServerCertificateValidationCallback = $script:CertCallback
    # 握手成功即可拿到指纹，HTTP 状态码是什么无所谓
    try { $req.GetResponse().Close() } catch { }
  } catch { }
  $captured = [Po0FwCert]::LastFingerprint
  if (-not $captured) {
    Write-Host "取证书失败：确认 $probe 可达，且当前出口 IP 已在白名单里"
    exit 1
  }
  Write-Host ''
  Write-Host '把下面两项填进 po0fw.json：'
  Write-Host ''
  Write-Host ('  "tls": "pinned",')
  Write-Host ('  "pin": "sha256//{0}"' -f $captured)
  Write-Host ''
  Write-Host '注意：这是整张证书的 SHA-256，和 po0fw.sh --pin 的 SPKI 公钥指纹不是一回事，不要互相套用。'
  exit 0
}

# ---------- 主流程 ----------

if (-not $cfg.tokens) {
  Write-Log "❌ 未配置 token：在 $ConfigPath 的 tokens 字段填入 pgnfw_ token"
  exit 2
}
if (@('strict', 'pinned', 'insecure') -notcontains $cfg.tls) {
  Write-Log "❌ tls 只能是 strict / pinned / insecure，当前是 $($cfg.tls)"
  exit 2
}
if ($cfg.tls -eq 'pinned' -and -not $cfg.pin) {
  Write-Log '❌ tls=pinned 但没填 pin，先跑 .\po0fw.ps1 -ShowPin'
  exit 2
}

# 分隔符兼容 , | ; 和空白；每段可带 @槽位 后缀。
# 必须用 @() 包住：只剩一个 token 时管道会返回标量字符串，
# StrictMode 下对它取 .Count 会直接抛错。
$items = @(([string]$cfg.tokens) -split '[,|;\s]+' | Where-Object { $_ -like 'pgnfw_*' })
if ($items.Count -eq 0) {
  Write-Log '❌ tokens 里没有合法的 pgnfw_ token'
  exit 2
}

$okCount = 0
$total = 0
$exitIp = '?'
$changed = $false
$lines = New-Object System.Collections.Generic.List[string]

foreach ($item in $items) {
  $total++
  $idx = $total

  $token = $item
  $slot = ''
  if ($item -match '^(.+?)@(.+)$') { $token = $Matches[1]; $slot = $Matches[2] }

  $url = "{0}/{1}/add" -f ([string]$cfg.api).TrimEnd('/'), [uri]::EscapeDataString($token)
  if ($slot) { $url += "?slot=" + [uri]::EscapeDataString($slot) }

  $pinTag = if ($slot) { " 📌$slot" } else { '' }
  $head = "#$idx$pinTag"

  $r = Invoke-Po0PostWithRetry -Url $url

  $applied = $false
  $currentIp = ''

  if ($r.code -eq 0) {
    $lines.Add("$head ❌ 请求失败: $($r.error)")
    Write-Log "$head 请求失败（已重试 $($cfg.maxAttempts) 次）: $($r.error)"
  } else {
    $data = $null
    if ($r.body) { try { $data = $r.body | ConvertFrom-Json } catch { } }
    if ($data -and $data.PSObject.Properties.Name -contains 'currentIp' -and $data.currentIp) {
      $currentIp = [string]$data.currentIp
      $exitIp = $currentIp
    }

    if ($r.code -eq 403) {
      $lines.Add("$head ❌ 槽位冲突：本机 IP 已在其它槽位，请先去 UI 删除")
      Write-Log "$head 槽位冲突 (403)"
    } elseif ($r.code -ne 200) {
      $lines.Add("$head ❌ HTTP $($r.code)")
      $snippet = if ($r.body.Length -gt 120) { $r.body.Substring(0, 120) } else { $r.body }
      Write-Log "$head HTTP $($r.code): $snippet"
    } elseif (-not $data) {
      $lines.Add("$head ❌ 响应异常")
      Write-Log "$head 响应无法解析: $($r.body)"
    } else {
      # 服务端把 whitelist 与 currentIp 都归一化成 x.x.x.0/24
      $enabled = ($data.PSObject.Properties.Name -contains 'enabled') -and ($data.enabled -eq $true)
      $wl = @()
      if ($data.PSObject.Properties.Name -contains 'whitelist' -and $data.whitelist) {
        foreach ($e in $data.whitelist) {
          if ($e -is [string]) { $wl += $e }
          elseif ($e -and $e.PSObject.Properties.Name -contains 'ip') { $wl += [string]$e.ip }
        }
      }
      $limit = if ($data.PSObject.Properties.Name -contains 'limit') { $data.limit } else { '?' }
      if ($enabled -and ($wl -contains $currentIp)) {
        $applied = $true
        $okCount++
        $lines.Add("$head ✅ $($wl.Count)/$limit  $currentIp")
      } else {
        $reason = if (-not $enabled) { '防火墙未启用' } else { '写入未生效' }
        $lines.Add("$head ❌ 加白未生效（$reason）")
        Write-Log "$head 未生效（$reason）: $($wl -join ', ')"
      }
    }
  }

  # 只在出口 IP 或加白状态变化时才吵，例行运行保持安静
  $stateFile = Join-Path $cfg.stateDir "state_$idx"
  $newState = "{0}|{1}" -f $(if ($currentIp) { $currentIp } else { '?' }), $(if ($applied) { '1' } else { '0' })
  $oldState = ''
  if (Test-Path -LiteralPath $stateFile) {
    try { $oldState = (Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8).Trim() } catch { }
  }
  if ($newState -ne $oldState) {
    try { Set-Content -LiteralPath $stateFile -Value $newState -Encoding UTF8 -NoNewline } catch { }
    $changed = $true
  }
}

$summary = "po0 加白 $okCount/$total · 出口 $exitIp"
$detail = ($lines -join [Environment]::NewLine)

if ($changed -or $okCount -ne $total) {
  Write-Log ($summary + [Environment]::NewLine + $detail)
} elseif ($Show) {
  Write-Host $summary
  Write-Host $detail
}

if ($okCount -eq $total) { exit 0 } else { exit 1 }
