-- Auto-detecting picker backend resolution for gherkio.nvim
-- Order of preference: snacks.picker → fzf-lua → telescope → builtin vim.ui.select
-- A user may force one via config: picker = "snacks" | "fzf" | "telescope" | "builtin"
-- or provide a custom function = picker(items, opts, on_choice).

local M = {}

local cache = { resolved = nil }

---@param name string
---@return boolean available
local function is_available(name)
  if name == "snacks" then
    local ok, _ = pcall(require, "snacks.picker")
    return ok
  elseif name == "fzf" then
    local has, _ = pcall(require, "fzf-lua.config")
    if not has then
      -- fzf-lua may load config lazily; fall back to checking the module itself
      has = pcall(require, "fzf-lua")
    end
    return has
  elseif name == "telescope" then
    local ok, _ = pcall(require, "telescope.pickers")
    return ok
  elseif name == "builtin" then
    return true
  end
  return false
end

-- Convert standard vim.ui.select-style opts into backend-specific prompt text
local function prompt_text(opts)
  return opts and (opts.prompt or opts.kind and opts.kind or "Select") or "Select"
end

-- ── Backends ──────────────────────────────────────────────────────────────────
local backends = {}

backends.snacks = function(items, opts, on_choice)
  local Snacks = require("snacks")
  local picker_ok, _ = pcall(function()
    return Snacks.picker
  end)
  if not picker_ok then
    error("snacks.picker unavailable")
  end
  local prompt = prompt_text(opts)
  Snacks.picker.select({
    items = items,
    prompt = prompt,
    on_select = function(item, idx)
      on_choice(item, idx)
    end,
  })
end

backends.fzf = function(items, opts, on_choice)
	local fzf_lua = require("fzf-lua")
	local prompt = prompt_text(opts)
	fzf_lua.fzf_exec(items, {
		prompt = prompt,
		actions = {
			["default"] = function(selected)
				if selected and selected[1] then
					on_choice(selected[1])
				end
			end,
		},
	})
end

backends.telescope = function(items, opts, on_choice)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  pickers.new({}, {
    prompt_title = prompt_text(opts),
    finder = finders.new_table({
      results = items,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry,
          ordinal = entry,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      local actions = require("telescope.actions")
      actions.select_default:replace(function()
        local selection = actions_state.get_selected_entry(prompt_bufnr)
        actions.close(prompt_bufnr)
        on_choice(selection.value)
      end)
      return true
    end,
  }):find()
end

backends.builtin = function(items, opts, on_choice)
  vim.ui.select(items, opts, on_choice)
end

-- ── Resolution ────────────────────────────────────────────────────────────────
local ORDER = { "snacks", "fzf", "telescope", "builtin" }

local CANONICAL = {
	snacks = "snacks",
	fzf = "fzf",
	["fzf-lua"] = "fzf",
	telescope = "telescope",
	builtin = "builtin",
	["vim.ui.select"] = "builtin",
}

--- Resolve which backend to use. For \"auto\", probes installed plugins once.
--- @return string backend_key
function M.resolve()
	if cache.resolved then
		return cache.resolved
	end
	local picker = require("gherkio.config").get("picker") or "auto"
	if type(picker) == "string" then
		local lowered = string.lower(picker)
		if lowered ~= "auto" then
			local canonical = CANONICAL[lowered]
			if canonical and is_available(canonical) then
				cache.resolved = canonical
				return canonical
			end
			if canonical == nil then
				vim.notify(
					string.format("Gherkio: unknown picker '%s', auto-detecting", picker),
					vim.log.levels.WARN
				)
			elseif not is_available(canonical) then
				vim.notify(
					string.format("Gherkio: picker '%s' requested but not installed, auto-detecting", picker),
					vim.log.levels.WARN
				)
			end
		end
	end

	for _, name in ipairs(ORDER) do
		if is_available(name) then
			cache.resolved = name
			return name
		end
	end

	cache.resolved = "builtin"
	return "builtin"
end

--- Invoke the resolved backend.
--- Falls back to builtin if the configured backend errors.
function M.select(items, opts, on_choice)
  local cfg = require("gherkio.config")
  local picker = cfg.get("picker")
  if type(picker) == "function" then
    local ok, err = pcall(picker, items, opts, on_choice)
    if not ok then
      vim.notify("Gherkio: custom picker failed (" .. tostring(err) .. "), using vim.ui.select", vim.log.levels.WARN)
      vim.ui.select(items, opts, on_choice)
    end
    return
  end

  local backend_key = M.resolve()
  local ok, err = pcall(backends[backend_key], items, opts, on_choice)
  if not ok then
    vim.notify(
      string.format("Gherkio: picker '%s' failed (%s), falling back to vim.ui.select", backend_key, tostring(err)),
      vim.log.levels.WARN
    )
    vim.ui.select(items, opts, on_choice)
  end
end

--- Clear the resolved-backend cache (used by tests / after config reload)
function M.reset()
  cache.resolved = nil
end

return M
