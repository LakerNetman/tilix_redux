# Manual checks: new session with a profile, and new session position

For the `feature-new-tab-profile` branch (feature request group G51: #1931, #2136). The insert
position and menu label escaping have unit tests in `source/gx/tilix/appwindow.d`; these checks cover
the dropdown, menus and setting. Create a second profile first, with a custom command such as `htop`
(Profile → Command → Run a custom command), and an underscore in its name, e.g. `my_htop`.

| # | Check | Pass |
|---|---|---|
| 1 | Look at the header bar with tabs enabled. | A ▾ button is joined to the new-tab button, with the tooltip "Create a new session with a profile". |
| 2 | Open the ▾ dropdown. | Every profile is listed. `my_htop` shows its underscore instead of an underlined letter. |
| 3 | `cd /tmp` in the current terminal, then choose `my_htop` from the dropdown. | A new tab opens running `htop` in `/tmp`. |
| 4 | Rename or add a profile in Preferences, then open the dropdown again. | The list shows the change without restarting Tilix. |
| 5 | Turn off tabs (Preferences → Appearance → use sidebar) and restart Tilix. | The ▾ button sits next to the new-session button, and works as above. |
| 6 | Open the window menu (☰). | A **New Session** submenu lists the profiles, and works like the dropdown. |
| 7 | Set the window style to "No CSD, hide toolbar" or borderless. | New Session in the window menu is still reachable where that menu is available. |
| 8 | With three tabs open and the first active, press Shift+Ctrl+T. | The new tab is added at the end (default). |
| 9 | Turn on Preferences → Global → "Open new sessions next to the current one" and repeat. | The new tab opens right after the first one. With the sidebar instead of tabs, the sidebar order matches. |
| 10 | With "Prompt when creating a new session" on, use the dropdown. | The session opens with the chosen profile without the prompt, since the profile was already chosen. The new-tab button still prompts. |
