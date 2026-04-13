#!/usr/bin/env bash
# atlas-memory-sync installer.
#
# Auto-detects memory log locations for the named agent (openclaw / hermes),
# shows the plan, waits for confirmation, then installs the sync service.
#
# Usage:
#   install.sh --agent openclaw [--home ~/.openclaw] [--atlas URL]
#              [--user-id ID] [--agent-id ID] [--hostname HOST]
#              [--yes] [--user-systemd]
#
# --agent           openclaw | hermes                             (required)
# --home            Agent home directory. Default: ~/.<agent>
# --atlas           Atlas /memories endpoint. Default: http://localhost:6420/memories
# --user-id         Passed as user_id on every memory payload
# --agent-id        Passed as agent_id on every memory payload
# --hostname        Logical host label. Default: $(hostname)
# --yes, -y         Skip the confirmation prompt
# --user-systemd    Force user-level systemd instead of system (Linux only)

set -e

AGENT=""
AGENT_HOME=""
ATLAS_URL="http://localhost:6420/memories"
USER_ID=""
AGENT_ID=""
HOSTNAME_LABEL="$(hostname)"
ASSUME_YES=0
FORCE_USER_SYSTEMD=0

usage() { sed -n '1,30p' "$0"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)        AGENT="$2"; shift 2;;
        --home)         AGENT_HOME="$2"; shift 2;;
        --atlas)        ATLAS_URL="$2"; shift 2;;
        --user-id)      USER_ID="$2"; shift 2;;
        --agent-id)     AGENT_ID="$2"; shift 2;;
        --hostname)     HOSTNAME_LABEL="$2"; shift 2;;
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
atlas-memory-sync install plan
========================================
Agent:        $AGENT
Agent home:   $AGENT_HOME
Atlas URL:    $ATLAS_URL
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
INSTALL_DIR="$HOME/.openclaw/atlas-memory-sync"
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
    UNIT="/etc/systemd/system/atlas-memory-sync.service"
    sudo tee "$UNIT" > /dev/null <<EOF
[Unit]
Description=Atlas Memory File Sync
After=network.target

[Service]
Type=simple
User=$USER
Environment=ATLAS_SYNC_WATCH_DIRS=$WATCH_DIRS_STR
Environment=ATLAS_SYNC_WATCH_FILES=$WATCH_FILES_STR
Environment=ATLAS_SYNC_URL=$ATLAS_URL
Environment=ATLAS_SYNC_HOSTNAME=$HOSTNAME_LABEL
Environment=ATLAS_SYNC_USER_ID=$USER_ID
Environment=ATLAS_SYNC_AGENT_ID=$AGENT_ID
WorkingDirectory=$INSTALL_DIR
ExecStart=$PYTHON_BIN $INSTALL_DIR/sync.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable atlas-memory-sync
    sudo systemctl restart atlas-memory-sync
    sleep 2
    sudo systemctl status atlas-memory-sync --no-pager | head -12
    ;;

systemd-user)
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/atlas-memory-sync.service" <<EOF
[Unit]
Description=Atlas Memory File Sync (user)
After=network.target

[Service]
Type=simple
Environment=ATLAS_SYNC_WATCH_DIRS=$WATCH_DIRS_STR
Environment=ATLAS_SYNC_WATCH_FILES=$WATCH_FILES_STR
Environment=ATLAS_SYNC_URL=$ATLAS_URL
Environment=ATLAS_SYNC_HOSTNAME=$HOSTNAME_LABEL
Environment=ATLAS_SYNC_USER_ID=$USER_ID
Environment=ATLAS_SYNC_AGENT_ID=$AGENT_ID
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
    systemctl --user enable atlas-memory-sync.service
    systemctl --user restart atlas-memory-sync.service
    sleep 2
    systemctl --user status atlas-memory-sync --no-pager 2>&1 | head -12
    ;;

launchd)
    PLIST="$HOME/Library/LaunchAgents/com.atlas.memory.sync.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.atlas.memory.sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON_BIN</string>
        <string>$INSTALL_DIR/sync.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ATLAS_SYNC_WATCH_DIRS</key><string>$WATCH_DIRS_STR</string>
        <key>ATLAS_SYNC_WATCH_FILES</key><string>$WATCH_FILES_STR</string>
        <key>ATLAS_SYNC_URL</key><string>$ATLAS_URL</string>
        <key>ATLAS_SYNC_HOSTNAME</key><string>$HOSTNAME_LABEL</string>
        <key>ATLAS_SYNC_USER_ID</key><string>$USER_ID</string>
        <key>ATLAS_SYNC_AGENT_ID</key><string>$AGENT_ID</string>
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
    launchctl list | grep atlas.memory.sync || echo "WARN: service not visible in launchctl list"
    ;;
esac

echo
echo "=== Install complete ==="
