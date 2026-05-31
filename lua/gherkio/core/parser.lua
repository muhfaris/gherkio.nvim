local M = {}

-- Scan all lines to find the boundaries of the top-level sections: setup, steps, teardown
-- Returns a map of section_name -> { start_line = N, end_line = M } (0-indexed)
function M.get_section_boundaries(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local sections = {}
  local ordered = {}

  for i, line in ipairs(lines) do
    local trimmed = line:gsub("^%s+", "")
    if not line:match("^%s*#") then
      if trimmed:match("^setup%s*:") then
        table.insert(ordered, { name = "setup", line = i - 1 })
      elseif trimmed:match("^steps%s*:") then
        table.insert(ordered, { name = "steps", line = i - 1 })
      elseif trimmed:match("^teardown%s*:") then
        table.insert(ordered, { name = "teardown", line = i - 1 })
      end
    end
  end

  -- Sort by line number
  table.sort(ordered, function(a, b) return a.line < b.line end)

  for idx, sec in ipairs(ordered) do
    local end_line = #lines - 1
    if idx < #ordered then
      end_line = ordered[idx + 1].line - 1
    end
    sections[sec.name] = {
      start_line = sec.line,
      end_line = end_line
    }
  end

  return sections
end

-- Detects which section contains the cursor_line (0-indexed)
function M.detect_section(bufnr, cursor_line)
  local boundaries = M.get_section_boundaries(bufnr)
  for name, bound in pairs(boundaries) do
    if cursor_line >= bound.start_line and cursor_line <= bound.end_line then
      return name
    end
  end
  return "steps" -- Default fallback
end

-- Gets start lines of all steps in a section (0-indexed)
function M.get_steps_in_section(bufnr, section)
  local boundaries = M.get_section_boundaries(bufnr)
  local bound = boundaries[section]
  if not bound then
    return {}
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, bound.start_line + 1, bound.end_line + 1, false)
  local step_lines = {}

  for i, line in ipairs(lines) do
    local absolute_line = bound.start_line + i -- 0-indexed
    local trimmed = line:gsub("^%s+", "")
    -- Step begins with a list item dash: e.g. "- request:" or "- use:"
    if trimmed:match("^-%s+") and not line:match("^%s*#") then
      table.insert(step_lines, absolute_line)
    end
  end

  return step_lines
end

-- Resolves the step index (0-indexed) containing the cursor_line
function M.detect_step_index(bufnr, cursor_line)
  local section = M.detect_section(bufnr, cursor_line)
  local steps = M.get_steps_in_section(bufnr, section)
  if #steps == 0 then
    return -1
  end

  -- If cursor is before the first step, default to step 0
  if cursor_line < steps[1] then
    return 0
  end

  for idx, step_start in ipairs(steps) do
    local next_step_start = (idx < #steps) and steps[idx + 1] or math.huge
    if cursor_line >= step_start and cursor_line < next_step_start then
      return idx - 1 -- 0-indexed index
    end
  end

  return #steps - 1
end

-- Scan the buffer for scenario title
function M.detect_scenario_name(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, line in ipairs(lines) do
    local match = line:match("^scenario%s*:%s*(.*)")
    if match then
      return vim.trim(match):gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", '%1')
    end
  end
  return "Unnamed Scenario"
end

-- Scan buffer to check if it references $accounts
function M.references_accounts(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, line in ipairs(lines) do
    if line:match("%$accounts%.") then
      return true
    end
  end
  return false
end

return M
