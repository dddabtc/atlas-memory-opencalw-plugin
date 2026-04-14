# appleseed-memory-sync

Watches an agent's Markdown notes (daily logs + long-term `MEMORY.md`) and pushes them into [Appleseed Memory](https://github.com/dddabtc/appleseed-memory) via the `/memories` REST API.

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
                --appleseed http://100.119.6.34:6420/memories \
                --user-id  dda                            \
                --agent-id dda225-root@vps
```

You'll be shown the detected paths and asked to confirm. Add `--yes` to skip.

### Options

| Flag | Meaning | Default |
|---|---|---|
| `--agent` | `openclaw` or `hermes` | *required* |
| `--home` | Agent home dir override | `~/.<agent>` |
| `--appleseed` | Appleseed `/memories` URL | `http://localhost:6420/memories` |
| `--user-id` | Attached to each memory | empty |
| `--agent-id` | Attached to each memory | empty |
| `--hostname` | Label for metadata | `$(hostname)` |
| `--watch-dir DIR` | Extra directory to watch; can repeat. Useful when notes live outside `$HOME` (e.g. VPS root user + `/home/ubuntu/clawd/memory`). Augments autodetection. | empty |
| `--watch-file FILE` | Extra single file to watch; can repeat. | empty |
| `--yes`, `-y` | Skip the confirmation prompt | off |
| `--user-systemd` | Force user-level systemd on Linux | auto |

**Example: VPS root user with legacy paths**

```bash
bash install.sh --agent openclaw \
  --watch-dir /home/ubuntu/clawd/memory \
  --appleseed http://localhost:6420/memories \
  --user-id dda --agent-id dda225-root \
  --yes
```

### Service selection

The installer picks the right service manager automatically:

1. macOS → `launchd` under `~/Library/LaunchAgents/`
2. Linux + sudo NOPASSWD → `systemd` system unit in `/etc/systemd/system/`
3. Linux without sudo → `systemd --user` unit in `~/.config/systemd/user/`

## Verify

```bash
# system systemd:
systemctl status appleseed-memory-sync
journalctl -u appleseed-memory-sync -f

# user systemd:
systemctl --user status appleseed-memory-sync

# launchd:
launchctl list | grep appleseed.memory.sync
tail -f ~/.openclaw/appleseed-memory-sync/stdout.log
```

## How it works

- State file `~/.openclaw/appleseed-memory-sync/state.json` maps each file path to `(mtime, appleseed_id)`.
- On start, every watched `.md` is POSTed if new (no `appleseed_id`) or PATCHed if its `mtime` changed.
- While running, filesystem events trigger the same sync. Without `watchdog` installed the service falls back to a 15s polling loop.
- A 5-minute periodic rescan covers missed events (e.g. editor save patterns that defeat inotify).

All configuration flows through environment variables set in the service unit:

| Variable | Purpose |
|---|---|
| `APPLESEED_SYNC_WATCH_DIRS`  | Colon-separated directories |
| `APPLESEED_SYNC_WATCH_FILES` | Colon-separated file paths |
| `APPLESEED_SYNC_URL`         | Appleseed `/memories` endpoint |
| `APPLESEED_SYNC_HOSTNAME`    | Free-form host label |
| `APPLESEED_SYNC_USER_ID`     | `user_id` on every payload |
| `APPLESEED_SYNC_AGENT_ID`    | `agent_id` on every payload |
| `APPLESEED_SYNC_STATE`       | Override state.json location |
