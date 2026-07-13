if vim.g.loaded_gherkio == 1 then
  return
end
vim.g.loaded_gherkio = 1

-- Router for command routing
local function route_command(opts)
  local gherkio = require("gherkio")
  local args = vim.split(opts.args or "", "%s+")
  local sub = args[1] or ""

  if sub == "" then
    gherkio.open_modal()
    return
  end

  if sub == "health" then
    vim.cmd("checkhealth gherkio")
    return
  end

  if sub == "stop" then
    gherkio.stop_job()
    return
  end

  if sub == "copy" then
    gherkio.copy_curl()
    return
  end

  if sub == "preview" then
    gherkio.preview_request()
    return
  end

  if sub == "paste" then
    gherkio.paste_dsl()
    return
  end

  if sub == "results" then
    gherkio.reopen_results()
    return
  end

  if sub == "report" then
    gherkio.open_report()
    return
  end

  if sub == "find" then
    gherkio.find_tests()
    return
  end

  if sub == "run" then
    local parser = require("gherkio.core.parser")
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1

    local dry_run = false
    local verbose = nil
    local target = args[2] or ""
    local target_num = args[3] or ""

    -- Parse flags anywhere in args
    for _, arg in ipairs(args) do
      if arg == "--dry-run" then
        dry_run = true
      elseif arg == "--verbose" then
        verbose = true
      elseif arg == "--no-verbose" then
        verbose = false
      end
    end

    if target == "project" then
      gherkio.run_test({ project = true, dry_run = dry_run, verbose = verbose })
    elseif target == "all" then
      gherkio.run_test({ dry_run = dry_run, verbose = verbose })
    elseif target == "section" then
      local sec = parser.detect_section(bufnr, cursor_line)
      gherkio.run_test({ section = sec, dry_run = dry_run, verbose = verbose })
    elseif target == "until" then
      local sec = parser.detect_section(bufnr, cursor_line)
      local step_num = tonumber(target_num)
      if not step_num then
        vim.notify("Usage: :Gherkio run until <step_number>", vim.log.levels.ERROR)
        return
      end
      gherkio.run_test({ until_target = string.format("%s:%d", sec, step_num), dry_run = dry_run, verbose = verbose })
    elseif target ~= "" then
      local project_root = require("gherkio.core.env").get_project_root()
      local full_target_path = target
      if project_root and not target:match("^/") then
        if target:match("^tests/") then
          full_target_path = project_root .. "/.gherkio/" .. target
        elseif not target:match("^%.gherkio/") then
          full_target_path = project_root .. "/.gherkio/tests/" .. target
        else
          full_target_path = project_root .. "/" .. target
        end
      end
      gherkio.run_test({ file = full_target_path, dry_run = dry_run, verbose = verbose })
    else
      -- Defaults: run under cursor
      gherkio.run_test({ line = cursor_line, dry_run = dry_run, verbose = verbose })
    end
    return
  end

  vim.notify(string.format("Unknown Gherkio sub-command: '%s'", sub), vim.log.levels.ERROR)
end

-- Create global :Gherkio user command with tab completion
vim.api.nvim_create_user_command("Gherkio", route_command, {
  nargs = "*",
  complete = function(arg_lead, cmd_line, cursor_pos)
    local subcmds = { "run", "find", "preview", "copy", "paste", "stop", "health", "results", "report" }
    local args = vim.split(cmd_line, "%s+")
    
    -- Completing sub-command
    if #args <= 2 then
      local matches = {}
      for _, c in ipairs(subcmds) do
        if c:sub(1, #arg_lead) == arg_lead then
          table.insert(matches, c)
        end
      end
      return matches
    end

    -- Completing options inside 'run' sub-command
    if args[2] == "run" then
      local run_choices = { "all", "project", "section", "until", "--dry-run", "--verbose", "--no-verbose" }
      local project_root = require("gherkio.core.env").get_project_root()
      if project_root then
        local search_prefix = arg_lead
        if not search_prefix:match("^tests/") and not search_prefix:match("^%.gherkio/") then
          search_prefix = "tests/" .. search_prefix
        end
        local glob_path = project_root .. "/.gherkio/" .. search_prefix .. "*"
        local paths = vim.fn.glob(glob_path, false, true)
        for _, p in ipairs(paths) do
          local relative = p:sub(#project_root + 2)
          local short = relative:match("^%.gherkio/(.+)$") or relative
          table.insert(run_choices, short)
        end
      end

      local matches = {}
      for _, c in ipairs(run_choices) do
        if c:sub(1, #arg_lead) == arg_lead then
          table.insert(matches, c)
        end
      end
      return matches
    end

    return {}
  end
})
