-- Headless native-pum tests for lua/opencode/completion/core.lua.
local this = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(this, ":p:h")
local root = vim.fn.fnamemodify(dir, ":h:h:h:h")
vim.opt.runtimepath:append(root)

local core = require("opencode.completion.core")

local failures = {}
local count = 0

local function fail(name, message)
  failures[#failures + 1] = string.format("%s: %s", name, message)
end

local function eq(name, actual, expected)
  if not vim.deep_equal(actual, expected) then
    fail(name, string.format("expected %s, got %s", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function truthy(name, value)
  if not value then
    fail(name, "expected truthy, got " .. vim.inspect(value))
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
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or { "" })
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
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

local function sync_source(items, start_col)
  local calls = {}
  local source = {
    query = function(request, callback)
      calls[#calls + 1] = request
      callback({ ok = true, items = items, start_col = start_col })
      return { cancel = function() end }
    end,
  }
  return source, calls
end

local function map_trigger(bufnr, lhs, log)
  vim.keymap.set("i", lhs, function()
    local state = core.get_state(bufnr)
    log.trigger = core.trigger(bufnr)
    log.pum = vim.fn.pumvisible()
    log.pending = state and state.pending or nil
  end, { buffer = bufnr, silent = true })
end

test("manual trigger opens native pum and native keys insert candidate", function()
  local bufnr = new_buffer({ "" })
  local source, calls = sync_source({
    { kind = "file", text = "alpha", metadata = { path = "alpha.lua" } },
    { kind = "file", text = "alphabet", metadata = { path = "alphabet.lua" } },
  }, 0)
  core.attach(bufnr, { source = source })
  local log = {}
  map_trigger(bufnr, "<F5>", log)
  feed("ial<F5><C-y><Esc>")

  eq("query count", #calls, 1)
  eq("start", calls[1].before_cursor, "al")
  eq("pum shown", log.pum, 1)
  eq("line", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "alpha")
  local selected = core.get_selected(bufnr)
  truthy("selected candidate", selected)
  eq("selected text", selected.text, "alpha")
  eq("selected metadata", selected.metadata, { path = "alpha.lua" })
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("cancel closes the pum without changing the draft", function()
  local bufnr = new_buffer({ "" })
  local source = sync_source({ { text = "alpha" }, { text = "alps" } }, 0)
  core.attach(bufnr, { source = source })
  local log = {}
  vim.keymap.set("i", "<F6>", function()
    core.trigger(bufnr)
    log.pum_before = vim.fn.pumvisible()
    core.cancel(bufnr)
    log.pum_active = core.get_state(bufnr).pum_active
  end, { buffer = bufnr, silent = true })
  feed("ial<F6><C-y><Esc>")

  eq("pum before cancel", log.pum_before, 1)
  eq("engine pum state", log.pum_active, false)
  eq("draft preserved", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "al")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("start_col replaces only the intended prefix", function()
  local bufnr = new_buffer({ "prefix al" })
  vim.api.nvim_win_set_cursor(0, { 1, 9 })
  local source = sync_source({ { text = "alpha" } }, 7)
  core.attach(bufnr, { source = source })
  local log = {}
  map_trigger(bufnr, "<F5>", log)
  feed("A<F5><C-y><Esc>")
  eq("line", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "prefix alpha")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("multi-line input completes only the cursor line", function()
  local bufnr = new_buffer({ "first line", "second al" })
  vim.api.nvim_win_set_cursor(0, { 2, 9 })
  local source, calls = sync_source({ { text = "alpha" } }, 7)
  core.attach(bufnr, { source = source })
  local log = {}
  map_trigger(bufnr, "<F5>", log)
  feed("A<F5><C-y><Esc>")
  eq("line 1", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "first line")
  eq("line 2", vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1], "second alpha")
  eq("query line", calls[1].lnum, 2)
  eq("query before_cursor", calls[1].before_cursor, "second al")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("detach while pum is open keeps the draft", function()
  local bufnr = new_buffer({ "" })
  local source = sync_source({ { text = "alpha" }, { text = "alps" } }, 0)
  core.attach(bufnr, { source = source })
  vim.keymap.set("i", "<F7>", function()
    core.trigger(bufnr)
    core.detach(bufnr)
  end, { buffer = bufnr, silent = true })
  feed("ial<F7><C-y><Esc>")
  eq("draft", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "al")
  eq("detached", core.is_attached(bufnr), false)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("auto trigger debounces, respects minimum length and uses pum", function()
  local bufnr = new_buffer({ "" })
  local source, calls = sync_source({ { text = "alpha" }, { text = "alps" } }, 0)
  core.attach(bufnr, { source = source, minimum_length = 1, debounce = 20 })
  local log = {}
  vim.keymap.set("i", "<F8>", function()
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
    wait(80)
    log.pum = vim.fn.pumvisible()
    log.calls = #calls
  end, { buffer = bufnr, silent = true })
  feed("ial<F8><C-y><Esc>")
  eq("debounced to one query", log.calls, 1)
  eq("auto trigger marker", calls[1].trigger, "auto")
  eq("pum", log.pum, 1)
  eq("line", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "alpha")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("auto trigger below minimum length does not query", function()
  local bufnr = new_buffer({ "" })
  local source, calls = sync_source({ { text = "alpha" } }, 0)
  core.attach(bufnr, { source = source, minimum_length = 3, debounce = 10 })
  local log = {}
  vim.keymap.set("i", "<F8>", function()
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
    wait(60)
    log.pum = vim.fn.pumvisible()
    log.calls = #calls
  end, { buffer = bufnr, silent = true })
  feed("ial<F8><C-y><Esc>")
  eq("no query", log.calls, 0)
  eq("no pum", log.pum, 0)
  eq("draft", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "al")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("auto trigger with trigger_chars only fires for the configured character", function()
  local bufnr = new_buffer({ "" })
  local source, calls = sync_source({ { text = "mention" } }, 0)
  core.attach(bufnr, { source = source, trigger_chars = { "@" }, debounce = 10 })
  local log = {}
  vim.keymap.set("i", "<F8>", function()
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
    wait(50)
    log.calls = #calls
  end, { buffer = bufnr, silent = true })
  feed("ial<F8><C-y><Esc>")
  eq("plain text ignored", log.calls, 0)

  log = {}
  feed("a@<F8><C-y><Esc>")
  eq("trigger char queries", log.calls, 1)
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("slow response after detach never reaches the buffer", function()
  local bufnr = new_buffer({ "" })
  local source = {
    query = function(_, callback)
      vim.defer_fn(function()
        callback({ ok = true, items = { { text = "late" } } })
      end, 20)
      return function() end
    end,
  }
  core.attach(bufnr, { source = source })
  local log = {}
  map_trigger(bufnr, "<F5>", log)
  feed("ial<F5><Esc>")
  core.detach(bufnr)
  wait(60)
  eq("draft untouched", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "al")
  eq("no state", core.get_state(bufnr), nil)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("detach cancels a pending debounce timer", function()
  local bufnr = new_buffer({ "" })
  local source, calls = sync_source({ { text = "alpha" } }, 0)
  core.attach(bufnr, { source = source, debounce = 30 })
  local log = {}
  vim.keymap.set("i", "<F9>", function()
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
    core.detach(bufnr)
    wait(80)
    log.calls = #calls
  end, { buffer = bufnr, silent = true })
  feed("ial<F9><Esc>")
  eq("timer did not query", log.calls, 0)
  eq("draft", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "al")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("native completefunc invocation reuses the cached query", function()
  local bufnr = new_buffer({ "al " })
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  local source, calls = sync_source({
    { kind = "file", text = "alpha" },
    { kind = "file", text = "alps" },
  }, 0)
  core.attach(bufnr, { source = source })
  truthy("manual cache", core.trigger(bufnr))
  eq("cached query", #calls, 1)
  feed("i<C-x><C-u><C-y><Esc>")
  eq("line", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "alpha ")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("native pum selection forwards the chosen candidate and metadata", function()
  local bufnr = new_buffer({ "" })
  local source = sync_source({
    { kind = "file", text = "alpha", metadata = { path = "alpha.lua", index = 1 } },
    { kind = "file", text = "alps", metadata = { path = "alps.lua", index = 2 } },
  }, 0)
  core.attach(bufnr, { source = source })
  local log = {}
  map_trigger(bufnr, "<F5>", log)
  feed("ial<F5><C-n><C-y><Esc>")

  eq("line", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "alps")
  local selected = core.get_selected(bufnr)
  truthy("selected candidate", selected)
  eq("selected text", selected.text, "alps")
  eq("selected metadata", selected.metadata, { path = "alps.lua", index = 2 })
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("current pum selection is observable before accepting", function()
  local bufnr = new_buffer({ "" })
  local source = sync_source({
    { kind = "file", text = "alpha", metadata = { index = 1 } },
    { kind = "file", text = "alps", metadata = { index = 2 } },
  }, 0)
  core.attach(bufnr, { source = source })
  local log = {}
  map_trigger(bufnr, "<F5>", log)
  vim.keymap.set("i", "<F6>", function()
    local selected = core.get_selected(bufnr)
    log.mid_text = selected and selected.text or nil
    log.mid_metadata = selected and selected.metadata or nil
  end, { buffer = bufnr, silent = true })
  feed("ial<F5><C-n><F6><C-y><Esc>")

  eq("selection before accept", log.mid_text, "alps")
  eq("selection metadata before accept", log.mid_metadata, { index = 2 })
  eq("line", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "alps")
  eq("selection after accept", core.get_selected(bufnr).text, "alps")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("refresh_context closes the pum and preserves the draft", function()
  local bufnr = new_buffer({ "" })
  local source = sync_source({ { text = "alpha" }, { text = "alps" } }, 0)
  core.attach(bufnr, { source = source, context = { session = 1 } })
  local log = {}
  map_trigger(bufnr, "<F5>", log)
  vim.keymap.set("i", "<F6>", function()
    log.refresh = core.refresh_context(bufnr, { session = 2 })
    log.pum_active = core.get_state(bufnr).pum_active
  end, { buffer = bufnr, silent = true })
  feed("ial<F5><F6><C-y><Esc>")
  eq("refresh succeeded", log.refresh, true)
  eq("engine pum state", log.pum_active, false)
  eq("draft preserved", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "al")
  eq("context updated", core.get_state(bufnr).context, { session = 2 })
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("rapid auto edits debounce into a single pum query", function()
  local bufnr = new_buffer({ "" })
  local source, calls = sync_source({ { text = "alpha" }, { text = "alps" } }, 0)
  core.attach(bufnr, { source = source, minimum_length = 1, debounce = 25 })
  local log = {}
  vim.keymap.set("i", "<F8>", function()
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
    wait(5)
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
    wait(100)
    log.calls = #calls
    log.pum = vim.fn.pumvisible()
  end, { buffer = bufnr, silent = true })
  feed("ial<F8><C-y><Esc>")
  eq("one debounced query", log.calls, 1)
  eq("pum shown", log.pum, 1)
  eq("line", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "alpha")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("unicode start col replaces the intended prefix", function()
  local bufnr = new_buffer({ "输入 al" })
  vim.api.nvim_win_set_cursor(0, { 1, #"输入 al" })
  local source, calls = sync_source({ { text = "alpha" } }, #"输入 ")
  core.attach(bufnr, { source = source })
  local log = {}
  map_trigger(bufnr, "<F5>", log)
  feed("A<F5><C-y><Esc>")

  eq("before cursor", calls[1].before_cursor, "输入 al")
  eq("byte column", calls[1].col, #"输入 al")
  eq("line", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "输入 alpha")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("trigger_chars keeps matching within the same token", function()
  local bufnr = new_buffer({ "" })
  local source, calls = sync_source({ { kind = "file", text = "mention" } }, 0)
  core.attach(bufnr, { source = source, trigger_chars = { "@" }, debounce = 5 })
  local log = {}
  vim.keymap.set("i", "<F8>", function()
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
    wait(30)
    log.after_trigger = #calls
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "@a" })
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
    wait(30)
    log.after_char = #calls
  end, { buffer = bufnr, silent = true })
  feed("i@<F8><Esc>")
  eq("query on trigger char", log.after_trigger, 1)
  eq("query continues in token", log.after_char, 2)
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("a failed query is silent and leaves the draft", function()
  local bufnr = new_buffer({ "" })
  local source = {
    query = function(_, callback)
      callback({ ok = false, error = { code = "failed", message = "no result" } })
      return function() end
    end,
  }
  core.attach(bufnr, { source = source })
  local notifications = 0
  local original_notify = vim.notify
  vim.notify = function()
    notifications = notifications + 1
  end
  local log = {}
  map_trigger(bufnr, "<F5>", log)
  local ok, err = pcall(feed, "ial<F5><Esc>")
  vim.notify = original_notify

  truthy("feed completed", ok, err)
  eq("no notification", notifications, 0)
  eq("no pum", log.pum, 0)
  eq("draft preserved", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "al")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("detach then reattach ignores the old source response", function()
  local bufnr = new_buffer({ "" })
  local old_callback
  local old_source = {
    query = function(_, callback)
      old_callback = callback
      return function() end
    end,
  }
  core.attach(bufnr, { source = old_source })
  core.trigger(bufnr)
  core.detach(bufnr)

  local source = sync_source({ { kind = "file", text = "new", metadata = { id = "new" } } }, 0)
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)
  old_callback({ ok = true, items = { { kind = "file", text = "old" } }, start_col = 0 })

  local candidates = core.get_candidates(bufnr)
  eq("one candidate", #candidates, 1)
  eq("new attachment intact", candidates[1].text, "new")
  eq("metadata intact", candidates[1].metadata, { id = "new" })
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("switching buffers discards a slow result in both buffers", function()
  local first = new_buffer({ "" })
  local source = {
    query = function(_, callback)
      vim.defer_fn(function()
        callback({ ok = true, items = { { text = "late" } }, start_col = 0 })
      end, 25)
      return function() end
    end,
  }
  core.attach(first, { source = source })
  local log = {}
  map_trigger(first, "<F5>", log)
  feed("ial<F5><Esc>")

  local second = new_buffer({ "" })
  wait(80)
  eq("first draft", vim.api.nvim_buf_get_lines(first, 0, 1, false)[1], "al")
  eq("first has no candidates", #core.get_candidates(first), 0)
  eq("second has no state", core.get_state(second), nil)
  core.detach(first)
  vim.api.nvim_buf_delete(first, { force = true })
  vim.api.nvim_buf_delete(second, { force = true })
end)

test("native omnifunc invocation reuses the cached query", function()
  local bufnr = new_buffer({ "al " })
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  local source, calls = sync_source({
    { kind = "file", text = "alpha" },
    { kind = "file", text = "alps" },
  }, 0)
  core.attach(bufnr, { source = source, mode = "omnifunc" })
  truthy("manual cache", core.trigger(bufnr))
  eq("cached query", #calls, 1)
  feed("i<C-x><C-o><C-y><Esc>")
  eq("line", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "alpha ")
  eq("query count", #calls, 1)
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("cancel closes a pum opened through native completefunc", function()
  local bufnr = new_buffer({ "al " })
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  local source, calls = sync_source({
    { kind = "file", text = "alpha" },
    { kind = "file", text = "alps" },
  }, 0)
  core.attach(bufnr, { source = source })
  truthy("manual cache", core.trigger(bufnr))
  eq("cached query", #calls, 1)
  vim.keymap.set("i", "<F6>", function()
    core.cancel(bufnr)
  end, { buffer = bufnr, silent = true })
  feed("i<C-x><C-u><F6><Esc>")
  eq("draft preserved", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "al ")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("plain code buffer has no completion state or buffer mappings", function()
  local input = new_buffer({ "" })
  core.attach(input, { source = sync_source({}) })
  local code = new_buffer({ "local x = 1" })
  eq("code completefunc", vim.bo[code].completefunc, "")
  eq("code attached", core.is_attached(code), false)
  for _, key in ipairs({ "<Tab>", "<S-Tab>", "<CR>", "<C-n>", "<C-p>" }) do
    local map = vim.fn.maparg(key, "i", false, true)
    eq("code map " .. key, map.buffer == 1, false)
  end
  eq("input Tab unmapped", vim.fn.maparg("<Tab>", "i", false, true).buffer == 1, false)
  core.detach(input)
  vim.api.nvim_buf_delete(input, { force = true })
  vim.api.nvim_buf_delete(code, { force = true })
end)

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  io.stderr:write(string.format("%d/%d headless tests failed\n", #failures, count))
  vim.cmd("cquit 1")
else
  print(string.format("ok %d headless tests", count))
end
