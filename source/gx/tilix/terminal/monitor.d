/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */
module gx.tilix.terminal.monitor;

import core.sys.posix.unistd;

import std.algorithm;
import std.array;
import std.concurrency;
import std.datetime;
import std.experimental.logger;
import std.typecons : Nullable;

import vtec.vtetypes;

import gx.i18n.l10n;
import gx.gtk.threads;

import gx.tilix.common;
import gx.tilix.constants;
import gx.tilix.terminal.activeprocess;

import gx.tilix.application;

enum MonitorEventType {
    NONE,
    /// A command started in an idle shell, or the first active process seen for a shell
    STARTED,
    /// A command was replaced by another one
    CHANGED,
    /// The command finished and the shell is active again
    FINISHED
};

/**
 * An event for a terminal whose active process changed
 */
struct MonitorEvent {
    MonitorEventType eventType;
    /// The pid of the terminal's shell
    GPid gpid;
    pid_t activePid;
    string activeName;
}

/**
 * Works out the events for changes in the active processes of the watched shells
 * and updates lastSeen to the current active processes.
 *
 * Params:
 *  lastSeen = The active process last seen keyed by shell pid, ProcessId.init if none
 *             yet. Only these shells are reported.
 *  active   = The current active processes keyed by shell pid, see activeProcesses
 */
MonitorEvent[] monitorEvents(ref ProcessId[pid_t] lastSeen, const ProcStat[pid_t] active) {
    MonitorEvent[] result;
    foreach (change; diffActiveProcesses(lastSeen, active)) {
        ProcessId last = lastSeen[change.shell];
        bool wasCommand = last.pid != -1 && last.pid != change.shell;
        bool isCommand = change.pid != change.shell;
        MonitorEventType eventType;
        if (isCommand) {
            eventType = wasCommand ? MonitorEventType.CHANGED : MonitorEventType.STARTED;
        } else {
            eventType = wasCommand ? MonitorEventType.FINISHED : MonitorEventType.STARTED;
        }
        result ~= MonitorEvent(eventType, change.shell, change.pid, change.name);
        lastSeen[change.shell] = ProcessId(change.pid, change.startTime);
    }
    return result;
}

/**
 * Class that monitors processes to see if new child processes have been
 * started or finished and raises an event if detected.
 *
 * A separate thread reads the processes. It owns the list of shells being watched,
 * which this class updates by sending it Watch and Unwatch messages, and it sends
 * the active process of each shell back in an ActiveProcesses message when they
 * change. A timeout on the UI thread receives the results and raises the events,
 * so no state is shared between the threads.
 */
class ProcessMonitor {
private:
    Tid tid;
    bool running = false;
    /// Incremented for every monitor thread started, results from an earlier one are ignored
    uint generation;
    /// The proc file system, tests use a directory with the same layout
    string root = "/proc";
    /// The active process last seen for each watched shell, only used by the UI thread
    ProcessId[pid_t] watched;

    bool fireEvents() {
        // Only the latest result matters, earlier ones are superseded by it
        Nullable!(immutable(ProcStat)[]) latest;
        while (receiveTimeout(dur!("msecs")(0), (ActiveProcesses message) {
            if (message.generation == generation) latest = message.active;
        })) {}
        if (!latest.isNull) {
            ProcStat[pid_t] active;
            foreach (stat; latest.get) active[stat.session] = stat;
            // The events are worked out first, handlers may add or remove processes
            foreach (event; monitorEvents(watched, active)) {
                onChildProcess.emit(event.eventType, event.gpid, event.activePid, event.activeName);
            }
        }
        return running;
    }

    static ProcessMonitor _instance;

    this(string root) {
        this.root = root;
    }

public:
    this() {

    }

    ~this() {
        stop();
    }

    void start() {
        running = true;
        generation++;
        tid = spawn(&monitorProcesses, SLEEP_CONSTANT_MS, thisTid, generation, root);
        foreach (gpid; watched.keys) {
            tid.send(Watch(gpid));
        }
        threadsAddTimeoutDelegate(SLEEP_CONSTANT_MS, &fireEvents);
        trace("Started process monitoring");
    }

    void stop() {
        // Nothing to do if not running, this is also called from the destructor where
        // logging or allocating while the garbage collector finalizes objects is invalid
        if (!running) return;
        tid.send(Stop());
        running = false;
        // Discard results that are still waiting, they would never be received otherwise
        while (receiveTimeout(dur!("msecs")(0), (ActiveProcesses message) {})) {}
        trace("Stopped process monitoring");
    }

    /**
     * Add a process for monitoring
     */
    void addProcess(GPid gpid) {
        if (gpid !in watched) {
            watched[gpid] = ProcessId.init;
            if (running) tid.send(Watch(gpid));
        }
        if (!running) start();
    }

    /**
     * Remove a process for monitoring
     */
    void removeProcess(GPid gpid) {
        if (gpid in watched) {
            watched.remove(gpid);
            if (running) {
                if (watched.length == 0) {
                    stop();
                } else {
                    tid.send(Unwatch(gpid));
                }
            }
        }
    }

    /**
     * When a process changes inform children
     */
    GenericEvent!(MonitorEventType, GPid, pid_t, string) onChildProcess;

    static @property ProcessMonitor instance() {
        if (!tilix.processMonitor) {
            warningf(_("Process monitoring is not enabled, this should never be called"));
        }
        if (_instance is null) {
            _instance = new ProcessMonitor();
        }
        return _instance;
    }
}

private:

/**
 * Constant used for sleep time between checks.
 */
enum SLEEP_CONSTANT_MS = 300;

/// Sent to the monitor thread to start watching a shell
struct Watch {
    GPid gpid;
}

/// Sent to the monitor thread to stop watching a shell
struct Unwatch {
    GPid gpid;
}

/// Sent to the monitor thread to end it
struct Stop {
}

/// Sent by the monitor thread, the active process of each watched shell
struct ActiveProcesses {
    uint generation;
    immutable(ProcStat)[] active;
}

/**
 * The state of the monitor thread, separate from the thread so it can be tested
 */
struct MonitorState {
    pid_t[] shells;
    immutable(ProcStat)[] lastSent;
    /// Set when a shell is watched, its state must be sent even if the result looks
    /// unchanged, i.e. a shell unwatched and watched again between scans
    bool newShell;

    void watch(GPid gpid) {
        if (!shells.canFind(gpid)) {
            shells ~= gpid;
            newShell = true;
        }
    }

    /// Nothing needs sending for this, the UI thread ignores shells it doesn't watch
    void unwatch(GPid gpid) {
        shells = shells.remove!(shell => shell == gpid);
    }

    /**
     * Finds the active process of each shell, returns them if they need to be sent,
     * that is when they changed since the last time or a shell was watched.
     */
    Nullable!(immutable(ProcStat)[]) scan(ProcessSource source) {
        Nullable!(immutable(ProcStat)[]) result;
        if (shells.length == 0) return result;
        ProcStat[] active = activeProcesses(source.snapshot(shells)).values;
        active.sort!((a, b) => a.session < b.session);
        immutable(ProcStat)[] current = active.idup;
        if (newShell || current != lastSent) {
            lastSent = current;
            newShell = false;
            result = current;
        }
        return result;
    }
}

void monitorProcesses(int sleep, Tid owner, uint generation, string root) {
    ProcessSource source = new ProcFsSource(root);
    MonitorState state;
    bool abort = false;

    void onWatch(Watch message) { state.watch(message.gpid); }
    void onUnwatch(Unwatch message) { state.unwatch(message.gpid); }
    void onStop(Stop message) { abort = true; }

    try {
        while (!abort) {
            try {
                auto active = state.scan(source);
                if (!active.isNull) owner.send(ActiveProcesses(generation, active.get));
            } catch (Exception e) {
                // Keep monitoring, an uncaught exception would end this thread for good
                warning(e);
            }
            // Wait for the next scan, handling every message that arrives meanwhile
            if (receiveTimeout(dur!("msecs")(sleep), &onWatch, &onUnwatch, &onStop)) {
                while (!abort && receiveTimeout(dur!("msecs")(0), &onWatch, &onUnwatch, &onStop)) {}
            }
        }
    } catch (OwnerTerminated e) {
        // Tilix is exiting
    }
}

// Event types for the changes in a terminal's active process
unittest {
    ProcStat proc(pid_t pid, string name, ulong startTime = 1) {
        ProcStat stat;
        stat.pid = pid;
        stat.name = name;
        stat.startTime = startTime;
        return stat;
    }

    ProcessId[pid_t] lastSeen = [100: ProcessId.init, 110: ProcessId.init];

    // First scan, an idle shell and a shell already running a command
    auto events = monitorEvents(lastSeen, [100: proc(100, "bash"), 110: proc(201, "top")]);
    events.sort!((a, b) => a.gpid < b.gpid);
    assert(events == [MonitorEvent(MonitorEventType.STARTED, 100, 100, "bash"),
                      MonitorEvent(MonitorEventType.STARTED, 110, 201, "top")]);
    assert(lastSeen == [100: ProcessId(100, 1), 110: ProcessId(201, 1)]);

    // Nothing changed
    assert(monitorEvents(lastSeen, [100: proc(100, "bash"), 110: proc(201, "top")]).length == 0);

    // A command starts in the idle shell
    assert(monitorEvents(lastSeen, [100: proc(300, "vim")]) == [MonitorEvent(MonitorEventType.STARTED, 100, 300, "vim")]);
    // It's replaced by another command, i.e. vim running a shell command
    assert(monitorEvents(lastSeen, [100: proc(301, "make")]) == [MonitorEvent(MonitorEventType.CHANGED, 100, 301, "make")]);
    // A new command that reuses the pid is a change too
    assert(monitorEvents(lastSeen, [100: proc(301, "less", 9)]) == [MonitorEvent(MonitorEventType.CHANGED, 100, 301, "less")]);
    // It finishes and the shell is active again
    assert(monitorEvents(lastSeen, [100: proc(100, "bash")]) == [MonitorEvent(MonitorEventType.FINISHED, 100, 100, "bash")]);
    assert(lastSeen[100] == ProcessId(100, 1));

    // Shells that aren't watched are ignored and missing shells are left alone
    assert(monitorEvents(lastSeen, [120: proc(120, "sh")]).length == 0);
    assert(120 !in lastSeen);
    assert(monitorEvents(lastSeen, null).length == 0);
}

// The monitor thread only sends results when they change
unittest {
    class FakeSource: ProcessSource {
        ProcStat[] stats;
        ProcStat[] snapshot(const pid_t[] shells) {
            return stats.filter!(s => shells.canFind(s.session)).array;
        }
    }

    ProcStat proc(pid_t pid, string name, pid_t session, pid_t tpgid) {
        return ProcStat(pid, name, session, pid, session, 34816, tpgid, 1);
    }

    FakeSource source = new FakeSource();
    source.stats = [proc(100, "bash", 100, 100), proc(110, "zsh", 110, 201), proc(201, "top", 110, 201)];
    MonitorState state;

    // Nothing is watched
    assert(state.scan(source).isNull);

    state.watch(100);
    auto sent = state.scan(source);
    assert(!sent.isNull && sent.get.length == 1 && sent.get[0].name == "bash");
    // Unchanged, so nothing is sent
    assert(state.scan(source).isNull);

    // Watching another shell sends straight away
    state.watch(110);
    state.watch(110);
    sent = state.scan(source);
    assert(sent.get.map!(s => s.name).array == ["bash", "top"]);

    // A change in a watched terminal is sent
    source.stats ~= [proc(300, "vim", 100, 300)];
    source.stats[0] = proc(100, "bash", 100, 300);
    sent = state.scan(source);
    assert(sent.get.map!(s => s.name).array == ["vim", "top"]);

    // Unwatching changes the result so the remaining shells are sent, unwatching
    // again changes nothing
    state.unwatch(100);
    sent = state.scan(source);
    assert(sent.get.map!(s => s.name).array == ["top"]);
    state.unwatch(100);
    assert(state.scan(source).isNull);

    // Unwatched and watched again between scans gives the same result as last time,
    // it's still sent since the UI thread has forgotten the shell
    state.unwatch(110);
    state.watch(110);
    sent = state.scan(source);
    assert(!sent.isNull && sent.get.map!(s => s.name).array == ["top"]);

    state.unwatch(110);
    assert(state.scan(source).isNull);
}

// Event handlers can add and remove processes while events are being fired, i.e. when a
// terminal closes, and every pending event is still delivered exactly once. Results from
// a monitor thread that has since been stopped are ignored.
unittest {
    // std.signals needs a class method as the slot
    class Handler {
        ProcessMonitor monitor;
        MonitorEvent[] seen;

        void onChildProcess(MonitorEventType eventType, GPid gpid, pid_t activePid, string activeName) {
            seen ~= MonitorEvent(eventType, gpid, activePid, activeName);
            // The first handler removes every other process, all with pending events
            if (seen.length == 1) {
                foreach (GPid other; [101, 102, 103]) {
                    if (other != gpid) monitor.removeProcess(other);
                }
            }
        }
    }

    ProcStat idle(pid_t pid) {
        return ProcStat(pid, "bash", 1, pid, pid, 34816, pid, 1);
    }

    // The monitor isn't started, results are sent directly to this thread instead
    ProcessMonitor monitor = new ProcessMonitor();
    monitor.watched = [101: ProcessId.init, 102: ProcessId.init, 103: ProcessId.init];
    Handler handler = new Handler();
    handler.monitor = monitor;
    monitor.onChildProcess.connect(&handler.onChildProcess);

    // From an earlier monitor thread, ignored
    thisTid.send(ActiveProcesses(monitor.generation + 1, [idle(101)].idup));
    monitor.fireEvents();
    assert(handler.seen.length == 0);

    // Only the latest result is used
    thisTid.send(ActiveProcesses(monitor.generation, [ProcStat(101, "old", 1, 101, 101, 34816, 101, 1)].idup));
    thisTid.send(ActiveProcesses(monitor.generation, [idle(101), idle(102), idle(103)].idup));
    monitor.fireEvents();
    assert(handler.seen.map!(e => e.gpid).array.sort.release == [101, 102, 103]);
    assert(handler.seen.all!(e => e.activeName == "bash" && e.eventType == MonitorEventType.STARTED));
    GPid first = handler.seen[0].gpid;
    assert(monitor.watched.keys == [first]);

    // Events are only delivered once
    handler.seen.length = 0;
    monitor.fireEvents();
    assert(handler.seen.length == 0);
}

// The monitor thread watching terminals in a fake proc file system
unittest {
    import core.thread : Thread;
    import core.time : msecs;
    import std.array : join;
    import std.conv : to;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.format : format;
    import std.path : buildPath;
    import std.process : thisProcessID;

    class Handler {
        MonitorEvent[] seen;
        void onChildProcess(MonitorEventType eventType, GPid gpid, pid_t activePid, string activeName) {
            seen ~= MonitorEvent(eventType, gpid, activePid, activeName);
        }
    }

    string root = buildPath(tempDir(), "tilix-monitor-test-" ~ to!string(thisProcessID()));
    mkdirRecurse(root);
    scope(exit) rmdirRecurse(root);

    void proc(pid_t pid, string name, pid_t ppid, pid_t pgrp, pid_t tpgid, pid_t[] children = null) {
        string dir = buildPath(root, to!string(pid));
        mkdirRecurse(buildPath(dir, "task", to!string(pid)));
        write(buildPath(dir, "stat"), format("%d (%s) S %d %d 100 34816 %d 0 0 0 0 0 0 0 0 0 20 0 1 0 1 0 0\n",
            pid, name, ppid, pgrp, tpgid));
        write(buildPath(dir, "task", to!string(pid), "children"), children.map!(c => to!string(c) ~ " ").join);
    }

    ProcessMonitor monitor = new ProcessMonitor(root);
    Handler handler = new Handler();
    monitor.onChildProcess.connect(&handler.onChildProcess);
    scope(exit) monitor.stop();

    // Waits for the monitor thread to report a change
    MonitorEvent waitForEvent() {
        foreach (i; 0 .. 100) {
            monitor.fireEvents();
            if (handler.seen.length > 0) {
                MonitorEvent event = handler.seen[0];
                handler.seen = handler.seen[1 .. $];
                return event;
            }
            Thread.sleep(30.msecs);
        }
        assert(false, "No event from the monitor thread");
    }

    proc(100, "bash", 1, 100, 100);
    monitor.addProcess(100);
    assert(monitor.running);
    assert(waitForEvent() == MonitorEvent(MonitorEventType.STARTED, 100, 100, "bash"));

    proc(100, "bash", 1, 100, 300, [300]);
    proc(300, "vim", 100, 300, 300);
    assert(waitForEvent() == MonitorEvent(MonitorEventType.STARTED, 100, 300, "vim"));

    proc(100, "bash", 1, 100, 301, [301]);
    proc(301, "make", 100, 301, 301);
    assert(waitForEvent() == MonitorEvent(MonitorEventType.CHANGED, 100, 301, "make"));

    proc(100, "bash", 1, 100, 100);
    assert(waitForEvent() == MonitorEvent(MonitorEventType.FINISHED, 100, 100, "bash"));

    // Removing the last process stops the thread and no further events arrive
    monitor.removeProcess(100);
    assert(!monitor.running);
    proc(100, "bash", 1, 100, 302, [302]);
    proc(302, "top", 100, 302, 302);
    Thread.sleep(400.msecs);
    monitor.fireEvents();
    assert(handler.seen.length == 0);

    // Starting again watches from scratch
    monitor.addProcess(100);
    assert(waitForEvent() == MonitorEvent(MonitorEventType.STARTED, 100, 302, "top"));
}
