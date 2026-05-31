local config = require("gherkio.config")

local M = {}

-- Safely copy text to system register and unnamed register
function M.set_contents(text)
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)
end

-- Open a beautiful floating window showing the preview of the cURL command
function M.show_preview_float(text)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
  vim.api.nvim_buf_set_option(bufnr, "filetype", "sh")

  -- Split text into lines to populate the buffer
  local lines = {}
  for line in text:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  -- Calculate width/height based on percentage configurations
  local total_cols = vim.o.columns
  local total_lines = vim.o.lines
  local width = math.floor(total_cols * config.get("preview").width)
  local height = math.floor(total_lines * config.get("preview").height)

  -- Keep float bounds reasonable
  if width < 30 then width = 30 end
  if height < 5 then height = 5 end

  -- Center window
  local row = math.floor((total_lines - height) / 2)
  local col = math.floor((total_cols - width) / 2)

  local opts = {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = config.get("preview").border or "rounded",
    title = " Gherkio cURL Preview ",
    title_pos = "center",
  }

  local win = vim.api.nvim_open_win(bufnr, true, opts)

  -- Make window read-only
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  vim.api.nvim_buf_set_option(bufnr, "readonly", true)

  -- Auto-close mappings
  if config.get("preview").auto_close then
    local function close()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true, nowait = true })
    vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, silent = true, nowait = true })
    vim.keymap.set("n", "<CR>", close, { buffer = bufnr, silent = true, nowait = true })
  end
end

return M
