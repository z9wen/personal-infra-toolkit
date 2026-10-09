"""Regression tests for codex_ghost_cleaner.py.

Each test builds a fake CODEX_HOME in a temporary directory. Nothing touches
real app data, and process listing/signalling is stubbed.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import sys
from pathlib import Path

import pytest

MODULE_PATH = Path(__file__).resolve().parents[1] / "codex_ghost_cleaner.py"
spec = importlib.util.spec_from_file_location("codex_ghost_cleaner", MODULE_PATH)
cgc = importlib.util.module_from_spec(spec)
sys.modules["codex_ghost_cleaner"] = cgc
spec.loader.exec_module(cgc)


def thread_id(n: int) -> str:
    return f"0199{n:04d}-0000-7000-8000-{n:012d}"


def make_home(root: Path, threads, files) -> Path:
    """threads: [(id, rollout_path)]; files: {relative path: session_meta payload}."""
    root.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(root / "state_5.sqlite") as db:
        db.execute(
            "create table threads(id text primary key, rollout_path text, title text, archived int,"
            " source text, thread_source text, cwd text, created_at int, updated_at int)"
        )
        for index, (tid, rollout) in enumerate(threads):
            db.execute(
                "insert into threads values(?,?,?,?,?,?,?,?,?)",
                (tid, rollout, "t" + tid[:8], 0, "vscode", "user", "/proj", index, index),
            )
    for relative, payload in files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"type": "session_meta", "payload": payload}) + "\n" + '{"type":"msg"}\n')
    return root


def thread_rows(root: Path) -> int:
    with sqlite3.connect(root / "state_5.sqlite") as db:
        return db.execute("select count(*) from threads").fetchone()[0]


def conversations(layout):
    return [c for project in cgc.build_conversation_inventory(layout) for c in project.conversations]


def test_relocated_codex_home_is_not_treated_as_ghosts(tmp_path):
    ids = [thread_id(10), thread_id(11)]
    files = {f"sessions/2025/rollout-x-{i}.jsonl": {"id": i, "thread_source": "user"} for i in ids}
    home = make_home(
        tmp_path,
        [(i, f"/Users/olduser/.codex/sessions/2025/rollout-x-{i}.jsonl") for i in ids],
        files,
    )
    candidates, total = cgc.scan(cgc.discover_layout(home))
    assert total == 2
    assert candidates == []


def test_partial_quarantine_moves_nothing(tmp_path):
    a = thread_id(1)
    outside = tmp_path / "outside"
    outside.mkdir()
    home = make_home(
        tmp_path / "home",
        [(a, str(tmp_path / "home" / f"sessions/rollout-x-{a}.jsonl"))],
        {
            f"archived_sessions/rollout-a-{a}.jsonl": {"id": a, "thread_source": "user"},
            f"sessions/rollout-x-{a}.jsonl": {"id": a, "thread_source": "user"},
        },
    )
    # One fragment is a symlink pointing outside CODEX_HOME.
    target = outside / f"rollout-x-{a}.jsonl"
    (home / f"sessions/rollout-x-{a}.jsonl").rename(target)
    os.symlink(target, home / f"sessions/rollout-x-{a}.jsonl")

    layout = cgc.discover_layout(home)
    with pytest.raises(cgc.CleanerError):
        cgc.delete_conversations(layout, conversations(layout))
    assert (home / f"archived_sessions/rollout-a-{a}.jsonl").exists()
    assert not list((home / "deleted_sessions").rglob("*.jsonl"))
    assert thread_rows(home) == 1


def test_failure_after_database_changes_restores_indexes(tmp_path):
    a = thread_id(2)
    relative = f"sessions/rollout-x-{a}.jsonl"
    home = make_home(tmp_path, [(a, str(tmp_path / relative))], {relative: {"id": a, "thread_source": "user"}})
    (home / ".codex-global-state.json").write_text(json.dumps({"pinned": [a]}))
    (home / ".codex-global-state.json.bak").write_text('{"pinned": [')  # truncated
    (home / "session_index.jsonl").write_text(json.dumps({"id": a, "thread_name": "x"}) + "\n")

    layout = cgc.discover_layout(home)
    with pytest.raises(cgc.CleanerError):
        cgc.delete_conversations(layout, conversations(layout))
    assert (home / relative).exists()
    assert thread_rows(home) == 1
    assert json.loads((home / ".codex-global-state.json").read_text()) == {"pinned": [a]}
    manifest = json.loads(next((home / "deleted_sessions").rglob("manifest.json")).read_text())
    assert manifest["status"] == "failed_rolled_back"


def test_history_base_of_another_session_is_not_deleted(tmp_path):
    a, b = thread_id(20), thread_id(21)
    ra, rb = f"sessions/rollout-a-{a}.jsonl", f"sessions/rollout-b-{b}.jsonl"
    home = make_home(
        tmp_path,
        [(a, str(tmp_path / ra)), (b, str(tmp_path / rb))],
        {
            ra: {"id": a, "thread_source": "user"},
            rb: {"id": b, "thread_source": "user", "history_mode": "paginated", "history_base": {"thread_id": a}},
        },
    )
    layout = cgc.discover_layout(home)
    by_id = {c.session_id: c for c in conversations(layout)}
    assert a not in by_id[b].related_ids
    cgc.delete_conversations(layout, [by_id[b]])
    with sqlite3.connect(home / "state_5.sqlite") as db:
        assert db.execute("select count(*) from threads where id=?", (a,)).fetchone()[0] == 1
    assert (home / ra).exists()


def test_process_matching_only_targets_codex_executables(monkeypatch):
    uid, me, parent = os.getuid(), os.getpid(), os.getppid()
    other_uid = uid + 1  # a different user, whoever runs the tests (root in containers)
    lines = [
        f"{me} {parent} {uid} python3 cleaner.py",
        f"{parent} 1 {uid} /opt/homebrew/bin/codex",  # our ancestor
        f"101 1 {uid} /Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
        f"102 1 {uid} /usr/bin/tail -f /Applications/ChatGPT.app/Contents/Info.plist",
        f"103 1 {uid} vim notes-about-Codex Helper.txt",
        f"104 1 {uid} /Users/me/bin/codex exec fix tests",
        f"105 1 {uid} /bin/zsh -c grep /node_modules/@openai/codex/ x",
        f"106 1 {other_uid} /Applications/Codex.app/Contents/MacOS/Codex",
        f"107 1 {uid} /Applications/ChatGPT.app/Contents/Frameworks/ChatGPT Helper (Renderer).app/Contents/MacOS/ChatGPT Helper (Renderer)",
        f"108 1 {uid} node /usr/local/lib/node_modules/@openai/codex/bin/codex.js",
    ]

    class Result:
        stdout = "\n".join(lines)

    monkeypatch.setattr(cgc.subprocess, "run", lambda *args, **kwargs: Result())
    assert sorted(p.pid for p in cgc.find_running_codex_processes()) == [101, 104, 107, 108]


@pytest.mark.parametrize(
    ("target", "outcome"),
    [("azure", cgc.SWITCH_LENGTH), ("custom", cgc.SWITCH_CHANGED), ("openai", cgc.SWITCH_SAME)],
)
def test_provider_switch_outcomes(tmp_path, target, outcome):
    rollout = tmp_path / "r.jsonl"
    meta = {"type": "session_meta", "payload": {"id": thread_id(1), "model_provider": "openai"}}
    rollout.write_text(json.dumps(meta, separators=(",", ":")) + "\n" + '{"type":"msg"}\n')
    assert cgc.switch_transcript_provider(rollout, target)[0] == outcome
    assert rollout.read_text().endswith('{"type":"msg"}\n')


def test_provider_names_are_json_escaped(tmp_path):
    rollout = tmp_path / "r.jsonl"
    meta = {"type": "session_meta", "payload": {"id": thread_id(1), "model_provider": "custom"}}
    rollout.write_text(json.dumps(meta, separators=(",", ":")) + "\n")
    assert cgc.switch_transcript_provider(rollout, 'a"cde')[0] == cgc.SWITCH_CHANGED
    assert cgc.session_meta_payload(rollout)["model_provider"] == 'a"cde'


def test_repair_mode_requires_confirmation_without_a_tty(monkeypatch):
    monkeypatch.setattr(sys.stdin, "isatty", lambda: False)
    with pytest.raises(cgc.CleanerError):
        cgc.confirm_repair(3, assume_yes=False)
    assert cgc.confirm_repair(3, assume_yes=True)
