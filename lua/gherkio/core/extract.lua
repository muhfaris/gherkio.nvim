local env = require("gherkio.core.env")
local parser = require("gherkio.core.parser")

local M = {}

-- Extracts a step or visual selection into a standalone reusable scenario file
function M.extract_step(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local project_root = env.get_project_root(bufnr)
  if not project_root then
    vim.notify("Not inside a Gherkio project", vim.log.levels.ERROR)
    return
  end

  local start_line, end_line
  if opts.range then
    start_line = opts.range[1] - 1
    end_line = opts.range[2] - 1
  else
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
    local section = parser.detect_section(bufnr, cursor_line)
    local step_idx = parser.detect_step_index(bufnr, cursor_line)
    if step_idx < 0 then
      vim.notify("No step detected under cursor", vim.log.levels.WARN)
      return
    end

    local step_lines = parser.get_steps_in_section(bufnr, section)
    start_line = step_lines[step_idx + 1]
    if step_idx + 1 < #step_lines then
      end_line = step_lines[step_idx + 2] - 1
    else
      local boundaries = parser.get_section_boundaries(bufnr)
      end_line = boundaries[section] and boundaries[section].end_line or start_line
    end
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
  if #lines == 0 then
    vim.notify("No lines selected for extraction", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Target path relative to .gherkio/tests/ (e.g. shared/auth.yaml): " }, function(input)
    if not input or vim.trim(input) == "" then
      return
    end

    local rel_path = vim.trim(input)
    if not rel_path:match("%.ya?ml$") then
      rel_path = rel_path .. ".yaml"
    end

    local target_full_path = project_root .. "/.gherkio/tests/" .. rel_path
    local target_dir = vim.fs.dirname(target_full_path)
    if vim.fn.isdirectory(target_dir) == 0 then
      vim.fn.mkdir(target_dir, "p")
    end

    -- Infer scenario name from step name or filename
    local scenario_name = vim.fs.basename(rel_path):gsub("%.ya?ml$", "")
    for _, line in ipairs(lines) do
      local name_match = line:match("name:%s*(.+)$")
      if name_match then
        scenario_name = vim.trim(name_match):gsub("^['\"]", ""):gsub("['\"]$", "")
        break
      end
    end

    -- Format target content
    local content_lines = {
      "scenario: " .. scenario_name,
      "steps:",
    }
    for _, line in ipairs(lines) do
      table.insert(content_lines, line)
    end

    local f = io.open(target_full_path, "w")
    if not f then
      vim.notify("Failed to write to " .. target_full_path, vim.log.levels.ERROR)
      return
    end
    f:write(table.concat(content_lines, "\n") .. "\n")
    f:close()

    -- Replace extracted block with use step
    local base_indent = lines[1]:match("^(%s*)") or "  "
    local replacement = {
      base_indent .. "- use: " .. rel_path,
    }
    vim.api.nvim_buf_set_lines(bufnr, start_line, end_line + 1, false, replacement)
    vim.notify("Extracted to .gherkio/tests/" .. rel_path, vim.log.levels.INFO)
  end)
end

return M
