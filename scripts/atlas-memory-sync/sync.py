#!/usr/bin/env python3
"""File watcher that syncs workspace memory .md files to Atlas Memory.

All configuration is taken from environment variables so the same script
runs on any host with different openclaw layouts:

  ATLAS_SYNC_WATCH_DIRS   Colon-separated directories to watch for *.md files.
  ATLAS_SYNC_WATCH_FILES  Colon-separated specific .md files to watch.
  ATLAS_SYNC_URL          Atlas /memories endpoint. Default: http://localhost:6420/memories
  ATLAS_SYNC_HOSTNAME     Logical host label stored in metadata. Default: socket hostname.
  ATLAS_SYNC_STATE        Path to state.json. Default: ~/.openclaw/atlas-memory-sync/state.json
"""

from __future__ import annotations

import json
import logging
import os
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import List

import requests

try:
    from watchdog.observers import Observer
    from watchdog.events import FileSystemEventHandler
    HAS_WATCHDOG = True
except ImportError:
    HAS_WATCHDOG = False
    Observer = None
    FileSystemEventHandler = object


def _split_paths(raw: str) -> List[Path]:
    return [Path(p).expanduser() for p in raw.split(":") if p.strip()]


WATCH_DIRS = _split_paths(os.environ.get("ATLAS_SYNC_WATCH_DIRS", ""))
WATCH_FILES = _split_paths(os.environ.get("ATLAS_SYNC_WATCH_FILES", ""))
ATLAS_URL = os.environ.get("ATLAS_SYNC_URL", "http://localhost:6420/memories")
HOSTNAME = os.environ.get("ATLAS_SYNC_HOSTNAME", socket.gethostname())
USER_ID = os.environ.get("ATLAS_SYNC_USER_ID", "")
AGENT_ID = os.environ.get("ATLAS_SYNC_AGENT_ID", "")
STATE_FILE = Path(os.environ.get(
    "ATLAS_SYNC_STATE",
    str(Path.home() / ".openclaw" / "atlas-memory-sync" / "state.json"),
))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("atlas-sync")


def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            log.warning("Corrupt state file, starting fresh")
    return {}


def save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2))


def make_source(filepath: Path) -> str:
    if filepath.name == "MEMORY.md":
        return "openclaw-longterm"
    return "openclaw-daily"


def sync_file(filepath: Path, state: dict) -> bool:
    if not filepath.is_file() or filepath.suffix != ".md":
        return False

    key = str(filepath)
    try:
        mtime = filepath.stat().st_mtime
    except OSError:
        return False

    if key in state and state[key].get("mtime") == mtime:
        return False

    try:
        content = filepath.read_text(encoding="utf-8")
    except OSError as e:
        log.error("Failed to read %s: %s", filepath, e)
        return False

    if not content.strip():
        return False

    existing_id = state.get(key, {}).get("atlas_id")
    payload = {
        "content": content,
        "title": filepath.stem,
        "source": make_source(filepath),
        "metadata": {
            "source_host": HOSTNAME,
            "file": filepath.name,
            "path": key,
            "synced_at": datetime.now(timezone.utc).isoformat(),
        },
    }
    if USER_ID:
        payload["user_id"] = USER_ID
    if AGENT_ID:
        payload["agent_id"] = AGENT_ID

    try:
        if existing_id:
            resp = requests.patch(f"{ATLAS_URL}/{existing_id}", json=payload, timeout=10)
            if resp.status_code == 404:
                existing_id = None
                resp = requests.post(ATLAS_URL, json=payload, timeout=10)
        else:
            resp = requests.post(ATLAS_URL, json=payload, timeout=10)

        resp.raise_for_status()
        data = resp.json()
        atlas_id = data.get("id") or existing_id or "unknown"
        state[key] = {"mtime": mtime, "atlas_id": atlas_id}
        save_state(state)
        action = "updated" if existing_id else "created"
        log.info("%s %s -> %s", action, filepath.name, atlas_id)
        return True
    except Exception as e:
        log.error("Failed to sync %s: %s", filepath.name, e)
        return False


def initial_scan(state: dict) -> None:
    count = 0
    for d in WATCH_DIRS:
        if not d.exists():
            log.warning("Watch dir does not exist: %s", d)
            continue
        for f in sorted(d.glob("*.md")):
            if sync_file(f, state):
                count += 1
    for f in WATCH_FILES:
        if sync_file(f, state):
            count += 1
    log.info("Initial scan complete: %d files synced", count)


class SyncHandler(FileSystemEventHandler):
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
        if p.suffix == ".md":
            time.sleep(0.5)
            sync_file(p, self.state)


def main() -> None:
    if not WATCH_DIRS and not WATCH_FILES:
        log.error("No watch targets. Set ATLAS_SYNC_WATCH_DIRS and/or ATLAS_SYNC_WATCH_FILES.")
        sys.exit(2)
    log.info("atlas-memory-sync starting (host=%s atlas=%s)", HOSTNAME, ATLAS_URL)
    for d in WATCH_DIRS:
        log.info("  watch dir:  %s", d)
    for f in WATCH_FILES:
        log.info("  watch file: %s", f)

    state = load_state()
    initial_scan(state)

    if HAS_WATCHDOG:
        log.info("mode: watchdog (inotify) + 5min rescan")
        observer = Observer()
        handler = SyncHandler(state)
        for d in WATCH_DIRS:
            d.mkdir(parents=True, exist_ok=True)
            observer.schedule(handler, str(d), recursive=False)
        for f in WATCH_FILES:
            if f.parent.exists():
                observer.schedule(handler, str(f.parent), recursive=False)
        observer.start()
        try:
            while True:
                time.sleep(300)
                for f in WATCH_FILES:
                    sync_file(f, state)
        except KeyboardInterrupt:
            observer.stop()
        observer.join()
    else:
        log.info("mode: polling every 15s (watchdog not installed)")
        try:
            while True:
                for d in WATCH_DIRS:
                    if d.exists():
                        for f in d.glob("*.md"):
                            sync_file(f, state)
                for f in WATCH_FILES:
                    sync_file(f, state)
                time.sleep(15)
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
