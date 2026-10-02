# Manual checks: directory name and git repository title variables

For the `feature-title-variables` branch (feature request group G08: #1762, #1880). The helpers
`directoryName` and `findGitRepository` have unit tests in `source/gx/tilix/terminal/util.d`. These
checks cover the title editor and live title updates. Shell integration (`vte.sh`) must be set up,
since the variables follow the directory the shell reports.

| # | Check | Pass |
|---|---|---|
| 1 | Preferences → Profile → General → Terminal title, open the variables menu next to the field. | "Directory name" and "Git repository" are listed under Terminal, after "Directory", and insert `${directoryName}` and `${gitRepo}`. |
| 2 | Set the terminal title to `${directoryName}`, then `cd ~/Downloads/tilix_redux/source`. | The title reads `source`. After `cd /` it reads `/`. |
| 3 | Set the terminal title to `${gitRepo}`, then `cd ~/Downloads/tilix_redux/source/gx`. | The title reads `tilix_redux`. After `cd ~/Downloads` it reads `Downloads`, the directory name, since that isn't a repository. |
| 4 | With the title still `${gitRepo}`, `ssh` to another machine with shell integration and `cd` into a repository there. | The title shows the remote directory's name. Remote repositories can't be looked up. |
| 5 | Set the session (tab) name to `${gitRepo}` in Preferences → Global. | Tabs show the repository of their active terminal. |
| 6 | In the Flatpak, without host file system access, repeat check 3. | The title shows the directory name, since the sandbox can't see the repository's files. |
