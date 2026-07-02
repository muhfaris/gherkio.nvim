local parser = require("gherkio.core.parser")
local config = require("gherkio.config")
local env = require("gherkio.core.env")

local M = {}

M.active_job = nil

-- Safe async run wrapper with fallback for older Neovim versions
local function run_command_async(cmd, on_exit, on_stdout)
  if vim.system then
    return vim.system(cmd, { text = true, stdout = on_stdout, stderr = on_stdout }, on_exit)
  else
    local job_id = vim.fn.jobstart(cmd, {
      stdout_buffered = false,
      stderr_buffered = false,
      on_stdout = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line ~= "" then
              on_stdout(nil, line .. "\n")
            end
          end
        end
      end,
      on_stderr = function(_, data)
        if data then
          for _, line in ipairs(data) do
            if line ~= "" then
              on_stdout(nil, line .. "\n")
            end
          end
        end
      end,
      on_exit = function(_, exit_code)
        on_exit({ code = exit_code })
      end
    })
    return {
      kill = function(_, sig)
        vim.fn.jobstop(job_id)
      end
    }
  end
end

-- Define gutter signs for inline pass/fail feedback
local signs_defined = false
local function ensure_signs()
  if not signs_defined then
    signs_defined = true
    vim.fn.sign_define("GherkioPass", { text = "✔", texthl = "String" })
    vim.fn.sign_define("GherkioFail", { text = "✗", texthl = "ErrorMsg" })
  end
end

-- Clear all Gherkio signs from a buffer
local function clear_signs(bufnr)
  vim.fn.sign_unplace("gherkio", { buffer = bufnr })
end

-- Place pass/fail signs on step lines
local function place_signs(bufnr, step_results)
  ensure_signs()
  clear_signs(bufnr)
  for key, passed in pairs(step_results) do
    local section, step_idx = key:match("^(.*):(-?%d+)$")
    if section and step_idx then
      step_idx = tonumber(step_idx)
      local steps = parser.get_steps_in_section(bufnr, section)
      if steps and steps[step_idx + 1] then
        local line = steps[step_idx + 1] + 1 -- 1-indexed
        local sign_name = passed and "GherkioPass" or "GherkioFail"
        vim.fn.sign_place(0, "gherkio", sign_name, bufnr, { lnum = line })
      end
    end
  end
end

-- Extract assertion path from error message like "body.statusCode: expected 200, got 400"
local function extract_assertion_path(err_msg)
  local path = err_msg:match("^%s*(.-):%s")
  if path then
    path = path:gsub("^%s*(.-)%s*$", "%1")
  end
  return path
end

-- Terminate active running background job
function M.stop_active_job()
  if M.active_job then
    M.active_job:kill(15) -- SIGTERM
    M.active_job = nil
    vim.notify("Gherkio execution cancelled.", vim.log.levels.INFO)
    return true
  end
  return false
end

-- Repeat the last executed run target (automatically updates cursor line if step-level execution)
function M.run_last()
  if not M.last_run_opts then
    vim.notify("No Gherkio test has been run yet in this session.", vim.log.levels.WARN)
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local project_root = env.get_project_root(current_buf)
  if not project_root then
    vim.notify("No Gherkio project found.", vim.log.levels.WARN)
    return
  end

  local opts = vim.deepcopy(M.last_run_opts)
  opts.bufnr = current_buf

  -- If the last run was specific to a cursor line, update it to the current cursor line
  if opts.line then
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
    opts.line = cursor_line
  end

  M.run_test(opts)
end

-- Asynchronous test runner mapping failures to quickfix
function M.run_test(opts)
  -- Cache the last executed test options for repeating
  M.last_run_opts = opts

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local project_root = env.get_project_root(bufnr)
  if not project_root then
    vim.notify("No Gherkio project found. Run `gherkio init` first.", vim.log.levels.WARN)
    return
  end

  -- Silently save buffer if modified
  if vim.bo[bufnr].modified then
    vim.cmd("silent write")
  end

  local full_path = vim.api.nvim_buf_get_name(bufnr)
  local relative_path = full_path:sub(#project_root + 2)

  -- Terminate any previous running job
  if M.active_job then
    M.active_job:kill(15)
  end

  -- Clear old gutter signs from previous run
  clear_signs(bufnr)

  local cmd = { "gherkio", "run", relative_path }

  if opts.env and opts.env ~= "" then
    table.insert(cmd, "--env")
    table.insert(cmd, opts.env)
  end
  if opts.account and opts.account ~= "" then
    table.insert(cmd, "--account")
    table.insert(cmd, opts.account)
  end
  local is_verbose = true
  if opts.verbose ~= nil then
    is_verbose = opts.verbose
  else
    is_verbose = config.get("verbose", true)
  end

  if is_verbose then
    table.insert(cmd, "-v")
  end
  if opts.dry_run then
    table.insert(cmd, "--dry-run")
    vim.notify("gherkio " .. table.concat(cmd, " "), vim.log.levels.INFO)
  end

  if opts.line and opts.line >= 0 then
    table.insert(cmd, "--line")
    table.insert(cmd, tostring(opts.line + 1))
  elseif opts.step and opts.step >= 0 then
    table.insert(cmd, "--step")
    table.insert(cmd, tostring(opts.step))
    if opts.section and opts.section ~= "" then
      table.insert(cmd, "--section")
      table.insert(cmd, opts.section)
    end
  elseif opts.until_target and opts.until_target ~= "" then
    table.insert(cmd, "--until")
    table.insert(cmd, opts.until_target)
  end

  -- Status update notification
  local display_target = "Scenario"
  if opts.line then
    display_target = "Step at line " .. (opts.line + 1)
  elseif opts.section then
    display_target = "Section '" .. opts.section .. "'"
    if opts.step then
      display_target = display_target .. " Step " .. opts.step
    end
  elseif opts.until_target then
    display_target = "Until '" .. opts.until_target .. "'"
  end

  local notif_cfg = config.get("notifications")
  local show_notif = true
  if notif_cfg == false then
    show_notif = false
  elseif type(notif_cfg) == "table" and notif_cfg.enabled == false then
    show_notif = false
  end

  local progress_notif = nil
  local total_steps = nil
  local completed_steps = 0
  if show_notif then
    progress_notif = vim.notify(string.format("Running Gherkio %s...", display_target), vim.log.levels.INFO, { title = "Gherkio" })
  end

  local output = {}

  -- Show streaming results window immediately (loading state)
  local results_mod = require("gherkio.core.results")
  results_mod.show_streaming(display_target)

  M.active_job = run_command_async(cmd, vim.schedule_wrap(function(obj)
    M.active_job = nil
    local passed = obj.code == 0

    if progress_notif then
      vim.notify("", vim.log.levels.INFO, { title = "Gherkio", hide = true })
    end

    M.process_run_results(bufnr, relative_path, passed, output)
  end), vim.schedule_wrap(function(err, data)
    if data then
      for line in data:gmatch("[^\r\n]+") do
        table.insert(output, line)
        results_mod.append_streaming_line(line)
        -- Track progress: detect step headers like "1. POST /login"
        local clean = line:gsub("%[%d+m", "")
        local step_num = clean:match("^(%d+)%.%s")
        if step_num then
          completed_steps = tonumber(step_num)
          if not total_steps or completed_steps > total_steps then
            total_steps = completed_steps
          end
          if progress_notif and total_steps then
            progress_notif = vim.notify(string.format("Executing step %d/%d...", completed_steps, total_steps), vim.log.levels.INFO, { title = "Gherkio", replace = progress_notif })
          end
        end
      end
    end
  end))
end

-- Process run results to extract failures and build quickfix entries
function M.process_run_results(bufnr, filepath, passed, output)
  local is_single_step = false
  local target_section = nil
  local target_step_idx = nil

  if M.last_run_opts then
    if M.last_run_opts.line and M.last_run_opts.line >= 0 then
      is_single_step = true
      target_section = parser.detect_section(bufnr, M.last_run_opts.line)
      target_step_idx = parser.detect_step_index(bufnr, M.last_run_opts.line)
    elseif M.last_run_opts.step and M.last_run_opts.step >= 0 then
      is_single_step = true
      target_section = M.last_run_opts.section or "steps"
      target_step_idx = M.last_run_opts.step
    end
  end

  local qf_entries = {}
  -- Track pass/fail per step for gutter signs: key = "section:step_idx", value = true/false
  local step_results = {}

  if is_single_step and target_section and target_step_idx then
    step_results[target_section .. ":" .. target_step_idx] = passed
  end

  local function add_qf_entry(text, line_num)
    table.insert(qf_entries, {
      bufnr = bufnr,
      lnum = line_num or 1,
      text = text,
      type = "E"
    })
  end

  -- Capture assertions or engine errors
  local current_section = "steps"
  local current_step_idx = -1

  for _, line in ipairs(output) do
    local clean_line = line:gsub("%[%d+m", "") -- Strip ANSI escape codes
    local trimmed = clean_line:gsub("^%s+", "")

    -- Detect active section changes in stdout (e.g., ── Setup ──, ── Steps ──, ── Teardown ──)
    local sec_header = clean_line:match("^──%s+([%a%s]+)%s+──$")
    if sec_header then
      current_section = sec_header:lower()
      current_step_idx = -1
    end

    -- Match step indicators in Gherkio print output: e.g. "1. GET /api", "├ GET /api", etc.
    local step_num_match = trimmed:match("^(%d+)%.%s+(.*)")
    if step_num_match then
      local parsed_idx = tonumber(step_num_match) - 1
      if is_single_step then
        -- In a single-step run, the first step index in CLI output (parsed_idx == 0)
        -- corresponds to our target step. Any other parsed steps are nested sub-steps.
        if parsed_idx == 0 then
          current_section = target_section
          current_step_idx = target_step_idx
          step_results[current_section .. ":" .. current_step_idx] = true
        else
          current_step_idx = -1
        end
      else
        current_step_idx = parsed_idx
        step_results[current_section .. ":" .. current_step_idx] = true
      end
    end

    -- Detect step/assertion failure indicators
    if trimmed:match("^✗%s+(.*)") or trimmed:match("^Error:%s*(.*)") then
      local err_msg = trimmed:match("^✗%s+(.*)") or trimmed:match("^Error:%s*(.*)")
      local resolved_line = nil

      -- Mark step as failed for gutter sign
      if current_step_idx >= 0 then
        step_results[current_section .. ":" .. current_step_idx] = false
      end

      -- Resolve assertion-level line within the step
      if current_step_idx >= 0 then
        local assertion_path = extract_assertion_path(err_msg)
        local range = parser.get_step_range(bufnr, current_section, current_step_idx)
        if range and assertion_path then
          resolved_line = parser.find_assertion_line(bufnr, assertion_path, range.start_line, range.end_line)
        end
        -- Fallback to step start line if assertion not found
        if not resolved_line then
          local steps = parser.get_steps_in_section(bufnr, current_section)
          if steps[current_step_idx + 1] then
            resolved_line = steps[current_step_idx + 1] + 1
          end
        end
      end

      add_qf_entry(string.format("[%s Step %d] %s", current_section, current_step_idx, err_msg), resolved_line)
    end
  end

  -- Clear and set quickfix list
  vim.fn.setqflist(qf_entries, "r")
  vim.fn.setqflist({}, "a", { title = "Gherkio Run Failures" })

  -- Place gutter signs for step pass/fail
  place_signs(bufnr, step_results)

  local win_cfg = config.get("results_window") or { auto_open = true }
  if win_cfg.auto_open then
    require("gherkio.core.results").finalize_streaming(output)
  end

  local notif_cfg = config.get("notifications")
  local show_notif = true
  if notif_cfg == false then
    show_notif = false
  elseif type(notif_cfg) == "table" and notif_cfg.enabled == false then
    show_notif = false
  end

  if passed then
    if show_notif then
      vim.notify("✓ Gherkio execution passed!", vim.log.levels.INFO)
    end
    if config.get("quickfix").auto_close then
      vim.cmd("cclose")
    end
  else
    if show_notif then
      vim.notify("✗ Gherkio execution failed! Check quickfix list.", vim.log.levels.ERROR)
    end
    if config.get("quickfix").auto_open and #qf_entries > 0 then
      vim.cmd("copen")
    end
  end
end


-- Convert step to cURL command
function M.copy_as_curl(opts, on_success)
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local project_root = env.get_project_root(bufnr)
  if not project_root then
    vim.notify("No Gherkio project found.", vim.log.levels.WARN)
    return
  end

  local full_path = vim.api.nvim_buf_get_name(bufnr)
  local relative_path = full_path:sub(#project_root + 2)

  local cmd = { "gherkio", "convert", "-r", relative_path }
  if opts.step and opts.step >= 0 then
    table.insert(cmd, "--step")
    table.insert(cmd, tostring(opts.step))
  end
  if opts.env and opts.env ~= "" then
    table.insert(cmd, "--env")
    table.insert(cmd, opts.env)
  end

  local output = {}
  local job = run_command_async(cmd, function(obj)
    local curl_cmd = table.concat(output, "\n")
    vim.schedule(function()
      if obj.code == 0 and curl_cmd ~= "" then
        on_success(curl_cmd)
      else
        vim.notify("Failed to convert step to cURL.", vim.log.levels.ERROR)
      end
    end)
  end, function(err, data)
    if data then
      table.insert(output, data)
    end
  end)
end

-- Convert cURL to Gherkio DSL YAML
function M.paste_as_dsl(curl_string, on_success)
  local cmd = { "gherkio", "convert", "--step-only" }
  local output = {}

  if vim.system then
    vim.system(cmd, { stdin = curl_string, text = true }, function(obj)
      vim.schedule(function()
        if obj.code == 0 then
          on_success(obj.stdout)
        else
          vim.notify("Failed to convert cURL to DSL. Make sure cURL syntax is valid.", vim.log.levels.ERROR)
        end
      end)
    end)
  else
    -- Fallback for older Neovim versions
    local temp_file = vim.fn.tempname()
    local f = io.open(temp_file, "w")
    if f then
      f:write(curl_string)
      f:close()
    end

    local shell_cmd = string.format("gherkio convert --step-only < %s", vim.fn.shellescape(temp_file))
    local dsl_output = vim.fn.system(shell_cmd)
    vim.fn.delete(temp_file)

    if vim.v.shell_error == 0 then
      on_success(dsl_output)
    else
      vim.notify("Failed to convert cURL to DSL. Make sure cURL syntax is valid.", vim.log.levels.ERROR)
    end
  end
end

return M
