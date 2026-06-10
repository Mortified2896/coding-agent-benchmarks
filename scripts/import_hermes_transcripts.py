#!/usr/bin/env python3
"""Import Hermes WebUI session transcripts into a private local SQLite DB.

Reads ~/.hermes/webui/sessions/*.json, extracts conversation data,
redacts obvious secrets before storing, and links sessions to
coding-agent-task-logs.  See docs/stage-29-private-transcript-layer.md
for the full design.
"""

import argparse
import datetime
import glob
import hashlib
import json
import os
import re
import sqlite3
import sys


SECRET_PATTERNS: list[tuple[str, re.Pattern]] = [
    ("openai_key", re.compile(r"sk-[A-Za-z0-9_-]{20,}")),
    ("aws_key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("github_token", re.compile(r"ghp_[A-Za-z0-9]{20,}")),
    ("slack_token", re.compile(r"xox[abp]-[A-Za-z0-9-]{10,}")),
    ("bearer", re.compile(r"Authorization:\s*Bearer\s+\S{16,}")),
    ("private_key", re.compile(
        r"-----BEGIN\s[A-Z\s]*PRIVATE\sKEY-----[\s\S]*?"
        r"-----END\s[A-Z\s]*PRIVATE\sKEY-----"
    )),
]

KV_PATTERN = re.compile(
    r"(?:password|token|api_key|secret)\s*=\s*(\S{16,})"
)
PLACEHOLDER_PATTERN = re.compile(
    r"^(?:changeme|example|<your-key-here>|<[^>]+>)$", re.IGNORECASE
)

SCHEMA_SQL = (
    "CREATE TABLE IF NOT EXISTS sessions ("
    " session_id TEXT PRIMARY KEY,"
    " chat_id TEXT,"
    " profile TEXT,"
    " model TEXT,"
    " provider TEXT,"
    " reasoning_level TEXT,"
    " created_at TEXT,"
    " updated_at TEXT,"
    " source_path TEXT NOT NULL,"
    " imported_at TEXT NOT NULL,"
    " message_count INTEGER NOT NULL DEFAULT 0"
    ");"
    "CREATE TABLE IF NOT EXISTS messages ("
    " session_id TEXT NOT NULL,"
    " message_seq INTEGER NOT NULL,"
    " role TEXT,"
    " timestamp TEXT,"
    " content_redacted TEXT,"
    " char_count INTEGER NOT NULL,"
    " secret_like_hits INTEGER NOT NULL DEFAULT 0,"
    " PRIMARY KEY (session_id, message_seq)"
    ");"
    "CREATE TABLE IF NOT EXISTS task_logs ("
    " task_id TEXT PRIMARY KEY,"
    " task_dir TEXT NOT NULL,"
    " task_started_at TEXT,"
    " task_finished_at TEXT,"
    " worker_model TEXT,"
    " worker_prompt_sha256 TEXT,"
    " worker_prompt_path TEXT NOT NULL,"
    " hermes_session_id TEXT,"
    " imported_at TEXT NOT NULL"
    ");"
    "CREATE TABLE IF NOT EXISTS session_task_links ("
    " session_id TEXT NOT NULL,"
    " task_id TEXT NOT NULL,"
    " link_source TEXT NOT NULL,"
    " link_confidence TEXT NOT NULL,"
    " linked_at TEXT NOT NULL,"
    " PRIMARY KEY (session_id, task_id, link_source)"
    ");"
    "CREATE TABLE IF NOT EXISTS import_runs ("
    " run_id INTEGER PRIMARY KEY AUTOINCREMENT,"
    " started_at TEXT NOT NULL,"
    " finished_at TEXT,"
    " sessions_scanned INTEGER NOT NULL DEFAULT 0,"
    " messages_imported INTEGER NOT NULL DEFAULT 0,"
    " task_logs_indexed INTEGER NOT NULL DEFAULT 0,"
    " task_log_links INTEGER NOT NULL DEFAULT 0,"
    " secret_like_matches INTEGER NOT NULL DEFAULT 0,"
    " output_db_path TEXT NOT NULL"
    ");"
    "CREATE INDEX IF NOT EXISTS idx_messages_session  ON messages(session_id);"
    "CREATE INDEX IF NOT EXISTS idx_messages_role     ON messages(role);"
    "CREATE INDEX IF NOT EXISTS idx_links_session     ON session_task_links(session_id);"
    "CREATE INDEX IF NOT EXISTS idx_links_task        ON session_task_links(task_id);"
    "CREATE INDEX IF NOT EXISTS idx_tasklogs_worker   ON task_logs(worker_model);"
    "CREATE INDEX IF NOT EXISTS idx_tasklogs_session  ON task_logs(hermes_session_id);"
)

ROLE_MAP = {"user": "user", "assistant": "assistant",
            "tool": "tool", "system": "system"}


def utcnow_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def float_to_iso(ts: float) -> str | None:
    try:
        return datetime.datetime.fromtimestamp(
            ts, tz=datetime.timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (OSError, OverflowError, ValueError):
        return None


def extract_text_from_content(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            item.get("text", "") if isinstance(item, dict)
            else str(item)
            for item in content
        )
    if content is None:
        return ""
    return str(content)


def redact_text(text: str) -> tuple[str, int, dict[str, int]]:
    total = 0
    cat_counts: dict[str, int] = {}

    for category, pattern in SECRET_PATTERNS:
        text, n = pattern.subn(f"[REDACTED:{category}]", text)
        if n:
            cat_counts[category] = cat_counts.get(category, 0) + n
            total += n

    def _kv_replace(m: re.Match) -> str:
        nonlocal total
        val = m.group(1)
        if PLACEHOLDER_PATTERN.match(val):
            return m.group(0)
        cat_counts["kv_assignment"] = cat_counts.get("kv_assignment", 0) + 1
        total += 1
        prefix = m.group(0)[:m.start(1) - m.start(0)]
        return f"{prefix}[REDACTED:kv_assignment]"

    text = KV_PATTERN.sub(_kv_replace, text)
    return text, total, cat_counts


def get_reasoning_level(session_id: str) -> str | None:
    state_db = os.path.expanduser("~/.hermes/state.db")
    if not os.path.isfile(state_db):
        return None
    try:
        conn = sqlite3.connect(state_db)
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT json_extract(model_config, '$.reasoning_config.effort') "
            "AS effort FROM sessions WHERE id = ?",
            (session_id,),
        ).fetchone()
        conn.close()
        if row and row["effort"]:
            return str(row["effort"])
    except Exception:
        pass
    return None


def _find_repo_root() -> str:
    for start in (os.getcwd(), os.path.dirname(os.path.abspath(__file__))):
        d = start
        while True:
            if os.path.isdir(os.path.join(d, ".git")):
                return d
            parent = os.path.dirname(d)
            if parent == d:
                break
            d = parent
    return os.getcwd()


def _load_json(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}


def import_sessions(db: sqlite3.Connection, no_task_logs: bool,
                    now: str) -> dict:
    cur = db.cursor()
    db_path = db.execute("PRAGMA database_list").fetchone()[2]
    repo_root = _find_repo_root()

    stats = {
        "sessions_scanned": 0,
        "messages_imported": 0,
        "task_logs_indexed": 0,
        "task_log_links": 0,
        "secret_like_matches": 0,
        "secret_categories": {},
    }

    # ── 1. Walk WebUI session JSON files ──────────────────────────
    session_dir = os.path.expanduser("~/.hermes/webui/sessions")
    session_files = sorted(glob.glob(os.path.join(session_dir, "*.json")))

    for sf in session_files:
        sess = _load_json(sf)
        if not isinstance(sess, dict):
            continue
        sid = sess.get("session_id")
        if not sid:
            continue

        stats["sessions_scanned"] += 1

        screated = sess.get("created_at")
        supdated = sess.get("updated_at")
        screated_iso = (float_to_iso(screated)
                        if isinstance(screated, (int, float)) else None)
        supdated_iso = (float_to_iso(supdated)
                        if isinstance(supdated, (int, float)) else None)
        reasoning = get_reasoning_level(sid)

        cur.execute(
            "INSERT OR REPLACE INTO sessions "
            "(session_id, chat_id, profile, model, provider, "
            " reasoning_level, created_at, updated_at, "
            " source_path, imported_at, message_count) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (sid, sess.get("chat_id"), sess.get("profile"),
             sess.get("model"), sess.get("model_provider"),
             reasoning, screated_iso, supdated_iso,
             sf, now, len(sess.get("messages", []))),
        )

        for seq, msg in enumerate(sess.get("messages", []), start=1):
            if not isinstance(msg, dict):
                continue

            role = ROLE_MAP.get(msg.get("role", ""), "unknown")
            raw_ts = msg.get("timestamp")
            if isinstance(raw_ts, (int, float)):
                ts_iso = float_to_iso(raw_ts)
            elif isinstance(raw_ts, str) and raw_ts:
                ts_iso = raw_ts
            else:
                ts_iso = None

            raw_text = extract_text_from_content(msg.get("content"))
            redacted, n_hits, cat_counts = redact_text(raw_text)
            for cat, cnt in cat_counts.items():
                stats["secret_categories"][cat] = \
                    stats["secret_categories"].get(cat, 0) + cnt
            stats["secret_like_matches"] += n_hits

            cur.execute(
                "INSERT OR REPLACE INTO messages "
                "(session_id, message_seq, role, timestamp, "
                " content_redacted, char_count, secret_like_hits) "
                "VALUES (?,?,?,?,?,?,?)",
                (sid, seq, role, ts_iso, redacted, len(redacted), n_hits),
            )
            stats["messages_imported"] += 1

    # ── 2. Index task logs ────────────────────────────────────────
    task_log_root = os.path.join(repo_root, ".local",
                                 "coding-agent-task-logs")
    task_meta_map: dict[str, dict] = {}  # task_dir -> metadata dict

    if not no_task_logs and os.path.isdir(task_log_root):
        for mf in sorted(glob.glob(
                os.path.join(task_log_root, "**", "metadata.json"),
                recursive=True)):
            meta = _load_json(mf)
            if not meta:
                continue
            task_dir = os.path.dirname(mf)
            task_id = meta.get("task_id") or os.path.basename(task_dir)
            task_meta_map[task_dir] = meta

            task_started_at = (
                meta.get("timestamp")
                or meta.get("session_start_time")
                or meta.get("timestamp_start")
                or meta.get("start_time")
            )
            worker_model = meta.get("model_id")

            prompt_rel = meta.get("worker_prompt_path")
            if prompt_rel and not os.path.isabs(prompt_rel):
                prompt_abs = os.path.join(task_dir, prompt_rel)
            elif prompt_rel:
                prompt_abs = prompt_rel
            else:
                prompt_abs = os.path.join(task_dir, "worker_prompt.md")

            prompt_sha = meta.get("worker_prompt_sha256")
            if not prompt_sha:
                prompt_sha = compute_sha256(
                    os.path.join(task_dir, "worker_prompt.md"))

            trace = _load_json(os.path.join(task_dir, "hermes_trace.json"))
            trace_sid = trace.get("hermes_session_id")

            orch_sid = meta.get("hermes_orchestrator_session_id")
            effective_sid = trace_sid or meta.get("hermes_session_id")

            cur.execute(
                "INSERT OR REPLACE INTO task_logs "
                "(task_id, task_dir, task_started_at, task_finished_at, "
                " worker_model, worker_prompt_sha256, worker_prompt_path, "
                " hermes_session_id, imported_at) "
                "VALUES (?,?,?,?,?,?,?,?,?)",
                (task_id, task_dir, task_started_at, task_started_at,
                 worker_model, prompt_sha, prompt_abs or "",
                 orch_sid or effective_sid, now),
            )
            stats["task_logs_indexed"] += 1

    # ── 3. Link sessions to task logs ─────────────────────────────
    if not no_task_logs and task_meta_map:
        task_rows = cur.execute(
            "SELECT task_id, task_dir, task_started_at, "
            "worker_prompt_sha256, hermes_session_id FROM task_logs"
        ).fetchall()
        session_rows = cur.execute(
            "SELECT session_id, chat_id, created_at FROM sessions"
        ).fetchall()

        for (t_id, t_dir, t_started, t_prompt_sha, t_hermes_sid) in task_rows:
            meta = task_meta_map.get(t_dir, {})
            meta_sid = meta.get("hermes_session_id")
            meta_chat_id = meta.get("hermes_session_chat_id")
            meta_orch_sid = meta.get("hermes_orchestrator_session_id")
            trace = _load_json(os.path.join(t_dir, "hermes_trace.json"))
            trace_sid = trace.get("hermes_session_id")

            link_count = 0

            for s_id, s_chat_id, s_created in session_rows:
                # (1) session_id == hermes_orchestrator_session_id
                #     OR hermes_trace.session_id
                sid_exact = bool(
                    (meta_orch_sid and meta_orch_sid == s_id)
                    or (trace_sid and trace_sid == s_id)
                )
                if not sid_exact:
                    # Also check the stored hermes_session_id
                    sid_exact = bool(t_hermes_sid and t_hermes_sid == s_id)

                if sid_exact:
                    cur.execute(
                        "INSERT OR REPLACE INTO session_task_links "
                        "(session_id, task_id, link_source, "
                        " link_confidence, linked_at) "
                        "VALUES (?,?,?,?,?)",
                        (s_id, t_id, "session_id", "exact", now),
                    )
                    link_count += 1

                # (2) chat_id == metadata.hermes_session_chat_id
                if (s_chat_id and meta_chat_id
                        and str(s_chat_id) == str(meta_chat_id)):
                    cur.execute(
                        "INSERT OR REPLACE INTO session_task_links "
                        "(session_id, task_id, link_source, "
                        " link_confidence, linked_at) "
                        "VALUES (?,?,?,?,?)",
                        (s_id, t_id, "chat_id", "exact", now),
                    )
                    link_count += 1

                # (3) session_id == metadata.hermes_session_id
                if (meta_sid and meta_sid == s_id
                        and (not sid_exact or meta_sid != t_hermes_sid)):
                    cur.execute(
                        "INSERT OR REPLACE INTO session_task_links "
                        "(session_id, task_id, link_source, "
                        " link_confidence, linked_at) "
                        "VALUES (?,?,?,?,?)",
                        (s_id, t_id, "orchestrator_session_id",
                         "strong", now),
                    )
                    link_count += 1

                # (4) Timestamp proximity (+/- 10 min)
                if s_created and t_started:
                    try:
                        s_dt = datetime.datetime.fromisoformat(
                            s_created.replace("Z", "+00:00"))
                        t_dt = datetime.datetime.fromisoformat(
                            t_started.replace("Z", "+00:00"))
                        if abs((s_dt - t_dt).total_seconds()) <= 600:
                            cur.execute(
                                "INSERT OR REPLACE INTO session_task_links "
                                "(session_id, task_id, link_source, "
                                " link_confidence, linked_at) "
                                "VALUES (?,?,?,?,?)",
                                (s_id, t_id, "timestamp", "weak", now),
                            )
                            link_count += 1
                    except (ValueError, TypeError):
                        pass

            stats["task_log_links"] += link_count

    # ── 4. Record import run ──────────────────────────────────────
    cur.execute(
        "INSERT INTO import_runs "
        "(started_at, finished_at, sessions_scanned, messages_imported, "
        " task_logs_indexed, task_log_links, secret_like_matches, "
        " output_db_path) "
        "VALUES (?,?,?,?,?,?,?,?)",
        (now, now, stats["sessions_scanned"], stats["messages_imported"],
         stats["task_logs_indexed"], stats["task_log_links"],
         stats["secret_like_matches"], db_path),
    )
    db.commit()
    return stats


def compute_sha256(path: str) -> str | None:
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Import Hermes WebUI transcripts into private SQLite DB")
    parser.add_argument("--db", default=None,
                        help="Output DB path")
    parser.add_argument("--repo", default=None,
                        help="Repository root")
    parser.add_argument("--no-task-logs", action="store_true",
                        help="Skip task-log indexing")
    args = parser.parse_args()

    repo_root = args.repo or _find_repo_root()
    if args.db:
        db_path = args.db
    else:
        db_path = os.path.join(
            repo_root, ".local", "private-analysis",
            "hermes_transcripts.sqlite")

    os.makedirs(os.path.dirname(db_path), exist_ok=True)

    db = sqlite3.connect(db_path)
    db.executescript(SCHEMA_SQL)
    db.commit()

    now = utcnow_iso()
    stats = import_sessions(db, args.no_task_logs, now)

    print(f"Sessions scanned:    {stats['sessions_scanned']}")
    print(f"Messages imported:   {stats['messages_imported']}")
    print(f"Task logs indexed:   {stats['task_logs_indexed']}")
    print(f"Task-log links:      {stats['task_log_links']}")
    print(f"Secret-like matches: {stats['secret_like_matches']}")
    if stats["secret_categories"]:
        cats = ", ".join(
            f"{k}={v}" for k, v in sorted(stats["secret_categories"].items()))
        print(f"  by category: {cats}")
    print(f"Output DB:           {db_path}")

    db.close()
    sys.exit(0)


if __name__ == "__main__":
    main()
