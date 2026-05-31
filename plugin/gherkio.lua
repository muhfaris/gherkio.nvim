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

  if sub == "paste" then
    gherkio.paste_dsl()
    return
  end

  if sub == "run" then
    local parser = require("gherkio.core.parser")
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1

    local verbose = false
    local dry_run = false
    local target = args[2] or ""
    local target_num = args[3] or ""

    -- Parse verbose and dry_run flags anywhere in args
    for _, arg in ipairs(args) do
      if arg == "-v" or arg == "--verbose" then
        verbose = true
      elseif arg == "--dry-run" then
        dry_run = true
      end
    end

    if target == "all" then
      gherkio.run_test({ verbose = verbose, dry_run = dry_run })
    elseif target == "section" then
      local sec = parser.detect_section(bufnr, cursor_line)
      gherkio.run_test({ section = sec, verbose = verbose, dry_run = dry_run })
    elseif target == "until" then
      local sec = parser.detect_section(bufnr, cursor_line)
      local step_num = tonumber(target_num)
      if not step_num then
        vim.notify("Usage: :Gherkio run until <step_number>", vim.log.levels.ERROR)
        return
      end
      gherkio.run_test({ until_target = string.format("%s:%d", sec, step_num), verbose = verbose, dry_run = dry_run })
    else
      -- Defaults: run under cursor
      gherkio.run_test({ line = cursor_line, verbose = verbose, dry_run = dry_run })
    end
    return
  end

  vim.notify(string.format("Unknown Gherkio sub-command: '%s'", sub), vim.log.levels.ERROR)
end

-- Create global :Gherkio user command with tab completion
vim.api.nvim_create_user_command("Gherkio", route_command, {
  nargs = "*",
  complete = function(arg_lead, cmd_line, cursor_pos)
    local subcmds = { "run", "copy", "paste", "stop", "health" }
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
      local run_choices = { "all", "section", "until", "-v", "--verbose", "--dry-run" }
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
