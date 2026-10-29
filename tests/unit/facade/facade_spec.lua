local test = require("tests.support.test")

local function tempdir()
  local dir = ("/tmp/opencode/nvim-facade-%d-%s"):format(
    vim.uv.os_getpid(), tostring(vim.uv.hrtime())
  )
  vim.fn.mkdir(dir, "p")
  return dir
end

test.describe("public facade", function()
  test.it("opens a terminal, hides and stops it, and keeps Terminal mode wiring", function()
    pcall(function()
      require("opencode").stop()
    end)
    test.reload()
    local opencode = require("opencode")
    local dir = tempdir()
    opencode.setup({
      cmd = { "sh", "-c", "printf ready; sleep 20" },
      window = { layout = "right", size = 40 },
    })

    local ok, err = opencode.open({ directory = dir })
    test.truthy(ok, tostring(err))
    test.truthy(opencode.is_open())
    test.truthy(opencode.is_running())
    test.equal("terminal", vim.bo[vim.api.nvim_get_current_buf()].buftype)

    local commands = vim.api.nvim_get_commands({})
    for _, name in ipairs({
      "OpenCode", "OpenCodeToggle", "OpenCodeOpen", "OpenCodeClose",
      "OpenCodeStop", "OpenCodeContinue", "OpenCodeSession", "OpenCodeSubmit",
      "OpenCodeHealth",
    }) do
      test.truthy(commands[name], "missing command " .. name)
    end
    test.falsy(commands.OpenCodeFocusInput)
    test.falsy(commands.OpenCodeFocusSession)

    local state = opencode.get_state()
    test.truthy(state.terminal.running)
    test.equal(nil, state.router)
    test.equal(nil, state.focus)

    test.truthy(opencode.focus())
    test.truthy(opencode.paste("hello"))
    test.truthy(opencode.submit())

    opencode.close()
    test.falsy(opencode.is_open())
    test.truthy(opencode.is_running())
    test.truthy(opencode.open())
    test.truthy(opencode.is_open())

    local pid = opencode.get_state().terminal.pid
    opencode.stop()
    test.falsy(opencode.is_running())
    local function process_alive(value)
      local alive, result = pcall(vim.uv.kill, value, 0)
      return alive and result == 0
    end
    vim.wait(2000, function()
      return not process_alive(pid)
    end)
    test.falsy(process_alive(pid))
    pcall(opencode.stop)
    vim.fn.delete(dir, "rf")
  end)
end)
