# macOS 系统通知。由 po0fw.sh source，不要单独跑。
# Linux / Android / 没装 osascript 的环境会在入口处直接 return。
#
# 默认 change：跟 Shadowrocket / Surge 模块同一套逻辑——
# 只在出口 IP 或加白状态较上次变化时弹，例行 10 分钟上报保持安静；
# 没配 token 这类配置错误也会弹。
#
# PO0FW_NOTIFY:
#   change  出口 IP / 加白状态变了才弹；配置错误也弹（默认）
#   always  每次执行都弹（成功 / 失败）
#   fail    只在失败时弹
#   off     关

po0fw_notify() {
  status="$1"
  subtitle="$2"
  body="${3:-}"

  case "${PO0FW_NOTIFY:-change}" in
    1 | true | yes | on | always) ;;
    fail)
      [ "$status" = "ok" ] && return 0
      ;;
    change)
      # 与 scripts/po0-firewall-whitelist.js 的 report() 对齐：
      #   if (changed) notify(...)
      # 没配 token 等走不到 state 比较的路径，单独用 error 放行。
      if [ "$status" = "error" ]; then
        :
      elif [ "${changed:-0}" != "1" ]; then
        return 0
      fi
      ;;
    *) return 0 ;;
  esac

  [ -x /usr/bin/osascript ] || return 0

  title="po0 防火墙加白"
  case "$status" in
    ok) sound="Glass" ;;
    *) sound="Basso" ;;
  esac

  subtitle=$(printf '%s' "$subtitle" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
  body=$(printf '%s' "$body" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$subtitle" ] || subtitle="$title"

  /usr/bin/osascript - "$title" "$subtitle" "$body" "$sound" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set notifTitle to item 1 of argv
  set notifSubtitle to item 2 of argv
  set notifBody to item 3 of argv
  set notifSound to item 4 of argv
  if notifBody is "" then
    display notification notifSubtitle with title notifTitle sound name notifSound
  else
    display notification notifBody with title notifTitle subtitle notifSubtitle sound name notifSound
  end if
end run
APPLESCRIPT
}
