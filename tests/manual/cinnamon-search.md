# Manual check: Cinnamon menu search provider

Typing in the Cinnamon (Linux Mint) menu finds open Tilix terminals, bookmarks and recent session
files while Tilix is running. The plugin, `data/cinnamon/tilix@gexperts.com`, asks Tilix over the
same D-Bus interface as the GNOME Shell provider (see search-provider.md). Its logic is covered by
`tests/manual/search-provider-dbus.sh`, which runs it in cjs against a probe. This checklist covers
the parts that need a real Cinnamon menu.

## Setup

1. Install Tilix. Check that
   `<prefix>/share/cinnamon/search_providers/tilix@gexperts.com/` holds `metadata.json` and
   `search_provider.js`.
   Cinnamon only looks in its data folders (`/usr/share`, `/usr/local/share`) and in
   `~/.local/share/cinnamon/search_providers`. For a private prefix such as `~/.local/tilix-dev`,
   link the folder there:
   `mkdir -p ~/.local/share/cinnamon/search_providers && ln -s ~/.local/tilix-dev/share/cinnamon/search_providers/tilix@gexperts.com ~/.local/share/cinnamon/search_providers/`
2. Turn the provider on. Installing doesn't change desktop settings, so this is a manual step.
   Look at the current list first with `gsettings get org.cinnamon enabled-search-providers`.
   If it's empty (`@as []`), run
   `gsettings set org.cinnamon enabled-search-providers "['tilix@gexperts.com']"`.
   Otherwise add `'tilix@gexperts.com'` to the existing list. Cinnamon loads it straight away.
3. Have the bookmarks `Docs` and `Uptime` and the session `~/demo-session.json` from
   search-provider.md's setup.

## Checks

| # | Do | Expect |
|---|---|---|
| 1 | Quit Tilix. Open the menu and type `docs`. | No Tilix results, and Tilix is not started (`pgrep -a tilix` shows nothing). |
| 2 | Start Tilix, then type `docs` in the menu. | The `Docs` bookmark appears with a folder icon. Its description, "Bookmark — ~/Documents", shows on hover or in the menu's info area, depending on the menu's "Show application descriptions" setting. |
| 3 | Pick it. | A new Tilix window opens in `~/Documents` and the menu closes. |
| 4 | In a terminal run `cd /tmp && vim notes.txt`. In the menu type `vim`. | The terminal appears with the Tilix icon, and the session name and `/tmp` as its description. |
| 5 | Switch to another window and pick that result. | Tilix comes to the front with that terminal focused. |
| 6 | Type `tmp vim`, then `tmp emacs`. | The first finds the terminal, the second finds nothing from Tilix. |
| 7 | Type `demo` and pick the session. | It opens in a new window. |
| 8 | Type `doc` quickly followed by more letters, e.g. `docsxyz`. | Only results for the final text are shown, never a stale `Docs` result. |
| 9 | With Tilix results showing, quit Tilix, then keep typing. | The Tilix results go away and the menu keeps working, with no error dialogs. |
| 10 | Check `~/.xsession-errors` (or Looking Glass, Alt+F2 `lg`, Log tab) after these checks. | No errors mentioning `tilix@gexperts.com`. |
| 11 | Remove `tilix@gexperts.com` from `enabled-search-providers`. | Tilix results stop appearing in the menu. |

## Not covered

- The menu shows search provider results under the app results; Cinnamon decides their position.
- Other Cinnamon search tools (for example third-party menu applets) may not use search providers.
