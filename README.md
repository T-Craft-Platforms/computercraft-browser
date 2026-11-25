# CC Browser

A browser and Lua applet runtime for CC:Tweaked. The graphical build adds pixel-drawn browser chrome, a start page with shortcuts, and a PNG viewer. Tabs, links, history, forms, and applets share the same browser logic in graphical and text mode.

## Install this branch

In CraftOS, run:

```text
wget run https://raw.githubusercontent.com/T-Craft-Platforms/computercraft-browser/feat/cc-desktop-browser/install.lua
```

Select the **feat/cc-desktop-browser** branch in the installer. Use the launcher path shown after installation.

## Choose a display

- On an Advanced Computer, Advanced Turtle, or Advanced Pocket Computer, the browser uses CC: Desktop graphics when available. Otherwise it opens in the normal CraftOS terminal.
- Pass `--monitor=left` (or the connected peripheral's name) to use an Advanced Monitor. Use its front face for touchscreen navigation. The computer keeps its keyboard and shows the display controls.
- Pass `--text` to use character mode on either the computer or the chosen monitor.
- Use the top-left close button, `Ctrl+Q`, or CC: Desktop's `F8` recovery key to return to CraftOS. `Ctrl+L` opens the address field.

CC: Desktop `0.1.0-preview.3` adds faithful rendering of CraftOS characters and PNG previews for local or HTTP(S) images up to 2 MiB. Older graphics previews use the bitmap text renderer and show a download option for PNGs. HTML image labels can open PNGs in the viewer. Pages use the browser's existing HTML and CSS subset.

`Ctrl+Shift+C` and `Ctrl+Shift+V` request an approved host clipboard copy or paste on a graphical computer. Enable `allowHostClipboard` in the local CC: Desktop config to see a Minecraft confirmation. `Ctrl+C` and `Ctrl+V` still use the browser clipboard and CraftOS paste behavior. See [CC: Desktop client settings](https://github.com/T-Craft-Platforms/cc-desktop-mod/blob/feat/browser-graphics-api/docs/development/client-configuration.md).

## Test

Run `lua5.4 tests/display.lua` from the repository root. This checks the graphical and text backends, viewport input, monitor event deduplication, and clipboard response routing.
