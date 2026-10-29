local test = require("tests.support.test")

local function tempdir()
  local dir = ("/tmp/opencode/nvim-facade-%d-%s"):format(
    vim.uv.os_getpid(), tostring(vim.uv.hrtime())
  )
  vim.fn.mkdir(dir, "p")
  return dir
end

local function has_mapping(buf, lhs)
  local raw = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  local wanted = vim.fn.keytrans(raw)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.lhs == lhs or map.lhsraw == raw then
      return true
    end
    if type(map.lhsraw) == "string" and vim.fn.keytrans(map.lhsraw) == wanted then
      return true
    end
  end
  return false
end

test.describe("public facade", function()
  test.it("opens a terminal, routes focus and primitives, hides and stops", function()
    pcall(function()
      require("opencode").stop()
    end)
    test.reload()
    local opencode = require("opencode")
    local dir = tempdir()
    opencode.setup({
      cmd = { "sh", "-c", "printf ready; sleep 20" },
      window = { layout = "right", size = 40, start_insert = false },
      keybindings = { read_cli = false },
    })

    local ok, err = opencode.open({ directory = dir })
    test.truthy(ok, tostring(err))
    test.truthy(opencode.is_open())
    test.truthy(opencode.is_running())
    test.equal("composer", opencode.get_focus())

    local commands = vim.api.nvim_get_commands({})
    for _, name in ipairs({
      "OpenCode", "OpenCodeToggle", "OpenCodeOpen", "OpenCodeClose",
      "OpenCodeStop", "OpenCodeContinue", "OpenCodeSession", "OpenCodeSubmit",
      "OpenCodeFocusInput", "OpenCodeFocusSession", "OpenCodeHealth",
    }) do
      test.truthy(commands[name], "missing command " .. name)
    end

    local state = opencode.get_state()
    test.truthy(state.router.attached)
    test.truthy(has_mapping(state.terminal.buffer, "<C-x>n"))
    test.deep_equal({}, vim.api.nvim_buf_get_keymap(state.terminal.buffer, "i"))

    test.truthy(opencode.focus_session())
    test.equal("session", opencode.get_focus())
    test.equal("session", opencode.get_focus_state().region)
    test.truthy(opencode.focus_input())
    test.equal("composer", opencode.get_focus())

    test.truthy(opencode.map_primitive("gl", "page_down"))
    test.truthy(opencode.primitive("page_down", 2))
    test.truthy(opencode.unmap_primitive("gl"))

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
