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

local function normalize_level(level)
  if level == "ok" or level == "info" or level == "warn" or level == "error" then
    return level
  end
  return "info"
end

--- Collect keybinding diagnostics without re-entering the public health facade.
--- The keybindings module is optional: if it is absent, report info, never an
--- error.  `opencode.keybindings.health()` reads the same configuration keys as
--- the runtime attachment path and returns `{ level, code, message }` entries.
--- @param config table|nil resolved configuration; fetched when omitted
--- @return table[] list of { level = "ok"|"warn"|"error"|"info", message = string }
function M.collect_keybindings(config)
  local results = {}
  local module_ok, keybindings = pcall(require, "opencode.keybindings")
  if not module_ok or type(keybindings) ~= "table" then
    results[1] = { level = "info", message = "OpenCode semantic keybindings are not installed" }
    return results
  end

  if type(config) ~= "table" then
    config = current_config()
  end
  if type(config) ~= "table" then
    results[1] = { level = "info", message = "OpenCode semantic keybindings are not configured" }
    return results
  end

  local keybindings_config = config.keybindings
  if type(keybindings_config) ~= "table" then
    results[1] = { level = "info", message = "OpenCode semantic keybindings are not configured" }
    return results
  end
  if not keybindings_config.enabled then
    results[1] = { level = "info", message = "OpenCode semantic keybindings are disabled" }
    return results
  end

  local ok, diagnostics = pcall(keybindings.health, {
    cli_path = keybindings_config.cli_path,
    read_cli = keybindings_config.read_cli,
    overrides = keybindings_config.overrides,
    sequence_timeout = keybindings_config.sequence_timeout,
  })
  if not ok then
    results[1] = {
      level = "warn",
      message = "cannot resolve OpenCode keybindings: " .. tostring(diagnostics),
    }
    return results
  end

  for _, item in ipairs(diagnostics or {}) do
    results[#results + 1] = {
      level = normalize_level(item.level),
      message = "keybindings: " .. tostring(item.message),
    }
  end
  if #results == 0 then
    results[1] = { level = "ok", message = "keybindings: OpenCode keybindings resolved" }
  end
  return results
end

--- Collect core health results without touching buffers. Exposed for tests.
--- Keybinding diagnostics are kept separate so `require("opencode").health()`
--- can continue appending them without duplicating them.
--- @return table[] list of { level = "ok"|"warn"|"error"|"info", message = string }
function M.collect()
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

  local config, config_error = current_config()
  if config == nil then
    results[#results + 1] = {
      level = "error",
      message = "configuration is invalid: " .. tostring(config_error),
    }
    return results
  end

  results[#results + 1] = { level = "ok", message = "configuration is valid" }
  local url = config.server.url
  results[#results + 1] = { level = "info", message = "server.url = " .. url }

  if url:lower():match("^https://") then
    results[#results + 1] = {
      level = "error",
      message = "HTTPS server URLs are not supported yet; use an http:// URL",
    }
  end

  return results
end

function M.check()
  vim.health.start("opencode.nvim")
  local results = M.collect()
  local config = current_config()
  if config ~= nil then
    vim.list_extend(results, M.collect_keybindings(config))
  end
  for _, result in ipairs(results) do
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
