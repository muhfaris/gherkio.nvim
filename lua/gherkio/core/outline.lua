-- Static outline extraction: parse a Gherkio test YAML buffer into a reviewable
-- scenario structure WITHOUT running any test. Purely derived from the buffer
-- content (names, use refs, request method/URL, save vars, assertions).
--
-- Output shape:
-- {
--   scenario = "Complex Auth Flow",
--   sections = {
--     { name = "setup",   steps = { step, ... } },
--     { name = "steps",   steps = { ... } },
--     { name = "teardown",steps = { ... } },
--   },
--   totals = { steps = N, assertions = N, shared_refs = N, sections = N },
-- }
--
-- step = {
--   number   = N,             -- 1-based global step number across sections
--   name     = "..."|nil,     -- inline step name
--   use      = "..."|nil,     -- shared ref path for `use:` steps
--   request  = "POST /v2/x"|nil,
--   save     = { "token", ... },
--   asserts  = { "✓ status = 200", ... },   -- one-liners, raw file strings
--   line     = L,             -- 1-based line of the step header in the YAML buffer
-- }

local parser = require("gherkio.core.parser")

local M = {}

-- Detect whether a (dash-peeled) line starts a new sub-block, i.e. is one of
-- request:/expect:/save: (with any value). Avoids resetting state when the
-- current line is itself introducing the block we need to consume.
local function key_starts_block(content)
	local k = content:match("^([%w_%.%-]+)%s*:")
	return k == "request" or k == "expect" or k == "save"
end

-- Trim + strip surrounding quotes from a yaml scalar value
local function clean_value(raw)
  if not raw then return nil end
  local s = vim.trim(raw)
  if s == "" then return nil end
  s = s:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
  return s
end

-- Parse one line into "key: value" parts in the context of a step block.
-- Assumption (matches gherkio DSL): request block uses `request:` sub-map with
-- `method:` and `url:`; assertions live under `expect:` (list or nested);
-- `save:` is a list or mapping of variable names; `use:` is a scalar ref.
local function parse_step_block(bufnr, start_line, end_line, number)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)

  local step = {
    number = number,
    name = nil,
    use = nil,
    request = nil,
    save = {},
    asserts = {},
    line = start_line + 1, -- 1-based for UI/jump
  }

  -- track which sub-block we're currently inside and its indentation depth
  local in_request, in_expect, in_save = false, false, false
  local request_indent, expect_indent, save_indent = nil, nil, nil
  local pending_assert = {}    -- accumulating an assertion line
  local pending_save = {}      -- accumulating a save line
  local last_assert_key = nil  -- last "key: value" seen inside expect:

  local function flush_assert()
    if not vim.tbl_isempty(pending_assert) then
      local rendered = table.concat(pending_assert, " ")
      rendered = rendered:gsub("%s+", " ")
      -- trim leading `:` if merging key with operator-only continuation
      rendered = rendered:gsub("^:%s*", "")
      table.insert(step.asserts, "✓ " .. rendered)
      pending_assert = {}
    end
  end

  local function flush_save()
    if not vim.tbl_isempty(pending_save) then
      table.insert(step.save, table.concat(pending_save, ""))
      pending_save = {}
    end
  end

  -- skip the step header itself ("- request:" style line) when scanning for
  -- nested keys; header's own indent defines step indent
  local step_indent = nil

  for i, line in ipairs(lines) do
    local raw = line
    local trimmed = raw:gsub("^%s+", "")
    local indent = #raw - #trimmed

    -- skip comments
    if trimmed:find("^#") then
      -- comment; ignore (but flush pending to avoid bleeding across block)
      flush_assert()
      flush_save()
    elseif trimmed == "" then
      -- blank: flush pending multi-line values
      flush_assert()
      flush_save()
    else
      -- establish step indent from the first non-comment content line ("-" list)
      if not step_indent then
        step_indent = indent
      end

      -- is this line a peer key of the step, or nested deeper?
      -- NOTE: step lists start with "- name:" so the dash adds 2 chars; peel
      -- it off first so the key's true column is used consistently.
      local line_content = trimmed
      local content_offset = indent
      if line_content:match("^-%s") then
        line_content = line_content:match("^-%s+(.*)")
        content_offset = indent + 2
      end
      local is_step_level = content_offset <= step_indent
      -- Actually the meaningful grouping is by content column: any line whose
      -- content_offset equals the dash-peeled header column (step_indent + 2)
      -- is a step peer; anything deeper nests. Compute the peer column once.
      local peer_column = step_indent + 2
      local is_peer = content_offset <= peer_column

      -- leaving a sub-block? Any peer-level key ends the previous block(s).
      -- Block openers close ALL other blocks and open their own (mutually
      -- exclusive sub-blocks per step); nested content then dispatches cleanly.
      if is_peer then
        in_request, in_expect, in_save = false, false, false
        request_indent, expect_indent, save_indent = nil, nil, nil
      end
      -- (the dispatched opener below re-establishes its own block state)

      -- (old is_step_level reset removed; is_peer above is authoritative)

      -- key extraction (after dash peel)
      local key, value = line_content:match("^([%w_%.%-]+)%s*:%s*(.*)$")
      if not key then
				key, value = line_content:match("^(%S+)%s*:%s*(.*)$")
			end

      if key and value then
        local key_ind = content_offset  -- use content column (dash peeled), not raw indent
        if key == "name" then
          step.name = clean_value(value)
        elseif key == "request" and value == "" then
          in_request = true
          request_indent = key_ind
        elseif key == "expect" and value == "" then
          in_expect = true
          expect_indent = key_ind
        elseif key == "save" and value == "" then
          in_save = true
          save_indent = key_ind
        elseif key == "use" then
          step.use = clean_value(value)
        else
          -- nested keys inside request/expect/save blocks
          if in_request and request_indent ~= nil and indent > request_indent then
            if key == "method" then
              step._method = clean_value(value)
            elseif key == "url" then
              step._url = clean_value(value)
            end
          elseif in_expect and expect_indent ~= nil and indent > expect_indent then
            -- assertion one-liners. Nested forms merge into the parent key:
            --   body.access_token:\n      matches: ^eyJ
            --   → "✓ body.access_token matches = ^eyJ"
            local v = clean_value(value)
            if v and v ~= "" then
              local rendered
              if last_assert_key then
                -- continuation of a nested key opened earlier:
                -- "body.access_token" continued by "matches: ^eyJ"
                -- → "body.access_token matches ^eyJ"
                rendered = last_assert_key .. " " .. key .. " " .. v
                last_assert_key = nil
              else
                rendered = key .. " = " .. v
              end
              table.insert(step.asserts, "✓ " .. rendered)
            else
              -- key with no value: value (or matcher) on following lines
              last_assert_key = key
            end
          elseif in_save and save_indent ~= nil and indent > save_indent then
            -- save: mapping key = var name; list item "- token" strips dash
            local content = trimmed
            if content:match("^-%s") then
              content = content:match("^-%s+(.*)")
            end
            local var_name = content:match("^([%w_%.%-]+)%s*(.*)$") or content
            if var_name and var_name ~= "" then
              table.insert(pending_save, var_name)
            end
            flush_save()
          end
        end
      else
        -- no "key: value" — continuation or plain list item
        if in_expect and expect_indent ~= nil and indent > expect_indent then
          table.insert(pending_assert, trimmed)
        elseif in_save and save_indent ~= nil and indent > save_indent then
          local content = trimmed
          if content:match("^-%s") then
            content = content:match("^-%s+(.*)")
          end
          if content and content ~= "" then
            table.insert(pending_save, content)
          end
        end
      end
    end
  end

  flush_assert()
  flush_save()

  -- finalize request display
  if step._method and step._url then
    step.request = string.format("%s %s", step._method, step._url)
  elseif step._url then
    step.request = step._url
  elseif step._method then
    step.request = step._method
  end
  step._method, step._url = nil, nil

  return step
end

--- Build the full outline data from a test YAML buffer.
--- @param bufnr integer buffer number of the YAML test file
--- @return table|nil outline data, nil when no sections/steps detected
function M.build(bufnr)
  local boundaries = parser.get_section_boundaries(bufnr)
  if vim.tbl_isempty(boundaries) then
    return nil
  end

  -- order sections canonically: setup, steps, teardown
  local order = { "setup", "steps", "teardown" }
  local sections = {}
  local totals = { steps = 0, assertions = 0, shared_refs = 0, sections = 0 }
  local global_step_number = 0

  for _, name in ipairs(order) do
    local bound = boundaries[name]
    if bound then
      totals.sections = totals.sections + 1
      local sec = { name = name, steps = {} }
      local step_lines = parser.get_steps_in_section(bufnr, name)

      for i, start_line in ipairs(step_lines) do
        local end_line
        if i < #step_lines then
          end_line = step_lines[i + 1] - 1
        else
          end_line = bound.end_line
        end

        global_step_number = global_step_number + 1
        local step = parse_step_block(bufnr, start_line, end_line, global_step_number)
        table.insert(sec.steps, step)
        totals.steps = totals.steps + 1
        totals.assertions = totals.assertions + #step.asserts
        if step.use then
          totals.shared_refs = totals.shared_refs + 1
        end
      end

      table.insert(sections, sec)
    end
  end

  return {
    scenario = parser.detect_scenario_name(bufnr),
    sections = sections,
    totals = totals,
  }
end

return M
