# Manual checks: file path links and custom link directories

For the `feature-smarter-links` branch (feature request group G30: #2068, #1794), built on
`triage-bug-fixes`. The file path pattern, `parseFileLink` and `resolveFileLinkPath` have unit tests in
`source/gx/tilix/terminal/regex.d`. Run these **without** shell integration (`vte.sh`) unless a step
says otherwise, since that's when #2068 happened.

| # | Check | Pass |
|---|---|---|
| 1 | Add a custom link (Preferences → Advanced → Custom Links): regex `([a-zA-Z0-9_/.\-]+\.[a-z]+)`, command `notify-send "$(pwd)" "$1"`. `cd /tmp`, `touch demo.txt`, `echo demo.txt` and Ctrl+click it. | The notification shows `/tmp`, not the home folder (#2068). |
| 2 | Preferences → Advanced. | A **File Paths** section has "Open file paths with Ctrl+click" (on) and an **Open with** field showing "Default application". |
| 3 | In a project folder run something printing `./src/app.py:12` for a file that exists, and hover over it. | The pointer becomes a hand over the path and position. |
| 4 | Ctrl+click it with Open with empty. | The file opens in its default application. |
| 5 | Set Open with to `code --goto ${file}:${line}:${column}` (or `gedit +${line} ${file}`) and Ctrl+click again. | The editor opens the file at line 12. Without a line number, line 1. |
| 6 | Ctrl+click `~/.bashrc`, `/etc/hosts` and `../README.md` in output. | Each opens, the relative one from the terminal's directory. |
| 7 | Ctrl+click a path that doesn't exist, e.g. `./missing/file.py`. | An info bar says no such file was found; nothing else happens. |
| 8 | Hover over `and/or`, `2026/10/01`, `1/2`, an email address and a URL. | The email address and URL are links as before, opened as such; the others aren't links. |
| 9 | Set Open with to `notify-send "${file}" "${line}"` and Ctrl+click `./src/app.py:12`. | The notification shows the full absolute path and 12. (The path is passed to the shell as a variable, like custom links, and the pattern never includes `;`, `$` or quotes.) |
| 10 | Turn off "Open file paths with Ctrl+click". | Paths are no longer links; the Open with field is disabled. |
| 11 | With shell integration set up, `cd` into a subfolder and repeat check 4 with a relative path. | It resolves against the reported directory. |
