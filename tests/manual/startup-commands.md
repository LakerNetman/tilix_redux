# Manual checks: startup commands that run in the shell

For the `feature-startup-commands` branch (feature request group G19: #1527, #1977, #1986, #1912).
`initCommandText` has unit tests in `source/gx/tilix/terminal/util.d`; these checks cover the Layout
Options dialog, session files and typing into the shell.

| # | Check | Pass |
|---|---|---|
| 1 | Terminal menu → Other → Layout Options. | Under Session Load there are two fields, **Instead of shell** (the old Command field) and **Run in shell**, each with a tooltip explaining it. |
| 2 | Split a session into two terminals. In the first set Run in shell to `cd /tmp && ls`, in the second `export DEMO=1; echo started`. Save the session. | The saved JSON has an `"initCommand"` for each terminal. |
| 3 | Close Tilix and load the session (`tilix -s file.json`). | The first terminal shows the `ls` output and is left at a prompt in `/tmp`. The second shows `started`, and `echo $DEMO` prints 1, so what the command set up stayed. |
| 4 | Look at the typed commands. | Each appears once, after the prompt, and is in the shell's history (Up arrow). |
| 5 | Set Run in shell to a long-running command such as `top`, save, and reload. | `top` runs. Quitting it leaves the shell open, unlike Instead of shell. |
| 6 | Turn on synchronised input for the session before saving, then reload. | Each terminal runs only its own command; none is copied to the other terminals. |
| 7 | Set both fields: Instead of shell `bash --norc`, Run in shell `echo hello`. | `bash --norc` starts and `hello` is typed into it. |
| 8 | Open a new terminal normally, not from a session file. | Nothing is typed. Run in shell, like Instead of shell, applies when loading a session file. |
| 9 | Use a profile whose shell takes several seconds to start (e.g. `sleep 3` at the top of `.bashrc`). | The command is still typed, at the latest about 1.5 seconds after start, and runs once the shell is ready. It may show before the prompt in this case. |
