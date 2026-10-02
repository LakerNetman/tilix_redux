# Manual checks: bugs found in the feature-request triage

Six of the seven fixes on the `triage-bug-fixes` branch change window, focus or menu behaviour,
which the unit tests can't exercise. Show File Browser's directory fallback has unit tests in
`source/gx/tilix/terminal/util.d`; the checks below cover the rest. Run them in a normal Tilix
build, not the Flatpak, unless a step says otherwise.

| # | Issue | Check | Pass |
|---|---|---|---|
| 1 | [#1270](https://github.com/gnunn1/tilix/issues/1270) | Start Tilix without shell integration (`bash --norc` as the profile's custom command), `cd /tmp`, then right-click → Show File Browser. | The file manager opens `/tmp`, with no GLib-CRITICAL errors in the terminal Tilix was started from. |
| 2 | [#1618](https://github.com/gnunn1/tilix/issues/1618) | Turn on "Hide window when focus is lost" for Quake mode, open the Quake window, then open Preferences from its menu. | The Quake window stays open while Preferences has focus. Clicking another application still hides it. |
| 3 | [#1517](https://github.com/gnunn1/tilix/issues/1517) | With a normal window and the Quake window both open, run `tilix -q --action=app-new-session -w /tmp` from another terminal. | A new tab opens in the Quake window, starting in `/tmp`, and the Quake window is shown. |
| 4 | [#2040](https://github.com/gnunn1/tilix/issues/2040) | Turn on Preferences → Global → "Save and restore window state". Resize the window, close it, start Tilix again. Repeat with the window maximized, then on a Wayland session. | The size comes back. A maximized window comes back maximized, and restores to the remembered size when unmaximized. Both work on Wayland. |
| 5 | [#1582](https://github.com/gnunn1/tilix/issues/1582) | With tabs shown, run `sleep 600` in a tab and click that tab's close button. | Tilix asks before closing, the same as Close Session from the menu. Cancelling keeps the tab. |
| 6 | [#2253](https://github.com/gnunn1/tilix/issues/2253) | Split a session into two terminals with title bars shown and right-click one. | Maximize is in the menu, and Restore once maximized. Close isn't in the menu while the title bar shows its own close button. |
| 7 | — | Paste with the Advanced Paste dialog. | The option reads "Convert tabs to spaces" and turns pasted tabs into spaces. |
