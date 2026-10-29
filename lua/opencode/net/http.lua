-- Asynchronous HTTP/1.1 client transport built on vim.uv.
--
-- Public API:
--
--   http.request(opts, callback)          -- callback(err, response)
--   http.stream(opts, handlers)           -- returns idempotent cancel()
--
-- Both return a cancel function.  Cancelling suppresses all remaining
-- callbacks and closes the socket and timer.  Callbacks are always dispatched
-- with vim.schedule so callers may safely touch buffers/windows.
--
-- Normal response:
--   { status, status_text, http_version, headers, body }
-- Headers are stored lowercase; repeated values are joined with ", ".
--
-- Error:
--   { code = "<machine code>", message = "<display text>" }
--
-- Only http:// is supported.  https:// fails with code
-- "https_not_supported"; it never silently falls back to plain HTTP.

local uv = vim.uv or vim.loop

local M = {}

local DEFAULT_TIMEOUT = 30000
local CRLF = "\r\n"

local function err(code, message)
  return { code = code, message = message }
end

local function lower(value)
  return value:lower()
end

local function trim_ows(value)
  return (value:gsub("^[ \t]+", ""):gsub("[ \t]+$", ""))
end

local function is_hex(c)
  return c:match("^%x$") ~= nil
end

-- Percent-encode one byte.  Existing valid %XX escapes are preserved.
local function encode_component(value, extra_allowed)
  local out = {}
  local i = 1
  while i <= #value do
    local c = value:sub(i, i)
    local b = c:byte()
    if c == "%" and is_hex(value:sub(i + 1, i + 1)) and is_hex(value:sub(i + 2, i + 2)) then
      out[#out + 1] = value:sub(i, i + 2)
      i = i + 3
    elseif c:match("^[%w%-%._~]$") or (extra_allowed and extra_allowed:find(c, 1, true)) then
      out[#out + 1] = c
      i = i + 1
    elseif b >= 128 or b < 32 or b == 127 or c == " " then
      out[#out + 1] = string.format("%%%02X", b)
      i = i + 1
    else
      out[#out + 1] = string.format("%%%02X", b)
      i = i + 1
    end
  end
  return table.concat(out)
end

local function parse_url(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil, err("invalid_url", "URL must be a non-empty string")
  end
  local scheme = raw:match("^([%a][%w+.-]*)://")
  if not scheme then
    return nil, err("invalid_url", "URL must include http:// scheme")
  end
  scheme = lower(scheme)
  if scheme == "https" then
    return nil, err("https_not_supported", "HTTPS is not supported by this transport")
  end
  if scheme ~= "http" then
    return nil, err("invalid_url", "only http:// URLs are supported")
  end

  local rest = raw:sub(#scheme + 4)
  rest = rest:gsub("#.*$", "")
  local authority, target = rest:match("^([^/?#]*)(.*)$")
  if not authority or authority == "" then
    return nil, err("invalid_url", "URL is missing a host")
  end
  if authority:find("@", 1, true) then
    return nil, err("invalid_url", "URL userinfo is not supported")
  end

  local host, port_text
  if authority:sub(1, 1) == "[" then
    host, port_text = authority:match("^%[([^%]]+)%]:(%d+)$")
    if not host then
      host = authority:match("^%[([^%]]+)%]$")
    end
    if not host then
      return nil, err("invalid_url", "invalid IPv6 host in URL")
    end
  else
    host, port_text = authority:match("^([^:]+):(%d+)$")
    if not host then
      host = authority:match("^([^:]+)$")
    end
    if not host then
      return nil, err("invalid_url", "invalid host in URL")
    end
  end
  if host == "" then
    return nil, err("invalid_url", "URL is missing a host")
  end
  if host:find("[^%w%.%-%_%:]") then
    return nil, err("invalid_url", "non-ASCII or invalid host in URL")
  end

  local port = 80
  if port_text then
    port = tonumber(port_text)
    if not port or port < 1 or port > 65535 then
      return nil, err("invalid_url", "invalid port in URL")
    end
  end

  if target == "" then
    target = "/"
  elseif target:sub(1, 1) == "?" then
    target = "/" .. target
  elseif target:sub(1, 1) ~= "/" then
    return nil, err("invalid_url", "invalid request target in URL")
  end

  local path, query = target:match("^([^?]*)(.*)$")
  if path == "" then
    path = "/"
  end
  local encoded_path = encode_component(path, "/:@!$&'()*+,;=")
  local encoded_target = encoded_path
  if query and query ~= "" then
    -- query starts with "?"
    local query_text = query:sub(2)
    encoded_target = encoded_path .. "?" .. encode_component(query_text, "/?:@!$&'()*+,;=?")
  end

  local host_header = host
  if host:find(":", 1, true) then
    host_header = "[" .. host .. "]"
  end
  if port ~= 80 or port_text then
    host_header = host_header .. ":" .. tostring(port)
  end

  return {
    host = host,
    port = port,
    path = encoded_target,
    host_header = host_header,
  }
end

local function normalize_request(opts, is_stream)
  if type(opts) ~= "table" then
    return nil, err("invalid_request", "request options must be a table")
  end
  local method = opts.method or "GET"
  if type(method) ~= "string" or method == "" or method:find("[^%w!#$%%&'*+.^_`|~%-]") then
    return nil, err("invalid_request", "invalid HTTP method")
  end
  method = method:upper()

  if method == "CONNECT" or method == "TRACE" then
    return nil, err("invalid_request", method .. " is not supported")
  end

  local url, url_err = parse_url(opts.url)
  if not url then
    return nil, url_err
  end

  local headers = opts.headers
  if headers == nil then
    headers = {}
  elseif type(headers) ~= "table" then
    return nil, err("invalid_request", "headers must be a table")
  end

  local body = opts.body
  if body ~= nil and type(body) ~= "string" then
    return nil, err("invalid_request", "body must be a string")
  end

  local timeout = opts.timeout
  if timeout == nil and not is_stream then
    timeout = DEFAULT_TIMEOUT
  end
  if timeout ~= nil and (type(timeout) ~= "number" or timeout <= 0) then
    return nil, err("invalid_request", "timeout must be a positive number")
  end

  local seen = {}
  local header_lines = {}
  local has_host = false
  local has_content_length = false
  local has_transfer_encoding = false
  local has_connection = false
  for name, value in pairs(headers) do
    if type(name) ~= "string" or not name:match("^[!#$%%&'*+.^_`|~%w%-]+$") then
      return nil, err("invalid_header", "invalid header name")
    end
    if type(value) ~= "string" and type(value) ~= "number" then
      return nil, err("invalid_header", "header values must be strings or numbers")
    end
    value = tostring(value)
    if name:find("[\r\n]") or value:find("[\r\n]") then
      return nil, err("invalid_header", "header names and values must not contain CR/LF")
    end
    local key = lower(name)
    if seen[key] then
      return nil, err("invalid_header", "duplicate header: " .. name)
    end
    seen[key] = true
    if key == "host" then
      has_host = true
    elseif key == "content-length" then
      has_content_length = true
    elseif key == "transfer-encoding" then
      has_transfer_encoding = true
    elseif key == "connection" then
      has_connection = true
    end
    header_lines[#header_lines + 1] = name .. ": " .. value
  end

  if has_transfer_encoding then
    return nil, err("unsupported_transfer_encoding", "request bodies with Transfer-Encoding are not supported")
  end

  local request_line = method .. " " .. url.path .. " HTTP/1.1" .. CRLF
  local parts = { request_line }
  if not has_host then
    parts[#parts + 1] = "Host: " .. url.host_header .. CRLF
  end
  for _, line in ipairs(header_lines) do
    parts[#parts + 1] = line .. CRLF
  end
  if body ~= nil and not has_content_length then
    parts[#parts + 1] = "Content-Length: " .. tostring(#body) .. CRLF
  end
  if not has_connection then
    parts[#parts + 1] = "Connection: close" .. CRLF
  end
  parts[#parts + 1] = CRLF
  if body then
    parts[#parts + 1] = body
  end

  return {
    method = method,
    url = url,
    payload = table.concat(parts),
    timeout = timeout,
    head_request = method == "HEAD",
  }
end

local Session = {}
Session.__index = Session

local function safe_schedule(fn)
  -- Always defer: callbacks never run inside a libuv callback, so callers may
  -- safely touch Neovim buffers and windows.
  vim.schedule(fn)
end

function Session:_cleanup()
  if self.timer then
    local timer = self.timer
    self.timer = nil
    pcall(timer.stop, timer)
    if not timer:is_closing() then
      timer:close()
    end
  end
  if self.handle then
    local handle = self.handle
    self.handle = nil
    if self.reading then
      self.reading = false
      pcall(handle.read_stop, handle)
    end
    if not handle:is_closing() then
      handle:close()
    end
  end
  self.write_pending = nil
end

function Session:_finish(result)
  if self.finished then
    return
  end
  self.finished = true
  self:_cleanup()
  if self.cancelled then
    return
  end
  safe_schedule(function()
    if self.cancelled then
      return
    end
    if self.stream then
      if self.on_done then
        self.on_done(result.err)
      end
    else
      self.callback(result.err, result.response)
    end
  end)
end

function Session:_fail(error)
  self:_finish({ err = error })
end

function Session:_process(data)
  if self.finished or self.cancelled then
    return
  end
  local events, parse_err = self.parser:feed(data)
  if not events then
    self:_fail(parse_err)
    return
  end
  for _, event in ipairs(events) do
    if event.type == "headers" then
      self.response_headers = event.response
      if self.stream and self.on_headers then
        local response = event.response
        safe_schedule(function()
          if not self.cancelled and self.on_headers then
            self.on_headers(response)
          end
        end)
      end
    elseif event.type == "chunk" then
      if self.stream then
        if self.on_chunk then
          local chunk = event.data
          safe_schedule(function()
            if not self.cancelled and self.on_chunk then
              self.on_chunk(chunk)
            end
          end)
        end
      else
        self.body_parts[#self.body_parts + 1] = event.data
      end
    elseif event.type == "complete" then
      if self.stream then
        self:_finish({})
      else
        local response = self.response_headers or {}
        response.body = table.concat(self.body_parts)
        self:_finish({ response = response })
      end
      return
    end
  end
end

function Session:_on_read(read_err, data)
  if self.finished or self.cancelled then
    return
  end
  if read_err then
    self:_fail(err("read_error", tostring(read_err)))
    return
  end
  if data == nil or data == "" then
    local events, finish_err = self.parser:finish()
    if not events then
      self:_fail(finish_err)
      return
    end
    for _, event in ipairs(events) do
      if event.type == "chunk" then
        if self.stream then
          if self.on_chunk then
            local chunk = event.data
            safe_schedule(function()
              if not self.cancelled and self.on_chunk then
                self.on_chunk(chunk)
              end
            end)
          end
        else
          self.body_parts[#self.body_parts + 1] = event.data
        end
      elseif event.type == "complete" then
        if self.stream then
          self:_finish({})
        else
          local response = self.response_headers or {}
          response.body = table.concat(self.body_parts)
          self:_finish({ response = response })
        end
        return
      end
    end
    return
  end
  self:_process(data)
end

function Session:_start_read()
  if not self.handle or self.finished or self.cancelled then
    return
  end
  self.reading = true
  self.handle:read_start(function(read_err, data)
    self:_on_read(read_err, data)
  end)
end

function Session:_on_connected(connect_err)
  if self.finished or self.cancelled then
    return
  end
  if connect_err then
    self:_fail(err("connect_failed", "connection failed: " .. tostring(connect_err)))
    return
  end
  self.connected = true
  self:_start_read()
  self:_write()
end

function Session:_write()
  if self.finished or self.cancelled or not self.handle or not self.connected then
    return
  end
  local payload = self.payload
  local offset = self.write_offset or 1
  if offset > #payload then
    self.payload = nil
    return
  end
  self.write_pending = true
  self.handle:write(payload:sub(offset), function(write_err)
    self.write_pending = false
    if self.finished or self.cancelled then
      return
    end
    if write_err then
      self:_fail(err("write_error", "write failed: " .. tostring(write_err)))
      return
    end
    self.write_offset = nil
    self.payload = nil
  end)
end

function Session:_on_timeout()
  if self.finished or self.cancelled then
    return
  end
  self:_fail(err("timeout", "HTTP request timed out"))
end

function Session:start()
  if self.timeout then
    local timer = assert(uv.new_timer())
    self.timer = timer
    timer:start(self.timeout, 0, function()
      self:_on_timeout()
    end)
  end

  local handle = assert(uv.new_tcp())
  self.handle = handle

  local host = self.url.host
  local port = self.url.port
  if host:match("^%d+%.%d+%.%d+%.%d+$") then
    handle:connect(host, port, function(connect_err)
      self:_on_connected(connect_err)
    end)
  else
    uv.getaddrinfo(host, nil, { socktype = uv.SOCK_STREAM }, function(resolve_err, addresses)
      if self.finished or self.cancelled then
        return
      end
      if resolve_err or not addresses or #addresses == 0 then
        self:_fail(err("connect_failed", "failed to resolve host: " .. tostring(resolve_err or host)))
        return
      end
      local address = addresses[1]
      for _, candidate in ipairs(addresses) do
        if candidate.addr and not candidate.addr:find(":", 1, true) then
          address = candidate
          break
        end
      end
      if not address or not address.addr then
        self:_fail(err("connect_failed", "failed to resolve host: " .. host))
        return
      end
      if not self.handle then
        return
      end
      self.handle:connect(address.addr, port, function(connect_err)
        self:_on_connected(connect_err)
      end)
    end)
  end
end

function Session:cancel()
  if self.cancelled then
    return
  end
  self.cancelled = true
  self.finished = true
  self:_cleanup()
end

local function new_session(opts, callback, handlers, stream)
  local request, req_err = normalize_request(opts, stream)
  if not request then
    return nil, req_err
  end

  local session = setmetatable({
    url = request.url,
    timeout = request.timeout,
    payload = request.payload,
    parser = require("opencode.net.parser").new({
      head_request = request.head_request,
    }),
    stream = stream,
    callback = callback,
    on_headers = handlers and handlers.on_headers,
    on_chunk = handlers and handlers.on_chunk,
    on_done = handlers and handlers.on_done,
    body_parts = {},
    write_offset = 1,
    cancelled = false,
    finished = false,
  }, Session)

  local ok, start_err = pcall(session.start, session)
  if not ok then
    session:_cleanup()
    return nil, err("connect_failed", tostring(start_err))
  end
  return function()
    session:cancel()
  end
end

---Perform a normal request.
---@param opts table
---@param callback fun(err: table|nil, response: table|nil)
---@return fun()|nil cancel
---@return table|nil err
function M.request(opts, callback)
  if type(callback) ~= "function" then
    return nil, err("invalid_request", "callback must be a function")
  end
  return new_session(opts, callback, nil, false)
end

---Perform a streaming request.
---@param opts table
---@param handlers table { on_headers, on_chunk, on_done }
---@return fun()|nil cancel
---@return table|nil err
function M.stream(opts, handlers)
  if type(handlers) ~= "table" then
    return nil, err("invalid_request", "stream handlers must be a table")
  end
  for _, name in ipairs({ "on_headers", "on_chunk", "on_done" }) do
    if handlers[name] ~= nil and type(handlers[name]) ~= "function" then
      return nil, err("invalid_request", name .. " must be a function")
    end
  end
  return new_session(opts, nil, handlers, true)
end

M.parse_url = parse_url
M.percent_encode = encode_component

return M
