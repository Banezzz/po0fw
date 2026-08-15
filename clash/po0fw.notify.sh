# 系统通知。由 po0fw.sh source，不要单独跑。
#
# 默认 change：跟 Shadowrocket / Surge 模块同一套逻辑——
# 只在出口 IP 或加白状态较上次变化时弹，例行定时上报保持安静；
# 没配 token 这类配置错误也会弹。
#
# 后端按环境自动选：
#   Android/Termux  termux-notification（要装 termux-api，并给 Termux:API 通知权限）
#   macOS           osascript
#   Linux 桌面      notify-send（有就用）
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

  title="po0 防火墙加白"
  subtitle=$(printf '%s' "$subtitle" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
  body=$(printf '%s' "$body" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$subtitle" ] || subtitle="$title"
  content="$subtitle"
  [ -n "$body" ] && content="$subtitle
$body"

  # Termux：Android 通知栏。id 固定，后一次盖前一次，避免刷一堆。
  if command -v termux-notification >/dev/null 2>&1; then
    if [ -n "$body" ]; then
      termux-notification --id po0fw --title "$title" --content "$content" >/dev/null 2>&1 || true
    else
      termux-notification --id po0fw --title "$title" --content "$subtitle" >/dev/null 2>&1 || true
    fi
    return 0
  fi

  if [ -x /usr/bin/osascript ]; then
    sound="Basso"
    [ "$status" = "ok" ] && sound="Glass"
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
    return 0
  fi

  if command -v notify-send >/dev/null 2>&1; then
    notify-send --app-name=po0fw "$title" "$content" >/dev/null 2>&1 || true
  fi
}
