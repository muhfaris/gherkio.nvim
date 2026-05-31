# gherkio.nvim

A lightweight, zero-dependency, context-aware Neovim plugin for the [Gherkio](https://github.com/muhfaris/gherkio) API testing engine.

Run test scenarios, convert cURL commands to DSL, view floating command previews, and navigate failed assertions inside your editor using Neovim's native capabilities.

---

## ✨ Features

- ⚡ **Asynchronous Runs**: Execute tests in the background using `vim.system` or `jobstart` without blocking the editor.
- 🛠️ **Quickfix List Integration**: Automatically maps Gherkio assertions and errors back to exact line numbers in your test buffer.
- 🎯 **Contextual Step Parser**: Under stands where your cursor is (Setup, Steps, or Teardown) to execute single steps, active sections, or up to specific step boundaries.
- 🌐 **Cascading Env & Account Selectors**: Detects `.gherkio/environments/` and credentials config to build interactive options menus using `vim.ui.select` (or custom wrappers like Telescope).
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
  -- Default verbosity flag for CLI runs
  verbose = false,

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

  -- Custom mappings registered inside Gherkio test buffers
  keys = {
    open_modal = "<leader>go", -- Opens the cascading interactive selector menu
    copy_curl  = "<leader>gc", -- Converts current step under cursor to cURL
    paste_dsl  = "<leader>gp", -- Parses clipboard cURL into Gherkio DSL
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
| `:Gherkio copy` | Convert the current step under the cursor to cURL and show a floating preview. |
| `:Gherkio paste` | Convert the clipboard cURL command to YAML DSL and paste it under the cursor. |
| `:Gherkio stop` | Cancel any active background Gherkio execution job. |
| `:Gherkio health` | Verify plugin dependencies and path validations using `:checkhealth gherkio`. |

### 🔍 Dry Run Preview & Verbosity Options

When using `:Gherkio run` subcommands, you can append options:
* `--dry-run`: Previews the execution step-by-step and parses all variables **without making any live HTTP requests**.
* `-v` or `--verbose`: Shows the full request/response headers and bodies inside the output.

Combine both to **preview actual target requests with fully resolved/interpolated variables** directly inside Neovim without executing them:
```vim
:Gherkio run all --dry-run -v
```

Alternatively, invoke `:Gherkio` to toggle `[x] Dry Run` and `[x] Verbose` interactively from the menu choices!

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
