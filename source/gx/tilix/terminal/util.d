/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */
module gx.tilix.terminal.util;

import std.conv;
import std.experimental.logger;
import std.file;
import std.process;
import std.uuid;

//Cribbed from Gnome Terminal
immutable string[] shells = [/* Note that on some systems shells can also
        * be installed in /usr/bin */
"/bin/bash", "/usr/bin/bash", "/bin/zsh", "/usr/bin/zsh", "/bin/tcsh", "/usr/bin/tcsh", "/bin/ksh", "/usr/bin/ksh", "/bin/csh", "/bin/sh"];

string getUserShell(string shell) {
    import std.file : exists;
    import core.sys.posix.pwd : getpwuid, passwd;
    import core.sys.posix.unistd: getuid;

    if (shell.length > 0 && exists(shell))
        return shell;

    // Try environment variable next
    try {
        shell = environment["SHELL"];
        if (shell.length > 0) {
            tracef("Using shell %s from SHELL environment variable", shell);
            return shell;
        }
    }
    catch (Exception e) {
        trace("No SHELL environment variable found");
    }

    //Try to get shell from getpwuid
    passwd* pw = getpwuid(getuid());
    if (pw && pw.pw_shell) {
        string pw_shell = to!string(pw.pw_shell);
        if (exists(pw_shell)) {
            tracef("Using shell %s from getpwuid",pw_shell);
            return pw_shell;
        }
    }

    //Try known shells
    foreach (s; shells) {
        if (exists(s)) {
            tracef("Found shell %s, using that", s);
            return s;
        }
    }
    error("No shell found, defaulting to /bin/sh");
    return "/bin/sh";
}

bool isFlatpak() {
    return "/.flatpak-info".exists;
}
/**
 * Escape sequences can only move the cursor within the visible screen, so if the
 * cursor is further back than one screen from the last row checked for triggers
 * the scrollback must have been cleared, i.e. by the clear command.
 */
bool isScrollbackCleared(long cursorRow, long lastRowChecked, long rowCount) {
    return cursorRow < lastRowChecked - rowCount;
}

unittest {
    // Cursor moving within the screen, i.e. a progress bar redrawing lines
    assert(!isScrollbackCleared(1000, 1000, 24));
    assert(!isScrollbackCleared(990, 1000, 24));
    assert(!isScrollbackCleared(976, 1000, 24));
    // Back further than a screen height
    assert(isScrollbackCleared(975, 1000, 24));
    assert(isScrollbackCleared(0, 1000, 24));
    // Nothing checked yet
    assert(!isScrollbackCleared(0, -1, 24));
    // Output moving forward
    assert(!isScrollbackCleared(1100, 1000, 24));
}

/**
 * Returns the title override to store for a title entered when renaming a
 * terminal. An empty title, or the profile's own title, means no override so
 * the terminal keeps following the profile's title.
 */
string titleOverrideFor(string entered, string profileTitle) {
    import std.string : strip;

    string title = entered.strip();
    return (title.length == 0 || title == profileTitle) ? null : title;
}

unittest {
    assert(titleOverrideFor("web server", "${title}") == "web server");
    // Surrounding spaces are dropped, inner ones kept
    assert(titleOverrideFor("  db   backup ", "${title}") == "db   backup");
    // Variables can be used like in the profile's title
    assert(titleOverrideFor("${hostname}: logs", "${title}") == "${hostname}: logs");
    // Empty, or unchanged from the profile, follows the profile again
    assert(titleOverrideFor("", "${title}") is null);
    assert(titleOverrideFor("   ", "${title}") is null);
    assert(titleOverrideFor("${title}", "${title}") is null);
}
