# Manual checks: paste options

For the `feature-paste-options` branch (feature request group G29: #2119, #1760, #2148, #1657).
`joinLines` and `pasteLines` have unit tests in `source/gx/tilix/terminal/advpaste.d`; these checks
cover the dialog, settings and terminal behaviour.

| # | Check | Pass |
|---|---|---|
| 1 | Preferences → Global → Clipboard. | A **Right click** choice offers Show menu (the default) and Paste. |
| 2 | Leave it on Show menu and right-click a terminal. | The menu opens, as before. |
| 3 | Set it to Paste, copy some text and right-click a terminal. | The clipboard is pasted. Shift+right click and the Menu key still open the menu. |
| 4 | With Paste set, run `mc` or `htop` and right-click in it. | The program gets the click, as before, rather than a paste. |
| 5 | With Paste set and "Always use advanced paste dialog" on, right-click with several lines copied. | The Advanced Paste dialog opens. |
| 6 | Copy a column of three names on separate lines, open Advanced Paste (bind its shortcut first) and tick **Replace newlines with spaces**. | The names are pasted as one line separated by spaces, and nothing runs (#1760). The delay field is disabled while this is ticked. |
| 7 | Bind a shortcut to **Paste as a single line** (Preferences → Shortcuts → Terminal) and use it with the same column copied. | Same result, without the dialog. The Keyboard Shortcuts window lists it too. |
| 8 | Copy ten lines like `echo 1` … `echo 10`, open Advanced Paste, set **Delay between lines** to 500 and paste. | The lines arrive and run one at a time, half a second apart (#2148). |
| 9 | Start a delayed paste of many lines and close the terminal before it finishes. | Nothing errors, and no further lines go anywhere. |
| 10 | Set the delay back to 0 and paste again. | Everything is pasted at once, as before. |
| 11 | Turn on synchronised input and repeat check 8. | The terminal you pasted into gets the lines with the delay; the other synchronised terminals receive the whole paste at once, as with Tilix's existing paste sync. |
| 12 | Paste `a<Tab>b` with Advanced Paste and "Convert tabs to spaces" on. | Spaces are pasted instead of the tab, so shell completion doesn't swallow it (#1657, already possible before this branch). |
