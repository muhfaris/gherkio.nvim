local M = {}

M.defaults = {
	keys = {
		open_modal = "<leader>gm",
		copy_curl = "<leader>gc",
		paste_dsl = "<leader>gp",
		preview_request = "<leader>gi",
		repeat_last = "<leader>gl",
		run_all = "<leader>ga",
		run_under_cursor = "<leader>gr",
		switch_env = "<leader>ge",
		switch_account = "<leader>gk",
	},
	picker = "vim.ui.select",
	quickfix = {
		auto_open = true,
		auto_close = true,
	},
	preview = {
		width = 0.6,
		height = 0.4,
		border = "rounded",
		auto_close = true,
	},
	results_window = {
		auto_open = true,
		layout = "vsplit", -- "float" | "vsplit" | "split"
		width = 0.35, -- percentage of screen for vsplit, or float
		height = 0.3, -- percentage of screen for split, or float
		border = "rounded",
	},
	default_env = "",
	default_account = "",
	lsp_schema = {
		enabled = true,
	},
}

M.options = {}

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

-- Retrieve option safely
function M.get(key, fallback)
	if M.options[key] ~= nil then
		return M.options[key]
	end
	return M.defaults[key] or fallback
end

return M
