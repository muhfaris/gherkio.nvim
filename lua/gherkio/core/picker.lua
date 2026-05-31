local parser = require("gherkio.core.parser")
local runner = require("gherkio.core.runner")
local clipboard = require("gherkio.core.clipboard")
local config = require("gherkio.config")

local M = {}

-- Local state to preserve verbose override within modal session
local verbose_override = nil
local dry_run_override = nil

-- Wrapper around picker backend configured by the user
local function ui_select(items, opts, on_choice)
  local picker = config.get("picker")
  if type(picker) == "function" then
    local ok, err = pcall(picker, items, opts, on_choice)
    if not ok then
      -- Fall back to vim.ui.select if custom picker fails
      vim.ui.select(items, opts, on_choice)
    end
  else
    vim.ui.select(items, opts, on_choice)
  end
end

-- Cascades picker selections for env, accounts, and actions
function M.open_modal()
  local bufnr = vim.api.nvim_get_current_buf()
  local project_root = runner.find_project_root(bufnr)
  if not project_root then
    vim.notify("No Gherkio project found. Run `gherkio init` first.", vim.log.levels.WARN)
    return
  end

  if verbose_override == nil then
    verbose_override = config.get("verbose", false)
  end
  if dry_run_override == nil then
    dry_run_override = false
  end

  local envs = runner.get_available_envs(project_root)
  if #envs == 0 then
    -- No environments, execute actions directly
    M.select_action({ env = "", account = "" })
  elseif #envs == 1 then
    -- Single env, automatically resolve accounts
    M.resolve_accounts({ env = envs[1] })
  else
    -- Prompt for environment
    local env_choices = { "Default (None)" }
    for _, e in ipairs(envs) do
      table.insert(env_choices, e)
    end

    ui_select(env_choices, {
      prompt = "Select Gherkio Environment:",
    }, function(choice)
      if not choice then return end
      local selected_env = choice == "Default (None)" and "" or choice
      M.resolve_accounts({ env = selected_env })
    end)
  end
end

-- Resolve accounts for selected environment
function M.resolve_accounts(state)
  local bufnr = vim.api.nvim_get_current_buf()
  local project_root = runner.find_project_root(bufnr)

  if state.env == "" then
    state.account = ""
    M.select_action(state)
    return
  end

  local accounts = runner.get_available_accounts(project_root, state.env)
  if #accounts == 0 then
    state.account = ""
    M.select_action(state)
  elseif #accounts == 1 then
    state.account = accounts[1]
    M.select_action(state)
  else
    -- Multiple accounts, show selector
    local account_choices = { "Default (None)" }
    for _, acc in ipairs(accounts) do
      table.insert(account_choices, acc)
    end

    ui_select(account_choices, {
      prompt = string.format("Select Gherkio Account for env '%s':", state.env),
    }, function(choice)
      if not choice then return end
      state.account = choice == "Default (None)" and "" or choice
      M.select_action(state)
    end)
  end
end

-- Action selector modal
function M.select_action(state)
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1

  local section = parser.detect_section(bufnr, cursor_line)
  local step_idx = parser.detect_step_index(bufnr, cursor_line)

  local verbose_status = verbose_override and "[x]" or "[ ]"
  local dry_run_status = dry_run_override and "[x]" or "[ ]"
  
  local items = {}
  if step_idx >= 0 then
    table.insert(items, { id = "run_cursor", label = string.format("Run Under Cursor (%s step %d)", section, step_idx) })
    table.insert(items, { id = "preview_request", label = string.format("Preview Current Step as cURL (%s step %d)", section, step_idx) })
    table.insert(items, { id = "copy_curl", label = string.format("Copy Current Step as cURL (%s step %d)", section, step_idx) })
  end
  table.insert(items, { id = "run_section", label = string.format("Run Current Section ('%s')", section) })
  table.insert(items, { id = "run_until", label = "Run Until Step..." })
  table.insert(items, { id = "run_all", label = "Run All Steps (Full Scenario)" })
  table.insert(items, { id = "paste_dsl", label = "Paste cURL as DSL" })
  table.insert(items, { id = "toggle_verbose", label = verbose_status .. " Verbose output mode" })
  table.insert(items, { id = "toggle_dry_run", label = dry_run_status .. " Dry Run mode (preview request without HTTP call)" })

  local item_labels = {}
  local item_map = {}
  for _, item in ipairs(items) do
    table.insert(item_labels, item.label)
    item_map[item.label] = item
  end

  local prompt_suffix = ""
  if state.env ~= "" then
    prompt_suffix = " (env: " .. state.env
    if state.account ~= "" then
      prompt_suffix = prompt_suffix .. ", account: " .. state.account
    end
    prompt_suffix = prompt_suffix .. ")"
  end

  ui_select(item_labels, {
    prompt = "Select Gherkio Action" .. prompt_suffix .. ":",
  }, function(choice)
    if not choice then return end
    local action = item_map[choice]
    if not action then return end

    if action.id == "run_cursor" then
      runner.run_test({
        env = state.env,
        account = state.account,
        verbose = verbose_override,
        dry_run = dry_run_override,
        line = cursor_line
      })
    elseif action.id == "run_section" then
      runner.run_test({
        env = state.env,
        account = state.account,
        verbose = verbose_override,
        dry_run = dry_run_override,
        section = section
      })
    elseif action.id == "run_until" then
      M.prompt_run_until(state, section)
    elseif action.id == "run_all" then
      runner.run_test({
        env = state.env,
        account = state.account,
        verbose = verbose_override,
        dry_run = dry_run_override
      })
    elseif action.id == "preview_request" then
      runner.copy_as_curl({
        env = state.env,
        step = step_idx
      }, function(curl_cmd)
        clipboard.show_preview_float(curl_cmd)
      end)
    elseif action.id == "copy_curl" then
      runner.copy_as_curl({
        env = state.env,
        step = step_idx
      }, function(curl_cmd)
        clipboard.set_contents(curl_cmd)
        vim.notify("cURL command copied to clipboard!", vim.log.levels.INFO)
      end)
    elseif action.id == "paste_dsl" then
      M.trigger_paste_dsl()
    elseif action.id == "toggle_verbose" then
      verbose_override = not verbose_override
      M.select_action(state) -- Redraw menu
    elseif action.id == "toggle_dry_run" then
      dry_run_override = not dry_run_override
      M.select_action(state) -- Redraw menu
    end
  end)
end

-- Helper: Prompt for step count inside Run Until flow
function M.prompt_run_until(state, section)
  local bufnr = vim.api.nvim_get_current_buf()
  local steps = parser.get_steps_in_section(bufnr, section)
  if #steps == 0 then
    vim.notify(string.format("Section '%s' contains no steps.", section), vim.log.levels.WARN)
    return
  end

  vim.fn.inputsave()
  local input = vim.fn.input(string.format("Run until step in '%s' (0 to %d): ", section, #steps - 1))
  vim.fn.inputrestore()

  if input == "" then return end
  local step_num = tonumber(input)
  if not step_num or step_num < 0 or step_num >= #steps then
    vim.notify(string.format("Invalid step number. Must be between 0 and %d.", #steps - 1), vim.log.levels.ERROR)
    return
  end

  runner.run_test({
    env = state.env,
    account = state.account,
    verbose = verbose_override,
    dry_run = dry_run_override,
    until_target = string.format("%s:%d", section, step_num)
  })
end

-- Helper: Trigger clipboard copy and conversion cascades for Paste cURL flow
function M.trigger_paste_dsl()
  -- Cascade system clipboard -> unnamed register -> input prompt
  local curl_string = vim.fn.getreg("+")
  if not curl_string or not curl_string:match("^%s*curl") then
    curl_string = vim.fn.getreg('"')
    if not curl_string or not curl_string:match("^%s*curl") then
      vim.fn.inputsave()
      curl_string = vim.fn.input("Paste cURL command: ")
      vim.fn.inputrestore()
    end
  end

  if not curl_string or curl_string == "" then
    vim.notify("No valid cURL command provided.", vim.log.levels.WARN)
    return
  end

  runner.paste_as_dsl(curl_string, function(yaml_dsl)
    -- Insert generated DSL at cursor line
    local lines = {}
    for line in yaml_dsl:gmatch("[^\r\n]+") do
      table.insert(lines, line)
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_idx = cursor[1] -- 1-indexed

    vim.api.nvim_buf_set_lines(0, line_idx, line_idx, false, lines)
    vim.notify("cURL command parsed and pasted as DSL!", vim.log.levels.INFO)
  end)
end

return M
