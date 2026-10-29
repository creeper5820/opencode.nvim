-- Incremental Server-Sent Events parser for OpenCode event streams.
--
-- This module only turns raw SSE bytes into native event tables.  It never
-- performs I/O, orders events globally, builds blocks or touches UI state.
--
-- Public API:
--
--   local parser = events.new()
--   local parsed, errors = parser:feed(chunk) -- any byte boundary
--   local parsed, errors = parser:finish()    -- discard incomplete tail
--   parser:reset()                            -- start of a new stream
--   parser.last_event_id                      -- last SSE id seen
--
--   local parsed, errors = events.parse(text) -- whole complete stream text
--
-- Parsed event:
--
--   {
--     id = "<SSE id>",          -- only when this event declared an id
--     sequence = <native>,      -- only when the payload carried one
--     type = "<event type>",
--     data = { ... },           -- v1 envelopes expose their properties
--   }
--
-- The SSE `id` field is attached only to the event block that declared it.
-- `parser.last_event_id` keeps the stream's last id for callers that need
-- resumption, but inherited ids are not copied onto later events: those ids
-- are event-stream cursors, not stable per-event identities, and 05C uses
-- event ids for de-duplication.
--
-- A decoded OpenCode v1 envelope `{ type, properties }` exposes `properties`
-- as `data`, so downstream consumers read native fields directly.  The
-- optional native event id/sequence on the envelope are preserved.
--
-- Invalid payloads are reported as recoverable errors and skipped; later
-- complete events in the same chunk are still delivered.  Errors:
--
--   { code = "invalid_event_data" | "invalid_event_payload",
--     message = "<display text>", raw = "<raw data field>" }

local M = {}

local Parser = {}
Parser.__index = Parser

local function parse_error(code, message, raw)
  return { code = code, message = message, raw = raw }
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

local function is_event_id(value)
  return type(value) == "string" or type(value) == "number"
end

local function is_array(value)
  for key in pairs(value) do
    if type(key) == "number" then
      return true
    end
  end
  return false
end

local function native_sequence(decoded)
  local durable = decoded.durable
  return first(
    decoded.sequence,
    decoded.seq,
    type(durable) == "table" and durable.seq or nil
  )
end

---Build a parser.  `opts.on_error` is accepted for callers that prefer a
---callback, but `feed`/`finish` always return the errors as well.
---@param opts table|nil
---@return table
function M.new(opts)
  if type(opts) ~= "table" then
    opts = {}
  end
  return setmetatable({
    buffer = "",
    data_lines = {},
    event_type = nil,
    event_id = nil,
    id_declared = false,
    last_event_id = nil,
    retry = nil,
    at_start = true,
    on_error = type(opts.on_error) == "function" and opts.on_error or nil,
  }, Parser)
end

---Reset all parser state for a fresh stream.
function Parser:reset()
  self.buffer = ""
  self.data_lines = {}
  self.event_type = nil
  self.event_id = nil
  self.id_declared = false
  self.last_event_id = nil
  self.retry = nil
  self.at_start = true
end

local function dispatch(self)
  local raw = table.concat(self.data_lines, "\n")
  local explicit_type = self.event_type
  local explicit_id = self.id_declared and self.event_id or nil

  -- A blank line always terminates the current block.
  self.data_lines = {}
  self.event_type = nil
  self.event_id = nil
  self.id_declared = false

  -- SSE: blocks without data fields are not dispatched.
  if raw == "" then
    return nil, nil
  end

  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok then
    return nil, parse_error("invalid_event_data", "invalid SSE JSON payload: " .. tostring(decoded), raw)
  end
  if type(decoded) ~= "table" or is_array(decoded) then
    return nil, parse_error("invalid_event_payload", "SSE event payload must be a JSON object", raw)
  end

  local envelope = type(decoded.properties) == "table"
  local data = envelope and decoded.properties or decoded
  local event_type = explicit_type
  if event_type == nil or event_type == "" or event_type == "message" then
    if type(decoded.type) == "string" and decoded.type ~= "" then
      event_type = decoded.type
    else
      event_type = explicit_type or "message"
    end
  end

  local event = {
    type = event_type,
    data = data,
  }
  local id = explicit_id
  if id == nil and envelope then
    -- Envelope ids identify the event; ids inside properties belong to a
    -- message/part/permission and stay in data.
    id = first(decoded.id, decoded.event_id, decoded.eventID)
    if is_event_id(id) then
      id = tostring(id)
    else
      id = nil
    end
  end
  if id ~= nil and id ~= "" then
    event.id = id
  end
  local sequence = native_sequence(decoded)
  if sequence ~= nil then
    event.sequence = sequence
  end
  return event, nil
end

function Parser:_consume_line(line, events, errors)
  if line == "" then
    local event, err = dispatch(self)
    if event then
      events[#events + 1] = event
    end
    if err then
      errors[#errors + 1] = err
      if self.on_error then
        self.on_error(err)
      end
    end
    return
  end

  -- Comment line.
  if line:sub(1, 1) == ":" then
    return
  end

  local colon = line:find(":", 1, true)
  local field, value
  if colon then
    field = line:sub(1, colon - 1)
    value = line:sub(colon + 1)
    if value:sub(1, 1) == " " then
      value = value:sub(2)
    end
  else
    field = line
    value = ""
  end

  if field == "data" then
    self.data_lines[#self.data_lines + 1] = value
  elseif field == "event" then
    self.event_type = value ~= "" and value or nil
  elseif field == "id" then
    if not value:find("\0", 1, true) then
      self.event_id = value
      self.id_declared = true
      self.last_event_id = value
    end
  elseif field == "retry" then
    local retry = tonumber(value)
    if retry and retry >= 0 then
      self.retry = retry
    end
  end
  -- Unknown fields are ignored, as required by SSE.
end

---Feed one arbitrary byte chunk.
---@param chunk string|nil
---@return table events
---@return table errors
function Parser:feed(chunk)
  local events = {}
  local errors = {}
  if type(chunk) ~= "string" or chunk == "" then
    return events, errors
  end

  if self.at_start then
    self.at_start = false
    if chunk:sub(1, 3) == "\239\187\191" then
      chunk = chunk:sub(4)
    end
  end

  self.buffer = self.buffer .. chunk

  local start = 1
  while true do
    local cr = self.buffer:find("\r", start, true)
    local lf = self.buffer:find("\n", start, true)
    local index
    if cr and lf then
      index = math.min(cr, lf)
    else
      index = cr or lf
    end
    if not index then
      break
    end

    local terminator = self.buffer:sub(index, index)
    -- A trailing CR may be the first half of a CRLF split across chunks.
    if terminator == "\r" and index == #self.buffer then
      break
    end

    local line = self.buffer:sub(start, index - 1)
    local skip = 1
    if terminator == "\r" and self.buffer:sub(index + 1, index + 1) == "\n" then
      skip = 2
    end
    start = index + skip
    self:_consume_line(line, events, errors)
  end

  self.buffer = self.buffer:sub(start)
  return events, errors
end

---Finish the current stream.  A trailing bare CR is a complete line ending at
---EOF, so a final blank CR line can still dispatch its event.  Any other
---incomplete trailing event is discarded, as required by SSE; callers
---reconnect or request a fresh history snapshot instead of releasing a
---partial block.
---@return table events
---@return table errors
function Parser:finish()
  local events = {}
  local errors = {}
  if self.buffer:sub(-1) == "\r" then
    self:_consume_line(self.buffer:sub(1, -2), events, errors)
  end
  self.buffer = ""
  self.data_lines = {}
  self.event_type = nil
  self.event_id = nil
  self.id_declared = false
  return events, errors
end

---Parse a complete SSE text.  Incomplete trailing data is discarded.
---@param text string
---@return table events
---@return table errors
function M.parse(text)
  local parser = M.new()
  local events, errors = parser:feed(text)
  local tail, tail_errors = parser:finish()
  for _, event in ipairs(tail) do
    events[#events + 1] = event
  end
  for _, err in ipairs(tail_errors) do
    errors[#errors + 1] = err
  end
  return events, errors
end

return M
