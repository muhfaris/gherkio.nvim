# gherkio.nvim

A lightweight, zero-dependency, context-aware Neovim plugin for the [Gherkio](https://github.com/muhfaris/gherkio) API testing engine.

Run test scenarios, convert cURL commands to DSL, view floating command previews, and navigate failed assertions inside your editor using Neovim's native capabilities.

---

## ✨ Features

- ⚡ **Asynchronous Runs**: Execute tests in the background using `vim.system` or `jobstart` without blocking the editor.
- ✅ **Inline Extmark Status**: Each step shows `✔ 1.2s` or `✗ fail` as inline virtual text after a run — results at a glance without switching windows.
- 🛠️ **Assertion-Level Quickfix**: Failed assertions jump to the exact assertion line inside the step, not the step header.
- 📊 **Live Streaming Window**: Raw output streams in-place while the run executes, with smart tail-following (pause by scrolling up).
- 🎯 **Contextual Step Parser**: Understands where your cursor is (Setup, Steps, or Teardown) to execute single steps, active sections, or up to specific step boundaries.
- 🗂️ **3-Tab Results Window**: `[1] All`, `[2] Bodies`, `[3] Failures` — focused views without overlapping modes.
- 🗺️ **Static Outline View (Review Without Running)**: `<leader>gO` / `:Gherkio outline` renders the whole scenario from the YAML buffer — sections, steps, assertion one-liners, `save:` vars, `[use:]` shared refs — with a totals footer. `<CR>` on any step jumps to its line in the YAML source. No run required.
- 🔎 **Inline Body Expand/Collapse**: Long bodies clamp with `« N more lines — <CR> to expand inline »`; `<CR>` expands/collapses in place.
- 🌐 **Auto-Detecting Picker**: Modal menus render through your installed picker (snacks → fzf-lua → telescope), falling back to `vim.ui.select`.
- 🔑 **Direct Env/Account Switching**: Switch environments (`<leader>ge`) or accounts (`<leader>gk`) without opening the modal.
- 📋 **cURL Converter**:
  - **Copy to cURL**: Convert any step under your cursor into an executable cURL command, copy it to the clipboard, and display it in a centered, syntax-highlighted floating window.
  - **Paste from cURL**: Automatically convert system or register cURL commands directly into standard Gherkio YAML DSL and paste them at the cursor location.
- ✂️ **Clean Visual Yank**: Visual-mode `Y` copies selected body lines with all tree decorations (`│`, `├─`, `└─`) stripped — pure JSON to clipboard. Normal-mode `y` copies the current step's body without needing any selection.
- 🚀 **Zero External Dependencies**: Pure Lua codebase with built-in YAML and buffer parsing. No external rocks required.
- 🏥 **Checkhealth Diagnostic Integration**: Integrated with `:checkhealth gherkio` to verify binary pathing, project state, and configuration flags.

---

## 📦 Installation

Install `gherkio.nvim` using your favorite plugin manager.

### [lazy.nvim](https://github.com/folke/lazy.nvim)
```lua
{
  "muhfaris/gherkio",
  -- Specify the subdirectory containing the plugin
  dir = "neovim/gherkio.nvim", 
  dependencies = { "nvim-lua/plenary.nvim" }, -- Optional, for helper utilities
  config = function()
    require("gherkio").setup({
      -- Custom user settings here
    })
  end
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)
```lua
use {
  'muhfaris/gherkio',
  rtp = 'neovim/gherkio.nvim',
  config = function()
    require('gherkio').setup()
  end
}
```

---

## ⚙️ Configuration

`gherkio.nvim` comes with reasonable defaults. Call `setup()` to initialize or customize options:

```lua
require("gherkio").setup({
  -- Interactive modal picker backend.
  -- "auto" probes installed pickers in order: snacks → fzf-lua → telescope → builtin.
  -- Or force one: "snacks" | "fzf" | "telescope" | "builtin"
  -- Or provide a custom function: picker = function(items, opts, on_choice) ... end
  picker = "auto",

  -- Single completion notification (no per-step progress spam)
  notifications = {
    enabled = true,
  },

  -- Quickfix list integration behavior
  quickfix = {
    auto_open = true,   -- Open quickfix window automatically on test failure
    auto_close = true,  -- Close quickfix window automatically when test passes
  },

  -- Floating window preview options for copy-as-curl
  preview = {
    width = 0.6,        -- Window width as a ratio of editor columns
    height = 0.4,       -- Window height as a ratio of editor lines
    border = "rounded", -- Border style ("single", "double", "rounded", "solid", "shadow")
    auto_close = true,  -- Close the preview window using `q`, `Esc`, or `Enter`
  },

  -- Results window options for test runs
  results_window = {
    auto_open = true,      -- Automatically show the results window on run
    layout = "vsplit",     -- "vsplit" | "split" | "float"
    width = 0.40,          -- Window width as a ratio of editor columns
    height = 0.3,          -- Window height as a ratio of editor lines (split layout)
    border = "rounded",    -- Border style
    max_body_lines = 200,  -- Body lines rendered before an inline <CR> expand marker
    focus_on_open = false, -- Keep cursor in the test buffer when the results window opens
  },

  -- Custom mappings registered inside Gherkio test buffers
  keys = {
    open_modal        = "<leader>gm", -- Opens the cascading interactive selector menu
    find_tests        = "<leader>gt", -- Fuzzy find test or schema files (global keymap)
    copy_curl         = "<leader>gc", -- Converts current step under cursor to cURL (copies to clipboard)
    paste_dsl         = "<leader>gp", -- Parses clipboard cURL into Gherkio DSL
    preview_request   = "<leader>gi", -- Inspects/previews current step in cURL format without copying or running
    run_under_cursor  = "<leader>gr", -- Run the test step under the cursor immediately
    repeat_last       = "<leader>gl", -- Re-run the last test execution
    run_all           = "<leader>ga", -- Run the full scenario (all steps)
    switch_env        = "<leader>ge", -- Switch active environment
    switch_account    = "<leader>gk", -- Switch active account
    open_report       = "<leader>go", -- Open latest HTML report in default web browser
    open_outline      = "<leader>gO", -- Static outline view: review the scenario without running it
  }
})
```

---

## ⌨️ Usage & Commands

The plugin exposes the `:Gherkio` user command, which includes tab autocomplete support for all actions:

| Command | Action |
| :--- | :--- |
| `:Gherkio` | Open the cascading interactive modal selection (supports verbose & dry-run toggles!). |
| `:Gherkio run` | Execute the single test step under the active cursor line. |
| `:Gherkio run all` | Run the complete Gherkio test scenario (all steps). |
| `:Gherkio run section` | Run only the active section (`setup`, `steps`, or `teardown`) containing the cursor. |
| `:Gherkio run until <N>` | Execute all steps in the current section up to step `<N>` (0-indexed). |
| `:Gherkio preview` | Preview current step as a cURL command in a floating window (does not copy to clipboard). |
| `:Gherkio copy` | Convert the current step under the cursor to cURL and copy it to the clipboard. |
| `:Gherkio paste` | Convert the clipboard cURL command to YAML DSL and paste it under the cursor. |
| `:Gherkio stop` | Cancel any active background Gherkio execution job. |
| `:Gherkio health` | Verify plugin dependencies and path validations using `:checkhealth gherkio`. |
| `:Gherkio results` | Reopen the results window of the last run. |
| `:Gherkio outline` | Open static outline view of current scenario file (review without running). |
| `:Gherkio report` | Open the latest HTML report in your default browser. |

### Keymaps (buffer-local to YAML files, except `find_tests` which is global)

| Key | Action |
| :--- | :--- |
| `<leader>gm` | Open the interactive action modal |
| `<leader>gt` | Find test or schema files (Telescope picker) |
| `<leader>gr` | Run the test step under the cursor immediately |
| `<leader>ga` | Run the full scenario (all steps) |
| `<leader>ge` | Switch active environment |
| `<leader>gk` | Switch active account |
| `<leader>gc` | Copy current step as cURL command |
| `<leader>gp` | Paste cURL from clipboard as DSL |
| `<leader>gi` | Preview current step as cURL in floating window |
| `<leader>gl` | Repeat the last test run |
| `<leader>gO` | Open static outline view (review scenario without running) |
| `<leader>go` | Open the latest HTML report in your default browser |

All keymaps are configurable via `config.keys`.

### Results Window Keymaps (buffer-local inside the results window)

| Key | Action |
| :--- | :--- |
| `1` | Switch to `[1] All` view (full tree) |
| `2` | Switch to `[2] Bodies` view (request/response blocks only) |
| `3` | Switch to `[3] Failures` view (failed steps only) |
| `<CR>` | Expand/collapse the body block under the cursor inline |
| `y` | Yank current step's body (response first, then request) to clipboard |
| `r` | Open response body in a formatted JSON preview popup |
| `Y` (visual mode) | Yank visual selection with tree decorations (`│`, `├─`, `└─`) stripped |
| `?` | Show the help popup |
| `q` or `<Esc>` | `q` closes the results window (help closed first); `<Esc>` dismisses the help popup, or closes the results window if help is already hidden |

### 🔍 Dry Run Preview

Append `--dry-run` to any run command to preview the execution step-by-step **without making live HTTP requests**:
```vim
:Gherkio run all --dry-run
```

All runs always capture full request/response data. Long bodies are clamped with an inline `« N more lines — <CR> to expand inline »` marker — press `<CR>` on (or inside) the block to expand it; press `<CR>` again to collapse it.

### Inline Step Status

After every run, each step line shows inline virtual text (extmarks, not legacy signs):
- `✔ <duration>` — step passed all assertions (e.g. `✔ 1.2s`)
- `✗ fail` — step failed one or more assertions

Marks clear automatically before the next run.

### Copy & Paste Flows

**Plain `y` (Normal mode, results window):** copies the parsed clean body (no decoration). Prefers the response body; falls back to the request body when there is no response.

**Visual `Y` (results window):** for request bodies or custom selections:
1. `V` (or `v`) — select the exact body lines
2. `Y` — copies selection with all treeline chars (`│`, `├─`, `└─`) and decoration indent stripped

Both write to the `+` system clipboard and `"` unnamed register. Use `<leader>gc` / `<leader>gp` to convert to/from cURL.

### Notifications

A single notification fires when the run completes (`✓ passed` / `✗ failed — check quickfix`). Per-step progress notifications were removed — the streaming window already shows progress in place. Set `notifications.enabled = false` to disable.

---

## 🏥 Diagnostics & Troubleshooting

To check if Gherkio is properly configured, run:
```vim
:checkhealth gherkio
```

This diagnostic script validates:
1. If the `gherkio` executable is available in your system path.
2. If Neovim can locate your active `.gherkio/` project root directory.
3. If environment configuration scopes and accounts credentials are detected correctly.
4. If your picker and global keymaps configuration structures are valid.
