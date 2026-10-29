local test = require("tests.support.test")
local terminal_module = require("opencode.terminal")

local function tempdir(label)
  local base = "/tmp/opencode"
  vim.fn.mkdir(base, "p")
  local dir = ("%s/nvim-terminal-%s-%d-%s"):format(
    base, label, vim.uv.os_getpid(), tostring(vim.uv.hrtime())
  )
  vim.fn.mkdir(dir, "p")
  return dir
end

local function config(overrides)
  local value = {
    cmd = "sh",
    args = {},
    cwd = nil,
    project = {},
    session = {},
    window = { layout = "right", size = 40 },
    paste = { bracketed = true, ready_delay = 0, submit_delay = 0 },
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

test.describe("terminal lifecycle", function()
  test.it("builds project, continue, session and prompt arguments", function()
    local dir = tempdir("args")
    local cfg = config({
      cmd = { "bunx", "opencode" },
      args = { "--standalone" },
      session = { continue = true, id = "ses_123", prompt = "hello" },
    })
    local cmd, cwd, err = terminal_module.build_command({ directory = dir }, cfg)
    test.truthy(cmd, tostring(err))
    test.equal(dir, cwd)
    test.deep_equal({
      "bunx",
      "opencode",
      "--standalone",
      "--session",
      "ses_123",
      "--prompt",
      "hello",
      dir,
    }, cmd)

    local continued = terminal_module.build_command({}, config({
      cmd = "opencode",
      session = { continue = true },
      project = { root = dir },
    }))
    test.deep_equal({ "opencode", "--continue", dir }, continued)

    local fresh = terminal_module.build_command({ session = false, continue = false }, config({
      cmd = "opencode",
      session = { id = "ses_old", continue = true, prompt = "old" },
      project = { root = dir },
    }))
    test.deep_equal({ "opencode", "--prompt", "old", dir }, fresh)
    vim.fn.delete(dir, "rf")
  end)

  test.it("rejects a missing project directory", function()
    local cmd, cwd, err = terminal_module.build_command(
      { directory = "/tmp/opencode/does-not-exist-" .. tostring(vim.uv.hrtime()) },
      config({ cmd = "opencode" })
    )
    test.equal(nil, cmd)
    test.equal(nil, cwd)
    test.matches("does not exist", err.message)
  end)

  test.it("sends bracketed paste with CR normalized and token guarded", function()
    local term = terminal_module.new({ config = config() })
    local sent = {}
    term.send = function(_, data)
      sent[#sent + 1] = data
      return true
    end
    test.truthy(term:paste("one\r\ntwo\rthree\27[201~four"))
    test.equal("\27[200~one\ntwo\nthree[201~four\27[201~", sent[1])
  end)

  test.it("keeps paste and submit as separate writes", function()
    local term = terminal_module.new({ config = config() })
    local sent = {}
    term.send = function(_, data)
      sent[#sent + 1] = data
      return true
    end
    test.truthy(term:paste("line 1\nline 2"))
    test.truthy(term:submit({ delay = 0 }))
    test.equal(2, #sent)
    test.equal("\r", sent[2])
  end)

  test.it("opens, hides without stopping, reveals and stops its own job", function()
    local dir = tempdir("lifecycle")
    local term = terminal_module.new({
      config = config({
        cmd = { "sh", "-c", "printf ready; sleep 20" },
      }),
      env = { TERM = "xterm-256color" },
    })
    local ok, err = term:open({ directory = dir })
    test.truthy(ok, tostring(err))
    test.truthy(term:is_running())
    test.truthy(term:is_open())
    local pid = term.state.pid
    test.truthy(pid and pid > 0)

    test.truthy(term:send("x"))
    term:close()
    test.falsy(term:is_open())
    test.truthy(term:is_running())

    local shown, show_error = term:open()
    test.truthy(shown, tostring(show_error))
    test.truthy(term:is_open())

    term:stop()
    test.falsy(term:is_running())
    test.falsy(term:is_open())
    vim.wait(1000, function()
      local ok, result = pcall(vim.uv.kill, pid, 0)
      return not (ok and result == 0)
    end)
    vim.fn.delete(dir, "rf")
  end)

  test.it("remembers a manually adjusted vertical width across close/open", function()
    local dir = tempdir("width")
    local term = terminal_module.new({
      config = config({
        cmd = { "sh", "-c", "sleep 20" },
        window = { layout = "right", size = 40, remember_width = true },
      }),
      env = { TERM = "xterm-256color" },
    })
    test.truthy(term:open({ directory = dir }))
    local win = term.state.win
    test.truthy(win)
    local target = math.min(37, vim.o.columns - 2)
    pcall(vim.api.nvim_win_set_width, win, target)
    test.equal(target, vim.api.nvim_win_get_width(win))

    term:close()
    test.truthy(term:open())
    test.equal(target, vim.api.nvim_win_get_width(term.state.win))

    term:close()
    term.state.remembered_width = vim.o.columns + 500
    test.truthy(term:open())
    test.truthy(vim.api.nvim_win_get_width(term.state.win) <= math.max(1, vim.o.columns - 1))
    term:stop()
    vim.fn.delete(dir, "rf")
  end)

  test.it("can disable width memory", function()
    local dir = tempdir("width-off")
    local term = terminal_module.new({
      config = config({
        cmd = { "sh", "-c", "sleep 20" },
        window = { layout = "right", size = 40, remember_width = false },
      }),
      env = { TERM = "xterm-256color" },
    })
    test.truthy(term:open({ directory = dir }))
    pcall(vim.api.nvim_win_set_width, term.state.win, math.min(30, vim.o.columns - 2))
    term:close()
    test.truthy(term:open())
    test.equal(40, vim.api.nvim_win_get_width(term.state.win))
    term:stop()
    vim.fn.delete(dir, "rf")
  end)
end)
