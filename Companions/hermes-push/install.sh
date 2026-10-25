#!/usr/bin/env bash
# Installs the push companion as a background service here, then fires a test push.
# Nollie puts this file in <HERMES_HOME>/push/ next to the config it generated, so nothing needs
# editing. Repeat runs are harmless, and "--uninstall" removes it all.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
conf="$here/hermes-push.conf"
system=$(uname -s)
mac_agent="$HOME/Library/LaunchAgents/com.coreykozarski.nollie.push.plist"
linux_unit="$HOME/.config/systemd/user/hermes-push.service"

say() { printf '%s\n' "$*"; }
die() { say "$*"; exit 1; }

# Picks the first Python that has the Hermes packages: beside the hermes command, else the usual venv locations.
find_python() {
    local candidate hermes_cmd
    if hermes_cmd=$(command -v hermes 2>/dev/null); then
        hermes_cmd=$(readlink -f "$hermes_cmd" 2>/dev/null || printf '%s' "$hermes_cmd")
        candidate=$(dirname "$hermes_cmd")/python
        [ -x "$candidate" ] && { printf '%s' "$candidate"; return; }
    fi
    for candidate in "$HOME/.hermes/hermes-agent/venv/bin/python" "$(dirname "$here")/hermes-agent/venv/bin/python"; do
        [ -x "$candidate" ] && { printf '%s' "$candidate"; return; }
    done
    say "There is no Hermes virtualenv here, so install the packages yourself: pip install websockets pyjwt cryptography" >&2
    command -v python3
}

# Runs a command, ignoring both failure and output; meant for things that may not exist yet.
quietly() { "$@" >/dev/null 2>&1 || true; }

remove_everything() {
    if [ "$system" = Linux ]; then
        quietly systemctl --user disable --now hermes-push
        rm -f "$linux_unit"
        quietly systemctl --user daemon-reload
    elif [ "$system" = Darwin ]; then
        quietly launchctl bootout "gui/$(id -u)" "$mac_agent"
        rm -f "$mac_agent"
    fi
    quietly pkill -f "$here/hermes_push.py"
    rm -rf "$here" "$(dirname "$here")/plugins/nollie-push"
    say "Push is gone: the service has stopped, and the plugin and $here have been deleted."
}

install_linux() {
    mkdir -p "$(dirname "$linux_unit")"
    cat > "$linux_unit" <<UNIT
[Unit]
Description=Nollie push companion
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=$py $here/hermes_push.py
Environment=HERMES_PUSH_CONFIG=$conf
RestartSec=5
Restart=always

[Install]
WantedBy=default.target
UNIT
    local ctl=(systemctl --user)
    "${ctl[@]}" daemon-reload
    "${ctl[@]}" enable --now hermes-push
    quietly loginctl enable-linger "$USER"
    say "service: $("${ctl[@]}" is-active hermes-push)"
}

install_mac() {
    mkdir -p "$(dirname "$mac_agent")"
    local log="$here/hermes-push.log"
    printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0"><dict>' \
        '  <key>Label</key><string>com.coreykozarski.nollie.push</string>' \
        "  <key>ProgramArguments</key><array><string>$py</string><string>$here/hermes_push.py</string></array>" \
        "  <key>EnvironmentVariables</key><dict><key>HERMES_PUSH_CONFIG</key><string>$conf</string></dict>" \
        '  <key>RunAtLoad</key><true/>' \
        '  <key>KeepAlive</key><true/>' \
        "  <key>StandardOutPath</key><string>$log</string>" \
        "  <key>StandardErrorPath</key><string>$log</string>" \
        '</dict></plist>' > "$mac_agent"
    quietly launchctl bootout "gui/$(id -u)" "$mac_agent"
    launchctl bootstrap "gui/$(id -u)" "$mac_agent"
    say "launch agent loaded"
}

if [ "${1:-}" = "--uninstall" ]; then
    remove_everything
    exit 0
fi

[ -f "$conf" ] || die "$conf is missing. Run the setup in Nollie first (Settings, then Notifications)."
py=$(find_python)
say "python: $py"

case $system in
    Linux)  install_linux ;;
    Darwin) install_mac ;;
    *)      say "This system is not supported here. To run it by hand: HERMES_PUSH_CONFIG=$conf $py $here/hermes_push.py" ;;
esac

say "Sending a test push..."
HERMES_PUSH_CONFIG="$conf" "$py" "$here/hermes_push.py" --test
