local test = require("tests.support.test")
local harness = require("tests.support.harness")

local PREAMBLE = [=[
local repo = vim.opt.runtimepath:get()[1]
package.path = repo .. "/?.lua;" .. repo .. "/?/init.lua;" .. package.path

local status = require("opencode.status")

local function fail(message)
  error(message, 0)
end

local function assert_true(value, message)
  if not value then
    fail(message or "assertion failed")
  end
end

local function assert_equal(expected, actual, message)
  if expected ~= actual then
    fail((message or "values differ") .. (": expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

local function contains(haystack, needle)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    fail(("missing %q in %q"):format(needle, tostring(haystack)))
  end
end

local function absent(haystack, needle)
  if type(haystack) == "string" and haystack:find(needle, 1, true) then
    fail(("did not expect %q in %q"):format(needle, haystack))
  end
end

local function setup_windows()
  local code = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local message = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(message, vim.api.nvim_create_buf(false, true))
  vim.cmd("split")
  local input = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(input, vim.api.nvim_create_buf(false, true))
  vim.api.nvim_set_current_win(code)
  return { code = code, message = message, input = input }
end

local snapshot = {
  session = { id = "ses_1", title = "Fix login" },
  project = { root = "/tmp/opencode/project" },
  agent = { id = "build", name = "Build" },
  model = { provider_id = "anthropic", id = "claude-sonnet" },
  connection = "connected",
  submission = "idle",
  execution = "streaming",
}
]=]

local function run_child(name, body)
  local h = harness.new()
  local ok, result = pcall(function()
    return h:spawn(PREAMBLE .. "\n" .. body .. '\nio.stdout:write("\\nOK\\n")')
  end)
  h:cleanup()
  if not ok then
    error(name .. ": " .. tostring(result), 0)
  end
  test.equal(
    0,
    result.code,
    name .. "\n" .. (result.stderr ~= "" and result.stderr or result.stdout)
  )
  test.matches("OK", result.stdout, name)
end

test.describe("opencode.status headless winbar", function()
  test.it("writes only the attached windows and leaves global/other windows alone", function()
    run_child("window local", [=[
status.reset()
local w = setup_windows()
vim.o.statusline = "GLOBAL_STATUS"
vim.o.winbar = "GLOBAL_WINBAR"
local global_winbar = vim.api.nvim_get_option_value("winbar", { scope = "global" })
vim.wo[w.code].winbar = "CODE_WINBAR"
vim.wo[w.message].winbar = "OLD_MESSAGE"
vim.wo[w.input].winbar = "OLD_INPUT"

assert_true(status.attach({
  message_window = w.message,
  input_window = w.input,
  submit_hint = "Submit <C-s>",
}))
assert_true(status.is_attached())
status.update(snapshot)

local message = vim.wo[w.message].winbar
local input = vim.wo[w.input].winbar
contains(message, "Session: Fix login")
contains(message, "Project: project")
contains(message, "Agent: Build")
contains(message, "Model: anthropic/claude-sonnet")
contains(message, "Connection: connected")
contains(message, "Submission: idle")
contains(message, "Execution: streaming")
contains(input, "Session: Fix login")
contains(input, "Submit <C-s>")
absent(input, "Project:")
absent(input, "Agent:")

assert_equal("CODE_WINBAR", vim.wo[w.code].winbar)
assert_equal("GLOBAL_STATUS", vim.o.statusline)
assert_equal(global_winbar, vim.api.nvim_get_option_value("winbar", { scope = "global" }))

status.set_connection("reconnecting")
message = vim.wo[w.message].winbar
input = vim.wo[w.input].winbar
contains(message, "Connection: reconnecting")
contains(message, "Execution: streaming")
contains(input, "Connection: reconnecting")
assert_equal("CODE_WINBAR", vim.wo[w.code].winbar)

status.update({ submission = "submitting" })
message = vim.wo[w.message].winbar
contains(message, "Submission: submitting")
contains(message, "Connection: reconnecting")

status.update({ session = { title = "Fix login (renamed)" } })
message = vim.wo[w.message].winbar
contains(message, "Session: Fix login (renamed)")
assert_equal("ses_1", status.get_state().session.id)
assert_equal("reconnecting", status.get_state().connection)
assert_equal("submitting", status.get_state().submission)

status.update({ session = { title = "100% done %{expr}\nnext" } })
message = vim.wo[w.message].winbar
contains(message, "100%% done %%{expr} next")
assert_true(not message:find("\n", 1, true))

status.detach()
assert_equal("OLD_MESSAGE", vim.wo[w.message].winbar)
assert_equal("OLD_INPUT", vim.wo[w.input].winbar)
assert_equal("CODE_WINBAR", vim.wo[w.code].winbar)
assert_equal(global_winbar, vim.api.nvim_get_option_value("winbar", { scope = "global" }))
]=])
  end)

  test.it("survives window close, spinner lifecycle, rebuild and reattach", function()
    run_child("lifecycle", [=[
status.reset()
local w = setup_windows()
status.attach({
  message_window = w.message,
  input_window = w.input,
  submit_hint = "Submit <C-s>",
})
status.update(snapshot)

assert_true(status.is_spinning())
local before = vim.wo[w.message].winbar
assert_true(status._tick())
assert_true(before ~= vim.wo[w.message].winbar)

vim.api.nvim_win_close(w.input, true)
assert_true(not vim.api.nvim_win_is_valid(w.input))
assert_true(status.is_attached())
assert_true(status.is_spinning())
status.set_connection("offline")
contains(vim.wo[w.message].winbar, "Connection: offline")

vim.cmd("split")
local input2 = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(input2, vim.api.nvim_create_buf(false, true))
status.attach({
  message_window = w.message,
  input_window = input2,
  submit_hint = "Submit <C-s>",
})
contains(vim.wo[w.message].winbar, "Session: Fix login")
contains(vim.wo[w.message].winbar, "Connection: offline")
contains(vim.wo[w.message].winbar, "Execution: streaming")
assert_true(status.is_spinning())

vim.api.nvim_set_current_win(input2)
vim.api.nvim_win_close(w.message, true)
assert_true(status.is_attached())
assert_true(status.is_spinning())
status.set_execution("interrupted")
assert_true(not status.is_spinning())
contains(vim.wo[input2].winbar, "Execution: interrupted")

vim.api.nvim_win_close(input2, true)
assert_true(not status.is_attached())
assert_true(not status.is_spinning())

local w2 = setup_windows()
vim.wo[w2.message].winbar = "RESTORE_MESSAGE"
vim.wo[w2.input].winbar = "RESTORE_INPUT"
status.attach({
  message_window = w2.message,
  input_window = w2.input,
  submit_hint = "Submit <C-s>",
})
contains(vim.wo[w2.message].winbar, "Session: Fix login")
contains(vim.wo[w2.message].winbar, "Execution: interrupted")
assert_true(not status.is_spinning())

status.detach()
assert_equal("RESTORE_MESSAGE", vim.wo[w2.message].winbar)
assert_equal("RESTORE_INPUT", vim.wo[w2.input].winbar)
local unchanged_message = vim.wo[w2.message].winbar
local unchanged_input = vim.wo[w2.input].winbar
status.update({ connection = "connected" })
assert_equal(unchanged_message, vim.wo[w2.message].winbar)
assert_equal(unchanged_input, vim.wo[w2.input].winbar)
assert_true(not status.is_attached())

status.attach({
  message_window = w2.message,
  input_window = w2.input,
  submit_hint = "Submit <C-s>",
})
contains(vim.wo[w2.message].winbar, "Connection: connected")
contains(vim.wo[w2.message].winbar, "Execution: interrupted")
]=])
  end)

  test.it("notifies only for critical failures", function()
    run_child("notifications", [=[
local calls = {}
local original_notify = vim.notify
vim.notify = function(message, level)
  calls[#calls + 1] = { message = message, level = level }
end

local ok, err = pcall(function()
  status.reset()
  local w = setup_windows()
  status.attach({ message_window = w.message, input_window = w.input })
  status.update({
    session = { id = "ses_1", title = "Fix login" },
    connection = "connected",
    submission = "idle",
    execution = "idle",
  })

  status.set_connection("reconnecting")
  status.set_submission("submitting")
  status.set_execution("streaming")
  assert_equal(0, #calls)

  status.set_submission("failed", { error = { message = "rejected", code = "E_SUBMIT" } })
  assert_equal(1, #calls)
  contains(calls[1].message, "submission failed")
  contains(calls[1].message, "rejected")
  assert_equal(vim.log.levels.ERROR, calls[1].level)
  contains(vim.wo[w.message].winbar, "Submission: failed")

  status.set_submission("failed", { error = "rejected again" })
  assert_equal(1, #calls)

  status.set_execution("failed", { error = "boom" })
  assert_equal(2, #calls)
  contains(calls[2].message, "execution failed")
  contains(vim.wo[w.message].winbar, "Execution: failed")

  status.set_execution("idle")
  status.set_execution("failed", { error = "boom again" })
  assert_equal(3, #calls)
end)

vim.notify = original_notify
if not ok then
  error(err, 0)
end
]=])
  end)
end)
