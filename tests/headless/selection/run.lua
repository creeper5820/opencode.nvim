-- Headless tests for Visual selection actions against the real 03 sidebar,
-- a real floating input buffer and a fake 05A session controller.
--
-- Run through tests/headless/selection/run.sh so HOME, every XDG directory and
-- shada point inside a disposable directory under /tmp/opencode.

local root = assert(vim.env.OPENCODE_SELECTION_TEST_ROOT, "OPENCODE_SELECTION_TEST_ROOT is required")

local function isolated(value)
  return type(value) == "string" and value:sub(1, #"/tmp/opencode/") == "/tmp/opencode/"
end

for _, name in ipairs({
  "HOME",
  "XDG_CONFIG_HOME",
  "XDG_DATA_HOME",
  "XDG_STATE_HOME",
  "XDG_CACHE_HOME",
  "TMPDIR",
}) do
  if not isolated(vim.env[name]) then
    io.stderr:write(
      ("refusing to run selection tests: %s is not isolated under /tmp/opencode; use tests/headless/selection/run.sh\n")
        :format(name)
    )
    vim.cmd("cquit 2")
  end
end

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/?.lua",
  package.path,
}, ";")

local context = require("opencode.context")
local ui = require("opencode.ui")
local actions = require("opencode.actions.selection")

-- Keep headless logs focused on assertions rather than mode/undo messages.
vim.o.showmode = false
vim.o.ruler = false
vim.o.report = 9999
vim.o.more = false
vim.o.selection = "inclusive"

local passed, failed = 0, 0
local current_test = "?"

local function report(ok, message)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(("FAIL [%s]: %s\n"):format(current_test, message))
  end
end

local function eq(actual, expected, label)
  report(vim.deep_equal(actual, expected), ("%s: expected %s, got %s"):format(
    label or "value",
    vim.inspect(expected),
    vim.inspect(actual)
  ))
end

local function ok(value, label)
  report(not not value, label or "expected truthy")
end

local function contains(haystack, needle, label)
  report(
    type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
    ("%s: missing %q in %q"):format(label or "value", needle, tostring(haystack))
  )
end

local function absent(haystack, needle, label)
  report(
    type(haystack) ~= "string" or haystack:find(needle, 1, true) == nil,
    ("%s: did not expect %q in %q"):format(label or "value", needle, tostring(haystack))
  )
end

local function test(name, fn)
  current_test = name
  local success, err = pcall(fn)
  if not success then
    failed = failed + 1
    io.stderr:write(("ERROR [%s]: %s\n"):format(name, tostring(err)))
  end
end

local function keys(sequence, mode)
  local termcodes = vim.api.nvim_replace_termcodes(sequence, true, false, true)
  vim.api.nvim_feedkeys(termcodes, mode or "xt", false)
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function float_windows()
  local count = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative ~= "" then
      count = count + 1
    end
  end
  return count
end

local function new_session()
  local session = {
    prompts = {},
    handler = nil,
  }
  function session.prompt(_, text, callback)
    session.prompts[#session.prompts + 1] = text
    if session.handler ~= nil then
      session.handler(text, callback)
    else
      callback(nil, { accepted = true })
    end
  end
  return session
end

local code_win
local code_buf
local session
local notices
local submit_calls
local unique_name = 0

local function fresh()
  actions._reset()
  ui._reset()
  vim.cmd("silent! only")
  vim.cmd("silent! enew!")
  vim.bo.modifiable = true
  vim.o.selection = "inclusive"
  ui.setup({ width = 40, input_height = 6 })
  ui.on_submit(nil)
  session = new_session()
  notices = {}
  submit_calls = 0
  actions.setup({
    ui = ui,
    session = session,
    notify = function(message, level)
      notices[#notices + 1] = { message = message, level = level }
    end,
  })
  code_win = vim.api.nvim_get_current_win()
  code_buf = vim.api.nvim_get_current_buf()
end

local function set_code(code, filetype)
  vim.api.nvim_set_current_win(code_win)
  vim.api.nvim_set_current_buf(code_buf)
  vim.api.nvim_buf_set_lines(code_buf, 0, -1, false, code)
  vim.bo[code_buf].filetype = filetype or "lua"
  unique_name = unique_name + 1
  pcall(vim.api.nvim_buf_set_name, code_buf, vim.fn.getcwd() .. "/selection-" .. unique_name .. ".lua")
end

-- Select with a real Visual motion so actions see getpos("v")/mode() state.
local function visual(mode, start_row, start_col, end_row, end_col)
  vim.api.nvim_set_current_win(code_win)
  vim.api.nvim_set_current_buf(code_buf)
  vim.api.nvim_win_set_cursor(code_win, { start_row, start_col - 1 })
  vim.cmd("normal! " .. mode)
  vim.api.nvim_win_set_cursor(code_win, { end_row, end_col - 1 })
end

local function open_question_explicit(code, filetype)
  set_code(code, filetype)
  local selection = { mode = "V", start = { row = 1 }, ["end"] = { row = #code } }
  return actions.question_selection({ buffer = code_buf, selection = selection })
end

-- 1. Public interface.
test("public interface", function()
  for _, name in ipairs({
    "send_selection",
    "question_selection",
    "submit_question",
    "cancel_question",
    "is_question_open",
    "get_question_state",
    "get_last_question",
    "setup",
  }) do
    eq(type(actions[name]), "function", name .. " is exported")
  end
end)

-- 2. Real float, real keymap, acceptance closes immediately.
test("question float is real and accepted submission closes it", function()
  fresh()
  set_code({ "local one = 1", "local two = 2" }, "lua")
  local expected = assert(context.format(assert(context.from_selection(code_buf, {
    mode = "V",
    start = { row = 1 },
    ["end"] = { row = 2 },
  }))))
  ui.set_draft("draft survives")
  ui.on_submit(function()
    submit_calls = submit_calls + 1
  end)

  visual("V", 1, 1, 2, 1)
  local opened, qstate = actions.question_selection()
  ok(opened, tostring(qstate))
  ok(actions.is_question_open(), "question is open")
  ok(vim.api.nvim_win_is_valid(qstate.win), "float window is valid")
  local config = vim.api.nvim_win_get_config(qstate.win)
  ok(config.relative ~= "", "float is positioned near the selection")
  eq(true, vim.bo[qstate.buf].modifiable, "float buffer is editable")
  eq("nofile", vim.bo[qstate.buf].buftype, "float buffer is scratch")
  eq("opencode_input", vim.bo[qstate.buf].filetype, "float reuses the input filetype")
  eq(false, vim.bo[qstate.buf].swapfile, "float has no swap file")

  vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "Why these lines?" })
  keys("<C-s>")
  eq(1, #session.prompts, "submit calls prompt once")
  eq("Why these lines?\n\n" .. expected, session.prompts[1], "prompt contains question and shared context")
  eq(false, vim.api.nvim_win_is_valid(qstate.win), "float closes on acceptance")
  eq(false, vim.api.nvim_buf_is_valid(qstate.buf), "float buffer is cleaned up")
  eq(false, actions.is_question_open())
  eq("Why these lines?", actions.get_last_question())
  eq(true, ui.is_open(), "sidebar opens after acceptance")
  eq(ui.get_windows().input, vim.api.nvim_get_current_win(), "input is focused")
  eq("draft survives", ui.get_draft(), "sidebar draft is untouched")
  eq(0, submit_calls, "selection question never invokes the sidebar submit callback")
  eq(0, float_windows(), "no float window is left behind")
end)

-- 3. Async acceptance closes on the prompt-accepted callback, not execution.
test("async acceptance closes before execution finishes", function()
  fresh()
  local captured
  session.handler = function(text, callback)
    captured = { text = text, callback = callback }
  end
  set_code({ "alpha", "beta" }, "lua")
  ui.set_draft("keep draft")
  local opened, qstate = open_question_explicit({ "alpha", "beta" })
  ok(opened)
  vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "pending question" })
  keys("<C-s>")
  eq(1, #session.prompts)
  ok(captured, "prompt callback is pending")
  ok(actions.is_question_open(), "float stays open while acceptance is pending")
  eq(true, actions.get_question_state().submitting)
  eq("keep draft", ui.get_draft(), "draft is untouched while pending")

  captured.callback(nil, { accepted = true })
  eq(false, actions.is_question_open(), "accepted prompt closes immediately")
  eq(true, ui.is_open(), "sidebar opens on acceptance")
  eq("keep draft", ui.get_draft())
  eq("pending question", actions.get_last_question())
end)

-- 4. Failure keeps the float/text and retry works.
test("failure keeps the float and retry submits again", function()
  fresh()
  local attempts = 0
  local retry_callback
  session.handler = function(_, callback)
    attempts = attempts + 1
    if attempts == 1 then
      callback({ code = "rejected", message = "try again" })
    else
      retry_callback = callback
    end
  end
  set_code({ "alpha" }, "lua")
  ui.set_draft("unchanged")
  local opened, qstate = open_question_explicit({ "alpha" })
  ok(opened)
  vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "retry me" })
  keys("<C-s>")
  eq(1, attempts)
  ok(actions.is_question_open(), "failed prompt keeps the float open")
  eq({ "retry me" }, lines(qstate.buf), "failed prompt keeps the text")
  eq("unchanged", ui.get_draft(), "failure does not touch the sidebar draft")
  eq(1, #notices, "failure is displayed")
  contains(notices[1].message, "try again", "error message")

  keys("<C-s>")
  eq(2, attempts, "retry calls prompt again")
  ok(retry_callback, "retry is pending")
  retry_callback(nil, { accepted = true })
  eq(false, actions.is_question_open())
  eq(true, ui.is_open())
  eq("unchanged", ui.get_draft())
end)

-- 5. Empty questions, duplicate submit and Esc cancellation.
test("empty, duplicate and cancelled questions never prompt", function()
  fresh()
  set_code({ "alpha" }, "lua")
  ui.set_draft("keep")
  local opened, qstate = open_question_explicit({ "alpha" })
  ok(opened)

  keys("<C-s>")
  eq(0, #session.prompts, "empty question does not call prompt")
  ok(actions.is_question_open(), "empty question leaves the float open")

  vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "   ", "" })
  keys("<C-s>")
  eq(0, #session.prompts, "whitespace-only question does not call prompt")

  local captured
  session.handler = function(_, callback)
    captured = callback
  end
  vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "one request" })
  keys("<C-s>")
  keys("<C-s>")
  eq(1, #session.prompts, "duplicate submit is blocked while pending")
  ok(captured, "request is pending")
  ok(actions.is_question_open())

  captured(nil, { accepted = true })
  eq(false, actions.is_question_open())
  eq(true, ui.is_open())
  eq("keep", ui.get_draft(), "question flow never changes the sidebar draft")
end)

test("normal-mode Esc cancels without a request", function()
  fresh()
  set_code({ "alpha" }, "lua")
  ui.set_draft("keep")
  local opened = open_question_explicit({ "alpha" })
  ok(opened)
  vim.api.nvim_buf_set_lines(actions.get_question_state().buffer, 0, -1, false, { "do not send" })
  vim.cmd("stopinsert")
  keys("<Esc>")
  eq(0, #session.prompts, "Esc sends nothing")
  eq(false, actions.is_question_open(), "Esc closes the float")
  eq(false, ui.is_open(), "cancel does not open the sidebar")
  eq("keep", ui.get_draft(), "cancel does not change the draft")
  eq(0, float_windows(), "only the code window remains")
end)

-- 6. The selection snapshot survives later buffer edits.
test("question uses the selection snapshot taken before editing", function()
  fresh()
  set_code({ "original selected line" }, "lua")
  visual("V", 1, 1, 1, 1)
  local opened, qstate = actions.question_selection()
  ok(opened)
  vim.api.nvim_buf_set_lines(code_buf, 0, -1, false, { "changed after opening" })
  vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "Use the snapshot" })
  keys("<C-s>")
  eq(1, #session.prompts)
  contains(session.prompts[1], "original selected line", "snapshot text")
  absent(session.prompts[1], "changed after opening", "later edits are not included")
  eq("Use the snapshot", actions.get_last_question())
end)

-- 7. Opening a second float cleans the first one up.
test("consecutive floats leave no old buffer, window or mapping", function()
  fresh()
  set_code({ "alpha", "beta" }, "lua")
  visual("V", 1, 1, 1, 1)
  local opened, first = actions.question_selection()
  ok(opened)
  local first_buf, first_win = first.buf, first.win
  ok(vim.api.nvim_win_is_valid(first_win))

  set_code({ "alpha", "beta" }, "lua")
  local second_ok, second = open_question_explicit({ "alpha", "beta" })
  ok(second_ok)
  eq(false, vim.api.nvim_win_is_valid(first_win), "old float window is closed")
  eq(false, vim.api.nvim_buf_is_valid(first_buf), "old float buffer is wiped")
  ok(vim.api.nvim_win_is_valid(second.win))
  ok(vim.api.nvim_buf_is_valid(second.buf))
  eq(1, float_windows(), "only one float is open")
  eq(false, vim.api.nvim_buf_is_valid(first_buf), "old buffer and its mappings are gone")

  ok(actions.cancel_question())
  eq(0, float_windows())
  eq(false, actions.is_question_open())
end)

-- 8. send_selection appends through the real sidebar without submitting.
test("send_selection appends in order, focuses input and never submits", function()
  fresh()
  set_code({ "first line", "second line", "third line" }, "lua")
  ui.set_draft("preexisting")
  ui.on_submit(function()
    submit_calls = submit_calls + 1
  end)

  local first_selection = { mode = "V", start = { row = 1 }, ["end"] = { row = 1 } }
  local second_selection = { mode = "v", start = { row = 2, col = 1 }, ["end"] = { row = 3, col = 5 } }
  local first_text = assert(context.format(assert(context.from_selection(code_buf, first_selection))))
  local second_text = assert(context.format(assert(context.from_selection(code_buf, second_selection))))

  visual("V", 1, 1, 1, 1)
  ok(actions.send_selection())
  eq(true, ui.is_open(), "sidebar opens")
  eq(ui.get_windows().input, vim.api.nvim_get_current_win(), "input gets focus")
  eq("preexisting\n" .. first_text, ui.get_draft())

  vim.api.nvim_set_current_win(code_win)
  visual("v", 2, 1, 3, 5)
  ok(actions.send_selection())
  eq(true, ui.is_open())
  eq(ui.get_windows().input, vim.api.nvim_get_current_win())
  eq("preexisting\n" .. first_text .. "\n" .. second_text, ui.get_draft(), "selections append in order")
  eq(0, #session.prompts, "send_selection never prompts")
  eq(0, submit_calls, "send_selection never submits the draft")
  eq(false, actions.is_question_open(), "send_selection does not open a float")
end)

-- 9. Empty selection is rejected without touching UI or session.
test("send_selection without a selection does nothing", function()
  fresh()
  set_code({ "alpha" }, "lua")
  vim.fn.setpos("'<", { 0, 0, 0, 0 })
  vim.fn.setpos("'>", { 0, 0, 0, 0 })
  local sent, err = actions.send_selection()
  eq(false, sent, "no selection returns false")
  ok(err ~= nil, "no selection returns an error")
  eq("", ui.get_draft())
  eq(false, ui.is_open())
  eq(0, #session.prompts)
end)

io.stdout:write(("Selection tests: %d passed, %d failed\n"):format(passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
vim.cmd("qall!")
