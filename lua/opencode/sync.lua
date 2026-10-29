-- Race-free history/SSE synchronizer for one OpenCode session.
--
-- The synchronizer subscribes to the event stream first, buffers every native
-- event that arrives, then requests the session history.  Only after the
-- history request succeeds does it release the first batch:
--
--   {
--     generation = 1,
--     snapshot = {
--       messages = { ... },       -- history entries from list_messages
--       location = { ... },       -- target location when configured
--       session_id = "ses_...",
--     },
--     events = {
--       { id = "...", sequence = "...", type = "...", data = {} },
--     },
--   }
--
-- Later batches have the same shape without `snapshot`:
--
--   { generation = 1, events = { ... } }
--
-- History responses may be a direct message array, { messages = ... },
-- { message = ... } or the 02B client's { data = ..., cursor = ... } shape;
-- all are exposed as snapshot.messages.  Other history fields are preserved.
--
-- Events are in arrival order.  `sequence` is only present when the native
-- payload carried one; this module never invents a global sequence.  Event
-- de-duplication and block projection belong to 05C.
--
-- Public API:
--
--   local syncer, err = sync.new({
--     client = client,              -- needs list_messages/stream_events
--     session_id = "ses_...",
--     location = { directory = root }, -- optional, string or table
--     types = nil,                  -- optional stream filter
--     backoff = { initial = 100, factor = 2, max = 5000 }, -- optional
--     schedule = function(fn, delay) return cancel end,   -- optional
--     on_batch = function(batch) end,
--     on_error = function(err) end,
--     on_connection = function(state, generation) end,    -- optional
--   })
--   local ok, generation = syncer:start()
--   syncer:stop()   -- idempotent; also available as syncer:cancel()
--   syncer:get_state()
--
--   local syncer, err = sync.start(options) -- new + start
--
-- `client.list_messages(session_id, callback)` must call
-- `callback(err, response)` at most meaningfully once.  `client.stream_events`
-- uses the 02A handler convention (`on_headers`, `on_chunk`, `on_done`) and
-- may return a cancel function (or a table with a `cancel` method).
--
-- Errors passed to `on_error` are `{ code, message, phase, generation,
-- cause?, raw? }` with phase "parse", "stream" or "history".  Configuration
-- errors are returned directly from start().  No UI or buffer is touched.
--
-- server.connected is forwarded as a native event.  The first one on each
-- stream confirms the connection; a later one on an already live stream means
-- the server restarted its event stream, so a fresh generation and history
-- snapshot are requested without opening a second subscription.

local events = require("opencode.events")

local M = {}

local DEFAULT_BACKOFF = {
  initial = 100,
  factor = 2,
  max = 5000,
}

local Syncer = {}
Syncer.__index = Syncer

local function err(code, message, extra)
  local out = { code = code, message = message }
  for key, value in pairs(extra or {}) do
    out[key] = value
  end
  return out
end

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

local function normalize_error(value, fallback_code, fallback_message)
  if type(value) == "table" then
    local out = {
      code = value.code or fallback_code,
      message = value.message or fallback_message or tostring(value),
    }
    if value.cause ~= nil then
      out.cause = value.cause
    else
      out.cause = value
    end
    return out
  end
  return {
    code = fallback_code,
    message = value ~= nil and tostring(value) or (fallback_message or fallback_code),
  }
end

local function cancel_handle(handle)
  if type(handle) == "function" then
    pcall(handle)
  elseif type(handle) == "table" then
    if type(handle.cancel) == "function" then
      pcall(handle.cancel, handle)
    elseif type(handle.stop) == "function" then
      pcall(handle.stop, handle)
      local closing = false
      if type(handle.is_closing) == "function" then
        local ok, result = pcall(handle.is_closing, handle)
        closing = ok and result
      end
      if type(handle.close) == "function" and not closing then
        pcall(handle.close, handle)
      end
    end
  end
end

local function default_schedule(fn, delay)
  local timer = vim.defer_fn(fn, delay)
  return function()
    if timer and not timer:is_closing() then
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
    end
  end
end

local function trim_path(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local trimmed = value:gsub("/+$", "")
  if trimmed == "" then
    trimmed = "/"
  end
  return trimmed
end

local function location_path(value)
  if type(value) == "string" then
    return trim_path(value)
  end
  if type(value) ~= "table" then
    return nil
  end
  local direct = trim_path(first(
    value.directory,
    value.path,
    value.root,
    value.cwd,
    value.workspace
  ))
  if direct then
    return direct
  end
  if type(value.project) == "table" then
    return location_path(value.project)
  end
  if type(value.location) == "table" then
    return location_path(value.location)
  end
  return nil
end

local function session_of(event, data)
  local session = first(
    event.session_id,
    event.sessionID,
    data.session_id,
    data.sessionID
  )
  if session == nil then
    local nested = data.session
    if type(nested) == "table" then
      session = first(nested.id, nested.sessionID, nested.session_id)
    elseif type(nested) == "string" then
      session = nested
    end
  end
  if session == nil and type(data.part) == "table" then
    session = first(data.part.sessionID, data.part.session_id)
  end
  if session == nil and type(data.message) == "table" then
    session = first(data.message.sessionID, data.message.session_id)
  end
  if session == nil and type(data.info) == "table" then
    session = first(data.info.sessionID, data.info.session_id)
    if session == nil and type(event.type) == "string" and event.type:match("^session%.") then
      session = first(data.info.id, data.info.sessionID)
    end
  end
  return session
end

local function event_location(event, data)
  local location = first(data.location, event.location)
  local path = location_path(location)
  if path then
    return path
  end
  path = location_path(data.directory) or location_path(data.cwd)
  if path then
    return path
  end
  if type(data.project) == "table" then
    path = location_path(data.project)
    if path then
      return path
    end
  end
  if type(data.info) == "table" then
    return location_path(data.info.location)
      or location_path(data.info.directory)
      or location_path(data.info.project)
  end
  return nil
end

local function normalize_snapshot(response, session_id, target_location)
  if type(response) ~= "table" then
    return nil, err("invalid_history_response", "history response must be a table")
  end

  local snapshot
  if response[1] ~= nil then
    snapshot = { messages = response }
  elseif type(response.messages) == "table" then
    snapshot = response
  elseif type(response.message) == "table" then
    snapshot = copy(response)
    snapshot.messages = response.message
  elseif type(response.data) == "table" then
    snapshot = copy(response)
    snapshot.messages = response.data
  elseif next(response) == nil then
    snapshot = { messages = {} }
  else
    return nil, err("invalid_history_response", "history response has no messages")
  end

  local out = copy(snapshot)
  if type(out.messages) ~= "table" then
    return nil, err("invalid_history_response", "history messages must be a table")
  end
  out.session_id = session_id
  if target_location ~= nil then
    out.location = copy(target_location)
  end
  return out
end

local function validate_options(self)
  if type(self.client) ~= "table" then
    return nil, err("invalid_config", "sync.client must be a table")
  end
  if type(self.client.list_messages) ~= "function" then
    return nil, err("invalid_config", "sync.client.list_messages must be a function")
  end
  if type(self.client.stream_events) ~= "function" then
    return nil, err("invalid_config", "sync.client.stream_events must be a function")
  end
  if type(self.session_id) ~= "string" or self.session_id == "" then
    return nil, err("invalid_config", "sync.session_id must be a non-empty string")
  end
  for _, name in ipairs({ "on_batch", "on_error", "on_connection" }) do
    local value = self[name]
    if value ~= nil and type(value) ~= "function" then
      return nil, err("invalid_config", "sync." .. name .. " must be a function")
    end
  end
  if self.types ~= nil and type(self.types) ~= "string" and type(self.types) ~= "table" then
    return nil, err("invalid_config", "sync.types must be a string or list of strings")
  end
  if type(self.types) == "table" then
    for _, value in ipairs(self.types) do
      if type(value) ~= "string" or value == "" then
        return nil, err("invalid_config", "sync.types entries must be non-empty strings")
      end
    end
  end
  if type(self.backoff.initial) ~= "number" or self.backoff.initial <= 0 then
    return nil, err("invalid_config", "sync.backoff.initial must be a positive number")
  end
  if type(self.backoff.factor) ~= "number" or self.backoff.factor < 1 then
    return nil, err("invalid_config", "sync.backoff.factor must be >= 1")
  end
  if type(self.backoff.max) ~= "number" or self.backoff.max < self.backoff.initial then
    return nil, err("invalid_config", "sync.backoff.max must be >= initial")
  end
  return true
end

function M.new(options)
  if options ~= nil and type(options) ~= "table" then
    return nil, err("invalid_config", "sync options must be a table")
  end
  options = options or {}
  if options.backoff ~= nil and type(options.backoff) ~= "table" then
    return nil, err("invalid_config", "sync.backoff must be a table")
  end
  if options.schedule ~= nil and type(options.schedule) ~= "function" then
    return nil, err("invalid_config", "sync.schedule must be a function")
  end
  local backoff = {
    initial = DEFAULT_BACKOFF.initial,
    factor = DEFAULT_BACKOFF.factor,
    max = DEFAULT_BACKOFF.max,
  }
  for key, value in pairs(options.backoff or {}) do
    backoff[key] = value
  end

  local self = setmetatable({
    client = options.client,
    session_id = options.session_id,
    location = copy(options.location),
    types = copy(options.types),
    on_batch = options.on_batch,
    on_error = options.on_error,
    on_connection = options.on_connection,
    backoff = backoff,
    schedule = options.schedule or default_schedule,
    parser = events.new(),

    started = false,
    stopped = false,
    phase = "idle",
    generation = 0,
    buffer = nil,

    stream_serial = 0,
    stream_cancel = nil,
    stream_alive = false,
    stream_seen_connected = false,

    history_token = 0,
    history_cancel = nil,
    history_pending = false,

    reconnect_attempt = 0,
    history_attempt = 0,
    retry = nil,
    retry_kind = nil,

    subscription_count = 0,
    history_count = 0,
  }, Syncer)
  return self
end

function Syncer:_report(phase, value, generation)
  if type(self.on_error) ~= "function" then
    return
  end
  local report = normalize_error(value, phase .. "_failed", phase .. " failed")
  report.phase = phase
  report.generation = generation or self.generation
  self.on_error(report)
end

function Syncer:_connection(state)
  if type(self.on_connection) == "function" then
    self.on_connection(state, self.generation)
  end
end

function Syncer:_mark_alive()
  if self.stream_alive then
    return
  end
  self.stream_alive = true
  self.reconnect_attempt = 0
  self:_connection("connected")
end

function Syncer:_cancel_timer()
  local cancel = self.retry
  self.retry = nil
  self.retry_kind = nil
  if cancel then
    cancel_handle(cancel)
  end
end

function Syncer:_invalidate_history()
  self.history_token = self.history_token + 1
  self.history_pending = false
  local cancel = self.history_cancel
  self.history_cancel = nil
  if cancel then
    cancel_handle(cancel)
  end
end

function Syncer:_schedule(kind, delay, fn)
  if self.stopped or self.retry then
    return false
  end
  self.retry_kind = kind
  local ok, cancel = pcall(self.schedule, function()
    if self.stopped then
      return
    end
    self.retry = nil
    self.retry_kind = nil
    fn()
  end, delay)
  if not ok then
    self.retry = nil
    self.retry_kind = nil
    self:_report(kind, err("scheduler_failed", "could not schedule " .. kind .. " retry: " .. tostring(cancel)))
    return false
  end
  self.retry = cancel or true
  return true
end

function Syncer:_delay(attempt)
  local delay = self.backoff.initial * self.backoff.factor ^ (attempt - 1)
  if delay > self.backoff.max then
    delay = self.backoff.max
  end
  return math.floor(delay + 0.5)
end

function Syncer:_emit(batch)
  if self.stopped or batch.generation ~= self.generation then
    return
  end
  if type(self.on_batch) == "function" then
    self.on_batch(batch)
  end
end

function Syncer:_open_stream(generation)
  self.stream_serial = self.stream_serial + 1
  local serial = self.stream_serial
  self.stream_alive = false
  self.stream_seen_connected = false
  self.subscription_count = self.subscription_count + 1

  local handlers = {
    on_headers = function(response)
      self:_on_headers(serial, response)
    end,
    on_chunk = function(chunk)
      self:_on_chunk(serial, chunk)
    end,
    on_done = function(done_err)
      self:_on_stream_done(serial, done_err)
    end,
    on_error = function(stream_err)
      self:_on_stream_done(serial, stream_err)
    end,
  }

  local ok, cancel, start_err = pcall(self.client.stream_events, { types = self.types }, handlers)
  if not ok then
    self:_on_stream_done(serial, err("stream_failed", "could not start event stream: " .. tostring(cancel)))
    return false
  end
  if cancel == nil and start_err ~= nil then
    self:_on_stream_done(serial, start_err)
    return false
  end
  if serial ~= self.stream_serial or self.stopped then
    cancel_handle(cancel)
    return false
  end
  if generation ~= self.generation then
    cancel_handle(cancel)
    return false
  end
  self.stream_cancel = cancel
  return true
end

function Syncer:_on_headers(serial, response)
  if self.stopped or serial ~= self.stream_serial then
    return
  end
  local status = type(response) == "table" and response.status or nil
  if type(status) == "number" and (status < 200 or status >= 300) then
    return
  end
  self:_mark_alive()
end

function Syncer:_accept(event)
  local data = type(event.data) == "table" and event.data or {}
  local session = session_of(event, data)
  if session ~= nil and tostring(session) ~= self.session_id then
    return false
  end
  local target = location_path(self.location)
  if target ~= nil then
    local actual = event_location(event, data)
    if actual ~= nil and actual ~= target then
      return false
    end
  end
  return true
end

function Syncer:_control(event)
  if event.type ~= "server.connected" then
    return false
  end
  self:_mark_alive()
  local seen = self.stream_seen_connected
  self.stream_seen_connected = true
  if self.phase == "live" and seen then
    return true
  end
  return false
end

function Syncer:_begin_resync()
  self.generation = self.generation + 1
  self.phase = "syncing"
  self.buffer = {}
  self.history_attempt = 0
  self:_cancel_timer()
  self:_invalidate_history()
  self:_request_history(self.generation)
end

function Syncer:_on_chunk(serial, chunk)
  if self.stopped or serial ~= self.stream_serial then
    return
  end
  self:_mark_alive()
  if self.stopped then
    return
  end

  local parsed, parse_errors = self.parser:feed(chunk)
  for _, parse_err in ipairs(parse_errors) do
    self:_report("parse", parse_err)
    if self.stopped then
      return
    end
  end
  if #parsed == 0 then
    return
  end

  local batch = {}
  local batch_generation = self.generation
  local function flush()
    if #batch > 0 and batch_generation == self.generation then
      self:_emit({ generation = batch_generation, events = batch })
    end
    batch = {}
    batch_generation = self.generation
  end

  for _, event in ipairs(parsed) do
    if self.stopped then
      return
    end
    local resync = self:_control(event)
    if self.stopped then
      return
    end
    if resync then
      -- Finish the old generation before opening the new sync window.
      flush()
      self:_begin_resync()
      if self.stopped then
        return
      end
    end
    if self:_accept(event) then
      if self.phase == "syncing" then
        self.buffer[#self.buffer + 1] = event
      elseif self.phase == "live" then
        if batch_generation ~= self.generation then
          flush()
        end
        batch[#batch + 1] = event
      end
    end
  end
  flush()
end

function Syncer:_schedule_history_retry(generation)
  if self.stopped or generation ~= self.generation or self.phase ~= "syncing" then
    return
  end
  if self.retry then
    return
  end
  self.history_attempt = self.history_attempt + 1
  local delay = self:_delay(self.history_attempt)
  self:_schedule("history", delay, function()
    if self.stopped or generation ~= self.generation or self.phase ~= "syncing" then
      return
    end
    self:_request_history(generation)
  end)
end

function Syncer:_request_history(generation)
  if self.stopped or generation ~= self.generation then
    return
  end
  self.history_count = self.history_count + 1
  self.history_token = self.history_token + 1
  local token = self.history_token
  local finished = false
  self.history_pending = true

  local function callback(history_err, response)
    if finished then
      return
    end
    finished = true
    if self.stopped or token ~= self.history_token or generation ~= self.generation then
      return
    end
    self.history_pending = false
    self.history_cancel = nil

    if history_err ~= nil then
      self:_report("history", history_err, generation)
      if not self.stopped then
        self:_schedule_history_retry(generation)
      end
      return
    end

    local snapshot, snapshot_err = normalize_snapshot(response, self.session_id, self.location)
    if not snapshot then
      self:_report("history", snapshot_err, generation)
      if not self.stopped then
        self:_schedule_history_retry(generation)
      end
      return
    end

    self.history_attempt = 0
    self.phase = "live"
    local buffered = self.buffer or {}
    self.buffer = nil
    self:_connection("synced")
    self:_emit({
      generation = generation,
      snapshot = snapshot,
      events = buffered,
    })
  end

  local ok, cancel = pcall(self.client.list_messages, self.session_id, callback)
  if not ok then
    callback(err("history_failed", "could not request history: " .. tostring(cancel)))
    return
  end
  if finished then
    -- A synchronous success/error needs no cancellation.
    return
  end
  if self.stopped or token ~= self.history_token or generation ~= self.generation then
    cancel_handle(cancel)
    return
  end
  self.history_cancel = cancel
end

function Syncer:_schedule_reconnect()
  if self.stopped or self.retry then
    return
  end
  self.reconnect_attempt = self.reconnect_attempt + 1
  local delay = self:_delay(self.reconnect_attempt)
  self:_schedule("stream", delay, function()
    self:_start_generation(true)
  end)
end

function Syncer:_on_stream_done(serial, stream_err)
  if self.stopped or serial ~= self.stream_serial then
    return
  end
  -- Invalidate this subscription so late chunks and duplicate done callbacks
  -- from the same stream are ignored.
  self.stream_serial = self.stream_serial + 1
  local cancel = self.stream_cancel
  self.stream_cancel = nil
  if cancel then
    cancel_handle(cancel)
  end
  self.stream_alive = false
  self:_cancel_timer()
  self:_invalidate_history()
  self.buffer = nil
  self.parser:reset()
  self.phase = "reconnecting"

  if stream_err ~= nil then
    self:_report("stream", stream_err)
  else
    self:_report("stream", err("stream_closed", "event stream closed"))
  end
  self:_connection("disconnected")
  if self.stopped then
    return
  end
  self:_schedule_reconnect()
end

function Syncer:_start_generation(new_stream)
  self.generation = self.generation + 1
  local generation = self.generation
  self.phase = "syncing"
  self.buffer = {}
  self.history_attempt = 0
  if new_stream then
    self.parser:reset()
    local opened = self:_open_stream(generation)
    if not opened or self.stopped or generation ~= self.generation then
      return generation
    end
  end
  self:_request_history(generation)
  return generation
end

---Start the synchronizer.  Calling start while already running is a no-op
---and never creates a second subscription.
---@return boolean|nil ok
---@return number|table generation_or_error
function Syncer:start()
  if self.started then
    return true, self.generation
  end
  local ok, validation_err = validate_options(self)
  if not ok then
    return nil, validation_err
  end
  self.started = true
  self.stopped = false
  self.phase = "idle"
  self.reconnect_attempt = 0
  self.history_attempt = 0
  self:_start_generation(true)
  return true, self.generation
end

---Stop the synchronizer.  Idempotent: cancels the stream, any pending
---history request/retry timer, invalidates the current generation and ignores
---all late callbacks/chunks.
---@return boolean
function Syncer:stop()
  if not self.started and self.stopped then
    return true
  end
  local was_started = self.started
  self.started = false
  self.stopped = true
  self.phase = "stopped"
  self.generation = self.generation + 1

  self:_cancel_timer()
  self:_invalidate_history()
  self.stream_serial = self.stream_serial + 1
  local cancel = self.stream_cancel
  self.stream_cancel = nil
  if cancel then
    cancel_handle(cancel)
  end
  self.stream_alive = false
  self.buffer = nil
  self.parser:reset()
  if was_started then
    self:_connection("disconnected")
  end
  return true
end

Syncer.cancel = Syncer.stop

---Diagnostics only; callers should not depend on blocks/UI state here.
---@return table
function Syncer:get_state()
  return {
    started = self.started,
    stopped = self.stopped,
    phase = self.phase,
    generation = self.generation,
    buffered = self.buffer and #self.buffer or 0,
    connected = self.stream_alive,
    subscriptions = self.subscription_count,
    history_requests = self.history_count,
    history_pending = self.history_pending,
    retry_kind = self.retry_kind,
  }
end

---Convenience: create and start in one call.
---@param options table
---@return table|nil syncer
---@return table|nil err
function M.start(options)
  local syncer, new_err = M.new(options)
  if not syncer then
    return nil, new_err
  end
  local ok, start_result = syncer:start()
  if not ok then
    return nil, start_result
  end
  return syncer, nil
end

return M
