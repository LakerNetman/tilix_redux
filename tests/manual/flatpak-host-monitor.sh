#!/usr/bin/env sh
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
# distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Watches the open file descriptors of the running Tilix Flatpak while terminals
# are opened and closed, to check host commands no longer leak pipes and D-Bus
# connections. Run it from a terminal that is NOT inside Tilix.
#
# Usage:
#   tests/manual/flatpak-host-monitor.sh snapshot    print the current counts
#   tests/manual/flatpak-host-monitor.sh cycle [N]   open N sessions (default 10),
#                                                    wait for you to close them,
#                                                    then compare with before
#
# See tests/manual/flatpak-host-commands.md

APP=com.gexperts.Tilix

tilix_pid() {
    flatpak ps --columns=application,child-pid 2>/dev/null | awk -v app="$APP" '$1 == app { print $2; exit }'
}

# Prints: total pipes sockets
counts() {
    PID="$1"
    FDS=$(ls -l "/proc/$PID/fd" 2>/dev/null) || return 1
    TOTAL=$(printf '%s\n' "$FDS" | grep -c -- '->')
    PIPES=$(printf '%s\n' "$FDS" | grep -c 'pipe:')
    SOCKETS=$(printf '%s\n' "$FDS" | grep -c 'socket:')
    echo "$TOTAL $PIPES $SOCKETS"
}

PID=$(tilix_pid)
if [ -z "$PID" ]; then
    echo "Tilix Flatpak is not running, start it with: flatpak run $APP" >&2
    exit 1
fi
if [ -n "$TILIX_ID" ]; then
    echo "Warning: this looks like a Tilix terminal, run the script from another terminal" >&2
fi

case "${1:-snapshot}" in
snapshot)
    set -- $(counts "$PID")
    echo "Tilix pid $PID: fds=$1 pipes=$2 sockets=$3"
    ;;
cycle)
    N="${2:-10}"
    set -- $(counts "$PID")
    B_TOTAL=$1; B_PIPES=$2; B_SOCKETS=$3
    echo "Before:  fds=$B_TOTAL pipes=$B_PIPES sockets=$B_SOCKETS (Tilix pid $PID)"
    echo "Opening $N new sessions, each looks up your login shell on the host..."
    i=0
    while [ "$i" -lt "$N" ]; do
        flatpak run "$APP" --action=app-new-session >/dev/null 2>&1
        sleep 1
        i=$((i + 1))
    done
    set -- $(counts "$PID")
    echo "Opened:  fds=$1 pipes=$2 sockets=$3"
    echo
    echo "Now close the $N new sessions (type 'exit' or use the session close button,"
    echo "closing checks for running processes on the host). Leave the original session open."
    printf "Press Enter when done... "
    read -r _
    sleep 2
    if [ -z "$(counts "$PID")" ]; then
        echo "Tilix is no longer running (pid $PID), did it crash or was the last window closed?" >&2
        exit 1
    fi
    set -- $(counts "$PID")
    A_TOTAL=$1; A_PIPES=$2; A_SOCKETS=$3
    echo "After:   fds=$A_TOTAL pipes=$A_PIPES sockets=$A_SOCKETS"
    D_TOTAL=$((A_TOTAL - B_TOTAL)); D_PIPES=$((A_PIPES - B_PIPES)); D_SOCKETS=$((A_SOCKETS - B_SOCKETS))
    echo "Change:  fds=$D_TOTAL pipes=$D_PIPES sockets=$D_SOCKETS after $N open/close cycles"
    echo
    # Before the fix every host command leaked 2 pipe fds and a D-Bus connection
    # (a socket), and each cycle runs at least two host commands. Allow a little
    # slack for caches GLib and GTK create once.
    if [ "$D_PIPES" -ge "$N" ] || [ "$D_SOCKETS" -ge "$N" ]; then
        echo "FAIL: descriptors grow with each cycle, host commands are leaking"
        exit 1
    elif [ "$D_TOTAL" -gt 4 ]; then
        echo "CHECK: $D_TOTAL more descriptors than before, repeat with a larger N to see if it grows"
        exit 2
    else
        echo "PASS: no descriptors leaked"
    fi
    ;;
*)
    echo "Usage: $0 snapshot | cycle [N]" >&2
    exit 1
    ;;
esac
