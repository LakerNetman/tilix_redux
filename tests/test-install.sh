#!/usr/bin/env sh
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
# distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Tests install.sh and uninstall.sh by installing into temporary prefixes whose
# names contain spaces. Works on a copy of the scripts and data with a stub
# tilix binary so it doesn't need a build and never touches the source tree.
#
# Usage: tests/test-install.sh [source dir]
# Exits with 77 (skipped) if a command install.sh needs is missing.

SOURCE_DIR=$(cd "${1:-$(dirname "$0")/..}" && pwd)

for COMMAND in install glib-compile-schemas glib-compile-resources msgfmt desktop-file-validate gtk-update-icon-cache realpath; do
    if ! command -v "$COMMAND" >/dev/null 2>&1; then
        echo "Skipping, $COMMAND is not available"
        exit 77
    fi
done

# Only the prefixes contain spaces, so even the old word splitting uninstall.sh
# could only reach paths inside this directory
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tilix-install-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

pass() {
    echo "ok   $1"
}

# Copy what install.sh uses, it writes generated files next to the sources
SRC="$WORK/src"
mkdir -p "$SRC"
cp -r "$SOURCE_DIR/install.sh" "$SOURCE_DIR/uninstall.sh" "$SOURCE_DIR/data" "$SOURCE_DIR/po" "$SRC/"
printf '#!/bin/sh\n' > "$SRC/tilix"
chmod +x "$SRC/tilix"

# Runs install.sh from the copy, extra arguments are passed through
run_install() {
    (cd "$SRC" && sh ./install.sh "$@") > "$WORK/install.log" 2>&1
}

run_uninstall() {
    (cd "$SRC" && sh ./uninstall.sh "$@") > "$WORK/uninstall.log" 2>&1
}

# Checks the key files installed into a prefix
check_installed() {
    PFX="$1"
    LABEL="$2"
    MISSING=""
    for FILE in \
        bin/tilix \
        share/glib-2.0/schemas/com.gexperts.Tilix.gschema.xml \
        share/tilix/resources/tilix.gresource \
        share/tilix/schemes/solarized-dark.json \
        share/applications/com.gexperts.Tilix.desktop \
        share/metainfo/com.gexperts.Tilix.appdata.xml \
        share/nautilus-python/extensions/open-tilix.py \
        share/dbus-1/services/com.gexperts.Tilix.service \
        share/gnome-shell/search-providers/com.gexperts.Tilix.search-provider.ini \
        share/cinnamon/search_providers/tilix@gexperts.com/metadata.json \
        share/cinnamon/search_providers/tilix@gexperts.com/search_provider.js \
        share/man/man1/tilix.1.gz; do
        [ -f "$PFX/$FILE" ] || MISSING="$MISSING $FILE"
    done
    if ! ls "$PFX"/share/locale/*/LC_MESSAGES/tilix.mo >/dev/null 2>&1; then
        MISSING="$MISSING share/locale/*/LC_MESSAGES/tilix.mo"
    fi
    if [ -z "$(find "$PFX/share/icons/hicolor" -name 'com.gexperts.Tilix*' 2>/dev/null)" ]; then
        MISSING="$MISSING share/icons/hicolor/*/com.gexperts.Tilix*"
    fi
    if [ -n "$MISSING" ]; then
        fail "$LABEL, missing:$MISSING"
        return 1
    fi
    pass "$LABEL"
}

check_empty() {
    PFX="$1"
    LABEL="$2"
    LEFT=$(find "$PFX" -type f 2>/dev/null | grep -v '/share/glib-2.0/schemas/gschemas.compiled$')
    if [ -n "$LEFT" ]; then
        fail "$LABEL, files left behind:"
        echo "$LEFT" | sed 's/^/     /'
        return 1
    fi
    pass "$LABEL"
}

# 1. Prefix given as an argument, with a space in it
PREFIX_A="$WORK/prefix a"
if run_install "$PREFIX_A"; then
    check_installed "$PREFIX_A" "install with prefix argument containing a space"
else
    fail "install with prefix argument containing a space exited with an error"
    tail -5 "$WORK/install.log"
fi

# 2. Prefix from the environment is honoured
PREFIX_B="$WORK/prefix b"
if (export PREFIX="$PREFIX_B"; run_install); then
    check_installed "$PREFIX_B" "install with PREFIX from the environment"
else
    fail "install with PREFIX from the environment exited with an error"
    tail -5 "$WORK/install.log"
fi

# 3. An old msgfmt without --desktop/--xml falls back to the untranslated files
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
REAL_MSGFMT=$(command -v msgfmt)
cat > "$STUBS/msgfmt" <<EOF
#!/bin/sh
case "\$1" in --desktop|--xml) echo "msgfmt: unknown option \$1" >&2; exit 1;; esac
exec "$REAL_MSGFMT" "\$@"
EOF
chmod +x "$STUBS/msgfmt"
PREFIX_C="$WORK/prefix c"
if (PATH="$STUBS:$PATH"; export PATH; run_install "$PREFIX_C"); then
    if check_installed "$PREFIX_C" "install with an old msgfmt"; then
        if cmp -s "$SRC/data/pkg/desktop/com.gexperts.Tilix.desktop.in" "$PREFIX_C/share/applications/com.gexperts.Tilix.desktop" &&
           cmp -s "$SRC/data/metainfo/com.gexperts.Tilix.appdata.xml.in" "$PREFIX_C/share/metainfo/com.gexperts.Tilix.appdata.xml"; then
            pass "old msgfmt installs the untranslated desktop and metainfo files"
        else
            fail "old msgfmt did not install the untranslated desktop and metainfo files"
        fi
    fi
else
    fail "install with an old msgfmt exited with an error, the fallback did not run"
    tail -5 "$WORK/install.log"
fi

# 4. Uninstall removes everything, and a prefix with a space doesn't delete a
#    sibling directory named after the part before the space
mkdir -p "$WORK/prefix/keep"
touch "$WORK/prefix/keep/file"
run_uninstall "$PREFIX_A"
check_empty "$PREFIX_A" "uninstall with prefix argument"
if [ -f "$WORK/prefix/keep/file" ]; then
    pass "uninstall leaves directories sharing part of the prefix name alone"
else
    fail "uninstall deleted '$WORK/prefix', the prefix was split on the space"
fi

# 5. Uninstall with PREFIX from the environment
(export PREFIX="$PREFIX_B"; run_uninstall)
check_empty "$PREFIX_B" "uninstall with PREFIX from the environment"

# The source copy is unchanged apart from generated files
if [ -f "$SRC/tilix" ] && [ -f "$SRC/install.sh" ]; then
    pass "source copy intact"
else
    fail "uninstall removed files from the source directory"
fi

echo "$FAILURES failures"
[ "$FAILURES" -eq 0 ]
