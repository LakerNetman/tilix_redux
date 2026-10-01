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
import std.utf : validate;

import core.time : Duration, seconds;

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
 * Identifies a process instance, the start time distinguishes a process from a
 * later one that reuses its pid
 */
struct ProcessId {
    pid_t pid = -1;
    ulong startTime;
}

/**
 * A change in the active process of a terminal
 */
struct ActiveProcessChange {
    /// The pid of the terminal's shell
    pid_t shell;
    pid_t pid;
    ulong startTime;
    string name;
}

/**
 * Compares the active process last seen for each shell with the current ones and
 * returns the shells where it changed. Shells with no active process, i.e. one
 * that just exited, are left unchanged.
 *
 * Params:
 *  lastSeen = The active process last seen keyed by shell pid, ProcessId.init if none yet
 *  active   = The current active processes keyed by shell pid, see activeProcesses
 */
ActiveProcessChange[] diffActiveProcesses(const ProcessId[pid_t] lastSeen, const ProcStat[pid_t] active) {
    ActiveProcessChange[] result;
    foreach (shell, last; lastSeen) {
        const(ProcStat)* current = shell in active;
        if (current !is null && (current.pid != last.pid || current.startTime != last.startTime)) {
            result ~= ActiveProcessChange(shell, current.pid, current.startTime, current.name);
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
 * Only the given shells and their descendants are read, the descendants are found
 * through /proc/<pid>/task/<tid>/children rather than reading every process on the
 * system. For an idle shell that is the shell's stat and its children file. Stats
 * are read fresh on every snapshot so names changed by exec are always current.
 *
 * Processes in the session whose parent exited, which are re-parented away from the
 * shell, are not found. That is rare for the foreground job and those processes are
 * usually in the background.
 *
 * Kernels without the children files (CONFIG_PROC_CHILDREN) fall back to reading
 * every process in /proc for that shell.
 */
class ProcFsSource: ProcessSource {
private:
    string root;

    /// Limit on the descendants read for one shell, guards against a fork bomb
    enum MAX_DESCENDANTS = 1000;

    pid_t[] pids() {
        return dirEntries(root, SpanMode.shallow)
            .map!(a => baseName(a.name))
            .filter!(name => name.isNumeric)
            .map!(name => to!pid_t(name))
            .array;
    }

    /**
     * Returns the children of every thread of a process. Sets supported to false if
     * the kernel doesn't provide the children files. A process that exited has none.
     */
    pid_t[] children(pid_t pid, out bool supported) {
        supported = true;
        pid_t[] result;
        try {
            foreach (task; dirEntries(buildPath(root, to!string(pid), "task"), SpanMode.shallow)) {
                string file = buildPath(task.name, "children");
                if (!exists(file)) {
                    supported = false;
                    return null;
                }
                foreach (child; readText(file).split()) {
                    result ~= to!pid_t(child);
                }
            }
        } catch (Exception e) {
            // The process or one of its threads exited while being read
        }
        return result;
    }

    /**
     * Adds the stats of the descendants of shell in its session to result. Returns
     * false if the children files aren't supported.
     */
    bool addDescendants(const ProcStat shell, ref ProcStat[] result) {
        pid_t[] queue = [shell.pid];
        bool[pid_t] seen = [shell.pid: true];
        size_t count = 0;
        while (queue.length > 0 && count < MAX_DESCENDANTS) {
            pid_t pid = queue[0];
            queue = queue[1 .. $];
            bool supported;
            foreach (child; children(pid, supported)) {
                if (child in seen) continue;
                seen[child] = true;
                Nullable!ProcStat stat = read(child);
                // Children that exited or started their own session, i.e. a new
                // terminal, aren't part of this terminal
                if (stat.isNull || stat.get.session != shell.session) continue;
                result ~= stat.get;
                queue ~= child;
                count++;
            }
            if (!supported) return false;
        }
        return true;
    }

    /// Adds every process in the session of shell, used without the children files
    void addSession(const ProcStat shell, ref ProcStat[] result) {
        pid_t[] all;
        try {
            all = pids();
        } catch (Exception e) {
            warning(e);
            return;
        }
        foreach (pid; all) {
            if (pid == shell.pid) continue;
            Nullable!ProcStat stat = read(pid);
            if (!stat.isNull && stat.get.session == shell.session) {
                result ~= stat.get;
            }
        }
    }

protected:
    /**
     * Reads the stat of a process, returns null if the process no longer exists
     * or the file can't be parsed.
     */
    Nullable!ProcStat read(pid_t pid) {
        try {
            return parseStat(readText(buildPath(root, to!string(pid), "stat")));
        } catch (Exception e) {
            // The process exited
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
        ProcStat[] result;
        foreach (pid; shells) {
            Nullable!ProcStat shell = read(pid);
            if (shell.isNull) continue;
            result ~= shell.get;
            // Without a terminal nothing in the session is in the foreground. The
            // descendants are read even when the shell itself is in the foreground,
            // a shell without job control, i.e. sh -c, runs commands in its own
            // process group so they are in the foreground too.
            if (shell.get.ttyNr == 0 || shell.get.tpgid <= 0) continue;
            if (!addDescendants(shell.get, result)) {
                addSession(shell.get, result);
            }
        }
        return result;
    }
}

/**
 * Runs a command and returns what it writes to stdout.
 *
 * Throws: an Exception if it can't be started, exits with a non zero status or takes
 * longer than timeout, in which case it is killed.
 */
string runWithTimeout(string[] args, Duration timeout) {
    import core.stdc.errno : EINTR, errno;
    import core.sys.posix.poll : poll, pollfd, POLLIN;
    import core.sys.posix.unistd : posixRead = read;
    import core.time : MonoTime;
    import std.array : appender;
    import std.exception : ErrnoException;
    import std.process : kill, pipeProcess, Redirect, tryWait, wait;

    auto pipes = pipeProcess(args, Redirect.stdout);
    scope(exit) {
        if (!tryWait(pipes.pid).terminated) {
            kill(pipes.pid);
            wait(pipes.pid);
        }
    }
    // Output is read as it arrives, a command writing more than the pipe holds
    // would otherwise block before exiting
    int fd = pipes.stdout.fileno;
    MonoTime deadline = MonoTime.currTime + timeout;
    auto output = appender!string();
    ubyte[4096] buffer;
    while (true) {
        Duration left = deadline - MonoTime.currTime;
        if (left <= Duration.zero) {
            throw new Exception(format("%s took longer than %s", args[0], timeout));
        }
        pollfd pfd = pollfd(fd, POLLIN);
        int ready = poll(&pfd, 1, cast(int) max(1, left.total!"msecs"));
        if (ready < 0 && errno != EINTR) throw new ErrnoException("poll failed");
        if (ready <= 0) continue;
        auto count = posixRead(fd, buffer.ptr, buffer.length);
        if (count < 0) {
            if (errno == EINTR) continue;
            throw new ErrnoException("read failed");
        }
        if (count == 0) break;
        output.put(cast(const(char)[]) buffer[0 .. count]);
    }
    int status = wait(pipes.pid);
    if (status != 0) {
        throw new Exception(format("%s exited with status %d", args[0], status));
    }
    return output.data;
}

/**
 * Reads process stats on the host when Tilix runs as a Flatpak.
 *
 * The sandbox has its own /proc which can't see the shells, they run on the host.
 * Instead tilix-flatpak-toolbox list-sessions is run on the host with flatpak-spawn,
 * one command per scan, and prints the stat line of each shell and its descendants
 * in its session. It finds them the same way as ProcFsSource.
 */
class FlatpakHostSource: ProcessSource {
private:
    string[] command;
    string delegate(string[] args) run;

    /// The toolbox installed in the Flatpak's app directory, as seen from the host
    static string toolboxPath() {
        string section;
        foreach (line; readText("/.flatpak-info").lineSplitter) {
            line = line.strip();
            if (line.startsWith("[")) {
                section = line;
            } else if (section == "[Instance]" && line.startsWith("app-path=")) {
                return buildPath(line["app-path=".length .. $], "bin", "tilix-flatpak-toolbox");
            }
        }
        throw new FileException("/.flatpak-info", "No app-path in the Instance section");
    }

public:
    /// Runs the toolbox in the Flatpak's app directory on the host
    this() {
        this(["flatpak-spawn", "--host", toolboxPath(), "list-sessions"],
             (string[] args) => runWithTimeout(args, 2.seconds));
    }

    /**
     * Params:
     *  command = The command listing the sessions, the shell pids are appended to it
     *  run     = Runs a command and returns its output, tests replace it
     */
    this(string[] command, string delegate(string[] args) run) {
        this.command = command;
        this.run = run;
    }

    ProcStat[] snapshot(const pid_t[] shells) {
        if (shells.length == 0) return [];
        string output = run(command ~ shells.map!(pid => to!string(pid)).array);
        ProcStat[] result;
        foreach (line; output.lineSplitter) {
            // ProcFsSource skips processes whose stat isn't valid UTF-8, do the same
            try {
                validate(line);
            } catch (Exception e) {
                continue;
            }
            Nullable!ProcStat stat = parseStat(line);
            if (!stat.isNull) result ~= stat.get;
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
    ProcStat active(pid_t pid, string name, ulong startTime = 1) {
        ProcStat s;
        s.pid = pid;
        s.name = name;
        s.startTime = startTime;
        return s;
    }
    ProcessId seen(pid_t pid, ulong startTime = 1) {
        return ProcessId(pid, startTime);
    }

    // First scan, nothing seen yet
    auto changes = diffActiveProcesses([100: ProcessId.init], [100: active(100, "bash")]);
    assert(changes == [ActiveProcessChange(100, 100, 1, "bash")]);

    // No change
    assert(diffActiveProcesses([100: seen(100)], [100: active(100, "bash")]).length == 0);

    // Command started, then back to the idle shell
    assert(diffActiveProcesses([100: seen(100)], [100: active(200, "vim")]) == [ActiveProcessChange(100, 200, 1, "vim")]);
    assert(diffActiveProcesses([100: seen(200)], [100: active(100, "bash")]) == [ActiveProcessChange(100, 100, 1, "bash")]);

    // A new command that reuses the previous command's pid is still a change
    assert(diffActiveProcesses([100: seen(200, 5)], [100: active(200, "less", 9)]) == [ActiveProcessChange(100, 200, 9, "less")]);

    // No active process found, i.e. between a command exiting and the next scan
    assert(diffActiveProcesses([100: seen(200)], null).length == 0);

    // Only watched shells are reported
    assert(diffActiveProcesses([100: seen(100)], [100: active(100, "bash"), 110: active(201, "top")]).length == 0);
}

// Reading from a proc file system
unittest {
    import std.process : thisProcessID;

    string root = buildPath(tempDir(), "tilix-proc-test-" ~ to!string(thisProcessID()));
    mkdirRecurse(root);
    scope(exit) rmdirRecurse(root);

    enum TTY1 = 34816;
    enum TTY2 = 34817;

    // Writes a process's stat and the children file of its main thread
    void proc(pid_t pid, string name, pid_t ppid, pid_t pgrp, pid_t session, long tty, pid_t tpgid,
              pid_t[] children = null, ulong start = 1) {
        string dir = buildPath(root, to!string(pid));
        mkdirRecurse(buildPath(dir, "task", to!string(pid)));
        std.file.write(buildPath(dir, "stat"),
            format("%d (%s) S %d %d %d %d %d 0 0 0 0 0 0 0 0 0 20 0 1 0 %d 0 0\n", pid, name, ppid, pgrp, session, tty, tpgid, start));
        std.file.write(buildPath(dir, "task", to!string(pid), "children"), children.map!(c => to!string(c) ~ " ").join);
    }

    // Writes the children file of another thread of a process
    void thread(pid_t pid, pid_t tid, pid_t[] children) {
        string dir = buildPath(root, to!string(pid), "task", to!string(tid));
        mkdirRecurse(dir);
        std.file.write(buildPath(dir, "children"), children.map!(c => to!string(c) ~ " ").join);
    }

    // Records which processes are read
    class CountingSource: ProcFsSource {
        pid_t[] reads;
        this(string root) { super(root); }
        override Nullable!ProcStat read(pid_t pid) {
            reads ~= pid;
            return super.read(pid);
        }
    }

    // Other processes on the system, none of them are read
    proc(1, "systemd", 0, 1, 1, 0, -1, [100, 110, 120, 500]);
    proc(500, "firefox", 1, 500, 500, 0, -1, [501]);
    proc(501, "firefox", 500, 500, 500, 0, -1);
    // Two terminals, the first idle and the second running top
    proc(100, "bash", 1, 100, 100, TTY1, 100);
    proc(110, "zsh", 1, 110, 110, TTY2, 201, [201]);
    proc(201, "top", 110, 201, 110, TTY2, 201);

    CountingSource source = new CountingSource(root);
    auto active = activeProcesses(source.snapshot([100]));
    assert(active[100].name == "bash");
    assert(source.reads == [100], "Only the shell of an idle terminal is read");

    source.reads = null;
    active = activeProcesses(source.snapshot([100, 110]));
    assert(active[100].name == "bash" && active[110].name == "top");
    assert(source.reads.sort.release == [100, 110, 201]);
    assert(source.snapshot([]).length == 0);

    // A pipeline in the first terminal, the last process in it
    proc(100, "bash", 1, 100, 100, TTY1, 300, [300, 301]);
    proc(300, "cat", 100, 300, 100, TTY1, 300);
    proc(301, "less", 100, 300, 100, TTY1, 300);
    assert(activeProcesses(source.snapshot([100]))[100].name == "less");

    // A command that started others is found through several levels
    proc(100, "bash", 1, 100, 100, TTY1, 410, [410]);
    proc(410, "make", 100, 410, 100, TTY1, 410, [401]);
    proc(401, "gcc", 410, 410, 100, TTY1, 410, [403]);
    proc(403, "cc1", 401, 410, 100, TTY1, 410);
    assert(activeProcesses(source.snapshot([100]))[100].name == "cc1");

    // A child started by another thread of a process is found
    proc(410, "make", 100, 410, 100, TTY1, 410, []);
    thread(410, 412, [401]);
    assert(activeProcesses(source.snapshot([100]))[100].name == "cc1");

    // A background job while the shell is idle
    proc(100, "bash", 1, 100, 100, TTY1, 100, [600]);
    proc(600, "sleep", 100, 600, 100, TTY1, 100);
    assert(activeProcesses(source.snapshot([100]))[100].name == "bash");

    // A shell without job control runs commands in its own process group, so
    // the command is in the foreground along with the shell
    proc(1, "systemd", 0, 1, 1, 0, -1, [100, 110, 120, 500]);
    proc(120, "sh", 1, 120, 120, TTY1 + 2, 120, [121]);
    proc(121, "sleep", 120, 120, 120, TTY1 + 2, 120);
    assert(activeProcesses(source.snapshot([120]))[120].name == "sleep");

    // Children in their own session, i.e. a new terminal, and their descendants
    // aren't part of the terminal. A listed child that exited is skipped.
    proc(100, "bash", 1, 100, 100, TTY1, 100, [130, 999]);
    proc(130, "tilix", 100, 130, 130, 0, -1, [131]);
    proc(131, "bash", 130, 131, 131, TTY1 + 3, 131);
    source.reads = null;
    active = activeProcesses(source.snapshot([100]));
    assert(active[100].name == "bash" && active[100].pid == 100);
    assert(!source.reads.canFind(131));

    // Stats are read fresh, so a name changed by exec is seen straight away
    proc(100, "bash", 1, 100, 100, TTY1, 700, [700]);
    proc(700, "bash", 100, 700, 100, TTY1, 700);
    assert(activeProcesses(source.snapshot([100]))[100].name == "bash");
    proc(700, "vim", 100, 700, 100, TTY1, 700);
    assert(activeProcesses(source.snapshot([100]))[100].name == "vim");

    // A shell that exited gives nothing
    assert(source.snapshot([800]).length == 0);
    // A missing root is not an error
    assert(new ProcFsSource(buildPath(root, "missing")).snapshot([100]).length == 0);

    // Without the children files every process is read to find those in the session.
    // Remove the processes from the earlier commands first, they have exited.
    foreach (pid; [300, 301, 401, 403, 410]) {
        rmdirRecurse(buildPath(root, to!string(pid)));
    }
    foreach (entry; dirEntries(root, "children", SpanMode.depth).array) {
        std.file.remove(entry.name);
    }
    source.reads = null;
    active = activeProcesses(source.snapshot([100, 110, 120]));
    assert(active[100].name == "vim" && active[110].name == "top" && active[120].name == "sleep");
    assert(source.reads.canFind(500), "The fallback reads every process");
}

// Reading stats through the Flatpak toolbox output
unittest {
    string[][] calls;
    string output;
    string fakeRun(string[] args) {
        calls ~= args;
        return output;
    }

    FlatpakHostSource source = new FlatpakHostSource(["flatpak-spawn", "--host", "/app/bin/tilix-flatpak-toolbox", "list-sessions"], &fakeRun);

    // Nothing to watch, nothing is run
    assert(source.snapshot([]).length == 0);
    assert(calls.length == 0);

    output = "100 (bash) S 1 100 100 34816 300 0 0 0 0 0 0 0 0 0 20 0 1 0 7 0 0\n" ~
             "300 (vim) S 100 300 100 34816 300 0 0 0 0 0 0 0 0 0 20 0 1 0 9 0 0\n" ~
             "garbage\n" ~
             "301 (\xff\xfe) S 100 300 100 34816 300 0 0 0 0 0 0 0 0 0 20 0 1 0 9 0 0\n" ~
             "\n";
    ProcStat[] stats = source.snapshot([100, 110]);
    assert(calls == [["flatpak-spawn", "--host", "/app/bin/tilix-flatpak-toolbox", "list-sessions", "100", "110"]]);
    // The garbage line and the one that isn't valid UTF-8 are skipped
    assert(stats.map!(s => s.name).array == ["bash", "vim"]);
    assert(activeProcesses(stats)[100].name == "vim");
}

// Running commands with a time limit
unittest {
    import core.time : msecs;
    import std.datetime.stopwatch : AutoStart, StopWatch;
    import std.exception : assertThrown;

    assert(runWithTimeout(["sh", "-c", "printf 'one\\ntwo\\n'"], 5.seconds) == "one\ntwo\n");
    assert(runWithTimeout(["true"], 5.seconds) == "");
    // More output than a pipe holds is read while the command runs
    assert(runWithTimeout(["sh", "-c", "yes 0123456789 | head -n 100000"], 10.seconds).length == 1_100_000);
    // A failing or missing command throws
    assertThrown(runWithTimeout(["sh", "-c", "exit 3"], 5.seconds));
    assertThrown(runWithTimeout(["/nonexistent/command"], 5.seconds));
    // A command that takes too long is killed rather than waited for
    auto sw = StopWatch(AutoStart.yes);
    assertThrown(runWithTimeout(["sleep", "10"], 300.msecs));
    assert(sw.peek() < 5.seconds);
}

// The Flatpak toolbox finds the same processes as ProcFsSource. meson builds the
// toolbox and passes its path in TILIX_TOOLBOX when a C compiler is available.
unittest {
    import core.thread : Thread;
    import core.time : msecs;
    import std.process : environment, Pid, Redirect, pipeProcess, kill, wait;
    import std.range : walkLength;

    string toolbox = environment.get("TILIX_TOOLBOX");
    if (toolbox.length == 0) return;

    // Terminal sessions running a command, a pipeline, a shell without job control and
    // an idle shell, if script is available to create them
    Pid[] sessions;
    // script waits a moment for its shell after being signalled, so signal them all
    // before waiting for any
    scope(exit) {
        foreach (pid; sessions) kill(pid);
        foreach (pid; sessions) wait(pid);
    }
    if (exists("/usr/bin/script")) {
        foreach (command; ["sleep 30", "sleep 30 | cat", "sh -c 'sh -c \"sleep 30\"'", "bash --norc"]) {
            sessions ~= pipeProcess(["/usr/bin/script", "-qfc", command, "/dev/null"], Redirect.all).pid;
        }
        Thread.sleep(500.msecs);
    }

    // Shells as Tilix would watch them: session leaders with a terminal
    pid_t[] shells;
    foreach (entry; dirEntries("/proc", SpanMode.shallow)) {
        if (!baseName(entry.name).isNumeric) continue;
        try {
            auto stat = parseStat(readText(buildPath(entry.name, "stat")));
            if (!stat.isNull && stat.get.ttyNr > 0 && stat.get.session == stat.get.pid) shells ~= stat.get.pid;
        } catch (Exception e) {}
    }

    string[string] describe(ProcStat[pid_t] active) {
        string[string] result;
        foreach (shell, stat; active) result[to!string(shell)] = stat.name ~ "/" ~ to!string(stat.pid);
        return result;
    }

    ProcFsSource proc = new ProcFsSource();
    FlatpakHostSource host = new FlatpakHostSource([toolbox, "list-sessions"], (string[] args) => runWithTimeout(args, 5.seconds));
    // Processes can change between the two reads, so allow a few attempts
    string[string] expected, actual;
    foreach (attempt; 0 .. 5) {
        expected = describe(activeProcesses(proc.snapshot(shells)));
        actual = describe(activeProcesses(host.snapshot(shells)));
        if (expected == actual) break;
        Thread.sleep(100.msecs);
    }
    assert(expected == actual, format("ProcFsSource %s, toolbox %s", expected, actual));
    if (sessions.length > 0) {
        // The sessions created above were found
        assert(expected.byValue.filter!(v => v.startsWith("sleep/")).walkLength >= 2, format("%s", expected));
    }
}
