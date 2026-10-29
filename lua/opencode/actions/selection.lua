-- Visual selection actions.
--
-- Two entry points share the exact same context extraction/formatting:
--
--   actions.send_selection()      append to the sidebar draft, never submit
--   actions.question_selection()  open a real editable float, prompt on <C-s>
--
-- The module never touches the HTTP client, session ids or SSE.  A question is
-- submitted through the 05A contract `session.prompt(text, callback)`, where a
-- callback with no error means the server accepted the prompt.  Acceptance
-- closes the float immediately; Agent execution is deliberately not awaited.
--
-- Dependencies can be replaced for tests and by the task-10 wiring:
--
--   actions.setup({
--     ui = require("opencode.ui"),
--     session = require("opencode.session"),
--     submit_key = "<C-s>",
--     notify = function(message, level) vim.notify(message, level) end,
--     float = { width = 64, height = 8, border = "rounded" },
--   })
--
-- `send_selection(opts)`/`question_selection(opts)` also accept per-call
-- `ui`, `session`, `notify`, `selection` and `buffer` fields.  Passing a
-- `selection` table is useful for tests and for callers that captured a
-- snapshot before leaving Visual mode.

local context = require("opencode.context")

local M = {}

local defaults = {
  submit_key = "<C-s>",
  cancel_key = "<Esc>",
  float = {
    width = 64,
    height = 8,
    border = "rounded",
    title = "OpenCode question",
  },
}

local state = {
  ui = nil,
  session = nil,
  notify = nil,
  on_question = nil,
  submit_key = defaults.submit_key,
  cancel_key = defaults.cancel_key,
  float = vim.deepcopy(defaults.float),
  question = nil,
  last_question = nil,
  last_prompt = nil,
  last_context = nil,
  last_appended = nil,
}

local function valid_buf(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function default_notify(message, level)
  vim.notify(message, level or vim.log.levels.ERROR)
end

local function emit(notifier, message, level)
  if notifier == false then
    return
  end
  local fn = notifier or state.notify or default_notify
  local ok = pcall(fn, message, level or vim.log.levels.ERROR)
  if not ok and fn ~= default_notify then
    pcall(default_notify, message, level or vim.log.levels.ERROR)
  end
end

local function error_message(err)
  if err == nil then
    return "unknown error"
  end
  if type(err) == "table" then
    if type(err.message) == "string" and err.message ~= "" then
      return err.message
    end
    if err.code ~= nil then
      return tostring(err.code)
    end
    return vim.inspect(err)
  end
  return tostring(err)
end

local function pick(value, fallback)
  if value ~= nil then
    return value
  end
  return fallback
end

-- Dependencies use both styles in this project: opencode.ui exposes plain
-- functions while a 05A controller instance exposes methods.  Pick the style
-- from the function arity so both the frozen `session.prompt(text, callback)`
-- facade and an injected controller work without wrappers.
local function call_dependency(object, name, ...)
  local fn = object[name]
  local argc = select("#", ...)
  local info = debug.getinfo(fn, "u")
  if info ~= nil and not info.isvararg and type(info.nparams) == "number" and info.nparams >= argc + 1 then
    return fn(object, ...)
  end
  return fn(...)
end

local function resolve_ui(value)
  local ui = pick(value, state.ui)
  if ui == nil then
    local ok, module = pcall(require, "opencode.ui")
    if not ok or type(module) ~= "table" then
      return nil, "opencode.ui is not available"
    end
    ui = module
  end
  if type(ui) ~= "table" then
    return nil, "opencode.ui must be a table"
  end
  return ui
end

local function resolve_session(value)
  local session = pick(value, state.session)
  if session == nil then
    local ok, module = pcall(require, "opencode.session")
    if not ok or type(module) ~= "table" then
      return nil, "opencode.session is not available"
    end
    session = module
  end
  if type(session) ~= "table" then
    return nil, "opencode.session must be a table"
  end
  if type(session.prompt) ~= "function" then
    return nil, "opencode.session.prompt is not available"
  end
  return session
end

-- Accept either an options table or a bare selection/context table.  The
-- latter keeps direct calls from mappings and tests concise.
local function normalize_options(opts)
  if type(opts) ~= "table" then
    return opts
  end
  if opts.selection == nil
    and opts.context == nil
    and type(opts.text) == "string"
    and opts.path ~= nil
    and opts.start_line ~= nil
  then
    return { context = opts }
  end
  if opts.selection == nil
    and opts.context == nil
    and (opts.mode ~= nil
      or opts.start ~= nil
      or opts.anchor ~= nil
      or opts.start_row ~= nil
      or opts.start_line ~= nil
      or opts[1] ~= nil)
  then
    local normalized = { selection = opts }
    if opts.buffer ~= nil then
      normalized.buffer = opts.buffer
    end
    return normalized
  end
  return opts
end

local function capture_context(opts)
  if opts.context ~= nil then
    if type(opts.context) ~= "table" then
      return nil, "context must be a table"
    end
    return opts.context
  end

  local selection = opts.selection
  if selection == nil then
    selection = context.current_selection()
  end
  if selection == nil then
    return nil, "no Visual selection is available"
  end

  local buffer = opts.buffer
  if buffer == nil and type(selection) == "table" then
    buffer = selection.buffer or selection.bufnr or selection.buf
  end
  if buffer == nil then
    buffer = vim.api.nvim_get_current_buf()
  end

  local extracted, err = context.from_selection(buffer, selection)
  if not extracted then
    return nil, tostring(err or "cannot extract selection context")
  end
  return extracted
end

local function format_context(selection_context)
  local ok, formatted, err = pcall(context.format, selection_context)
  if not ok then
    return nil, tostring(formatted)
  end
  if type(formatted) ~= "string" then
    return nil, tostring(err or "cannot format selection context")
  end
  return formatted
end

local function close_float(qstate)
  if qstate == nil then
    return
  end
  if state.question == qstate then
    state.question = nil
  end

  if valid_win(qstate.win) then
    pcall(vim.api.nvim_win_close, qstate.win, true)
  end
  if valid_buf(qstate.buf) then
    pcall(vim.api.nvim_buf_delete, qstate.buf, { force = true })
  end
  qstate.closed = true
end

local function open_float(selection_context, formatted, opts)
  -- Opening another question never leaves the previous float, buffer or
  -- buffer-local mappings behind.
  if state.question ~= nil then
    close_float(state.question)
  end

  local ok, buf = pcall(vim.api.nvim_create_buf, false, true)
  if not ok or not valid_buf(buf) then
    return nil, "cannot create question buffer: " .. tostring(buf)
  end

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "opencode_input"
  vim.bo[buf].modifiable = true
  vim.bo[buf].modified = false

  local float = state.float
  local width = math.max(10, math.min(float.width or 64, math.max(vim.o.columns - 2, 10)))
  local height = math.max(2, math.min(float.height or 8, math.max(vim.o.lines - 4, 2)))
  local win_config = {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = float.border or "rounded",
    zindex = 50,
  }
  if type(float.title) == "string" and float.title ~= "" then
    win_config.title = float.title
    win_config.title_pos = "center"
  end

  local win_ok, win = pcall(vim.api.nvim_open_win, buf, true, win_config)
  if not win_ok and win_config.title ~= nil then
    -- Older Neovim versions do not support float titles; functionality is
    -- more important than the title.
    win_config.title = nil
    win_config.title_pos = nil
    win_ok, win = pcall(vim.api.nvim_open_win, buf, true, win_config)
  end
  if not win_ok or not valid_win(win) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil, "cannot open question window: " .. tostring(win)
  end

  pcall(function()
    vim.wo[win].wrap = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].spell = false
  end)

  local qstate = {
    buf = buf,
    win = win,
    context = selection_context,
    formatted = formatted,
    ui = opts.ui,
    session = opts.session,
    notifier = opts.notify,
    submitting = false,
    finished = false,
    closed = false,
    error = nil,
    question = nil,
    prompt = nil,
  }

  local keymap_ok, keymap_error = pcall(function()
    local submit_key = pick(opts.submit_key, state.submit_key)
    if submit_key ~= false and submit_key ~= nil and submit_key ~= "" then
      for _, mode in ipairs({ "i", "n" }) do
        vim.keymap.set(mode, submit_key, function()
          M._submit_question(qstate)
        end, {
          buffer = buf,
          silent = true,
          nowait = true,
          desc = "OpenCode: submit question",
        })
      end
    end

    local cancel_key = pick(opts.cancel_key, state.cancel_key)
    if cancel_key ~= false and cancel_key ~= nil and cancel_key ~= "" then
      vim.keymap.set("n", cancel_key, function()
        M.cancel_question(qstate)
      end, {
        buffer = buf,
        silent = true,
        nowait = true,
        desc = "OpenCode: cancel question",
      })
    end
  end)
  if not keymap_ok then
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil, "cannot install question keymaps: " .. tostring(keymap_error)
  end

  state.question = qstate
  -- The float is a prompt: start in Insert mode but keep all native editing
  -- (including Enter and the Esc mode switch) intact.
  pcall(vim.cmd, "startinsert")
  return qstate
end

--- Append the formatted selection to the sidebar draft and focus the input.
--- Never calls session.prompt, ui.submit or ui.on_submit.
--- @param opts table|nil
--- @return boolean ok
--- @return string|nil error
function M.send_selection(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    return false, "options must be a table"
  end
  opts = normalize_options(opts)

  local notifier = pick(opts.notify, state.notify)
  local extracted, capture_error = capture_context(opts)
  if not extracted then
    emit(notifier, "OpenCode: " .. tostring(capture_error), vim.log.levels.WARN)
    return false, capture_error
  end

  local formatted, format_error = format_context(extracted)
  if not formatted then
    emit(notifier, "OpenCode: " .. tostring(format_error), vim.log.levels.WARN)
    return false, format_error
  end

  local ui, ui_error = resolve_ui(opts.ui)
  if not ui then
    emit(notifier, "OpenCode: " .. tostring(ui_error), vim.log.levels.ERROR)
    return false, ui_error
  end
  if type(ui.append_draft) ~= "function" then
    local message = "opencode.ui.append_draft is not available"
    emit(notifier, "OpenCode: " .. message, vim.log.levels.ERROR)
    return false, message
  end

  local append_ok, append_error = pcall(call_dependency, ui, "append_draft", formatted)
  if not append_ok then
    local message = "cannot append selection to draft: " .. tostring(append_error)
    emit(notifier, "OpenCode: " .. message, vim.log.levels.ERROR)
    return false, message
  end
  state.last_appended = formatted

  local open_ok, open_error = pcall(call_dependency, ui, "open")
  if not open_ok then
    local message = "cannot open sidebar: " .. tostring(open_error)
    emit(notifier, "OpenCode: " .. message, vim.log.levels.ERROR)
    return false, message
  end
  if type(ui.focus_input) == "function" then
    pcall(call_dependency, ui, "focus_input")
  end
  return true
end

--- Capture a selection snapshot and open the editable question float.
--- The snapshot is stored in the float state, so later buffer/selection edits
--- cannot change what will be sent.
--- @param opts table|nil
--- @return boolean ok
--- @return table|string float state or error
function M.question_selection(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    return false, "options must be a table"
  end
  opts = normalize_options(opts)

  local notifier = pick(opts.notify, state.notify)
  local extracted, capture_error = capture_context(opts)
  if not extracted then
    emit(notifier, "OpenCode: " .. tostring(capture_error), vim.log.levels.WARN)
    return false, capture_error
  end

  local formatted, format_error = format_context(extracted)
  if not formatted then
    emit(notifier, "OpenCode: " .. tostring(format_error), vim.log.levels.WARN)
    return false, format_error
  end

  local qstate, open_error = open_float(extracted, formatted, opts)
  if not qstate then
    emit(notifier, "OpenCode: " .. tostring(open_error), vim.log.levels.ERROR)
    return false, open_error
  end
  return true, qstate
end

--- Submit the current float content.  Empty/whitespace-only questions are
--- ignored, duplicate submissions are rejected while one is pending, and
--- failures keep the float and its text for retry.
--- @param qstate table|nil Internal float state (defaults to the open float).
--- @return boolean started
function M._submit_question(qstate)
  if type(qstate) ~= "table" then
    qstate = state.question
  end
  if qstate == nil or state.question ~= qstate then
    return false
  end
  if qstate.submitting then
    return false
  end
  if not valid_buf(qstate.buf) then
    close_float(qstate)
    return false
  end

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, qstate.buf, 0, -1, false)
  if not ok then
    qstate.error = { code = "read_failed", message = tostring(lines) }
    return false
  end
  local question = table.concat(lines or {}, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  if question == "" then
    qstate.error = { code = "empty_input", message = "question must not be empty" }
    return false
  end

  local prompt = question
  if type(qstate.formatted) == "string" and qstate.formatted ~= "" then
    prompt = question .. "\n\n" .. qstate.formatted
  end
  qstate.question = question
  qstate.prompt = prompt
  qstate.error = nil

  local session, session_error = resolve_session(qstate.session)
  if not session then
    qstate.error = { code = "session_unavailable", message = tostring(session_error) }
    emit(qstate.notifier, "OpenCode question failed: " .. tostring(session_error), vim.log.levels.ERROR)
    return false
  end

  qstate.submitting = true
  local completed = false

  local function done(err)
    if completed then
      return
    end
    completed = true
    if state.question ~= qstate then
      return
    end
    qstate.submitting = false

    if err ~= nil and err ~= false then
      qstate.error = err
      emit(
        qstate.notifier,
        "OpenCode question failed: " .. error_message(err),
        vim.log.levels.ERROR
      )
      return
    end

    qstate.finished = true
    local question_text = qstate.question
    local prompt_text = qstate.prompt
    local context_snapshot = qstate.context
    close_float(qstate)

    state.last_question = question_text
    state.last_prompt = prompt_text
    state.last_context = context_snapshot
    if type(state.on_question) == "function" then
      pcall(state.on_question, question_text, prompt_text, context_snapshot)
    end

    local ui, ui_error = resolve_ui(qstate.ui)
    if not ui then
      emit(qstate.notifier, "OpenCode: " .. tostring(ui_error), vim.log.levels.ERROR)
      return
    end
    local open_ok, open_error = pcall(call_dependency, ui, "open")
    if not open_ok then
      emit(
        qstate.notifier,
        "OpenCode: cannot open sidebar: " .. tostring(open_error),
        vim.log.levels.ERROR
      )
      return
    end
    if type(ui.focus_input) == "function" then
      pcall(call_dependency, ui, "focus_input")
    end
  end

  local prompt_ok, prompt_error = pcall(call_dependency, session, "prompt", prompt, done)
  if not prompt_ok and not completed then
    done(prompt_error)
  end
  return true
end

M.submit_question = M._submit_question

--- Cancel the open question without submitting anything.
--- @param qstate table|nil Internal float state (defaults to the open float).
--- @return boolean cancelled
function M.cancel_question(qstate)
  if type(qstate) ~= "table" then
    qstate = state.question
  end
  if qstate == nil or state.question ~= qstate then
    return false
  end
  close_float(qstate)
  return true
end

function M.is_question_open()
  local qstate = state.question
  return qstate ~= nil and valid_win(qstate.win) and valid_buf(qstate.buf)
end

--- Inspectable state for tests and status integrations.
--- @return table
function M.get_question_state()
  local qstate = state.question
  local result = {
    open = qstate ~= nil and valid_win(qstate.win) and valid_buf(qstate.buf),
    last_question = state.last_question,
    last_prompt = state.last_prompt,
    last_appended = state.last_appended,
  }
  if qstate ~= nil then
    result.buffer = qstate.buf
    result.window = qstate.win
    result.submitting = qstate.submitting
    result.finished = qstate.finished
    result.error = qstate.error
    result.question = qstate.question
    result.prompt = qstate.prompt
    result.formatted = qstate.formatted
    if qstate.context ~= nil then
      result.context = vim.deepcopy(qstate.context)
    end
  else
    result.submitting = false
    result.finished = false
  end
  return result
end

function M.get_last_question()
  return state.last_question
end

--- Replace dependencies and float settings.  Safe to call repeatedly.
--- @param opts table|nil
--- @return table actions
function M.setup(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    error("opencode.actions.selection.setup expects a table or nil", 0)
  end
  if state.question ~= nil then
    close_float(state.question)
  end

  if opts.ui ~= nil then
    state.ui = opts.ui
  end
  if opts.session ~= nil then
    state.session = opts.session
  end
  if opts.notify ~= nil then
    assert(type(opts.notify) == "function" or opts.notify == false, "notify must be a function or false")
    state.notify = opts.notify
  end
  if opts.on_question ~= nil then
    assert(opts.on_question == false or type(opts.on_question) == "function", "on_question must be a function or false")
    state.on_question = opts.on_question or nil
  end
  if opts.submit_key ~= nil then
    assert(
      opts.submit_key == false or (type(opts.submit_key) == "string" and opts.submit_key ~= ""),
      "submit_key must be a non-empty string or false"
    )
    state.submit_key = opts.submit_key
  end
  if opts.cancel_key ~= nil then
    assert(
      opts.cancel_key == false or (type(opts.cancel_key) == "string" and opts.cancel_key ~= ""),
      "cancel_key must be a non-empty string or false"
    )
    state.cancel_key = opts.cancel_key
  end
  if opts.float ~= nil then
    assert(type(opts.float) == "table", "float must be a table")
    state.float = vim.tbl_deep_extend("force", vim.deepcopy(defaults.float), opts.float)
  end
  return M
end

--- Reset only this module's resources and injected dependencies.
function M._reset()
  if state.question ~= nil then
    close_float(state.question)
  end
  state.ui = nil
  state.session = nil
  state.notify = nil
  state.on_question = nil
  state.submit_key = defaults.submit_key
  state.cancel_key = defaults.cancel_key
  state.float = vim.deepcopy(defaults.float)
  state.question = nil
  state.last_question = nil
  state.last_prompt = nil
  state.last_context = nil
  state.last_appended = nil
end

return M
