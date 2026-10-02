# Manual checks: terminal padding and border

For the `feature-terminal-padding` branch (feature request group G23: #2024, #1595, #2209).
`paddingCss` and `clampBorderWidth` have unit tests in `source/gx/tilix/terminal/util.d`; these checks
cover the profile editor and drawing.

| # | Check | Pass |
|---|---|---|
| 1 | Preferences → Profile → General. | **Padding** (0–64) and **Border** (0–16, with a colour button) are listed after Cell spacing. |
| 2 | Set Padding to 12. | Every terminal using the profile gets 12 px of space between its text and edges at once, in the terminal's background colour, also with a transparent background. |
| 3 | Split the window and select text right next to the divider in the right-hand terminal. | Selecting no longer grabs the divider instead (#2024). |
| 4 | Set Border to 3 and pick a bright colour. | A 3 px border in that colour surrounds each terminal and its title bar, without covering text. The edges between tiles are visible in a dark theme (#2209). |
| 5 | Change the border colour, then set the width back to 0. | The colour updates at once; at 0 the border disappears and the terminal takes the space back. |
| 6 | Make a second profile with a different border colour and switch one terminal to it. | That terminal's border changes (#1595). Selecting the second profile in Preferences shows its own colour in the colour button. |
| 7 | Add `.tilix-background vte-terminal { padding: 20px; }` to `~/.config/gtk-3.0/gtk.css`, restart Tilix, leave the profile's Padding at 0. | The 20 px from gtk.css still applies. Setting the profile's Padding to 5 overrides it with 5. |
| 8 | Use a terminal's own title bar and maximise one of several terminals. | Border and padding still look right, including in the maximised terminal. |
