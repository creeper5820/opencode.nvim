local test = require("tests.support.test")
local terminal_module = require("opencode.terminal")

local function temp_project()
  local base = "/tmp/opencode"
  vim.fn.mkdir(base, "p")
  local dir = ("%s/nvim-tui-smoke-%d-%s"):format(
    base, vim.uv.os_getpid(), tostring(vim.uv.hrtime())
  )
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "isolated OpenCode TUI smoke project" }, dir .. "/README")
  return dir
end

test.describe("real OpenCode TUI smoke", function()
  if test.skip_if(vim.fn.executable("opencode") ~= 1, "starts an isolated official TUI",
    "opencode executable is not available") then
    return
  end

  test.it("starts the official TUI in an isolated project and stops it cleanly", function()
    local dir = temp_project()
    local term = terminal_module.new({
      config = {
        cmd = "opencode",
        args = { "--standalone" },
        cwd = dir,
        project = {},
        session = {},
        window = { layout = "right", size = 80 },
        paste = { bracketed = true, ready_delay = 0, submit_delay = 0 },
      },
      env = { TERM = "xterm-256color" },
    })
    local ok, err = term:open({ directory = dir })
    test.truthy(ok, tostring(err))
    test.truthy(term:is_running())

    local pid = term.state.pid
    local rendered = vim.wait(8000, function()
      local buf = term.state.buf
      if not term:is_running() or not buf or not vim.api.nvim_buf_is_valid(buf) then
        return false
      end
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      for _, line in ipairs(lines) do
        if line ~= "" then
          return true
        end
      end
      return false
    end, 100)
    test.truthy(rendered, "official TUI did not render terminal output in time")

    vim.wait(750, function()
      return false
    end)
    local marker = "opencode-nvim-smoke"
    test.truthy(term:send(marker))
    local echoed = vim.wait(4000, function()
      local buf = term.state.buf
      if not term:is_running() or not buf or not vim.api.nvim_buf_is_valid(buf) then
        return false
      end
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      return text:find(marker, 1, true) ~= nil
    end, 100)
    test.truthy(echoed, "official TUI did not receive PTY input")

    term:stop()
    test.falsy(term:is_running())
    local function process_alive(value)
      local ok, result = pcall(vim.uv.kill, value, 0)
      return ok and result == 0
    end
    vim.wait(2000, function()
      return not process_alive(pid)
    end)
    test.falsy(process_alive(pid), "OpenCode process was left running")
    vim.fn.delete(dir, "rf")
  end)
end)
