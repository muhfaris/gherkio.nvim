local config = require("gherkio.config")

local M = {}

-- Lazy loader helper to keep init.lua extremely lightweight
local function lazy(module, func)
  return function(...)
    return require("gherkio.core." .. module)[func](...)
  end
end

-- Lazy functions mapped directly to internal modules
M.run_test = function(opts)
  require("gherkio.core.runner").run_test(opts or {})
end

M.stop_job = function()
  require("gherkio.core.runner").stop_active_job()
end

M.copy_curl = function()
  local parser = require("gherkio.core.parser")
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local step_idx = parser.detect_step_index(bufnr, cursor_line)

  if step_idx < 0 then
    vim.notify("Cursor is not positioned inside a valid test step.", vim.log.levels.WARN)
    return
  end

  require("gherkio.core.runner").copy_as_curl({
    step = step_idx
  }, function(curl_cmd)
    local clipboard = require("gherkio.core.clipboard")
    clipboard.set_contents(curl_cmd)
    clipboard.show_preview_float(curl_cmd)
    vim.notify("cURL command copied to clipboard!", vim.log.levels.INFO)
  end)
end

M.paste_dsl = function()
  require("gherkio.core.picker").trigger_paste_dsl()
end

M.open_modal = function()
  require("gherkio.core.picker").open_modal()
end

-- Primary plugin initialization
function M.setup(opts)
  config.setup(opts)

  -- Setup buffer-local keymaps automatically for YAML files within Gherkio projects
  local keys = config.get("keys")
  if keys then
    local function bind_keys(bufnr)
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name == "" then return end

      local runner = require("gherkio.core.runner")
      local project_root = runner.find_project_root(bufnr)
      if project_root then
        if keys.open_modal and keys.open_modal ~= "" then
          vim.keymap.set("n", keys.open_modal, M.open_modal, { buffer = bufnr, silent = true, desc = "Gherkio Modal Options" })
        end
        if keys.copy_curl and keys.copy_curl ~= "" then
          vim.keymap.set("n", keys.copy_curl, M.copy_curl, { buffer = bufnr, silent = true, desc = "Gherkio Copy Step cURL" })
        end
        if keys.paste_dsl and keys.paste_dsl ~= "" then
          vim.keymap.set("n", keys.paste_dsl, M.paste_dsl, { buffer = bufnr, silent = true, desc = "Gherkio Paste cURL as DSL" })
        end
      end
    end

    -- Bind to current active buffer on startup/lazy-load if it's already a YAML file
    local current_buf = vim.api.nvim_get_current_buf()
    local ft = vim.bo[current_buf].filetype
    if ft == "yaml" then
      bind_keys(current_buf)
    end

    -- Automatically bind to future YAML buffers inside Gherkio projects
    local group = vim.api.nvim_create_augroup("GherkioKeymaps", { clear = true })
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
      group = group,
      pattern = { "*.yaml", "*.yml" },
      callback = function(args)
        bind_keys(args.buf)
      end
    })
  end
end

return M
