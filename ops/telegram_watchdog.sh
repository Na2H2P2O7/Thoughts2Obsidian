#!/bin/bash
# Telegram 通道自愈看门狗（纯脚本，无 LLM agent 介入）
#
# 背景：mac2016 到 api.telegram.org 会间歇性网络中断。抖动时 OpenClaw 的 Telegram
# 通道可能卡死成 stopped/disconnected，而自带 health-monitor 的自动重启会
# "channel stop timed out after 5000ms" 恢复失败 → 跟 bot 说话没有龙虾表情、
# 所有 telegram dispatcher 停摆（但 launchd 后台任务照常）。
#
# 本脚本由 launchd 每 ~3 分钟跑一次：发现 Telegram 通道不健康、且网络已可达、
# 且不在冷却期时，kickstart 重启 gateway（这是已验证能恢复 telegram 的方式）。
#
# 防抖 / 防风暴：
#   - 需连续 FAIL_THRESHOLD 次不健康才动手（避开重启瞬间的过渡态）
#   - 距上次 kick 不足 COOLDOWN 秒则跳过（给 gateway 充分时间起来）
#   - 网络不可达则不 kick（重启也没用，等网络恢复）
#
# 测试钩子（不影响生产）：
#   WATCHDOG_FAKE_STATUS="<telegram 状态行>"  用它替代真实 openclaw 查询
#   WATCHDOG_DRY_RUN=1                         只记录 "WOULD kick"，不真的重启

set -u
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

FAIL_THRESHOLD="${WATCHDOG_FAIL_THRESHOLD:-2}"
COOLDOWN="${WATCHDOG_COOLDOWN:-600}"
NET_TIMEOUT="${WATCHDOG_NET_TIMEOUT:-8}"
NET_URL="${WATCHDOG_NET_URL:-https://api.telegram.org/}"
DRY_RUN="${WATCHDOG_DRY_RUN:-0}"

STATE_DIR="$HOME/.openclaw/ops/state"
COUNT_FILE="$STATE_DIR/tg_unhealthy_count"
LASTKICK_FILE="$STATE_DIR/tg_last_kick_epoch"
LOG="$HOME/.openclaw/logs/telegram-watchdog.log"
mkdir -p "$STATE_DIR" "$(dirname "$LOG")"

now="$(date +%s)"
log() { echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$LOG"; }

# 1) 读取 Telegram 通道状态（no --probe：用 gateway 缓存视角，网络中断时也不会阻塞）
if [ -n "${WATCHDOG_FAKE_STATUS:-}" ]; then
  status_line="$WATCHDOG_FAKE_STATUS"
else
  status_line="$(openclaw channels status 2>/dev/null | grep -i 'Telegram' | head -1)"
fi

# 2) 判定健康：必须同时有 running 且 connected，且不含 stopped/disconnected/not-running
healthy=0
if [ -n "$status_line" ] \
   && echo "$status_line" | grep -qiE 'running' \
   && echo "$status_line" | grep -qiE 'connected' \
   && ! echo "$status_line" | grep -qiE 'disconnected|not-running|stopped'; then
  healthy=1
fi

if [ "$healthy" = "1" ]; then
  echo 0 > "$COUNT_FILE"
  exit 0
fi

# 3) 不健康：累计连续计数
count=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$count" > "$COUNT_FILE"
log "UNHEALTHY telegram (count=$count/$FAIL_THRESHOLD) line=[${status_line:-<empty: gateway unreachable?>}]"
[ "$count" -lt "$FAIL_THRESHOLD" ] && exit 0

# 4) 网络可达性：不可达则不 kick（重启无用，等网络恢复）
# curl 在连接失败/超时时自身就输出 http_code=000（不要再 || echo 000，否则拼成 000000）
net_code="$(curl -s -o /dev/null -m "$NET_TIMEOUT" -w '%{http_code}' "$NET_URL" 2>/dev/null)"
net_code="${net_code:-000}"
# 可达 = 真实 HTTP 状态码 1xx–5xx；其余（000/空/异常）视为不可达
if ! echo "${net_code}" | grep -qE '^[1-5][0-9][0-9]$'; then
  log "SKIP api.telegram.org unreachable (net_code=${net_code}) → 不重启，等网络恢复"
  exit 0
fi

# 5) 冷却期
last_kick="$(cat "$LASTKICK_FILE" 2>/dev/null || echo 0)"
if [ $(( now - last_kick )) -lt "$COOLDOWN" ]; then
  log "SKIP 冷却中（距上次 kick $(( now - last_kick ))s < ${COOLDOWN}s）"
  exit 0
fi

# 6) 动手：重启 gateway
if [ "$DRY_RUN" = "1" ]; then
  log "DRY-RUN WOULD kickstart gateway（telegram 不健康 + 网络可达 net_code=${net_code}）"
  echo "$now" > "$LASTKICK_FILE"
  echo 0 > "$COUNT_FILE"
  exit 0
fi

log "ACTION telegram 不健康 + 网络可达(net_code=${net_code}) → kickstart ai.openclaw.gateway"
if launchctl kickstart -k "gui/$(id -u)/ai.openclaw.gateway" >> "$LOG" 2>&1; then
  echo "$now" > "$LASTKICK_FILE"
  echo 0 > "$COUNT_FILE"
  log "KICKED gateway ok"
else
  log "ERROR kickstart 失败（rc=$?）"
fi
exit 0
