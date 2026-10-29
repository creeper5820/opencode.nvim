local test = require("tests.support.test")
local config = require("opencode.config")
local health = require("opencode.health")

local function capture_health(fn)
  local saved = {
    start = vim.health.start,
    ok = vim.health.ok,
    info = vim.health.info,
    warn = vim.health.warn,
    error = vim.health.error,
  }
  local messages = {}
  local function capture(level)
    return function(message)
      messages[#messages + 1] = level .. ":" .. message
    end
  end
  vim.health.start = function(name)
    messages[#messages + 1] = "start:" .. name
  end
  vim.health.ok = capture("ok")
  vim.health.info = capture("info")
  vim.health.warn = capture("warn")
  vim.health.error = capture("error")

  local ok, err = pcall(fn)
  vim.health.start = saved.start
  vim.health.ok = saved.ok
  vim.health.info = saved.info
  vim.health.warn = saved.warn
  vim.health.error = saved.error
  return ok, err, messages
end

local function messages(results)
  local out = {}
  for _, item in ipairs(results) do
    out[#out + 1] = item.level .. ":" .. item.message
  end
  return table.concat(out, "\n")
end

test.describe("health", function()
  test.it("reports Neovim, vim.uv, configuration and the executable", function()
    local cfg = config.resolve({ cmd = "sh" })
    local text = messages(health.collect({ config = cfg }))
    test.matches("Neovim %d", text)
    test.matches("vim%.uv", text)
    test.matches("configuration is valid", text)
    test.matches("OpenCode executable: sh", text)
  end)

  test.it("reports a missing executable as an error", function()
    local cfg = config.resolve({ cmd = "definitely-not-an-opencode-binary" })
    local text = messages(health.collect({ config = cfg }))
    test.matches("not executable", text)
  end)

  test.it("reports terminal visibility and process state", function()
    local cfg = config.resolve({ cmd = "sh" })
    local running = health.collect({
      config = cfg,
      terminal = {
        get_state = function()
          return { running = true, open = false, pid = 123, cwd = "/tmp/opencode/project" }
        end,
      },
    })
    test.matches("TUI running %(pid 123%)", messages(running))
    test.matches("TUI window is hidden", messages(running))

    local stopped = health.collect({
      config = cfg,
      terminal = {
        get_state = function()
          return { running = false }
        end,
      },
    })
    test.matches("TUI is not running", messages(stopped))
  end)

  test.it("check() runs in headless Neovim", function()
    local ok, err, output = capture_health(function()
      health.check()
    end)
    test.truthy(ok, tostring(err))
    test.truthy(#output > 0)
  end)
end)
