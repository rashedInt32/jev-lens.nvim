# jev-lens.nvim

Claude Code just finished editing. Before you open a single diff, a popup
tells you whether you need to look, which files, and why:

```
 jev-lens  base-7a  3 files  +84 -12                   look: yes  0.93
 ─────────────────────────────────────────────────────────────────────
  src/auth/session.ts    behavior change      0.88   ← prompt 1
  src/app.ts             leftover debris      0.81   4 comments 1 log
  src/util/format.ts     skip                 0.12
 ─────────────────────────────────────────────────────────────────────
  l lazydiff   s strip debris   r reviewed   j session   R re-judge   q close
```

The judging happens in [jev-lens](https://github.com/rashedInt32/jev-lens),
a Claude Code plugin. This plugin just watches the verdict it writes and
draws it. No API calls, no key, nothing leaves nvim.

https://github.com/user-attachments/assets/f5be3fb4-5b1f-4ed3-a8b7-996a354311f1

## What the keys do

- `l` opens the file and turns on [lazydiff](https://github.com/rashedInt32/lazydiff.nvim)
  if you have it, so you land on the change.
- `s` strips the flagged debris in that file, after a confirm that shows the
  count. It refuses if the buffer has unsaved changes and checks every line
  still matches before deleting. A wrong strip is the one way this tool
  loses your trust, so it is careful.
- `r` marks the verdict reviewed. The baseline moves and the next verdict
  starts from here.
- `j` jumps to the Claude session that did it: the sidekick window if
  Claude runs inside nvim, else the tmux pane.
- `R` judges again now.
- `q` closes. The same files will not pop again until something new joins.

## When it stays quiet

Green is one notify line, never a popup. So is a verdict where no file
clears the bar, a tiny diff, a verdict whose flagged files are all
cosmetic, the re-judge after a strip, and a verdict that flags the same
files you just dismissed. If you are typing, the popup waits until you
leave insert mode.

## Install

You need jev-lens installed in Claude Code first. Then, with lazy.nvim:

```lua
{
  "rashedInt32/jev-lens.nvim",
  event = "VeryLazy",
  opts = {},
}
```

Neovim 0.10 or newer. Nothing else.

## Setup

Everything has a default:

```lua
require("jev-lens").setup({
  data_dir = vim.env.JEV_LENS_DIR or (vim.env.HOME .. "/.claude/jev-lens"),
  poll_ms = 1000,        -- fallback poll; a file watcher does the real work
  show_shadow = false,   -- also show verdicts judged in shadow mode
  on_startup = true,     -- show a pending verdict when nvim opens in the repo
  judge_cmd = nil,       -- found in the plugin cache; set { "node", "/path/to/judge.mjs" } to override
  keys = { lazydiff = "l", strip = "s", reviewed = "r", jump = "j", judge = "R", close = "q" },
  float = { border = "rounded" },
})
```

Highlights: `JevLensHeader`, `JevLensLook`, `JevLensUnsure`, `JevLensOk`,
`JevLensFlagged`, `JevLensSkip`, `JevLensRule`, `JevLensKeys`.

## Commands

- `:JevLens` toggles the latest verdict for this repo.
- `:JevLens show`, `judge`, `reviewed`, `toggle`.
- `require("jev-lens").pending()` returns the unreviewed verdict or nil, if
  you want a dot in your statusline.

## How it finds the verdict

jev-lens writes `~/.claude/jev-lens/repos/<key>/verdict.json`, where the
key is the first 16 hex chars of the sha256 of your repo root. This plugin
computes the same key, watches that folder, and shows each verdict once.
Several nvim instances in one repo all see it; marking reviewed is shared
through the file.

## Tests

```bash
tests/run.sh
```

Headless, isolated data dir, no network.

## License

MIT
