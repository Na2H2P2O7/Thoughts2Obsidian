#!/bin/bash
# 随想记录员 · run_profile.sh
# CLI 包装：记录一条随想并（可选）向 Telegram 群发回执。
# 供手动测试与「fallback agent」补记使用。日常路径由 dispatcher 直接调用
# append_thought.py（同步、无需 bash 包装）。
#
# 用法:
#   run_profile.sh --message "随想内容"
#   run_profile.sh "随想内容"
#   run_profile.sh --message "随想内容" --no-notify
set -euo pipefail

# 确保能找到 node / openclaw（非交互 shell 的 PATH 可能不含 /usr/local/bin）
export PATH="/usr/local/bin:$PATH"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 载入 profile 配置（若存在）
CFG="${SUIXIANG_CONFIG:-$HOME/.openclaw/workspace/projects/suixiang/profiles/default/config.env}"
if [ -f "$CFG" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$CFG"
  set +a
fi

MESSAGE=""
NOTIFY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --message) MESSAGE="$2"; shift 2;;
    --no-notify) NOTIFY=0; shift;;
    *) MESSAGE="$1"; shift;;
  esac
done

PY="${PYTHON:-python3}"
APPEND_SCRIPT="${APPEND_SCRIPT:-$HERE/append_thought.py}"

out="$("$PY" "$APPEND_SCRIPT" "$MESSAGE" 2>&1)" || true
code=$?
printf '%s\n' "$out"

result_line="$(printf '%s\n' "$out" | grep '📣 RESULT' | tail -1 || true)"
status="$(printf '%s' "$result_line" | sed -nE 's/.*status=([^ ]+).*/\1/p')"

if [ "$NOTIFY" = "1" ] && [ -n "${SUIXIANG_CHAT_ID:-}" ]; then
  if [ "$status" = "success" ]; then
    count="$(printf '%s' "$result_line" | sed -nE 's/.*count=([^ ]+).*/\1/p')"
    date="$(printf '%s' "$result_line" | sed -nE 's/.* date=([^ ]+).*/\1/p')"
    hhmm="$(printf '%s' "$result_line" | sed -nE 's/.*hhmm=([^ ]+).*/\1/p')"
    openclaw message send --channel telegram --target "$SUIXIANG_CHAT_ID" \
      --message "$(printf '✅ 随想已记录（今日第 %s 条）\n🕐 %s %s' "$count" "$date" "$hhmm")" || true
  elif [ "$status" != "skipped" ]; then
    openclaw message send --channel telegram --target "$SUIXIANG_CHAT_ID" \
      --message "⚠️ 随想记录脚本失败。RESULT: ${result_line:-<no result>}" || true
  fi
fi

exit "$code"
