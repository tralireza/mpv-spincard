#!/usr/bin/env bash
# Deploy spincard to the mpv on i7 (the primary target).
#
#   ./deploy.sh            # deploy to host "i7"
#   ./deploy.sh myhost     # deploy to another ssh host
#
# Non-destructive to your existing mpv config:
#   - syncs the script into  ~/.mpv/scripts/spincard/  (dedicated dir)
#   - copies the sample script-opts ONLY if you don't already have one
#   - never edits your input.conf (prints the line to add yourself)

set -euo pipefail

HOST="${1:-i7}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRC="$HERE/scripts/spincard/"
DEST="~/.mpv/scripts/spincard/"

echo ">> Syncing script to $HOST:$DEST"
rsync -av --delete --exclude '*.swp' --exclude '.DS_Store' "$SRC" "$HOST:$DEST"

echo ">> Ensuring script-opts config on $HOST (won't overwrite an existing one)"
if ssh "$HOST" 'test -f ~/.mpv/script-opts/spincard.conf'; then
    echo "   exists — left untouched"
else
    ssh "$HOST" 'mkdir -p ~/.mpv/script-opts'
    scp -q "$HERE/script-opts/spincard.conf" "$HOST:.mpv/script-opts/spincard.conf"
    echo "   installed default config"
fi

cat <<EOF

Done. Next:
  - Restart mpv on $HOST (scripts load at startup), then play a file.
  - Optional toggle keys — add to ~/.mpv/input.conf on $HOST. Use PLAIN keys:
    over tmux/SSH, Ctrl+<letter> collides with Tab/Enter/Esc. Avoid i/I (mpv stats).
        c script-binding spincard/toggle
        C script-binding spincard/toggle-lean    # lean card (see lean_hide)
EOF
