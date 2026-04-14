#!/usr/bin/env python3
"""Incremental OpenClaw session JSONL → Appleseed Memory bridge.

Watches session JSONL files under APPLESEED_SYNC_SESSION_DIRS. Each file is an
OpenClaw session log (one JSON object per line). We track a byte offset per
file, parse only new lines, POST new messages to ``/threads/{id}/append``, and
(optionally) trigger ``/memories/distill`` so the content becomes searchable.

Env vars (same base as sync.py):
  APPLESEED_SYNC_SESSION_DIRS   Colon-separated JSONL session directories.
  APPLESEED_SYNC_URL            Appleseed /memories endpoint (we derive /threads from it).
  APPLESEED_SYNC_HOSTNAME       Logical host label.
  APPLESEED_SYNC_USER_ID        user_id tag.
  APPLESEED_SYNC_AGENT_ID       agent_id tag.
  APPLESEED_SYNC_SESSION_STATE  State file. Default: ~/.openclaw/appleseed-memory-sync/session_state.json
  APPLESEED_SYNC_DISTILL        "1" (default) = call /memories/distill after append; "0" = skip.
  APPLESEED_SYNC_DISTILL_DEBOUNCE_SEC  Min seconds between distills per thread. Default 60.
"""

from __future__ import annotations

import json
import logging
import os
import re
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

import requests

try:
    from watchdog.observers import Observer
    from watchdog.events import FileSystemEventHandler
    HAS_WATCHDOG = True
except ImportError:
    HAS_WATCHDOG = False
    Observer = None
    FileSystemEventHandler = object


# ── Config ────────────────────────────────────────────────────────────────
def _split_paths(raw: str) -> List[Path]:
    return [Path(p).expanduser() for p in raw.split(":") if p.strip()]


SESSION_DIRS = _split_paths(os.environ.get("APPLESEED_SYNC_SESSION_DIRS", ""))
MEMORIES_URL = os.environ.get("APPLESEED_SYNC_URL", "http://localhost:6420/memories")
# Derive base (strip trailing /memories) then build /threads + /memories/distill
BASE_URL = MEMORIES_URL.rstrip("/")
if BASE_URL.endswith("/memories"):
    BASE_URL = BASE_URL[: -len("/memories")]
THREADS_URL = f"{BASE_URL}/threads"
DISTILL_URL = f"{BASE_URL}/memories/distill"

HOSTNAME = os.environ.get("APPLESEED_SYNC_HOSTNAME", socket.gethostname())
USER_ID = os.environ.get("APPLESEED_SYNC_USER_ID", "")
AGENT_ID = os.environ.get("APPLESEED_SYNC_AGENT_ID", "")
STATE_FILE = Path(os.environ.get(
    "APPLESEED_SYNC_SESSION_STATE",
    str(Path.home() / ".openclaw" / "appleseed-memory-sync" / "session_state.json"),
))
DISTILL_ENABLED = os.environ.get("APPLESEED_SYNC_DISTILL", "1") == "1"
DISTILL_DEBOUNCE = float(os.environ.get("APPLESEED_SYNC_DISTILL_DEBOUNCE_SEC", "60"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("session-sync")


# ── State ─────────────────────────────────────────────────────────────────
def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            log.warning("Corrupt session state, starting fresh")
    return {}


def save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2))


# ── Client-side content filtering / stripping ─────────────────────────────
# OpenClaw plugin injects this block *before* the real user content. We strip it.
AUTO_RECALL_RE = re.compile(
    r"^\[Appleseed Memory Auto-Recall\].*?(?=\n\n|\Z)",
    re.DOTALL,
)

DROP_PREFIXES = (
    "[cron:",
    "System (untrusted):",
)
DROP_EXACT = {"HEARTBEAT_OK", "NO_REPLY"}


def strip_and_filter(content: str) -> Optional[str]:
    """Return cleaned content, or None if the message should be dropped."""
    cleaned = AUTO_RECALL_RE.sub("", content).strip()
    if not cleaned:
        return None
    if cleaned in DROP_EXACT:
        return None
    for prefix in DROP_PREFIXES:
        if cleaned.startswith(prefix):
            return None
    return cleaned


# ── JSONL message extraction ──────────────────────────────────────────────
def _flatten_content(raw) -> str:
    """Flatten OpenClaw content (list of parts or string) into plain text."""
    if isinstance(raw, str):
        return raw
    if isinstance(raw, list):
        parts = []
        for p in raw:
            if isinstance(p, dict):
                if p.get("type") == "text" and p.get("text"):
                    parts.append(p["text"])
                # ignore toolCall / toolResult / thinking blocks for ingestion
            elif isinstance(p, str):
                parts.append(p)
        return "\n".join(parts)
    return ""


def parse_new_lines(path: Path, offset: int) -> tuple[int, Optional[str], List[dict]]:
    """Read from offset to EOF, return (new_offset, session_id_if_seen, messages).

    Only fully-terminated lines are consumed. Trailing partial lines stay
    unread (offset left pointing at their start) so the next call can retry.
    """
    try:
        size = path.stat().st_size
    except OSError:
        return offset, None, []
    if size < offset:
        # File was rotated/truncated. Reset.
        log.warning("File shrank, resetting offset: %s", path)
        offset = 0
    if size == offset:
        return offset, None, []

    session_id: Optional[str] = None
    messages: List[dict] = []
    with path.open("rb") as f:
        f.seek(offset)
        buf = f.read()
    # Split on newline; keep only complete lines.
    text = buf.decode("utf-8", errors="replace")
    lines = text.split("\n")
    trailing = lines.pop()  # partial or empty
    consumed_bytes = len(buf) - len(trailing.encode("utf-8"))
    new_offset = offset + consumed_bytes

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = item.get("type")
        if t == "session" and not session_id:
            session_id = item.get("id")
        elif t == "message":
            msg = item.get("message", {})
            role = msg.get("role")
            if role not in ("user", "assistant"):
                continue
            content = _flatten_content(msg.get("content"))
            cleaned = strip_and_filter(content) if content else None
            if cleaned:
                messages.append({"role": role, "content": cleaned})

    return new_offset, session_id, messages


# ── Appleseed API calls ───────────────────────────────────────────────────────
def ensure_thread(thread_id: str) -> bool:
    """POST /threads if missing. Idempotent enough — 409 / already-exists is fine."""
    payload = {"thread_id": thread_id, "title": f"Session {thread_id}"}
    if USER_ID:
        payload["user_id"] = USER_ID
    if AGENT_ID:
        payload["agent_id"] = AGENT_ID
    try:
        resp = requests.post(THREADS_URL, json=payload, timeout=10)
        # 200 = created; 409/400 with "exists" we tolerate.
        if resp.status_code in (200, 201):
            return True
        if resp.status_code == 409:
            return True
        log.warning("POST /threads %s → %s %s", thread_id, resp.status_code, resp.text[:200])
        return False
    except Exception as e:
        log.error("POST /threads failed: %s", e)
        return False


def append_messages(thread_id: str, messages: List[dict]) -> bool:
    try:
        resp = requests.post(
            f"{THREADS_URL}/{thread_id}/append",
            json={"messages": messages},
            timeout=30,
        )
        if resp.status_code == 404:
            # Thread doesn't exist — try to create then retry once.
            if ensure_thread(thread_id):
                resp = requests.post(
                    f"{THREADS_URL}/{thread_id}/append",
                    json={"messages": messages},
                    timeout=30,
                )
        resp.raise_for_status()
        return True
    except Exception as e:
        log.error("POST /threads/%s/append failed: %s", thread_id, e)
        return False


def distill_thread(thread_id: str) -> bool:
    try:
        resp = requests.post(
            DISTILL_URL,
            json={"thread_id": thread_id, "target_tokens": 300},
            timeout=120,
        )
        resp.raise_for_status()
        return True
    except Exception as e:
        log.warning("distill %s failed: %s", thread_id, e)
        return False


# ── Per-file sync ─────────────────────────────────────────────────────────
def sync_session_file(path: Path, state: dict) -> bool:
    """Sync new messages from one session JSONL. Return True on any POST success."""
    if not path.is_file() or path.suffix != ".jsonl":
        return False
    # Skip checkpoint files (openclaw writes *.checkpoint.*.jsonl).
    if ".checkpoint." in path.name:
        return False

    key = str(path)
    entry = state.get(key, {})
    offset = int(entry.get("offset", 0))

    new_offset, found_session_id, messages = parse_new_lines(path, offset)
    thread_id = entry.get("thread_id") or found_session_id

    # Fallback: derive thread_id from filename (sessions are named <uuid>.jsonl).
    if not thread_id:
        thread_id = path.stem

    if new_offset == offset and not messages:
        return False

    success = False
    if messages:
        if not entry.get("thread_created"):
            ensure_thread(thread_id)
            entry["thread_created"] = True
        if append_messages(thread_id, messages):
            log.info("%s: +%d msgs (thread=%s)", path.name, len(messages), thread_id)
            success = True
            # Distill with debounce.
            if DISTILL_ENABLED:
                last = float(entry.get("last_distill_at", 0))
                now = time.time()
                if now - last >= DISTILL_DEBOUNCE:
                    if distill_thread(thread_id):
                        entry["last_distill_at"] = now
                        log.info("%s: distilled", thread_id)

    # Always advance offset (even if message POST failed, so we don't retry-loop forever).
    # The only exception is if we want replay-on-failure; current choice: skip.
    entry["offset"] = new_offset
    entry["thread_id"] = thread_id
    state[key] = entry
    save_state(state)
    return success


# ── File watcher wiring ───────────────────────────────────────────────────
class SessionHandler(FileSystemEventHandler):
    def __init__(self, state: dict):
        self.state = state

    def on_created(self, event):
        if not event.is_directory:
            self._handle(event.src_path)

    def on_modified(self, event):
        if not event.is_directory:
            self._handle(event.src_path)

    def on_moved(self, event):
        if not event.is_directory:
            self._handle(event.dest_path)

    def _handle(self, path):
        p = Path(path)
        if p.suffix == ".jsonl" and ".checkpoint." not in p.name:
            # Debounce a hair so openclaw's buffered write finishes.
            time.sleep(0.3)
            sync_session_file(p, self.state)


def full_scan(state: dict) -> int:
    n = 0
    for d in SESSION_DIRS:
        if not d.exists():
            log.warning("Session dir does not exist: %s", d)
            continue
        for f in sorted(d.glob("*.jsonl")):
            if sync_session_file(f, state):
                n += 1
    return n


def main() -> None:
    if not SESSION_DIRS:
        log.error("No APPLESEED_SYNC_SESSION_DIRS configured. Nothing to do.")
        sys.exit(2)
    log.info("session-sync starting (host=%s base=%s distill=%s)",
             HOSTNAME, BASE_URL, DISTILL_ENABLED)
    for d in SESSION_DIRS:
        log.info("  watch: %s", d)

    state = load_state()

    # IMPORTANT: on first start, do NOT post historical content — the user
    # chose "incremental only". Seed offsets to current EOF for unseen files.
    for d in SESSION_DIRS:
        if not d.exists():
            continue
        for f in sorted(d.glob("*.jsonl")):
            if ".checkpoint." in f.name:
                continue
            key = str(f)
            if key not in state:
                try:
                    size = f.stat().st_size
                except OSError:
                    continue
                state[key] = {"offset": size, "thread_id": f.stem, "seeded": True}
    save_state(state)
    log.info("Seeded %d sessions to current EOF (incremental mode)", len(state))

    if HAS_WATCHDOG:
        log.info("mode: watchdog + 30s periodic rescan")
        observer = Observer()
        handler = SessionHandler(state)
        for d in SESSION_DIRS:
            d.mkdir(parents=True, exist_ok=True)
            observer.schedule(handler, str(d), recursive=False)
        observer.start()
        try:
            while True:
                time.sleep(30)
                full_scan(state)
        except KeyboardInterrupt:
            observer.stop()
        observer.join()
    else:
        log.info("mode: polling every 15s")
        try:
            while True:
                full_scan(state)
                time.sleep(15)
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
