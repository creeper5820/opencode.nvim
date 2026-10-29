-- Headless tests for the two-window OpenCode sidebar.
-- Run through tests/headless/ui/run.sh so XDG directories and shada are isolated.

local root = assert(vim.env.OPENCODE_UI_TEST_ROOT, "OPENCODE_UI_TEST_ROOT is required")

local function isolated(value)
  return type(value) == "string" and value:sub(1, #"/tmp/opencode/") == "/tmp/opencode/"
end

for _, name in ipairs({ "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "TMPDIR" }) do
  if not isolated(vim.env[name]) then
    io.stderr:write(("refusing to run UI tests: %s is not isolated under /tmp/opencode; use tests/headless/ui/run.sh\n"):format(name))
    vim.cmd("cquit 2")
  end
end

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local ui = require("opencode.ui")

-- Keep headless logs focused on assertions rather than mode/undo messages.
vim.o.showmode = false
vim.o.ruler = false
vim.o.report = 9999
vim.o.more = false

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

local function set_lines(buf, value)
  local was_modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, value)
  vim.bo[buf].modifiable = was_modifiable
end

local function buffer_map(buf, mode, lhs)
  local want = lhs:lower()
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if mapping.lhs:lower() == want then
      return mapping
    end
  end
  return nil
end

local function global_map(mode, lhs)
  local want = lhs:lower()
  for _, mapping in ipairs(vim.api.nvim_get_keymap(mode)) do
    if mapping.lhs:lower() == want then
      return mapping
    end
  end
  return nil
end

local function count_normal_windows()
  local count = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "" then
      count = count + 1
    end
  end
  return count
end

local function fresh()
  ui._reset()
  vim.cmd("silent! only")
  vim.cmd("silent! enew!")
  vim.bo.modifiable = true
  ui.setup({ width = 40, input_height = 6 })
  ui.on_submit(nil)
end

-- 0. Required public interface.
test("public interface", function()
  for _, name in ipairs({
    "toggle", "open", "close", "is_open",
    "focus_input", "focus_messages",
    "get_buffers", "get_windows", "get_draft",
    "append_draft", "set_draft", "on_submit",
  }) do
    eq(type(ui[name]), "function", name .. " is exported")
  end
end)

-- 1. Two real stacked windows with the expected buffers/options.
test("two stacked windows and buffers", function()
  fresh()
  ui.open()
  local wins = ui.get_windows()
  local bufs = ui.get_buffers()

  ok(vim.api.nvim_win_is_valid(wins.messages), "messages window is valid")
  ok(vim.api.nvim_win_is_valid(wins.input), "input window is valid")
  ok(wins.messages ~= wins.input, "windows are distinct")
  ok(bufs.messages ~= bufs.input, "buffers are distinct")
  eq(vim.api.nvim_win_get_buf(wins.messages), bufs.messages, "messages buffer attached")
  eq(vim.api.nvim_win_get_buf(wins.input), bufs.input, "input buffer attached")

  local mrow = vim.api.nvim_win_get_position(wins.messages)[1]
  local irow = vim.api.nvim_win_get_position(wins.input)[1]
  ok(irow > mrow, "input window is below messages window")

  ok(vim.bo[bufs.messages].modifiable == false, "messages buffer is not modifiable")
  ok(vim.bo[bufs.messages].buftype == "nofile", "messages buffer is scratch")
  eq("hide", vim.bo[bufs.messages].bufhidden, "messages buffer hides instead of wiping")
  eq(false, vim.bo[bufs.messages].buflisted, "messages buffer is not listed")
  eq(false, vim.bo[bufs.messages].swapfile, "messages buffer has no swapfile")
  eq("opencode_messages", vim.bo[bufs.messages].filetype, "messages filetype")
  ok(vim.bo[bufs.input].modifiable == true, "input buffer is modifiable")
  ok(vim.bo[bufs.input].buftype == "nofile", "input buffer is scratch")
  eq("hide", vim.bo[bufs.input].bufhidden, "input buffer hides instead of wiping")
  eq(false, vim.bo[bufs.input].buflisted, "input buffer is not listed")
  eq(false, vim.bo[bufs.input].swapfile, "input buffer has no swapfile")
  eq("opencode_input", vim.bo[bufs.input].filetype, "input filetype")

  eq(vim.api.nvim_win_get_width(wins.messages), 40, "messages width")
  eq(vim.api.nvim_win_get_width(wins.input), 40, "input width")
  eq(vim.api.nvim_win_get_height(wins.input), 6, "input height")
  eq(true, vim.wo[wins.messages].winfixwidth, "messages window keeps width")
  eq(true, vim.wo[wins.input].winfixwidth, "input window keeps width")
  eq(true, vim.wo[wins.input].winfixheight, "input window keeps height")
  eq(false, vim.wo[wins.messages].number, "messages window has no line numbers")
  eq(false, vim.wo[wins.input].number, "input window has no line numbers")

  ui.setup({ sidebar = { width = 42, input_height = 5 } })
  eq(vim.api.nvim_win_get_width(ui.get_windows().messages), 42, "setup sidebar width")
  eq(vim.api.nvim_win_get_height(ui.get_windows().input), 5, "setup sidebar input height")
end)

-- 2. Native window commands move focus between areas and the code window.
test("native window switching", function()
  fresh()
  local code_win = vim.api.nvim_get_current_win()
  ui.open()
  local wins = ui.get_windows()

  eq(vim.api.nvim_get_current_win(), wins.input, "open focuses input")
  vim.cmd("wincmd k")
  eq(vim.api.nvim_get_current_win(), wins.messages, "wincmd k reaches messages")
  vim.cmd("wincmd j")
  eq(vim.api.nvim_get_current_win(), wins.input, "wincmd j reaches input")
  vim.cmd("wincmd h")
  eq(vim.api.nvim_get_current_win(), code_win, "wincmd h reaches code window")

  ui.focus_messages()
  eq(vim.api.nvim_get_current_win(), wins.messages, "focus_messages")
  ui.focus_input()
  eq(vim.api.nvim_get_current_win(), wins.input, "focus_input")

  ui.close()
  eq(vim.api.nvim_get_current_win(), code_win, "close returns focus to previous window")
end)

-- 3. Repeated toggle does not duplicate buffers/windows.
test("toggle idempotence", function()
  fresh()
  local base_windows = count_normal_windows()
  ui.open()
  local first_bufs = ui.get_buffers()
  local first_wins = ui.get_windows()
  eq(count_normal_windows(), base_windows + 2, "open adds two windows")

  ui.open()
  ui.open()
  eq(count_normal_windows(), base_windows + 2, "repeated open adds no windows")
  eq(ui.get_buffers().messages, first_bufs.messages, "repeated open reuses messages buffer")
  eq(ui.get_buffers().input, first_bufs.input, "repeated open reuses input buffer")
  eq(ui.get_windows().messages, first_wins.messages, "repeated open reuses messages window")
  eq(ui.get_windows().input, first_wins.input, "repeated open reuses input window")

  ui.toggle()
  eq(ui.is_open(), false, "toggle closes")
  eq(count_normal_windows(), base_windows, "close removes two windows")

  ui.toggle()
  ok(ui.is_open(), "toggle reopens")
  local second_bufs = ui.get_buffers()
  local second_wins = ui.get_windows()
  eq(second_bufs.messages, first_bufs.messages, "messages buffer reused")
  eq(second_bufs.input, first_bufs.input, "input buffer reused")
  ok(second_wins.messages ~= first_wins.messages, "window recreated")
  eq(count_normal_windows(), base_windows + 2, "no duplicate windows")

  ui.toggle()
  eq(ui.is_open(), false, "second toggle closes")
end)

-- 4. Hiding preserves messages, draft and buffer identity.
test("hide and show preserve state", function()
  fresh()
  ui.open()
  local bufs = ui.get_buffers()
  set_lines(bufs.messages, { "assistant message", "second line" })
  ui.set_draft("my draft")

  ui.close()
  eq(ui.is_open(), false, "closed")
  eq(ui.get_windows().messages, nil, "messages window removed while hidden")
  eq(ui.get_windows().input, nil, "input window removed while hidden")
  eq(ui.get_buffers().messages, bufs.messages, "messages buffer kept while hidden")
  eq(ui.get_buffers().input, bufs.input, "input buffer kept while hidden")

  ui.open()
  eq(lines(ui.get_buffers().messages), { "assistant message", "second line" }, "messages kept")
  eq(ui.get_draft(), "my draft", "draft kept")
  eq(lines(ui.get_buffers().input), { "my draft" }, "input buffer restored")
end)

-- 5. Full Vim editing: insert, CR newline, visual, registers, undo/redo.
test("input supports native editing", function()
  fresh()
  ui.open()
  local buf = ui.get_buffers().input

  keys("ihello<CR>world<Esc>")
  eq(lines(buf), { "hello", "world" }, "insert and CR newline")
  eq(ui.get_draft(), "hello\nworld", "draft tracks editing")
  eq(vim.api.nvim_get_mode().mode, "n", "Esc performs the native mode switch")
  ok(ui.is_open(), "Esc does not close the sidebar")

  keys("ggVjy")
  eq(vim.fn.getreg('"'), "hello\nworld\n", "visual yank in input buffer")

  keys("u")
  eq(lines(buf), { "" }, "undo restores previous state")
  keys("<C-r>")
  eq(lines(buf), { "hello", "world" }, "redo restores edit")

  keys("ggyyGp")
  eq(lines(buf), { "hello", "world", "hello" }, "register paste")
end)

-- 6. Submit mapping is input-local and clears only after acceptance.
test("submit mapping input-local and accepted", function()
  fresh()
  local calls = {}
  ui.on_submit(function(text, done)
    calls[#calls + 1] = text
    done(nil)
  end)
  ui.open()
  local bufs = ui.get_buffers()
  ui.set_draft("from input")

  ui.focus_messages()
  keys("<C-s>")
  eq(#calls, 0, "submit key does nothing in messages")
  eq(ui.get_draft(), "from input", "messages submit leaves draft")

  vim.cmd("wincmd h")
  keys("<C-s>")
  eq(#calls, 0, "submit key does nothing in code window")

  ui.focus_input()
  keys("<C-s>")
  eq(calls, { "from input" }, "submit mapping calls callback once")
  eq(ui.get_draft(), "", "accepted submission clears draft")
  eq(lines(bufs.input), { "" }, "input buffer cleared")

  ok(buffer_map(bufs.input, "i", "<C-s>") ~= nil, "insert submit mapping is buffer-local")
  ok(buffer_map(bufs.input, "n", "<C-s>") ~= nil, "normal submit mapping is buffer-local")
  local global_insert_submit = global_map("i", "<C-s>")
  local global_normal_submit = global_map("n", "<C-s>")
  ok(
    global_insert_submit == nil or global_insert_submit.desc ~= "OpenCode: submit input",
    "no global insert submit mapping"
  )
  ok(
    global_normal_submit == nil or global_normal_submit.desc ~= "OpenCode: submit input",
    "no global normal submit mapping"
  )
end)

-- 7. Insert-mode submit, empty draft and failure keep the draft.
test("submit edge cases", function()
  fresh()
  local calls = {}
  ui.on_submit(function(text, done)
    calls[#calls + 1] = text
    done("rejected")
  end)
  ui.open()
  local buf = ui.get_buffers().input

  ui.submit()
  eq(#calls, 0, "empty draft is not submitted")

  keys("iplease submit<C-s>")
  eq(#calls, 1, "insert-mode submit calls callback once")
  eq(calls[1], "please submit", "submitted text")
  eq(ui.get_draft(), "please submit", "failed submission keeps draft")
  eq(lines(buf), { "please submit" }, "failed submission keeps buffer")

  ui.on_submit(function(text, done)
    calls[#calls + 1] = text
    done(nil)
  end)
  ui.focus_input()
  keys("<C-s>")
  eq(#calls, 2, "retry after failure")
  eq(ui.get_draft(), "", "retry accepted clears draft")
end)

-- 7b. Callback exceptions keep the draft and configurable submit keys are
-- remapped only on the input buffer.
test("submit callback errors and key configuration", function()
  fresh()
  ui.open()
  ui.set_draft("keep after error")
  ui.on_submit(function()
    error("fake transport failure")
  end)
  local submit_ok, submit_err = pcall(ui.submit)
  eq(false, submit_ok, "callback exception propagates")
  ok(tostring(submit_err):find("fake transport failure", 1, true) ~= nil, "callback error is preserved")
  eq("keep after error", ui.get_draft(), "callback exception keeps draft")

  local calls = {}
  ui.on_submit(function(text, done)
    calls[#calls + 1] = text
    done(nil)
  end)
  eq(true, ui.submit(), "submission is possible after a callback exception")
  eq(calls, { "keep after error" }, "retry reaches callback")
  eq("", ui.get_draft(), "accepted retry clears draft")

  ui.setup({ keymaps = { submit = "<C-g>" } })
  local input = ui.get_buffers().input
  ok(buffer_map(input, "i", "<C-s>") == nil, "old insert submit key removed")
  ok(buffer_map(input, "n", "<C-s>") == nil, "old normal submit key removed")
  ok(buffer_map(input, "i", "<C-g>") ~= nil, "configured insert submit key installed")
  ok(buffer_map(input, "n", "<C-g>") ~= nil, "configured normal submit key installed")

  ui.set_draft("custom submit")
  ui.focus_input()
  keys("<C-g>")
  eq(calls, { "keep after error", "custom submit" }, "configured key submits once")
  eq(ui.get_draft(), "", "configured key clears accepted draft")

  ui.setup({ keymaps = { submit = false } })
  ok(buffer_map(input, "i", "<C-g>") == nil, "disabled insert submit key removed")
  ok(buffer_map(input, "n", "<C-g>") == nil, "disabled normal submit key removed")
  ui.set_draft("not submitted")
  keys("<C-g>")
  eq(#calls, 2, "disabled submit key does nothing")
  eq("not submitted", ui.get_draft(), "disabled submit key keeps draft")
end)

-- 8. Messages are read-only, paging is buffer-local, no insert mapping.
test("messages readonly and paging isolation", function()
  fresh()
  ui.open()
  local wins = ui.get_windows()
  local bufs = ui.get_buffers()
  local body = {}
  for i = 1, 200 do
    body[i] = "line " .. i
  end
  set_lines(bufs.messages, body)

  eq(vim.bo[bufs.messages].modifiable, false, "readonly")
  ok(buffer_map(bufs.messages, "n", "<C-d>") ~= nil, "C-d mapped buffer-locally")
  ok(buffer_map(bufs.messages, "n", "<C-f>") ~= nil, "C-f mapped buffer-locally")
  ok(buffer_map(bufs.messages, "i", "<C-d>") == nil, "no insert paging mapping in messages")
  ok(buffer_map(bufs.messages, "i", "<C-s>") == nil, "no insert submit mapping in messages")
  ok(buffer_map(bufs.messages, "n", "<C-s>") == nil, "no normal submit mapping in messages")
  ok(buffer_map(bufs.input, "n", "<C-d>") == nil, "no paging mapping in input")
  ok(buffer_map(bufs.input, "n", "<C-f>") == nil, "no full-page mapping in input")
  ok(global_map("n", "<C-d>") == nil, "no global C-d mapping")
  ok(global_map("n", "<C-f>") == nil, "no global C-f mapping")

  local code_win = vim.fn.win_getid(vim.fn.winnr("h"))
  vim.api.nvim_set_current_win(code_win)
  local code_top = vim.fn.line("w0")
  keys("<C-d>")
  eq(vim.fn.line("w0"), code_top, "C-d does not scroll code window")

  ui.focus_input()
  local message_top = vim.fn.line("w0", wins.messages)
  keys("<C-d>")
  eq(vim.fn.line("w0", wins.messages), message_top, "C-d in input does not scroll messages")

  ui.focus_messages()
  vim.wo[wins.messages].scroll = 4
  vim.cmd("normal! gg")
  eq(1, vim.fn.line("w0"), "messages start at the top")
  keys("<C-d>")
  eq(5, vim.fn.line("w0"), "C-d scrolls a half page when no count is given")

  vim.cmd("normal! gg")
  keys("3<C-d>")
  eq(4, vim.fn.line("w0"), "C-d honors a count")

  vim.cmd("normal! gg")
  local top_before_f = vim.fn.line("w0")
  keys("<C-f>")
  local top_after_f = vim.fn.line("w0")
  ok(top_after_f > top_before_f + vim.wo[wins.messages].scroll, "C-f scrolls a full page")
  keys("<C-b>")
  eq(top_before_f, vim.fn.line("w0"), "C-b scrolls back a full page")

  vim.cmd("normal! G")
  local bottom_top = vim.fn.line("w0")
  keys("<C-u>")
  eq(bottom_top - vim.wo[wins.messages].scroll, vim.fn.line("w0"), "C-u scrolls up a half page")

  -- Visual selection and yank stay native.
  vim.cmd("normal! ggVj")
  keys("y")
  eq(vim.fn.getreg('"'), "line 1\nline 2\n", "visual yank in messages")

  -- Fold keys are not overridden; the renderer owns folding behavior.
  ok(buffer_map(bufs.messages, "n", "za") == nil, "fold key not mapped")
end)

-- 9. Manual window close is repaired by open/toggle.
test("repair after manual window close", function()
  fresh()
  local code_win = vim.api.nvim_get_current_win()
  ui.open()
  local bufs = ui.get_buffers()
  ui.set_draft("survives")
  set_lines(bufs.messages, { "output survives" })

  local input_win = ui.get_windows().input
  vim.api.nvim_win_close(input_win, true)
  eq(ui.is_open(), false, "is_open false after input window closed")
  ui.toggle()
  eq(ui.is_open(), true, "toggle repairs input window")
  eq(vim.api.nvim_get_current_win(), ui.get_windows().input, "input focused")
  eq(ui.get_draft(), "survives", "draft survives repair")
  eq(lines(bufs.messages), { "output survives" }, "messages survive repair")

  local messages_win = ui.get_windows().messages
  vim.api.nvim_win_close(messages_win, true)
  eq(ui.is_open(), false, "is_open false after messages window closed")
  ui.toggle()
  eq(ui.is_open(), true, "toggle repairs messages window")
  eq(lines(ui.get_buffers().messages), { "output survives" }, "messages survive second repair")
  ok(vim.api.nvim_win_is_valid(code_win), "code window untouched")
end)

-- 10. Wiped buffers are safely recreated with the draft preserved.
test("repair after buffer wipe", function()
  fresh()
  ui.open()
  local bufs = ui.get_buffers()
  keys("ityped before wipe<Esc>")
  eq("typed before wipe", ui.get_draft(), "draft tracked before wipe")

  vim.api.nvim_buf_delete(bufs.input, { force = true })
  eq(ui.is_open(), false, "is_open detects a wiped input buffer")
  ui.toggle()
  local new_bufs = ui.get_buffers()
  ok(new_bufs.input ~= bufs.input, "input buffer recreated")
  eq("typed before wipe", ui.get_draft(), "draft restored after wipe")
  ok(vim.api.nvim_win_is_valid(ui.get_windows().input), "input window restored")
  eq(vim.api.nvim_win_get_buf(ui.get_windows().input), new_bufs.input, "new input buffer attached")
  ok(buffer_map(new_bufs.input, "n", "<C-s>") ~= nil, "submit mapping recreated after wipe")

  vim.api.nvim_buf_delete(new_bufs.messages, { force = true })
  eq(ui.is_open(), false, "is_open detects a wiped messages buffer")
  ui.toggle()
  eq(vim.api.nvim_win_get_buf(ui.get_windows().messages), ui.get_buffers().messages, "messages buffer reattached")
  eq(vim.bo[ui.get_buffers().messages].modifiable, false, "recreated messages readonly")
  eq("typed before wipe", ui.get_draft(), "draft survives messages wipe")

  local unloaded = ui.get_buffers().input
  vim.cmd("silent! bunload " .. unloaded)
  eq(ui.is_open(), false, "is_open detects an unloaded input buffer")
  ui.focus_input()
  ok(ui.get_buffers().input ~= unloaded, "unloaded input buffer replaced")
  eq("typed before wipe", ui.get_draft(), "draft restored after unload")
  eq(vim.api.nvim_get_current_win(), ui.get_windows().input, "focus_input restores and focuses input")
  ok(buffer_map(ui.get_buffers().input, "n", "<C-s>") ~= nil, "submit mapping restored after unload")
end)

-- 11. Draft clears on asynchronous acceptance, not on submission.
test("async acceptance", function()
  fresh()
  local finish
  local calls = 0
  ui.on_submit(function(_, done)
    calls = calls + 1
    finish = done
  end)
  ui.open()
  ui.set_draft("pending text")
  eq(ui.submit(), true, "submission started")
  eq(ui.get_draft(), "pending text", "draft kept while awaiting acceptance")
  eq(ui.submit(), false, "duplicate submission blocked while pending")

  ui.set_draft("edited while pending")
  finish(nil)
  eq(calls, 1, "callback called once")
  eq(ui.get_draft(), "edited while pending", "newer edits are not discarded")

  ui.focus_input()
  ui.set_draft("second try")
  ui.submit()
  finish(nil)
  eq(ui.get_draft(), "", "accepted draft cleared")
end)

-- 12. append_draft preserves existing text and ordering.
test("append_draft", function()
  fresh()
  ui.set_draft("first")
  ui.append_draft("second")
  eq(ui.get_draft(), "first\nsecond", "append after existing")
  ui.append_draft("third")
  eq(ui.get_draft(), "first\nsecond\nthird", "ordered append")
  eq(ui.append_draft(""), "first\nsecond\nthird", "empty append is a no-op")

  ui.open()
  eq(lines(ui.get_buffers().input), { "first", "second", "third" }, "draft before open materialized")
end)

io.stdout:write(("UI tests: %d passed, %d failed\n"):format(passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
vim.cmd("qall!")
