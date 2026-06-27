#!/bin/bash
# 随想记录员 · deploy.sh
# 从本机把 skill 部署到目标机（运行 OpenClaw + FastNote 后端的那台），
# 并接线 OpenClaw（plugin + 兜底 agent + bindings），然后重启 gateway。幂等：可重复运行。
#
# 准备:
#   cp profiles/default/config.env.example profiles/default/config.env  # 填入你的 chat_id 等
#   export SUIXIANG_SSH_HOST=<你的 ssh 别名>                            # 默认 mac2016
#
# 用法:
#   ./deploy.sh                # 部署 + 接线 + 重启 gateway
#   ./deploy.sh --no-restart   # 部署 + 接线，不重启
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_HOST="${SUIXIANG_SSH_HOST:-mac2016}"
CFG="$HERE/profiles/default/config.env"
RESTART=1
[ "${1:-}" = "--no-restart" ] && RESTART=0

if [ ! -f "$CFG" ]; then
  echo "缺少 $CFG" >&2
  echo "请先: cp profiles/default/config.env.example profiles/default/config.env 并填入你的值" >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "$CFG"; set +a
: "${SUIXIANG_CHAT_ID:?config.env 缺少 SUIXIANG_CHAT_ID}"
SUIXIANG_FOLDER="${SUIXIANG_FOLDER:-Thoughts}"
SUIXIANG_TZ="${SUIXIANG_TZ:-America/New_York}"

REMOTE_HOME="$(ssh "$SSH_HOST" 'echo $HOME')"
echo "==> 目标: $SSH_HOST ($REMOTE_HOME)  群: $SUIXIANG_CHAT_ID"

# 远端路径（相对 home，供 rsync 用）
R_SKILL=".openclaw/workspace/skills/suixiang"
R_EXT=".openclaw/extensions/suixiang-dispatcher"
R_PROJ=".openclaw/workspace/projects/suixiang"
R_WS=".openclaw/workspace-suixiang"
R_AGENTDIR=".openclaw/agents/suixiang/agent"

echo "==> 创建远端目录"
ssh "$SSH_HOST" "mkdir -p \
  $R_SKILL/scripts \
  $R_EXT \
  $R_PROJ/profiles/default $R_PROJ/logs \
  $R_WS \
  $R_AGENTDIR"

echo "==> 同步文件"
rsync -a "$HERE/scripts/" "$SSH_HOST:$R_SKILL/scripts/"
rsync -a "$HERE/SKILL.md" "$SSH_HOST:$R_SKILL/SKILL.md"
rsync -a "$HERE/extensions/suixiang-dispatcher/" "$SSH_HOST:$R_EXT/"
rsync -a "$CFG" "$SSH_HOST:$R_PROJ/profiles/default/config.env"
rsync -a "$HERE/agent/AGENTS.md" "$SSH_HOST:$R_WS/AGENTS.md"
rsync -a "$HERE/agent/models.json" "$SSH_HOST:$R_AGENTDIR/models.json"

echo "==> 赋可执行权限"
ssh "$SSH_HOST" "chmod +x $R_SKILL/scripts/append_thought.py $R_SKILL/scripts/run_profile.sh"

echo "==> 接线 openclaw.json（备份 + 幂等 patch）"
ssh "$SSH_HOST" "SUIXIANG_CHAT_ID='$SUIXIANG_CHAT_ID' SUIXIANG_FOLDER='$SUIXIANG_FOLDER' SUIXIANG_TZ='$SUIXIANG_TZ' python3 - <<'PY'
import json, os, shutil, time
home = os.path.expanduser('~')
cfg_path = os.path.join(home, '.openclaw', 'openclaw.json')
backup = cfg_path + '.bak-suixiang-' + time.strftime('%Y%m%d-%H%M%S')
shutil.copy2(cfg_path, backup)
print('  backup:', backup)

with open(cfg_path, encoding='utf-8') as f:
    d = json.load(f)

APPEND = os.path.join(home, '.openclaw/workspace/skills/suixiang/scripts/append_thought.py')
LOGDIR = os.path.join(home, '.openclaw/workspace/projects/suixiang/logs')
WS = os.path.join(home, '.openclaw/workspace-suixiang')
AGENTDIR = os.path.join(home, '.openclaw/agents/suixiang/agent')
GROUP = os.environ['SUIXIANG_CHAT_ID']
FOLDER = os.environ.get('SUIXIANG_FOLDER', 'Thoughts')
TZ = os.environ.get('SUIXIANG_TZ', 'America/New_York')

# --- plugins ---
plugins = d.setdefault('plugins', {})
allow = plugins.setdefault('allow', [])
if 'suixiang-dispatcher' not in allow:
    allow.append('suixiang-dispatcher')
entries = plugins.setdefault('entries', {})
entries['suixiang-dispatcher'] = {
    'enabled': True,
    'config': {
        'telegramGroupId': GROUP,
        'appendScript': APPEND,
        'logDir': LOGDIR,
        'folder': FOLDER,
        'tz': TZ,
    },
    'hooks': {'allowConversationAccess': True},
}

# --- agents.list (fallback agent) ---
agents = d.setdefault('agents', {})
alist = agents.setdefault('list', [])
agent_entry = {
    'id': 'suixiang',
    'default': False,
    'name': '随想记录员',
    'workspace': WS,
    'agentDir': AGENTDIR,
    'model': {'primary': 'deepseek/deepseek-v4-pro', 'fallbacks': ['zai/glm-4.6']},
    'identity': {'name': '随想记录员', 'emoji': '📝'},
    'thinkingDefault': 'off',
}
alist[:] = [a for a in alist if a.get('id') != 'suixiang'] + [agent_entry]

# --- bindings (group id variants) ---
binds = d.setdefault('bindings', [])
def has_bind(gid):
    for b in binds:
        m = b.get('match', {})
        if m.get('channel') == 'telegram' and m.get('peer', {}).get('id') == gid:
            return True
    return False
for gid in (GROUP, GROUP.lstrip('-'), 'telegram:' + GROUP):
    if not has_bind(gid):
        binds.append({'agentId': 'suixiang', 'match': {'channel': 'telegram', 'peer': {'kind': 'group', 'id': gid}}})

tmp = cfg_path + '.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
with open(tmp, encoding='utf-8') as f:
    json.load(f)  # 校验可重新解析
os.replace(tmp, cfg_path)
print('  patched: plugins.allow/entries, agents.list[suixiang], bindings x3')
PY"

if [ "$RESTART" = "1" ]; then
  echo "==> 重启 gateway"
  ssh "$SSH_HOST" "launchctl kickstart -k gui/\$(id -u)/ai.openclaw.gateway" || \
    echo "  (kickstart 失败，可手动: launchctl kickstart -k gui/\$(id -u)/ai.openclaw.gateway)"
else
  echo "==> 跳过重启（--no-restart）。需手动: ssh $SSH_HOST 'launchctl kickstart -k gui/\$(id -u)/ai.openclaw.gateway'"
fi

echo "==> 完成。"
echo "    自检: ssh $SSH_HOST \"python3 $REMOTE_HOME/.openclaw/workspace/skills/suixiang/scripts/append_thought.py '测试随想'\""
