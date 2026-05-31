local runner = require("gherkio.core.runner")
local config = require("gherkio.config")

local M = {}

-- Standard checkhealth entrypoint
function M.check()
  local health = vim.health or require("health")
  
  health.start("gherkio")

  -- 1. Verify gherkio binary existence in path
  if vim.fn.executable("gherkio") == 1 then
    local version_out = vim.fn.system("gherkio --version"):gsub("[\r\n]", "")
    health.ok(string.format("gherkio binary found in PATH: %s", version_out))
  else
    health.error("gherkio binary not found in PATH.", {
      "Install it using: go install github.com/muhfaris/gherkio@latest",
      "Ensure your $GOPATH/bin or $GOBIN is added to your system's PATH variable."
    })
  end

  -- 2. Verify Gherkio project root detection
  local project_root = runner.find_project_root(0)
  if project_root then
    health.ok(string.format("Gherkio project root detected: %s", project_root))
    
    -- Check environments folder
    local envs = runner.get_available_envs(project_root)
    if #envs > 0 then
      health.ok(string.format("Detected %d test environments: %s", #envs, table.concat(envs, ", ")))
    else
      health.warn("No environment configurations detected in '.gherkio/environments/'.", {
        "Tests will run without environment variables unless environments are defined.",
        "Create a file like '.gherkio/environments/local.yaml' to set up variables."
      })
    end
  else
    health.warn("No active Gherkio project detected from the current workspace directory.", {
      "Open Neovim inside a directory containing an initialized Gherkio project, or run `gherkio init` to create one."
    })
  end

  -- 3. Verify user configurations
  local picker_setting = config.get("picker")
  if type(picker_setting) == "string" then
    if picker_setting == "vim.ui.select" then
      health.ok("Picker backend configured to standard 'vim.ui.select'.")
    else
      health.warn(string.format("Unknown picker setting string: '%s'. Defaulting back to 'vim.ui.select'.", picker_setting))
    end
  elseif type(picker_setting) == "function" then
    health.ok("Picker backend configured to custom function wrapper.")
  else
    health.error("Invalid 'picker' configuration type in setup options.")
  end

  local keys = config.get("keys")
  if type(keys) == "table" then
    health.ok("Keymaps structure is valid.")
  else
    health.error("Invalid 'keys' structure in setup options.")
  end
end

return M
