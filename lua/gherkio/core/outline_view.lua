-- Render outline data into ASCII lines and open the outline window.
local outline = require("gherkio.core.outline")
local config = require("gherkio.config")

local M = {}

-- Window layout: default split on the right, like the results window
local outline_win, outline_buf, src_buf

local function close_outline()
	if outline_win and vim.api.nvim_win_is_valid(outline_win) then
		vim.api.nvim_win_close(outline_win, false)
	end
	outline_win = nil
end

-- Map outline lines back to source line numbers for <CR> jumping
-- (line -> { kind = "step", src_line = L } | nil)
local line_to_src = {}

local function render_lines(data, src_path)
	local lines = {}
	line_to_src = {}

	local t = data.totals
	local header = string.format(
		"  scenario: %s          ·  %s",
		data.scenario or "Unnamed Scenario",
		src_path or "buffer"
	)
	table.insert(lines, "")
	table.insert(lines, header)
	table.insert(lines, "")

	for _, sec in ipairs(data.sections) do
		local use_count = 0
		for _, st in ipairs(sec.steps) do
			if st.use then
				use_count = use_count + 1
			end
		end
		table.insert(lines, string.format("  ── %s (%d steps%s) ──", sec.name, #sec.steps, use_count > 0 and string.format(" · %d shared", use_count) or ""))

		for _, st in ipairs(sec.steps) do
			local label
			if st.use then
				label = string.format("  · %2d. %s %24s", st.number, "[use]", st.use)
			else
				label = string.format("  · %2d. %-28s %s", st.number, st.name or "(unnamed)", st.request or "—")
			end
			table.insert(lines, label)
			local this_line = #lines
			line_to_src[this_line] = st.line

			-- save vars on the step line
			if #st.save > 0 then
				lines[#lines] = label .. "   [save: " .. table.concat(st.save, ", ") .. "]"
			end

			-- assertions as indented one-liners
			if not st.use then
				for _, a in ipairs(st.asserts) do
					table.insert(lines, "        " .. a)
					line_to_src[#lines] = st.line
				end
			end
		end
		table.insert(lines, "")
	end

	-- footer summary
	table.insert(lines, "  " .. string.rep("─", 60))
	table.insert(lines, string.format("  Summary: %d steps · %d assertions · %d shared refs · %d sections", t.steps, t.assertions, t.shared_refs, t.sections))

	return lines
end

local function jump_to_source()
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	local src = line_to_src[cursor_line]
	if not src then
		vim.notify("No step under cursor to jump to", vim.log.levels.WARN)
		return
	end
	local winid = vim.fn.bufwinid(src_buf)
	if winid == -1 then
		-- source buffer not visible: reopen its window
		vim.cmd("wincmd p")
		if vim.api.nvim_win_is_valid(vim.api.nvim_get_current_win()) then
			vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), src_buf)
		end
		winid = vim.api.nvim_get_current_win()
	end
	vim.api.nvim_win_set_cursor(winid, { src, 0 })
	vim.api.nvim_set_current_win(winid)
end

--- Open the outline window for the given source YAML buffer.
--- @param opts table? { bufnr = N }
function M.open(opts)
	opts = opts or {}
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	src_buf = bufnr

	local data = outline.build(bufnr)
	if not data then
		vim.notify("No Gherkio sections found in this buffer (need setup/steps/teardown)", vim.log.levels.WARN)
		return
	end

	local src_path = vim.api.nvim_buf_get_name(bufnr)

	local lines = render_lines(data, src_path)

	if not outline_buf or not vim.api.nvim_buf_is_valid(outline_buf) then
		outline_buf = vim.api.nvim_create_buf(false, true)
	end
	vim.api.nvim_buf_set_lines(outline_buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(outline_buf, "bufhidden", "hide")
	vim.api.nvim_buf_set_option(outline_buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(outline_buf, "modifiable", false)

	local wc = config.get("results_window") or {}
	local focus = opts.focus ~= nil and opts.focus or (wc.focus_on_open == true)

	if outline_win and vim.api.nvim_win_is_valid(outline_win) then
		vim.api.nvim_win_set_buf(outline_win, outline_buf)
	else
		local layout = wc.outline_layout or "vsplit"
		if layout == "float" then
			local width = math.floor(vim.o.columns * (wc.width or 0.5))
			local height = math.floor(vim.o.lines * (wc.height or 0.6))
			outline_win = vim.api.nvim_open_win(outline_buf, focus, {
				relative = "editor",
				row = math.floor((vim.o.lines - height) / 2),
				col = math.floor((vim.o.columns - width) / 2),
				width = width,
				height = height,
				style = "minimal",
				border = wc.border or "rounded",
			})
		else
			vim.cmd("botright vsplit")
			outline_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(outline_win, outline_buf)
			local width = math.max(40, math.floor(vim.o.columns * (wc.width or 0.5)))
			vim.api.nvim_win_set_width(outline_win, width)
		end
	end

	if not focus then
		-- keep cursor in source window
		local src_win = vim.fn.bufwinid(bufnr)
		if src_win ~= -1 then
			vim.api.nvim_set_current_win(src_win)
		end
	end

	-- keymaps
	vim.keymap.set("n", "q", close_outline, { buffer = outline_buf, silent = true, nowait = true })
	vim.keymap.set("n", "<Esc>", function()
		if vim.w.gherkio_outline_help_open then
			-- help handling placeholder (help popup planned later)
			vim.w.gherkio_outline_help_open = nil
		else
			close_outline()
		end
	end, { buffer = outline_buf, silent = true, nowait = true })
	vim.keymap.set("n", "<CR>", jump_to_source, { buffer = outline_buf, silent = true, desc = "Jump to Step in YAML Source" })

	-- syntax (simple): highlight checkmarks/lines
	vim.api.nvim_buf_set_option(outline_buf, "syntax", "")
	vim.cmd([[syn match GherkioOutlineHeader /^  scenario:/ contained]])
	vim.cmd([[syn match GherkioOutlineSection /── .* ──/]])
	vim.cmd([[syn match GherkioOutlineCheck /✓ .*/ contained]])
	vim.cmd([[syn match GherkioOutlineUse /\[use\]/]])
	vim.cmd([[syn match GherkioOutlineSave /\[save: .*\]/]])
	vim.cmd([[hi def link GherkioOutlineHeader Comment]])
	vim.cmd([[hi def link GherkioOutlineSection Title]])
	vim.cmd([[hi def link GherkioOutlineCheck String]])
	vim.cmd([[hi def link GherkioOutlineUse Special]])
	vim.cmd([[hi def link GherkioOutlineSave Identifier]])
end

return M
