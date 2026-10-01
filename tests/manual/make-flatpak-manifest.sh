#!/usr/bin/env sh
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
# distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Generates a Flatpak manifest that builds Tilix from this checkout rather than
# from GitHub master, using GtkD 3.11 which Tilix needs (VTE pasteText).
#
# Usage: tests/manual/make-flatpak-manifest.sh <output dir>
#
# The output dir gets a copy of experimental/flatpak with the modified manifest,
# build it with:
#   flatpak-builder --user --install --force-clean <output dir>/build <output dir>/com.gexperts.Tilix.yaml
#
# See tests/manual/flatpak-host-commands.md

set -e

SOURCE_DIR=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$1"
if [ -z "$OUT" ]; then
    echo "Usage: $0 <output dir>" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required" >&2
    exit 1
fi

OUT=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$OUT")
case "$OUT" in
    "$SOURCE_DIR"|"$SOURCE_DIR"/*)
        # flatpak-builder copies the source dir, an output dir inside it would be copied into itself
        echo "The output dir must be outside the source tree" >&2
        exit 1;;
esac
mkdir -p "$OUT"

cp "$SOURCE_DIR"/experimental/flatpak/* "$OUT/"

python3 - "$OUT/com.gexperts.Tilix.yaml" "$SOURCE_DIR" <<'EOF'
import sys

manifest, source_dir = sys.argv[1], sys.argv[2]
text = open(manifest).read()

replacements = [
    # GtkD 3.9 lacks VTE pasteText used by Tilix. The pkgconfig patch is
    # already part of 3.11 and no longer applies. The checksum is of the GitHub
    # archive for the v3.11.0 tag as downloaded on 2026-09-29.
    ("""      - type: archive
        url: https://gtkd.org/Downloads/sources/GtkD-3.9.0.zip
        sha512: f8b8a7b83a23af990abb77f16e4bddf2f72bb65ad210ff8f138b0d4ff66fb5fb2a73a3cbe868a8d2ecf3abf98ece5af771af63068dc2fbf8668e46039320cf0f
        strip-components: 0
      - type: patch
        path: gtkd3-pkgconfig.patch
""", """      - type: archive
        url: https://github.com/gtkd-developers/GtkD/archive/refs/tags/v3.11.0.tar.gz
        sha256: c5de7ef0d955c06a35bc979858e2b67c17919294a7aabe36fd593b79c46e5928
"""),
    # Build this checkout, including uncommitted changes, instead of GitHub master
    ("""      - type: git
        url: https://github.com/gnunn1/tilix.git""", """      - type: dir
        path: %s""" % source_dir),
]
for old, new in replacements:
    if text.count(old) != 1:
        sys.exit("Could not find the expected section in %s, has the manifest changed?\n%s" % (manifest, old))
    text = text.replace(old, new)
open(manifest, "w").write(text)
EOF

echo "Manifest written to $OUT/com.gexperts.Tilix.yaml"
echo "Build and install it with:"
echo "  flatpak-builder --user --install --force-clean \"$OUT/build\" \"$OUT/com.gexperts.Tilix.yaml\""
