local env = require("gherkio.core.env")

local M = {}

-- Go to definition for `use:` imports or `$VARIABLE` references in Gherkio scenarios
function M.goto_definition()
  local bufnr = vim.api.nvim_get_current_buf()
  local project_root = env.get_project_root(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_idx = cursor[1] - 1
  local col_idx = cursor[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, line_idx, line_idx + 1, false)[1] or ""

  -- 1. Check if line is a `use:` reference
  local use_path = line:match("use:%s*([%w_%-./\\]+)")
  if use_path and project_root then
    if not use_path:match("%.ya?ml$") then
      use_path = use_path .. ".yaml"
    end
    -- Try relative to current buffer's directory first
    local current_file = vim.api.nvim_buf_get_name(bufnr)
    local candidate1 = vim.fs.dirname(current_file) .. "/" .. use_path
    local candidate2 = project_root .. "/.gherkio/tests/" .. use_path

    local target = nil
    if vim.fn.filereadable(candidate1) == 1 then
      target = candidate1
    elseif vim.fn.filereadable(candidate2) == 1 then
      target = candidate2
    end

    if target then
      vim.cmd("edit " .. vim.fn.fnameescape(target))
      return
    end
  end

  -- 2. Check if cursor is on a variable reference ($VAR or ${VAR})
  local word = vim.fn.expand("<cWORD>")
  local var_name = word:match("%$([%w_%-]+)") or word:match("%${([%w_%-]+)}")
  if not var_name then
    var_name = vim.fn.expand("<cword>")
  end

  if not var_name or var_name == "" then
    return
  end

  -- Search current buffer for variable declaration in save: or set:
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for idx, l in ipairs(lines) do
    if l:match("^%s*" .. vim.pesc(var_name) .. "%s*:") or l:match("^%s*-%s*" .. vim.pesc(var_name) .. "%s*:") then
      vim.api.nvim_win_set_cursor(0, { idx, 0 })
      vim.notify(string.format("Jumped to definition of $%s (line %d)", var_name, idx), vim.log.levels.INFO)
      return
    end
  end

  vim.notify(string.format("Definition for $%s not found in current buffer", var_name), vim.log.levels.WARN)
end

return M
