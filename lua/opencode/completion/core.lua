--- Asynchronous completion engine bound to a single buffer.
---
--- The engine owns no UI and performs no network requests.  A source is
--- injected through `attach()` and implements the async `source.query`
--- contract documented below.
---
--- Source contract:
---
---   source.query(request, callback) -> cancel_handle|nil
---
---   request = {
---     bufnr        = integer,       -- attached buffer
---     lnum         = integer,       -- 1-based cursor line
---     col          = integer,       -- 0-based cursor byte column
---     line         = string,        -- full line text
---     before_cursor= string,        -- line text up to the cursor
---     context      = any,           -- opaque value passed to attach/refresh_context
---     context_revision = integer,   -- changes on refresh_context
---     seq          = integer,       -- monotonically increasing query id
---     trigger      = "auto"|"manual",
---   }
---
---   callback({
---     ok       = true,
---     items    = { { kind=string, text=string, metadata=any, ... }, ... },
---     start_col= integer|nil,       -- 0-based byte column, defaults to request.col
---   })
---   callback({ ok = false, error = { code = string, message = string } })
---
---   The handle may be a function or a table with a `cancel`/`abort`/`stop`
---   field.  Calling it more than once must be safe.  The callback must be
---   called at most once; it may run synchronously or asynchronously and is
---   deferred automatically when invoked from a libuv fast event.  The engine
---   validates the buffer, cursor and context again before using a result.
---   Errors are never displayed by the engine.
---
--- Candidate `text` is the inserted word.  `kind` defaults to "text" when
--- absent.  The engine shallow-copies each candidate table, so `kind`,
--- `text`, `metadata` and any extra fields reach insertion/commit layers
--- through `get_candidates()`, `get_selected()` and the `user_data` field of
--- the native completion item without changing the source's table.
---
--- Options (passed as `attach(bufnr, { ..., options = opts })` or as
--- top-level fields):
---
---   auto           = boolean   -- query on TextChangedI (default true)
---   minimum_length = integer   -- characters in the current token (default 1)
---   debounce       = integer   -- milliseconds (default 100)
---   trigger_chars  = string[]? -- require one of these in the current token
---   mode           = "completefunc"|"omnifunc" (default "completefunc")
---   keymap         = string?   -- optional buffer-local insert mapping
---
--- The engine never maps Tab, S-Tab, CR, C-n or C-p by default.  `trigger`
--- and `cancel` accept `0` as the current buffer.  `detach` is idempotent.

local M = {}

-- Function options cannot use a `require(...)` expression, so expose the
-- native completion entry point through one prefixed global name.
_G.opencode_completion_completefunc = function(...)
  return M._completefunc(...)
end

local uv = vim.uv or vim.loop

local OPTION_FUNC = "v:lua.opencode_completion_completefunc"

local DEFAULTS = {
  auto = true,
  minimum_length = 1,
  debounce = 100,
  trigger_chars = nil,
  mode = "completefunc",
  keymap = nil,
}

local states = {}

local function new_augroup(bufnr)
  return vim.api.nvim_create_augroup("opencode_completion_" .. bufnr, { clear = true })
end

local function is_insert_mode()
  local ok, mode = pcall(vim.fn.mode, 1)
  if not ok or type(mode) ~= "string" then
    return false
  end
  local first = mode:sub(1, 1)
  return first == "i" or first == "R"
end

local function resolve_bufnr(bufnr)
  if bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function buffer_ok(bufnr)
  return type(bufnr) == "number"
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.api.nvim_buf_is_loaded(bufnr)
end

local function cursor_context(bufnr)
  if not buffer_ok(bufnr) then
    return nil
  end
  local win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local pos = vim.api.nvim_win_get_cursor(win)[2]
  pos = math.max(0, math.min(pos, #line))
  return {
    lnum = lnum,
    col = pos,
    line = line,
    before_cursor = line:sub(1, pos),
  }
end

local function normalize_cancel(handle)
  if type(handle) == "function" then
    return handle
  end
  if type(handle) == "table" then
    local cancel = handle.cancel or handle.abort or handle.stop
    if type(cancel) == "function" then
      return function()
        return cancel(handle)
      end
    end
  end
  return nil
end

local function call_cancel(handle)
  local cancel = normalize_cancel(handle)
  if cancel then
    pcall(cancel)
  end
end

local function stop_timer(state)
  if state.timer then
    pcall(state.timer.stop, state.timer)
    pcall(state.timer.close, state.timer)
    state.timer = nil
  end
end

--- Invalidate every pending result.  No buffer is touched.
local function invalidate(state)
  state.request_id = state.request_id + 1
  state.debounce_id = state.debounce_id + 1
  state.pending = false
  if state.active then
    call_cancel(state.active.handle)
    state.active = nil
  end
  stop_timer(state)
  state.candidates = {}
  state.cached = nil
end

local function normalize_items(items)
  local candidates = {}
  local complete_items = {}
  for _, item in ipairs(items) do
    if type(item) == "table" and type(item.text) == "string" then
      local candidate = {}
      for key, value in pairs(item) do
        candidate[key] = value
      end
      if candidate.kind == nil then
        candidate.kind = "text"
      end
      candidates[#candidates + 1] = candidate
      complete_items[#complete_items + 1] = {
        word = candidate.text,
        abbr = type(candidate.abbr) == "string" and candidate.abbr or candidate.text,
        menu = type(candidate.menu) == "string" and candidate.menu or candidate.kind,
        info = type(candidate.info) == "string" and candidate.info or nil,
        user_data = candidate,
        dup = candidate.dup and 1 or nil,
        icase = candidate.icase and 1 or nil,
      }
    end
  end
  return candidates, complete_items
end

local function record_selection(state, item)
  if type(item) == "table" and type(item.user_data) == "table" then
    state.last_selected = item.user_data
  end
end

local function completion_active()
  local ok, info = pcall(vim.fn.complete_info, { "mode" })
  if not ok or type(info) ~= "table" then
    return false
  end
  return type(info.mode) == "string" and info.mode ~= ""
end

local function complete_now(state, start_col, complete_items)
  if not is_insert_mode() then
    return false
  end
  state.pum_active = false
  local ok = pcall(vim.fn.complete, start_col + 1, complete_items)
  state.pum_active = ok
  return ok
end

local function accept_result(state, generation, id, request, result)
  if
    state.request_id ~= generation
    or state.query_seq ~= id
    or state.context_revision ~= request.context_revision
  then
    return
  end
  local function discard()
    state.active = nil
    state.pending = false
    state.candidates = {}
    state.cached = nil
  end
  if not state.attached or not buffer_ok(state.bufnr) then
    discard()
    return
  end
  if vim.api.nvim_get_current_buf() ~= state.bufnr then
    discard()
    return
  end
  if type(result) ~= "table" or result.ok == false then
    discard()
    return
  end
  local items = result.items
  if type(items) ~= "table" then
    discard()
    return
  end

  local now = cursor_context(state.bufnr)
  if not now
    or now.lnum ~= request.lnum
    or now.col ~= request.col
    or now.line ~= request.line
  then
    discard()
    return
  end

  local start_col = result.start_col
  if type(start_col) ~= "number" or start_col < 0 or start_col > request.col then
    start_col = request.col
  end
  start_col = math.floor(start_col)

  local candidates, complete_items = normalize_items(items)
  state.candidates = candidates
  state.start_col = start_col
  state.cached = {
    start_col = start_col,
    items = complete_items,
    lnum = request.lnum,
    col = request.col,
    line = request.line,
  }
  state.active = nil
  state.pending = false

  if #complete_items > 0 then
    complete_now(state, start_col, complete_items)
  end
end

local function dispatch(state, trigger)
  if not state.attached or not state.source or not buffer_ok(state.bufnr) then
    return false
  end
  if trigger == "auto" and not is_insert_mode() then
    return false
  end
  local ctx = cursor_context(state.bufnr)
  if not ctx then
    return false
  end

  state.query_seq = state.query_seq + 1
  local id = state.query_seq
  local generation = state.request_id
  state.pending = true
  state.candidates = {}
  state.cached = nil

  local request = {
    bufnr = state.bufnr,
    lnum = ctx.lnum,
    col = ctx.col,
    line = ctx.line,
    before_cursor = ctx.before_cursor,
    context = state.context,
    context_revision = state.context_revision,
    seq = id,
    trigger = trigger,
  }

  local done = false
  local function callback(result)
    if done then
      return
    end
    done = true
    local function finish()
      accept_result(state, generation, id, request, result)
    end
    if type(vim.in_fast_event) == "function" and vim.in_fast_event() then
      vim.schedule(finish)
    else
      finish()
    end
  end

  local ok, handle = pcall(state.source.query, request, callback)
  if not ok then
    if not done and state.request_id == generation and state.query_seq == id then
      state.pending = false
      state.active = nil
    end
    return done
  end
  if state.request_id == generation and state.query_seq == id and state.pending and not done then
    state.active = { id = id, generation = generation, handle = handle }
  end
  return true
end

local function current_token(before_cursor)
  return before_cursor:match("[^%s]*$") or ""
end

local function text_counts(text)
  return vim.fn.strchars(text)
end

local function auto_allowed(state, before_cursor)
  if not state.options.auto then
    return false
  end
  local token = current_token(before_cursor)
  local chars = state.options.trigger_chars
  if type(chars) == "table" and #chars > 0 then
    local found = false
    for _, ch in ipairs(chars) do
      if type(ch) == "string" and ch ~= "" and token:find(ch, 1, true) then
        found = true
        break
      end
    end
    if not found then
      return false
    end
  end
  local min = state.options.minimum_length or 0
  return text_counts(token) >= min
end

local function schedule_auto(state)
  local ctx = cursor_context(state.bufnr)
  if not ctx then
    return
  end
  if not auto_allowed(state, ctx.before_cursor) then
    return
  end
  if not state.timer then
    state.timer = uv.new_timer()
  end
  state.debounce_id = state.debounce_id + 1
  local id = state.debounce_id
  state.timer:start(
    math.max(0, state.options.debounce or 0),
    0,
    vim.schedule_wrap(function()
      if not state.attached or state.debounce_id ~= id then
        return
      end
      dispatch(state, "auto")
    end)
  )
end

local function on_text_changed(state)
  if not state.attached or not buffer_ok(state.bufnr) then
    return
  end
  -- Every edit invalidates results computed for the previous text.
  invalidate(state)
  schedule_auto(state)
end

local function close_pum_if_ours(state)
  if not state.pum_active then
    return
  end
  state.pum_active = false
  if
    not is_insert_mode()
    or vim.api.nvim_get_current_buf() ~= state.bufnr
    or not completion_active()
  then
    return
  end
  local keys = vim.api.nvim_replace_termcodes("<C-e>", true, false, true)
  vim.api.nvim_feedkeys(keys, "ni", false)
end

local function restore_option(state)
  if not buffer_ok(state.bufnr) then
    return
  end
  local current = vim.bo[state.bufnr][state.options.mode]
  if current == OPTION_FUNC then
    pcall(function()
      vim.bo[state.bufnr][state.options.mode] = state.previous_option or ""
    end)
  end
end

--- Native complete-function entry point.  It serves the cached result of the
--- most recent query, so `<C-x><C-u>`/`<C-x><C-o>` can reuse native pum
--- behavior without starting another asynchronous request.
function M._completefunc(findstart, base)
  local bufnr = vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state or not state.attached or not state.cached then
    if findstart == 1 then
      return -3
    end
    return {}
  end
  local ctx = cursor_context(bufnr)
  local cached = state.cached
  if findstart == 1 then
    if
      not ctx
      or ctx.lnum ~= cached.lnum
      or ctx.col ~= cached.col
      or ctx.line ~= cached.line
    then
      return -3
    end
    return cached.start_col
  end
  -- On the second invocation Vim may temporarily move the cursor while
  -- extracting the base text, so only the cache snapshot is authoritative.
  state.pum_active = true
  return cached.items
end

--- Attach the engine to a buffer.  Returns true on success.
function M.attach(bufnr, opts)
  bufnr = resolve_bufnr(bufnr)
  if not buffer_ok(bufnr) then
    return false
  end
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    return false
  end
  if type(opts.source) ~= "table" or type(opts.source.query) ~= "function" then
    return false
  end
  if states[bufnr] then
    M.detach(bufnr)
  end

  local base_options = type(opts.options) == "table" and opts.options or {}
  local options = vim.tbl_extend("force", DEFAULTS, base_options)
  if opts.auto ~= nil then
    options.auto = opts.auto
  end
  if opts.minimum_length ~= nil then
    options.minimum_length = opts.minimum_length
  end
  if opts.debounce ~= nil then
    options.debounce = opts.debounce
  end
  if opts.trigger_chars ~= nil then
    options.trigger_chars = opts.trigger_chars
  end
  if opts.mode ~= nil then
    options.mode = opts.mode
  end
  if opts.keymap ~= nil then
    options.keymap = opts.keymap
  end
  if options.mode ~= "completefunc" and options.mode ~= "omnifunc" then
    options.mode = "completefunc"
  end
  if type(options.auto) ~= "boolean" then
    options.auto = DEFAULTS.auto
  end
  if type(options.minimum_length) ~= "number" then
    options.minimum_length = DEFAULTS.minimum_length
  else
    options.minimum_length = math.max(0, math.floor(options.minimum_length))
  end
  if type(options.debounce) ~= "number" then
    options.debounce = DEFAULTS.debounce
  else
    options.debounce = math.max(0, math.floor(options.debounce))
  end
  if type(options.trigger_chars) ~= "table" then
    options.trigger_chars = nil
  else
    local chars = {}
    for _, ch in ipairs(options.trigger_chars) do
      if type(ch) == "string" and ch ~= "" then
        chars[#chars + 1] = ch
      end
    end
    options.trigger_chars = #chars > 0 and chars or nil
  end
  if type(options.keymap) ~= "string" or options.keymap == "" then
    options.keymap = nil
  end

  local previous_option = vim.bo[bufnr][options.mode] or ""
  if previous_option == OPTION_FUNC then
    previous_option = ""
  end

  local state = {
    bufnr = bufnr,
    source = opts.source,
    context = opts.context,
    options = options,
    previous_option = previous_option,
    attached = true,
    request_id = 0,
    query_seq = 0,
    debounce_id = 0,
    context_revision = 0,
    candidates = {},
    pending = false,
    pum_active = false,
  }
  states[bufnr] = state

  local group = new_augroup(bufnr)
  state.augroup = group
  vim.api.nvim_create_autocmd({ "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      on_text_changed(state)
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertLeavePre" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      invalidate(state)
      state.pum_active = false
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      invalidate(state)
      state.pum_active = false
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.detach(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd({ "CompleteChanged" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      local event = vim.v.event
      if type(event) == "table" then
        record_selection(state, event.completed_item)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CompleteDone" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      state.pum_active = false
      local item = vim.v.completed_item
      if type(item) == "table" and type(item.user_data) == "table" then
        record_selection(state, item)
      else
        state.last_selected = nil
      end
    end,
  })

  local func = OPTION_FUNC
  local option_ok = pcall(function()
    vim.bo[bufnr][options.mode] = func
  end)
  if not option_ok then
    M.detach(bufnr)
    return false
  end

  if type(options.keymap) == "string" and options.keymap ~= "" then
    state.keymap = options.keymap
    pcall(vim.keymap.set, "i", options.keymap, function()
      M.trigger(bufnr, "manual")
    end, {
      buffer = bufnr,
      silent = true,
      desc = "OpenCode completion",
    })
  end

  return true
end

--- Trigger an immediate query.  `trigger` is "manual" by default.  Returns
--- true when a query was started.  The native pum is only opened while in
--- Insert mode; otherwise the accepted result is kept in the cache.
function M.trigger(bufnr, trigger)
  bufnr = resolve_bufnr(bufnr)
  local state = states[bufnr]
  if not state or not state.attached then
    return false
  end
  if trigger ~= "auto" then
    trigger = "manual"
  end
  invalidate(state)
  return dispatch(state, trigger)
end

--- Cancel the pending timer and in-flight query.  Native pum is left alone
--- unless this engine opened it.
function M.cancel(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local state = states[bufnr]
  if not state or not state.attached then
    return false
  end
  invalidate(state)
  state.last_selected = nil
  close_pum_if_ours(state)
  return true
end

--- Replace the opaque context and invalidate every old response.
function M.refresh_context(bufnr, context)
  bufnr = resolve_bufnr(bufnr)
  local state = states[bufnr]
  if not state or not state.attached then
    return false
  end
  state.context_revision = state.context_revision + 1
  state.context = context
  state.last_selected = nil
  invalidate(state)
  close_pum_if_ours(state)
  return true
end

--- Detach from a buffer.  Idempotent; safe for an unloaded buffer.
function M.detach(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local state = states[bufnr]
  if not state then
    return false
  end
  state.attached = false
  invalidate(state)
  close_pum_if_ours(state)
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  if state.keymap and buffer_ok(bufnr) then
    pcall(vim.keymap.del, "i", state.keymap, { buffer = bufnr })
  end
  restore_option(state)
  states[bufnr] = nil
  return true
end

function M.is_attached(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local state = states[bufnr]
  return state ~= nil and state.attached == true
end

--- Latest accepted candidates for a buffer.  Candidate tables are copies of
--- the source items, so `metadata` and extra fields are passed through
--- unchanged while the source's own tables stay untouched.
function M.get_candidates(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local state = states[bufnr]
  if not state then
    return {}
  end
  return state.candidates
end

--- Most recent candidate selected in the native pum (updated while the pum
--- selection changes and when completion is finished), or nil if none yet.
function M.get_selected(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local state = states[bufnr]
  return state and state.last_selected or nil
end

--- Exposed for tests and integration code; not required by the source API.
function M.get_state(bufnr)
  bufnr = resolve_bufnr(bufnr)
  return states[bufnr]
end

return M
