-- Gherkio Telescope extension for browsing and running test files.
--
-- Provides a fuzzy-find picker showing all .gherkio/tests/ and .gherkio/schemas/
-- files with actions to edit, split, or run the selected test.
--
-- If Telescope is not installed this module is a no-op.

local env = require("gherkio.core.env")
local runner = require("gherkio.core.runner")

local M = {}

-- ── File scanning ──────────────────────────────────────────────────
local function scan_gherkio_files(project_root)
  local pattern = project_root .. "/.gherkio/**/*"
  local files = {}
  local seen = {}
  local matches = vim.fn.glob(pattern, false, true)
  for _, f in ipairs(matches) do
    if vim.fn.isdirectory(f) == 0 then
      local is_report = f:match("/%.gherkio/reports/")
      local is_session = f:match("session%.yaml$")
      if not is_report and not is_session and not seen[f] then
        seen[f] = true
        table.insert(files, f)
      end
    end
  end

  table.sort(files)
  return files
end

-- ── Actions ────────────────────────────────────────────────────────
local function run_test_action(full_path)
  local project_root = env.get_project_root()
  if not project_root then
    vim.notify("No Gherkio project found.", vim.log.levels.WARN)
    return
  end

  require("gherkio").run_test({ file = full_path })
end

-- ── Telescope Extension ────────────────────────────────────────────
local has_telescope, telescope = pcall(require, "telescope")

if has_telescope then
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local finders = require("telescope.finders")
  local pickers = require("telescope.pickers")
  local sorters = require("telescope.sorters")
  local conf = require("telescope.config").values

  function M.find_tests(opts)
    opts = opts or {}
    local project_root = env.get_project_root()
    if not project_root then
      vim.notify("No Gherkio project found.", vim.log.levels.WARN)
      return
    end

    local files = scan_gherkio_files(project_root)
    if #files == 0 then
      vim.notify("No Gherkio test files found.", vim.log.levels.INFO)
      return
    end

    pickers.new(opts, {
      prompt_title = " Gherkio Find (<CR>:edit, <C-r>:run, <C-d>:dir, <C-a>:all) ",
      finder = finders.new_table {
        results = files,
        entry_maker = function(filepath)
          local relative = filepath:sub(#project_root + 2)
          -- Strip ".gherkio/" prefix for cleaner display
          local short_path = relative:match("^%.gherkio/(.+)$") or relative
          local entry_type = short_path:match("^([^/]+)") or ""
          local icons = {
            tests = "  ",
            schemas = "  ",
            credentials = "  ",
            environments = "  ",
          }
          local icon = icons[entry_type] or "  "
          return {
            value = filepath,
            ordinal = short_path,
            display = function(entry)
              return icon .. short_path
            end,
            path = filepath,
            is_test = entry_type == "tests",
          }
        end,
      },
      previewer = conf.grep_previewer(opts),
      sorter = sorters.get_fzy_sorter(opts),
      attach_mappings = function(prompt_bufnr, map)
        -- <CR> → open file
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            vim.cmd("edit " .. selection.path)
          end
        end)

        -- <C-v> → vsplit
        map("i", "<C-v>", function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            vim.cmd("vsplit " .. selection.path)
          end
        end)

        -- <C-s> → split
        map("i", "<C-s>", function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            vim.cmd("split " .. selection.path)
          end
        end)

        -- <C-r> → run test (only for test files, not schemas)
        map("i", "<C-r>", function()
          local selection = action_state.get_selected_entry()
          if selection and selection.is_test then
            actions.close(prompt_bufnr)
            run_test_action(selection.path)
          elseif selection then
            vim.notify("Cannot run a schema file.", vim.log.levels.WARN)
          end
        end)

        -- <C-d> → run all tests in directory of selected test file
        map("i", "<C-d>", function()
          local selection = action_state.get_selected_entry()
          if selection and selection.is_test then
            actions.close(prompt_bufnr)
            local dir = vim.fs.dirname(selection.path)
            require("gherkio").run_test({ file = dir })
          elseif selection then
            vim.notify("Selected file is not a test file.", vim.log.levels.WARN)
          end
        end)

        -- <C-a> → run all tests in project
        map("i", "<C-a>", function()
          actions.close(prompt_bufnr)
          require("gherkio").run_test({ project = true })
        end)

        -- <C-e> → edit (alias)
        map("i", "<C-e>", function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            vim.cmd("edit " .. selection.path)
          end
        end)

        return true
      end,
    }):find()
  end
else
  -- Telescope not available — no-op
  function M.find_tests(_opts)
    vim.notify("gherkio.nvim: 'telescope.nvim' is required for the test finder.", vim.log.levels.WARN)
  end
end

return M
