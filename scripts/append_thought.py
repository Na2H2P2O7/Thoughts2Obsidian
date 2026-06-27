#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""随想记录员 · append_thought.py

把一段随想「原样」追加到当日 Markdown（Thoughts/YYYY-MM-DD.md），硬写入 FastNote，
随后由 fast-note-sync 同步到所有设备的 Obsidian vault。

设计原则：
  - 只记录，绝不发挥/扩写/评论/回答。逐字保存。
  - 纯脚本，不调用任何 LLM。
  - 同一天多条按时间顺序「增量追加」，绝不覆盖。
  - 每条前加 HH:MM 时间戳（默认 America/New_York 时区）。

FastNote 写入逻辑逐行复用自 mac2016 上 xyz skill 的
`~/.openclaw/workspace/skills/xyz/scripts/xiaoyuzhou_dl.py`
（upsert_fast_note_markdown / ensure_fast_note_folder / java_string_hash /
  sanitize_filename / backup_file_once，及 FastNote DB 常量 L2384-2395）。

用法:
    python3 append_thought.py "今天想到一个点子……"
    echo "随想内容" | python3 append_thought.py -

输出最后一行为机读回执:
    📣 RESULT status=success note_path=Thoughts/2026-06-26.md note_id=123 count=2 hhmm=14:32
    📣 RESULT status=skipped reason=empty
    📣 RESULT status=failed reason="..."
"""

import os
import re
import sys
import time
import json
import shutil
import sqlite3
import fcntl
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
from typing import Optional

# ---- 可配置项（环境变量覆盖）----
THOUGHTS_FOLDER = os.environ.get("SUIXIANG_FOLDER", "Thoughts")
TZ = ZoneInfo(os.environ.get("SUIXIANG_TZ", "America/New_York"))
LOCK_PATH = os.environ.get("SUIXIANG_LOCK", "/tmp/suixiang.lock")

# ---- FastNote 常量（复用自 xyz xiaoyuzhou_dl.py L2384-2395）----
FAST_NOTE_FOLDER_DB = "/opt/fast-note/storage/database/db_user_folder_1.sqlite3"
FAST_NOTE_NOTE_DB = "/opt/fast-note/storage/database/db_user_1.sqlite3"
FAST_NOTE_NOTE_HISTORY_DB = "/opt/fast-note/storage/database/db_user_note_history_1.sqlite3"
FAST_NOTE_VAULT_ROOT = "/opt/fast-note/storage/vault/u_1/note"
FAST_NOTE_CLIENT_NAME = "Win"
FAST_NOTE_BACKUP_DIR = os.environ.get(
    "FAST_NOTE_BACKUP_DIR",
    os.path.expanduser("~/.openclaw/workspace/.backups/fast-note"),
)


# ===== 以下函数逐行复用自 xyz/xiaoyuzhou_dl.py =====

def sanitize_filename(name: str) -> str:
    """清理文件名，移除非法字符"""
    illegal = r'[<>:"/\\|?*]'
    name = re.sub(illegal, "_", name)
    name = name.strip(" .-_")
    if len(name) > 200:
        name = name[:200]
    return name


def java_string_hash(text: str) -> str:
    h = 0
    for ch in text:
        h = (31 * h + ord(ch)) & 0xFFFFFFFF
    if h >= 2 ** 31:
        h -= 2 ** 32
    return str(h)


def backup_file_once(src_path: str) -> Optional[str]:
    if os.environ.get("FAST_NOTE_ENABLE_SQLITE_BACKUP") != "1":
        return None
    src = Path(src_path)
    if not src.exists():
        return None
    backup_dir = Path(FAST_NOTE_BACKUP_DIR)
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = backup_dir / f"{src.name}.{stamp}.bak"
    shutil.copy2(src, dest)
    return str(dest)


def normalize_fast_note_segment(name: str) -> str:
    return sanitize_filename((name or "").strip())


def ensure_fast_note_folder(folder_path: str) -> int:
    """确保 Fast Note 文件夹路径存在，返回最终 folder id。"""
    parts = [normalize_fast_note_segment(p) for p in folder_path.split("/") if p.strip()]
    if not parts:
        raise ValueError("folder_path 不能为空")

    now_ms = int(time.time() * 1000)
    now_dt = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    con = sqlite3.connect(FAST_NOTE_FOLDER_DB)
    cur = con.cursor()
    parent_id = 0
    current_path = ""

    try:
        for level, part in enumerate(parts, start=1):
            current_path = f"{current_path}/{part}" if current_path else part
            cur.execute(
                "select id from folder where vault_id=1 and path=? order by id desc limit 1",
                (current_path,),
            )
            row = cur.fetchone()
            if row:
                parent_id = int(row[0])
                continue

            cur.execute(
                "insert into folder (vault_id, action, path, path_hash, level, fid, ctime, mtime, updated_timestamp, created_at, updated_at) values (1, 'create', ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (current_path, java_string_hash(current_path), level, parent_id, now_ms, now_ms, now_ms, now_dt, now_dt),
            )
            parent_id = int(cur.lastrowid)

        con.commit()
        return parent_id
    finally:
        con.close()


def upsert_fast_note_markdown(folder_path: str, note_title: str, content: str) -> dict:
    """将 Markdown 内容写入 Fast Note / Obsidian 存储，并写成 Fast Note UI 稳定可见的正规化形态。"""
    folder_backup = backup_file_once(FAST_NOTE_FOLDER_DB)
    note_backup = backup_file_once(FAST_NOTE_NOTE_DB)
    note_history_backup = backup_file_once(FAST_NOTE_NOTE_HISTORY_DB)

    folder_path = "/".join(normalize_fast_note_segment(seg) for seg in folder_path.split("/") if seg.strip())
    folder_id = ensure_fast_note_folder(folder_path)
    safe_title = normalize_fast_note_segment(note_title)
    note_path = f"{folder_path}/{safe_title}.md"
    now_ms = int(time.time() * 1000)
    now_dt = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    path_hash = java_string_hash(note_path)
    size = len(content.encode("utf-8"))
    content_hash = java_string_hash(content)

    def write_note_files(note_id: int) -> None:
        note_dir = Path(FAST_NOTE_VAULT_ROOT) / f"n_{note_id}"
        note_dir.mkdir(parents=True, exist_ok=True)
        (note_dir / "content.txt").write_text(content, encoding="utf-8")
        (note_dir / "snapshot.txt").write_text(content, encoding="utf-8")

    def append_note_history(note_id: int, version: int, created_at: str) -> None:
        hist_con = sqlite3.connect(FAST_NOTE_NOTE_HISTORY_DB)
        hist_cur = hist_con.cursor()
        hist_cur.execute(
            "insert into note_history (note_id, vault_id, path, content, content_hash, diff_patch, client_name, version, created_at, updated_at) values (?, 1, ?, '', ?, '', ?, ?, ?, NULL)",
            (note_id, note_path, content_hash, FAST_NOTE_CLIENT_NAME, version, created_at),
        )
        hist_con.commit()
        hist_con.close()

    con = sqlite3.connect(FAST_NOTE_NOTE_DB)
    cur = con.cursor()
    cur.execute(
        "select id, version, ctime, created_at from note where vault_id=1 and path=? and rename=0 order by id desc limit 1",
        (note_path,),
    )
    row = cur.fetchone()
    created_new_note = False

    if row:
        note_id = int(row[0])
        previous_version = int(row[1] or 0)
        version = max(previous_version, 1) + 1
        ctime = int(row[2] or now_ms)
        created_at = row[3] or now_dt
        write_note_files(note_id)
        cur.execute(
            "update note set action='modify', fid=?, path_hash=?, content='', content_hash=?, content_last_snapshot='', content_last_snapshot_hash=?, version=?, client_name=?, size=?, mtime=?, updated_timestamp=?, updated_at=? where id=?",
            (folder_id, path_hash, content_hash, content_hash, version, FAST_NOTE_CLIENT_NAME, size, now_ms, now_ms, now_dt, note_id),
        )
    else:
        created_new_note = True
        version = 1
        ctime = now_ms
        created_at = now_dt
        cur.execute(
            "insert into note (vault_id, action, rename, fid, path, path_hash, content, content_hash, content_last_snapshot, content_last_snapshot_hash, version, client_name, size, ctime, mtime, updated_timestamp, created_at, updated_at) values (1, 'modify', 0, ?, ?, ?, '', ?, '', ?, 1, ?, ?, ?, ?, ?, ?, ?)",
            (folder_id, note_path, path_hash, content_hash, content_hash, FAST_NOTE_CLIENT_NAME, size, ctime, now_ms, now_ms, created_at, now_dt),
        )
        note_id = int(cur.lastrowid)
        write_note_files(note_id)

    cur.execute("delete from note_fts where note_id=?", (note_id,))
    cur.execute("insert into note_fts(note_id, path, content) values (?, ?, ?)", (note_id, note_path, content))
    con.commit()
    con.close()

    append_note_history(note_id, version, now_dt)

    normalized_second_pass = True
    second_now_ms = int(time.time() * 1000)
    second_now_dt = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    second_version = max(version, 1) + 1
    write_note_files(note_id)

    con = sqlite3.connect(FAST_NOTE_NOTE_DB)
    cur = con.cursor()
    cur.execute(
        "update note set action='modify', rename=0, fid=?, path_hash=?, content='', content_hash=?, content_last_snapshot='', content_last_snapshot_hash=?, version=?, client_name=?, size=?, mtime=?, updated_timestamp=?, updated_at=? where id=?",
        (folder_id, path_hash, content_hash, content_hash, second_version, FAST_NOTE_CLIENT_NAME, size, second_now_ms, second_now_ms, second_now_dt, note_id),
    )
    cur.execute("delete from note_fts where note_id=?", (note_id,))
    cur.execute("insert into note_fts(note_id, path, content) values (?, ?, ?)", (note_id, note_path, content))
    con.commit()
    con.close()

    append_note_history(note_id, second_version, second_now_dt)
    version = second_version

    verified_action = "unknown"
    con = sqlite3.connect(FAST_NOTE_NOTE_DB)
    cur = con.cursor()
    cur.execute("select action, version from note where id=?", (note_id,))
    verify_row = cur.fetchone()
    if verify_row:
        verified_action = str(verify_row[0] or "")
        current_version = int(verify_row[1] or version or 0)
        if verified_action != "modify":
            fix_now_ms = int(time.time() * 1000)
            fix_now_dt = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            fix_version = max(current_version, version, 1) + 1
            write_note_files(note_id)
            cur.execute(
                "update note set action='modify', rename=0, fid=?, path_hash=?, content='', content_hash=?, content_last_snapshot='', content_last_snapshot_hash=?, version=?, client_name=?, size=?, mtime=?, updated_timestamp=?, updated_at=? where id=?",
                (folder_id, path_hash, content_hash, content_hash, fix_version, FAST_NOTE_CLIENT_NAME, size, fix_now_ms, fix_now_ms, fix_now_dt, note_id),
            )
            cur.execute("delete from note_fts where note_id=?", (note_id,))
            cur.execute("insert into note_fts(note_id, path, content) values (?, ?, ?)", (note_id, note_path, content))
            con.commit()
            append_note_history(note_id, fix_version, fix_now_dt)
            version = fix_version
            verified_action = "modify"
    con.close()

    return {
        "note_id": note_id,
        "note_path": note_path,
        "folder_id": folder_id,
        "note_backup": note_backup,
        "note_history_backup": note_history_backup,
        "folder_backup": folder_backup,
        "normalized_second_pass": normalized_second_pass,
        "final_version": version,
        "verified_action": verified_action,
    }


# ===== 随想记录员新增逻辑 =====

def fast_note_path(folder_path: str, note_title: str) -> str:
    """按 upsert_fast_note_markdown 完全相同的规则计算 note 的存储 path。

    必须与 upsert 内部一致——否则「读现有」会因路径不匹配而落空，导致追加变覆盖。
    """
    folder = "/".join(
        normalize_fast_note_segment(seg) for seg in folder_path.split("/") if seg.strip()
    )
    safe_title = normalize_fast_note_segment(note_title)
    return f"{folder}/{safe_title}.md"


def read_existing_note(note_path: str) -> Optional[str]:
    """读取 FastNote 中某 note 的现有正文，用于增量追加；不存在返回 None。"""
    if not Path(FAST_NOTE_NOTE_DB).exists():
        return None
    con = sqlite3.connect(FAST_NOTE_NOTE_DB)
    cur = con.cursor()
    cur.execute(
        "select id from note where vault_id=1 and path=? and rename=0 order by id desc limit 1",
        (note_path,),
    )
    row = cur.fetchone()
    con.close()
    if not row:
        return None
    note_id = int(row[0])
    content_file = Path(FAST_NOTE_VAULT_ROOT) / f"n_{note_id}" / "content.txt"
    if content_file.exists():
        return content_file.read_text(encoding="utf-8")
    return None


def count_entries(content: str) -> int:
    """统计当日条目数（按加粗时间戳行 **HH:MM** 计）。"""
    return len(re.findall(r"(?m)^\*\*\d{2}:\d{2}\*\*\s*$", content))


def emit(line: str) -> None:
    print(line, flush=True)


def main() -> int:
    # 取消息：优先命令行参数；为空或为 '-' 时读 stdin
    arg = sys.argv[1] if len(sys.argv) > 1 else None
    if arg is None or arg == "-":
        msg = sys.stdin.read()
    else:
        msg = arg
    msg = (msg or "").strip()
    if not msg:
        emit("📣 RESULT status=skipped reason=empty")
        return 0

    now = datetime.now(TZ)
    date = now.strftime("%Y-%m-%d")
    hhmm = now.strftime("%H:%M")
    # 用与 upsert 一致的规范化路径来读现有内容，确保「追加」而非「覆盖」
    note_path = fast_note_path(THOUGHTS_FOLDER, date)
    entry = f"**{hhmm}**\n{msg}"

    # flock 串行化「读-改-写」，防止并发追加互相覆盖
    lock_fh = open(LOCK_PATH, "w")
    try:
        fcntl.flock(lock_fh, fcntl.LOCK_EX)
        existing = read_existing_note(note_path)
        if existing is None or not existing.strip():
            content = f"# {date}\n\n{entry}\n"
        else:
            content = existing.rstrip("\n") + f"\n\n{entry}\n"
        result = upsert_fast_note_markdown(THOUGHTS_FOLDER, date, content)
        count = count_entries(content)
        emit(
            f"📣 RESULT status=success note_path={result['note_path']} "
            f"note_id={result['note_id']} count={count} date={date} hhmm={hhmm}"
        )
        return 0
    finally:
        try:
            fcntl.flock(lock_fh, fcntl.LOCK_UN)
        finally:
            lock_fh.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 — 任何失败都打印机读回执，交由 dispatcher 兜底
        emit(f"📣 RESULT status=failed reason={json.dumps(str(exc), ensure_ascii=False)}")
        sys.exit(1)
