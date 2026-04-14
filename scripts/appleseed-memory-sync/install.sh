#!/usr/bin/env bash
# appleseed-memory-sync installer.
#
# Auto-detects memory log locations for the named agent (openclaw / hermes),
# shows the plan, waits for confirmation, then installs the sync service.
#
# Usage:
#   install.sh --agent openclaw [--home ~/.openclaw] [--appleseed URL]
#              [--user-id ID] [--agent-id ID] [--hostname HOST]
#              [--watch-dir DIR]... [--watch-file FILE]...
#              [--yes] [--user-systemd]
#
# --agent           openclaw | hermes                             (required)
# --home            Agent home directory. Default: ~/.<agent>
# --appleseed           Appleseed /memories endpoint. Default: http://localhost:6420/memories
# --user-id         Passed as user_id on every memory payload
# --agent-id        Passed as agent_id on every memory payload
# --hostname        Logical host label. Default: $(hostname)
# --watch-dir DIR   Extra directory to watch (can repeat). Augments autodetection.
# --watch-file F    Extra single file to watch (can repeat). Augments autodetection.
# --session-dir DIR Install a second service that watches openclaw session JSONL
#                   files in DIR and streams new messages to /threads + /memories/distill.
#                   Can repeat. If omitted, session-sync is not installed.
# --no-distill      Disable immediate /memories/distill after session append (default on).
# --yes, -y         Skip the confirmation prompt
# --user-systemd    Force user-level systemd instead of system (Linux only)

set -e

AGENT=""
AGENT_HOME=""
APPLESEED_URL="http://localhost:6420/memories"
USER_ID=""
AGENT_ID=""
HOSTNAME_LABEL="$(hostname)"
ASSUME_YES=0
FORCE_USER_SYSTEMD=0
declare -a EXTRA_DIRS EXTRA_FILES SESSION_DIRS
DISTILL_ENABLED=1

usage() { sed -n '1,30p' "$0"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)        AGENT="$2"; shift 2;;
        --home)         AGENT_HOME="$2"; shift 2;;
        --appleseed)        APPLESEED_URL="$2"; shift 2;;
        --user-id)      USER_ID="$2"; shift 2;;
        --agent-id)     AGENT_ID="$2"; shift 2;;
        --hostname)     HOSTNAME_LABEL="$2"; shift 2;;
        --watch-dir)    EXTRA_DIRS+=("$2"); shift 2;;
        --watch-file)   EXTRA_FILES+=("$2"); shift 2;;
        --session-dir)  SESSION_DIRS+=("$2"); shift 2;;
        --no-distill)   DISTILL_ENABLED=0; shift;;
        --yes|-y)       ASSUME_YES=1; shift;;
        --user-systemd) FORCE_USER_SYSTEMD=1; shift;;
        -h|--help)      usage;;
        *) echo "Unknown option: $1" >&2; usage;;
    esac
done

[[ -z "$AGENT" ]] && { echo "ERROR: --agent is required" >&2; usage; }
case "$AGENT" in openclaw|hermes) ;; *) echo "ERROR: --agent must be openclaw or hermes" >&2; exit 1;; esac
[[ -z "$AGENT_HOME" ]] && AGENT_HOME="$HOME/.$AGENT"

# ── Detect candidate memory paths ─────────────────────────────────────────────
# Known layouts seen in the wild:
#   openclaw: ~/clawd/memory/*.md, ~/.openclaw/memory/*.md, ~/.openclaw/workspace/memory/*.md
#             ~/.openclaw/workspace/MEMORY.md, ~/clawd/MEMORY.md
#   hermes:   ~/.hermes/memories/*.md, ~/.hermes/memories/MEMORY.md

declare -a CAND_DIRS CAND_FILES

add_dir_if_has_md() {
    local d="$1"
    if [[ -d "$d" ]] && compgen -G "$d/*.md" > /dev/null; then
        CAND_DIRS+=("$d")
    fi
    return 0
}

add_file_if_exists() {
    if [[ -f "$1" ]]; then
        CAND_FILES+=("$1")
    fi
    return 0
}

if [[ "$AGENT" == "openclaw" ]]; then
    add_dir_if_has_md "$HOME/clawd/memory"
    add_dir_if_has_md "$AGENT_HOME/memory"
    add_dir_if_has_md "$AGENT_HOME/workspace/memory"
    add_file_if_exists "$AGENT_HOME/workspace/MEMORY.md"
    add_file_if_exists "$HOME/clawd/MEMORY.md"
elif [[ "$AGENT" == "hermes" ]]; then
    add_dir_if_has_md "$AGENT_HOME/memories"
    add_dir_if_has_md "$AGENT_HOME/memory"
    add_file_if_exists "$AGENT_HOME/memories/MEMORY.md"
    add_file_if_exists "$AGENT_HOME/memory/MEMORY.md"
    add_file_if_exists "$AGENT_HOME/MEMORY.md"
fi

# User-supplied paths (--watch-dir / --watch-file), kept verbatim.
# These are added even if currently empty of .md files — useful when a daily
# note file will exist later.
for d in "${EXTRA_DIRS[@]+"${EXTRA_DIRS[@]}"}"; do
    if [[ -d "$d" ]]; then
        CAND_DIRS+=("$d")
    else
        echo "WARN: --watch-dir '$d' does not exist; will be created on first write."
        CAND_DIRS+=("$d")
    fi
done
for f in "${EXTRA_FILES[@]+"${EXTRA_FILES[@]}"}"; do
    if [[ -f "$f" ]]; then
        CAND_FILES+=("$f")
    else
        echo "WARN: --watch-file '$f' does not exist yet; will sync once created."
        CAND_FILES+=("$f")
    fi
done

# Deduplicate
dedup_array() {
    local -a out=()
    local item
    local seen=""
    for item in "$@"; do
        case ":$seen:" in
            *":$item:"*) ;;
            *) out+=("$item"); seen="$seen:$item";;
        esac
    done
    printf '%s\n' "${out[@]}"
}
readarray -t CAND_DIRS < <(dedup_array "${CAND_DIRS[@]}")
readarray -t CAND_FILES < <(dedup_array "${CAND_FILES[@]}")

if [[ ${#CAND_DIRS[@]} -eq 0 && ${#CAND_FILES[@]} -eq 0 ]]; then
    echo "ERROR: no memory directories or MEMORY.md found under:"
    echo "  \$HOME=$HOME"
    echo "  --home=$AGENT_HOME"
    echo "Nothing to sync. Aborting."
    exit 2
fi

# ── Detect OS / service manager ──────────────────────────────────────────────
OS="$(uname -s)"
SERVICE_MODE=""
if [[ "$OS" == "Darwin" ]]; then
    SERVICE_MODE="launchd"
elif command -v systemctl >/dev/null 2>&1; then
    if [[ "$FORCE_USER_SYSTEMD" -eq 1 ]]; then
        SERVICE_MODE="systemd-user"
    elif sudo -n true 2>/dev/null; then
        SERVICE_MODE="systemd-system"
    else
        SERVICE_MODE="systemd-user"
    fi
else
    echo "ERROR: unsupported OS or no service manager found (uname=$OS)" >&2
    exit 3
fi

# ── Show plan ────────────────────────────────────────────────────────────────
cat <<EOF

========================================
appleseed-memory-sync install plan
========================================
Agent:        $AGENT
Agent home:   $AGENT_HOME
Appleseed URL:    $APPLESEED_URL
Hostname tag: $HOSTNAME_LABEL
user_id:      ${USER_ID:-<none>}
agent_id:     ${AGENT_ID:-<none>}
Service:      $SERVICE_MODE

Detected watch directories (*.md files):
EOF
for d in "${CAND_DIRS[@]}"; do echo "  - $d"; done
[[ ${#CAND_DIRS[@]} -eq 0 ]] && echo "  (none)"
echo
echo "Detected watch files:"
for f in "${CAND_FILES[@]}"; do echo "  - $f"; done
[[ ${#CAND_FILES[@]} -eq 0 ]] && echo "  (none)"
echo

if [[ "$ASSUME_YES" -eq 0 ]]; then
    read -rp "Proceed with install? [y/N] " ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 0;;
    esac
fi

# ── Build env strings ────────────────────────────────────────────────────────
IFS=: ; WATCH_DIRS_STR="${CAND_DIRS[*]}"; IFS=$' \t\n'
IFS=: ; WATCH_FILES_STR="${CAND_FILES[*]}"; IFS=$' \t\n'

# ── Deploy sync.py ───────────────────────────────────────────────────────────
INSTALL_DIR="$HOME/.openclaw/appleseed-memory-sync"
mkdir -p "$INSTALL_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/sync.py" "$INSTALL_DIR/sync.py"
chmod +x "$INSTALL_DIR/sync.py"

# ── Ensure deps ──────────────────────────────────────────────────────────────
python3 -c "import requests" 2>/dev/null || \
    pip install --user --break-system-packages requests 2>/dev/null || \
    pip install --user requests 2>/dev/null || \
    echo "WARN: requests install failed"
python3 -c "import watchdog" 2>/dev/null || {
    timeout 60 pip install --user --break-system-packages watchdog 2>/dev/null || \
    timeout 60 pip install --user watchdog 2>/dev/null || \
    echo "NOTE: watchdog unavailable — sync will fall back to polling mode"
}

PYTHON_BIN="$(command -v python3)"

# ── Install service ──────────────────────────────────────────────────────────
case "$SERVICE_MODE" in
systemd-system)
    UNIT="/etc/systemd/system/appleseed-memory-sync.service"
    sudo tee "$UNIT" > /dev/null <<EOF
[Unit]
Description=Appleseed Memory File Sync
After=network.target

[Service]
Type=simple
User=$USER
Environment=APPLESEED_SYNC_WATCH_DIRS=$WATCH_DIRS_STR
Environment=APPLESEED_SYNC_WATCH_FILES=$WATCH_FILES_STR
Environment=APPLESEED_SYNC_URL=$APPLESEED_URL
Environment=APPLESEED_SYNC_HOSTNAME=$HOSTNAME_LABEL
Environment=APPLESEED_SYNC_USER_ID=$USER_ID
Environment=APPLESEED_SYNC_AGENT_ID=$AGENT_ID
WorkingDirectory=$INSTALL_DIR
ExecStart=$PYTHON_BIN $INSTALL_DIR/sync.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable appleseed-memory-sync
    sudo systemctl restart appleseed-memory-sync
    sleep 2
    sudo systemctl status appleseed-memory-sync --no-pager | head -12
    ;;

systemd-user)
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/appleseed-memory-sync.service" <<EOF
[Unit]
Description=Appleseed Memory File Sync (user)
After=network.target

[Service]
Type=simple
Environment=APPLESEED_SYNC_WATCH_DIRS=$WATCH_DIRS_STR
Environment=APPLESEED_SYNC_WATCH_FILES=$WATCH_FILES_STR
Environment=APPLESEED_SYNC_URL=$APPLESEED_URL
Environment=APPLESEED_SYNC_HOSTNAME=$HOSTNAME_LABEL
Environment=APPLESEED_SYNC_USER_ID=$USER_ID
Environment=APPLESEED_SYNC_AGENT_ID=$AGENT_ID
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
WorkingDirectory=$INSTALL_DIR
ExecStart=$PYTHON_BIN $INSTALL_DIR/sync.py
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
    loginctl enable-linger "$USER" 2>/dev/null || true
    systemctl --user daemon-reload
    systemctl --user enable appleseed-memory-sync.service
    systemctl --user restart appleseed-memory-sync.service
    sleep 2
    systemctl --user status appleseed-memory-sync --no-pager 2>&1 | head -12
    ;;

launchd)
    PLIST="$HOME/Library/LaunchAgents/com.appleseed.memory.sync.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.appleseed.memory.sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON_BIN</string>
        <string>$INSTALL_DIR/sync.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>APPLESEED_SYNC_WATCH_DIRS</key><string>$WATCH_DIRS_STR</string>
        <key>APPLESEED_SYNC_WATCH_FILES</key><string>$WATCH_FILES_STR</string>
        <key>APPLESEED_SYNC_URL</key><string>$APPLESEED_URL</string>
        <key>APPLESEED_SYNC_HOSTNAME</key><string>$HOSTNAME_LABEL</string>
        <key>APPLESEED_SYNC_USER_ID</key><string>$USER_ID</string>
        <key>APPLESEED_SYNC_AGENT_ID</key><string>$AGENT_ID</string>
        <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$INSTALL_DIR/stdout.log</string>
    <key>StandardErrorPath</key><string>$INSTALL_DIR/stderr.log</string>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    sleep 1
    launchctl list | grep "^com.appleseed.memory.sync" || echo "WARN: service not visible in launchctl list"
    ;;
esac

# ── Optional: session-sync service ──────────────────────────────────────────
if [[ ${#SESSION_DIRS[@]} -gt 0 ]]; then
    IFS=: ; SESSION_DIRS_STR="${SESSION_DIRS[*]}"; IFS=$' \t\n'
    cp "$SCRIPT_DIR/session_sync.py" "$INSTALL_DIR/session_sync.py"
    chmod +x "$INSTALL_DIR/session_sync.py"

    echo
    echo "== Installing session-sync =="
    echo "  session dirs: $SESSION_DIRS_STR"
    echo "  distill:      $DISTILL_ENABLED"

    case "$SERVICE_MODE" in
    systemd-system)
        UNIT="/etc/systemd/system/appleseed-memory-session-sync.service"
        sudo tee "$UNIT" > /dev/null <<EOF
[Unit]
Description=Appleseed Memory Session Sync (openclaw JSONL → threads + distill)
After=network.target appleseed-memory-sync.service

[Service]
Type=simple
User=$USER
Environment=APPLESEED_SYNC_SESSION_DIRS=$SESSION_DIRS_STR
Environment=APPLESEED_SYNC_URL=$APPLESEED_URL
Environment=APPLESEED_SYNC_HOSTNAME=$HOSTNAME_LABEL
Environment=APPLESEED_SYNC_USER_ID=$USER_ID
Environment=APPLESEED_SYNC_AGENT_ID=$AGENT_ID
Environment=APPLESEED_SYNC_DISTILL=$DISTILL_ENABLED
Environment=APPLESEED_SYNC_SESSION_STATE=$INSTALL_DIR/session_state.json
WorkingDirectory=$INSTALL_DIR
ExecStart=$PYTHON_BIN $INSTALL_DIR/session_sync.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable appleseed-memory-session-sync
        sudo systemctl restart appleseed-memory-session-sync
        sleep 2
        sudo systemctl status appleseed-memory-session-sync --no-pager | head -12
        ;;

    systemd-user)
        cat > "$HOME/.config/systemd/user/appleseed-memory-session-sync.service" <<EOF
[Unit]
Description=Appleseed Memory Session Sync (user)
After=network.target

[Service]
Type=simple
Environment=APPLESEED_SYNC_SESSION_DIRS=$SESSION_DIRS_STR
Environment=APPLESEED_SYNC_URL=$APPLESEED_URL
Environment=APPLESEED_SYNC_HOSTNAME=$HOSTNAME_LABEL
Environment=APPLESEED_SYNC_USER_ID=$USER_ID
Environment=APPLESEED_SYNC_AGENT_ID=$AGENT_ID
Environment=APPLESEED_SYNC_DISTILL=$DISTILL_ENABLED
Environment=APPLESEED_SYNC_SESSION_STATE=$INSTALL_DIR/session_state.json
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
WorkingDirectory=$INSTALL_DIR
ExecStart=$PYTHON_BIN $INSTALL_DIR/session_sync.py
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable appleseed-memory-session-sync.service
        systemctl --user restart appleseed-memory-session-sync.service
        sleep 2
        systemctl --user status appleseed-memory-session-sync --no-pager 2>&1 | head -12
        ;;

    launchd)
        SESSION_PLIST="$HOME/Library/LaunchAgents/com.appleseed.memory.session-sync.plist"
        cat > "$SESSION_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.appleseed.memory.session-sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON_BIN</string>
        <string>$INSTALL_DIR/session_sync.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>APPLESEED_SYNC_SESSION_DIRS</key><string>$SESSION_DIRS_STR</string>
        <key>APPLESEED_SYNC_URL</key><string>$APPLESEED_URL</string>
        <key>APPLESEED_SYNC_HOSTNAME</key><string>$HOSTNAME_LABEL</string>
        <key>APPLESEED_SYNC_USER_ID</key><string>$USER_ID</string>
        <key>APPLESEED_SYNC_AGENT_ID</key><string>$AGENT_ID</string>
        <key>APPLESEED_SYNC_DISTILL</key><string>$DISTILL_ENABLED</string>
        <key>APPLESEED_SYNC_SESSION_STATE</key><string>$INSTALL_DIR/session_state.json</string>
        <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$INSTALL_DIR/session-stdout.log</string>
    <key>StandardErrorPath</key><string>$INSTALL_DIR/session-stderr.log</string>
</dict>
</plist>
EOF
        launchctl unload "$SESSION_PLIST" 2>/dev/null || true
        launchctl load "$SESSION_PLIST"
        sleep 1
        launchctl list | grep "^com.appleseed.memory.session-sync" || echo "WARN: session-sync not loaded"
        ;;
    esac
fi

echo
echo "=== Install complete ==="
