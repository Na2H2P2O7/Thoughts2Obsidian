#!/bin/bash
# 安装 Telegram 自愈看门狗到目标机（launchd 用户 agent，纯脚本）。幂等。
#
# 用法:  ./install-watchdog.sh            # 安装/更新 + 加载 + 立即跑一次
#        SUIXIANG_SSH_HOST=xxx ./install-watchdog.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_HOST="${SUIXIANG_SSH_HOST:-mac2016}"
LABEL="com.suixiang.telegram-watchdog"
INTERVAL="${WATCHDOG_INTERVAL:-600}"

echo "==> 目标: $SSH_HOST"
ssh "$SSH_HOST" "mkdir -p .openclaw/ops/state .openclaw/logs Library/LaunchAgents"

echo "==> 同步 watchdog 脚本"
rsync -a "$HERE/telegram_watchdog.sh" "$SSH_HOST:.openclaw/ops/telegram_watchdog.sh"
ssh "$SSH_HOST" "chmod +x .openclaw/ops/telegram_watchdog.sh"

echo "==> 生成 plist（用远端 \$HOME）并加载"
ssh "$SSH_HOST" "bash -s" <<REMOTE
set -euo pipefail
HOME_DIR="\$HOME"
UID_N="\$(id -u)"
PLIST="\$HOME_DIR/Library/LaunchAgents/${LABEL}.plist"
cat > "\$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>\$HOME_DIR/.openclaw/ops/telegram_watchdog.sh</string>
  </array>
  <key>StartInterval</key><integer>${INTERVAL}</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>\$HOME_DIR/.openclaw/logs/telegram-watchdog.out.log</string>
  <key>StandardErrorPath</key><string>\$HOME_DIR/.openclaw/logs/telegram-watchdog.err.log</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
</dict>
</plist>
PLISTEOF
launchctl bootout "gui/\$UID_N/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/\$UID_N" "\$PLIST"
launchctl kickstart "gui/\$UID_N/${LABEL}"
echo "  loaded: \$(launchctl print gui/\$UID_N/${LABEL} 2>/dev/null | grep -E 'state =' | head -1 | tr -d '\t')"
REMOTE

echo "==> 完成。日志: ~/.openclaw/logs/telegram-watchdog.log"
