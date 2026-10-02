#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
# distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Checks the GNOME Shell search provider over a real D-Bus, without starting Tilix or touching the
# desktop's bus. It builds a small probe program around source/gx/tilix/searchprovider.d with fixed
# results, runs a private bus that starts the probe on demand (as GNOME Shell's first search would
# start Tilix) and calls every org.gnome.Shell.SearchProvider2 method with gdbus.
#
# The probe runs twice: as a plain GApplication, and as a windowless GtkApplication like Tilix, which
# checks that the provider chains onto GTK's own D-Bus registration. The GTK run needs a display and
# is skipped without one. The probe owns Tilix's real bus name, which is safe as the bus is private.
#
# Then the Cinnamon menu plugin (data/cinnamon/tilix@gexperts.com) is run in cjs against the probe,
# see cinnamon-search-harness.js. That part is skipped without cjs.
#
# Needs ldc2, dbus-run-session, gdbus and GtkD 3.11 found by pkg-config, for example:
#   PKG_CONFIG_PATH=~/.local/gtkd-3.11/lib/x86_64-linux-gnu/pkgconfig \
#   LD_LIBRARY_PATH=~/.local/gtkd-3.11/lib/x86_64-linux-gnu tests/manual/search-provider-dbus.sh

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

for tool in ldc2 dbus-run-session gdbus pkg-config; do
    command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 2; }
done
pkg-config --exists gtkd-3 || { echo "GtkD not found, set PKG_CONFIG_PATH" >&2; exit 2; }

# pkg-config mixes C compiler flags into the output, ldc2 only needs GtkD's own
DFLAGS=$(pkg-config --cflags --libs gtkd-3 | tr ' ' '\n' | grep -E '^-I.*gtkd|^-L-' | tr '\n' ' ')
# The probe is linked with GtkD's folder as its rpath, otherwise the bus starts it with the system's
# GtkD, which may be an older version (Ubuntu ships 3.10) and crashes it
GTKD_LIBDIR=$(printf '%s\n' $DFLAGS | sed -n 's/^-L-L//p' | head -1)
[ -n "$GTKD_LIBDIR" ] && DFLAGS="$DFLAGS -L-rpath=$GTKD_LIBDIR"

cat > "$WORK/probe.d" <<'EOF'
import std.process : environment;
import std.stdio;
import gio.c.types : GApplicationFlags;
import gx.tilix.searchprovider;

version (Gtk) import gtk.Application;
else import gio.Application;

class Host: SearchProviderHost {
    SearchItem[] searchItems() {
        // Logged so tests can tell whether a search reached the provider
        File(environment["PROBE_LOG"], "a").writeln("items");
        return [SearchItem("terminal:t1", "vim notes", "Default — ~/docs", "com.gexperts.Tilix", ["vim notes", "/home/me/docs"]),
                SearchItem("bookmark:b1", "Server", "Bookmark — me@host", "network-server", ["Server", "me@host"])];
    }
    void activateResult(string id, uint timestamp) {
        File(environment["PROBE_LOG"], "a").writefln("activate %s %s", id, timestamp);
    }
    void launchSearch(string[] terms, uint timestamp) {
        File(environment["PROBE_LOG"], "a").writefln("launch %s %s", terms, timestamp);
    }
}

int main(string[] args) {
    auto app = new Application("com.gexperts.Tilix", GApplicationFlags.FLAGS_NONE);
    installSearchProvider(app.getApplicationStruct(), new Host());
    app.setInactivityTimeout(3000);
    return app.run(args);
}
EOF

# Only the probe's service directory, standard services such as portals would slow GTK's startup
# on a bus where they can't work
sed -e 's|<standard_session_servicedirs */>||' -e 's|<servicedir>.*</servicedir>||' \
    -e "s|</busconfig>|<servicedir>$WORK/services</servicedir></busconfig>|" \
    /usr/share/dbus-1/session.conf > "$WORK/session.conf"

# Runs inside the private bus, prints one line per check
cat > "$WORK/calls.sh" <<'EOF'
call() {
    gdbus call --session --dest com.gexperts.Tilix --object-path /com/gexperts/Tilix/SearchProvider \
        --method org.gnome.Shell.SearchProvider2."$@" 2>&1
}
echo "initial: $(call GetInitialResultSet "['DOCS']")"
echo "subsearch: $(call GetSubsearchResultSet "['terminal:t1']" "['host']")"
echo "metas: $(call GetResultMetas "['bookmark:b1','gone:1','terminal:t1']")"
echo "activate: $(call ActivateResult terminal:t1 "['docs']" 1234)"
echo "launch: $(call LaunchSearch "['a','b']" 99)"
echo "nomatch: $(call GetInitialResultSet "['zzz']")"
echo "unknown: $(call Nope)"
EOF

PASS=0
FAIL=0
expect() {
    local label=$1 pattern=$2 text=$3
    if printf '%s\n' "$text" | grep -qF -- "$pattern"; then
        PASS=$((PASS + 1))
        echo "  ok   $label"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL $label, expected: $pattern"
    fi
}

# Lets the private bus start the probe of the given kind, logging to the given file
write_service() {
    rm -rf "$WORK/services" && mkdir "$WORK/services"
    cat > "$WORK/services/com.gexperts.Tilix.service" <<EOF
[D-BUS Service]
Name=com.gexperts.Tilix
Exec=/usr/bin/env PROBE_LOG=$2 $WORK/probe-$1 --gapplication-service
EOF
}

run_probe() {
    local kind=$1 version=$2
    echo "== $kind"
    if ! ldc2 $version -of="$WORK/probe-$kind" -I "$ROOT/source" "$WORK/probe.d" \
            "$ROOT/source/gx/tilix/searchprovider.d" $DFLAGS >"$WORK/build-$kind.log" 2>&1; then
        FAIL=$((FAIL + 1))
        echo "  FAIL build, see below"
        cat "$WORK/build-$kind.log"
        return
    fi
    local log="$WORK/probe-$kind.log"
    write_service "$kind" "$log"
    local out failed_before=$FAIL
    out=$(timeout 60 dbus-run-session --config-file="$WORK/session.conf" -- bash "$WORK/calls.sh" 2>/dev/null)
    local log_text=""
    [ -f "$log" ] && log_text=$(cat "$log")

    # The first call starts the probe, so its object must exist before the bus name is owned
    expect "first call starts the probe and is answered" "initial: (['terminal:t1'],)" "$out"
    expect "subsearch searches the new terms" "subsearch: (['bookmark:b1'],)" "$out"
    expect "metas in requested order, unknown id skipped" \
        "metas: ([{'id': <'bookmark:b1'>, 'name': <'Server'>, 'description': <'Bookmark — me@host'>, 'gicon': <'network-server'>}, {'id': <'terminal:t1'>, 'name': <'vim notes'>, 'description': <'Default — ~/docs'>, 'gicon': <'com.gexperts.Tilix'>}],)" "$out"
    expect "activate replies" "activate: ()" "$out"
    expect "activate reaches the host with its timestamp" "activate terminal:t1 1234" "$log_text"
    expect "launch replies" "launch: ()" "$out"
    expect "launch reaches the host with its terms" 'launch ["a", "b"] 99' "$log_text"
    expect "no match is an empty list" "nomatch: (@as [],)" "$out"
    expect "unknown method is an error" "org.freedesktop.DBus.Error.UnknownMethod" "$out"
    if [ "$FAIL" -gt "$failed_before" ]; then
        echo "  -- gdbus output:"
        printf '%s\n' "$out" | sed 's/^/     /'
        echo "  -- probe log:"
        printf '%s\n' "$log_text" | sed 's/^/     /'
    fi
}

run_probe gio ""
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    run_probe gtk "-d-version=Gtk"
else
    echo "== gtk skipped, no display"
fi

# The Cinnamon plugin, run in cjs against the plain probe
run_cinnamon() {
    echo "== cinnamon menu plugin"
    if ! command -v cjs >/dev/null; then
        echo "  skipped, no cjs"
        return
    fi
    if [ ! -x "$WORK/probe-gio" ]; then
        FAIL=$((FAIL + 1))
        echo "  FAIL no probe, its build failed above"
        return
    fi
    local log="$WORK/probe-cinnamon.log" out ok bad
    write_service gio "$log"
    out=$(timeout 60 dbus-run-session --config-file="$WORK/session.conf" -- \
        cjs "$ROOT/tests/manual/cinnamon-search-harness.js" \
        "$ROOT/data/cinnamon/tilix@gexperts.com/search_provider.js" "$log" 2>&1)
    printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
    ok=$(printf '%s\n' "$out" | grep -c '^  ok ')
    bad=$(printf '%s\n' "$out" | grep -c '^  FAIL ')
    PASS=$((PASS + ok))
    FAIL=$((FAIL + bad))
    # The harness prints a summary line last, without it cjs failed before finishing
    if ! printf '%s\n' "$out" | grep -q '^cinnamon failures: '; then
        FAIL=$((FAIL + 1))
        echo "  FAIL harness did not finish:"
        printf '%s\n' "$out" | sed 's/^/     /' | tail -15
    fi
}

run_cinnamon

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
