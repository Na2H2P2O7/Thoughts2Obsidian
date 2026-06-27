---
name: suixiang
description: >
  随想记录员。把 Telegram 随想群（chat_id 在 config 中配置）里说的每一段文本，原样、
  增量追加保存为当日 Markdown（Thoughts/YYYY-MM-DD.md，每条带 HH:MM 时间戳，
  America/New_York 时区），硬写入 mac2016 的 FastNote 后端，并经 fast-note-sync
  同步到所有设备的 Obsidian vault；随后在群里回执。纯脚本实现、不调用 LLM；
  只有脚本写入失败时才回退到 DeepSeek V4 Pro 兜底 agent。复用 xyz skill 的
  FastNote 写入与回执机制。
---

# 随想记录员 (suixiang)

「随想记录员」唯一的职责是**忠实记录**：在 Telegram 随想群里说的任何一段话，
被原样、按时间顺序、绝不覆盖地追加到 Obsidian 的当日随想笔记，并回执。
**只记录，不发挥、不扩写、不评论、不回答。**

## 架构（与 xyz skill 同构）

```
Telegram 群 <YOUR_CHAT_ID> 「说一段话」
  → OpenClaw before_dispatch hook (suixiang-dispatcher)
       · 过滤 channel=telegram 且 conversationId=<YOUR_CHAT_ID>
       · 同步 spawnSync python3 append_thought.py "<原文>"（本地 sqlite 写，亚秒级）
  → append_thought.py
       · America/New_York 算 YYYY-MM-DD 与 HH:MM
       · 读当日笔记现有正文 → 追加 "\n\n**HH:MM**\n<原文>"（flock 串行化，防覆盖）
       · upsert_fast_note_markdown('Thoughts', 'YYYY-MM-DD', 全文)  ← 复用自 xyz
       · 打印 📣 RESULT status=success note_path=... note_id=... count=N hhmm=HH:MM
  → 成功 → dispatcher 群内回执 "✅ 已记录 HH:MM → Thoughts/YYYY-MM-DD.md（今日第 N 条）"
  → 失败 → dispatcher 返回未处理 → 路由到该群的 DeepSeek V4 Pro 兜底 agent（见 agent/AGENTS.md）
  → FastNote DB 写入 → fast-note-sync 同步到所有设备 Obsidian vault 的 Thoughts/
```

为什么 hard-write FastNote 而非直接写本机 vault：FastNote 后端 DB 在 mac2016
（`/opt/fast-note/...`），本机 Obsidian 通过 fast-note-sync 插件
（`http://<FAST_NOTE_SERVER_HOST>:9000`）从它**同步下来**。写 FastNote = 一处写、多设备同步。

## 文件

| 路径 | 作用 | 部署到 mac2016 |
|---|---|---|
| `scripts/append_thought.py` | 核心：读现有→追加→upsert→打印 RESULT | `~/.openclaw/workspace/skills/suixiang/scripts/` |
| `scripts/run_profile.sh` | CLI 包装 + Telegram 回执（手动/兜底用） | 同上 |
| `extensions/suixiang-dispatcher/` | before_dispatch hook + 回执/回退 | `~/.openclaw/extensions/suixiang-dispatcher/` |
| `profiles/default/config.env` | chat_id / 文件夹 / 时区 | `~/.openclaw/workspace/projects/suixiang/profiles/default/` |
| `agent/AGENTS.md` | 兜底 agent 指令 | `~/.openclaw/workspace-suixiang/AGENTS.md` |
| `agent/models.json` | 兜底 agent agentDir | `~/.openclaw/agents/suixiang/agent/models.json` |
| `deploy.sh` | rsync + patch openclaw.json + 重启 gateway | 在本机运行 |

## 复用来源（mac2016 `~/.openclaw/workspace/skills/xyz/scripts/xiaoyuzhou_dl.py`）

`upsert_fast_note_markdown` / `ensure_fast_note_folder` / `java_string_hash` /
`sanitize_filename` / `backup_file_once` 及 FastNote DB 常量，均逐行复制进
`append_thought.py`（避免导入 223KB 的播客流水线），仅新增「读现有正文」与「美东时区/追加」逻辑。
Telegram 回执沿用 `openclaw message send --channel telegram --target <id> --message <text>`。

## 记录规则

- 文件夹固定 `Thoughts/`；当日文件 `YYYY-MM-DD.md`。
- 同日多条增量追加到文件末尾，**绝不覆盖**。
- 每条格式：`**HH:MM**` 加粗时间戳行 + 换行后的原文。
- 时区 `America/New_York`（决定日期切换与 HH:MM）。
- 空/非文本消息：静默跳过（不记录、不回执）。

## OpenClaw 接线（由 deploy.sh 写入 openclaw.json）

- `plugins.allow` 追加 `"suixiang-dispatcher"`。
- `plugins.entries["suixiang-dispatcher"] = {enabled:true, config:{telegramGroupId,appendScript,logDir,folder,tz}, hooks:{allowConversationAccess:true}}`。
- `agents.list` 追加 `suixiang`（model.primary=`deepseek/deepseek-v4-pro`）；
  `bindings` 为群 `<YOUR_CHAT_ID>` 的各 id 变体绑定到 `suixiang`。
- 重启 gateway：`launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway`。

## 验证

见 `deploy.sh` 末尾与项目计划：直跑脚本验 DB → 验本机 Obsidian 下行同步 →
重启后 Telegram 实测回执 → 故障回退验证。
