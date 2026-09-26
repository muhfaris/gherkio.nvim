-- Gherkio structured results viewer with tab navigation
-- Parses verbose CLI output and renders tab-based views

local config = require("gherkio.config")

local M = {}

-- Tab definitions (3-tab design)
local TABS = {
	{ key = "1", name = "All", id = "all" },
	{ key = "2", name = "Bodies", id = "bodies" },
	{ key = "3", name = "Failures", id = "failures" },
}

-- Map legacy tab ids to the new 3-tab design so previously cached state does not break
local TAB_ID_LEGACY = {
	full = "all",
	summary = "all",
	request = "bodies",
	response = "bodies",
	errors = "failures",
}
local function normalize_tab_id(id)
	return TAB_ID_LEGACY[id] or id
end

-- ── State ──────────────────────────────────────────────────────────
local state = nil -- nil | { data, active_tab, bufnr, run_meta, expanded = set, line_map = table }

-- Default cap on rendered body lines before an expand marker is shown
local DEFAULT_MAX_BODY_LINES = 200

-- Forward declaration so helpers above can re-render via switch_tab
local switch_tab
local prettify_json  -- forward declaration (defined below prettify helpers)

-- ── Body expand/collapse helpers ──────────────────────────────────

-- Stable id for a single body block within the parsed data — used to remember
-- which bodies the user expanded
local function body_id(sc_idx, sec_idx, step_idx, block_type)
	return table.concat({ sc_idx, sec_idx, step_idx, block_type }, ":")
end

-- Read the configurable render cap for body lines
local function body_max_lines()
	local rc = config.get("results_window") or {}
	local n = tonumber(rc.max_body_lines) or DEFAULT_MAX_BODY_LINES
	return n < 10 and 10 or n
end

-- Append (possibly clamped) body lines into `into_table`.
-- When clamped, appends an expand marker line embedding the body id so <CR>
-- can resolve which body to expand/collapse without needing a separate map.
local function add_body_lines_scoped(body_str, width, into_table, bid)
	local is_expanded = state and state.expanded and state.expanded[bid] or false
	local all = prettify_json(body_str, width)
	local max = body_max_lines()

	local emitted = {}
	if not is_expanded and #all > max then
		for i = 1, max do
			table.insert(emitted, all[i])
		end
		table.insert(emitted, string.format("« %d more lines — <CR> to expand inline »  (id:%s)", #all - max, bid))
	else
		for _, l in ipairs(all) do
			table.insert(emitted, l)
		end
	end

	for _, l in ipairs(emitted) do
		table.insert(into_table, l)
	end
end

local function parse_expand_marker(text)
	return text:match("« %d+ more lines — <CR> to expand inline »%s*%(id:([%w:%-_]+)%)")
end

-- Expand the body whose marker is nearest at-or-above the cursor (searching
-- within the same block), or the body containing the current line.
local function bid_under_cursor()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local l = cursor[1]
	local bufnr = vim.api.nvim_get_current_buf()
	local function bid_at(lnum)
		local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
		if not line then return nil end
		return parse_expand_marker(line)
	end
	-- direct hit?
	local bid = bid_at(l)
	if bid then return bid end
	-- search upward while inside the same block (stop at treeline connectors that end a block)
	for i = l, 1, -1 do
		bid = bid_at(i)
		if bid then return bid end
	end
	return nil
end

local function expand_body_under_cursor()
	if not state or not state.data then return end
	local bid = bid_under_cursor()
	if not bid then
		vim.notify("No collapsed body under cursor", vim.log.levels.WARN)
		return
	end
	state.expanded[bid] = true
	switch_tab(state.active_tab)
end

local function collapse_body_under_cursor()
	if not state or not state.data then return end
	local bid = bid_under_cursor()
	if not bid then
		vim.notify("No body block under cursor to collapse", vim.log.levels.WARN)
		return
	end
	state.expanded[bid] = nil
	switch_tab(state.active_tab)
end

-- <CR> behaviour: toggle expand/collapse on clamped/expanded body under cursor
local function toggle_body_under_cursor()
	if not state or not state.data then return end
	local cursor = vim.api.nvim_win_get_cursor(0)
	local l = cursor[1]
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1] or ""
	local bid = parse_expand_marker(line)
	if bid then
		state.expanded[bid] = true
		switch_tab(state.active_tab)
		return
	end
	-- Collapsing an expanded body: find the block containing cursor and toggle it off
	bid = bid_under_cursor()
	if bid and state.expanded[bid] then
		state.expanded[bid] = nil
		switch_tab(state.active_tab)
		return
	end
	-- Do nothing (no body context)
end

-- ── Helpers ─────────────────────────────────────────────────────────
local function trim(s)
	return s and s:gsub("^%s+", ""):gsub("%s+$", "") or ""
end

local function starts_with(s, prefix)
	return s and s:sub(1, #prefix) == prefix
end

local function is_summary_line(line)
	return starts_with(line, "✓ PASS")
		or starts_with(line, "✗ FAIL")
		or line:match("^%d+%s+passed") ~= nil
		or starts_with(line, "Duration:")
end

local function parse_duration_to_ms(dur_str)
	if not dur_str or dur_str == "" then
		return 0
	end
	local val, unit = dur_str:match("^([%d%.]+)(%a+)$")
	if not val then
		return 0
	end
	val = tonumber(val)
	if unit == "ms" then
		return val
	elseif unit == "s" then
		return val * 1000
	elseif unit == "m" then
		return val * 60000
	end
	return 0
end

local function format_ms_duration(ms)
	if ms < 1000 then
		return string.format("%.0fms", ms)
	elseif ms < 60000 then
		return string.format("%.1fs", ms / 1000)
	else
		local mins = math.floor(ms / 60000)
		local secs = (ms % 60000) / 1000
		return string.format("%dm%.0fs", mins, secs)
	end
end

-- Prettifies a JSON string, trims common leading indentation, and returns a list of lines
function prettify_json(body_str, width)
	if not body_str or body_str == "" then
		return {}
	end
	body_str = body_str:gsub("^%s+", ""):gsub("%s+$", "")

	-- Fallback: split by lines and trim common indentation
	local lines = {}
	for line in body_str:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end

	if #lines > 0 then
		local min_indent = nil
		for _, line in ipairs(lines) do
			if line:match("%S") then
				local indent = #(line:match("^(%s*)") or "")
				if not min_indent or indent < min_indent then
					min_indent = indent
				end
			end
		end
		if min_indent and min_indent > 0 then
			for i, line in ipairs(lines) do
				lines[i] = line:sub(min_indent + 1)
			end
		end
	end

	if not width or width < 40 then
		width = 78
	end
	-- Leave 10 characters margin for tree lines: e.g. "     │  " (8 chars) + safety buffer
	local limit = width - 10
	if limit < 30 then
		limit = 30
	end

	local wrapped_lines = {}
	for _, line in ipairs(lines) do
		if #line <= limit then
			table.insert(wrapped_lines, line)
		else
			-- Try to detect JSON key-value pattern: e.g., '      "name": "value' or '      "name": value'
			local indent, key_prefix, rest = line:match("^(%s*)(%b\"\"%s*:%s*\"?)(.*)$")
			if not indent then
				-- Fallback if key is not quoted or quotes are different
				indent, key_prefix, rest = line:match("^(%s*)([^:]+%s*:%s*\"?)(.*)$")
			end

			local cont_prefix
			local indent_len = 0
			if indent and key_prefix and rest then
				indent_len = #indent
				cont_prefix = string.rep(" ", #indent + #key_prefix)
		else
				indent = line:match("^(%s*)") or ""
				indent_len = #indent
				key_prefix = ""
				local extra_indent = "    " -- 4 extra spaces for continuation lines
				cont_prefix = indent .. extra_indent
				rest = line
			end

			local current_prefix = ""

			while #rest > 0 do
				local max_len = limit - #current_prefix
				if max_len < 10 then
					max_len = 10
				end

				if #rest <= max_len then
					if current_prefix == "" then
						table.insert(wrapped_lines, indent .. key_prefix .. rest)
					else
						table.insert(wrapped_lines, current_prefix .. rest)
					end
					break
				end

				local chunk = rest:sub(1, max_len)
				local last_space = nil
				for i = max_len, 1, -1 do
					local char = chunk:sub(i, i)
					if char == " " or char == "\t" then
						last_space = i
						break
					end
				end

				local cut_idx
				if last_space and last_space > 1 then
					cut_idx = last_space
				else
					cut_idx = max_len
				end

				local part = rest:sub(1, cut_idx)
				if current_prefix == "" then
					table.insert(wrapped_lines, indent .. key_prefix .. part)
				else
					table.insert(wrapped_lines, current_prefix .. part)
				end

				rest = rest:sub(cut_idx + 1)
				if rest:sub(1, 1) == " " then
					rest = rest:sub(2)
				end

				current_prefix = cont_prefix
			end
		end
	end

	return wrapped_lines
end


-- Renders header lines as "k: v" pairs in deterministic sorted key order
local function add_sorted_headers(headers, into_table)
	local keys = {}
	for k in pairs(headers) do
		table.insert(keys, k)
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		table.insert(into_table, string.format("%s: %s", k, headers[k]))
	end
end

-- Formats a byte count for the response meta line
local function approx_bytes(body_str)
	local n = #body_str or 0
	if n < 1000 then
		return string.format("%dB", n)
	elseif n < 1024 * 1024 then
		return string.format("%.1fKB", n / 1024)
	end
	return string.format("%.1fMB", n / (1024 * 1024))
end
local BODY_MAX_LINES = 30
-- Legacy helper retained for backward compatibility; superseded by
-- add_body_lines_scoped (inline expand/collapse). Not referenced internally.
local function add_body_lines(body_str, width, into_table)
	local all = prettify_json(body_str, width)
	if #all <= BODY_MAX_LINES then
		for _, l in ipairs(all) do
			table.insert(into_table, l)
		end
		return
	end
	for i = 1, BODY_MAX_LINES do
		table.insert(into_table, all[i])
	end
	table.insert(into_table, string.format("… %d more lines (press r to inspect)", #all - BODY_MAX_LINES))
end

-- Builds a gorgeous top border bar with the active tab highlighted
local function build_top_bar(active_id, width)
	local title = " Gherkio Results "
	local tabs_str = ""
	for _, t in ipairs(TABS) do
		local tab_text = ""
		if t.id == active_id then
			tab_text = string.format("[%s]●%s", t.key, t.name)
		else
			tab_text = string.format("[%s] %s", t.key, t.name)
		end
		tabs_str = tabs_str .. "  " .. tab_text
	end
	tabs_str = tabs_str .. "  "

	local left = "┌─" .. title .. "──"
	local right = "─┐"

	-- Calculate lengths using Neovim's strdisplaywidth to handle multibyte characters correctly
	local left_width = vim.fn.strdisplaywidth(left)
	local right_width = vim.fn.strdisplaywidth(right)
	local tabs_width = vim.fn.strdisplaywidth(tabs_str)

	local middle_len = width - left_width - right_width - tabs_width
	local middle = string.rep("─", math.max(2, middle_len))

	return left .. middle .. tabs_str .. right
end

-- Render a step with tree lines
local function render_step_tree(step, blocks)
	local lines = {}

	local status_icon = step.passed and "✓" or "✗"
	local dur_str = ""
	if step.duration and step.duration ~= "" then
		dur_str = " (" .. step.duration .. ")"
	end
	local step_header = string.format("  %d. %s  %s%s", step.number, step.label, status_icon, dur_str)
	table.insert(lines, step_header)

	local num_blocks = #blocks
	for i, block in ipairs(blocks) do
		local is_last_block = (i == num_blocks)
		local connector = is_last_block and "     └─ " or "     ├─ "
		local child_indent = is_last_block and "        " or "     │  "

		-- Block Title line: e.g. "     ├─ Request: POST /v2/auth/login"
		table.insert(lines, connector .. block.title)

		-- Block Content lines:
		for _, line in ipairs(block.lines) do
			table.insert(lines, child_indent .. line)
		end

		-- Add empty tree line spacer between blocks (not after the last block)
		if not is_last_block then
			table.insert(lines, "     │")
		end
	end

	return lines
end

-- ── Parser ─────────────────────────────────────────────────────────
-- Parses Gherkio CLI output lines into a clean structured data table
function M.parse_output(lines)
	local data = {
		scenario = "",
		passed = true,
		is_dry_run = false,
		scenarios = {},
		summary = { passed = true, pass_count = 0, fail_count = 0, total = 0, duration = "" },
		raw_lines = lines,
	}

	local current_scenario = nil
	local current_section = nil
	local current_step = nil
	local step_counter = 0

	-- Parsing context state
	local context = nil -- nil | "request" | "response" | "assertions" | "saved"
	local reading_body = false
	local body_lines = {}
	local reading_headers = false

	-- Active step's status indent prefix to strip from body/details
	local current_status_indent = ""

	for _, line in ipairs(lines) do
		-- Strip ANSI escape codes
		local cl = line:gsub("\27%[[%d;]*%a", "")
		local trimmed = trim(cl)

		if trimmed == "" then
			if reading_headers then
				reading_headers = false
			end
			if reading_body then
				reading_body = false
			end
			goto next_line
		end

		-- Detect scenario start, completion, or global summary
		if starts_with(cl, "✓ ") or starts_with(cl, "✗ ") then
			if cl:match("— across") then
				-- Global suite summary line: e.g. "✗ FAIL — across 3 scenario(s)"
				data.summary.passed = starts_with(cl, "✓")
				goto next_line
			elseif cl:match("PASS%s*%(") or cl:match("FAIL%s*%(") then
				-- Scenario completion: e.g. "✗ FAIL (Place an Order (Store POST) (alpha))"
				if current_scenario then
					current_scenario.completed = true
				end
				current_scenario = nil
				current_section = nil
				current_step = nil
				step_counter = 0
				context = nil
				reading_body = false
				reading_headers = false
				goto next_line
			else
				-- Scenario header line: e.g. "✗ Place an Order (Store POST) (alpha)"
				local is_pass = starts_with(cl, "✓ ")
				local name_text = cl:match("^[^%s]+%s+(.*)")
				if name_text then
					current_scenario = {
						name = name_text:gsub("%s*%[DRY RUN%]%s*", ""),
						passed = is_pass,
						is_dry_run = name_text:find("%[DRY RUN%]") ~= nil,
						sections = {},
						resolved_variables = {}
					}
					table.insert(data.scenarios, current_scenario)
					if data.scenario == "" then
						data.scenario = current_scenario.name
						data.is_dry_run = current_scenario.is_dry_run
					end
					-- Reset parsing state for the new scenario
					current_section = nil
					current_step = nil
					step_counter = 0
					context = nil
					reading_body = false
					reading_headers = false
					goto next_line
				end
			end
		end

		-- Detect section boundaries (e.g., "── Resolved Variables ──")
		if cl:match("^──%s+([%a%s]+)%s+──$") then
			local sec_name = cl:match("^──%s+([%a%s]+)%s+──$"):lower()
			current_section = { name = sec_name, steps = {} }
			if current_scenario then
				table.insert(current_scenario.sections, current_section)
			else
				-- Fallback in case scenario header was missed
				table.insert(data.scenarios, {
					name = "Default Scenario",
					passed = true,
					sections = { current_section },
					resolved_variables = {}
				})
				current_scenario = data.scenarios[#data.scenarios]
			end
			current_step = nil
			context = nil
			reading_body = false
			reading_headers = false
			goto next_line
		end

		-- Detect summary line (at the end of output)
		if is_summary_line(trimmed) then
			context = nil
			reading_body = false
			reading_headers = false
			if trimmed:match("passed") then
				local p, f, t = trimmed:match("(%d+)%s+passed,%s+(%d+)%s+failed,%s+(%d+)%s+total")
				if p then
					data.summary.pass_count = tonumber(p)
				end
				if f then
					data.summary.fail_count = tonumber(f)
				end
				if t then
					data.summary.total = tonumber(t)
				end
			elseif starts_with(trimmed, "Duration:") then
				data.summary.duration = trimmed:match("Duration:%s*(.*)") or ""
			end
			goto next_line
		end

		-- Detect step header
		local step_num = nil
		local step_label = nil
		local step_duration = ""
		local depth = 0

		local explicit_num, label_match = trimmed:match("^(%d+)%.%s+(.*)")
		if explicit_num then
			step_num = tonumber(explicit_num)
			step_label = label_match
			depth = 0
		else
			local single_step_label = trimmed:match("^▼%s+(.*)")
			if single_step_label then
				step_label = single_step_label
				depth = 0
			else
				-- Check for nested step header
				-- Prefix is (D-1) times "   │" followed by "   ├ "
				local prefix, nested_label = cl:match("^([%s│]*)   ├%s+(.*)")
				if prefix then
					local _, num_pipes = prefix:gsub("   │", "")
					depth = num_pipes + 1
					-- Remove "▼ " if present in nested_label
					step_label = nested_label:gsub("^▼%s+", "")
				end
			end
		end

		if step_label then
			-- Extract duration from step label if present
			local lbl, dur = step_label:match("(.-)%s+%(([%w%.]+)%)$")
			if lbl then
				step_label = lbl
				step_duration = dur
			end

			step_counter = step_counter + 1
			local assigned_num = step_num or step_counter
			if step_num then
				step_counter = step_num
			end

			if not current_scenario then
				-- Fallback if no scenario header was parsed
				table.insert(data.scenarios, {
					name = "Default Scenario",
					passed = true,
					sections = {},
					resolved_variables = {}
				})
				current_scenario = data.scenarios[#data.scenarios]
			end

			if not current_section or current_section.name == "resolved variables" then
				current_section = { name = "steps", steps = {} }
				table.insert(current_scenario.sections, current_section)
			end

			-- Calculate status indent to strip from inner lines of this step
			if depth > 0 then
				current_status_indent = string.rep("   │", depth) .. " "
			else
				current_status_indent = "   "
			end

			current_step = {
				number = assigned_num,
				label = step_label,
				passed = true,
				duration = step_duration,
				request = { method = "", url = "", headers = {}, body = "" },
				response = { status = nil, headers = {}, body = "" },
				assertions = {},
				saved = {},
				error = nil,
				warnings = {},
			}
			table.insert(current_section.steps, current_step)
			context = nil
			reading_body = false
			reading_headers = false
			goto next_line
		end

		-- Inside a step, parse inner lines after stripping the status indent
		if current_step then
			local cleaned_line = cl
			if starts_with(cl, current_status_indent) then
				cleaned_line = cl:sub(#current_status_indent + 1)
			end
			local step_trimmed = trim(cleaned_line)

			-- Step status
			local success_dur = step_trimmed:match("^✓%s+success%s*%(([%w%.]+)%)$")
			if success_dur or step_trimmed == "✓ success" then
				current_step.passed = true
				if success_dur then
					current_step.duration = success_dur
				end
				goto next_line
			end

			local failed_dur = step_trimmed:match("^✗%s+failed%s*%(([%w%.]+)%)$")
			if failed_dur or step_trimmed == "✗ failed" then
				current_step.passed = false
				if failed_dur then
					current_step.duration = failed_dur
				end
				goto next_line
			end

			-- Auto-detect assertions and saved variables when no context is set yet
			if
				context == nil
				and not step_trimmed:match("^✓%s+success")
				and not step_trimmed:match("^✗%s+failed")
			then
				if starts_with(step_trimmed, "✓") or starts_with(step_trimmed, "✗") then
					local ass_passed = starts_with(step_trimmed, "✓")
					local ass_text = trim(step_trimmed:sub(ass_passed and #"✓" + 1 or #"✗" + 1))
					table.insert(current_step.assertions, {
						passed = ass_passed,
						text = ass_text,
					})
					if not ass_passed then
						current_step.passed = false
						data.passed = false
					end
					goto next_line
				elseif step_trimmed:match("saved:") then
					local remaining = step_trimmed:match("saved:%s*(.*)")
					if remaining then
						-- Split by comma-separated entries: accessToken → "val", custId → "val"
						for entry in remaining:gmatch("([^,]+)") do
							local name, val = entry:match("^%s*([%w_.-]+)%s*[=→]%s*(.*)")
							if name then
								current_step.saved[name] = (val or ""):gsub("^%s*(.-)%s*$", "%1")
							end
						end
					end
					goto next_line
				end
			end

			-- Context switchers
			if step_trimmed == "Request:" then
				context = "request"
				reading_body = false
				reading_headers = false
				goto next_line
			elseif step_trimmed == "Response:" then
				context = "response"
				reading_body = false
				reading_headers = false
				goto next_line
			elseif step_trimmed == "Assertions:" then
				context = "assertions"
				reading_body = false
				reading_headers = false
				goto next_line
			elseif step_trimmed == "Saved Variables:" then
				context = "saved"
				reading_body = false
				reading_headers = false
				goto next_line
			end

			-- If we are reading a body (JSON block)
			if reading_body then
				table.insert(body_lines, cleaned_line)
				local body_str = table.concat(body_lines, "\n")
				if context == "request" then
					current_step.request.body = body_str
				elseif context == "response" then
					current_step.response.body = body_str
				end
				goto next_line
			end

			-- If we are reading headers
			if reading_headers then
				-- Check for "Body:" before generic header pattern so Body: doesn't get
				-- consumed as a header (k="Body", v=""), which would skip body capture.
				local body_hdr = step_trimmed:match("^Body:%s*(.*)")
				if body_hdr ~= nil then
					reading_headers = false
					reading_body = true
					body_lines = {}
					if body_hdr ~= "" then
						local rest = cleaned_line:match("Body:%s*(.*)")
						table.insert(body_lines, rest or "")
						local body_str = table.concat(body_lines, "\n")
						if context == "request" then
							current_step.request.body = body_str
						elseif context == "response" then
							current_step.response.body = body_str
						end
					end
					goto next_line
				end

				local k, v = step_trimmed:match("^%s*([%w-]+)%s*:%s*(.*)")
				if k then
					if context == "request" then
						current_step.request.headers[k] = v
					elseif context == "response" then
						current_step.response.headers[k] = v
					end
					goto next_line
				else
					reading_headers = false
				end
			end

			-- Check for "Body:" start (could have JSON on same line, like "Body:    {")
			local body_start = step_trimmed:match("^Body:%s*(.*)")
			if body_start then
				reading_body = true
				body_lines = {}
				if body_start ~= "" then
					local rest = cleaned_line:match("Body:%s*(.*)")
					table.insert(body_lines, rest)
					local body_str = table.concat(body_lines, "\n")
					if context == "request" then
						current_step.request.body = body_str
					elseif context == "response" then
						current_step.response.body = body_str
					end
				end
				goto next_line
			end

			-- Context-specific line parsing
			if context == "request" then
				local method, url = step_trimmed:match("^([A-Z]+)%s+(%S+)")
				if method and url then
					current_step.request.method = method
					current_step.request.url = url
					goto next_line
				elseif step_trimmed == "Headers:" then
					reading_headers = true
					goto next_line
				end
			elseif context == "response" then
				local status = step_trimmed:match("^Status:%s*(%d+)")
				if status then
					current_step.response.status = tonumber(status)
					goto next_line
				elseif step_trimmed == "Headers:" then
					reading_headers = true
					goto next_line
				end
			elseif context == "assertions" then
				local is_assertion = false
				local ass_passed = false
				local ass_text = ""
				if starts_with(step_trimmed, "✓") then
					is_assertion = true
					ass_passed = true
					ass_text = trim(step_trimmed:sub(#"✓" + 1))
				elseif starts_with(step_trimmed, "✗") then
					is_assertion = true
					ass_passed = false
					ass_text = trim(step_trimmed:sub(#"✗" + 1))
				end

				if is_assertion then
					table.insert(current_step.assertions, {
						passed = ass_passed,
						text = ass_text,
					})
					if not ass_passed then
						current_step.passed = false
						data.passed = false
					end
					goto next_line
				end
			elseif context == "saved" then
				local name, val = step_trimmed:match("^%s*([%w_.-]+)%s*=%s*(.*)")
				if name then
					current_step.saved[name] = val
					goto next_line
				end
			end

			-- Detect step-specific error
			local err_msg = nil
			if starts_with(step_trimmed, "Error:") then
				err_msg = step_trimmed:sub(#"Error:" + 1)
			elseif starts_with(step_trimmed, "✗") then
				local without_icon = trim(step_trimmed:sub(#"✗" + 1))
				if starts_with(without_icon, "Error:") then
					err_msg = without_icon:sub(#"Error:" + 1)
				end
			end
			if err_msg then
				current_step.error = trim(err_msg)
				current_step.passed = false
				goto next_line
			end

			-- Detect warnings
			local warn_msg = step_trimmed:match("^⚠%s*(.*)")
			if warn_msg then
				table.insert(current_step.warnings, warn_msg)
				goto next_line
			end
		end

		-- Capture resolved variables section variables
		if current_scenario and current_section and current_section.name == "resolved variables" then
			local name, val = trimmed:match("^%$(%S+)%s*→%s*(.*)")
			if name then
				current_scenario.resolved_variables = current_scenario.resolved_variables or {}
				current_scenario.resolved_variables[name] = val
			end
		end

		::next_line::
	end

	-- Calculate overall passed status
	local overall_passed = true
	for _, sc in ipairs(data.scenarios) do
		if not sc.passed then
			overall_passed = false
			break
		end
	end
	data.passed = overall_passed

	-- If summary total is 0, calculate it from steps and assertions of all scenarios
	-- If summary total is 0 or we have multiple scenarios, calculate it from steps and assertions of all scenarios
	if data.summary.total == 0 or #data.scenarios > 1 then
		local pass_count = 0
		local fail_count = 0
		local has_errors = false
		local total_ms = 0
		local any_step = false

		for _, sc in ipairs(data.scenarios) do
			for _, section in ipairs(sc.sections) do
				for _, step in ipairs(section.steps) do
					any_step = true
					local step_has_assertions = false
					for _, ass in ipairs(step.assertions) do
						step_has_assertions = true
						if ass.passed then
							pass_count = pass_count + 1
						else
							fail_count = fail_count + 1
						end
					end

					if not step.passed then
						has_errors = true
						if not step_has_assertions then
							fail_count = fail_count + 1
						end
					end

					if step.duration and step.duration ~= "" then
						total_ms = total_ms + parse_duration_to_ms(step.duration)
					end
				end
			end
		end

		if any_step then
			data.summary.pass_count = pass_count
			data.summary.fail_count = fail_count
			data.summary.total = pass_count + fail_count
			if has_errors then
				data.summary.passed = false
			else
				data.summary.passed = true
			end
			data.summary.duration = format_ms_duration(total_ms)
		end
	end

	return data
end

-- ── Renderer ────────────────────────────────────────────────────────
-- Generates buffer lines from parsed data for a given tab view.
function M.render_view(data, tab_id, width, run_meta)
	tab_id = normalize_tab_id(tab_id)
	if not width then
		local bufnr = state and state.bufnr
		if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
			local wins = vim.fn.win_findbuf(bufnr)
			if #wins > 0 then
				width = vim.api.nvim_win_get_width(wins[1])
			end
		end
	end
	width = width or 78
	if width < 40 then
		width = 40
	end

	local lines = {}

	-- 1. Top border with active/inactive tabs
	table.insert(lines, build_top_bar(tab_id, width))
	table.insert(lines, "")
	if run_meta then
		table.insert(lines, string.format("  ▶ Run %s — %s", run_meta.started_at or "", run_meta.target or ""))
	end

	-- 2. Scenarios and Steps
	local rendered_any_steps = false

	for idx, sc in ipairs(data.scenarios) do
		if idx > 1 then
			table.insert(lines, "")
		end

		-- Draw scenario-level divider and title
		local border_char = "═"
		table.insert(lines, "  " .. string.rep(border_char, width - 4))

		local status_icon = sc.passed and "✓" or "✗"
		local scenario_title = sc.name
		local scenario_line = string.format("  %s %s", status_icon, scenario_title)
		if sc.is_dry_run then
			scenario_line = scenario_line .. " [DRY RUN]"
		end
		table.insert(lines, scenario_line)
		table.insert(lines, "  " .. string.rep(border_char, width - 4))
		table.insert(lines, "")

		-- Render Resolved Variables inside the scenario block if they exist
		if
			(tab_id == "all")
			and sc.resolved_variables
			and not vim.tbl_isempty(sc.resolved_variables)
		then
			table.insert(lines, "  ── Resolved Variables ──")
			for k, v in pairs(sc.resolved_variables) do
				table.insert(lines, string.format("     $%s → %s", k, v))
			end
			table.insert(lines, "")
		end

		for _, section in ipairs(sc.sections) do
			if section.name == "resolved variables" then
				goto continue_section
			end

			-- Filter steps based on tab (3-tab design)
			local steps_to_render = {}
			for _, step in ipairs(section.steps) do
				local include_step = false
				if tab_id == "all" then
					include_step = true
				elseif tab_id == "bodies" then
					-- Show only steps that have wire-traffic blocks
					include_step = (step.request and step.request.method ~= "")
						or (step.response and step.response.status ~= nil)
				elseif tab_id == "failures" then
					include_step = not step.passed
				end

				if include_step then
					table.insert(steps_to_render, step)
				end
			end

			if #steps_to_render > 0 then
				rendered_any_steps = true

				-- Section header (only if not the default "steps" section)
				if section.name ~= "steps" and section.name ~= "" then
					table.insert(lines, "  ── " .. section.name:gsub("^%l", string.upper) .. " ──")
					table.insert(lines, "")
				end

				-- Render each step
				for _, step in ipairs(steps_to_render) do
					local blocks = {}

					-- Body ids keyed to parse structure for inline expand/collapse
					local sc_idx = idx
					local sec_idx = 0
					for si, sec in ipairs(sc.sections) do
						if sec == section then
							sec_idx = si
							break
						end
					end
					local st_idx = 0
					for sti, stp in ipairs(section.steps) do
						if stp == step then
							st_idx = sti
							break
						end
					end

					-- Build blocks based on tab_id
					if tab_id == "all" or tab_id == "bodies" then
						if step.request and step.request.method ~= "" then
							local req_lines = {}
							local bid = body_id(sc_idx, sec_idx, st_idx, "request")
							add_sorted_headers(step.request.headers, req_lines)
							if step.request.body and step.request.body ~= "" then
								if #req_lines > 0 then
									table.insert(req_lines, "")
								end
								add_body_lines_scoped(step.request.body, width, req_lines, bid)
							end
							table.insert(blocks, {
								type = "request",
								title = string.format("Request: %s %s", step.request.method, step.request.url),
								lines = req_lines,
								body_id = bid,
							})
						end
					end

					if tab_id == "all" or tab_id == "bodies" or tab_id == "failures" then
						if step.response and step.response.status ~= nil then
							local res_lines = {}
							local bid = body_id(sc_idx, sec_idx, st_idx, "response")
							add_sorted_headers(step.response.headers, res_lines)
							local size_str = ""
							if step.response.body and step.response.body ~= "" then
								if #res_lines > 0 then
									table.insert(res_lines, "")
								end
								size_str = string.format("  ·  %s", approx_bytes(step.response.body))
								add_body_lines_scoped(step.response.body, width, res_lines, bid)
							end
							table.insert(blocks, {
								type = "response",
								title = string.format("Response: %s%s", step.response.status, size_str),
								lines = res_lines,
								body_id = bid,
							})
						end
					end

					if tab_id == "all" or tab_id == "failures" then
						-- Assertions
						if step.assertions and #step.assertions > 0 then
							local ass_lines = {}
							for _, ass in ipairs(step.assertions) do
								local ass_icon = ass.passed and "✓" or "✗"
								table.insert(ass_lines, string.format("%s %s", ass_icon, ass.text))
							end
							table.insert(blocks, {
								type = "assertions",
								title = "Assertions:",
								lines = ass_lines,
							})
						end

						-- Saved variables
						if step.saved and not vim.tbl_isempty(step.saved) then
							local saved_lines = {}
							for k, v in pairs(step.saved) do
								table.insert(saved_lines, string.format("%s = %s", k, v))
							end
							table.insert(blocks, {
								type = "saved",
								title = "Saved Variables:",
								lines = saved_lines,
							})
						end
					end

					-- Error block (always render if present)
					if step.error and step.error ~= "" then
						table.insert(blocks, {
							type = "error",
							title = string.format("Error: %s", step.error),
							lines = {},
						})
					end

					-- Warnings block (always render if present)
					if step.warnings and #step.warnings > 0 then
						local warn_lines = {}
						for _, w in ipairs(step.warnings) do
							table.insert(warn_lines, w)
						end
						table.insert(blocks, {
							type = "warnings",
							title = "Warnings:",
							lines = warn_lines,
						})
					end

					-- Render the tree for this step
					local step_lines = render_step_tree(step, blocks)
					for _, sl in ipairs(step_lines) do
						table.insert(lines, sl)
					end
					table.insert(lines, "")
				end
			end

			::continue_section::
		end
	end

	if not rendered_any_steps then
		if tab_id == "failures" then
			table.insert(lines, "  ✓ All steps passed! No errors to show.")
		else
			table.insert(lines, "  No steps found for this view.")
		end
		table.insert(lines, "")
	end

	-- 4. Bottom Summary Bar
	table.insert(lines, "  " .. string.rep("─", width - 4))

	local s = data.summary
	local summary_status = s.passed and "✓ PASS" or "✗ FAIL"
	local summary_details = string.format("%d passed, %d failed", s.pass_count, s.fail_count)
	if s.total > 0 then
		summary_details = summary_details .. string.format(", %d total", s.total)
	end
	local duration_str = s.duration ~= "" and ("Duration: " .. s.duration) or ""

	local summary_line = string.format("  %s  %s", summary_status, summary_details)
	if duration_str ~= "" then
		local padding_needed = width - vim.fn.strdisplaywidth(summary_line) - vim.fn.strdisplaywidth(duration_str) - 4
		if padding_needed > 0 then
			summary_line = summary_line .. string.rep(" ", padding_needed) .. duration_str
		else
			summary_line = summary_line .. "    " .. duration_str
		end
	end
	table.insert(lines, summary_line)

	-- 5. Bottom border
	table.insert(lines, "└" .. string.rep("─", width - 2) .. "┘")

	return lines
end

-- ── Syntax Highlighting ──────────────────────────────────────────────
local function setup_syntax(bufnr)
	vim.api.nvim_buf_set_option(bufnr, "syntax", "")

	vim.cmd([[
    syntax clear
    
    " Borders and frame
    syntax match GherkioBorder /^[┌└]─\+/
    syntax match GherkioBorder /─\+[┐┘]$/
    syntax match GherkioBorder /^[─ ]\+$/
    syntax match GherkioBorder /^[═ ]\+$/
    
    " Tree lines
    syntax match GherkioTree /[│├└─]/
    
    " Pass/Fail/Warn icons
    syntax match GherkioPass /✓/
    syntax match GherkioFail /✗/
    syntax match GherkioWarn /⚠/
    
    " Tab bar highlights
    syntax match GherkioTabActive /●\w\+/
    syntax match GherkioTabKey /\[\d\]/
    
    " Section headers
    syntax match GherkioSectionHeader /──.*──/
    
    " Headers
    syntax match GherkioHeader /Request:/
    syntax match GherkioHeader /Response:/
    syntax match GherkioHeader /Assertions:/
    syntax match GherkioHeader /Saved Variables:/
    syntax match GherkioHeader /Error:/
    syntax match GherkioHeader /Warnings:/
    
    " JSON highlighting inside the buffer
    " Match JSON keys: double quoted string followed by a colon
    syntax match GherkioJsonKey /"\([^"\\]\|\\.\)*"\ze\s*:/
    
    " Match JSON strings: double quoted string not followed by a colon
    syntax match GherkioJsonString /"\([^"\\]\|\\.\)*"\(\s*:\)\@!/
    
    " Match JSON numbers
    syntax match GherkioJsonNumber /\<[+-]\=\d\+\%(\.\d\+\)\=\%([eE][+-]\=\d\+\)\=\>/
    
    " Match JSON booleans and null
    syntax match GherkioJsonKeyword /\<\%(true\|false\|null\)\>/
    
    " Step and suite duration
    syntax match GherkioDuration /(\d\+\%(\.\d\+\)\=m\=s)/
    syntax match GherkioDuration /\<Duration:\s*\d\+\%(\.\d\+\)\=m\=s\>/
    
    " Highlight associations
    highlight default link GherkioBorder Comment
    highlight default link GherkioTree Comment
    highlight default link GherkioPass DiagnosticOk
    highlight default link GherkioFail DiagnosticError
    highlight default link GherkioWarn DiagnosticWarn
    highlight default link GherkioTabActive PmenuSel
    highlight default link GherkioTabKey Special
    highlight default link GherkioSectionHeader Title
    highlight default link GherkioHeader Title
    highlight default link GherkioJsonKey Identifier
    highlight default link GherkioJsonString String
    highlight default link GherkioJsonNumber Number
    highlight default link GherkioJsonKeyword Keyword
    highlight default link GherkioDuration Comment
  ]])
end

-- ── Navigation ──────────────────────────────────────────────────────
-- Finds the step number under the cursor by searching upwards
-- Finds the step info under the cursor (step number and parent scenario title)
local function get_current_step_info()
	local win = vim.api.nvim_get_current_win()
	local cursor = vim.api.nvim_win_get_cursor(win)
	local current_line = cursor[1]

	local step_num = nil
	for l = current_line, 1, -1 do
		local line = vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1]
		if line then
			local num = line:match("^%s*(%d+)%.%s")
			if num then
				step_num = tonumber(num)
				break
			end
		end
	end

	if not step_num then
		return nil
	end

	local scenario_title = nil
	for l = current_line, 1, -1 do
		local line = vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1]
		if line and line:match("^%s*═+$") then
			if l > 1 then
				local title_line = vim.api.nvim_buf_get_lines(0, l - 2, l - 1, false)[1]
				if title_line then
					local title = title_line:match("^%s*✓%s*(.-)%s*$") or title_line:match("^%s*✗%s*(.-)%s*$")
					if title then
						scenario_title = title:gsub("%s*%[DRY RUN%]$", "")
						break
					end
				end
			end
		end
	end

	return {
		step_number = step_num,
		scenario_title = scenario_title,
	}
end

-- Focuses the cursor on the step matching the given step info
local function focus_step_info(info)
	if not info or not info.step_number then
		return
	end
	local total_lines = vim.api.nvim_buf_line_count(0)
	local current_scenario = nil

	for l = 1, total_lines do
		local line = vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1]
		if line then
			if line:match("^%s*═+$") then
				if l > 1 then
					local title_line = vim.api.nvim_buf_get_lines(0, l - 2, l - 1, false)[1]
					if title_line then
						local title = title_line:match("^%s*✓%s*(.-)%s*$") or title_line:match("^%s*✗%s*(.-)%s*$")
						if title then
							current_scenario = title:gsub("%s*%[DRY RUN%]$", "")
						end
					end
				end
			end

			local num = line:match("^%s*(" .. info.step_number .. ")%.%s")
			if num then
				if not info.scenario_title or current_scenario == info.scenario_title then
					local win = vim.api.nvim_get_current_win()
					vim.api.nvim_win_set_cursor(win, { l, 2 })
					return
				end
			end
		end
	end
end

local function get_current_step_object()
	local info = get_current_step_info()
	if not info or not state or not state.data then
		return nil
	end
	for _, sc in ipairs(state.data.scenarios or {}) do
		if not info.scenario_title or sc.name == info.scenario_title then
			for _, sec in ipairs(sc.sections or {}) do
				for _, step in ipairs(sec.steps or {}) do
					if step.number == info.step_number then
						return step, sc
					end
				end
			end
		end
	end
	return nil
end

local function yank_step_body()
	local step = get_current_step_object()
	if not step then
		vim.notify("No step under cursor", vim.log.levels.WARN)
		return
	end
	local target_body = nil
	local label = "Response"
	if state and state.active_tab == "request" and step.request and step.request.body ~= "" then
		target_body = step.request.body
		label = "Request"
	elseif step.response and step.response.body ~= "" then
		target_body = step.response.body
	elseif step.request and step.request.body ~= "" then
		target_body = step.request.body
		label = "Request"
	end

	if not target_body or target_body == "" then
		vim.notify("No body found for current step", vim.log.levels.WARN)
		return
	end

	local clipboard = require("gherkio.core.clipboard")
	clipboard.set_contents(target_body)
	vim.notify(string.format("✓ %s body of Step %d copied to clipboard!", label, step.number), vim.log.levels.INFO)
end

local function inspect_response_in_buffer()
	local step = get_current_step_object()
	if not step or not step.response or not step.response.body or step.response.body == "" then
		vim.notify("No response body available for this step", vim.log.levels.WARN)
		return
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "filetype", "json")
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "swapfile", false)

	local body_lines = {}
	for line in step.response.body:gmatch("[^\r\n]+") do
		table.insert(body_lines, line)
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, body_lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	local width = math.min(100, math.floor(vim.o.columns * 0.8))
	local height = math.min(30, math.floor(vim.o.lines * 0.8))
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = string.format(" Step %d Response JSON ", step.number),
		title_pos = "center",
	})

	vim.keymap.set("n", "q", function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, { buffer = buf, silent = true })
	vim.keymap.set("n", "<Esc>", function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, { buffer = buf, silent = true })
end
local function jump_step(dir)
	local win = vim.api.nvim_get_current_win()
	local cursor = vim.api.nvim_win_get_cursor(win)
	local current_line = cursor[1]
	local total_lines = vim.api.nvim_buf_line_count(0)

	local step = dir == "next" and 1 or -1
	local start = current_line + step
	local finish = dir == "next" and total_lines or 1

	for l = start, finish, step do
		local line = vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1]
		if line then
			local is_target = false
			if line:match("^%s*%d+%.%s") then
				is_target = true
			elseif line:match("^%s*──%s+.*%s+──") then
				is_target = true
			elseif (line:match("^%s*✓%s") or line:match("^%s*✗%s")) and not line:match("PASS") and not line:match("FAIL") then
				is_target = true
			end
			if is_target then
				vim.api.nvim_win_set_cursor(win, { l, 2 })
				return
			end
		end
	end
end

-- Switch to a different tab and re-render the view
switch_tab = function(tab_id)
	if not state or not state.data then
		return
	end

	local active_step_info = get_current_step_info()
	state.active_tab = tab_id

	local current_width = 78
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		local wins = vim.fn.win_findbuf(state.bufnr)
		if #wins > 0 then
			current_width = vim.api.nvim_win_get_width(wins[1])
		end
	end

	local lines = M.render_view(state.data, tab_id, current_width, state.run_meta)
	local bufnr = state.bufnr
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
	vim.api.nvim_buf_set_option(bufnr, "readonly", false)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
	vim.api.nvim_buf_set_option(bufnr, "readonly", true)

	setup_syntax(bufnr)
	focus_step_info(active_step_info)

	-- Update floating window title
	local wins = vim.fn.win_findbuf(bufnr)
	if #wins > 0 then
		local win_cfg = config.get("results_window") or {}
		if win_cfg.layout == "float" then
			for _, w in ipairs(wins) do
				vim.api.nvim_win_set_config(w, {
					title = " Gherkio — " .. tab_id:gsub("^%l", string.upper) .. " ",
				})
			end
		end
	end
end

local help_win = nil
local help_buf = nil

local function close_help()
	if help_win and vim.api.nvim_win_is_valid(help_win) then
		vim.api.nvim_win_close(help_win, false) -- no force: don't cascade-close the results float
	end
	help_win = nil
	help_buf = nil
end

local function toggle_help()
	if help_win and vim.api.nvim_win_is_valid(help_win) then
		close_help()
		return
	end

	local help_lines = {
		"  Gherkio Results Keybindings",
		"  ───────────────────────────",
		"",
		"  Tabs & Views:",
		"    1 : Switch to [1] All View",
		"    2 : Switch to [2] Bodies View",
		"    3 : Switch to [3] Failures View",
		"",
		"  Inspection & Actions:",
		"    y : Yank clean response/request body to clipboard",
		"    r : Open response in formatted JSON preview popup",
		"   <CR>: Expand/collapse body inline",
		"    Y : Yank visual selection with tree decor stripped",
		"",
		"  Navigation:",
		"    ] : Jump to Next Step/Section",
		"    [ : Jump to Prev Step/Section",
		"",
	"  Controls:",
		"    ? : Toggle this help menu",
		"    o : Open report in browser",
		"    q : Close results window (help closed first)",
		"  Esc : Dismiss help popup (or close results if help is hidden)",
	}

	-- Calculate height and width of help popup
	local height = #help_lines
	local width = 0
	for _, line in ipairs(help_lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	width = width + 4 -- padding

	-- Get dimensions of the parent window to center the popup
	local parent_win = vim.api.nvim_get_current_win()
	local parent_width = vim.api.nvim_win_get_width(parent_win)
	local parent_height = vim.api.nvim_win_get_height(parent_win)

	local row = math.floor((parent_height - height) / 2)
	local col = math.floor((parent_width - width) / 2)
	if row < 0 then
		row = 0
	end
	if col < 0 then
		col = 0
	end

	help_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, help_lines)
	vim.api.nvim_buf_set_option(help_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(help_buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(help_buf, "modifiable", false)

	help_win = vim.api.nvim_open_win(help_buf, false, {
		relative = "win",
		win = parent_win,
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		zindex = 60, -- render above the results float (default zindex 50)
	})

	-- Set up syntax highlighting for help window
	vim.api.nvim_buf_set_option(help_buf, "syntax", "gherkio-help")
	vim.cmd([[
    syntax clear
    syntax match GherkioHelpTitle /Gherkio Results Keybindings/
    syntax match GherkioHelpHeader /^\s\+\w\+ & \w\+:/
    syntax match GherkioHelpHeader /^\s\+\w\+:/
    syntax match GherkioHelpKey /^\s\+[^:]\+\ze\s*:/
    syntax match GherkioHelpDivider /──\+/

    highlight default link GherkioHelpTitle Title
    highlight default link GherkioHelpHeader Special
    highlight default link GherkioHelpKey Identifier
    highlight default link GherkioHelpDivider Comment
  ]])

	-- Close elegantly WITHOUT cascading into the results window:
	-- never use force=true (it can take nested/parent floats down with it).

	-- Give the help buffer its own focusable window: users can press <Esc> or q
	-- INSIDE the help window to dismiss it, without killing the results window.
	local function close_help_from_help_buffer()
		close_help()
		-- restore focus to the parent (results) window
		if vim.api.nvim_win_is_valid(parent_win) then
			pcall(vim.api.nvim_set_current_win, parent_win)
		end
	end

	for _, key in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", key, close_help_from_help_buffer, {
			buffer = help_buf,
			silent = true,
			nowait = true,
			desc = "Close Gherkio Help",
		})
	end
	vim.keymap.set("n", "?", close_help_from_help_buffer, {
		buffer = help_buf,
		silent = true,
		nowait = true,
		desc = "Close Gherkio Help",
	})
end

-- ── Viewer ──────────────────────────────────────────────────────────
-- Opens the Gherkio structured results UI window
function M.show_results(output_lines, run_meta)
	local data = M.parse_output(output_lines)
	if not data then
		vim.notify("Failed to parse Gherkio output.", vim.log.levels.ERROR)
		return
	end

	local active_tab = normalize_tab_id(state and state.active_tab or "all")
	run_meta = run_meta or (state and state.run_meta)

	local win_cfg = config.get("results_window")
		or {
			auto_open = true,
			layout = "vsplit",
			width = 0.40,
			height = 0.3,
			border = "rounded",
		}

	local layout = win_cfg.layout or "vsplit"

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

	-- Update state
	state = {
		data = data,
		active_tab = active_tab,
		bufnr = bufnr,
		run_meta = run_meta,
		-- Preserve per-body expansion across re-renders and runs
		expanded = (state and state.expanded) or {},
	}

	-- Find or create window first
	local win = nil
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == bufnr then
			win = w
			break
		end
	end

	local target_width = 78
	if layout == "vsplit" then
		if not win then
			vim.cmd("botright vsplit")
			win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(win, bufnr)
		end
		target_width = math.floor(vim.o.columns * (win_cfg.width or 0.40))
		if target_width < 40 then
			target_width = 40
		end
		vim.api.nvim_win_set_width(win, target_width)
		vim.api.nvim_win_set_option(win, "wrap", false)
		if win_cfg.focus_on_open == false then
			pcall(function() vim.cmd("wincmd p") end)
		end
	elseif layout == "split" then
		if not win then
			vim.cmd("botright split")
			win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(win, bufnr)
		end
		local height = math.floor(vim.o.lines * (win_cfg.height or 0.3))
		if height < 10 then
			height = 10
		end
		vim.api.nvim_win_set_height(win, height)
		target_width = vim.api.nvim_win_get_width(win)
		if win_cfg.focus_on_open == false then
			pcall(function() vim.cmd("wincmd p") end)
		end
	else -- float
		local total_cols = vim.o.columns
		local total_lines = vim.o.lines
		local width_ratio = win_cfg.width == 0.40 and 0.8 or (win_cfg.width or 0.8)
		local height_ratio = win_cfg.height == 0.3 and 0.6 or (win_cfg.height or 0.6)
		target_width = math.floor(total_cols * width_ratio)
		local height = math.floor(total_lines * height_ratio)
		if target_width < 50 then
			target_width = 50
		end
		if height < 10 then
			height = 10
		end
		local row = math.floor((total_lines - height) / 2)
		local col = math.floor((total_cols - target_width) / 2)
		local opts = {
			relative = "editor",
			row = row,
			col = col,
			width = target_width,
			height = height,
			style = "minimal",
			border = win_cfg.border or "rounded",
			title = " Gherkio — All ",
			title_pos = "center",
		}
		local enter = win_cfg.focus_on_open ~= false
		if win then
			vim.api.nvim_win_set_config(win, opts)
		else
			win = vim.api.nvim_open_win(bufnr, enter, opts)
			if not enter then
				-- Return focus to previous window
				pcall(function() vim.cmd("wincmd p") end)
			end
		end
	end

	-- Configure clean results window layout (no numbers, signs)
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_option(win, "number", false)
		vim.api.nvim_win_set_option(win, "relativenumber", false)
		vim.api.nvim_win_set_option(win, "signcolumn", "no")
		vim.api.nvim_win_set_option(win, "foldcolumn", "0")
		vim.api.nvim_win_set_option(win, "wrap", true)
		vim.api.nvim_win_set_option(win, "breakindent", true)
	end

	-- Render the view with the actual window's target width!
	local lines = M.render_view(data, active_tab, target_width, run_meta)

	-- Set buffer contents
	vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
	vim.api.nvim_buf_set_option(bufnr, "readonly", false)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
	vim.api.nvim_buf_set_option(bufnr, "readonly", true)

	-- Apply syntax highlighting
	setup_syntax(bufnr)

	-- Buffer-local keymaps
	local function close()
		close_help()
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	-- Tab switching keys (1 - 3)
	for _, t in ipairs(TABS) do
		vim.keymap.set("n", t.key, function()
			switch_tab(t.id)
		end, { buffer = bufnr, silent = true, nowait = true, desc = "Tab: " .. t.name })
	end

	-- Navigation and Jump keys
	vim.keymap.set("n", "]", function()
		jump_step("next")
	end, { buffer = bufnr, silent = true, desc = "Next Gherkio Step" })
	vim.keymap.set("n", "[", function()
		jump_step("prev")
	end, { buffer = bufnr, silent = true, desc = "Previous Gherkio Step" })

	-- Action keys
	-- Visual yank with tree-decoration stripping: select body lines, press Y,
	-- get clean JSON without `   │`, `├─`, `└─`, or leading connector segments.
	local function strip_tree_decor(line)
		local s = line
		-- Repeatedly strip leading treeline segments: "<spaces>│<spaces>"
		while true do
			local stripped = s:match("^%s*│%s*(.*)")
			if not stripped then break end
			s = stripped
		end
		-- Remove leading block connectors: "<spaces>├─ " or "<spaces>└─ "
		-- (byte-range class; single-char class mis-handles multibyte UTF-8 in some Lua builds)
		s = s:match("^%s*.-[├└]─%s*(.*)") or s:gsub("^%s+", "")
		-- trim trailing whitespace and decoration-induced leading spaces
		s = s:gsub("%s+$", "")
		s = s:gsub("^%s+", "")
		return s
	end

	local function clean_visual_text(l1, l2)
		local bufnr = vim.api.nvim_get_current_buf()
		local cleaned = {}
		for l = l1, l2 do
			local line = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
			if line then
				local s = strip_tree_decor(line)
				if s ~= "" then
					table.insert(cleaned, s)
				end
			end
		end
		return table.concat(cleaned, "\n")
	end

	local function visual_yank_clean()
		local start_pos = vim.fn.getpos("'<")
		local end_pos = vim.fn.getpos("'>")
		local l1, l2 = start_pos[2], end_pos[2]
		local text = clean_visual_text(l1, l2)
		if text == "" then return end
		local clipboard = require("gherkio.core.clipboard")
		clipboard.set_contents(text)
		vim.notify("✓ Copied clean selection (tree decorations stripped)", vim.log.levels.INFO)
	end

	vim.keymap.set("v", "Y", visual_yank_clean, { buffer = bufnr, silent = true, desc = "Yank Visual Selection Cleaned of Tree Decor" })
	vim.keymap.set("n", "y", yank_step_body, { buffer = bufnr, silent = true, desc = "Yank Response/Request Body" })
	vim.keymap.set("n", "r", inspect_response_in_buffer, { buffer = bufnr, silent = true, desc = "Inspect Response JSON in Popup" })
	vim.keymap.set(
		"n",
		"<CR>",
		toggle_body_under_cursor,
		{ buffer = bufnr, silent = true, nowait = true, desc = "Expand/Collapse Body Inline" }
	)

	-- Help toggle key
	vim.keymap.set(
		"n",
		"?",
		toggle_help,
		{ buffer = bufnr, silent = true, nowait = true, desc = "Toggle Gherkio Keybindings Help" }
	)

	vim.keymap.set("n", "o", function()
		local init = require("gherkio")
		if init.open_report then
			init.open_report()
		end
	end, { buffer = bufnr, silent = true, desc = "Open Gherkio HTML Report in Browser" })

	-- `q` closes the results window entirely (help dismissed first, if open).
	vim.keymap.set("n", "q", function()
		close()
	end, { buffer = bufnr, silent = true, nowait = true })

	-- <Esc> is reserved to dismiss overlays: closes the help popup when open;
	-- when no overlay is showing it falls through to closing the results window.
	vim.keymap.set("n", "<Esc>", function()
		if help_win and vim.api.nvim_win_is_valid(help_win) then
			close_help()
			return
		end
		close()
	end, { buffer = bufnr, silent = true, nowait = true })
	if layout == "float" then
		vim.keymap.set("n", "<CR>", function()
			-- In float, <CR> conflict: help open? just close help, else toggle body
			if help_win and vim.api.nvim_win_is_valid(help_win) then
				close_help()
				return
			end
			toggle_body_under_cursor()
		end, { buffer = bufnr, silent = true, nowait = true })
	end

	-- Auto-resize on window resize
	local resize_group = vim.api.nvim_create_augroup("GherkioResize", { clear = true })
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = resize_group,
		callback = function()
			if state and state.data and state.active_tab and state.bufnr then
				if vim.api.nvim_buf_is_valid(state.bufnr) then
					local wins = vim.fn.win_findbuf(state.bufnr)
					if #wins > 0 then
						local win_id = wins[1]
						if vim.api.nvim_win_is_valid(win_id) then
							local current_width = vim.api.nvim_win_get_width(win_id)
							-- Re-render with the new width
							local lines = M.render_view(state.data, state.active_tab, current_width, state.run_meta)
							vim.api.nvim_buf_set_option(state.bufnr, "modifiable", true)
							vim.api.nvim_buf_set_option(state.bufnr, "readonly", false)
							vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
							vim.api.nvim_buf_set_option(state.bufnr, "modifiable", false)
							vim.api.nvim_buf_set_option(state.bufnr, "readonly", true)
							setup_syntax(state.bufnr)
						end
					end
				end
			end
		end,
	})

	-- Cleanup on buffer wipeout
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = bufnr,
		once = true,
		callback = function()
			pcall(vim.api.nvim_del_augroup_by_name, "GherkioResize")
			close_help()
		end,
	})
end

-- Expose internal test hooks (used by headless verification only)
function M._debug_state()
	return state
end

function M._set_expanded(bid, value)
	if not state then
		state = { expanded = {} }
	end
	state.expanded = state.expanded or {}
	state.expanded[bid] = value
	return bid
end

function M._expanded(bid)
	return state and state.expanded and state.expanded[bid] or nil
end

-- Re-opens the last results window from cached data without re-running the test.
function M.reopen_results(run_meta)
	if not state or not state.data then
		vim.notify("No cached Gherkio results available. Run a test first.", vim.log.levels.WARN)
		return
	end
	M.show_results(state.data.raw_lines, run_meta or state.run_meta)
end

-- ── Streaming / Loading ────────────────────────────────────────────
-- Shows a live-updating raw-output view while the test runs.
-- Falls back to structured results when finalized.

local streaming_bufnr = nil
local streaming_win = nil
-- Smart follow: only auto-scroll to the tail while the cursor is at the bottom.
local streaming_auto_follow = true
local streaming_augroup = nil

-- Opens the results window immediately with a loading banner.
function M.show_streaming(target)
	-- Reuse existing gherkio-results buffer or create one
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_option(buf, "filetype") == "gherkio-results" then
			streaming_bufnr = buf
			break
		end
	end
	if not streaming_bufnr then
		streaming_bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_option(streaming_bufnr, "filetype", "gherkio-results")
		vim.api.nvim_buf_set_option(streaming_bufnr, "buftype", "nofile")
		vim.api.nvim_buf_set_option(streaming_bufnr, "bufhidden", "hide")
		vim.api.nvim_buf_set_option(streaming_bufnr, "swapfile", false)
	end

	local win_cfg = config.get("results_window") or { layout = "vsplit", width = 0.40, border = "rounded" }
	local layout = win_cfg.layout or "vsplit"

	-- Show or reuse window
	streaming_win = nil
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == streaming_bufnr then
			streaming_win = w
			break
		end
	end

	local header = string.format("  ⏳ Running Gherkio %s...", target)
	local lines = {
		"┌─ Gherkio Results ──────────────────────────────────────────────────────┐",
		header,
		"├─ Output ───────────────────────────────────────────────────────────────┤",
		"",
		"└────────────────────────────────────────────────────────────────────────┘",
	}

	vim.api.nvim_buf_set_option(streaming_bufnr, "modifiable", true)
	vim.api.nvim_buf_set_option(streaming_bufnr, "readonly", false)
	vim.api.nvim_buf_set_lines(streaming_bufnr, 0, -1, false, lines)

	local target_width = math.floor(vim.o.columns * (win_cfg.width or 0.40))
	if target_width < 40 then
		target_width = 40
	end

	if layout == "vsplit" then
		if not streaming_win then
			vim.cmd("botright vsplit")
			streaming_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(streaming_win, streaming_bufnr)
		end
		vim.api.nvim_win_set_width(streaming_win, target_width)
	elseif layout == "split" then
		if not streaming_win then
			vim.cmd("botright split")
			streaming_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(streaming_win, streaming_bufnr)
		end
		local height = math.floor(vim.o.lines * (win_cfg.height or 0.3))
		if height < 10 then
			height = 10
		end
		vim.api.nvim_win_set_height(streaming_win, height)
	else -- float
		local total_cols = vim.o.columns
		local total_lines = vim.o.lines
		local width = math.floor(total_cols * (win_cfg.width or 0.40))
		if width < 50 then
			width = 50
		end
		local height = math.floor(total_lines * 0.4)
		if height < 8 then
			height = 8
		end
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
			title = " Gherkio — Running ",
			title_pos = "center",
		}
		if streaming_win and vim.api.nvim_win_is_valid(streaming_win) then
			vim.api.nvim_win_set_config(streaming_win, opts)
		else
			local enter = win_cfg.focus_on_open ~= false
			streaming_win = vim.api.nvim_open_win(streaming_bufnr, enter, opts)
			if not enter then
				pcall(function() vim.cmd("wincmd p") end)
			end
		end
	end

	if streaming_win and vim.api.nvim_win_is_valid(streaming_win) then
		vim.api.nvim_win_set_option(streaming_win, "number", false)
		vim.api.nvim_win_set_option(streaming_win, "relativenumber", false)
		vim.api.nvim_win_set_option(streaming_win, "signcolumn", "no")
		vim.api.nvim_win_set_option(streaming_win, "foldcolumn", "0")
		vim.api.nvim_win_set_option(streaming_win, "wrap", false)
	end

	vim.api.nvim_buf_set_option(streaming_bufnr, "modifiable", false)
	vim.api.nvim_buf_set_option(streaming_bufnr, "readonly", true)

	-- Smart follow: start fresh each run and track whether the user is at the tail.
	streaming_auto_follow = true
	if streaming_augroup then
		pcall(vim.api.nvim_del_augroup_by_id, streaming_augroup)
		streaming_augroup = nil
	end
	if streaming_bufnr and vim.api.nvim_buf_is_valid(streaming_bufnr) then
		streaming_augroup = vim.api.nvim_create_augroup("GherkioStreamingFollow", { clear = false })
		vim.api.nvim_create_autocmd("CursorMoved", {
			group = streaming_augroup,
			buffer = streaming_bufnr,
			desc = "Gherkio: detect if user follows the streaming tail",
			callback = function()
				vim.schedule(function()
					if not streaming_win or not vim.api.nvim_win_is_valid(streaming_win) then
						return
					end
					local ok, cursor = pcall(vim.api.nvim_win_get_cursor, streaming_win)
					if not ok then
						return
					end
					-- Tail is one line above the bottom border.
					local line_count = vim.api.nvim_buf_line_count(streaming_bufnr)
					local tail = math.max(1, line_count - 1)
					streaming_auto_follow = cursor[1] >= tail
				end)
			end,
		})
	end
end

-- Appends a single raw output line to the streaming buffer.
function M.append_streaming_line(line)
	-- Strip ANSI escape codes for clean display
	local clean = line:gsub("\27%[%d;]*%a", "")
	if clean == "" then
		return
	end

	vim.schedule(function()
		if not streaming_bufnr or not vim.api.nvim_buf_is_valid(streaming_bufnr) then
			return
		end
		local ok, _ = pcall(function()
			local cur_lines = vim.api.nvim_buf_get_lines(streaming_bufnr, 0, -1, false)
			-- Insert before the last line (bottom border)
			local insert_pos = #cur_lines - 1
			if insert_pos < 3 then
				insert_pos = 3
			end
			vim.api.nvim_buf_set_option(streaming_bufnr, "modifiable", true)
			vim.api.nvim_buf_set_option(streaming_bufnr, "readonly", false)
			vim.api.nvim_buf_set_lines(streaming_bufnr, insert_pos, insert_pos, false, { "    " .. clean })
			-- Smart follow: only scroll to the tail if the user is still following it
			if streaming_auto_follow and streaming_win and vim.api.nvim_win_is_valid(streaming_win) then
				local line_count = vim.api.nvim_buf_line_count(streaming_bufnr)
				-- Scroll to one line above bottom border so border stays visible
				vim.api.nvim_win_set_cursor(streaming_win, { math.max(1, line_count - 1), 0 })
			end
			vim.api.nvim_buf_set_option(streaming_bufnr, "modifiable", false)
			vim.api.nvim_buf_set_option(streaming_bufnr, "readonly", true)
		end)
		if not ok then
			-- Buffer was likely closed, reset state
			streaming_bufnr = nil
			streaming_win = nil
		end
	end)
end

-- Replaces the streaming buffer with the full structured results view.
function M.finalize_streaming(all_lines, run_meta)
	-- Clean up the smart-follow cursor tracker
	if streaming_augroup then
		pcall(vim.api.nvim_del_augroup_by_id, streaming_augroup)
		streaming_augroup = nil
	end
	streaming_auto_follow = true
	-- Close streaming window reference so show_results creates a fresh window
	streaming_bufnr = nil
	streaming_win = nil
	M.show_results(all_lines, run_meta)
end

return M
