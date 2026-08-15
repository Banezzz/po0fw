# macOS 系统通知。由 po0fw.sh source，不要单独跑。
# Linux / Android / 没装 osascript 的环境会在入口处直接 return。
#
# PO0FW_NOTIFY:
#   always  每次执行都弹（成功 / 失败）
#   fail    只在失败时弹
#   change  出口 IP 或加白状态变了才弹（失败也弹）
#   off     关（默认）

po0fw_notify() {
  status="$1"
  body="$2"

  case "${PO0FW_NOTIFY:-off}" in
    1 | true | yes | on | always) ;;
    fail)
      [ "$status" = "ok" ] && return 0
      ;;
    change)
      [ "${changed:-0}" = "1" ] || [ "$status" != "ok" ] || return 0
      ;;
    *) return 0 ;;
  esac

  [ -x /usr/bin/osascript ] || return 0

  case "$status" in
    ok)
      title="po0 加白成功"
      sound="Glass"
      ;;
    *)
      title="po0 加白失败"
      sound="Basso"
      ;;
  esac

  body=$(printf '%s' "$body" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
  [ -n "$body" ] || body="$title"

  /usr/bin/osascript - "$title" "$body" "$sound" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display notification (item 2 of argv) with title (item 1 of argv) sound name (item 3 of argv)
end run
APPLESCRIPT
}
