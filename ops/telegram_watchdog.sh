#!/bin/bash
# Telegram / OpenClaw 自愈看门狗（纯脚本，无 LLM agent 介入）
#
# 两类故障自愈：
#   A) 进程堆积：某处泄漏子进程（实测是 NotebookLM 拉起的 Chrome 会话没退干净）
#      堆到逼近 per-uid 进程上限 → 任何新进程 fork 失败 → dispatcher 起不了
#      append/回执子进程、SSH 也开不了 shell。→ 进程数逼近上限就 kick 网关回收其子孙。
#   B) Telegram 通道卡死：到 api.telegram.org 网络抖动后通道 stopped/disconnected，
#      自带 health-monitor 的重启 "channel stop timed out after 5000ms" 恢复失败。
#      → 通道不健康 + 网络已可达 + 过冷却 → kick 网关。
#
# 关键：A 用最便宜的 ps|wc 且**先于**一切 openclaw/curl 调用检查，并在耗尽前
# （默认 per-uid 上限的 70%）就触发，给看门狗自己留足 fork 余量——否则进程真顶死
# 时看门狗自己也 fork 不出子命令，无法自救（这正是旧版失效的原因）。
#
# 防抖 / 防风暴：连续 FAIL_THRESHOLD 次通道不健康才动手；kick 后 COOLDOWN 冷却；
# 通道故障时网络不可达则不 kick（重启无用）。
#
# 测试钩子（不影响生产）：
#   WATCHDOG_FAKE_STATUS="<telegram 状态行>"   替代真实 openclaw 查询
#   WATCHDOG_FAKE_PROC=<n>                      替代真实进程计数
#   WATCHDOG_DRY_RUN=1                          只记 "WOULD kick"，不真重启
#
# 注意：所有紧邻中文标点的变量都用 ${var} 花括号——裸 $var 后跟 CJK 字节会让
# set -u 误判变量名报 "unbound variable" 并中止脚本（踩过两次）。

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

# 统一的 kick：冷却门控 + dry-run 感知 + 重启 + 计数复位
do_kick() {
  reason="$1"
  last_kick="$(cat "$LASTKICK_FILE" 2>/dev/null || echo 0)"
  if [ $(( now - last_kick )) -lt "$COOLDOWN" ]; then
    log "SKIP 冷却中（${reason}；距上次 kick $(( now - last_kick ))s < ${COOLDOWN}s）"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN WOULD kickstart gateway（${reason}）"
    echo "$now" > "$LASTKICK_FILE"; echo 0 > "$COUNT_FILE"; return 0
  fi
  log "ACTION ${reason} → kickstart ai.openclaw.gateway"
  if launchctl kickstart -k "gui/$(id -u)/ai.openclaw.gateway" >> "$LOG" 2>&1; then
    echo "$now" > "$LASTKICK_FILE"; echo 0 > "$COUNT_FILE"; log "KICKED gateway ok"
  else
    log "ERROR kickstart 失败"
  fi
}

# ============ A) 进程数闸（最先、最便宜、最鲁棒）============
PROC_CAP="$(sysctl -n kern.maxprocperuid 2>/dev/null || echo 0)"
PROC_MAX="${WATCHDOG_PROC_MAX:-0}"
if [ "$PROC_MAX" -eq 0 ] 2>/dev/null && [ "$PROC_CAP" -gt 0 ] 2>/dev/null; then
  PROC_MAX=$(( PROC_CAP * 70 / 100 ))   # 默认上限的 70%，留足 fork 余量
fi
if [ -n "${WATCHDOG_FAKE_PROC:-}" ]; then
  proc_count="$WATCHDOG_FAKE_PROC"
else
  proc_count="$(ps -U "$(id -un)" -o pid= 2>/dev/null | wc -l | tr -d ' ')"
fi
if [ "${PROC_MAX:-0}" -gt 0 ] 2>/dev/null && [ "${proc_count:-0}" -ge "$PROC_MAX" ] 2>/dev/null; then
  log "PROC-PILEUP proc_count=${proc_count} >= ${PROC_MAX}（cap ${PROC_CAP}）→ 回收泄漏子进程"
  do_kick "进程堆积 proc_count=${proc_count}/${PROC_CAP}"
  exit 0
fi

# ============ B) Telegram 通道健康 ============
# 读取通道状态（no --probe：用 gateway 缓存视角，网络中断时也不会阻塞）
if [ -n "${WATCHDOG_FAKE_STATUS:-}" ]; then
  status_line="$WATCHDOG_FAKE_STATUS"
else
  status_line="$(openclaw channels status 2>/dev/null | grep -i 'Telegram' | head -1)"
fi

# 健康 = 同时有 running 且 connected，且不含 stopped/disconnected/not-running
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

# 不健康：累计连续计数
count=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$count" > "$COUNT_FILE"
log "UNHEALTHY telegram (count=${count}/${FAIL_THRESHOLD}) line=[${status_line:-<empty: gateway unreachable?>}]"
[ "$count" -lt "$FAIL_THRESHOLD" ] && exit 0

# 网络可达性：不可达则不 kick（重启无用，等网络恢复）
# curl 连接失败/超时时自身就输出 http_code=000（不要再 || echo 000，否则拼成 000000）
net_code="$(curl -s -o /dev/null -m "$NET_TIMEOUT" -w '%{http_code}' "$NET_URL" 2>/dev/null)"
net_code="${net_code:-000}"
if ! echo "${net_code}" | grep -qE '^[1-5][0-9][0-9]$'; then   # 可达 = 真实 1xx–5xx
  log "SKIP api.telegram.org unreachable (net_code=${net_code}) → 不重启，等网络恢复"
  exit 0
fi

do_kick "telegram 不健康 + 网络可达(net_code=${net_code})"
exit 0
