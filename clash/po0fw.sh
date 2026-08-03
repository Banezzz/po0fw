#!/bin/sh
# po0 防火墙自动加白 · 通用 shell 版
#
# 给 Clash 系客户端（Clash Verge Rev / FlClash）用户准备：mihomo 内核没有
# cron / event 脚本这个扩展点，无法像 Surge 那样把加白做成模块，所以改由
# 系统调度器（cron / launchd）来跑这个脚本。
#
# 服务端按 C 段（/24）加白，因此**同一出口 IP 下只需要一台设备上报**：
# 在常开设备（软路由 / NAS / 树莓派 / 常开主机）上挂一条 cron，同一 WAN 出口
# 下的所有设备就都被覆盖了，其它机器一行配置都不用加。
#
# 用法：
#   ./po0fw.sh            正常上报（cron 里用这个）
#   ./po0fw.sh -v         上报并把结果打到 stdout（手动排错用）
#   ./po0fw.sh --pin      打印服务端证书的公钥指纹，用于配置 PO0FW_PIN
#
# 配置：同目录的 po0fw.conf，或直接用环境变量。见 po0fw.conf.example。
#
# 退出码：0 全部成功；1 有失败；2 配置错误。

set -u

SELF_DIR=$(dirname "$0")
CONF="${PO0FW_CONF:-$SELF_DIR/po0fw.conf}"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

API_BASE="${PO0FW_API:-https://124.221.69.228/api/firewall}"
TOKENS="${PO0FW_TOKENS:-}"
TLS_MODE="${PO0FW_TLS:-strict}" # strict | pinned | insecure
PIN="${PO0FW_PIN:-}"
STATE_DIR="${PO0FW_STATE_DIR:-${HOME:-/tmp}/.po0fw}"
LOG="${PO0FW_LOG:-$STATE_DIR/po0fw.log}"
MAX_ATTEMPTS="${PO0FW_MAX_ATTEMPTS:-3}"
RETRY_BASE="${PO0FW_RETRY_BASE:-2}"
REQ_TIMEOUT="${PO0FW_TIMEOUT:-12}"

VERBOSE=0
case "${1:-}" in
  -v | --verbose) VERBOSE=1 ;;
  --pin) MODE_PIN=1 ;;
esac

API_HOST=$(printf '%s' "$API_BASE" | sed 's|^https\{0,1\}://||; s|[:/].*$||')
API_PORT=$(printf '%s' "$API_BASE" | sed -n 's|^https\{0,1\}://[^:/]*:\([0-9]*\).*|\1|p')
[ -z "$API_PORT" ] && API_PORT=443

# --pin：算出服务端公钥的 sha256 指纹。裸 IP 的自签证书过不了 CA 校验，
# 但钉住公钥同样能挡住中间人——比无脑 --insecure 安全得多。
if [ "${MODE_PIN:-0}" = "1" ]; then
  if ! command -v openssl >/dev/null 2>&1; then
    echo "需要 openssl 才能计算指纹" >&2
    exit 2
  fi
  fp=$(openssl s_client -connect "$API_HOST:$API_PORT" -servername "$API_HOST" </dev/null 2>/dev/null |
    openssl x509 -pubkey -noout 2>/dev/null |
    openssl pkey -pubin -outform der 2>/dev/null |
    openssl dgst -sha256 -binary 2>/dev/null |
    openssl enc -base64 2>/dev/null)
  if [ -z "$fp" ]; then
    echo "取证书失败：确认 $API_HOST:$API_PORT 可达，且当前出口 IP 已在白名单里" >&2
    exit 1
  fi
  echo "PO0FW_TLS=\"pinned\""
  echo "PO0FW_PIN=\"sha256//$fp\""
  exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true
  [ "$VERBOSE" = "1" ] && printf '%s\n' "$*"
  return 0
}

# 日志别无限长：超过 256KB 就只留最后 200 行
if [ -f "$LOG" ]; then
  size=$(wc -c <"$LOG" 2>/dev/null || echo 0)
  if [ "$size" -gt 262144 ] 2>/dev/null; then
    tail -n 200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
fi

if [ -z "$TOKENS" ]; then
  log "❌ 未配置 token：在 $CONF 里设 PO0FW_TOKENS，或用环境变量传入"
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  log "❌ 找不到 curl"
  exit 2
fi

# 裸 IP 的 HTTPS 多半没有能过 CA 校验的证书，这里给三档：
#   strict   正常校验（证书带 IP SAN 时用这个）
#   pinned   跳过链校验但钉住公钥指纹（推荐，仍能挡中间人）
#   insecure 完全不校验（token 在 URL 路径里，会被中间人看到，不得已才用）
case "$TLS_MODE" in
  strict) TLS_ARGS="" ;;
  pinned)
    if [ -z "$PIN" ]; then
      log "❌ PO0FW_TLS=pinned 但没设 PO0FW_PIN，先跑 ./po0fw.sh --pin"
      exit 2
    fi
    TLS_ARGS="-k --pinnedpubkey $PIN"
    ;;
  insecure) TLS_ARGS="-k" ;;
  *)
    log "❌ PO0FW_TLS 只能是 strict / pinned / insecure，当前是 $TLS_MODE"
    exit 2
    ;;
esac

# 单发。--noproxy 绕开环境变量里的代理；TUN 模式绕不过去，那要靠
# Clash 配置里的 IP-CIDR ... DIRECT 规则（见 override.yaml）。
post_once() {
  # shellcheck disable=SC2086
  curl -sS -X POST \
    --max-time "$REQ_TIMEOUT" \
    --noproxy '*' \
    -H 'Content-Type: application/json' \
    -w '\n%{http_code}' \
    $TLS_ARGS \
    "$1" 2>&1
}

# 只对传输层失败重试；服务端给了明确答复（含 403 槽位冲突）就不再试。
post_with_retry() {
  url="$1"
  attempt=1
  while :; do
    resp=$(post_once "$url")
    code=$(printf '%s' "$resp" | tail -n1)
    case "$code" in
      000) ;;                      # curl 连不上时也会打 000，这属于传输失败，要重试
      [0-9][0-9][0-9]) return 0 ;; # 拿到真实 HTTP 状态码，无论几百都算有答复
    esac
    [ "$attempt" -ge "$MAX_ATTEMPTS" ] && return 1
    sleep $((RETRY_BASE * attempt))
    attempt=$((attempt + 1))
  done
}

json_str() { # json_str <key>：从 stdin 取 "key":"value" 的 value
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 |
    sed 's/.*:[[:space:]]*"//; s/"$//'
}

ok_count=0
total=0
exit_ip="?"
changed=0
lines=""

# 分隔符兼容 , | ; 和空白；每段可带 @槽位 后缀
for item in $(printf '%s' "$TOKENS" | tr ',|;' '   '); do
  case "$item" in
    pgnfw_*) ;;
    *) continue ;;
  esac
  total=$((total + 1))
  idx=$total

  token="${item%%@*}"
  slot=""
  case "$item" in *@*) slot="${item#*@}" ;; esac

  url="$API_BASE/$token/add"
  [ -n "$slot" ] && url="$url?slot=$slot"

  pin_tag=""
  [ -n "$slot" ] && pin_tag=" 📌$slot"

  if ! post_with_retry "$url"; then
    err=$(printf '%s' "$resp" | head -1)
    lines="$lines
#$idx$pin_tag ❌ 请求失败: $err"
    log "#$idx$pin_tag 请求失败（已重试 $MAX_ATTEMPTS 次）: $err"
    continue
  fi

  code=$(printf '%s' "$resp" | tail -n1)
  body=$(printf '%s' "$resp" | sed '$d')
  current_ip=$(printf '%s' "$body" | json_str currentIp)
  [ -n "$current_ip" ] && exit_ip="$current_ip"

  if [ "$code" = "403" ]; then
    lines="$lines
#$idx$pin_tag ❌ 槽位冲突：本机 IP 已在其它槽位，请先去 UI 删除"
    log "#$idx$pin_tag 槽位冲突 (403)"
    applied=0
  elif [ "$code" != "200" ]; then
    lines="$lines
#$idx$pin_tag ❌ HTTP $code"
    log "#$idx$pin_tag HTTP $code: $(printf '%s' "$body" | head -c 120)"
    applied=0
  else
    # 服务端把 whitelist 和 currentIp 都归一化成 x.x.x.0/24。
    # currentIp 自己出现一次，若同时也在 whitelist 里则至少出现两次。
    enabled=$(printf '%s' "$body" | grep -c '"enabled"[[:space:]]*:[[:space:]]*true')
    hits=$(printf '%s' "$body" | grep -oF "\"$current_ip\"" | wc -l | tr -d ' ')
    if [ "$enabled" -ge 1 ] && [ "$hits" -ge 2 ]; then
      applied=1
      ok_count=$((ok_count + 1))
      lines="$lines
#$idx$pin_tag ✅ $current_ip"
    else
      applied=0
      lines="$lines
#$idx$pin_tag ❌ 加白未生效（防火墙未启用或写入失败）"
      log "#$idx$pin_tag 未生效: $(printf '%s' "$body" | head -c 160)"
    fi
  fi

  # 只在出口 IP 或加白状态变化时才吵，例行 cron 保持安静
  state_file="$STATE_DIR/state_$idx"
  new_state="${current_ip:-?}|$applied"
  old_state=$(cat "$state_file" 2>/dev/null || echo "")
  if [ "$new_state" != "$old_state" ]; then
    printf '%s' "$new_state" >"$state_file" 2>/dev/null || true
    changed=1
  fi
done

if [ "$total" = "0" ]; then
  log "❌ PO0FW_TOKENS 里没有合法的 pgnfw_ token"
  exit 2
fi

summary="po0 加白 $ok_count/$total · 出口 $exit_ip"
if [ "$changed" = "1" ] || [ "$ok_count" != "$total" ]; then
  log "$summary$lines"
fi
[ "$VERBOSE" = "1" ] && [ "$changed" = "0" ] && [ "$ok_count" = "$total" ] &&
  printf '%s%s\n' "$summary" "$lines"

[ "$ok_count" = "$total" ] && exit 0
exit 1
