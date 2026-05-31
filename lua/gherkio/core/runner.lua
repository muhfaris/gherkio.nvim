local parser = require("gherkio.core.parser")
local config = require("gherkio.config")

local M = {}

M.active_job = nil

-- Traverse up to find .gherkio/ directory
function M.find_project_root(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr or 0)
  local start_dir = ""
  if filepath ~= "" then
    start_dir = vim.fs.dirname(filepath)
  else
    start_dir = vim.fn.getcwd()
  end

  local match = vim.fs.find(".gherkio", { path = start_dir, upward = true, type = "directory" })
  if #match > 0 then
    return vim.fs.dirname(match[1])
  end

  -- Fallback: check current working directory
  if vim.fn.isdirectory(vim.fn.getcwd() .. "/.gherkio") == 1 then
    return vim.fn.getcwd()
  end

  return nil
end

-- Resolve available environments in .gherkio/environments/*.yaml
function M.get_available_envs(project_root)
  if not project_root then return {} end
  local envs_dir = project_root .. "/.gherkio/environments"
  if vim.fn.isdirectory(envs_dir) == 0 then
    return {}
  end

  local files = vim.fn.globpath(envs_dir, "*.yaml", false, true)
  local envs = {}
  for _, file in ipairs(files) do
    local filename = vim.fs.basename(file)
    local env_name = filename:match("^(.*)%.yaml$")
    if env_name then
      table.insert(envs, env_name)
    end
  end
  table.sort(envs)
  return envs
end

-- Parse credentials file to extract accounts indented under accounts: key
local function parse_yaml_accounts(filepath)
  local f = io.open(filepath, "r")
  if not f then return {} end
  local accounts = {}
  local in_accounts = false
  local accounts_indent = 0
  local name_indent = nil

  for line in f:lines() do
    -- Ignore comments
    if not line:match("^%s*#") then
      local indent, key = line:match("^(%s*)([%w_-]+)%s*:")
      if key then
        local indent_len = #indent
        if key == "accounts" then
          in_accounts = true
          accounts_indent = indent_len
          name_indent = nil
        elseif in_accounts then
          if indent_len <= accounts_indent then
            in_accounts = false
          else
            if not name_indent then
              name_indent = indent_len
            end
            if indent_len == name_indent then
              table.insert(accounts, key)
            end
          end
        end
      end
    end
  end
  f:close()
  return accounts
end

-- Resolve available accounts in .gherkio/credentials/<env>.yaml
function M.get_available_accounts(project_root, env)
  if not project_root or not env or env == "" then return {} end
  local creds_file = string.format("%s/.gherkio/credentials/%s.yaml", project_root, env)
  if vim.fn.filereadable(creds_file) == 0 then
    -- Fallback: check without extension
    creds_file = string.format("%s/.gherkio/credentials/%s.yml", project_root, env)
    if vim.fn.filereadable(creds_file) == 0 then
      return {}
    end
  end

  return parse_yaml_accounts(creds_file)
end

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
  local project_root = M.find_project_root(current_buf)
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
  local project_root = M.find_project_root(bufnr)
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

  local cmd = { "gherkio", "run", relative_path }

  if opts.env and opts.env ~= "" then
    table.insert(cmd, "--env")
    table.insert(cmd, opts.env)
  end
  if opts.account and opts.account ~= "" then
    table.insert(cmd, "--account")
    table.insert(cmd, opts.account)
  end
  if opts.verbose then
    table.insert(cmd, "-v")
  end
  if opts.dry_run then
    table.insert(cmd, "--dry-run")
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

  vim.notify(string.format("Running Gherkio %s...", display_target), vim.log.levels.INFO)

  local output = {}
  M.active_job = run_command_async(cmd, function(obj)
    M.active_job = nil
    local passed = obj.code == 0

    vim.schedule(function()
      M.process_run_results(bufnr, relative_path, passed, output)
    end)
  end, function(err, data)
    if data then
      for line in data:gmatch("[^\r\n]+") do
        table.insert(output, line)
      end
    end
  end)
end

-- Process run results to extract failures and build quickfix entries
function M.process_run_results(bufnr, filepath, passed, output)
  local qf_entries = {}
  local steps_boundaries = parser.get_section_boundaries(bufnr)

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

    -- Detect active section changes in stdout
    if trimmed:match("^── Setup ──") then
      current_section = "setup"
    elseif trimmed:match("^── Teardown ──") then
      current_section = "teardown"
    end

    -- Match step indicators in Gherkio print output: e.g. "1. GET /api", "├ GET /api", etc.
    local step_num_match = trimmed:match("^(%d+)%.%s+(.*)")
    if step_num_match then
      current_step_idx = tonumber(step_num_match) - 1
    end

    -- Detect step/assertion failure indicators
    if trimmed:match("^✗%s+(.*)") or trimmed:match("^Error:%s*(.*)") then
      local err_msg = trimmed:match("^✗%s+(.*)") or trimmed:match("^Error:%s*(.*)")
      local resolved_line = nil

      -- Try mapping the index to line using our parser
      if current_step_idx >= 0 then
        local steps = parser.get_steps_in_section(bufnr, current_section)
        if steps[current_step_idx + 1] then
          resolved_line = steps[current_step_idx + 1] + 1 -- 1-indexed for quickfix
        end
      end

      -- If we couldn't resolve the step line, fall back to matching "line: N" in the output
      if not resolved_line then
        local line_match = err_msg:match("%(line:%s*(%d+)%)")
        if line_match then
          resolved_line = tonumber(line_match)
        end
      end

      add_qf_entry(string.format("[%s Step %d] %s", current_section, current_step_idx, err_msg), resolved_line)
    end
  end

  -- Clear and set quickfix list
  vim.fn.setqflist(qf_entries, "r")
  vim.fn.setqflist({}, "a", { title = "Gherkio Run Failures" })

  local win_cfg = config.get("results_window") or { auto_open = true }
  if win_cfg.auto_open then
    M.show_results_float(output)
  end

  if passed then
    vim.notify("✓ Gherkio execution passed!", vim.log.levels.INFO)
    if config.get("quickfix").auto_close then
      vim.cmd("cclose")
    end
  else
    vim.notify("✗ Gherkio execution failed! Check quickfix list.", vim.log.levels.ERROR)
    if config.get("quickfix").auto_open and #qf_entries > 0 then
      vim.cmd("copen")
    end
  end
end

-- Custom folding expression for gherkio results output
function M.gherkio_foldexpr(lnum)
  local line = vim.fn.getline(lnum)

  -- Section headers like ── Setup ──, ── Teardown ──, ── Resolved Variables ──
  if line:match("^──%s+[%a%s]+%s+──") then
    return ">1"
  end

  -- Step headers like 1. GET /login, 12. POST /user
  if line:match("^%d+%.%s") or line:match("^▼%s") then
    return ">2"
  end

  -- Dash separator lines closing a step fold
  if line:match("^───+$") then
    return "1"
  end

  -- Summary section resets at the bottom
  if line:match("^[✓✗]%s+[PASTFAIL]+%s+.*") or line:match("^%d+%s+passed,%s+%d+%s+failed") or line:match("^Duration:") then
    return "0"
  end

  return "="
end

_G.gherkio_foldexpr = M.gherkio_foldexpr

-- Open a beautiful floating or split window showing Gherkio test execution output
function M.show_results(output_lines)
  local win_cfg = config.get("results_window") or {
    auto_open = true,
    layout = "vsplit",
    width = 0.35,
    height = 0.3,
    border = "rounded",
  }

  local layout = win_cfg.layout or "vsplit"

  -- Clean ANSI escape codes from output lines
  local cleaned_lines = {}
  for _, line in ipairs(output_lines) do
    local clean = line:gsub("\27%[[%d;]*%a", "") -- Strip ANSI escape codes
    table.insert(cleaned_lines, clean)
  end

  -- Find or create buffer
  local bufnr = nil
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_option(buf, "filetype") == "gherkio-results" then
      bufnr = buf
      break
    end
  end

  if not bufnr then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(bufnr, "filetype", "gherkio-results")
    vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
    vim.api.nvim_buf_set_option(bufnr, "bufhidden", "hide")
    vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
  end

  -- Set folding options on buffer
  vim.api.nvim_buf_set_option(bufnr, "foldmethod", "expr")
  vim.api.nvim_buf_set_option(bufnr, "foldexpr", "v:lua.gherkio_foldexpr(v:lnum)")

  -- Update buffer contents
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_option(bufnr, "readonly", false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, cleaned_lines)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  vim.api.nvim_buf_set_option(bufnr, "readonly", true)

  -- Find or create window based on layout type
  local win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == bufnr then
      win = w
      break
    end
  end

  if layout == "vsplit" then
    if not win then
      vim.cmd("botright vsplit")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, bufnr)
    end
    local width = math.floor(vim.o.columns * (win_cfg.width or 0.35))
    if width < 30 then width = 30 end
    vim.api.nvim_win_set_width(win, width)

  elseif layout == "split" then
    if not win then
      vim.cmd("botright split")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, bufnr)
    end
    local height = math.floor(vim.o.lines * (win_cfg.height or 0.3))
    if height < 5 then height = 5 end
    vim.api.nvim_win_set_height(win, height)

  else -- layout == "float"
    local total_cols = vim.o.columns
    local total_lines = vim.o.lines
    -- Use layout-specific sizes, default to 0.8 / 0.6 if default split values are passed
    local width_ratio = win_cfg.width == 0.35 and 0.8 or (win_cfg.width or 0.8)
    local height_ratio = win_cfg.height == 0.3 and 0.6 or (win_cfg.height or 0.6)
    
    local width = math.floor(total_cols * width_ratio)
    local height = math.floor(total_lines * height_ratio)

    if width < 30 then width = 30 end
    if height < 5 then height = 5 end

    local row = math.floor((total_lines - height) / 2)
    local col = math.floor((total_cols - width) / 2)

    local opts = {
      relative = "editor",
      row = row,
      col = col,
      width = width,
      height = height,
      style = "minimal",
      border = win_cfg.border or "rounded",
      title = " Gherkio Test Run Output ",
      title_pos = "center",
    }

    if win then
      -- If float window already exists, update config
      vim.api.nvim_win_set_config(win, opts)
    else
      win = vim.api.nvim_open_win(bufnr, true, opts)
    end
  end

  -- Apply window options
  vim.api.nvim_win_set_option(win, "foldlevel", 99)

  -- Map q, Esc, CR to close the window
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, silent = true, nowait = true })
  if layout == "float" then
    vim.keymap.set("n", "<CR>", close, { buffer = bufnr, silent = true, nowait = true })
  end
end

M.show_results_float = M.show_results

-- Convert step to cURL command
function M.copy_as_curl(opts, on_success)
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local project_root = M.find_project_root(bufnr)
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
