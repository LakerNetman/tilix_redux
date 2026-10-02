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
 * Returns the local directory of a terminal for actions such as opening a file
 * browser, or null if it isn't known.
 *
 * The shell reports its directory through shell integration (vte.sh). Without it
 * the shell's working directory is read from the proc file system, and failing that,
 * i.e. in a Flatpak where the shell runs on the host, the directory the terminal
 * started in is used.
 *
 * Params:
 *  reported   = The directory reported by the shell, empty if none
 *  shell      = The pid of the terminal's shell, 0 or less if not running
 *  initialCWD = The directory the terminal started in
 *  procRoot   = The proc file system, tests use a directory with the same layout
 */
string terminalLocalDirectory(string reported, int shell, string initialCWD, string procRoot = "/proc") {
    import std.path : buildPath;

    if (reported.length > 0) return reported;
    if (shell > 0) {
        try {
            string cwd = readLink(buildPath(procRoot, to!string(shell), "cwd"));
            if (cwd.length > 0 && isDir(cwd)) return cwd;
        } catch (Exception e) {
            // The shell exited, or its directory can't be read
        }
    }
    if (initialCWD.length > 0 && exists(initialCWD) && isDir(initialCWD)) return initialCWD;
    return null;
}

unittest {
    import std.path : buildPath;

    string root = buildPath(tempDir(), "tilix-cwd-test-" ~ to!string(thisProcessID()));
    string shellDir = buildPath(root, "projects");
    mkdirRecurse(shellDir);
    mkdirRecurse(buildPath(root, "proc", "100"));
    symlink(shellDir, buildPath(root, "proc", "100", "cwd"));
    scope(exit) rmdirRecurse(root);
    string proc = buildPath(root, "proc");

    // The reported directory wins
    assert(terminalLocalDirectory("/reported", 100, "/start", proc) == "/reported");
    // Without shell integration the shell's own working directory is used
    assert(terminalLocalDirectory("", 100, "/start", proc) == shellDir);
    // The shell isn't visible, i.e. in a Flatpak, so the starting directory is used
    assert(terminalLocalDirectory("", 200, root, proc) == root);
    assert(terminalLocalDirectory("", 0, root, proc) == root);
    // Nothing known, or a starting directory that no longer exists
    assert(terminalLocalDirectory("", 200, "", proc) is null);
    assert(terminalLocalDirectory("", 200, buildPath(root, "gone"), proc) is null);
}

/**
 * Returns the text to type into a shell to run a startup command: the command
 * ended by exactly one newline, or nothing if there is no command.
 */
string initCommandText(string command) {
    import std.string : strip, stripRight;

    if (command.strip().length == 0) return "";
    return command.stripRight("\r\n") ~ "\n";
}

unittest {
    assert(initCommandText("npm run server") == "npm run server\n");
    // A newline already there isn't doubled, which would also run an empty command
    assert(initCommandText("source venv/bin/activate\n") == "source venv/bin/activate\n");
    assert(initCommandText("ls\r\n") == "ls\n");
    // Inner content, including quotes and semicolons, is typed as is
    assert(initCommandText("cd ~/dev && git status; echo 'done'") == "cd ~/dev && git status; echo 'done'\n");
    assert(initCommandText("") == "");
    assert(initCommandText("   ") == "");
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

/**
 * Returns the last part of a directory path, i.e. "tilix" for "/home/u/src/tilix/".
 * The root directory gives "/".
 */
string directoryName(string path) {
    import std.path : baseName;
    import std.string : stripRight;

    if (path.length == 0) return "";
    string trimmed = path.stripRight("/");
    if (trimmed.length == 0) return "/";
    return baseName(trimmed);
}

/**
 * Returns the name of the git repository containing the directory, the name of
 * the directory with a .git entry found by walking up from it, or null if it
 * isn't in a repository. .git can be a file, as in worktrees and submodules.
 */
string findGitRepository(string directory) {
    import std.path : buildPath, dirName, isAbsolute;

    if (directory.length == 0 || !isAbsolute(directory)) return null;
    string current = directory;
    // Deep enough for any real path, and guards against a loop
    foreach (i; 0 .. 256) {
        try {
            if (exists(buildPath(current, ".git"))) return directoryName(current);
        } catch (Exception e) {
            // Can't be read, i.e. permissions, keep walking up
        }
        string parent = dirName(current);
        if (parent == current) break;
        current = parent;
    }
    return null;
}

unittest {
    import std.path : buildPath;

    assert(directoryName("/home/u/src/tilix") == "tilix");
    assert(directoryName("/home/u/src/tilix/") == "tilix");
    assert(directoryName("/home/u/my project") == "my project");
    assert(directoryName("/") == "/");
    assert(directoryName("") == "");

    string root = buildPath(tempDir(), "tilix-git-test-" ~ to!string(thisProcessID()));
    scope(exit) rmdirRecurse(root);
    // A repository with a .git directory, and a nested directory in it
    mkdirRecurse(buildPath(root, "projects", "tilix", ".git"));
    mkdirRecurse(buildPath(root, "projects", "tilix", "source", "gx"));
    // A worktree, where .git is a file
    mkdirRecurse(buildPath(root, "projects", "tilix-fixes", "docs"));
    std.file.write(buildPath(root, "projects", "tilix-fixes", ".git"), "gitdir: ../tilix/.git/worktrees/fixes\n");
    // Not in a repository
    mkdirRecurse(buildPath(root, "notes"));

    assert(findGitRepository(buildPath(root, "projects", "tilix")) == "tilix");
    assert(findGitRepository(buildPath(root, "projects", "tilix", "source", "gx")) == "tilix");
    assert(findGitRepository(buildPath(root, "projects", "tilix-fixes", "docs")) == "tilix-fixes");
    // Outside any repository, unless the temporary directory itself is in one
    if (findGitRepository(tempDir()) is null) {
        assert(findGitRepository(buildPath(root, "notes")) is null);
    }
    // A directory that doesn't exist still checks its parents
    assert(findGitRepository(buildPath(root, "projects", "tilix", "gone")) == "tilix");
    assert(findGitRepository("relative/path") is null);
    assert(findGitRepository("") is null);
}
