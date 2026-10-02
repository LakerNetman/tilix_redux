# Manual test: Flatpak host commands

When Tilix runs as a Flatpak, it can't see host processes directly. Instead it asks the host to run
`tilix-flatpak-toolbox` over D-Bus (`org.freedesktop.Flatpak.Development.HostCommand`). This happens:

- every time a terminal starts, to look up your login shell (`get-passwd`)
- every time a terminal or window closes, to check whether a process is still running (`get-child-pid`)
- when a process name is shown in a title (`get-proc-stat`)

This test checks the fixes in `sendHostCommand` and `captureHostToolboxCommand` in
`source/gx/tilix/terminal/terminal.d`:

| Fix | What went wrong before |
|---|---|
| Output pipe closed properly | 2 file descriptors leaked per host command |
| Write end closed after the command is sent | Reading the output could block the UI forever |
| D-Bus connection released when the command finishes | One session-bus connection leaked per host command |
| Exit signals matched by process ID | A command could receive another command's exit status |

None of this can run in the automated tests, because it needs a real Flatpak sandbox.

## Setup

These steps need `flatpak` and `flatpak-builder`, plus network access for the runtimes and sources.

1. Generate a manifest that builds this checkout with GtkD 3.11. The output folder must be outside
   the source tree:

   ```bash
   tests/manual/make-flatpak-manifest.sh ~/tilix-flatpak
   ```

2. Install the runtime and SDK the manifest names:

   ```bash
   flatpak install --user flathub org.gnome.Platform//3.34 org.gnome.Sdk//3.34 org.freedesktop.Sdk.Extension.ldc//19.08 org.freedesktop.Sdk.Extension.dmd//19.08
   ```

   > The manifest in `experimental/flatpak` is old. GNOME 3.34 and the 19.08 SDK extensions are
   > end-of-life. If they're no longer available, change `runtime-version` in the generated
   > manifest to a current GNOME runtime and install the SDK extensions for the matching
   > freedesktop branch. The bundled VTE 0.53 module and its patches may then need updating too.
   > That's a separate piece of work from this test.

3. Build and install:

   ```bash
   flatpak-builder --user --install --force-clean ~/tilix-flatpak/build ~/tilix-flatpak/com.gexperts.Tilix.yaml
   ```

4. Start it from a normal (non-Tilix) terminal and leave one window open:

   ```bash
   flatpak run com.gexperts.Tilix
   ```

**Optional control run:** repeat test 1 with a build of the code from before the fixes. Build the
original release the same way, with the same GtkD change. It should report FAIL. That shows the
test can detect the leak on your system.

## Test 1: no descriptor leaks (pipes, D-Bus connections)

From a terminal that is **not** inside Tilix:

```bash
tests/manual/flatpak-host-monitor.sh cycle 10
```

The script opens 10 new sessions (`--action=app-new-session`). Each one looks up your shell on the
host. When it asks, close those 10 sessions (type `exit`, or use the close button), leave the
original one open, and press Enter.

- **Pass:** `PASS: no descriptors leaked`. The pipe and socket counts are back to the "Before" values, give or take one.
- **Fail:** pipes or sockets grew by 10 or more. Before the fix, each cycle leaked at least 4 pipe
  file descriptors and 2 D-Bus sockets.
- If it prints `CHECK`, run it again with `cycle 30`. A real leak grows with N. One-off caches don't.

## Test 2: the login shell is found on the host

In a new Tilix terminal:

```bash
echo "$SHELL"; ps -o comm= -p $$
```

- **Pass:** both show your host login shell, the one in `getent passwd $USER`, such as `bash` or `zsh`.
- **Fail:** `/bin/sh`, a shell from the sandbox, or a terminal that never shows a prompt.

## Test 3: close prompts use the right process

1. In one terminal run `sleep 600`, then close that terminal.
   **Pass:** Tilix asks for confirmation because a process is running.
2. In a terminal with only an idle shell, close it.
   **Pass:** it closes without a prompt.
3. Open four terminals in one session (`Ctrl+Alt+R` / `Ctrl+Alt+D`). Run `sleep 600` in two of
   them and leave two idle. Close the whole session.
   **Pass:** the prompt lists exactly the two terminals running `sleep`.

These checks exercise `get-child-pid`, and the exit status now being matched to the right command.

## Test 4: several host commands at once

1. Open six terminals in quick succession (`Ctrl+Shift+T` six times, as fast as possible).
2. In each one run a different command: `top`, `sleep 600`, `less /etc/passwd`, `vi`, `man ls`,
   and leave one idle.
3. Close the window.
   **Pass:** the prompt lists `top`, `sleep`, `less`, `vi` and `man`, each once, and not the idle
   terminal. Getting each name takes a `get-child-pid` and a `get-proc-stat` host command per
   terminal.
4. Cancel, then close and reopen terminals quickly several times, running commands in some of
   them before closing.

- **Pass:** every new terminal gets a working prompt, close prompts name the right commands, and
  nothing freezes.
- **Fail:** a terminal without a prompt, a missing or wrong name in a close prompt, or the window
  stops responding. Before the fix, an exit signal from one command could be taken for another
  command's.

> `${process}` in terminal titles comes from the process monitor, not from these host commands.
> Test 6 covers it.

## Test 5: no UI freeze

Open 20 terminals, then close them one after another as quickly as you can.

- **Pass:** the window stays responsive the whole time.
- **Fail:** a freeze longer than a second. Record which action caused it, and run
  `flatpak run --command=sh com.gexperts.Tilix -c 'G_MESSAGES_DEBUG=all tilix'` to capture the log.

## Test 6: process names in titles

`${process}` titles come from the process monitor. In a Flatpak it runs
`flatpak-spawn --host <app>/bin/tilix-flatpak-toolbox list-sessions <pids>` every 300 ms, because
the sandbox's own `/proc` can't see the shells, which run on the host.

1. Turn on process monitoring, which has no Preferences option:

   ```bash
   flatpak run --command=gsettings com.gexperts.Tilix set com.gexperts.Tilix.Settings process-monitor true
   ```

2. Restart Tilix. In Preferences → Profile → General, set the terminal title to `${process}`.
3. Open three terminals:
   - in the first, run `top`, quit it, then run `sleep 600 | cat`
   - in the second, run `sh -c 'sleep 600'`
   - leave the third idle
4. **Pass:** within a second each title shows its command: `top`, then the shell's name after
   quitting, then `cat`, then `sleep` in the second, and the shell's name in the idle one.
   Typing `exit` in a terminal closes it without the monitor or Tilix stalling.
5. **Fail:** titles stay at the shell's name, show the wrong command, or lag by more than a
   couple of seconds.

   To see what the monitor sees, run the toolbox by hand. The shell pids are looked up on the
   host, since the sandbox can't see them, and passed in:

   ```bash
   flatpak run --command=sh com.gexperts.Tilix -c 'flatpak-spawn --host "$(sed -n "s/^app-path=//p" /.flatpak-info)/bin/tilix-flatpak-toolbox" list-sessions "$@"' sh $(pgrep -x bash)
   ```

   It should print one `stat` line per shell and per process running in it. If `flatpak-spawn`
   is missing from the runtime, monitoring logs a warning on every scan and titles stay at the
   shell's name.

## Recording results

| Test | Result | Notes (counts, what happened) |
|---|---|---|
| 1. Descriptor leaks | | Before / After / Change |
| 2. Host login shell | | |
| 3. Close prompts | | |
| 4. Concurrent host commands | | |
| 5. No UI freeze | | |
| 6. Process names in titles | | |
| Control run (optional) | | Should FAIL on the old code |
