local parser = require("gherkio.core.parser")
local runner = require("gherkio.core.runner")
local clipboard = require("gherkio.core.clipboard")
local config = require("gherkio.config")
local env = require("gherkio.core.env")

local M = {}

-- Local state to preserve dry-run override within modal session
local dry_run_override = nil

-- Stateful environment and account cache
local last_env = nil
local last_account = nil

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
  if not env.is_gherkio_project(bufnr) then
    vim.notify("No Gherkio project found. Run `gherkio init` first.", vim.log.levels.WARN)
    return
  end

  env.invalidate_cache()

  if dry_run_override == nil then
    dry_run_override = false
  end

  -- Get full context from gherkio CLI
  local ctx = env.get_context(bufnr)
  if not ctx then
    vim.notify("Failed to get environment context from gherkio.", vim.log.levels.ERROR)
    return
  end

  local env_count = #ctx.environments
  local auto = ctx.autoSelect

  -- Determine initial state based on auto-select hints and cache
  local initial_state = { env = "", account = "" }

  -- Check cache first for multi-env scenarios
  if env_count > 1 and last_env then
    -- Validate cached env still exists
    local env_exists = false
    for _, e in ipairs(ctx.environments) do
      if e.name == last_env then
        env_exists = true
        break
      end
    end

    if env_exists then
      initial_state.env = last_env
      -- Also restore account cache if valid
      if last_account then
        local accounts = ctx.accounts[last_env] or {}
        for _, acc in ipairs(accounts) do
          if acc == last_account then
            initial_state.account = last_account
            break
          end
        end
      end
    end
  end

  -- If no cached state, apply auto-select hints
  if initial_state.env == "" then
    if auto and auto.env and auto.env ~= "" then
      initial_state.env = auto.env
      initial_state.account = auto.account or ""
    end
  end

  -- Proceed to action selection
  if env_count == 0 then
    -- No environments, execute actions directly
    M.select_action({ env = "", account = "" })
  elseif initial_state.env == "" then
    -- Multi-env with no valid cache, prompt
    M.prompt_select_env(ctx)
  else
    -- Has env selected, proceed to action (auto-account already applied)
    M.select_action(initial_state)
  end
end

-- Prompt user to select an environment
function M.prompt_select_env(ctx, on_resolve)
  local env_choices = { "Default (None)" }
  for _, e in ipairs(ctx.environments) do
    table.insert(env_choices, e.name)
  end

  ui_select(env_choices, {
    prompt = "Select Gherkio Environment:",
  }, function(choice)
    if not choice then return end
    local selected_env = choice == "Default (None)" and "" or choice
    last_env = selected_env
    last_account = nil -- Reset account when env changes
    M.resolve_accounts({ env = selected_env, accounts = ctx.accounts }, on_resolve)
  end)
end

-- Resolve accounts for selected environment
function M.resolve_accounts(state, on_resolve)
  if state.env == "" then
    state.account = ""
    if on_resolve then
      on_resolve(state)
    else
      M.select_action(state)
    end
    return
  end

  local accounts = state.accounts and state.accounts[state.env] or {}
  if #accounts == 0 then
    state.account = ""
    if on_resolve then
      on_resolve(state)
    else
      M.select_action(state)
    end
  elseif #accounts == 1 then
    state.account = accounts[1]
    if on_resolve then
      on_resolve(state)
    else
      M.select_action(state)
    end
  else
    -- Multi-account: Check if we have a valid cached account
    if last_account ~= nil then
      local acc_exists = false
      for _, acc in ipairs(accounts) do
        if acc == last_account then
          acc_exists = true
          break
        end
      end
      if acc_exists then
        state.account = last_account
        if on_resolve then
          on_resolve(state)
        else
          M.select_action(state)
        end
        return
      end
    end

    -- No valid cached account, prompt for account
    M.prompt_select_account(state.env, accounts, on_resolve)
  end
end

-- Prompt user to select an account for a given environment
function M.prompt_select_account(env, accounts, on_resolve)
  local account_choices = { "Default (None)" }
  for _, acc in ipairs(accounts) do
    table.insert(account_choices, acc)
  end

  ui_select(account_choices, {
    prompt = string.format("Select Gherkio Account for env '%s':", env),
  }, function(choice)
    if not choice then return end
    local selected_acc = choice == "Default (None)" and "" or choice
    last_account = selected_acc
    local state = { env = env, account = selected_acc }
    if on_resolve then
      on_resolve(state)
    else
      M.select_action(state)
    end
  end)
end

-- Action selector modal
function M.select_action(state)
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1

  local section = parser.detect_section(bufnr, cursor_line)
  local step_idx = parser.detect_step_index(bufnr, cursor_line)

  local dry_run_status = dry_run_override and "[x]" or "[ ]"
  
  local items = {}
  if step_idx >= 0 then
    table.insert(items, { id = "run_cursor", label = string.format("🚀 Run Under Cursor (%s step %d)", section, step_idx) })
    table.insert(items, { id = "preview_request", label = string.format("🔍 Preview Current Step as cURL (%s step %d)", section, step_idx) })
    table.insert(items, { id = "copy_curl", label = string.format("📋 Copy Current Step as cURL (%s step %d)", section, step_idx) })
  end
  table.insert(items, { id = "run_section", label = string.format("⚡ Run Current Section ('%s')", section) })
  table.insert(items, { id = "run_until", label = "⏳ Run Until Step..." })
  table.insert(items, { id = "run_all", label = "🏃 Run All Steps (Full Scenario)" })
  table.insert(items, { id = "paste_dsl", label = "📥 Paste cURL as DSL" })
  table.insert(items, { id = "toggle_dry_run", label = dry_run_status .. " Dry Run mode (preview request without HTTP call)" })

  -- Configurable settings for switching environments and accounts inside the action picker
  local envs = env.get_available_envs(bufnr)
  if #envs > 1 then
    table.insert(items, { id = "change_env", label = string.format("⚙️ Change Environment (current: %s)", state.env == "" and "Default" or state.env) })
  end

  if state.env ~= "" then
    local accounts = env.get_available_accounts(bufnr, state.env)
    if #accounts > 1 then
      table.insert(items, { id = "change_account", label = string.format("👤 Change Account (current: %s)", state.account == "" and "Default" or state.account) })
    end
  end

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
        dry_run = dry_run_override,
        line = cursor_line
      })
    elseif action.id == "run_section" then
      runner.run_test({
        env = state.env,
        account = state.account,
        dry_run = dry_run_override,
        section = section
      })
    elseif action.id == "run_until" then
      M.prompt_run_until(state, section)
    elseif action.id == "run_all" then
      runner.run_test({
        env = state.env,
        account = state.account,
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
    elseif action.id == "toggle_dry_run" then
      dry_run_override = not dry_run_override
      M.select_action(state) -- Redraw menu
    elseif action.id == "change_env" then
      last_env = nil
      last_account = nil
      local ctx = env.get_context(bufnr)
      if ctx then
        M.prompt_select_env(ctx)
      end
    elseif action.id == "change_account" then
      last_account = nil
      -- Clear session file so saved vars from the old account don't bleed into the new one
      local proj_root = env.get_project_root(bufnr)
      if proj_root then
        local session_file = proj_root .. "/.gherkio/session.yaml"
        vim.fn.delete(session_file)
      end
      local accounts = env.get_available_accounts(bufnr, state.env)
      M.prompt_select_account(state.env, accounts)
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

-- Switch environment via picker (keybinding-friendly)
function M.switch_env()
  local bufnr = vim.api.nvim_get_current_buf()
  if not env.is_gherkio_project(bufnr) then
    vim.notify("No Gherkio project found.", vim.log.levels.WARN)
    return
  end
  env.invalidate_cache()
  last_env = nil
  last_account = nil
  -- Clear session file so saved vars from the old account/env don't bleed
  local proj_root = env.get_project_root(bufnr)
  if proj_root then
    local session_file = proj_root .. "/.gherkio/session.yaml"
    vim.fn.delete(session_file)
  end
  local ctx = env.get_context(bufnr)
  if ctx then
    M.prompt_select_env(ctx, function(state)
      local env_str = state.env ~= "" and state.env or "default"
      local acc_str = state.account ~= "" and state.account or "none"
      vim.notify(string.format("Gherkio: Active environment set to '%s' (account: '%s')", env_str, acc_str), vim.log.levels.INFO)
    end)
  end
end

-- Switch account for current environment via picker (keybinding-friendly)
function M.switch_account()
  local bufnr = vim.api.nvim_get_current_buf()
  if not env.is_gherkio_project(bufnr) then
    vim.notify("No Gherkio project found.", vim.log.levels.WARN)
    return
  end
  env.invalidate_cache()
  local effective_env = last_env or ""
  if effective_env == "" then
    -- Try auto-select
    local ctx = env.get_context(bufnr)
    if ctx and ctx.autoSelect and ctx.autoSelect.env then
      effective_env = ctx.autoSelect.env
    end
  end
  if effective_env == "" then
    vim.notify("No environment selected. Use :Gherkio or switch_env first.", vim.log.levels.WARN)
    return
  end
  last_account = nil
  local accounts = env.get_available_accounts(bufnr, effective_env)
  if #accounts <= 1 then
    vim.notify("Only one account available for '" .. effective_env .. "'.", vim.log.levels.INFO)
    return
  end
  M.prompt_select_account(effective_env, accounts, function(state)
    -- Clear session file so saved vars from the previous account (e.g. $email)
    -- don't bleed into the new account's run.
    local project_root = env.get_project_root(bufnr)
    if project_root then
      local session_file = project_root .. "/.gherkio/session.yaml"
      vim.fn.delete(session_file)
    end
    local acc_str = state.account ~= "" and state.account or "none"
    vim.notify(string.format("Gherkio: Active account set to '%s' for environment '%s'", acc_str, state.env), vim.log.levels.INFO)
  end)
end

-- Helper to ensure env and account are resolved (cached/auto-selected/prompted)
-- before running a test or action.
-- Calls callback(selected_env, selected_account) upon successful resolution.
function M.ensure_env_and_account(bufnr, callback)
  if not env.is_gherkio_project(bufnr) then
    vim.notify("No Gherkio project found. Run `gherkio init` first.", vim.log.levels.WARN)
    return
  end

  env.invalidate_cache()

  local ctx = env.get_context(bufnr)
  if not ctx then
    vim.notify("Failed to get environment context from gherkio.", vim.log.levels.ERROR)
    return
  end

  local env_count = ctx.environments and #ctx.environments or 0
  if env_count == 0 then
    callback("", "")
    return
  end

  -- Determine if we already have a valid environment (from cache or autoSelect)
  local resolved_env = nil

  if last_env then
    -- Validate cached env still exists
    for _, e in ipairs(ctx.environments or {}) do
      if e.name == last_env then
        resolved_env = last_env
        break
      end
    end
  end

  if not resolved_env and ctx.autoSelect and ctx.autoSelect.env and ctx.autoSelect.env ~= "" then
    -- Validate autoSelect env exists
    for _, e in ipairs(ctx.environments or {}) do
      if e.name == ctx.autoSelect.env then
        resolved_env = ctx.autoSelect.env
        break
      end
    end
  end

  -- Helper to resolve account once env is determined
  local function resolve_account(selected_env)
    if selected_env == "" then
      callback("", "")
      return
    end

    local accounts = ctx.accounts and ctx.accounts[selected_env] or {}
    if #accounts == 0 then
      callback(selected_env, "")
      return
    end

    if #accounts == 1 then
      callback(selected_env, accounts[1])
      return
    end

    -- Check cache
    if last_account then
      for _, acc in ipairs(accounts) do
        if acc == last_account then
          callback(selected_env, last_account)
          return
        end
      end
    end

    -- Check autoSelect account
    if ctx.autoSelect and ctx.autoSelect.env == selected_env and ctx.autoSelect.account and ctx.autoSelect.account ~= "" then
      for _, acc in ipairs(accounts) do
        if acc == ctx.autoSelect.account then
          callback(selected_env, ctx.autoSelect.account)
          return
        end
      end
    end

    -- If no valid cached or auto-selected account, prompt the user
    local account_choices = { "Default (None)" }
    for _, acc in ipairs(accounts) do
      table.insert(account_choices, acc)
    end

    ui_select(account_choices, {
      prompt = string.format("Select Gherkio Account for env '%s':", selected_env),
    }, function(choice)
      if not choice then return end -- Aborted by user
      local selected_acc = choice == "Default (None)" and "" or choice
      last_account = selected_acc
      callback(selected_env, selected_acc)
    end)
  end

  -- If env is already resolved, go straight to resolving account
  if resolved_env then
    resolve_account(resolved_env)
    return
  end

  -- Otherwise, prompt for env first
  local env_choices = { "Default (None)" }
  for _, e in ipairs(ctx.environments or {}) do
    table.insert(env_choices, e.name)
  end

  ui_select(env_choices, {
    prompt = "Select Gherkio Environment:",
  }, function(choice)
    if not choice then return end -- Aborted by user
    local selected_env = choice == "Default (None)" and "" or choice
    last_env = selected_env
    last_account = nil -- Reset account when env changes
    resolve_account(selected_env)
  end)
end

-- Get current cached environment and account state
function M.get_active_state()
  return {
    env = last_env or "",
    account = last_account or ""
  }
end

return M

