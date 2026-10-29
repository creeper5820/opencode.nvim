local M = {}

local MINIMUM_NVIM = { 0, 10, 0 }

local function version_at_least(current, minimum)
  for index = 1, math.max(#current, #minimum) do
    local left = current[index] or 0
    local right = minimum[index] or 0
    if left ~= right then
      return left > right
    end
  end
  return true
end

local function current_config()
  local ok, config_or_error = pcall(function()
    return require("opencode").get_config()
  end)
  if not ok then
    return nil, config_or_error
  end
  return config_or_error
end

local function executable(config)
  local cmd = config and config.cmd or "opencode"
  if type(cmd) == "table" then
    return cmd[1]
  end
  return cmd
end

local function cli_version(bin)
  if type(bin) ~= "string" or bin == "" then
    return nil, "cmd is empty"
  end
  local ok, output = pcall(vim.fn.system, { bin, "--version" })
  if not ok then
    return nil, tostring(output)
  end
  if vim.v.shell_error ~= 0 then
    return nil, ("%s --version exited with %d"):format(bin, vim.v.shell_error)
  end
  local line = tostring(output):match("^%s*([^\r\n]+)")
  if not line or line == "" then
    return nil, "empty version output"
  end
  return line
end

--- Collect health results without touching user services.
--- @param rt table|nil Assembled runtime; fetched lazily when omitted.
--- @return table[] list of { level, message }
function M.collect(rt)
  local results = {}
  local version = vim.version()
  local current = { version.major, version.minor, version.patch }
  local version_text = ("%d.%d.%d"):format(current[1], current[2], current[3])

  if version_at_least(current, MINIMUM_NVIM) then
    results[#results + 1] = { level = "ok", message = "Neovim " .. version_text }
  else
    results[#results + 1] = {
      level = "error",
      message = ("Neovim %s is too old; >= 0.10.0 is required"):format(version_text),
    }
  end

  if type(vim.uv) == "table" then
    results[#results + 1] = { level = "ok", message = "vim.uv is available" }
  else
    results[#results + 1] = {
      level = "error",
      message = "vim.uv is unavailable; Neovim >= 0.10.0 is required",
    }
  end

  local config
  if rt and rt.config then
    config = rt.config
  else
    local config_error
    config, config_error = current_config()
    if config == nil then
      results[#results + 1] = {
        level = "error",
        message = "configuration is invalid: " .. tostring(config_error),
      }
      return results
    end
  end

  results[#results + 1] = { level = "ok", message = "configuration is valid" }

  local bin = executable(config)
  if type(bin) ~= "string" or bin == "" then
    results[#results + 1] = { level = "error", message = "cmd does not name an executable" }
  elseif vim.fn.executable(bin) ~= 1 then
    results[#results + 1] = {
      level = "error",
      message = ('OpenCode executable "%s" is not executable or not on PATH'):format(bin),
    }
  else
    results[#results + 1] = { level = "ok", message = 'OpenCode executable: ' .. bin }
    local cli, cli_error = cli_version(bin)
    if cli then
      results[#results + 1] = { level = "ok", message = "OpenCode " .. cli }
    else
      results[#results + 1] = {
        level = "warn",
        message = "cannot run " .. bin .. " --version: " .. tostring(cli_error),
      }
    end
  end

  if rt and rt.terminal then
    local state = rt.terminal:get_state()
    if state.running then
      results[#results + 1] = {
        level = "ok",
        message = ("TUI running (pid %s) in %s"):format(tostring(state.pid), tostring(state.cwd)),
      }
      results[#results + 1] = {
        level = state.open and "ok" or "info",
        message = state.open and "TUI window is visible" or "TUI window is hidden (process stays alive)",
      }
    else
      results[#results + 1] = { level = "info", message = "TUI is not running" }
    end
  elseif rt == nil then
    local ok, opencode = pcall(require, "opencode")
    if ok and type(opencode) == "table" and type(opencode.get_state) == "function" then
      local state_ok, state = pcall(opencode.get_state)
      if state_ok and type(state) == "table" and state.terminal then
        if state.terminal.running then
          results[#results + 1] = {
            level = "ok",
            message = ("TUI running (pid %s) in %s"):format(
              tostring(state.terminal.pid), tostring(state.terminal.cwd)
            ),
          }
        else
          results[#results + 1] = { level = "info", message = "TUI is not running" }
        end
      end
    end
  end

  return results
end

function M.check()
  vim.health.start("opencode.nvim")
  for _, result in ipairs(M.collect(nil)) do
    if result.level == "ok" then
      vim.health.ok(result.message)
    elseif result.level == "warn" then
      vim.health.warn(result.message)
    elseif result.level == "error" then
      vim.health.error(result.message)
    else
      vim.health.info(result.message)
    end
  end
end

return M
