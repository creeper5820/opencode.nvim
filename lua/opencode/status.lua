-- Window-local OpenCode session/status display.
--
-- This module only consumes status snapshots and setters. It never parses SSE,
-- creates windows, or reads session/block internals. The UI owns the two
-- windows; 10 wires the two layers together.
--
-- The winbar is built from a status snapshot shaped like the 05C status:
--
--   {
--     session = { id = "...", title = "..." },
--     project = { root = "..." },
--     agent = { id = "...", name = "..." },
--     model = { provider_id = "...", id = "..." },
--     connection = "connecting|connected|reconnecting|offline",
--     submission = "idle|submitting|failed",
--     execution = "idle|streaming|tool_running|retrying|compacting|"
--       .. "waiting_permission|interrupted|failed",
--     waiting_permission = { [request_id] = { ... } },
--   }
--
-- Missing fields are omitted rather than replaced with misleading defaults.
-- Every field is escaped before being written to the winbar, so a session title
-- containing "%" or newlines cannot inject statusline items.
local M = {}

local uv = vim.uv or vim.loop
local AUGROUP_NAME = "OpencodeStatusWinbar"
local MESSAGE = "message"
local INPUT = "input"

local DEFAULTS = {
  spinner_interval = 1000,
  spinner_frames = { "|", "/", "-", "\\" },
  limits = {
    session = 40,
    project = 32,
    agent = 24,
    model = 32,
    status = 24,
    hint = 24,
  },
}

local EXECUTION_LABELS = {
  idle = "idle",
  streaming = "streaming",
  tool_running = "tool running",
  retrying = "retrying",
  compacting = "compacting",
  waiting_permission = "waiting permission",
  interrupted = "interrupted",
  failed = "failed",
}

local function copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local out = {}
  seen[value] = out
  for key, item in pairs(value) do
    out[copy(key, seen)] = copy(item, seen)
  end
  return out
end

local function first(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if value ~= nil then
      return value
    end
  end
  return nil
end

local function merge_table(base, patch)
  if patch == nil then
    return base
  end
  if type(base) ~= "table" or type(patch) ~= "table" then
    return copy(patch)
  end
  local out = copy(base)
  for key, value in pairs(patch) do
    if type(value) == "table" and type(out[key]) == "table" then
      out[key] = merge_table(out[key], value)
    else
      out[key] = copy(value)
    end
  end
  return out
end

local function text_value(value)
  local kind = type(value)
  if kind == "string" then
    return value
  end
  if kind == "number" then
    return tostring(value)
  end
  return nil
end

-- Remove control characters and collapse whitespace so a title cannot break a
-- single-line winbar. Values that are empty after sanitizing are treated as
-- unavailable and omitted by renderers.
local function sanitize(value)
  local text = text_value(value)
  if not text then
    return nil
  end
  text = text:gsub("[\r\n\t]", " ")
  text = text:gsub("%c", " ")
  text = text:gsub("%s+", " ")
  text = vim.trim(text)
  if text == "" then
    return nil
  end
  return text
end

local function pick_text(...)
  for index = 1, select("#", ...) do
    local value = sanitize(select(index, ...))
    if value then
      return value
    end
  end
  return nil
end

local function clip(value, maximum)
  local text = sanitize(value)
  if not text then
    return nil
  end
  if type(maximum) == "number" and maximum > 0 then
    local count = vim.fn.strchars(text)
    if count > maximum then
      text = vim.fn.strcharpart(text, 0, math.max(maximum - 1, 0)) .. "…"
    end
  end
  return text
end

-- Escape only statusline metacharacters. Everything else is literal text.
local function escape_statusline(text)
  if type(text) ~= "string" or text == "" then
    return ""
  end
  return (text:gsub("%%", "%%%%"))
end

local function clip_display(text, width)
  if type(width) ~= "number" or width <= 0 then
    return text
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width <= 1 then
    return "…"
  end
  local maximum = width - 1
  local used = 0
  local out = {}
  for index = 0, vim.fn.strchars(text) - 1 do
    local char = vim.fn.strcharpart(text, index, 1)
    local advance = vim.fn.strdisplaywidth(char)
    if used + advance > maximum then
      break
    end
    out[#out + 1] = char
    used = used + advance
  end
  return table.concat(out) .. "…"
end

local function merge_limits(overrides)
  local out = copy(DEFAULTS.limits)
  if type(overrides) == "table" then
    for key, value in pairs(overrides) do
      if type(value) == "number" and value > 0 then
        out[key] = math.floor(value)
      end
    end
  end
  return out
end

local function basename(path)
  local text = sanitize(path)
  if not text then
    return nil
  end
  local trimmed = text:gsub("[/\\]+$", "")
  if trimmed == "" then
    return text
  end
  local name = vim.fn.fnamemodify(trimmed, ":t")
  if not name or name == "" then
    name = trimmed
  end
  return name
end

local function session_id_of(session)
  if type(session) == "string" then
    return sanitize(session)
  end
  if type(session) ~= "table" then
    return nil
  end
  return pick_text(session.id, session.sessionID, session.session_id)
end

local function session_label(session)
  if type(session) == "string" then
    return session
  end
  if type(session) ~= "table" then
    return nil
  end
  return pick_text(session.title, session.name, session.id, session.sessionID, session.session_id)
end

local function project_label(project)
  if type(project) == "string" then
    return basename(project)
  end
  if type(project) ~= "table" then
    return nil
  end
  local name = pick_text(project.name, project.title)
  if name then
    return name
  end
  return basename(first(project.root, project.path, project.worktree))
end

local function agent_label(agent)
  if type(agent) == "string" then
    return agent
  end
  if type(agent) ~= "table" then
    return nil
  end
  return pick_text(agent.name, agent.id, agent.agent)
end

local function model_label(model)
  if type(model) == "string" then
    return model
  end
  if type(model) ~= "table" then
    return nil
  end
  local provider = pick_text(model.provider_id, model.providerID, model.provider)
  local id = pick_text(model.id, model.modelID, model.model, model.name)
  if provider and id then
    return provider .. "/" .. id
  end
  return id or provider
end

local function state_text(value)
  if type(value) == "table" then
    value = first(value.state, value.status, value.type, value.value)
  end
  return sanitize(value)
end

-- waiting_permission may be a map keyed by request id (05C), an array, a count,
-- or a boolean. `nil` means "no information", not "nothing pending".
local function permission_count(value)
  if value == nil or value == false then
    return 0
  end
  if value == true then
    return 1
  end
  if type(value) == "number" then
    local count = math.floor(value)
    return count > 0 and count or 0
  end
  if type(value) == "string" then
    return sanitize(value) and 1 or 0
  end
  if type(value) ~= "table" then
    return 0
  end
  local explicit = first(value.count, value.n, value.pending)
  if type(explicit) == "number" then
    local count = math.floor(explicit)
    return count > 0 and count or 0
  end
  if explicit == true then
    return 1
  end
  local count = 0
  for key, item in pairs(value) do
    if key ~= "count" and key ~= "n" and key ~= "pending" and item ~= nil then
      count = count + 1
    end
  end
  return count
end

local function permission_label(value)
  local count = permission_count(value)
  if count <= 0 then
    return nil
  end
  if count == 1 then
    return "waiting permission"
  end
  return ("waiting permission (%d)"):format(count)
end

local function append_field(target, label, value, maximum)
  local text = clip(value, maximum)
  if text then
    target[#target + 1] = label .. ": " .. text
  end
end

local function status_fields(source, limits, options)
  local fields = {}
  append_field(fields, "Connection", state_text(source.connection), limits.status)
  append_field(fields, "Submission", state_text(source.submission), limits.status)

  local execution_raw = state_text(source.execution)
  local execution = execution_raw and (EXECUTION_LABELS[execution_raw] or execution_raw) or nil
  append_field(fields, "Execution", execution, limits.status)

  -- Keep a pending permission visible even when the execution dimension has
  -- moved on to ordinary tool progress. Only an explicit empty/nil permission
  -- snapshot clears it.
  if permission_count(source.waiting_permission) > 0 and execution_raw ~= "waiting_permission" then
    fields[#fields + 1] = "Permission: " .. permission_label(source.waiting_permission)
  end

  local spinner = sanitize(options.spinner)
  if spinner then
    fields[#fields + 1] = spinner
  end
  return fields
end

--- Build winbar text for a status snapshot. This is pure and has no UI side
--- effects, which makes the formatting rules independently testable.
---
--- @param snapshot table|nil Status snapshot (session/project/agent/model/...).
--- @param target string|nil "message" (default) or "input".
--- @param options table|nil { limits, spinner, submit_hint, width }
--- @return string
function M.render(snapshot, target, options)
  options = type(options) == "table" and options or {}
  local source = type(snapshot) == "table" and snapshot or {}
  local limits = merge_limits(options.limits)
  local is_input = target == INPUT

  local groups = {}
  if is_input then
    local session = clip(session_label(source.session), limits.session)
    if session then
      groups[#groups + 1] = "Session: " .. session
    end
  else
    local metadata = {}
    append_field(metadata, "Session", session_label(source.session), limits.session)
    append_field(metadata, "Project", project_label(source.project), limits.project)
    if #metadata > 0 then
      groups[#groups + 1] = table.concat(metadata, " · ")
    end

    local model = {}
    append_field(model, "Agent", agent_label(source.agent), limits.agent)
    append_field(model, "Model", model_label(source.model), limits.model)
    if #model > 0 then
      groups[#groups + 1] = table.concat(model, " · ")
    end
  end

  local statuses = status_fields(source, limits, options)
  if #statuses > 0 then
    groups[#groups + 1] = table.concat(statuses, " · ")
  end

  if is_input then
    local hint = clip(options.submit_hint, limits.hint)
    if hint then
      groups[#groups + 1] = hint
    end
  end

  if #groups == 0 then
    return ""
  end
  local line = table.concat(groups, " | ")
  if options.width then
    line = clip_display(line, options.width)
  end
  return escape_statusline(line)
end

local function new_state()
  return {
    session = nil,
    project = nil,
    agent = nil,
    model = nil,
    connection = nil,
    submission = nil,
    execution = nil,
    waiting_permission = nil,
    error = nil,
    retry = nil,
    compaction = nil,
    generation = nil,
    spinner_frame = 0,
    notified_submission = false,
    notified_execution = false,
  }
end

local function new_settings()
  return {
    spinner_interval = DEFAULTS.spinner_interval,
    spinner_frames = copy(DEFAULTS.spinner_frames),
    limits = copy(DEFAULTS.limits),
    submit_hint = nil,
  }
end

local current = new_state()
local settings = new_settings()
local windows = {}
local timer = nil
local augroup = nil

local function window_valid(win)
  if type(win) ~= "number" then
    return false
  end
  local ok, valid = pcall(vim.api.nvim_win_is_valid, win)
  return ok and valid == true
end

local function any_valid_window()
  for _, entry in pairs(windows) do
    if window_valid(entry.window) then
      return true
    end
  end
  return false
end

local function spinner_active()
  if current.connection == "connecting" or current.connection == "reconnecting" then
    return true
  end
  if current.submission == "submitting" then
    return true
  end
  return current.execution == "streaming"
    or current.execution == "tool_running"
    or current.execution == "retrying"
    or current.execution == "compacting"
end

local function spinner_text()
  if not spinner_active() then
    return nil
  end
  local frames = settings.spinner_frames
  if type(frames) ~= "table" or #frames == 0 then
    return nil
  end
  return frames[(current.spinner_frame % #frames) + 1]
end

local function stop_spinner()
  if timer then
    pcall(function()
      timer:stop()
    end)
    pcall(function()
      timer:close()
    end)
    timer = nil
  end
  current.spinner_frame = 0
end

local function clear_autocmds()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
end

local render_all

local function tick()
  if not any_valid_window() or not spinner_active() then
    stop_spinner()
    if any_valid_window() then
      render_all()
    end
    return false
  end
  local frames = settings.spinner_frames
  if type(frames) ~= "table" or #frames == 0 then
    stop_spinner()
    return false
  end
  current.spinner_frame = (current.spinner_frame % #frames) + 1
  render_all()
  return true
end

local function start_spinner()
  if timer or not any_valid_window() or not spinner_active() then
    return
  end
  if not (uv and uv.new_timer) then
    return
  end
  local interval = settings.spinner_interval
  if type(interval) ~= "number" or interval < 50 then
    interval = DEFAULTS.spinner_interval
  end
  local handle = uv.new_timer()
  if not handle then
    return
  end
  timer = handle
  local callback = vim.schedule_wrap(function()
    if timer ~= handle then
      return
    end
    tick()
  end)
  local started = pcall(handle.start, handle, interval, interval, callback)
  if not started then
    timer = nil
    pcall(handle.close, handle)
  end
end

local function render_target(target)
  local entry = windows[target]
  if not entry then
    return
  end
  if not window_valid(entry.window) then
    windows[target] = nil
    return
  end
  local text = M.render(current, target, {
    limits = settings.limits,
    spinner = spinner_text(),
    submit_hint = settings.submit_hint,
  })
  local ok = pcall(function()
    vim.wo[entry.window].winbar = text
  end)
  if not ok then
    windows[target] = nil
  end
end

render_all = function()
  render_target(MESSAGE)
  render_target(INPUT)
  if not any_valid_window() then
    stop_spinner()
  end
end

local function sync()
  if not any_valid_window() then
    stop_spinner()
    return
  end
  if spinner_active() then
    start_spinner()
  else
    stop_spinner()
  end
  render_all()
end

local function install_autocmds()
  clear_autocmds()
  if not any_valid_window() then
    return
  end
  augroup = vim.api.nvim_create_augroup(AUGROUP_NAME, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(args)
      local win = tonumber(args.match)
      if not win then
        return
      end
      local changed = false
      for target, entry in pairs(windows) do
        if entry.window == win then
          windows[target] = nil
          changed = true
        end
      end
      if changed and not any_valid_window() then
        stop_spinner()
      end
    end,
  })
end

local function normalize_options(options)
  if type(options) == "number" then
    return { generation = options }
  end
  if type(options) ~= "table" then
    return {}
  end
  return options
end

local function option_generation(options, partial)
  local value = first(options.generation, partial and partial.generation, partial and partial.gen)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    return tonumber(value)
  end
  return nil
end

local function current_session_id()
  return session_id_of(current.session)
end

local function reset_session_scope()
  current.session = nil
  current.project = nil
  current.agent = nil
  current.model = nil
  current.submission = nil
  current.execution = nil
  current.waiting_permission = nil
  current.error = nil
  current.retry = nil
  current.compaction = nil
  current.notified_submission = false
  current.notified_execution = false
end

local function error_text(value)
  if value == nil or value == false then
    return nil
  end
  if type(value) == "string" then
    return sanitize(value)
  end
  if type(value) ~= "table" then
    return nil
  end
  local message = first(value.message, value.msg, value.error, value.data and value.data.message)
  if type(message) == "table" then
    return error_text(message)
  end
  local code = first(value.code, value.name, value.type)
  local code_text = sanitize(code)
  local text = sanitize(message)
  if text and code_text then
    return text .. " (" .. code_text .. ")"
  end
  if text then
    return text
  end
  return code_text
end

local function notify_error(kind, detail)
  local message = kind
  local text = error_text(detail)
  if text then
    message = message .. ": " .. clip(text, 200)
  end
  pcall(function()
    vim.notify(message, vim.log.levels.ERROR)
  end)
end

local function notify_submission(previous, options)
  if current.submission == "failed" then
    if previous ~= "failed" or not current.notified_submission then
      if options.notify ~= false then
        notify_error("OpenCode submission failed", current.error)
      end
      current.notified_submission = true
    end
  else
    current.notified_submission = false
  end
end

local function notify_execution(previous, options)
  if current.execution == "failed" then
    if previous ~= "failed" or not current.notified_execution then
      if options.notify ~= false then
        notify_error("OpenCode execution failed", current.error)
      end
      current.notified_execution = true
    end
  else
    current.notified_execution = false
  end
end

local function collect_partial(snapshot)
  local partial = {}
  local function absorb(source)
    if type(source) ~= "table" then
      return
    end
    for key, value in pairs(source) do
      if key ~= "status" then
        if
          type(value) == "table"
          and type(partial[key]) == "table"
          and (key == "session" or key == "project" or key == "agent" or key == "model")
        then
          partial[key] = merge_table(partial[key], value)
        else
          partial[key] = value
        end
      end
    end
  end
  if type(snapshot.status) == "table" then
    absorb(snapshot.status)
  end
  absorb(snapshot)
  return partial
end

local function apply_state_field(field, value)
  if value == nil then
    return
  end
  if value == false then
    current[field] = nil
    return
  end
  local error_value = nil
  if type(value) == "table" then
    error_value = first(value.error, value.message)
    value = first(value.state, value.status, value.type, value.value)
  end
  current[field] = state_text(value)
  if error_value ~= nil then
    current.error = copy(error_value)
  end
end

local function apply_partial(partial)
  for _, key in ipairs({ "session", "project", "agent", "model" }) do
    local value = partial[key]
    if value ~= nil then
      if value == false then
        current[key] = nil
      else
        current[key] = merge_table(current[key], value)
      end
    end
  end
  if partial.session_id ~= nil then
    if partial.session_id == false then
      current.session = nil
    else
      current.session = merge_table(current.session, { id = partial.session_id })
    end
  end

  apply_state_field("connection", partial.connection)
  apply_state_field("submission", partial.submission)
  apply_state_field("execution", partial.execution)

  if partial.waiting_permission ~= nil then
    if partial.waiting_permission == false then
      current.waiting_permission = nil
    else
      current.waiting_permission = copy(partial.waiting_permission)
    end
  end
  if partial.error ~= nil then
    if partial.error == false then
      current.error = nil
    else
      current.error = copy(partial.error)
    end
  end
  if partial.retry ~= nil then
    current.retry = partial.retry == false and nil or copy(partial.retry)
  end
  if partial.compaction ~= nil then
    current.compaction = partial.compaction == false and nil or copy(partial.compaction)
  end
end

local function guard(options)
  local generation = option_generation(options, nil)
  if generation ~= nil and current.generation ~= nil and generation < current.generation then
    return false
  end
  local session_id = sanitize(options.session_id)
  local active = current_session_id()
  if session_id and active and session_id ~= active then
    return false
  end
  if generation ~= nil and (current.generation == nil or generation > current.generation) then
    current.generation = generation
  end
  return true
end

--- Attach the status display to the UI windows. Windows are owned by 03;
--- this module only writes their window-local 'winbar'. Passing nil for either
--- window is allowed, and re-attaching replaces previously attached windows.
---
--- @param options table|nil {
---   message_window, input_window, submit_hint, spinner_interval, limits
--- }
--- @return boolean
function M.attach(options)
  options = type(options) == "table" and options or {}
  M.detach()

  settings = new_settings()
  if type(options.spinner_interval) == "number" then
    settings.spinner_interval = options.spinner_interval
  end
  if type(options.spinner_frames) == "table" then
    local frames = {}
    for _, frame in ipairs(options.spinner_frames) do
      local text = sanitize(frame)
      if text then
        frames[#frames + 1] = text
      end
    end
    if #frames > 0 then
      settings.spinner_frames = frames
    end
  end
  settings.limits = merge_limits(options.limits)
  settings.submit_hint = sanitize(options.submit_hint)

  local function remember(target, win)
    if not window_valid(win) then
      return
    end
    local previous = ""
    pcall(function()
      previous = vim.wo[win].winbar
    end)
    windows[target] = { window = win, previous = previous }
  end

  remember(MESSAGE, options.message_window)
  remember(INPUT, options.input_window)
  install_autocmds()
  sync()
  return M.is_attached()
end

--- Merge a status snapshot. Absent dimensions keep their previous value, which
--- lets callers push partial updates without resetting unrelated fields. When
--- `snapshot.status` is present (a 05C change/snapshot), it is merged first and
--- top-level fields then override it.
---
--- Pass `generation` (or include it in the snapshot) to reject stale events.
--- A session id change is accepted only for a newer generation, an explicit
--- `switch = true`, or while no generation is known yet.
---
--- @param snapshot table|nil
--- @param options table|number|nil { generation, session_id, switch, notify }
--- @return boolean
function M.update(snapshot, options)
  if type(snapshot) ~= "table" then
    return false
  end
  options = normalize_options(options)
  local partial = collect_partial(snapshot)
  local generation = option_generation(options, partial)

  if generation ~= nil and current.generation ~= nil and generation < current.generation then
    return false
  end

  local incoming_session = session_id_of(partial.session) or sanitize(partial.session_id) or sanitize(options.session_id)
  local active_session = current_session_id()
  if incoming_session and active_session and incoming_session ~= active_session then
    local accepted = options.switch == true or partial.switch == true
    if not accepted and generation ~= nil then
      accepted = current.generation == nil or generation > current.generation
    elseif not accepted and generation == nil and current.generation == nil then
      accepted = true
    end
    if not accepted then
      return false
    end
    reset_session_scope()
  end

  local previous_submission = current.submission
  local previous_execution = current.execution
  apply_partial(partial)

  if generation ~= nil and (current.generation == nil or generation > current.generation) then
    current.generation = generation
  end

  notify_submission(previous_submission, options)
  notify_execution(previous_execution, options)
  sync()
  return true
end

--- Update only the connection dimension.
--- @param value string|table|nil
--- @param options table|number|nil
--- @return boolean
function M.set_connection(value, options)
  options = normalize_options(options)
  if not guard(options) then
    return false
  end
  apply_state_field("connection", value)
  sync()
  return true
end

--- Update only the submission dimension. The optional error is kept for the
--- failure notification; it is not rendered in the winbar.
--- @param value string|table|nil
--- @param options table|number|nil { error, generation, session_id, notify }
--- @return boolean
function M.set_submission(value, options)
  options = normalize_options(options)
  if not guard(options) then
    return false
  end
  local previous = current.submission
  local error_value = options.error
  if type(value) == "table" then
    error_value = first(error_value, value.error, value.message)
  end
  apply_state_field("submission", value)
  if error_value ~= nil then
    current.error = copy(error_value)
  end
  notify_submission(previous, options)
  sync()
  return true
end

--- Update only the execution dimension.
--- @param value string|table|nil
--- @param options table|number|nil { error, generation, session_id, notify }
--- @return boolean
function M.set_execution(value, options)
  options = normalize_options(options)
  if not guard(options) then
    return false
  end
  local previous = current.execution
  local error_value = options.error
  if type(value) == "table" then
    error_value = first(error_value, value.error, value.message)
  end
  apply_state_field("execution", value)
  if error_value ~= nil then
    current.error = copy(error_value)
  end
  notify_execution(previous, options)
  sync()
  return true
end

--- Stop rendering, restore every attached window's previous local winbar and
--- stop the spinner. State is retained so a later attach() immediately shows
--- the latest status again. Pass `{ reset = true }` to drop state as well.
--- @param options table|nil
function M.detach(options)
  options = type(options) == "table" and options or {}
  for _, entry in pairs(windows) do
    if window_valid(entry.window) then
      pcall(function()
        vim.wo[entry.window].winbar = entry.previous or ""
      end)
    end
  end
  windows = {}
  stop_spinner()
  clear_autocmds()
  if options.reset then
    current = new_state()
    settings = new_settings()
  end
end

--- Drop all state and detach. Primarily useful for tests and full teardown.
function M.reset()
  M.detach({ reset = true })
end

--- @return boolean
function M.is_attached()
  return any_valid_window()
end

--- @return boolean
function M.is_spinning()
  return timer ~= nil
end

--- Advance the spinner once. Exposed for deterministic headless tests; the
--- regular UI path uses the low-frequency timer.
--- @return boolean
function M._tick()
  return tick()
end

--- @return table
function M.get_state()
  return copy(current)
end

return M
