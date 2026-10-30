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

  test.it("resizes with buffer-local terminal keys and pins its width", function()
    local dir = tempdir("resize-keys")
    local term = terminal_module.new({
      config = config({
        cmd = { "sh", "-c", "sleep 20" },
        window = {
          layout = "right",
          size = 40,
          remember_width = true,
          resize_keys = { shrink = "<C-Left>", grow = "<C-Right>", step = 3 },
        },
      }),
      env = { TERM = "xterm-256color" },
    })
    test.truthy(term:open({ directory = dir }))
    local win, buf = term.state.win, term.state.buf
    test.truthy(vim.wo[win].winfixwidth)
    test.equal(1, vim.bo[buf].scrollback)

    vim.api.nvim_set_current_win(win)
    local shrink = vim.fn.maparg("<C-Left>", "t", false, true)
    test.equal(buf, shrink.buffer == 1 and buf or nil)
    shrink.callback()
    test.equal(37, vim.api.nvim_win_get_width(win))
    vim.fn.maparg("<C-Right>", "t", false, true).callback()
    test.equal(40, vim.api.nvim_win_get_width(win))

    test.equal("<Nop>", vim.fn.maparg("<C-d>", "n"))
    term:stop()
    vim.fn.delete(dir, "rf")
  end)

  test.it("drops mouse wheel over the unfocused OpenCode window only", function()
    local dir = tempdir("wheel")
    local term = terminal_module.new({
      config = config({
        cmd = { "sh", "-c", "i=0; while [ $i -lt 300 ]; do echo line$i; i=$((i+1)); done; sleep 20" },
        window = { layout = "right", size = 40 },
      }),
      env = { TERM = "xterm-256color" },
    })
    test.truthy(term:open({ directory = dir }))
    local win = term.state.win
    vim.wait(500)
    vim.cmd("stopinsert")
    local editor
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= win then
        editor = w
      end
    end
    vim.api.nvim_set_current_win(editor)
    local lines = {}
    for i = 1, 500 do
      lines[i] = "text" .. i
    end
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(editor), 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(editor, { 1, 0 })

    -- Headless Neovim has no UI to deliver real mouse events, so drive the
    -- guard mapping with a stubbed mouse position.
    local guard = vim.fn.maparg("<ScrollWheelDown>", "n", false, true)
    test.equal("OpenCode: guard mouse wheel", guard.desc)
    local original_getmousepos = vim.fn.getmousepos
    local original_feedkeys = vim.api.nvim_feedkeys
    local fed = {}
    local over
    vim.fn.getmousepos = function()
      return { winid = over }
    end
    vim.api.nvim_feedkeys = function(keys)
      fed[#fed + 1] = keys
    end
    local ok, err = pcall(function()
      over = win
      guard.callback()
      test.equal(0, #fed)
      over = editor
      guard.callback()
      test.equal(1, #fed)
      test.equal(vim.api.nvim_replace_termcodes("<ScrollWheelDown>", true, false, true), fed[1])
    end)
    vim.fn.getmousepos = original_getmousepos
    vim.api.nvim_feedkeys = original_feedkeys
    test.truthy(ok, tostring(err))
    term:stop()
    test.equal("", vim.fn.maparg("<ScrollWheelDown>", "n"))
    vim.fn.delete(dir, "rf")
  end)

  test.it("never becomes the only window in its tab", function()
    local dir = tempdir("not-alone")
    local term = terminal_module.new({
      config = config({
        cmd = { "sh", "-c", "sleep 20" },
        window = { layout = "right", size = 40, remember_width = true },
      }),
      env = { TERM = "xterm-256color" },
    })
    test.truthy(term:open({ directory = dir }))
    local win = term.state.win
    vim.api.nvim_set_current_win(win)
    vim.cmd("only")
    vim.wait(500, function()
      return #vim.api.nvim_tabpage_list_wins(0) > 1
    end)
    test.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    test.truthy(vim.api.nvim_win_is_valid(win))
    test.equal(40, vim.api.nvim_win_get_width(win))
    term:stop()
    vim.fn.delete(dir, "rf")
  end)
end)
