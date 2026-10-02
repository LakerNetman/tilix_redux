# Manual checks: renaming terminals

For the `feature-rename-terminal` branch (feature request group G04: #1162, #1747, #2092). The rule
for which title gets stored has unit tests (`titleOverrideFor` in
`source/gx/tilix/terminal/util.d`); these checks cover the dialog, menus and shortcut.

| # | Check | Pass |
|---|---|---|
| 1 | Open the terminal title bar menu (click the title). | **Rename…** is the first item. It opens a "Rename Terminal" dialog showing the current title. |
| 2 | Enter `web server` and press Enter. | The title bar, and the tab if it shows `${title}`, read "web server". |
| 3 | Press **Shift+Ctrl+R** in a terminal. | The same dialog opens. Preferences → Shortcuts lists it as "Rename terminal" under Terminal, and the Keyboard Shortcuts window shows it too. |
| 4 | Turn the terminal title bar off (Preferences → Appearance) and right-click a terminal. Then turn it back on and right-click again. | **Rename…** appears exactly once in both cases. |
| 5 | Open Rename, clear the field and press OK. | The title goes back to the profile's title, i.e. the shell's title or `${title}`. Typing the profile's title unchanged does the same. |
| 6 | Rename a terminal, save the session, close Tilix and load the session. | The terminal keeps its name (#1747). |
| 7 | From another Tilix terminal, run `tilix -a app-new-session -t "my title"`. | The new tab and its terminal are titled "my title" (#2092). If not, note what it shows; that issue was reported on 1.9.1 and the code suggests it now works. |
| 8 | Double-click a tab's label (with tabs enabled). | The label becomes editable and renames the session (already supported before this branch). |
