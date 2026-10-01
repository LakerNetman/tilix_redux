#!/usr/bin/env sh

# Determine PREFIX the same way as install.sh
if [ -z "$1" ]; then
    if [ -z "$PREFIX" ]; then
        PREFIX='/usr'
    fi
else
    PREFIX="$1"
fi
export PREFIX

if [ "$PREFIX" = "/usr" ] && [ "$(id -u)" != "0" ]; then
    # Make sure only root can run our script
    echo "This script must be run as root" 1>&2
    exit 1
fi

echo "Uninstalling from prefix ${PREFIX}"

rm -f "${PREFIX}/bin/tilix"
rm -f "${PREFIX}/share/glib-2.0/schemas/com.gexperts.Tilix.gschema.xml"
glib-compile-schemas "${PREFIX}/share/glib-2.0/schemas/"
rm -rf "${PREFIX}/share/tilix"

find "${PREFIX}/share/locale" -type f -name "tilix.mo" -delete
find "${PREFIX}/share/icons/hicolor" -type f -name "com.gexperts.Tilix.png" -delete
find "${PREFIX}/share/icons/hicolor" -type f -name "com.gexperts.Tilix*.svg" -delete
rm -f "${PREFIX}/share/nautilus-python/extensions/open-tilix.py"
rm -f "${PREFIX}/share/dbus-1/services/com.gexperts.Tilix.service"
rm -f "${PREFIX}/share/applications/com.gexperts.Tilix.desktop"
rm -f "${PREFIX}/share/metainfo/com.gexperts.Tilix.appdata.xml"
rm -f "${PREFIX}/share/man/man1/tilix.1.gz"
rm -f "${PREFIX}"/share/man/*/man1/tilix.1.gz
