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

--- Collect health results without touching buffers. Exposed for tests.
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

  local ok, config_or_error = pcall(function()
    return require("opencode").get_config()
  end)
  if not ok then
    results[#results + 1] = {
      level = "error",
      message = "configuration is invalid: " .. tostring(config_or_error),
    }
    return results
  end

  results[#results + 1] = { level = "ok", message = "configuration is valid" }
  local url = config_or_error.server.url
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
  for _, result in ipairs(M.collect()) do
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
