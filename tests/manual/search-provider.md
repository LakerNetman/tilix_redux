# Manual check: GNOME Shell search provider

Typing in the Activities overview finds open Tilix terminals, bookmarks and recent session
files. The D-Bus side is covered by unit tests and was checked on a private bus with a probe
program. This checklist covers the parts that need a real GNOME Shell.

## Setup

1. Install Tilix with meson or `install.sh`. Check that
   `<prefix>/share/gnome-shell/search-providers/com.gexperts.Tilix.search-provider.ini` exists.
   For a prefix other than `/usr` or `/usr/local`, `<prefix>/share` must be in `XDG_DATA_DIRS`.
2. Log out and back in. GNOME Shell only reads provider files when it starts.
3. In Settings > Search, check that Tilix is listed and switched on.
4. Make two bookmarks in Tilix: a path bookmark named `Docs` for `~/Documents`, and a remote or
   command bookmark named `Uptime` with the command `uptime`.
5. Save a session as `~/demo-session.json`, so it appears in the recent sessions list.

## Checks

| # | Do | Expect |
|---|---|---|
| 1 | Quit Tilix completely. Open Activities and type `docs`. | Tilix starts in the background without opening a window, and a Tilix group appears with the `Docs` bookmark. |
| 2 | Pick `Docs`. | A new Tilix window opens with its terminal in `~/Documents`. |
| 3 | In Activities, type `uptime` and pick the bookmark. | A new window opens and `uptime` is typed into the shell after the prompt appears, then runs. The shell stays open. |
| 4 | In a terminal, run `cd /tmp && vim notes.txt`. In Activities, type `vim`. | The terminal shows up with its title, and the session name and `/tmp` as the description. |
| 5 | Switch to another app and pick that result. | Tilix comes to the front with that session tab selected and that terminal focused, even in a split. |
| 6 | Type `tmp vim` (two words). | The same terminal matches, since every word must match something. `tmp emacs` finds nothing. |
| 7 | Type `demo`. Pick the session result. | `demo-session` is listed, and picking it opens a new window with that session loaded. |
| 8 | Rename or delete `~/demo-session.json`, then search `demo` again. | The session is no longer listed. |
| 9 | Search for a terminal, close that terminal, then pick the stale result. | Tilix just comes to the front. Nothing crashes. |
| 10 | Make a session file invalid (for example, empty it), keep it in the recent list, and pick it from search. | An error dialog says the session could not be loaded, no empty window is left behind, and the file is gone from the recent list. |
| 11 | Click the Tilix icon at the left of the search results. | The current Tilix window comes to the front, or a new one opens if there are none. |
| 12 | Switch Tilix off in Settings > Search and search again. | No Tilix results appear. |
| 13 | Run `tilix --new-process` and `tilix -g test` alongside a normal Tilix. | Both start normally. Search results come from the main instance only. |

## Not covered

- Flatpak: the manifest does not export the provider file yet.
- The bookmark "include return key" setting doesn't apply here. A bookmark picked from search always runs.
