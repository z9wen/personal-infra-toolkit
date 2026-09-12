#!/usr/bin/env python3
"""Safely detect and remove stale local Codex/ChatGPT desktop chat indexes.

With no arguments this opens an interactive terminal conversation manager.
Conversations are grouped under local-project roots or the automatically
created working folders used by projectless desktop chats. Stable
``session_id`` values ensure paginated rollouts, guardian reviews, and subagent
files are not displayed as duplicate chats. Selected conversations are removed
as one family and their JSONL files are moved to a recoverable quarantine
directory.

The non-interactive repair mode also detects states where a thread is still
indexed but either its exact rollout JSONL no longer exists or its paginated
history lineage points to a missing source rollout.

Usage:

    # Open the project/conversation terminal manager
    python3 codex_ghost_cleaner.py

    # Read-only ghost scan
    python3 codex_ghost_cleaner.py --scan-only

Any remaining ChatGPT/Codex processes owned by the current user are stopped
automatically before local state is changed.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as datetime_module
import json
import os
import re
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Iterable, Sequence


VERSION = "2.1.0"
THREAD_ID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
THREAD_ID_IN_NAME_RE = re.compile(
    r"(?<![0-9a-fA-F])([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"
)
IDENTITY_KEYS = {
    "id",
    "threadId",
    "thread_id",
    "conversationId",
    "conversation_id",
}


class CleanerError(RuntimeError):
    """Expected error that should be shown without a traceback."""


@dataclasses.dataclass(frozen=True)
class Candidate:
    thread_id: str
    title: str
    rollout_path: str
    archived: bool
    source: str
    thread_source: str
    has_automation_run: bool = False
    has_surviving_fragments: bool = False
    issue_kind: str = "missing_rollout"
    missing_source_rollout: str = ""


@dataclasses.dataclass(frozen=True)
class ProcessInfo:
    pid: int
    command: str


@dataclasses.dataclass(frozen=True)
class Layout:
    home: Path
    state_db: Path
    catalog_db: Path
    summaries_db: Path
    history_dbs: tuple[Path, ...]
    session_index: Path
    global_state_files: tuple[Path, ...]


@dataclasses.dataclass(frozen=True)
class TranscriptRecord:
    path: Path
    session_id: str
    rollout_id: str
    related_ids: frozenset[str]
    cwd: str
    thread_source: str
    is_user_rollout: bool
    archived: bool
    modified_at_ms: int


@dataclasses.dataclass(frozen=True)
class Conversation:
    session_id: str
    title: str
    project_path: str
    updated_at_ms: int
    archived: bool
    transcript_paths: tuple[Path, ...]
    related_ids: frozenset[str]
    fragment_count: int
    health: str
    protected: bool = False


@dataclasses.dataclass(frozen=True)
class ProjectGroup:
    path: str
    conversations: tuple[Conversation, ...]
    updated_at_ms: int


@dataclasses.dataclass(frozen=True)
class WorkspaceMetadata:
    project_assignments: dict[str, str]
    projectless_directories: dict[str, str]
    projectless_ids: frozenset[str]


def stderr(message: str) -> None:
    print(message, file=sys.stderr)


def discover_state_db(home: Path) -> Path:
    databases = list(home.glob("state_*.sqlite"))
    if not databases:
        raise CleanerError(f"找不到状态数据库：{home}/state_*.sqlite")

    def version_key(path: Path) -> tuple[int, str]:
        match = re.search(r"state_(\d+)\.sqlite$", path.name)
        return (int(match.group(1)) if match else -1, path.name)

    return max(databases, key=version_key)


def discover_layout(home: Path) -> Layout:
    resolved = home.expanduser().resolve()
    if not resolved.is_dir():
        raise CleanerError(f"CODEX_HOME 不存在或不是目录：{resolved}")

    global_files = tuple(
        path
        for path in (
            resolved / ".codex-global-state.json",
            resolved / ".codex-global-state.json.bak",
        )
        if path.is_file()
    )
    return Layout(
        home=resolved,
        state_db=discover_state_db(resolved),
        catalog_db=resolved / "sqlite" / "codex-dev.db",
        summaries_db=resolved / "sqlite" / "codex-thread-summaries-dev.db",
        history_dbs=tuple(sorted(resolved.glob("thread_history_*.sqlite"))),
        session_index=resolved / "session_index.jsonl",
        global_state_files=global_files,
    )


def connect_sqlite(path: Path, *, readonly: bool) -> sqlite3.Connection:
    if not path.is_file():
        raise CleanerError(f"数据库不存在：{path}")
    if readonly:
        connection = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True)
    else:
        connection = sqlite3.connect(path, timeout=5.0)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA busy_timeout = 5000")
    return connection


def table_exists(connection: sqlite3.Connection, table: str) -> bool:
    row = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone()
    return row is not None


def table_columns(connection: sqlite3.Connection, table: str) -> set[str]:
    if not table_exists(connection, table):
        return set()
    return {str(row[1]) for row in connection.execute(f'PRAGMA table_info("{table}")')}


def transcript_ids(home: Path) -> set[str]:
    found: set[str] = set()
    for root in (home / "sessions", home / "archived_sessions"):
        if not root.is_dir():
            continue
        for path in root.rglob("*.jsonl"):
            match = THREAD_ID_IN_NAME_RE.search(path.name)
            if match:
                found.add(match.group(1).lower())
    return found


def rollout_paths_by_storage_id(home: Path) -> dict[str, Path]:
    """Index rollout files by the final UUID in their filename.

    Paginated files keep the stable session ID first and append the storage
    rollout ID after an underscore. ``history_base.thread_id`` refers to that
    final storage ID, not necessarily to the stable session ID.
    """
    found: dict[str, Path] = {}
    for root in (home / "sessions", home / "archived_sessions"):
        if not root.is_dir():
            continue
        for path in root.rglob("*.jsonl"):
            matches = THREAD_ID_IN_NAME_RE.findall(path.name)
            if matches:
                found.setdefault(matches[-1].lower(), path)
    return found


def session_meta_payload(path: Path) -> dict[str, Any] | None:
    try:
        with path.open("r", encoding="utf-8") as handle:
            first_line = handle.readline()
        parsed = json.loads(first_line)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(parsed, dict) or parsed.get("type") != "session_meta":
        return None
    payload = parsed.get("payload")
    return payload if isinstance(payload, dict) else None


def missing_paginated_source(
    recorded: Path, rollout_paths: dict[str, Path]
) -> str:
    """Return the first missing storage rollout in a paginated lineage."""
    current = recorded
    visited: set[str] = set()
    while True:
        payload = session_meta_payload(current)
        if payload is None or payload.get("history_mode") != "paginated":
            return ""
        history_base = payload.get("history_base")
        if not isinstance(history_base, dict):
            return ""
        source_id = str(history_base.get("thread_id") or "").lower()
        if not THREAD_ID_RE.fullmatch(source_id):
            return ""
        if source_id in visited:
            return ""
        visited.add(source_id)
        source_path = rollout_paths.get(source_id)
        if source_path is None or not source_path.is_file():
            return source_id
        current = source_path


def iter_transcript_paths(home: Path) -> Iterable[Path]:
    for root in (home / "sessions", home / "archived_sessions"):
        if not root.is_dir():
            continue
        yield from root.rglob("*.jsonl")


def parse_iso_timestamp_ms(value: Any) -> int:
    if not isinstance(value, str) or not value:
        return 0
    try:
        parsed = datetime_module.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return 0
    return int(parsed.timestamp() * 1000)


def scan_transcript_records(home: Path) -> list[TranscriptRecord]:
    archived_root = home / "archived_sessions"
    records: list[TranscriptRecord] = []
    for path in iter_transcript_paths(home):
        payload = session_meta_payload(path)
        if payload is None:
            continue
        raw_rollout_id = str(payload.get("id") or "").lower()
        raw_session_id = str(payload.get("session_id") or raw_rollout_id).lower()
        if not THREAD_ID_RE.fullmatch(raw_session_id):
            continue

        related_ids = {
            value.lower()
            for value in THREAD_ID_IN_NAME_RE.findall(path.name)
            if THREAD_ID_RE.fullmatch(value)
        }
        if THREAD_ID_RE.fullmatch(raw_rollout_id):
            related_ids.add(raw_rollout_id)
        related_ids.add(raw_session_id)
        history_base = payload.get("history_base")
        if isinstance(history_base, dict):
            base_id = str(history_base.get("thread_id") or "").lower()
            if THREAD_ID_RE.fullmatch(base_id):
                related_ids.add(base_id)

        source = payload.get("source")
        thread_source = str(payload.get("thread_source") or "")
        try:
            modified_at_ms = path.stat().st_mtime_ns // 1_000_000
        except OSError:
            modified_at_ms = 0
        records.append(
            TranscriptRecord(
                path=path,
                session_id=raw_session_id,
                rollout_id=raw_rollout_id,
                related_ids=frozenset(related_ids),
                cwd=str(payload.get("cwd") or ""),
                thread_source=thread_source,
                is_user_rollout=thread_source == "user" or source == "vscode",
                archived=archived_root in path.parents,
                modified_at_ms=modified_at_ms,
            )
        )
    return records


def load_session_index(path: Path) -> dict[str, tuple[str, int]]:
    entries: dict[str, tuple[str, int]] = {}
    if not path.is_file():
        return entries
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                parsed = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(parsed, dict):
                continue
            thread_id = str(parsed.get("id") or "").lower()
            if not THREAD_ID_RE.fullmatch(thread_id):
                continue
            title = str(parsed.get("thread_name") or "").strip()
            updated_at_ms = parse_iso_timestamp_ms(parsed.get("updated_at"))
            previous = entries.get(thread_id)
            if previous is None or updated_at_ms >= previous[1]:
                entries[thread_id] = (title, updated_at_ms)
    return entries


def load_state_thread_metadata(path: Path) -> dict[str, dict[str, Any]]:
    with connect_sqlite(path, readonly=True) as connection:
        columns = table_columns(connection, "threads")
        wanted = (
            "id",
            "title",
            "cwd",
            "updated_at",
            "updated_at_ms",
            "archived",
            "source",
            "thread_source",
            "rollout_path",
        )
        expressions = [name if name in columns else f"NULL AS {name}" for name in wanted]
        rows = connection.execute(f"SELECT {', '.join(expressions)} FROM threads").fetchall()
    return {str(row["id"]).lower(): dict(row) for row in rows}


def load_global_workspace_metadata(
    state_files: Sequence[Path],
) -> WorkspaceMetadata:
    parsed: dict[str, Any] | None = None
    for path in state_files:
        try:
            candidate = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            continue
        if isinstance(candidate, dict):
            parsed = candidate
            break
    if parsed is None:
        return WorkspaceMetadata({}, {}, frozenset())

    raw_projects = parsed.get("local-projects")
    raw_assignments = parsed.get("thread-project-assignments")
    if not isinstance(raw_projects, dict):
        raw_projects = {}
    if not isinstance(raw_assignments, dict):
        raw_assignments = {}

    roots_by_project: dict[str, str] = {}
    for project_id, raw_project in raw_projects.items():
        if not isinstance(raw_project, dict):
            continue
        roots = raw_project.get("rootPaths")
        if isinstance(roots, list) and roots and isinstance(roots[0], str):
            roots_by_project[str(project_id)] = roots[0]

    assignments: dict[str, str] = {}
    for thread_id, raw_assignment in raw_assignments.items():
        if not THREAD_ID_RE.fullmatch(str(thread_id)) or not isinstance(
            raw_assignment, dict
        ):
            continue
        project_id = str(raw_assignment.get("projectId") or "")
        root = roots_by_project.get(project_id)
        if root:
            assignments[str(thread_id).lower()] = root

    projectless_directories: dict[str, str] = {}
    raw_output_directories = parsed.get("thread-projectless-output-directories")
    if isinstance(raw_output_directories, dict):
        for thread_id, raw_directory in raw_output_directories.items():
            normalized_id = str(thread_id).lower()
            if not THREAD_ID_RE.fullmatch(normalized_id) or not isinstance(
                raw_directory, str
            ):
                continue
            directory = raw_directory.strip()
            if not directory:
                continue
            output_path = Path(directory).expanduser()
            # Desktop stores the artifact directory (…/outputs); the terminal
            # tree should show the task's generated working folder above it.
            if output_path.name == "outputs":
                output_path = output_path.parent
            projectless_directories[normalized_id] = str(output_path)

    projectless_ids: set[str] = set(projectless_directories)
    raw_projectless_ids = parsed.get("projectless-thread-ids")
    if isinstance(raw_projectless_ids, list):
        projectless_ids.update(
            str(value).lower()
            for value in raw_projectless_ids
            if THREAD_ID_RE.fullmatch(str(value))
        )

    return WorkspaceMetadata(
        project_assignments=assignments,
        projectless_directories=projectless_directories,
        projectless_ids=frozenset(projectless_ids),
    )


def build_conversation_inventory(layout: Layout) -> list[ProjectGroup]:
    records = scan_transcript_records(layout.home)
    grouped_records: dict[str, list[TranscriptRecord]] = {}
    for record in records:
        grouped_records.setdefault(record.session_id, []).append(record)

    index_entries = load_session_index(layout.session_index)
    state_rows = load_state_thread_metadata(layout.state_db)
    workspace_metadata = load_global_workspace_metadata(layout.global_state_files)
    automated_ids = automation_thread_ids(layout.catalog_db)
    broken = {item.thread_id: item for item in scan(layout)[0]}

    session_ids = set(index_entries)
    session_ids.update(
        record.session_id for record in records if record.is_user_rollout
    )
    session_ids.update(
        thread_id
        for thread_id, row in state_rows.items()
        if row.get("thread_source") == "user" or row.get("source") == "vscode"
    )

    by_project: dict[str, list[Conversation]] = {}
    for session_id in session_ids:
        session_records = grouped_records.get(session_id, [])
        state = state_rows.get(session_id, {})
        user_records = [record for record in session_records if record.is_user_rollout]
        preferred_record = max(
            user_records or session_records,
            key=lambda record: record.modified_at_ms,
            default=None,
        )

        index_title, index_updated_ms = index_entries.get(session_id, ("", 0))
        state_title = str(state.get("title") or "").strip()
        title = index_title or state_title or f"未命名对话 {session_id[:8]}"
        # Sidebar project assignment is authoritative. A projectless desktop
        # chat has no project, but modern versions still create an isolated
        # task folder and record its …/outputs path in global state.
        project_path = workspace_metadata.project_assignments.get(session_id, "")
        if not project_path:
            project_path = workspace_metadata.projectless_directories.get(
                session_id, ""
            )
        if not project_path:
            project_path = str(state.get("cwd") or "").strip()
        if not project_path and preferred_record is not None:
            project_path = preferred_record.cwd
        if not project_path:
            if session_id in workspace_metadata.projectless_ids:
                project_path = "(无项目聊天 · 自动目录记录缺失)"
            else:
                project_path = "(旧索引 · 无法定位目录)"

        state_updated_ms = int(state.get("updated_at_ms") or 0)
        if not state_updated_ms:
            state_updated_ms = int(state.get("updated_at") or 0) * 1000
        updated_at_ms = max(
            [index_updated_ms, state_updated_ms]
            + [record.modified_at_ms for record in session_records]
        )

        related_ids = {session_id}
        transcript_paths: list[Path] = []
        for record in session_records:
            related_ids.update(record.related_ids)
            transcript_paths.append(record.path)

        broken_item = broken.get(session_id)
        if broken_item is not None and broken_item.issue_kind == "missing_lineage":
            health = "lineage 断链"
        elif broken_item is not None:
            health = "rollout 缺失"
        elif not transcript_paths:
            health = "仅剩索引"
        elif not state:
            health = "历史索引"
        else:
            health = "正常"

        archived = bool(state.get("archived")) or bool(
            session_records and all(record.archived for record in session_records)
        )
        conversation = Conversation(
            session_id=session_id,
            title=title,
            project_path=project_path,
            updated_at_ms=updated_at_ms,
            archived=archived,
            transcript_paths=tuple(sorted(set(transcript_paths))),
            related_ids=frozenset(related_ids),
            fragment_count=len(set(transcript_paths)),
            health=health,
            protected=bool(related_ids & automated_ids),
        )
        by_project.setdefault(project_path, []).append(conversation)

    projects: list[ProjectGroup] = []
    for path, conversations in by_project.items():
        ordered = tuple(
            sorted(conversations, key=lambda item: item.updated_at_ms, reverse=True)
        )
        projects.append(
            ProjectGroup(
                path=path,
                conversations=ordered,
                updated_at_ms=max((item.updated_at_ms for item in ordered), default=0),
            )
        )
    return sorted(projects, key=lambda item: item.updated_at_ms, reverse=True)


def automation_thread_ids(catalog_db: Path) -> set[str]:
    if not catalog_db.is_file():
        return set()
    with connect_sqlite(catalog_db, readonly=True) as connection:
        if "thread_id" not in table_columns(connection, "automation_runs"):
            return set()
        return {
            str(row[0]).lower()
            for row in connection.execute(
                "SELECT thread_id FROM automation_runs WHERE thread_id IS NOT NULL"
            )
        }


def scan(layout: Layout) -> tuple[list[Candidate], int]:
    present_ids = transcript_ids(layout.home)
    rollout_paths = rollout_paths_by_storage_id(layout.home)
    automated_ids = automation_thread_ids(layout.catalog_db)

    with connect_sqlite(layout.state_db, readonly=True) as connection:
        columns = table_columns(connection, "threads")
        required = {"id", "rollout_path"}
        if not required.issubset(columns):
            raise CleanerError(
                f"{layout.state_db} 的 threads 表结构不受支持；为避免误删，已经停止。"
            )

        expressions = ["id", "rollout_path"]
        for name, fallback in (
            ("title", "''"),
            ("archived", "0"),
            ("source", "''"),
            ("thread_source", "''"),
        ):
            expressions.append(name if name in columns else f"{fallback} AS {name}")
        rows = connection.execute(
            f"SELECT {', '.join(expressions)} FROM threads ORDER BY created_at, id"
        ).fetchall()

    candidates: list[Candidate] = []
    for row in rows:
        thread_id = str(row["id"]).lower()
        raw_path = str(row["rollout_path"] or "")
        recorded = Path(os.path.expandvars(os.path.expanduser(raw_path)))
        recorded_exists = bool(raw_path) and recorded.is_file()
        exists_elsewhere = thread_id in present_ids
        # Codex resumes a thread from the exact rollout_path stored in the
        # threads table.  Finding an older fragment with the same thread ID
        # does not make a dangling rollout_path usable: the desktop app still
        # fails with rollout_not_found.  Treat that state as a cleanup
        # candidate while preserving the information for reporting/recovery.
        missing_source = ""
        issue_kind = "missing_rollout"
        if recorded_exists:
            missing_source = missing_paginated_source(recorded, rollout_paths)
            if not missing_source:
                continue
            issue_kind = "missing_lineage"
        candidates.append(
            Candidate(
                thread_id=thread_id,
                title=str(row["title"] or ""),
                rollout_path=raw_path,
                archived=bool(row["archived"]),
                source=str(row["source"] or ""),
                thread_source=str(row["thread_source"] or ""),
                has_automation_run=thread_id in automated_ids,
                has_surviving_fragments=exists_elsewhere,
                issue_kind=issue_kind,
                missing_source_rollout=missing_source,
            )
        )
    return candidates, len(rows)


def clean_display_text(value: str, limit: int = 90) -> str:
    compact = " ".join(value.split())
    if len(compact) <= limit:
        return compact
    return compact[: limit - 1] + "…"


def print_scan_report(candidates: Sequence[Candidate], total: int) -> None:
    print(f"共检查 {total} 个本地任务；发现 {len(candidates)} 个严格匹配的幽灵任务。")
    if not candidates:
        return
    for index, item in enumerate(candidates, start=1):
        flags = [f"source={item.source or 'unknown'}"]
        if item.archived:
            flags.append("archived")
        if item.has_automation_run:
            flags.append("有自动化运行记录，默认保护")
        if item.issue_kind == "missing_lineage":
            flags.append("分页历史 lineage 断链")
        elif item.has_surviving_fragments:
            flags.append("有旧分片，但精确 rollout_path 已断链")
        print(f"\n[{index}] {item.thread_id}")
        if item.title:
            print(f"    标题：{clean_display_text(item.title)}")
        print(f"    状态：{', '.join(flags)}")
        if item.issue_kind == "missing_lineage":
            print(f"    当前：{item.rollout_path}")
            print(f"    缺少来源：{item.missing_source_rollout}")
        else:
            print(f"    缺失：{item.rollout_path or '(空路径)'}")


def find_running_codex_processes() -> list[ProcessInfo] | None:
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,uid=,command="],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None

    matches: list[ProcessInfo] = []
    bundle_markers = (
        "/Applications/ChatGPT.app/",
        "/Applications/Codex.app/",
        "ChatGPT Helper",
        "Codex Helper",
        "/node_modules/@openai/codex/",
    )
    for raw_line in result.stdout.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split(maxsplit=2)
        if len(parts) != 3:
            continue
        raw_pid, raw_uid, command = parts
        try:
            pid = int(raw_pid)
            uid = int(raw_uid)
        except ValueError:
            continue
        if uid != os.getuid() or pid == os.getpid():
            continue
        first_command = command.split(maxsplit=1)[0]
        is_bundle_process = any(marker in command for marker in bundle_markers)
        is_codex_cli = Path(first_command).name == "codex"
        if is_bundle_process or is_codex_cli:
            matches.append(ProcessInfo(pid=pid, command=command))
    return matches


def process_details(processes: Sequence[ProcessInfo]) -> str:
    return "\n".join(
        f"  PID {process.pid}: {clean_display_text(process.command, 140)}"
        for process in processes[:12]
    )


def signal_processes(processes: Sequence[ProcessInfo], sent_signal: signal.Signals) -> None:
    for process in processes:
        try:
            os.kill(process.pid, sent_signal)
        except ProcessLookupError:
            continue
        except PermissionError as exc:
            raise CleanerError(
                f"没有权限终止 PID {process.pid}：{clean_display_text(process.command, 120)}"
            ) from exc


def wait_for_codex_exit(timeout_seconds: float) -> list[ProcessInfo]:
    deadline = time.monotonic() + timeout_seconds
    while True:
        processes = find_running_codex_processes()
        if processes is None:
            raise CleanerError("终止进程后无法重新读取进程列表。")
        if not processes:
            return []
        if time.monotonic() >= deadline:
            return processes
        time.sleep(0.25)


def ensure_app_stopped(allow_running: bool) -> None:
    if allow_running:
        stderr("警告：已跳过桌面端/CLI 自动终止与运行检查。")
        return
    processes = find_running_codex_processes()
    if processes is None:
        raise CleanerError(
            "无法读取进程列表，因此不能安全写入。"
        )
    if processes:
        print("\n检测到残留的 ChatGPT/Codex 进程，正在自动退出：")
        print(process_details(processes))
        signal_processes(processes, signal.SIGTERM)
        remaining = wait_for_codex_exit(8.0)
        if remaining:
            print("常规退出超时，正在强制终止剩余进程：")
            print(process_details(remaining))
            signal_processes(remaining, signal.SIGKILL)
            remaining = wait_for_codex_exit(3.0)
        if remaining:
            raise CleanerError(
                "以下 ChatGPT/Codex 进程无法终止，因此没有清理数据库：\n"
                + process_details(remaining)
            )
        print("ChatGPT/Codex 进程已全部退出。")


def atomic_write(path: Path, data: bytes) -> None:
    original_mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.ghost-cleaner-", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(file_descriptor, original_mode)
        with os.fdopen(file_descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        try:
            os.close(file_descriptor)
        except OSError:
            pass
        temporary.unlink(missing_ok=True)
        raise


def clean_session_index(path: Path, thread_ids: set[str]) -> int:
    if not path.is_file():
        return 0
    original = path.read_bytes()
    kept: list[bytes] = []
    removed = 0
    for raw_line in original.splitlines(keepends=True):
        try:
            parsed = json.loads(raw_line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            kept.append(raw_line)
            continue
        if isinstance(parsed, dict) and str(parsed.get("id", "")).lower() in thread_ids:
            removed += 1
        else:
            kept.append(raw_line)
    if removed:
        atomic_write(path, b"".join(kept))
    return removed


DROP = object()


def purge_exact_thread_refs(node: Any, thread_ids: set[str], *, root: bool = False) -> tuple[Any, int]:
    if isinstance(node, dict):
        if not root:
            for key in IDENTITY_KEYS:
                value = node.get(key)
                if isinstance(value, str) and value.lower() in thread_ids:
                    return DROP, 1

        cleaned: dict[Any, Any] = {}
        removed = 0
        for key, value in node.items():
            if isinstance(key, str) and key.lower() in thread_ids:
                removed += 1
                continue
            if isinstance(value, str) and value.lower() in thread_ids:
                removed += 1
                continue
            new_value, child_removed = purge_exact_thread_refs(value, thread_ids)
            removed += child_removed
            if new_value is not DROP:
                cleaned[key] = new_value
        return cleaned, removed

    if isinstance(node, list):
        cleaned_list: list[Any] = []
        removed = 0
        for value in node:
            if isinstance(value, str) and value.lower() in thread_ids:
                removed += 1
                continue
            new_value, child_removed = purge_exact_thread_refs(value, thread_ids)
            removed += child_removed
            if new_value is not DROP:
                cleaned_list.append(new_value)
        return cleaned_list, removed

    return node, 0


def clean_global_state(path: Path, thread_ids: set[str]) -> int:
    if not path.is_file():
        return 0
    original = path.read_bytes()
    try:
        parsed = json.loads(original.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CleanerError(f"无法解析 {path}；为避免损坏，已经停止。") from exc

    cleaned, removed = purge_exact_thread_refs(parsed, thread_ids, root=True)
    if not removed:
        return 0
    trailing_newline = original.endswith(b"\n")
    if b"\n" in original:
        encoded = json.dumps(cleaned, ensure_ascii=False, indent=2).encode("utf-8")
    else:
        encoded = json.dumps(
            cleaned, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")
    if trailing_newline:
        encoded += b"\n"
    atomic_write(path, encoded)
    return removed


def placeholders(count: int) -> str:
    return ",".join("?" for _ in range(count))


def chunks(values: Sequence[str], size: int = 400) -> Iterable[Sequence[str]]:
    for start in range(0, len(values), size):
        yield values[start : start + size]


def delete_single_column(
    connection: sqlite3.Connection,
    table: str,
    column: str,
    thread_ids: Sequence[str],
) -> int:
    if column not in table_columns(connection, table):
        return 0
    removed = 0
    for part in chunks(thread_ids):
        cursor = connection.execute(
            f'DELETE FROM "{table}" WHERE "{column}" IN ({placeholders(len(part))})',
            tuple(part),
        )
        removed += max(cursor.rowcount, 0)
    return removed


def check_integrity(connection: sqlite3.Connection, path: Path) -> None:
    result = connection.execute("PRAGMA integrity_check").fetchone()
    if result is None or str(result[0]).lower() != "ok":
        raise CleanerError(f"数据库完整性检查失败：{path}: {result[0] if result else 'unknown'}")


def clean_state_db(path: Path, thread_ids: Sequence[str]) -> dict[str, int]:
    counts: dict[str, int] = {}
    with connect_sqlite(path, readonly=False) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("BEGIN IMMEDIATE")
        try:
            if {"parent_thread_id", "child_thread_id"}.issubset(
                table_columns(connection, "thread_spawn_edges")
            ):
                connection.execute(
                    "CREATE TEMP TABLE IF NOT EXISTS ghost_cleaner_ids "
                    "(id TEXT PRIMARY KEY)"
                )
                connection.execute("DELETE FROM ghost_cleaner_ids")
                connection.executemany(
                    "INSERT OR IGNORE INTO ghost_cleaner_ids(id) VALUES (?)",
                    ((thread_id,) for thread_id in thread_ids),
                )
                cursor = connection.execute(
                    "DELETE FROM thread_spawn_edges "
                    "WHERE parent_thread_id IN (SELECT id FROM ghost_cleaner_ids) "
                    "OR child_thread_id IN (SELECT id FROM ghost_cleaner_ids)"
                )
                counts["state.thread_spawn_edges"] = max(cursor.rowcount, 0)
            counts["state.thread_dynamic_tools"] = delete_single_column(
                connection, "thread_dynamic_tools", "thread_id", thread_ids
            )
            counts["state.threads"] = delete_single_column(
                connection, "threads", "id", thread_ids
            )
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        check_integrity(connection, path)
    return counts


def clean_catalog_db(
    path: Path,
    thread_ids: Sequence[str],
    *,
    include_automation_runs: bool,
) -> dict[str, int]:
    if not path.is_file():
        return {}
    counts: dict[str, int] = {}
    with connect_sqlite(path, readonly=False) as connection:
        connection.execute("BEGIN IMMEDIATE")
        try:
            for table in ("local_thread_catalog", "thread_timeline_ledger", "inbox_items"):
                counts[f"catalog.{table}"] = delete_single_column(
                    connection, table, "thread_id", thread_ids
                )
            if include_automation_runs:
                counts["catalog.automation_runs"] = delete_single_column(
                    connection, "automation_runs", "thread_id", thread_ids
                )
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        check_integrity(connection, path)
    return counts


def clean_summaries_db(path: Path, thread_ids: Sequence[str]) -> dict[str, int]:
    if not path.is_file():
        return {}
    with connect_sqlite(path, readonly=False) as connection:
        connection.execute("BEGIN IMMEDIATE")
        try:
            removed = delete_single_column(
                connection, "thread_turn_summaries", "thread_id", thread_ids
            )
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        check_integrity(connection, path)
    return {"summaries.thread_turn_summaries": removed}


def clean_history_db(path: Path, thread_ids: Sequence[str]) -> dict[str, int]:
    counts: dict[str, int] = {}
    with connect_sqlite(path, readonly=False) as connection:
        connection.execute("BEGIN IMMEDIATE")
        try:
            for table in ("thread_items", "thread_turns", "thread_history_projection_state"):
                counts[f"{path.name}.{table}"] = delete_single_column(
                    connection, table, "thread_id", thread_ids
                )
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        check_integrity(connection, path)
    return counts


def count_sqlite_refs(
    path: Path, table: str, column: str, thread_ids: Sequence[str]
) -> int:
    if not path.is_file():
        return 0
    with connect_sqlite(path, readonly=True) as connection:
        if column not in table_columns(connection, table):
            return 0
        count = 0
        for part in chunks(thread_ids):
            row = connection.execute(
                f'SELECT COUNT(*) FROM "{table}" '
                f'WHERE "{column}" IN ({placeholders(len(part))})',
                tuple(part),
            ).fetchone()
            count += int(row[0]) if row else 0
        return count


def verify(layout: Layout, thread_ids: Sequence[str]) -> dict[str, int]:
    residual: dict[str, int] = {}
    checks = (
        (layout.state_db, "threads", "id", "state.threads"),
        (layout.state_db, "thread_dynamic_tools", "thread_id", "state.thread_dynamic_tools"),
        (layout.catalog_db, "local_thread_catalog", "thread_id", "catalog.local_thread_catalog"),
        (layout.catalog_db, "thread_timeline_ledger", "thread_id", "catalog.thread_timeline_ledger"),
        (layout.catalog_db, "inbox_items", "thread_id", "catalog.inbox_items"),
        (layout.summaries_db, "thread_turn_summaries", "thread_id", "summaries"),
    )
    for path, table, column, label in checks:
        count = count_sqlite_refs(path, table, column, thread_ids)
        if count:
            residual[label] = count
    for history_db in layout.history_dbs:
        for table in ("thread_items", "thread_turns", "thread_history_projection_state"):
            count = count_sqlite_refs(history_db, table, "thread_id", thread_ids)
            if count:
                residual[f"{history_db.name}.{table}"] = count
    return residual


def expand_descendant_thread_ids(state_db: Path, seed_ids: Iterable[str]) -> set[str]:
    expanded = {thread_id.lower() for thread_id in seed_ids}
    with connect_sqlite(state_db, readonly=True) as connection:
        if not {"parent_thread_id", "child_thread_id"}.issubset(
            table_columns(connection, "thread_spawn_edges")
        ):
            return expanded
        edges = [
            (str(row[0]).lower(), str(row[1]).lower())
            for row in connection.execute(
                "SELECT parent_thread_id, child_thread_id FROM thread_spawn_edges"
            )
        ]
    changed = True
    while changed:
        changed = False
        for parent_id, child_id in edges:
            if parent_id in expanded and child_id not in expanded:
                expanded.add(child_id)
                changed = True
    return expanded


def backup_sqlite_database(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with connect_sqlite(source, readonly=True) as source_connection:
        with sqlite3.connect(destination) as destination_connection:
            source_connection.backup(destination_connection)


def create_index_backup(layout: Layout, quarantine_dir: Path) -> list[str]:
    backed_up: list[str] = []
    databases = (
        layout.state_db,
        layout.catalog_db,
        layout.summaries_db,
        *layout.history_dbs,
    )
    database_dir = quarantine_dir / "index_backup" / "databases"
    for source in databases:
        if not source.is_file():
            continue
        destination = database_dir / source.name
        backup_sqlite_database(source, destination)
        backed_up.append(str(destination.relative_to(quarantine_dir)))

    file_dir = quarantine_dir / "index_backup" / "files"
    for source in (layout.session_index, *layout.global_state_files):
        if not source.is_file():
            continue
        file_dir.mkdir(parents=True, exist_ok=True)
        destination = file_dir / source.name
        shutil.copy2(source, destination)
        backed_up.append(str(destination.relative_to(quarantine_dir)))
    return backed_up


def create_quarantine_dir(home: Path) -> Path:
    stamp = datetime_module.datetime.now(datetime_module.timezone.utc).strftime(
        "%Y%m%dT%H%M%S.%fZ"
    )
    destination = home / "deleted_sessions" / stamp
    destination.mkdir(parents=True, exist_ok=False)
    return destination


def quarantine_transcripts(
    paths: Iterable[Path], home: Path, quarantine_dir: Path
) -> list[tuple[Path, Path]]:
    moved: list[tuple[Path, Path]] = []
    for source in sorted(set(paths)):
        if not source.is_file():
            continue
        resolved = source.resolve()
        try:
            relative = resolved.relative_to(home.resolve())
        except ValueError as exc:
            raise CleanerError(f"拒绝移动 CODEX_HOME 之外的文件：{resolved}") from exc
        destination = quarantine_dir / "transcripts" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.replace(resolved, destination)
        moved.append((resolved, destination))
    return moved


def rollback_quarantined_transcripts(moved: Sequence[tuple[Path, Path]]) -> None:
    for original, quarantined in reversed(moved):
        if not quarantined.is_file():
            continue
        original.parent.mkdir(parents=True, exist_ok=True)
        os.replace(quarantined, original)


def write_quarantine_manifest(
    quarantine_dir: Path,
    *,
    status: str,
    conversations: Sequence[Conversation],
    related_ids: Sequence[str],
    moved: Sequence[tuple[Path, Path]],
    backups: Sequence[str],
    error: str = "",
) -> None:
    payload = {
        "version": VERSION,
        "status": status,
        "created_at": datetime_module.datetime.now(
            datetime_module.timezone.utc
        ).isoformat(),
        "conversations": [
            {
                "session_id": item.session_id,
                "title": item.title,
                "project_path": item.project_path,
            }
            for item in conversations
        ],
        "related_thread_ids": list(related_ids),
        "moved_transcripts": [
            {
                "original": str(original),
                "quarantined": str(quarantined),
            }
            for original, quarantined in moved
        ],
        "index_backups": list(backups),
        "error": error,
    }
    encoded = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8") + b"\n"
    atomic_write(quarantine_dir / "manifest.json", encoded)


def cleanup_thread_ids(
    layout: Layout, thread_ids: Sequence[str], *, include_automation_runs: bool
) -> dict[str, int]:
    ids = sorted(set(thread_ids))
    counts: dict[str, int] = {}
    counts.update(clean_state_db(layout.state_db, ids))
    counts.update(
        clean_catalog_db(
            layout.catalog_db,
            ids,
            include_automation_runs=include_automation_runs,
        )
    )
    counts.update(clean_summaries_db(layout.summaries_db, ids))
    for history_db in layout.history_dbs:
        counts.update(clean_history_db(history_db, ids))
    id_set = set(ids)
    counts["session_index.jsonl"] = clean_session_index(layout.session_index, id_set)
    for state_file in layout.global_state_files:
        counts[state_file.name] = clean_global_state(state_file, id_set)

    residual = verify(layout, ids)
    if residual:
        details = ", ".join(f"{name}={count}" for name, count in sorted(residual.items()))
        raise CleanerError(f"清理后复检仍发现活动索引引用：{details}")
    return counts


def delete_conversations(
    layout: Layout, conversations: Sequence[Conversation]
) -> tuple[Path, dict[str, int], int, int]:
    if not conversations:
        raise CleanerError("没有选择要删除的对话。")
    protected = [item for item in conversations if item.protected]
    if protected:
        raise CleanerError("所选对话中包含自动化任务，已拒绝删除。")

    seed_ids: set[str] = set()
    transcript_paths: set[Path] = set()
    for conversation in conversations:
        seed_ids.update(conversation.related_ids)
        transcript_paths.update(conversation.transcript_paths)
    related_ids = sorted(expand_descendant_thread_ids(layout.state_db, seed_ids))

    quarantine_dir = create_quarantine_dir(layout.home)
    backups = create_index_backup(layout, quarantine_dir)
    moved: list[tuple[Path, Path]] = []
    try:
        moved = quarantine_transcripts(transcript_paths, layout.home, quarantine_dir)
        write_quarantine_manifest(
            quarantine_dir,
            status="prepared",
            conversations=conversations,
            related_ids=related_ids,
            moved=moved,
            backups=backups,
        )
        counts = cleanup_thread_ids(
            layout, related_ids, include_automation_runs=False
        )
    except Exception as exc:
        try:
            rollback_quarantined_transcripts(moved)
            write_quarantine_manifest(
                quarantine_dir,
                status="failed_rolled_back_transcripts",
                conversations=conversations,
                related_ids=related_ids,
                moved=moved,
                backups=backups,
                error=str(exc),
            )
        except Exception:
            pass
        if isinstance(exc, CleanerError):
            raise
        raise CleanerError(f"对话删除失败：{exc}") from exc

    write_quarantine_manifest(
        quarantine_dir,
        status="completed",
        conversations=conversations,
        related_ids=related_ids,
        moved=moved,
        backups=backups,
    )
    return quarantine_dir, counts, len(moved), len(related_ids)


def transcript_provider(path: Path) -> str | None:
    """读取单个 rollout 记录在 session_meta 里的 model_provider。"""
    payload = session_meta_payload(path)
    if payload is None:
        return None
    provider = payload.get("model_provider")
    return str(provider) if isinstance(provider, str) and provider else None


def switch_transcript_provider(
    path: Path, new_provider: str
) -> tuple[str, str] | None:
    """Safely update one rollout's provider marker.

    Rollout files are JSONL.  The provider is stored in the first
    ``session_meta`` line, but the remaining lines contain the actual
    transcript and must never be discarded.  Paginated history also stores
    byte offsets into source rollouts, so changing the byte length of the
    first line would invalidate every descendant cutoff.  Refuse such a
    change; callers can create a continuation/fork instead.
    """
    try:
        original = path.read_bytes()
        first_end = original.find(b"\n")
        if first_end < 0:
            first_line = original
            remainder = b""
        else:
            first_line = original[: first_end + 1]
            remainder = original[first_end + 1 :]
        parsed = json.loads(first_line.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(parsed, dict) or parsed.get("type") != "session_meta":
        return None
    payload = parsed.get("payload")
    if not isinstance(payload, dict):
        return None
    old_provider = payload.get("model_provider")
    if not isinstance(old_provider, str) or not old_provider:
        return None
    if old_provider == new_provider:
        return None
    marker = f'"model_provider":"{old_provider}"'.encode("utf-8")
    if marker not in first_line:
        return None
    replacement = f'"model_provider":"{new_provider}"'.encode("utf-8")
    rewritten = first_line.replace(marker, replacement, 1)
    if len(rewritten) != len(first_line):
        # Byte offsets in paginated descendants refer to this exact file.
        # An in-place length change would make the lineage invalid.
        return None
    atomic_write(path, rewritten + remainder)
    return old_provider, new_provider


def config_provider_names(home: Path) -> list[str]:
    """从 config.toml 的 [model_providers.*] 收集自定义 provider 名（不含内建 openai）。"""
    config_path = home / "config.toml"
    try:
        import tomllib

        with config_path.open("rb") as handle:
            data = tomllib.load(handle)
        providers = data.get("model_providers")
        names = [str(key) for key in providers] if isinstance(providers, dict) else []
    except (ImportError, OSError, ValueError):
        names = []
        try:
            text = config_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            text = ""
        names = [
            match.group(1)
            for match in re.finditer(
                r"^\[model_providers\.([^\]]+)\]$", text, re.MULTILINE
            )
            if "." not in match.group(1)
        ]
    return sorted(names)


def switch_conversations_provider(
    conversations: Sequence[Conversation], target: str
) -> tuple[dict[str, dict[str, int]], list[str]]:
    """把一批对话的所有 rollout 切到目标 provider。

    返回 (会话统计, 未变化会话列表)；统计形如
    {session_id: {旧provider: 改动文件数}}。
    """
    stats: dict[str, dict[str, int]] = {}
    unchanged: list[str] = []
    for conversation in conversations:
        per_session: dict[str, int] = {}
        for path in conversation.transcript_paths:
            result = switch_transcript_provider(path, target)
            if result is None:
                continue
            old_provider, _ = result
            per_session[old_provider] = per_session.get(old_provider, 0) + 1
        if per_session:
            stats[conversation.session_id] = per_session
        else:
            unchanged.append(conversation.session_id)
    return stats, unchanged


def format_updated_at(timestamp_ms: int) -> str:
    if timestamp_ms <= 0:
        return "未知时间"
    return datetime_module.datetime.fromtimestamp(timestamp_ms / 1000).strftime(
        "%m-%d %H:%M"
    )


def project_display_name(path: str) -> str:
    if path.startswith("("):
        return path
    name = Path(path).name
    return name or path


def run_conversation_tui(
    projects: Sequence[ProjectGroup], layout: Layout
) -> set[str]:
    try:
        import curses
    except ImportError as exc:
        raise CleanerError("当前 Python 不包含 curses，无法启动终端界面。") from exc

    conversation_by_id = {
        conversation.session_id: conversation
        for project in projects
        for conversation in project.conversations
    }

    def collect_providers() -> dict[str, str]:
        providers: dict[str, str] = {}
        for project in projects:
            for conversation in project.conversations:
                values = {
                    provider
                    for path in conversation.transcript_paths
                    if (provider := transcript_provider(path))
                }
                if len(values) == 1:
                    providers[conversation.session_id] = values.pop()
                elif values:
                    providers[conversation.session_id] = "mixed"
        return providers

    def add_text(screen: Any, y: int, x: int, text: str, attr: int = 0) -> None:
        height, width = screen.getmaxyx()
        if y < 0 or y >= height or x >= width:
            return
        sanitized = text.replace("\n", " ").replace("\r", " ")
        try:
            screen.addnstr(y, x, sanitized, max(width - x - 1, 0), attr)
        except curses.error:
            pass

    def confirm_delete(screen: Any, selected_ids: set[str]) -> bool:
        choice = 0
        selected_items = [conversation_by_id[item] for item in sorted(selected_ids)]
        while True:
            screen.erase()
            height, width = screen.getmaxyx()
            add_text(screen, 1, 2, "确认删除所选对话？", curses.A_BOLD)
            add_text(
                screen,
                3,
                2,
                f"将处理 {len(selected_items)} 条对话；所有 JSONL 会移入 deleted_sessions 隔离区。",
            )
            add_text(screen, 4, 2, "索引会从本机数据库移除，Codex/ChatGPT 将自动退出。")
            preview_limit = max(height - 10, 0)
            for index, item in enumerate(selected_items[:preview_limit], start=0):
                add_text(
                    screen,
                    6 + index,
                    4,
                    f"- {item.title}  ({project_display_name(item.project_path)})",
                )
            if len(selected_items) > preview_limit:
                add_text(
                    screen,
                    height - 4,
                    4,
                    f"…另有 {len(selected_items) - preview_limit} 条",
                )

            cancel_attr = curses.A_REVERSE if choice == 0 else curses.A_NORMAL
            delete_attr = curses.A_REVERSE if choice == 1 else curses.A_NORMAL
            button_y = height - 2
            add_text(screen, button_y, 2, "[ 取消 ]", cancel_attr)
            add_text(screen, button_y, 14, "[ 移入隔离区并删除 ]", delete_attr)
            screen.refresh()
            key = screen.getch()
            if key in (curses.KEY_LEFT, curses.KEY_RIGHT, 9):
                choice = 1 - choice
            elif key in (10, 13, curses.KEY_ENTER):
                return choice == 1
            elif key in (27, ord("q"), ord("Q")):
                return False

    def tui_main(screen: Any) -> set[str]:
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        screen.keypad(True)
        expanded: set[str] = {projects[0].path} if projects else set()
        selected: set[str] = set()
        cursor = 0
        top = 0
        provider_by_id = collect_providers()
        message = "Enter/→ 展开项目；空格选择对话；d 删除；p 切换 provider；q 退出"

        def choose_provider(screen: Any, providers: Sequence[str]) -> str | None:
            choice = 0
            while True:
                screen.erase()
                height, width = screen.getmaxyx()
                add_text(
                    screen, 1, 2, "选择要切换到的 provider：", curses.A_BOLD
                )
                add_text(
                    screen,
                    2,
                    2,
                    f"将修改已选的 {len(selected)} 条对话（会话记录里的 model_provider）；"
                    "Esc 取消",
                )
                for index, name in enumerate(providers):
                    attr = curses.A_REVERSE if index == choice else curses.A_NORMAL
                    label = f"{name}（官方）" if name == "openai" else name
                    add_text(screen, 4 + index, 4, label, attr)
                add_text(
                    screen,
                    height - 1,
                    1,
                    "↑↓ 选择  Enter 确认  Esc 取消",
                    curses.A_DIM,
                )
                screen.refresh()
                key = screen.getch()
                if key == curses.KEY_UP:
                    choice = max(choice - 1, 0)
                elif key == curses.KEY_DOWN:
                    choice = min(choice + 1, len(providers) - 1)
                elif key in (10, 13, curses.KEY_ENTER):
                    return providers[choice]
                elif key in (27, ord("q"), ord("Q")):
                    return None

        def confirm_switch(screen: Any, target: str) -> bool:
            choice = 0
            selected_items = [conversation_by_id[item] for item in sorted(selected)]
            while True:
                screen.erase()
                height, width = screen.getmaxyx()
                add_text(screen, 1, 2, f"确认切换 provider 到 {target}？", curses.A_BOLD)
                add_text(
                    screen,
                    3,
                    2,
                    "只改会话记录（rollout 第一行），对话内容与索引不动；可随时切回。",
                )
                preview_limit = max(height - 10, 0)
                for index, item in enumerate(selected_items[:preview_limit]):
                    current = provider_by_id.get(item.session_id, "?")
                    add_text(
                        screen,
                        5 + index,
                        4,
                        f"- {item.title}  ({current} → {target})",
                    )
                if len(selected_items) > preview_limit:
                    add_text(
                        screen,
                        height - 4,
                        4,
                        f"…另有 {len(selected_items) - preview_limit} 条",
                    )
                cancel_attr = curses.A_REVERSE if choice == 0 else curses.A_NORMAL
                switch_attr = curses.A_REVERSE if choice == 1 else curses.A_NORMAL
                button_y = height - 2
                add_text(screen, button_y, 2, "[ 取消 ]", cancel_attr)
                add_text(screen, button_y, 14, "[ 确认切换 ]", switch_attr)
                screen.refresh()
                key = screen.getch()
                if key in (curses.KEY_LEFT, curses.KEY_RIGHT, 9):
                    choice = 1 - choice
                elif key in (10, 13, curses.KEY_ENTER):
                    return choice == 1
                elif key in (27, ord("q"), ord("Q")):
                    return False

        def visible_rows() -> list[tuple[str, ProjectGroup, Conversation | None]]:
            rows: list[tuple[str, ProjectGroup, Conversation | None]] = []
            for project in projects:
                rows.append(("project", project, None))
                if project.path in expanded:
                    rows.extend(
                        ("conversation", project, conversation)
                        for conversation in project.conversations
                    )
            return rows

        while True:
            rows = visible_rows()
            if rows:
                cursor = max(0, min(cursor, len(rows) - 1))
            else:
                cursor = 0
            height, width = screen.getmaxyx()
            body_height = max(height - 5, 1)
            if cursor < top:
                top = cursor
            if cursor >= top + body_height:
                top = cursor - body_height + 1

            screen.erase()
            add_text(
                screen,
                0,
                1,
                f"Codex 对话管理器  v{VERSION}    已选择 {len(selected)} 条",
                curses.A_BOLD,
            )
            add_text(
                screen,
                1,
                1,
                "按稳定 session_id 聚合；[] 内标签为会话的 provider，p 可切换",
            )
            if width < 72 or height < 14:
                add_text(screen, 3, 1, "终端窗口太小，请放大到至少 72×14。", curses.A_BOLD)
            elif not rows:
                add_text(screen, 3, 1, "没有找到可管理的本地对话。")
            else:
                for screen_row, row_index in enumerate(
                    range(top, min(len(rows), top + body_height)), start=2
                ):
                    kind, project, conversation = rows[row_index]
                    attr = curses.A_REVERSE if row_index == cursor else curses.A_NORMAL
                    if kind == "project":
                        marker = "[-]" if project.path in expanded else "[+]"
                        selected_in_project = sum(
                            item.session_id in selected for item in project.conversations
                        )
                        line = (
                            f"{marker} {project_display_name(project.path)} "
                            f"({len(project.conversations)} 对话"
                            + (
                                f"，已选 {selected_in_project}" if selected_in_project else ""
                            )
                            + f")  {project.path}"
                        )
                        add_text(screen, screen_row, 1, line, attr | curses.A_BOLD)
                    else:
                        assert conversation is not None
                        checked = "x" if conversation.session_id in selected else " "
                        tags: list[str] = []
                        tags.append(provider_by_id.get(conversation.session_id, "?"))
                        if conversation.fragment_count > 1:
                            tags.append(f"{conversation.fragment_count}分片")
                        if conversation.archived:
                            tags.append("归档")
                        if conversation.health != "正常":
                            tags.append(conversation.health)
                        if conversation.protected:
                            tags.append("自动化保护")
                        suffix = " " + " ".join(f"[{tag}]" for tag in tags) if tags else ""
                        line = (
                            f"    [{checked}] {format_updated_at(conversation.updated_at_ms)} "
                            f"{conversation.title}{suffix}"
                        )
                        add_text(screen, screen_row, 1, line, attr)

            add_text(screen, height - 2, 1, message)
            add_text(
                screen,
                height - 1,
                1,
                "↑↓ 移动  ←→/Enter 折叠展开  Space 选择  a 全选  x 清空  d 删除  p 切换Provider  q 退出",
                curses.A_DIM,
            )
            screen.refresh()
            key = screen.getch()

            if key in (ord("q"), ord("Q"), 27):
                return set()
            if not rows:
                continue
            if key == curses.KEY_UP:
                cursor = max(cursor - 1, 0)
                continue
            if key == curses.KEY_DOWN:
                cursor = min(cursor + 1, len(rows) - 1)
                continue
            if key == curses.KEY_PPAGE:
                cursor = max(cursor - body_height, 0)
                continue
            if key == curses.KEY_NPAGE:
                cursor = min(cursor + body_height, len(rows) - 1)
                continue

            kind, project, conversation = rows[cursor]
            if key == curses.KEY_RIGHT:
                expanded.add(project.path)
            elif key == curses.KEY_LEFT:
                if kind == "conversation":
                    project_row = next(
                        index
                        for index, row in enumerate(rows)
                        if row[0] == "project" and row[1].path == project.path
                    )
                    cursor = project_row
                expanded.discard(project.path)
            elif key in (10, 13, curses.KEY_ENTER):
                if kind == "project":
                    if project.path in expanded:
                        expanded.discard(project.path)
                    else:
                        expanded.add(project.path)
                elif conversation is not None and not conversation.protected:
                    if conversation.session_id in selected:
                        selected.remove(conversation.session_id)
                    else:
                        selected.add(conversation.session_id)
            elif key == ord(" ") and conversation is not None:
                if conversation.protected:
                    message = "该对话关联自动化任务，已保护，不能从 TUI 删除。"
                elif conversation.session_id in selected:
                    selected.remove(conversation.session_id)
                else:
                    selected.add(conversation.session_id)
            elif key in (ord("a"), ord("A")):
                selectable = {
                    item.session_id
                    for item in project.conversations
                    if not item.protected
                }
                if selectable and selectable.issubset(selected):
                    selected.difference_update(selectable)
                else:
                    selected.update(selectable)
            elif key in (ord("x"), ord("X")):
                selected.clear()
            elif key in (ord("p"), ord("P")):
                if not selected:
                    message = "请先用空格选择至少一条对话。"
                else:
                    providers = ["openai"] + [
                        name
                        for name in config_provider_names(layout.home)
                        if name != "openai"
                    ]
                    target = choose_provider(screen, providers)
                    if target is None:
                        message = "已取消 provider 切换。"
                    elif not confirm_switch(screen, target):
                        message = "已取消 provider 切换。"
                    else:
                        stats, unchanged = switch_conversations_provider(
                            [
                                conversation_by_id[sid]
                                for sid in sorted(selected)
                            ],
                            target,
                        )
                        provider_by_id = collect_providers()
                        if not stats:
                            message = f"所选对话已经全部是 {target}，没有需要修改的。"
                        else:
                            aggregate: dict[str, int] = {}
                            for counts in stats.values():
                                for old, count in counts.items():
                                    aggregate[old] = aggregate.get(old, 0) + count
                            total = sum(aggregate.values())
                            detail = "，".join(
                                f"{old}→{target}×{count}"
                                for old, count in sorted(aggregate.items())
                            )
                            message = (
                                f"已将 {len(stats)} 条对话切到 {target}"
                                f"（{detail}，共 {total} 个文件）"
                            )
                            if unchanged:
                                message += (
                                    f"；{len(unchanged)} 条已经是 {target}，未改动"
                                )
            elif key in (ord("d"), ord("D")):
                if not selected:
                    message = "请先用空格选择至少一条对话。"
                elif confirm_delete(screen, selected):
                    return selected
                else:
                    message = "已取消删除。"

    try:
        return curses.wrapper(tui_main)
    except curses.error as exc:
        raise CleanerError(f"终端界面启动失败：{exc}") from exc


def select_candidates(
    candidates: Sequence[Candidate],
    requested_ids: Sequence[str],
    *,
    include_automation_runs: bool,
) -> list[Candidate]:
    requested = {value.lower() for value in requested_ids}
    selected = [
        item
        for item in candidates
        if not requested
        or item.thread_id in requested
        or item.missing_source_rollout in requested
    ]
    found: set[str] = set()
    for item in selected:
        if item.thread_id in requested:
            found.add(item.thread_id)
        if item.missing_source_rollout in requested:
            found.add(item.missing_source_rollout)
    missing = sorted(requested - found)
    if missing:
        stderr("以下指定 ID 不符合严格幽灵条件，因此不会处理：")
        for thread_id in missing:
            stderr(f"  {thread_id}")

    protected = [item for item in selected if item.has_automation_run]
    if protected and not include_automation_runs:
        stderr("以下任务仍有关联的自动化运行记录，默认跳过：")
        for item in protected:
            stderr(f"  {item.thread_id}")
        stderr("确认连自动化运行记录也要删除时，请加 --include-automation-runs。")
        selected = [item for item in selected if not item.has_automation_run]
    return selected


def apply_cleanup(
    layout: Layout,
    candidates: Sequence[Candidate],
    *,
    include_automation_runs: bool,
) -> None:
    thread_ids = [item.thread_id for item in candidates]
    try:
        counts = cleanup_thread_ids(
            layout,
            thread_ids,
            include_automation_runs=include_automation_runs,
        )
    except Exception as exc:
        raise CleanerError(f"清理失败：{exc}") from exc

    print(f"\n已清理 {len(candidates)} 个幽灵任务。")
    changed_counts = {name: count for name, count in counts.items() if count}
    if changed_counts:
        print("删除的索引记录：")
        for name, count in sorted(changed_counts.items()):
            print(f"  {name}: {count}")
    print("数据库完整性检查：通过")
    print("现在可以重新打开 ChatGPT/Codex 桌面端。")


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "不带参数时打开按项目分组的 Codex 对话终端管理器；"
            "也可扫描并清理 rollout 丢失或分页 lineage 断裂的幽灵任务。"
        )
    )
    default_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    parser.add_argument(
        "--codex-home",
        type=Path,
        default=default_home,
        help=f"Codex 数据目录（默认：{default_home}）",
    )
    parser.add_argument(
        "--tui",
        action="store_true",
        help="显式打开项目/对话终端管理器（不带参数时默认启用）",
    )
    parser.add_argument(
        "--id",
        action="append",
        default=[],
        metavar="THREAD_ID",
        help="只处理指定的幽灵任务；可重复使用",
    )
    parser.add_argument(
        "--scan-only",
        action="store_true",
        help="只扫描，不执行清理",
    )
    parser.add_argument(
        "--include-automation-runs",
        action="store_true",
        help="连同幽灵任务关联的自动化运行记录一起删除",
    )
    parser.add_argument(
        "--allow-running",
        action="store_true",
        help="跳过桌面端/CLI 自动终止与进程检查（不推荐）",
    )
    parser.add_argument("--version", action="version", version=VERSION)
    args = parser.parse_args(argv)

    invalid_ids = [value for value in args.id if not THREAD_ID_RE.fullmatch(value)]
    if invalid_ids:
        parser.error("无效的任务 ID：" + ", ".join(invalid_ids))
    if not argv:
        args.tui = True
    if args.tui and (args.id or args.scan_only or args.include_automation_runs):
        parser.error("终端管理器不能与 --id/--scan-only/--include-automation-runs 同时使用")
    return args


def main(argv: Sequence[str] | None = None) -> int:
    raw_argv = list(argv if argv is not None else sys.argv[1:])
    args = parse_args(raw_argv)
    try:
        layout = discover_layout(args.codex_home)
        if args.tui:
            if not sys.stdin.isatty() or not sys.stdout.isatty():
                raise CleanerError("终端管理器需要在交互式 Terminal 中运行。")
            projects = build_conversation_inventory(layout)
            selected_ids = run_conversation_tui(projects, layout)
            if not selected_ids:
                print("已退出；没有修改任何文件。")
                return 0

            ensure_app_stopped(args.allow_running)
            refreshed_projects = build_conversation_inventory(layout)
            refreshed = {
                conversation.session_id: conversation
                for project in refreshed_projects
                for conversation in project.conversations
            }
            selected_conversations = [
                refreshed[thread_id]
                for thread_id in selected_ids
                if thread_id in refreshed
            ]
            disappeared = sorted(selected_ids - set(refreshed))
            if disappeared:
                stderr("以下对话在 Codex 退出后已不存在，已跳过：")
                for thread_id in disappeared:
                    stderr(f"  {thread_id}")
            if not selected_conversations:
                print("所选对话均已不存在；没有执行删除。")
                return 0

            quarantine_dir, counts, moved_count, related_count = delete_conversations(
                layout, selected_conversations
            )
            print(f"\n已删除 {len(selected_conversations)} 条聚合对话。")
            print(f"已隔离 JSONL：{moved_count} 个")
            print(f"已清理关联任务/分片 ID：{related_count} 个")
            changed_counts = {name: count for name, count in counts.items() if count}
            if changed_counts:
                print("删除的索引记录：")
                for name, count in sorted(changed_counts.items()):
                    print(f"  {name}: {count}")
            print(f"可恢复隔离区：{quarantine_dir}")
            print("数据库完整性检查：通过")
            print("现在可以重新打开 ChatGPT/Codex 桌面端。")
            return 0

        candidates, total = scan(layout)
        print_scan_report(candidates, total)
        selected = select_candidates(
            candidates,
            args.id,
            include_automation_runs=args.include_automation_runs,
        )

        if args.scan_only:
            print("\n只读扫描完成，没有修改任何文件。")
            return 0

        if not selected:
            print("\n没有可清理的任务；未修改任何文件。")
            return 0

        ensure_app_stopped(args.allow_running)
        apply_cleanup(
            layout,
            selected,
            include_automation_runs=args.include_automation_runs,
        )
        return 0
    except CleanerError as exc:
        stderr(f"错误：{exc}")
        return 2
    except KeyboardInterrupt:
        stderr("\n已取消。")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
