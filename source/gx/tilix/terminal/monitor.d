/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */
module gx.tilix.terminal.monitor;

import core.sys.posix.unistd;
import core.thread;

import std.concurrency;
import std.datetime;
import std.experimental.logger;
import std.parallelism;

import vtec.vtetypes;

import gx.i18n.l10n;
import gx.gtk.threads;

import gx.tilix.common;
import gx.tilix.constants;
import gx.tilix.terminal.activeprocess;

import gx.tilix.application;

enum MonitorEventType {
    NONE,
    STARTED,
    CHANGED,
    FINISHED
};

/**
 * Class that monitors processes to see if new child processes have been
 * started or finished and raises an event if detected. This class uses
 * a separate thread to monitor the processes and a timeoutDelegate to
 * trigger the actual events to the terminals.
 */
class ProcessMonitor {
private:
    Tid tid;
    bool running = false;

    bool fireEvents() {
        struct Event {
            MonitorEventType eventType;
            GPid gpid;
            pid_t activePid;
            string activeName;
        }

        // Collect the events under the lock but emit them after releasing it, handlers
        // may add or remove processes which would otherwise change processes while it
        // is being iterated
        Event[] events;
        synchronized (processesLock) {
            foreach(process; processes) {
                if (process.eventType != MonitorEventType.NONE) {
                    events ~= Event(process.eventType, process.gpid, process.activePid, process.activeName);
                    process.eventType = MonitorEventType.NONE;
                }
            }
        }
        foreach(event; events) {
            onChildProcess.emit(event.eventType, event.gpid, event.activePid, event.activeName);
        }
        return running;
    }

    static ProcessMonitor _instance;

public:
    this() {

    }

    ~this() {
        stop();
    }

    void start() {
        running = true;
        tid = spawn(&monitorProcesses, SLEEP_CONSTANT_MS, thisTid);
        threadsAddTimeoutDelegate(SLEEP_CONSTANT_MS, &fireEvents);
        trace("Started process monitoring");
    }

    void stop() {
        // Nothing to do if not running, this is also called from the destructor where
        // logging or allocating while the garbage collector finalizes objects is invalid
        if (!running) return;
        tid.send(true);
        running = false;
        trace("Stopped process monitoring");
    }

    /**
     * Add a process for monitoring
     */
    void addProcess(GPid gpid) {
        synchronized (processesLock) {
            if (gpid !in processes) {
                shared ProcessStatus status = new shared(ProcessStatus)(gpid);
                processes[gpid] = status;
            }
        }
        if (!running) start();
    }

    /**
     * Remove a process for monitoring
     */
    void removeProcess(GPid gpid) {
        synchronized (processesLock) {
            if (gpid in processes) {
                processes.remove(gpid);
                if (running && processes.length == 0) stop();
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

/**
 * List of processes being monitored.
 */
shared ProcessStatus[GPid] processes;

/**
 * Guards processes and the ProcessStatus objects in it. It is shared by every
 * block that uses them: a synchronized statement without an object gets its
 * own mutex per statement, so separate blocks would not exclude each other.
 */
__gshared Object processesLock = new Object();

void monitorProcesses(int sleep, Tid tid) {
    // Only used by this thread
    ProcessSource source = new ProcFsSource();
    bool abort = false;
    while (!abort) {
        try {
            scanProcesses(source);
        } catch (Exception e) {
            // Keep monitoring, an uncaught exception would end this thread for good
            warning(e);
        }
        receiveTimeout(dur!("msecs")( sleep ),
                (bool msg) {
                    if (msg) abort = true;
                }
        );
    }
}

/**
 * Finds the active process of each monitored shell and marks those where it
 * changed so fireEvents raises an event for them.
 */
void scanProcesses(ProcessSource source) {
    pid_t[] shells;
    synchronized (processesLock) {
        foreach (gpid, process; processes) shells ~= gpid;
    }
    // Reading the processes is slow so it is done without holding the lock
    ProcStat[pid_t] active = activeProcesses(source.snapshot(shells));
    synchronized (processesLock) {
        pid_t[pid_t] lastSeen;
        foreach (process; processes) lastSeen[process.gpid] = process.activePid;
        foreach (change; diffActiveProcesses(lastSeen, active)) {
            // The process may have been removed while scanning
            auto process = change.shell in processes;
            if (process is null) continue;
            (*process).activeName = change.name;
            (*process).activePid = change.pid;
            (*process).eventType = MonitorEventType.STARTED;
        }
    }
}

/**
 * Status of a single process
 */
shared class ProcessStatus {
    GPid gpid;
    pid_t activePid = -1;
    string activeName = "";
    MonitorEventType eventType = MonitorEventType.NONE;

    this(GPid gpid) {
        this.gpid = gpid;
    }
}

// Event handlers can remove processes while events are being fired, i.e. when a
// terminal closes, and every pending event is still delivered exactly once
unittest {
    import std.algorithm : sort;

    // std.signals needs a class method as the slot
    class Handler {
        ProcessMonitor monitor;
        GPid[] seen;

        void onChildProcess(MonitorEventType eventType, GPid gpid, pid_t activePid, string activeName) {
            seen ~= gpid;
            // The first handler removes every other process, all with pending events,
            // whichever order the processes are iterated in
            if (seen.length == 1) {
                foreach (GPid other; [101, 102, 103]) {
                    if (other != gpid) monitor.removeProcess(other);
                }
            }
        }
    }

    ProcessMonitor monitor = new ProcessMonitor();
    // Add directly rather than with addProcess so the monitor thread isn't started
    synchronized (processesLock) {
        foreach (GPid gpid; [101, 102, 103]) {
            shared ProcessStatus status = new shared(ProcessStatus)(gpid);
            status.eventType = MonitorEventType.STARTED;
            processes[gpid] = status;
        }
    }
    scope(exit) synchronized (processesLock) { processes = null; }

    Handler handler = new Handler();
    handler.monitor = monitor;
    monitor.onChildProcess.connect(&handler.onChildProcess);

    monitor.fireEvents();
    GPid first = handler.seen[0];
    assert(handler.seen.sort.release == [101, 102, 103]);
    synchronized (processesLock) {
        assert(processes.length == 1 && first in processes);
    }

    // Events are only delivered once
    handler.seen.length = 0;
    monitor.fireEvents();
    assert(handler.seen.length == 0);
}

// Scanning marks the processes whose active process changed
unittest {
    class FakeSource: ProcessSource {
        ProcStat[] stats;
        ProcStat[] snapshot(const pid_t[] shells) {
            return stats;
        }
    }

    ProcStat proc(pid_t pid, string name, pid_t session, pid_t tpgid) {
        return ProcStat(pid, name, session, pid, session, 34816, tpgid, 0);
    }

    MonitorEventType[GPid] events() {
        MonitorEventType[GPid] result;
        synchronized (processesLock) {
            foreach (gpid, process; processes) {
                result[gpid] = process.eventType;
                process.eventType = MonitorEventType.NONE;
            }
        }
        return result;
    }

    string activeName(GPid gpid) {
        synchronized (processesLock) {
            return processes[gpid].activeName;
        }
    }

    synchronized (processesLock) {
        foreach (GPid gpid; [100, 110]) processes[gpid] = new shared(ProcessStatus)(gpid);
    }
    scope(exit) synchronized (processesLock) { processes = null; }

    FakeSource source = new FakeSource();
    source.stats = [proc(100, "bash", 100, 100), proc(110, "zsh", 110, 201), proc(201, "top", 110, 201)];

    // First scan reports every shell
    scanProcesses(source);
    assert(events() == [100: MonitorEventType.STARTED, 110: MonitorEventType.STARTED]);
    assert(activeName(100) == "bash" && activeName(110) == "top");

    // Nothing changed
    scanProcesses(source);
    assert(events() == [100: MonitorEventType.NONE, 110: MonitorEventType.NONE]);

    // A command starts in the first terminal only
    source.stats = [proc(100, "bash", 100, 300), proc(300, "vim", 100, 300),
                    proc(110, "zsh", 110, 201), proc(201, "top", 110, 201)];
    scanProcesses(source);
    assert(events() == [100: MonitorEventType.STARTED, 110: MonitorEventType.NONE]);
    assert(activeName(100) == "vim");

    // No processes found at all, i.e. they exited, leaves the last state alone
    source.stats = [];
    scanProcesses(source);
    assert(events() == [100: MonitorEventType.NONE, 110: MonitorEventType.NONE]);
    assert(activeName(100) == "vim");
}
