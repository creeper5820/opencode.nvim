-- Incremental HTTP/1.x response parser.
--
-- This module is transport independent.  `feed` accepts arbitrary byte
-- fragments and returns a list of events:
--
--   { type = "headers", response = { status, status_text, headers, http_version } }
--   { type = "chunk", data = "<body bytes>" }
--   { type = "complete" }
--
-- On a protocol error `feed`/`finish` return nil plus `{ code, message }`.
-- Once an error or completion has been reported the parser ignores further
-- input.  Callers must not inspect parser internals.

local M = {}

local MAX_HEADER_BYTES = 64 * 1024

local function protocol_error(code, message)
  return { code = code, message = message }
end

local function trim_ows(value)
  return (value:gsub("^[ \t]+", ""):gsub("[ \t]+$", ""))
end

local function lower(value)
  return value:lower()
end

local Parser = {}
Parser.__index = Parser

---@param opts table|nil
---  head_request: boolean  response to HEAD has no body
---  max_header_bytes: number|nil
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    buf = "",
    state = "status_line",
    head_request = opts.head_request == true,
    max_header_bytes = opts.max_header_bytes or MAX_HEADER_BYTES,
    header_bytes = 0,
    headers = nil,
    status = nil,
    status_text = nil,
    http_version = nil,
    body_mode = nil,
    content_length = nil,
    body_received = 0,
    chunk_remaining = 0,
    done = false,
    failed = false,
    events = nil,
  }, Parser)
end

function Parser:_emit(event)
  self.events[#self.events + 1] = event
end

function Parser:_fail(code, message)
  self.failed = true
  self.state = "failed"
  return nil, protocol_error(code, message)
end

-- Extract one line from the front of the buffer.  Returns nil when more data
-- is needed.  LF and CRLF are both accepted for resilience.
function Parser:_take_line()
  local crlf = self.buf:find("\r\n", 1, true)
  local lf = self.buf:find("\n", 1, true)
  local pos
  if crlf and (not lf or crlf <= lf) then
    pos = crlf
    local line = self.buf:sub(1, pos - 1)
    self.buf = self.buf:sub(pos + 2)
    return line
  elseif lf then
    local line = self.buf:sub(1, lf - 1)
    self.buf = self.buf:sub(lf + 1)
    return line
  end
  return nil
end

function Parser:_parse_status(line)
  local major, minor, status, text = line:match("^HTTP/(%d)%.(%d)[ \t]+(%d%d%d)[ \t]*(.*)$")
  if not major then
    return self:_fail("invalid_status_line", "invalid HTTP status line")
  end
  status = tonumber(status)
  if status < 100 or status > 599 then
    return self:_fail("invalid_status_line", "invalid HTTP status code")
  end
  if tonumber(major) > 1 then
    return self:_fail("unsupported_http_version", "unsupported HTTP version")
  end
  self.status = status
  self.status_text = text
  self.http_version = major .. "." .. minor
  self.headers = {}
  self.state = "headers"
  return true
end

function Parser:_parse_header(line)
  if line == "" then
    return "done"
  end
  if line:match("^[ \t]") then
    return self:_fail("invalid_header", "obsolete header folding is not supported")
  end
  local name, value = line:match("^([^:]+):(.*)$")
  if not name or not name:match("^[!#$%%&'*+.^_`|~%w%-]+$") then
    return self:_fail("invalid_header", "invalid HTTP header line")
  end
  name = lower(name)
  value = trim_ows(value)
  local existing = self.headers[name]
  if existing == nil then
    self.headers[name] = value
  elseif name == "content-length" then
    if existing ~= value then
      return self:_fail("invalid_content_length", "conflicting Content-Length headers")
    end
  elseif name == "transfer-encoding" then
    self.headers[name] = existing .. ", " .. value
  else
    self.headers[name] = existing .. ", " .. value
  end
  return true
end

function Parser:_determine_body_mode()
  local status = self.status
  local te = self.headers["transfer-encoding"]
  local cl = self.headers["content-length"]

  if self.head_request or status == 204 or status == 304 then
    self.body_mode = "none"
    return true
  end

  if te then
    local has_chunked = false
    local tokens = {}
    for part in te:gmatch("[^,]+") do
      local token = lower(trim_ows(part))
      if token ~= "" then
        tokens[#tokens + 1] = token
      end
    end
    if #tokens > 0 and tokens[#tokens] == "chunked" then
      has_chunked = true
    end
    if not has_chunked then
      return self:_fail("unsupported_transfer_encoding", "unsupported transfer encoding")
    end
    if #tokens > 1 then
      return self:_fail("unsupported_transfer_encoding", "transfer codings before chunked are not supported")
    end
    self.body_mode = "chunked"
    self.state = "chunk_size"
    return true
  end

  if cl ~= nil then
    if not cl:match("^%d+$") then
      return self:_fail("invalid_content_length", "invalid Content-Length")
    end
    local length = tonumber(cl)
    if not length or length > 9007199254740991 then
      return self:_fail("invalid_content_length", "Content-Length is too large")
    end
    self.content_length = length
    self.body_mode = "length"
    self.state = "body_length"
    return true
  end

  -- No framing headers: the response body runs until the connection closes.
  self.body_mode = "close"
  self.state = "body_close"
  return true
end

function Parser:_headers_complete()
  -- Informational responses (excluding 101) are skipped until the final
  -- response.  101 switching protocols is not supported by this transport.
  if self.status >= 100 and self.status < 200 then
    if self.status == 101 then
      return self:_fail("unsupported_response", "protocol upgrades are not supported")
    end
    self.state = "status_line"
    self.headers = nil
    self.status = nil
    self.status_text = nil
    self.http_version = nil
    self.header_bytes = 0
    return true
  end

  local ok, err = self:_determine_body_mode()
  if not ok then
    return nil, err
  end

  self:_emit({
    type = "headers",
    response = {
      status = self.status,
      status_text = self.status_text,
      headers = self.headers,
      http_version = self.http_version,
    },
  })

  if self.body_mode == "none" or (self.body_mode == "length" and self.content_length == 0) then
    self:_emit({ type = "complete" })
    self.done = true
    self.state = "done"
  end
  return true
end

function Parser:_handle_headers()
  while true do
    local line = self:_take_line()
    if line == nil then
      if #self.buf > self.max_header_bytes - self.header_bytes then
        return self:_fail("headers_too_large", "HTTP headers exceed size limit")
      end
      return true
    end
    self.header_bytes = self.header_bytes + #line + 2
    if self.header_bytes > self.max_header_bytes then
      return self:_fail("headers_too_large", "HTTP headers exceed size limit")
    end
    local result, err = self:_parse_header(line)
    if result == nil then
      return nil, err
    end
    if result == "done" then
      return self:_headers_complete()
    end
  end
end

function Parser:_handle_body_length()
  if #self.buf == 0 then
    return true
  end
  local remaining = self.content_length - self.body_received
  local take = math.min(remaining, #self.buf)
  if take > 0 then
    local data = self.buf:sub(1, take)
    self.buf = self.buf:sub(take + 1)
    self.body_received = self.body_received + take
    self:_emit({ type = "chunk", data = data })
  end
  if self.body_received == self.content_length then
    -- Ignore any bytes beyond the declared response length.
    self.buf = ""
    self:_emit({ type = "complete" })
    self.done = true
    self.state = "done"
  end
  return true
end

function Parser:_handle_body_close()
  if #self.buf > 0 then
    local data = self.buf
    self.buf = ""
    self:_emit({ type = "chunk", data = data })
  end
  return true
end

function Parser:_handle_chunk_size()
  local line = self:_take_line()
  if line == nil then
    return true
  end
  local size_text = line:match("^([^;]*)")
  if not size_text then
    return self:_fail("invalid_chunk_size", "invalid chunk size line")
  end
  size_text = trim_ows(size_text)
  if size_text == "" or not size_text:match("^%x+$") then
    return self:_fail("invalid_chunk_size", "invalid chunk size")
  end
  local size = tonumber(size_text, 16)
  if not size or size > 9007199254740991 then
    return self:_fail("invalid_chunk_size", "chunk size is too large")
  end
  if size == 0 then
    self.state = "trailers"
  else
    self.chunk_remaining = size
    self.state = "chunk_data"
  end
  return true
end

function Parser:_handle_chunk_data()
  if #self.buf == 0 then
    return true
  end
  local take = math.min(self.chunk_remaining, #self.buf)
  local data = self.buf:sub(1, take)
  self.buf = self.buf:sub(take + 1)
  self.chunk_remaining = self.chunk_remaining - take
  self:_emit({ type = "chunk", data = data })
  if self.chunk_remaining == 0 then
    self.state = "chunk_data_end"
  end
  return true
end

function Parser:_handle_chunk_data_end()
  local line = self:_take_line()
  if line == nil then
    return true
  end
  if line ~= "" then
    return self:_fail("invalid_chunk", "missing CRLF after chunk data")
  end
  self.state = "chunk_size"
  return true
end

function Parser:_handle_trailers()
  while true do
    local line = self:_take_line()
    if line == nil then
      return true
    end
    if line == "" then
      self:_emit({ type = "complete" })
      self.done = true
      self.state = "done"
      return true
    end
    local result, err = self:_parse_header(line)
    if result == nil then
      return nil, err
    end
  end
end

---Feed an arbitrary byte fragment.
---@param data string
---@return table[]|nil events
---@return table|nil err
function Parser:feed(data)
  if self.failed then
    return nil, protocol_error("parser_failed", "HTTP parser is already in an error state")
  end
  if self.done then
    return {}
  end
  if type(data) ~= "string" then
    return self:_fail("invalid_input", "parser input must be a string")
  end
  self.buf = self.buf .. data
  self.events = {}

  while not self.done do
    local ok, err
    local state = self.state
    if state == "status_line" then
      local line = self:_take_line()
      if line == nil then
        if #self.buf > self.max_header_bytes then
          return self:_fail("headers_too_large", "HTTP status line is too long")
        end
        break
      end
      self.header_bytes = #line + 2
      ok, err = self:_parse_status(line)
    elseif state == "headers" then
      ok, err = self:_handle_headers()
    elseif state == "body_length" then
      ok, err = self:_handle_body_length()
    elseif state == "body_close" then
      ok, err = self:_handle_body_close()
    elseif state == "chunk_size" then
      ok, err = self:_handle_chunk_size()
    elseif state == "chunk_data" then
      ok, err = self:_handle_chunk_data()
    elseif state == "chunk_data_end" then
      ok, err = self:_handle_chunk_data_end()
    elseif state == "trailers" then
      ok, err = self:_handle_trailers()
    else
      break
    end
    if ok == nil then
      return nil, err
    end
    if state == self.state and not self.done then
      -- No progress possible with the currently buffered bytes.
      break
    end
  end

  local events = self.events
  self.events = nil
  return events
end

---Signal EOF from the peer.
---@return table[]|nil events
---@return table|nil err
function Parser:finish()
  if self.failed then
    return nil, protocol_error("parser_failed", "HTTP parser is already in an error state")
  end
  if self.done then
    return {}
  end
  self.events = {}
  if self.body_mode == "close" and self.state == "body_close" then
    if #self.buf > 0 then
      local data = self.buf
      self.buf = ""
      self:_emit({ type = "chunk", data = data })
    end
    self:_emit({ type = "complete" })
    self.done = true
    self.state = "done"
    local events = self.events
    self.events = nil
    return events
  end
  self.events = nil
  return self:_fail("premature_eof", "connection closed before HTTP response was complete")
end

return M
