# atlas-memory-sync

Watches an agent's Markdown notes (daily logs + long-term `MEMORY.md`) and pushes them into [Atlas Memory](https://github.com/dddabtc/atlas-memory) via the `/memories` REST API.

Works on Linux (systemd, system or user mode) and macOS (launchd).

## Supported agents

| Agent | Auto-detected locations |
|---|---|
| `openclaw` | `~/clawd/memory/*.md`, `~/.openclaw/memory/*.md`, `~/.openclaw/workspace/memory/*.md`, `~/.openclaw/workspace/MEMORY.md`, `~/clawd/MEMORY.md` |
| `hermes`   | `~/.hermes/memories/*.md`, `~/.hermes/memory/*.md`, `~/.hermes/memories/MEMORY.md`, `~/.hermes/MEMORY.md` |

Only paths that actually exist and contain `.md` files are added to the service.

## Install

```bash
bash install.sh --agent openclaw                          \
                --atlas http://100.119.6.34:6420/memories \
                --user-id  dda                            \
                --agent-id dda225-root@vps
```

You'll be shown the detected paths and asked to confirm. Add `--yes` to skip.

### Options

| Flag | Meaning | Default |
|---|---|---|
| `--agent` | `openclaw` or `hermes` | *required* |
| `--home` | Agent home dir override | `~/.<agent>` |
| `--atlas` | Atlas `/memories` URL | `http://localhost:6420/memories` |
| `--user-id` | Attached to each memory | empty |
| `--agent-id` | Attached to each memory | empty |
| `--hostname` | Label for metadata | `$(hostname)` |
| `--yes`, `-y` | Skip the confirmation prompt | off |
| `--user-systemd` | Force user-level systemd on Linux | auto |

### Service selection

The installer picks the right service manager automatically:

1. macOS → `launchd` under `~/Library/LaunchAgents/`
2. Linux + sudo NOPASSWD → `systemd` system unit in `/etc/systemd/system/`
3. Linux without sudo → `systemd --user` unit in `~/.config/systemd/user/`

## Verify

```bash
# system systemd:
systemctl status atlas-memory-sync
journalctl -u atlas-memory-sync -f

# user systemd:
systemctl --user status atlas-memory-sync

# launchd:
launchctl list | grep atlas.memory.sync
tail -f ~/.openclaw/atlas-memory-sync/stdout.log
```

## How it works

- State file `~/.openclaw/atlas-memory-sync/state.json` maps each file path to `(mtime, atlas_id)`.
- On start, every watched `.md` is POSTed if new (no `atlas_id`) or PATCHed if its `mtime` changed.
- While running, filesystem events trigger the same sync. Without `watchdog` installed the service falls back to a 15s polling loop.
- A 5-minute periodic rescan covers missed events (e.g. editor save patterns that defeat inotify).

All configuration flows through environment variables set in the service unit:

| Variable | Purpose |
|---|---|
| `ATLAS_SYNC_WATCH_DIRS`  | Colon-separated directories |
| `ATLAS_SYNC_WATCH_FILES` | Colon-separated file paths |
| `ATLAS_SYNC_URL`         | Atlas `/memories` endpoint |
| `ATLAS_SYNC_HOSTNAME`    | Free-form host label |
| `ATLAS_SYNC_USER_ID`     | `user_id` on every payload |
| `ATLAS_SYNC_AGENT_ID`    | `agent_id` on every payload |
| `ATLAS_SYNC_STATE`       | Override state.json location |
