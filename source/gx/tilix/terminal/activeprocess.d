/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */
module gx.tilix.terminal.activeprocess;

import core.sys.posix.unistd;

import std.algorithm;
import std.array;
import std.conv;
import std.experimental.logger;
import std.file;
import std.path;
import std.string;
import std.typecons : Nullable;

/**
 * The fields of /proc/<pid>/stat used to find the active process of a terminal
 */
struct ProcStat {
    pid_t pid;
    string name;
    pid_t ppid;
    pid_t pgrp;
    /// The session id, the pid of the terminal's shell
    pid_t session;
    long ttyNr;
    /// The foreground process group of the controlling terminal
    pid_t tpgid;
    /// Identifies a process instance even if its pid is reused later
    ulong startTime;

    /**
     * Foreground process has a controlling terminal and
     * process group id == terminal process group id.
     */
    @property bool isForeground() const {
        return ttyNr > 0 && pgrp == tpgid;
    }
}

/**
 * Parses the contents of /proc/<pid>/stat, returns null if it isn't valid.
 *
 * The name is in parentheses and may itself contain parentheses and spaces,
 * so the fields are located from the last ')'.
 */
Nullable!ProcStat parseStat(string content) {
    Nullable!ProcStat result;
    ptrdiff_t lpar = content.indexOf('(');
    ptrdiff_t rpar = content.lastIndexOf(')');
    if (lpar < 1 || rpar < lpar) return result;
    // Fields after the name, starting with the state which is field 3
    string[] fields = content[rpar + 1 .. $].split();
    // starttime is field 22
    if (fields.length < 20) return result;
    try {
        ProcStat stat;
        stat.pid = to!pid_t(content[0 .. lpar].strip());
        stat.name = content[lpar + 1 .. rpar];
        stat.ppid = to!pid_t(fields[1]);
        stat.pgrp = to!pid_t(fields[2]);
        stat.session = to!pid_t(fields[3]);
        stat.ttyNr = to!long(fields[4]);
        stat.tpgid = to!pid_t(fields[5]);
        stat.startTime = to!ulong(fields[19]);
        result = stat;
    } catch (ConvException e) {
        // Leave result null
    }
    return result;
}

/**
 * Returns the active process of every terminal, keyed by session id which is the
 * pid of the terminal's shell.
 *
 * The foreground processes are grouped by session. When a session has one it is
 * the active process: the shell itself when idle, otherwise the command it is
 * running. With several, i.e. a pipeline or a command that started others, the
 * active process is the one with the highest pid that has no foreground children.
 */
ProcStat[pid_t] activeProcesses(const ProcStat[] stats) {
    ProcStat[][pid_t] sessions;
    foreach (stat; stats.dup.sort!((a, b) => a.pid < b.pid)) {
        if (stat.isForeground) {
            sessions[stat.session] ~= stat;
        }
    }

    ProcStat[pid_t] result;
    foreach (session, foreground; sessions) {
        if (foreground.length == 1) {
            result[session] = foreground[0];
            continue;
        }
        foreach_reverse (stat; foreground) {
            if (!foreground.canFind!(p => p.ppid == stat.pid)) {
                result[session] = stat;
                break;
            }
        }
    }
    return result;
}

/**
 * A change in the active process of a terminal
 */
struct ActiveProcessChange {
    /// The pid of the terminal's shell
    pid_t shell;
    pid_t pid;
    string name;
}

/**
 * Compares the active process last seen for each shell with the current ones and
 * returns the shells where it changed. Shells with no active process, i.e. one
 * that just exited, are left unchanged.
 *
 * Params:
 *  lastSeen = The pid of the active process last seen keyed by shell pid, -1 if none yet
 *  active   = The current active processes keyed by shell pid, see activeProcesses
 */
ActiveProcessChange[] diffActiveProcesses(const pid_t[pid_t] lastSeen, const ProcStat[pid_t] active) {
    ActiveProcessChange[] result;
    foreach (shell, lastPid; lastSeen) {
        const(ProcStat)* current = shell in active;
        if (current !is null && current.pid != lastPid) {
            result ~= ActiveProcessChange(shell, current.pid, current.name);
        }
    }
    return result;
}

/**
 * Provides the stats of the processes in terminal sessions
 */
interface ProcessSource {
    /**
     * Returns the stats of the processes in the sessions of the given shells.
     * Stats of other processes may also be included.
     */
    ProcStat[] snapshot(const pid_t[] shells);
}

/**
 * Reads process stats from the proc file system.
 *
 * Stats are cached by pid. On each snapshot new processes are read and processes
 * with a controlling terminal are read again since their foreground state changes,
 * the others are not re-read. This is the same amount of reading as before the
 * process code was restructured.
 */
class ProcFsSource: ProcessSource {
private:
    string root;
    ProcStat[pid_t] cache;

    pid_t[] pids() {
        return dirEntries(root, SpanMode.shallow)
            .map!(a => baseName(a.name))
            .filter!(name => name.isNumeric)
            .map!(name => to!pid_t(name))
            .array;
    }

    /**
     * Reads the stat of a process, returns null if the process no longer exists
     * or the file can't be parsed.
     */
    Nullable!ProcStat read(pid_t pid) {
        try {
            return parseStat(readText(buildPath(root, to!string(pid), "stat")));
        } catch (Exception e) {
            // The process exited after the directory was listed
            return Nullable!ProcStat();
        }
    }

public:
    /**
     * Params:
     *  root = The proc file system, tests use a directory with the same layout
     */
    this(string root = "/proc") {
        this.root = root;
    }

    ProcStat[] snapshot(const pid_t[] shells) {
        pid_t[] current;
        try {
            current = pids();
        } catch (Exception e) {
            warning(e);
            return [];
        }
        bool[pid_t] exists;
        foreach (pid; current) exists[pid] = true;
        foreach (pid; cache.keys) {
            if (pid !in exists) cache.remove(pid);
        }

        ProcStat[] result;
        foreach (pid; current) {
            ProcStat* cached = pid in cache;
            if (cached is null || cached.ttyNr > 0) {
                Nullable!ProcStat stat = read(pid);
                if (stat.isNull) {
                    cache.remove(pid);
                    continue;
                }
                cache[pid] = stat.get;
                cached = pid in cache;
            }
            if (shells.canFind(cached.session)) {
                result ~= *cached;
            }
        }
        return result;
    }
}

// Parsing stat files
unittest {
    string line(string pidAndName, string rest) {
        return pidAndName ~ " " ~ rest;
    }
    // Fields from state (3) to starttime (22) and a few more
    enum REST = "S 1000 1234 1000 34816 1234 4194560 100 0 0 0 5 2 0 0 20 0 1 0 987654 1000000 200 18446744073709551615";

    auto stat = parseStat(line("1234 (vim)", REST));
    assert(!stat.isNull);
    assert(stat.get.pid == 1234 && stat.get.name == "vim");
    assert(stat.get.ppid == 1000 && stat.get.pgrp == 1234 && stat.get.session == 1000);
    assert(stat.get.ttyNr == 34816 && stat.get.tpgid == 1234);
    assert(stat.get.startTime == 987654);
    assert(stat.get.isForeground);

    // Names with parentheses and spaces
    assert(parseStat(line("42 (a) (b c)", REST)).get.name == "a) (b c");
    assert(parseStat(line("42 ()", REST)).get.name == "");
    // Trailing newline as read from the file
    assert(parseStat(line("42 (x)", REST) ~ "\n").get.startTime == 987654);

    // Invalid content
    assert(parseStat("").isNull);
    assert(parseStat("1234 vim S 1 2 3").isNull);
    assert(parseStat("1234 (vim) S 1000 1234").isNull);
    assert(parseStat(line("abc (vim)", REST)).isNull);
    assert(parseStat("1234 (vim) S x 1234 1000 34816 1234 0 0 0 0 0 0 0 0 0 20 0 1 0 5").isNull);
    assert(parseStat(line("(vim)", REST)).isNull);

    // Not foreground without a terminal or in a background process group
    ProcStat s;
    s.ttyNr = 0; s.pgrp = 5; s.tpgid = 5;
    assert(!s.isForeground);
    s.ttyNr = 34816; s.tpgid = 6;
    assert(!s.isForeground);
}

// Finding the active process of each terminal
unittest {
    enum TTY1 = 34816;
    enum TTY2 = 34817;

    ProcStat proc(pid_t pid, string name, pid_t ppid, pid_t pgrp, pid_t session, long tty, pid_t tpgid) {
        return ProcStat(pid, name, ppid, pgrp, session, tty, tpgid, 0);
    }

    // Idle shell, it is in the foreground itself
    auto active = activeProcesses([proc(100, "bash", 1, 100, 100, TTY1, 100)]);
    assert(active.length == 1 && active[100].name == "bash");

    // Shell running vim, the shell is no longer in the foreground
    active = activeProcesses([
        proc(100, "bash", 1, 100, 100, TTY1, 200),
        proc(200, "vim", 100, 200, 100, TTY1, 200)]);
    assert(active[100].name == "vim" && active[100].pid == 200);

    // A pipeline, the process with the highest pid wins
    active = activeProcesses([
        proc(100, "bash", 1, 100, 100, TTY1, 300),
        proc(300, "cat", 100, 300, 100, TTY1, 300),
        proc(301, "less", 100, 300, 100, TTY1, 300)]);
    assert(active[100].name == "less");

    // A command that started others, the one without foreground children wins.
    // After pid wrap around make has the highest pid but it has children.
    active = activeProcesses([
        proc(100, "bash", 1, 100, 100, TTY1, 410),
        proc(401, "gcc", 410, 410, 100, TTY1, 410),
        proc(410, "make", 100, 410, 100, TTY1, 410),
        proc(402, "sh", 401, 410, 100, TTY1, 410),
        proc(403, "cc1", 402, 410, 100, TTY1, 410)]);
    assert(active[100].name == "cc1");

    // Background jobs and processes without a terminal are ignored
    active = activeProcesses([
        proc(100, "bash", 1, 100, 100, TTY1, 100),
        proc(500, "sleep", 100, 500, 100, TTY1, 100),
        proc(600, "daemon", 1, 600, 600, 0, -1)]);
    assert(active.length == 1 && active[100].name == "bash");

    // Two terminals, input order doesn't matter
    active = activeProcesses([
        proc(201, "top", 110, 201, 110, TTY2, 201),
        proc(100, "bash", 1, 100, 100, TTY1, 100),
        proc(110, "zsh", 1, 110, 110, TTY2, 201)]);
    assert(active.length == 2 && active[100].name == "bash" && active[110].name == "top");

    assert(activeProcesses([]).length == 0);
}

// Detecting changes in the active process
unittest {
    ProcStat active(pid_t pid, string name) {
        ProcStat s;
        s.pid = pid;
        s.name = name;
        return s;
    }

    // First scan, nothing seen yet
    auto changes = diffActiveProcesses([100: -1], [100: active(100, "bash")]);
    assert(changes == [ActiveProcessChange(100, 100, "bash")]);

    // No change
    assert(diffActiveProcesses([100: 100], [100: active(100, "bash")]).length == 0);

    // Command started, then back to the idle shell
    assert(diffActiveProcesses([100: 100], [100: active(200, "vim")]) == [ActiveProcessChange(100, 200, "vim")]);
    assert(diffActiveProcesses([100: 200], [100: active(100, "bash")]) == [ActiveProcessChange(100, 100, "bash")]);

    // No active process found, i.e. between a command exiting and the next scan
    assert(diffActiveProcesses([100: 200], null).length == 0);

    // Only watched shells are reported
    assert(diffActiveProcesses([100: 100], [100: active(100, "bash"), 110: active(201, "top")]).length == 0);
}

// Reading from a proc file system
unittest {
    import std.process : thisProcessID;

    string root = buildPath(tempDir(), "tilix-proc-test-" ~ to!string(thisProcessID()));
    mkdirRecurse(root);
    scope(exit) rmdirRecurse(root);

    void writeStat(pid_t pid, string name, pid_t ppid, pid_t pgrp, pid_t session, long tty, pid_t tpgid, ulong start = 1) {
        mkdirRecurse(buildPath(root, to!string(pid)));
        std.file.write(buildPath(root, to!string(pid), "stat"),
            format("%d (%s) S %d %d %d %d %d 0 0 0 0 0 0 0 0 0 20 0 1 0 %d 0 0\n", pid, name, ppid, pgrp, session, tty, tpgid, start));
    }

    writeStat(1, "systemd", 0, 1, 1, 0, -1);
    writeStat(100, "bash", 1, 100, 100, 34816, 100);
    writeStat(110, "zsh", 1, 110, 110, 34817, 110);
    // Not processes, or not readable as one
    mkdirRecurse(buildPath(root, "self"));
    mkdirRecurse(buildPath(root, "999"));
    mkdirRecurse(buildPath(root, "998"));
    std.file.write(buildPath(root, "998", "stat"), "garbage");

    ProcFsSource source = new ProcFsSource(root);

    // Only the processes in the requested sessions
    ProcStat[] stats = source.snapshot([100]);
    assert(stats.length == 1 && stats[0].name == "bash");
    assert(source.snapshot([100, 110]).length == 2);
    assert(source.snapshot([]).length == 0);

    // A command starts in the first terminal
    writeStat(100, "bash", 1, 100, 100, 34816, 200);
    writeStat(200, "bash", 100, 200, 100, 34816, 200);
    assert(activeProcesses(source.snapshot([100]))[100].name == "bash");
    // It execs, processes with a terminal are re-read so the new name is seen
    // rather than the name from before the exec
    writeStat(200, "vim", 100, 200, 100, 34816, 200);
    auto active = activeProcesses(source.snapshot([100]));
    assert(active[100].name == "vim" && active[100].pid == 200);

    // It exits, the idle shell is active again
    rmdirRecurse(buildPath(root, "200"));
    writeStat(100, "bash", 1, 100, 100, 34816, 100);
    active = activeProcesses(source.snapshot([100]));
    assert(active[100].name == "bash" && active[100].pid == 100);
    assert(200 !in source.cache);

    // A missing root is not an error
    assert(new ProcFsSource(buildPath(root, "missing")).snapshot([100]).length == 0);
}
