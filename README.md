# gherkio.nvim

A lightweight, zero-dependency, context-aware Neovim plugin for the [Gherkio](https://github.com/muhfaris/gherkio) API testing engine.

Run test scenarios, convert cURL commands to DSL, view floating command previews, and navigate failed assertions inside your editor using Neovim's native capabilities.

---

## ✨ Features

- ⚡ **Asynchronous Runs**: Execute tests in the background using `vim.system` or `jobstart` without blocking the editor.
- ✅ **Inline Gutter Signs**: Each step shows `✔` or `✗` in the sign column after a run — results at a glance without switching windows.
- 🛠️ **Assertion-Level Quickfix**: Failed assertions jump to the exact assertion line inside the step, not the step header.
- 📊 **Live Progress Indicator**: See "Executing step 2/5..." in real-time as each step runs.
- 🎯 **Contextual Step Parser**: Understands where your cursor is (Setup, Steps, or Teardown) to execute single steps, active sections, or up to specific step boundaries.
- 🌐 **Cascading Env & Account Selectors**: Detects `.gherkio/environments/` and credentials config to build interactive options menus using `vim.ui.select` (or custom wrappers like Telescope).
- 🔑 **Direct Env/Account Switching**: Switch environments (`<leader>ge`) or accounts (`<leader>gk`) without opening the modal.
- 📋 **cURL Converter**:
  - **Copy to cURL**: Convert any step under your cursor into an executable cURL command, copy it to the clipboard, and display it in a centered, syntax-highlighted floating window.
  - **Paste from cURL**: Automatically convert system or register cURL commands directly into standard Gherkio YAML DSL and paste them at the cursor location.
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
  -- Interactive modal options picker backend. 
  -- Set to a function to route to Telescope or fzf-lua, e.g.:
  -- picker = require("telescope.themes").get_dropdown({}),
  picker = "vim.ui.select",

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

  -- Floating window results options for test runs
  results_window = {
    auto_open = true,   -- Automatically show the test output logs in a floating window
    width = 0.8,        -- Window width as a ratio of editor columns
    height = 0.6,       -- Window height as a ratio of editor lines
    border = "rounded", -- Border style
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
| `<leader>go` | Open the latest HTML report in your default browser |

All keymaps are configurable via `config.keys`.

### 🔍 Dry Run Preview

Append `--dry-run` to any run command to preview the execution step-by-step **without making live HTTP requests**:
```vim
:Gherkio run all --dry-run
```

All runs always capture full request/response data. In the results window, the `── Request ──` and `── Response ──` sections are **folded by default** — press `zo` on a step to expand its details.

### Gutter Signs

After every run, each step's `- request:` line shows:
- `✔` — step passed all assertions
- `✗` — step failed one or more assertions

Signs clear automatically before the next run.

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
