# CC Browser

A browser and Lua applet runtime for CC:Tweaked. The graphical build adds a pixel-drawn interface, the Awesome HTML and CSS renderer, and a PNG viewer. Tabs, history, forms, and applets work in graphical and text mode.

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
- Open **Settings → Display** to choose Automatic, Terminal, or Graphical and adjust the window scale from 100% to 200%. Graphical mode and scaling are disabled when the display lacks graphics support. Scale changes reflow the browser without changing the physical size of the Minecraft terminal.
- Use the top-left close button, `Ctrl+Q`, or CC: Desktop's `F8` recovery key to return to CraftOS. `Ctrl+L` opens the address field.

Use CC: Desktop `0.1.0-preview.3` for CraftOS text blitting and PNG decoding. The graphical browser matches the native terminal's pixel dimensions and reflows when CraftOS reports a display size change. Minecraft controls the outer computer GUI and its scaling.

## Awesome renderer

Choose **Awesome** under **Settings → Rendering engine**. It is the default for new installs. It supports styled headings and text, links, lists, tables, box styling, inline PNGs, flex and grid layouts, and width-based media queries. Styles can come from inline attributes, stylesheet blocks, and linked stylesheets. F7 enables caret selection on the same rendered layout, with Shift to extend and Ctrl+C to copy.

Forms use the existing interactive layout. PNG previews are bounded to 2 MiB, and up to three same-origin PNGs of at most 256 KiB each can display inline. Pages that depend on JavaScript or unsupported CSS can render differently from a desktop browser.

`Ctrl+Shift+C` and `Ctrl+Shift+V` request an approved host clipboard copy or paste on a graphical computer. Enable `allowHostClipboard` in the local CC: Desktop config to see a Minecraft confirmation. `Ctrl+C` and `Ctrl+V` still use the browser clipboard and CraftOS paste behavior. See [CC: Desktop client settings](https://github.com/T-Craft-Platforms/cc-desktop-mod/blob/feat/browser-graphics-api/docs/development/client-configuration.md).

## Test

Run `lua5.4 tests/display.lua` and `lua5.4 tests/awesome.lua` from the repository root. These check backend switching, resizing, input, CSS reflow, and selection on the graphical layout.
