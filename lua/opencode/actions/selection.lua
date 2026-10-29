-- Visual selection actions for the embedded TUI.
--
-- Both entry points use the same context extraction/formatting module.  They
-- interact with OpenCode only through a terminal channel: no HTTP session
-- controller, session ID or server-side prompt API is involved.
--
--   send_selection()      paste formatted context into the TUI composer
--   question_selection()  open a real Vim float; on submit paste question +
--                         context, then send a separate Enter/Submit event
--
-- Bracketed paste keeps ordinary text (including text beginning with "/", ":",
-- or a key-like word) from being interpreted as TUI shortcuts.  Tests inject
-- `opencode.channel.new({})` as `opts.channel` or via setup().

local context = require("opencode.context")

local M = {}

local defaults = {
  submit_key = "<C-s>",
  cancel_key = "<Esc>",
  submit_delay = nil,
  paste = { bracketed = true },
  float = {
    width = 64,
    height = 8,
    border = "rounded",
    title = "OpenCode question",
  },
}

local state = {
  channel = nil,
  focus_input = nil,
  open = nil,
  notify = nil,
  on_question = nil,
  submit_key = defaults.submit_key,
  cancel_key = defaults.cancel_key,
  submit_delay = defaults.submit_delay,
  paste = vim.deepcopy(defaults.paste),
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
  local fn = notifier
  if fn == nil then
    fn = state.notify
  end
  if fn == nil then
    fn = default_notify
  end
  if fn == false then
    return
  end
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

local function call_dependency(object, name, ...)
  local fn = object[name]
  local argc = select("#", ...)
  local info = debug.getinfo(fn, "u")
  if info ~= nil and not info.isvararg and type(info.nparams) == "number" and info.nparams >= argc + 1 then
    return fn(object, ...)
  end
  return fn(...)
end

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

local function resolve_channel(opts)
  local channel = pick(opts.channel, state.channel)
  if type(channel) == "function" then
    local ok, value = pcall(channel)
    channel = ok and value or nil
  end
  if channel == nil then
    local opener = pick(opts.open, state.open)
    if opener ~= false then
      if type(opener) == "function" then
        pcall(opener)
      else
        local ok, module = pcall(require, "opencode")
        if ok and type(module) == "table" and type(module.open) == "function" then
          pcall(module.open)
        end
      end
    end
    local ok, module = pcall(require, "opencode")
    if ok and type(module) == "table" and type(module.channel) == "function" then
      local channel_ok, live = pcall(module.channel)
      if channel_ok then
        channel = live
      end
    end
  end
  if type(channel) ~= "table" then
    return nil, "OpenCode terminal is not available"
  end
  if type(channel.paste) ~= "function" then
    return nil, "terminal channel cannot paste"
  end
  if type(channel.submit) ~= "function" then
    return nil, "terminal channel cannot submit"
  end
  if type(channel.is_alive) == "function" then
    local ok, alive = pcall(channel.is_alive, channel)
    if not ok or not alive then
      return nil, "OpenCode terminal is not running"
    end
  end
  return channel
end

local function focus_composer(opts)
  local focus = pick(opts.focus_input, state.focus_input)
  if focus == false then
    return true
  end
  if type(focus) == "function" then
    pcall(focus)
    return true
  end
  local ok, module = pcall(require, "opencode")
  if ok and type(module) == "table" and type(module.focus_input) == "function" then
    pcall(module.focus_input)
  end
  return true
end

local function paste_opts(opts)
  local value = pick(opts.paste, state.paste)
  if type(value) ~= "table" then
    return { bracketed = true }
  end
  return value
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
    channel = opts.channel,
    focus_input = opts.focus_input,
    open = opts.open,
    notifier = opts.notify,
    paste = opts.paste,
    submit_delay = opts.submit_delay,
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
  pcall(vim.cmd, "startinsert")
  return qstate
end

--- Paste the formatted selection into the TUI composer.  Never submits.
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

  local channel, channel_error = resolve_channel(opts)
  if not channel then
    emit(notifier, "OpenCode: " .. tostring(channel_error), vim.log.levels.ERROR)
    return false, channel_error
  end

  focus_composer(opts)
  local ok, err = channel:paste(formatted, paste_opts(opts))
  if not ok then
    local message = "cannot write selection to OpenCode composer: " .. error_message(err)
    emit(notifier, "OpenCode: " .. message, vim.log.levels.ERROR)
    return false, message
  end
  state.last_appended = formatted
  return true
end

--- Capture a selection snapshot and open the editable question float.
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

--- Submit the open question through the terminal channel.
--- @param qstate table|nil
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

  local channel, channel_error = resolve_channel(qstate)
  if not channel then
    qstate.error = { code = "terminal_unavailable", message = tostring(channel_error) }
    emit(qstate.notifier, "OpenCode question failed: " .. tostring(channel_error), vim.log.levels.ERROR)
    return false
  end

  qstate.submitting = true
  focus_composer(qstate)

  local paste_ok, paste_error = channel:paste(prompt, paste_opts(qstate))
  if not paste_ok then
    qstate.submitting = false
    qstate.error = { code = "paste_failed", message = error_message(paste_error) }
    emit(qstate.notifier, "OpenCode question failed: " .. error_message(paste_error), vim.log.levels.ERROR)
    return false
  end

  local submit_ok, submit_error = channel:submit({
    delay = pick(qstate.submit_delay, state.submit_delay),
  })
  if not submit_ok then
    -- The text is already in the TUI; keep it there and ask the user to press
    -- Enter manually instead of silently duplicating it on retry.
    qstate.finished = true
    qstate.submitting = false
    qstate.error = { code = "submit_failed", message = error_message(submit_error) }
    close_float(qstate)
    emit(
      qstate.notifier,
      "OpenCode: prompt was pasted but submit failed ("
        .. error_message(submit_error)
        .. "); press Enter in OpenCode",
      vim.log.levels.ERROR
    )
    return false
  end

  qstate.finished = true
  qstate.submitting = false
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
  return true
end

M.submit_question = M._submit_question

--- Cancel the open question without sending anything.
--- @param qstate table|nil
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

  if opts.channel ~= nil then
    state.channel = opts.channel
  end
  if opts.focus_input ~= nil then
    assert(opts.focus_input == false or type(opts.focus_input) == "function", "focus_input must be a function or false")
    state.focus_input = opts.focus_input
  end
  if opts.open ~= nil then
    assert(opts.open == false or type(opts.open) == "function", "open must be a function or false")
    state.open = opts.open
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
  if opts.submit_delay ~= nil then
    assert(type(opts.submit_delay) == "number" and opts.submit_delay >= 0, "submit_delay must be a non-negative number")
    state.submit_delay = opts.submit_delay
  end
  if opts.paste ~= nil then
    assert(type(opts.paste) == "table", "paste must be a table")
    state.paste = vim.tbl_deep_extend("force", vim.deepcopy(defaults.paste), opts.paste)
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
  state.channel = nil
  state.focus_input = nil
  state.open = nil
  state.notify = nil
  state.on_question = nil
  state.submit_key = defaults.submit_key
  state.cancel_key = defaults.cancel_key
  state.submit_delay = defaults.submit_delay
  state.paste = vim.deepcopy(defaults.paste)
  state.float = vim.deepcopy(defaults.float)
  state.question = nil
  state.last_question = nil
  state.last_prompt = nil
  state.last_context = nil
  state.last_appended = nil
end

return M
