import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { spawn, spawnSync } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

// 随想记录员 dispatcher
// 在指定 Telegram 群里说的「每一段文本」都被同步写入当日 FastNote 笔记，
// 并以群内回复作为回执。纯脚本路径不调用任何 LLM；只有脚本写入失败时，
// 才返回「未处理」让 OpenClaw 路由到该群绑定的 DeepSeek V4 Pro 兜底 agent。

const HOME = process.env.HOME || "";
// 真实 chat_id 由 openclaw.json 的 pluginConfig.telegramGroupId 提供；
// 默认留空 → 未配置时 dispatcher 不拦截任何会话（安全默认）。
const DEFAULT_GROUP_ID = "";
const DEFAULT_APPEND_SCRIPT = `${HOME}/.openclaw/workspace/skills/suixiang/scripts/append_thought.py`;
const DEFAULT_LOG_DIR = `${HOME}/.openclaw/workspace/projects/suixiang/logs`;
const DEFAULT_PYTHON = "python3";
const DEFAULT_FOLDER = "Thoughts";
const DEFAULT_TZ = "America/New_York";
// 用绝对路径调用 openclaw CLI，避免依赖 PATH（gateway 子进程 PATH 不一定含 /usr/local/bin）
const DEFAULT_NODE = "/usr/local/bin/node";
const DEFAULT_OPENCLAW_CLI = "/usr/local/lib/node_modules/openclaw/openclaw.mjs";
const RECEIPT_PREFIX = "✅ 随想已记录";
const ERROR_PREFIX = "⚠️";

function cfg(pluginConfig = {}) {
  return {
    telegramGroupId: String(pluginConfig.telegramGroupId || DEFAULT_GROUP_ID),
    appendScript: String(pluginConfig.appendScript || DEFAULT_APPEND_SCRIPT),
    python: String(pluginConfig.python || DEFAULT_PYTHON),
    logDir: String(pluginConfig.logDir || DEFAULT_LOG_DIR),
    folder: String(pluginConfig.folder || DEFAULT_FOLDER),
    tz: String(pluginConfig.tz || DEFAULT_TZ),
    node: String(pluginConfig.node || DEFAULT_NODE),
    openclawCli: String(pluginConfig.openclawCli || DEFAULT_OPENCLAW_CLI),
  };
}

function appendLog(logPath, line) {
  try {
    mkdirSync(dirname(logPath), { recursive: true });
    appendFileSync(logPath, `${new Date().toISOString()} ${line}\n`, "utf8");
  } catch {
    // 不要因为诊断日志失败而影响消息处理
  }
}

function field(line, key) {
  const m = line.match(new RegExp(`${key}=([^\\s]+)`));
  return m ? m[1] : "";
}

// 主动发送 Telegram 回执（fire-and-forget）。before_dispatch 的返回 text 在本环境
// 不会真正投递成 Telegram 消息，必须用 openclaw CLI 显式发送——与 xyz 的回执一致。
function sendReceipt(options, target, message, logPath) {
  try {
    const child = spawn(
      options.node,
      [options.openclawCli, "message", "send", "--channel", "telegram", "--target", target, "--message", message],
      { detached: true, stdio: "ignore", env: { ...process.env } },
    );
    child.unref();
  } catch (error) {
    appendLog(logPath, `receipt-send-error ${error?.message || String(error)}`);
  }
}

export default definePluginEntry({
  id: "suixiang-dispatcher",
  name: "随想记录员 Dispatcher",
  description:
    "Records every plain-text message in the configured Telegram group to a daily FastNote markdown note; falls back to the DeepSeek agent only on script failure.",
  register(api) {
    api.on(
      "before_dispatch",
      async (event, ctx) => {
        const options = cfg(api.pluginConfig);
        const channel = String(event.channel || ctx?.channelId || "").toLowerCase();
        const conversationId = String(ctx?.conversationId || "");
        if (channel !== "telegram" || conversationId !== options.telegramGroupId) return;

        // 只取其一：event.content 与 event.body 往往是同一段文本，join 会写两遍
        const text = String(event.content || event.body || "").trim();
        if (!text) return; // 非文本/空消息：不拦截，按正常流程处理
        // 防自环：忽略本插件/兜底 agent 自己发出的回执
        if (text.startsWith(RECEIPT_PREFIX) || text.startsWith(ERROR_PREFIX)) {
          return { handled: true };
        }

        const dispatchLog = `${options.logDir}/suixiang-dispatcher.log`;

        let res;
        try {
          res = spawnSync(options.python, [options.appendScript, text], {
            encoding: "utf8",
            timeout: 4000,
            maxBuffer: 4 * 1024 * 1024,
            env: {
              ...process.env,
              SUIXIANG_FOLDER: options.folder,
              SUIXIANG_TZ: options.tz,
              FAST_NOTE_ENABLE_SQLITE_BACKUP: "1",
            },
          });
        } catch (error) {
          appendLog(dispatchLog, `spawn-error ${error?.message || String(error)}`);
          return; // 兜底：交给 DeepSeek V4 Pro agent
        }

        const out = `${res.stdout || ""}${res.stderr || ""}`;
        const resultLine =
          out.split(/\r?\n/).filter((l) => l.includes("📣 RESULT")).pop() || "";
        const status = field(resultLine, "status");
        appendLog(
          dispatchLog,
          `conversation=${conversationId} exit=${res.status} status=${status} line=${resultLine.replace(/\n/g, " ")}`,
        );

        if (res.status === 0 && status === "success") {
          const count = field(resultLine, "count");
          const date = field(resultLine, "date");
          const hhmm = field(resultLine, "hhmm");
          const receipt = `${RECEIPT_PREFIX}（今日第 ${count} 条）\n🕐 ${date} ${hhmm}`;
          sendReceipt(options, options.telegramGroupId, receipt, dispatchLog);
          return { handled: true };
        }

        if (status === "skipped") return { handled: true }; // 空内容：静默不回执

        // 脚本失败：返回未处理 → OpenClaw 路由到该群的 DeepSeek V4 Pro 兜底 agent
        return;
      },
      { priority: 100, timeoutMs: 5000 },
    );
  },
});
