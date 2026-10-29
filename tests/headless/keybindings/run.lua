-- Headless behavior tests for lua/opencode/keybindings.
--
-- These tests run in their own Neovim process (see run.sh) with isolated HOME,
-- XDG directories, shada and TMPDIR.  They exercise real buffer-local mappings
-- and an injected fake interrupt action; no OpenCode service is contacted.

local this = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(this, ":p:h")
local root = vim.fn.fnamemodify(dir, ":h:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local keybindings = require("opencode.keybindings")
local session_action = require("opencode.actions.session")

local failures = {}
local count = 0

local function fail(name, message)
  failures[#failures + 1] = ("%s: %s"):format(name, message)
end

local function eq(name, expected, actual)
  if not vim.deep_equal(actual, expected) then
    fail(name, ("expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

local function truthy(name, value)
  if not value then
    fail(name, "expected truthy, got " .. vim.inspect(value))
  end
end

local function falsy(name, value)
  if value then
    fail(name, "expected falsy, got " .. vim.inspect(value))
  end
end

local function test(name, fn)
  count = count + 1
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    fail(name, err)
  end
end

local function new_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "" })
  vim.api.nvim_set_current_buf(buf)
  return buf
end

local function feed(keys)
  local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcodes, "x", false)
end

local function wait(ms)
  vim.wait(ms, function()
    return false
  end, 5)
end

local function buffer_mapping(lhs, mode)
  local map = vim.fn.maparg(lhs, mode, false, true)
  return type(map) == "table" and map.buffer == 1 and map or nil
end

local function cleanup(buf)
  keybindings.detach(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

local function single_config()
  return { keybinds = { ["session.interrupt"] = "escape" } }
end

local function double_config()
  return { keybinds = { ["session.interrupt"] = "escapeescape" } }
end

test("default single Escape interrupts only after Insert is left", function()
  local buf = new_buffer()
  local calls = 0
  keybindings.attach(buf, {
    cli_config = single_config(),
    actions = { ["session.interrupt"] = function()
      calls = calls + 1
    end },
  })

  -- The first Escape is handled by native Insert mode, not by our mapping.
  feed("ihello<Esc>")
  eq("insert escape did not interrupt", 0, calls)
  eq("left insert", "n", vim.api.nvim_get_mode().mode)
  truthy("buffer-local Normal mapping", buffer_mapping("<Esc>", "n"))
  falsy("no Insert mapping", buffer_mapping("<Esc>", "i"))
  falsy("no Visual mapping", buffer_mapping("<Esc>", "x"))

  feed("<Esc>")
  eq("Normal escape interrupts once", 1, calls)
  feed("<Esc>")
  eq("second Normal escape interrupts again", 2, calls)
  cleanup(buf)
end)

test("double Escape needs two presses within the sequence timeout", function()
  local buf = new_buffer()
  local calls = 0
  keybindings.attach(buf, {
    cli_config = double_config(),
    actions = { ["session.interrupt"] = function()
      calls = calls + 1
    end },
    sequence_timeout = 80,
  })

  feed("<Esc>")
  eq("one press does not interrupt immediately", 0, calls)
  wait(120)
  eq("the pending sequence expires", 0, calls)
  eq("pending sequence cleared", nil, keybindings.get_state(buf).pending)

  feed("<Esc>")
  wait(25)
  feed("<Esc>")
  eq("second press inside timeout interrupts", 1, calls)
  eq("no stale pending sequence", nil, keybindings.get_state(buf).pending)
  wait(120)

  feed("<Esc>")
  feed("<Esc>")
  eq("two quick presses interrupt once", 2, calls)

  feed("<Esc>")
  wait(120)
  feed("<Esc>")
  eq("second press after timeout does not interrupt", 2, calls)
  cleanup(buf)
end)

test("an intervening edit or motion resets a pending sequence", function()
  local buf = new_buffer({ "one", "two", "three" })
  local calls = 0
  keybindings.attach(buf, {
    cli_config = double_config(),
    actions = { ["session.interrupt"] = function()
      calls = calls + 1
    end },
    sequence_timeout = 200,
  })

  feed("<Esc>")
  feed("j")
  feed("<Esc>")
  eq("motion reset the sequence", 0, calls)
  wait(250)

  feed("<Esc>")
  feed("iX<Esc>")
  feed("<Esc>")
  eq("mode/edit change reset the sequence", 0, calls)
  cleanup(buf)
end)

test("a non-repeated leader sequence uses a native buffer-local mapping", function()
  local buf = new_buffer()
  local calls = 0
  local previous_timeout = vim.o.timeoutlen
  vim.o.timeoutlen = 100
  keybindings.attach(buf, {
    cli_config = {
      keybinds = {
        leader = "space",
        ["session.interrupt"] = "<leader>i",
      },
    },
    actions = { ["session.interrupt"] = function()
      calls = calls + 1
    end },
  })

  feed("<Space>i")
  eq("leader sequence interrupts", 1, calls)
  feed("<Space>")
  wait(150)
  eq("an incomplete leader sequence does nothing", 1, calls)
  vim.o.timeoutlen = previous_timeout
  cleanup(buf)
end)

test("Visual Escape is left to Neovim and never interrupts", function()
  local buf = new_buffer({ "selected text" })
  local calls = 0
  keybindings.attach(buf, {
    cli_config = single_config(),
    actions = { ["session.interrupt"] = function()
      calls = calls + 1
    end },
  })

  feed("v")
  eq("visual mode entered", "v", vim.api.nvim_get_mode().mode)
  feed("<Esc>")
  eq("visual escape did not interrupt", 0, calls)
  eq("visual escape returned to Normal", "n", vim.api.nvim_get_mode().mode)
  feed("<Esc>")
  eq("Normal escape still works", 1, calls)
  cleanup(buf)
end)

test("ordinary code buffers are untouched", function()
  local input = new_buffer()
  local calls = 0
  keybindings.attach(input, {
    cli_config = single_config(),
    actions = { ["session.interrupt"] = function()
      calls = calls + 1
    end },
  })

  local code = new_buffer({ "local x = 1" })
  falsy("code buffer not attached", keybindings.is_attached(code))
  falsy("code buffer has no Normal Escape mapping", buffer_mapping("<Esc>", "n"))
  feed("<Esc>")
  eq("code buffer did not interrupt", 0, calls)

  keybindings.attach(code, {
    cli_config = single_config(),
    actions = { ["session.interrupt"] = function()
      calls = calls + 1
    end },
  })
  feed("<Esc>")
  eq("explicitly attached buffer interrupts", 1, calls)

  cleanup(input)
  cleanup(code)
end)

test("reattaching replaces the old action and detach leaves no mapping", function()
  local buf = new_buffer()
  local first = 0
  local second = 0
  local first_state = keybindings.attach(buf, {
    cli_config = single_config(),
    actions = { ["session.interrupt"] = function()
      first = first + 1
    end },
  })
  eq("one mapping after first attach", 1, #first_state.mappings)

  local second_state = keybindings.attach(buf, {
    cli_config = single_config(),
    actions = { ["session.interrupt"] = function()
      second = second + 1
    end },
  })
  eq("no duplicate mapping after reattach", 1, #second_state.mappings)
  feed("<Esc>")
  eq("old action replaced", 0, first)
  eq("new action runs once", 1, second)

  keybindings.detach(buf)
  falsy("detached", keybindings.is_attached(buf))
  falsy("mapping removed", buffer_mapping("<Esc>", "n"))
  feed("<Esc>")
  eq("detached action does not run", 1, second)

  keybindings.attach(buf, {
    cli_config = single_config(),
    actions = { ["session.interrupt"] = function()
      first = first + 1
    end },
  })
  feed("<Esc>")
  eq("reattach works", 1, first)
  cleanup(buf)
end)

test("mapping works in a second window and is removed when the buffer is wiped", function()
  local buf = new_buffer()
  local calls = 0
  keybindings.attach(buf, {
    cli_config = single_config(),
    actions = { ["session.interrupt"] = function()
      calls = calls + 1
    end },
  })
  local original = vim.api.nvim_get_current_win()
  vim.cmd("split")
  local other = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(other, buf)
  feed("<Esc>")
  eq("action runs in the second window", 1, calls)
  vim.api.nvim_set_current_win(original)
  vim.api.nvim_buf_delete(buf, { force = true })
  eq("state removed with the buffer", nil, keybindings.get_state(buf))
end)

test("a temporary cli.json drives the attached mapping", function()
  local cli_path = vim.fn.tempname() .. "/cli.json"
  vim.fn.mkdir(vim.fn.fnamemodify(cli_path, ":h"), "p")
  vim.fn.writefile({
    vim.json.encode({
      keybinds = {
        leader = "space",
        ["session.interrupt"] = "escapeescape",
      },
      leader = { timeout = 250 },
    }),
  }, cli_path)

  local buf = new_buffer()
  local calls = 0
  local state = keybindings.attach(buf, {
    cli_path = cli_path,
    actions = { ["session.interrupt"] = function()
      calls = calls + 1
    end },
    sequence_timeout = 80,
  })
  eq("leader from cli.json", "<Space>", state.resolved.leader)
  eq("timeout from cli.json", 250, state.resolved.leader_timeout)
  eq("sequence from cli.json", "<Esc><Esc>", state.resolved.bindings["session.interrupt"].keys[1])

  feed("<Esc><Esc>")
  eq("cli.json sequence interrupts", 1, calls)
  cleanup(buf)
  vim.fn.delete(cli_path)
  vim.fn.delete(vim.fn.fnamemodify(cli_path, ":h"), "rf")
end)

test("session_action.interrupt is usable from a mapping and treats idle as no-op", function()
  local buf = new_buffer()
  local started = 0
  local completed = {}
  local controller = {
    interrupt = function(_, callback)
      started = started + 1
      callback(nil, { interrupted = false, idle = true })
    end,
  }
  keybindings.attach(buf, {
    cli_config = single_config(),
    actions = {
      ["session.interrupt"] = function()
        session_action.interrupt(controller, function(err, result)
          completed[#completed + 1] = { err = err, result = result }
        end)
      end,
    },
  })

  feed("<Esc>")
  eq("controller invoked", 1, started)
  eq("callback invoked", 1, #completed)
  eq("idle is not an error", nil, completed[1].err)
  eq("idle result", true, completed[1].result.idle)
  eq("not interrupted", false, completed[1].result.interrupted)
  cleanup(buf)
end)

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  io.stderr:write(("%d/%d headless keybindings tests failed\n"):format(#failures, count))
  vim.cmd("cquit 1")
else
  print(("ok %d headless keybindings tests"):format(count))
end
