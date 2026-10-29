-- Isolated unit tests for lua/opencode/completion/core.lua.
local this = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(this, ":p:h")
local root = vim.fn.fnamemodify(dir, ":h:h:h:h")
vim.opt.runtimepath:append(root)

local core = require("opencode.completion.core")
local uv = vim.uv or vim.loop

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

local function wait(ms)
  vim.wait(ms, function()
    return false
  end, 5)
end

local function new_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or { "" })
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
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

test("attach validates and sets buffer-local completefunc", function()
  local bufnr = new_buffer({ "abc" })
  local source = sync_source({})
  truthy("attach", core.attach(bufnr, { source = source, context = { a = 1 } }))
  truthy("attached", core.is_attached(bufnr))
  eq(
    "completefunc",
    vim.bo[bufnr].completefunc,
    "v:lua.opencode_completion_completefunc"
  )
  local options = core.get_state(bufnr).options
  eq("auto default", options.auto, true)
  eq("minimum_length default", options.minimum_length, 1)
  eq("debounce default", options.debounce, 100)
  eq("trigger_chars default", options.trigger_chars, nil)
  eq("mode default", options.mode, "completefunc")
  eq("keymap default", options.keymap, nil)
  truthy("detach", core.detach(bufnr))
  eq("detached", core.is_attached(bufnr), false)
  eq("completefunc cleared", vim.bo[bufnr].completefunc, "")
  eq("detach idempotent", core.detach(bufnr), false)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("attach supports omnifunc and options", function()
  local bufnr = new_buffer({ "abc" })
  local source = sync_source({})
  truthy("attach", core.attach(bufnr, {
    source = source,
    auto = false,
    minimum_length = 3,
    debounce = 5,
    trigger_chars = { "@" },
    mode = "omnifunc",
  }))
  truthy("omnifunc", vim.bo[bufnr].omnifunc:find("opencode_completion_completefunc", 1, true) ~= nil)
  local options = core.get_state(bufnr).options
  eq("auto", options.auto, false)
  eq("minimum_length", options.minimum_length, 3)
  eq("debounce", options.debounce, 5)
  eq("trigger_chars", options.trigger_chars, { "@" })
  core.detach(bufnr)
  eq("omnifunc cleared", vim.bo[bufnr].omnifunc, "")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("query receives cursor context and candidates keep metadata", function()
  local bufnr = new_buffer({ "hello al" })
  vim.api.nvim_win_set_cursor(0, { 1, 8 })
  local metadata = { path = "a b/ü.txt", range = { 1, 2 } }
  local source, calls = sync_source({
    { kind = "file", text = "alpha", metadata = metadata },
    { kind = "text", text = "alps", metadata = { id = 2 } },
  }, 6)
  truthy("attach", core.attach(bufnr, { source = source, context = { project = "x" } }))
  truthy("trigger", core.trigger(bufnr))

  eq("one query", #calls, 1)
  local req = calls[1]
  eq("bufnr", req.bufnr, bufnr)
  eq("lnum", req.lnum, 1)
  eq("col", req.col, 7)
  eq("line", req.line, "hello al")
  eq("before_cursor", req.before_cursor, "hello a")
  eq("context", req.context, { project = "x" })
  eq("trigger", req.trigger, "manual")
  eq("seq", req.seq, 1)
  eq("context_revision", req.context_revision, 0)

  local candidates = core.get_candidates(bufnr)
  eq("candidate count", #candidates, 2)
  eq("kind", candidates[1].kind, "file")
  eq("text", candidates[1].text, "alpha")
  eq("metadata identity", candidates[1].metadata, metadata)
  eq("cached start col", core.get_state(bufnr).cached.start_col, 6)
  eq("cached user_data", core.get_state(bufnr).cached.items[1].user_data, candidates[1])
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("default start col is the cursor column", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  local source = sync_source({ { text = "abc" } })
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)
  eq("default start", core.get_state(bufnr).cached.start_col, 2)
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("invalid candidates are ignored", function()
  local bufnr = new_buffer({ "a" })
  local source = sync_source({
    { kind = "file" },
    { text = 12 },
    { text = "ok", metadata = { keep = true } },
  })
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)
  eq("only valid", #core.get_candidates(bufnr), 1)
  eq("valid text", core.get_candidates(bufnr)[1].text, "ok")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("changed cursor discards stale result", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local source = {
    query = function(_, callback)
      vim.defer_fn(function()
        callback({ ok = true, items = { { text = "late" } } })
      end, 30)
      return function() end
    end,
  }
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  wait(70)
  eq("no candidates", core.get_candidates(bufnr), {})
  eq("not pending", core.get_state(bufnr).pending, false)
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("only the latest response is accepted", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local call = 0
  local source = {
    query = function(_, callback)
      call = call + 1
      if call == 1 then
        vim.defer_fn(function()
          callback({ ok = true, items = { { text = "old" } } })
        end, 70)
      else
        vim.defer_fn(function()
          callback({ ok = true, items = { { text = "new" } } })
        end, 10)
      end
      return function() end
    end,
  }
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)
  core.trigger(bufnr)
  wait(120)
  local candidates = core.get_candidates(bufnr)
  eq("one candidate", #candidates, 1)
  eq("latest candidate", candidates[1].text, "new")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("cancel invalidates in-flight response and calls source cancel once", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local cancelled = 0
  local callback_ref
  local source = {
    query = function(_, callback)
      callback_ref = callback
      vim.defer_fn(function()
        callback({ ok = true, items = { { text = "late" } } })
      end, 30)
      return {
        cancel = function()
          cancelled = cancelled + 1
        end,
      }
    end,
  }
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)
  truthy("cancel", core.cancel(bufnr))
  eq("source cancelled", cancelled, 1)
  callback_ref({ ok = true, items = { { text = "late" } } })
  eq("no candidates", core.get_candidates(bufnr), {})
  wait(50)
  eq("cancel idempotent state", core.get_candidates(bufnr), {})
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("refresh_context discards old response and sends new context", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local contexts = {}
  local revisions = {}
  local call = 0
  local source = {
    query = function(request, callback)
      call = call + 1
      contexts[#contexts + 1] = request.context
      revisions[#revisions + 1] = request.context_revision
      local value = call
      vim.defer_fn(function()
        callback({ ok = true, items = { { text = value == 1 and "old" or "new" } } })
      end, value == 1 and 50 or 5)
      return function() end
    end,
  }
  core.attach(bufnr, { source = source, context = { session = 1 } })
  core.trigger(bufnr)
  truthy("refresh", core.refresh_context(bufnr, { session = 2 }))
  core.trigger(bufnr)
  wait(90)
  eq("contexts", contexts, { { session = 1 }, { session = 2 } })
  eq("revisions", revisions, { 0, 1 })
  eq("latest", core.get_candidates(bufnr)[1].text, "new")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("detach ignores a late response and removes state", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local source = {
    query = function(_, callback)
      vim.defer_fn(function()
        callback({ ok = true, items = { { text = "late" } } })
      end, 30)
      return function() end
    end,
  }
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)
  core.detach(bufnr)
  wait(60)
  eq("state removed", core.get_state(bufnr), nil)
  eq("candidates empty", core.get_candidates(bufnr), {})
  eq("not attached", core.is_attached(bufnr), false)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("source errors and error results degrade silently", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local source = {
    query = function(_, callback)
      callback({ ok = false, error = { code = "boom", message = "nope" } })
      return function() end
    end,
  }
  core.attach(bufnr, { source = source })
  eq("query started", core.trigger(bufnr), true)
  eq("no candidates", core.get_candidates(bufnr), {})

  local throwing = {
    query = function()
      error("failed")
    end,
  }
  core.detach(bufnr)
  core.attach(bufnr, { source = throwing })
  eq("throw returns false", core.trigger(bufnr), false)
  eq("no candidates after throw", core.get_candidates(bufnr), {})
  eq("not pending", core.get_state(bufnr).pending, false)
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("attach rejects missing source and invalid buffer", function()
  eq("no source", core.attach(0, {}), false)
  local bufnr = new_buffer({ "" })
  eq("invalid source", core.attach(bufnr, { source = {} }), false)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("no default insert mappings for common completion keys", function()
  local bufnr = new_buffer({ "" })
  core.attach(bufnr, { source = sync_source({}) })
  local keys = { "<Tab>", "<S-Tab>", "<CR>", "<C-n>", "<C-p>" }
  for _, key in ipairs(keys) do
    local map = vim.fn.maparg(key, "i", false, true)
    eq("no map " .. key, map.buffer == 1, false)
  end
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("optional keymap is buffer-local and removed on detach", function()
  local bufnr = new_buffer({ "" })
  core.attach(bufnr, { source = sync_source({}), keymap = "<F5>" })
  local map = vim.fn.maparg("<F5>", "i", false, true)
  eq("buffer map", map.buffer, 1)
  core.detach(bufnr)
  eq("map removed", vim.fn.maparg("<F5>", "i"), "")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("wiping the buffer detaches", function()
  local bufnr = new_buffer({ "" })
  core.attach(bufnr, { source = sync_source({}) })
  vim.api.nvim_buf_delete(bufnr, { force = true })
  eq("detached by wipeout", core.is_attached(bufnr), false)
end)

test("attach normalizes buffer 0 and restores a previous completefunc", function()
  local bufnr = new_buffer({ "abc" })
  vim.bo[bufnr].completefunc = "v:lua.OtherComplete"
  local source, calls = sync_source({ { text = "abc" } }, 0)
  truthy("attach 0", core.attach(0, { source = source }))
  truthy("attached actual buffer", core.is_attached(bufnr))
  eq("attached 0", core.is_attached(0), true)
  eq(
    "engine completefunc",
    vim.bo[bufnr].completefunc,
    "v:lua.opencode_completion_completefunc"
  )

  truthy("trigger 0", core.trigger(0))
  eq("query count", #calls, 1)
  eq("query bufnr", calls[1].bufnr, bufnr)
  eq("candidates 0", #core.get_candidates(0), 1)

  truthy("detach 0", core.detach(0))
  eq("previous completefunc restored", vim.bo[bufnr].completefunc, "v:lua.OtherComplete")
  eq("detached 0", core.is_attached(0), false)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("attach restores a previous omnifunc on detach", function()
  local bufnr = new_buffer({ "" })
  vim.bo[bufnr].omnifunc = "v:lua.OtherOmni"
  core.attach(bufnr, { source = sync_source({}), mode = "omnifunc" })
  eq(
    "engine omnifunc",
    vim.bo[bufnr].omnifunc,
    "v:lua.opencode_completion_completefunc"
  )
  core.detach(bufnr)
  eq("previous omnifunc restored", vim.bo[bufnr].omnifunc, "v:lua.OtherOmni")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("candidate fields are copied without mutating source items", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local metadata = { path = "a b/ü.txt" }
  local extra = { keep = true }
  local original = { text = "alpha", metadata = metadata, extra = extra }
  local source = sync_source({ original }, 0)
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)

  local candidate = core.get_candidates(bufnr)[1]
  eq("kind default", candidate.kind, "text")
  eq("source kind untouched", original.kind, nil)
  eq("text", candidate.text, "alpha")
  eq("metadata identity", candidate.metadata, metadata)
  truthy("extra field identity", candidate.extra == extra)
  eq("user_data is the accepted candidate", core.get_state(bufnr).cached.items[1].user_data, candidate)

  candidate.text = "changed"
  eq("source text untouched", original.text, "alpha")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("superseding query cancels the previous handle and ignores its result", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local cancels = 0
  local callbacks = {}
  local requests = {}
  local source = {
    query = function(request, callback)
      requests[#requests + 1] = request
      callbacks[#callbacks + 1] = callback
      return {
        cancel = function()
          cancels = cancels + 1
        end,
      }
    end,
  }
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)
  core.trigger(bufnr)
  eq("old handle cancelled once", cancels, 1)
  eq("monotonic seq", { requests[1].seq, requests[2].seq }, { 1, 2 })

  callbacks[1]({ ok = true, items = { { text = "old" } } })
  eq("old result ignored", #core.get_candidates(bufnr), 0)
  callbacks[2]({ ok = true, items = { { text = "new" } } })
  eq("new result accepted", core.get_candidates(bufnr)[1].text, "new")
  eq("no extra cancel", cancels, 1)
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("a source callback completes at most once", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local source = {
    query = function(_, callback)
      callback({ ok = true, items = { { text = "first" } } })
      callback({ ok = true, items = { { text = "second" } } })
      return nil
    end,
  }
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)
  eq("one candidate", #core.get_candidates(bufnr), 1)
  eq("first result", core.get_candidates(bufnr)[1].text, "first")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("refresh_context clears the previous pum selection", function()
  local bufnr = new_buffer({ "abc" })
  core.attach(bufnr, { source = sync_source({ { text = "abc" } }, 0), context = { session = 1 } })
  core.get_state(bufnr).last_selected = { kind = "file", text = "old", metadata = { id = 1 } }
  truthy("refresh", core.refresh_context(bufnr, { session = 2 }))
  eq("selection cleared", core.get_selected(bufnr), nil)
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("refresh_context invalidates a pending response without a new query", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local cancelled = 0
  local pending
  local source = {
    query = function(_, callback)
      pending = callback
      return function()
        cancelled = cancelled + 1
      end
    end,
  }
  core.attach(bufnr, { source = source, context = { session = 1 } })
  core.trigger(bufnr)
  truthy("refresh", core.refresh_context(bufnr, { session = 2 }))
  eq("pending query cancelled", cancelled, 1)
  pending({ ok = true, items = { { text = "late" } } })
  eq("late result ignored", #core.get_candidates(bufnr), 0)
  eq("not pending", core.get_state(bufnr).pending, false)
  eq("context updated", core.get_state(bufnr).context, { session = 2 })
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("changing the current buffer discards a pending result", function()
  local first = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local pending
  local cancelled = 0
  local source = {
    query = function(_, callback)
      pending = callback
      return function()
        cancelled = cancelled + 1
      end
    end,
  }
  core.attach(first, { source = source })
  core.trigger(first)

  local second = new_buffer({ "" })
  eq("bufleave cancels", cancelled, 1)
  pending({ ok = true, items = { { text = "late" } } })
  eq("first buffer untouched", #core.get_candidates(first), 0)
  eq("no second buffer state", core.get_state(second), nil)
  core.detach(first)
  vim.api.nvim_buf_delete(first, { force = true })
  vim.api.nvim_buf_delete(second, { force = true })
end)

test("auto=false never queries on text changes", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  local source, calls = sync_source({ { text = "abc" } })
  core.attach(bufnr, { source = source, auto = false, debounce = 5 })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
  wait(40)
  eq("no auto query", #calls, 0)
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("invalid start_col values fall back to the cursor column", function()
  local bufnr = new_buffer({ "abcd" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  for _, value in ipairs({ -1, 99 }) do
    local source = sync_source({ { text = "abc" } }, value)
    core.attach(bufnr, { source = source })
    core.trigger(bufnr)
    eq("fallback for " .. value, core.get_state(bufnr).cached.start_col, 3)
    core.detach(bufnr)
  end
  local source = sync_source({ { text = "abc" } }, 1.9)
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)
  eq("floor start col", core.get_state(bufnr).cached.start_col, 1)
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("source failures are silent and do not notify", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local notifications = {}
  local original_notify = vim.notify
  vim.notify = function(...)
    notifications[#notifications + 1] = { ... }
  end
  local ok, err = pcall(function()
    local failing = {
      query = function(_, callback)
        callback({ ok = false, error = { code = "failed", message = "nope" } })
        return function() end
      end,
    }
    core.attach(bufnr, { source = failing })
    eq("error result does not fail trigger", core.trigger(bufnr), true)
    eq("no candidates", #core.get_candidates(bufnr), 0)

    local throwing = {
      query = function()
        error("query exploded")
      end,
    }
    core.detach(bufnr)
    core.attach(bufnr, { source = throwing })
    eq("throwing query returns false", core.trigger(bufnr), false)
    eq("no candidates after throw", #core.get_candidates(bufnr), 0)
    eq("not pending after throw", core.get_state(bufnr).pending, false)
  end)
  vim.notify = original_notify
  truthy("test body completed", ok, err)
  eq("no notifications", #notifications, 0)
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("fast event source callbacks are deferred to the main loop", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  local timer
  local source = {
    query = function(_, callback)
      timer = uv.new_timer()
      timer:start(5, 0, function()
        pcall(timer.stop, timer)
        pcall(timer.close, timer)
        callback({ ok = true, items = { { kind = "file", text = "fast" } }, start_col = 0 })
      end)
      return function()
        pcall(timer.stop, timer)
        pcall(timer.close, timer)
      end
    end,
  }
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)
  wait(80)
  local candidates = core.get_candidates(bufnr)
  eq("one candidate", #candidates, 1)
  eq("fast result accepted", candidates[1].text, "fast")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("cancel is idempotent and detach does not cancel twice", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local cancels = 0
  local source = {
    query = function()
      return {
        cancel = function()
          cancels = cancels + 1
        end,
      }
    end,
  }
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)
  core.get_state(bufnr).last_selected = { text = "old" }
  truthy("first cancel", core.cancel(bufnr))
  eq("cancelled once", cancels, 1)
  eq("selection cleared", core.get_selected(bufnr), nil)
  truthy("second cancel", core.cancel(bufnr))
  eq("still once", cancels, 1)
  core.detach(bufnr)
  eq("detach adds no cancel", cancels, 1)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("table cancel handles receive the handle", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local handle = { cancels = 0 }
  function handle:cancel()
    self.cancels = self.cancels + 1
  end
  local source = {
    query = function()
      return handle
    end,
  }
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)
  core.cancel(bufnr)
  eq("method cancel", handle.cancels, 1)
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("detach then reattach ignores a late response from the old source", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
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

  local new_source = sync_source({ { text = "new" } }, 0)
  core.attach(bufnr, { source = new_source })
  core.trigger(bufnr)
  old_callback({ ok = true, items = { { text = "old" } } })
  local candidates = core.get_candidates(bufnr)
  eq("one new candidate", #candidates, 1)
  eq("old response ignored", candidates[1].text, "new")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("re-attaching replaces and cancels the previous attachment", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local cancels = 0
  local old_callback
  local old_source = {
    query = function(_, callback)
      old_callback = callback
      return function()
        cancels = cancels + 1
      end
    end,
  }
  core.attach(bufnr, { source = old_source })
  core.trigger(bufnr)

  local new_source = sync_source({ { text = "new" } }, 0)
  core.attach(bufnr, { source = new_source })
  eq("old attachment cancelled", cancels, 1)
  core.trigger(bufnr)
  old_callback({ ok = true, items = { { text = "old" } } })
  eq("new attachment intact", core.get_candidates(bufnr)[1].text, "new")
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("invalid options are normalized", function()
  local bufnr = new_buffer({ "" })
  core.attach(bufnr, {
    source = sync_source({}),
    auto = "yes",
    minimum_length = -2,
    debounce = -3,
    trigger_chars = "@",
    keymap = "",
  })
  local options = core.get_state(bufnr).options
  eq("auto default", options.auto, true)
  eq("minimum length clamped", options.minimum_length, 0)
  eq("debounce clamped", options.debounce, 0)
  eq("invalid trigger_chars", options.trigger_chars, nil)
  eq("empty keymap", options.keymap, nil)
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("completefunc cache is invalidated when the cursor moves", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local source = sync_source({ { text = "abc" } }, 0)
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)
  eq("cached findstart", core._completefunc(1, ""), 0)
  eq("cached item", core._completefunc(0, "")[1].word, "abc")

  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  eq("stale findstart", core._completefunc(1, ""), -3)
  core.detach(bufnr)
  eq("detached findstart", core._completefunc(1, ""), -3)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("a pending query does not block editing and is discarded", function()
  local bufnr = new_buffer({ "abc" })
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  local pending
  local cancelled = 0
  local source = {
    query = function(_, callback)
      pending = callback
      return function()
        cancelled = cancelled + 1
      end
    end,
  }
  core.attach(bufnr, { source = source })
  core.trigger(bufnr)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "abcd" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr })
  eq("buffer edit applied", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1], "abcd")
  eq("pending query cancelled", cancelled, 1)
  eq("not pending", core.get_state(bufnr).pending, false)

  pending({ ok = true, items = { { text = "late" } } })
  eq("late result ignored", #core.get_candidates(bufnr), 0)
  core.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("attach rejects a non-table options argument", function()
  local bufnr = new_buffer({ "" })
  eq("string opts", core.attach(bufnr, "nope"), false)
  eq("number opts", core.attach(bufnr, 42), false)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("options can be provided as a nested table", function()
  local bufnr = new_buffer({ "" })
  truthy("attach", core.attach(bufnr, {
    source = sync_source({}),
    options = {
      auto = false,
      minimum_length = 0,
      debounce = 7,
      trigger_chars = { "@" },
      mode = "omnifunc",
      keymap = "<F4>",
    },
  }))
  local options = core.get_state(bufnr).options
  eq("auto", options.auto, false)
  eq("minimum_length", options.minimum_length, 0)
  eq("debounce", options.debounce, 7)
  eq("trigger_chars", options.trigger_chars, { "@" })
  eq("mode", options.mode, "omnifunc")
  eq("keymap", options.keymap, "<F4>")
  eq("buffer-local keymap", vim.fn.maparg("<F4>", "i", false, true).buffer, 1)
  core.detach(bufnr)
  eq("keymap removed", vim.fn.maparg("<F4>", "i"), "")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  io.stderr:write(string.format("%d/%d unit tests failed\n", #failures, count))
  vim.cmd("cquit 1")
else
  print(string.format("ok %d unit tests", count))
end
