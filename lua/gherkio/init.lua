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
    vim.notify("cURL command copied to clipboard!", vim.log.levels.INFO)
  end)
end

M.preview_request = function()
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
    clipboard.show_preview_float(curl_cmd)
  end)
end

M.paste_dsl = function()
  require("gherkio.core.picker").trigger_paste_dsl()
end

M.open_modal = function()
  require("gherkio.core.picker").open_modal()
end

M.run_last = function()
  require("gherkio.core.runner").run_last()
end

M.run_all = function()
  local state = require("gherkio.core.picker").get_active_state()
  require("gherkio.core.runner").run_test({
    env = state.env,
    account = state.account
  })
end

local initialized_roots = {}

local function setup_lsp_schema(project_root)
  if initialized_roots[project_root] then
    return
  end
  initialized_roots[project_root] = true

  local cache_dir = vim.fn.stdpath("cache") .. "/gherkio"
  if vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, "p")
  end
  local schema_path = cache_dir .. "/test.schema.json"

  local function register_with_client(client)
    if client.name ~= "yamlls" then return end

    local settings = client.config.settings or {}
    settings.yaml = settings.yaml or {}
    settings.yaml.schemas = settings.yaml.schemas or {}

    -- Normalize paths for Unix/Windows compatibility
    local schema_path_normalized = schema_path:gsub("\\", "/")
    local glob = (project_root .. "/.gherkio/tests/**/*.yaml"):gsub("\\", "/")

    -- Only notify if configuration actually changed
    if settings.yaml.schemas[schema_path_normalized] ~= glob then
      settings.yaml.schemas[schema_path_normalized] = glob
      client.config.settings = settings
      client.notify("workspace/didChangeConfiguration", { settings = settings })
    end
  end

  -- Query `gherkio` executable path from system
  if vim.fn.executable("gherkio") == 1 then
    vim.system({ "gherkio", "schema", "--type", "test" }, { text = true }, function(obj)
      if obj.code == 0 and obj.stdout and #obj.stdout > 0 then
        local f = io.open(schema_path, "w")
        if f then
          f:write(obj.stdout)
          f:close()
        end
        -- Trigger update for already active yamlls instances
        vim.schedule(function()
          local active_clients = {}
          if vim.lsp.get_clients then
            active_clients = vim.lsp.get_clients({ name = "yamlls" })
          else
            active_clients = vim.lsp.get_active_clients()
          end
          for _, client in ipairs(active_clients) do
            register_with_client(client)
          end
        end)
      end
    end)
  end

  -- Listen for future LspAttach events for yamlls
  local group = vim.api.nvim_create_augroup("GherkioLspSchema", { clear = false })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and client.name == "yamlls" then
        register_with_client(client)
      end
    end,
  })
end

-- Primary plugin initialization
function M.setup(opts)
  config.setup(opts)

  -- Setup buffer-local keymaps automatically for YAML files within Gherkio projects
  local keys = config.get("keys")
  
  local function bind_keys(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then return end

    local runner = require("gherkio.core.runner")
    local project_root = runner.find_project_root(bufnr)
    if project_root then
      -- Automatically set up JSON Schema validation if enabled
      local lsp_cfg = config.get("lsp_schema")
      if lsp_cfg and lsp_cfg.enabled then
        setup_lsp_schema(project_root)
      end

      if keys then
        if keys.open_modal and keys.open_modal ~= "" then
          vim.keymap.set("n", keys.open_modal, M.open_modal, { buffer = bufnr, silent = true, desc = "Gherkio Modal Options" })
        end
        if keys.copy_curl and keys.copy_curl ~= "" then
          vim.keymap.set("n", keys.copy_curl, M.copy_curl, { buffer = bufnr, silent = true, desc = "Gherkio Copy Step cURL" })
        end
        if keys.paste_dsl and keys.paste_dsl ~= "" then
          vim.keymap.set("n", keys.paste_dsl, M.paste_dsl, { buffer = bufnr, silent = true, desc = "Gherkio Paste cURL as DSL" })
        end
        if keys.preview_request and keys.preview_request ~= "" then
          vim.keymap.set("n", keys.preview_request, M.preview_request, { buffer = bufnr, silent = true, desc = "Gherkio Preview Step cURL" })
        end
        if keys.repeat_last and keys.repeat_last ~= "" then
          vim.keymap.set("n", keys.repeat_last, M.run_last, { buffer = bufnr, silent = true, desc = "Gherkio Repeat Last Run" })
        end
        if keys.run_all and keys.run_all ~= "" then
          vim.keymap.set("n", keys.run_all, M.run_all, { buffer = bufnr, silent = true, desc = "Gherkio Run All Steps" })
        end
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

return M
