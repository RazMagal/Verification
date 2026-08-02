# Project instructions for Claude Code — verification (HDL/UVM DV)

## Copying files to the clipboard (for EDA Playground) — use `confepo clip`

This project's workflow copies `.sv` / `.svh` sources to the clipboard to paste
into EDA Playground's **Design** / **Testbench** panes in the browser. When you
do that, **always copy with `confepo clip`, never raw `xclip`.**

- Do:    `confepo clip ip/apb_timer/tb/tb_top.sv`   (or `… | confepo clip`)
- Don't: `xclip -selection primary …`  /  `xclip -selection clipboard …`  /  `xsel`

**Why:** raw `xclip -selection primary` grabs the same X PRIMARY selection that
the terminal (Alacritty) grabs on every mouse-drag select. X11 selection
ownership is a race, so a per-copy `xclip` makes Alacritty log
`Unable to store text in clipboard: Failed to set new owner of XCB selection`
(and can win the selection out from under a copy in progress). A browser paste
(Ctrl+V) reads only the CLIPBOARD selection, so `confepo clip` writes CLIPBOARD
**only** and never touches PRIMARY — which removes the races entirely.

`confepo clip` is on `PATH` (from the confepo dotfiles). `confepo clip --help`
for usage; it reads a FILE argument or stdin.
