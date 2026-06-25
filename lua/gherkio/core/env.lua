local M = {}

-- Cache for environment context (refreshed on project change)
local env_context_cache = {}
local last_project_root = nil

-- Safe async run wrapper with fallback for older Neovim versions
local function run_command_sync(cmd)
  if vim.system then
    local result = vim.system(cmd, { text = true }):wait()
    return result.stdout, result.stderr, result.code
  else
    local output = vim.fn.system(cmd)
    return output, "", vim.v.shell_error
  end
end

-- Traverse up to find .gherkio/ directory
local function find_project_root(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr or 0)
  local start_dir = ""
  if filepath ~= "" then
    start_dir = vim.fs.dirname(filepath)
  else
    start_dir = vim.fn.getcwd()
  end

  local match = vim.fs.find(".gherkio", { path = start_dir, upward = true, type = "directory" })
  if #match > 0 then
    return vim.fs.dirname(match[1])
  end

  -- Fallback: check current working directory
  if vim.fn.isdirectory(vim.fn.getcwd() .. "/.gherkio") == 1 then
    return vim.fn.getcwd()
  end

  return nil
end

-- Fetch environment context from gherkio CLI
local function fetch_env_context(project_root)
  -- Check cache first
  if env_context_cache.project_root == project_root then
    return env_context_cache.data
  end

  local cmd = { "gherkio", "env", "context", "--json" }
  local stdout, stderr, code = run_command_sync(cmd)

  if code ~= 0 or not stdout or stdout == "" then
    vim.notify(string.format("Failed to get gherkio env context: %s", stderr or "unknown error"), vim.log.levels.ERROR)
    return nil
  end

  local ok, data = pcall(vim.json.decode, stdout)
  if not ok then
    vim.notify(string.format("Failed to parse gherkio env context: %s", data), vim.log.levels.ERROR)
    return nil
  end

  -- Cache the result
  env_context_cache = {
    project_root = project_root,
    data = data
  }

  return data
end

-- Get available environments
function M.get_available_envs(bufnr)
  local project_root = find_project_root(bufnr)
  if not project_root then
    return {}
  end

  local ctx = fetch_env_context(project_root)
  if not ctx then
    return {}
  end

  local envs = {}
  for _, env in ipairs(ctx.environments or {}) do
    table.insert(envs, env.name)
  end
  return envs
end

-- Get accounts for a specific environment
function M.get_available_accounts(bufnr, env_name)
  local project_root = find_project_root(bufnr)
  if not project_root or not env_name or env_name == "" then
    return {}
  end

  local ctx = fetch_env_context(project_root)
  if not ctx or not ctx.accounts then
    return {}
  end

  return ctx.accounts[env_name] or {}
end

-- Get auto-select hints from context
function M.get_auto_select(bufnr)
  local project_root = find_project_root(bufnr)
  if not project_root then
    return nil
  end

  local ctx = fetch_env_context(project_root)
  if not ctx then
    return nil
  end

  return ctx.autoSelect
end

-- Get the full environment context (for programmatic use)
function M.get_context(bufnr)
  local project_root = find_project_root(bufnr)
  if not project_root then
    return nil
  end

  return fetch_env_context(project_root)
end

-- Invalidate cache (call when project structure might have changed)
function M.invalidate_cache()
  env_context_cache = {}
  last_project_root = nil
end

-- Check if we have a valid project
function M.is_gherkio_project(bufnr)
  return find_project_root(bufnr) ~= nil
end

-- Get project root
function M.get_project_root(bufnr)
  return find_project_root(bufnr)
end

return M
