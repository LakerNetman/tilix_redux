# Proposal: refactor process detection

Status: all steps of the migration plan, 0–5, are done. Step 5 still needs checking in a real
Flatpak (test 6 in `tests/manual/flatpak-host-commands.md`). It covers
`source/gx/tilix/terminal/activeprocess.d` and `source/gx/tilix/terminal/monitor.d`.

## What the code did before the refactor

This describes the code before steps 0–5. When the hidden `process-monitor` setting is on, Tilix shows the command running in each
terminal (the `${process}` title variable):

1. `ProcessMonitor` starts a thread that calls `getActiveProcessList()` every 300 ms.
2. `Process.updateMap()` lists **every** process in `/proc`. It reads `/proc/<pid>/stat` for each
   new pid and caches a `Process` per pid in a static map. For every cached process with a
   terminal, it reads `stat` again to check whether it's in the foreground.
3. Foreground processes are grouped by session ID, which is the shell's pid. Each group's
   "active" process is the last one with no foreground children.
4. A GTK timeout on the main thread emits `onChildProcess` for changes. Terminals update their
   title from it.

## Problems

| # | Problem | Effect |
|---|---|---|
| 1 | **The locks don't lock.** `monitor.d` uses four bare `synchronized { }` blocks. In D, each bare `synchronized` statement gets its *own* mutex, so the monitor thread iterating `processes` and the UI thread adding or removing entries (`addProcess`/`removeProcess`) don't exclude each other. | A data race on an associative array. Opening or closing terminals while the monitor scans could corrupt the map or crash. **Fixed in step 0** with one shared lock. **Step 4 removed the shared state and the lock altogether.** |
| 2 | **Stale cached data.** A `Process` is parsed once and cached by pid. After `fork` and before `exec`, a child has the shell's name. If the scan catches it in that window, the name stays wrong for the life of the process. Pid reuse has the same effect. | Titles show `bash` instead of `vim` until the command exits. **Fixed in steps 2–3:** there is no cache any more, every scan reads fresh stats, and a change is detected by pid *and* start time, so a pid reused by a new command is noticed. |
| 3 | **It scans the whole system.** Every 300 ms it lists all of `/proc` and re-reads `stat` for every process with a terminal, not just Tilix's. | Constant background I/O that grows with the number of processes on the machine, including other terminal apps. **Fixed in step 3:** only the watched shells and their descendants are read. |
| 4 | **The scan runs inside the lock.** All that I/O happens inside `synchronized`, which would block the UI thread's `fireEvents` if the locks worked. | Fixing #1 alone would add UI stalls. **Fixed in step 0.** |
| 5 | **It doesn't work in Flatpak.** Shells run on the host through `HostCommand`, but the monitor reads the sandbox's `/proc`, which can't see host processes. That's the `TODO: be correct for flatpak sandbox` in `terminal.d`. | `${process}` never works in the Flatpak. **Fixed in step 5**, but not yet checked in a real Flatpak. |
| 6 | **A failure stops monitoring.** An exception in the spawned thread, such as a `to!long` on unexpected `stat` content, ends the thread and nothing restarts it. | Monitoring stops for the rest of the session. **Fixed in step 2:** each scan is wrapped in `try`/`catch`. |
| 7 | **It can't be tested.** It reads the real `/proc` into static global state from another thread. | This is why it was left out of the new unit tests. **Fixed in steps 1–2:** the logic is pure functions, and the monitor takes a `ProcessSource` that tests can fake. |
| 8 | **Event types are unused.** `MonitorEventType` has `CHANGED` and `FINISHED`, but only `STARTED` is ever emitted. When a command exits, the idle shell becomes the active process and is reported as `STARTED`. | Titles are correct, but handlers can't tell a command finishing from one starting. **Fixed in step 4:** `STARTED`, `CHANGED` and `FINISHED` are all emitted. |

## Proposed design

### 1. A pure core that can be tested (done in step 1)

As implemented in `activeprocess.d`:

```d
struct ProcStat {
    pid_t pid;
    string name;
    pid_t ppid, pgrp, session;
    long ttyNr;
    pid_t tpgid;
    ulong startTime;   // field 22, identifies a process instance even if the pid is reused
    @property bool isForeground() const;
}

/// Parses the contents of /proc/<pid>/stat, handles names containing ')' and spaces
Nullable!ProcStat parseStat(string content);

/// Returns the active process of each session, keyed by the shell's pid
ProcStat[pid_t] activeProcesses(const ProcStat[] stats);

/// Compares the active process last seen for each watched shell with the current ones
ActiveProcessChange[] diffActiveProcesses(const pid_t[pid_t] lastSeen, const ProcStat[pid_t] active);
```

These functions have no I/O and no global state. The unit tests cover:
- names like `a) (b c`, and malformed or truncated content
- an idle shell, a running command, background jobs, and processes without a terminal
- pipelines (`cat | less`) and nested commands (`make → gcc → sh → cc1`), including a parent
  with a higher pid than its children after pid wraparound
- several terminals at once, and unsorted input

Step 3 added tests for pid reuse detected through `startTime`. Zombies aren't tested: they keep
their stat until reaped and are normally reaped by the shell straight away.

### 2. A pluggable process source (done in steps 2 and 5)

```d
interface ProcessSource {
    /// Stats for the processes in the given sessions
    ProcStat[] snapshot(const pid_t[] shells);
}
```

- **`ProcFsSource(string root = "/proc")`** is the native case. Tests point `root` at a temp
  folder holding fake `stat` and `children` files. Since step 3 it reads only the watched shells
  and their descendants, see below.
- **`FlatpakHostSource`** (step 5) runs a new toolbox subcommand on the host,
  `tilix-flatpak-toolbox list-sessions <pid>...`. It prints the `stat` line of each shell and of
  its descendants in **one** host command per scan, found the same way as `ProcFsSource`: every
  thread's `children` file, skipping other sessions, and falling back to the whole session
  without `children` files. Calling `get-proc-stat` per process instead would mean dozens of
  round trips every 300 ms. This fixes problem 5.

  It runs through **`flatpak-spawn --host`**, not Tilix's own `HostCommand` D-Bus code as first
  planned. That code works on the UI thread and spins the main loop while it waits for the
  command, which can't be done from the monitor thread. `flatpak-spawn` is a plain blocking call.
  `runWithTimeout` reads the output as it arrives and kills the command after 2 seconds, so a
  stuck host command can't hang monitoring. The monitor uses this source when Tilix runs as a
  Flatpak (`/.flatpak-info` exists), and `ProcFsSource` otherwise.
- **`FakeSource`** is a test double for the monitor itself. The monitor's scan loop body is now
  `scanProcesses(ProcessSource)`, which the unit tests drive with one.

### 3. Read only what's needed (done in step 3)

A terminal's active process is in its foreground process group, so there's no need to scan all
of `/proc`. For each watched shell, `ProcFsSource` now:
- reads `/proc/<shell>/stat`, skipping shells without a terminal
- walks the shell's descendants through `/proc/<pid>/task/<tid>/children`, reading every thread's
  file so children started by any thread are found
- skips descendants in another session, such as a new terminal started from the shell, along
  with their own descendants
- falls back to reading every process in `/proc` for that shell on kernels without the children
  files (`CONFIG_PROC_CHILDREN`, which mainstream distributions enable)

The walk happens even when the shell itself is in the foreground. A shell without job control,
such as `sh -c '…'`, runs commands in its own process group, so they're in the foreground along
with it. A first draft that skipped the walk there would have reported `sh` instead of the
command.

This differs from the design here in two ways:
- **There is no cache.** Reading a handful of files per terminal is cheap, so every scan reads
  fresh stats, which removes stale data completely.
- **`startTime` is used when spotting changes**, by `diffActiveProcesses`, with the monitor
  remembering the start time of each terminal's active process. Keying a cache on it isn't
  needed.

**Known difference:** a process in the session whose parent exited is re-parented away from the
shell, so the walk doesn't find it, while the old full scan did. That's rare for the foreground
job.

**Measured on a desktop with 358 processes**, with test terminals running a command, a pipeline,
a shell without job control, an idle shell and a background job: step 2 and step 3 gave the same
answers in 20 out of 20 scans. Step 3 read 15 process stats instead of looking at all 358, and a
scan took 1.4 ms instead of 2.3 ms.

Still possible later: natively, `tcgetpgrp(pty fd)` gives the foreground process group without
touching `/proc`, as gnome-terminal and VTE do, but it needs the pty, which the monitor thread
doesn't have.

### 4. Pass messages instead of sharing state (done in step 4)

- **The monitor thread owns its state** (`MonitorState`): the shells it watches and the last
  result it sent. The UI thread changes the list with `Watch(gpid)` and `Unwatch(gpid)`
  messages, and ends the thread with `Stop()`.
- **Each scan sends results only if something changed**, as an `ActiveProcesses` message
  holding an immutable array of the active `ProcStat`s. A newly watched shell always triggers a
  send, because a shell unwatched and watched again between scans gives a result identical to
  the last one sent, while the UI thread has reset that shell.
- **The UI thread keeps the active process last seen per shell.** Its existing 300 ms timeout
  takes the latest result from its message queue, ignoring older ones, and works out the events
  with `monitorEvents`. It emits them only after working them all out, so handlers can add or
  remove processes safely.
- **Each start of the monitor thread gets a new generation number**, carried in its results.
  Results from a thread that was stopped are ignored, and `stop()` discards any that are still
  queued.
- **The event types now mean something:**
  - `STARTED`: the first active process seen for a shell, or a command starting while the shell
    was idle
  - `CHANGED`: one command replaced by another, including a new command reusing the previous
    one's pid
  - `FINISHED`: the shell is active again

  Terminals only use the name, so titles behave as before.

With no shared mutable state, the `shared` map, `ProcessStatus` and `processesLock` are gone,
and so are problems 1 and 4.

### 5. Recover from failures (done in step 2)

Each scan is wrapped in `try`/`catch (Exception)`, logged, and monitoring carries on with the next
tick. That fixes problem 6.

## Migration plan

Each step can ship on its own and keeps today's behaviour until the last one.

| Step | Change | Risk | Tests |
|---|---|---|---|
| 0 | **Done.** All four blocks in `monitor.d` now use `synchronized (processesLock)`, one shared lock. The `/proc` scan runs outside the lock, so the UI thread doesn't wait on it (problem 4). `fireEvents` collects events under the lock and sends them after releasing it, so handlers can safely add or remove processes. | Low | Unit test for handlers removing processes during `fireEvents`; the race itself is covered by review |
| 1 | **Done.** Added `ProcStat`, `parseStat`, `activeProcesses` and `diffActiveProcesses`, replacing the `Process` class and its static maps. | Low | Fixture-based unit tests. On this machine's live `/proc`, the old and new code gave identical results in 40 scans, including a running command, a pipeline and nested commands |
| 2 | **Done.** Added `ProcessSource` and `ProcFsSource` with a configurable root, plus `scanProcesses(ProcessSource)` in the monitor, with each scan inside `try`/`catch`. | Low | Fake `/proc` in a temp folder, and `FakeSource`-driven monitor tests |
| 3 | **Done.** Read only the watched shells and their descendants through the `children` files, with a fallback to a full scan, no cache, and changes detected by pid and start time. | Medium: pipelines and job control need care | Fake `/proc` covering pipelines, nested commands, children of other threads, background jobs, `sh -c`, other sessions, exited children, the fallback and pid reuse, plus a check that an idle terminal reads only its shell. Compared with step 2 on a live system |
| 4 | **Done.** Message passing between the threads, with no shared state or locks, generation numbers for stale results, and `STARTED`/`CHANGED`/`FINISHED` events. | Medium | Pure tests for the event types and for when the monitor thread sends; tests of the UI side with injected messages (stale and superseded results, handlers removing processes); and a test with a real monitor thread against a fake `/proc`, passing 30 out of 30 runs, 5 of them with every CPU core busy |
| 5 | **Done.** Added the `list-sessions` toolbox subcommand, `FlatpakHostSource` run through `flatpak-spawn --host`, and `runWithTimeout`. | Medium: needs the Flatpak manual test | Unit tests for parsing the output, the command line and `runWithTimeout`, covering large output, failures and timeouts. meson builds the toolbox when a C compiler is available, and a test checks it finds the same active processes as `ProcFsSource` on the live system, with extra test terminal sessions. Not yet checked in a real Flatpak; see test 6 in `tests/manual/flatpak-host-commands.md` |

A rough size: step 0 is a few lines. Steps 1–2 are about a day each, including tests. Steps 3–5
are about 2–3 days together, plus manual Flatpak testing.

## Open questions

- Should `process-monitor` get a Preferences option? Today it can only be turned on with
  `gsettings`.
- Should `${process}` fall back to the pty's `tcgetpgrp` when the monitor is off, so titles work
  without the background thread? That would be cheap enough to run on the UI thread.
