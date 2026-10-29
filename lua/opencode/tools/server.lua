-- Local HTTP server for OpenCode tool calls.
--
-- Security properties:
--   * binds 127.0.0.1 on an ephemeral port only;
--   * every route, including GET /health, requires
--     `Authorization: Bearer <token>`;
--   * bounded request line, header and body sizes, plus read timeouts;
--   * requests are closed after one response (no keep-alive);
--   * action handlers are injected and run outside the buffer layer; the
--     server never edits buffers itself;
--   * the token is never logged, echoed, or included in an error message.
--
-- Usage:
--   local server = require("opencode.tools.server").new({
--     token = token,
--     instance_id = id,
--     project_root = root,
--     handlers = { open = function(input, ctx) ... end },
--   })
--   server:start(function(err, info) ... end)
--   server:stop()
--
-- Handler contract (synchronous or asynchronous):
--   result, err = handler(input, ctx)
--   -- or: ctx.respond(result, err) later
-- A non-nil result is serialized into the success envelope. Returning
-- `nil, err` (or throwing) produces the failure envelope. Returning
-- `nil, nil` means the handler will call ctx.respond later, up to the
-- handler timeout.

local uv = vim.uv or vim.loop
local protocol = require("opencode.tools.protocol")

local M = {}

local DEFAULTS = {
  max_header_bytes = 16 * 1024,
  max_body_bytes = 1024 * 1024,
  max_headers = 100,
  max_request_line = 8 * 1024,
  max_connections = 64,
  header_timeout = 5000,
  body_timeout = 10000,
  handler_timeout = 30000,
}

local STATUS_TEXT = {
  [200] = "OK",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [408] = "Request Timeout",
  [413] = "Payload Too Large",
  [422] = "Unprocessable Entity",
  [431] = "Request Header Fields Too Large",
  [499] = "Client Closed Request",
  [500] = "Internal Server Error",
  [503] = "Service Unavailable",
  [504] = "Gateway Timeout",
}

local Server = {}
Server.__index = Server

local function default_instance_id()
  return string.format("%x-%x", uv.os_getpid(), uv.hrtime())
end

local function default_project_root()
  return vim.fs.normalize(uv.cwd() or ".")
end

local function normalize_limits(opts)
  local limits = {}
  local custom = (opts and opts.limits) or opts or {}
  for key, value in pairs(DEFAULTS) do
    local supplied = custom[key]
    if type(supplied) == "number" and supplied > 0 then
      limits[key] = math.floor(supplied)
    else
      limits[key] = value
    end
  end
  return limits
end

--- Create a server instance. `start` binds the socket.
function M.new(opts)
  opts = opts or {}
  if type(opts.token) ~= "string" or opts.token == "" then
    error("tools.server: token is required")
  end
  local instance_id = opts.instance_id or default_instance_id()
  if not require("opencode.tools.registry").valid_instance_id(instance_id) then
    error("tools.server: invalid instance_id")
  end
  local self = setmetatable({
    token = opts.token,
    instance_id = instance_id,
    project_root = require("opencode.tools.registry").canonicalize(
      opts.project_root or default_project_root()
    ) or default_project_root(),
    limits = normalize_limits(opts),
    logger = opts.logger,
    handlers = {},
    connections = {},
    rejected_sockets = {},
    state = "idle",
    listener = nil,
    port = nil,
    url = nil,
    _start_callbacks = {},
    _stop_callbacks = {},
  }, Server)
  for action, handler in pairs(opts.handlers or {}) do
    self:register_handler(action, handler)
  end
  return self
end

function Server:_log(level, message)
  if type(self.logger) == "function" then
    pcall(self.logger, level, message)
  end
end

--- Scrub the instance token from any text shown to clients.
function Server:_scrub(text)
  if type(text) ~= "string" or self.token == "" then
    return text
  end
  local parts = {}
  local start = 1
  while true do
    local first, last = text:find(self.token, start, true)
    if not first then
      break
    end
    parts[#parts + 1] = text:sub(start, first - 1)
    parts[#parts + 1] = "<redacted>"
    start = last + 1
  end
  if #parts == 0 then
    return text
  end
  parts[#parts + 1] = text:sub(start)
  return table.concat(parts)
end

--- Register or replace an injected action handler.
-- Handlers must not edit buffers from the libuv callback; they should
-- schedule Neovim API work themselves.
function Server:register_handler(action, handler)
  if type(handler) ~= "function" then
    error("tools.server: handler must be a function")
  end
  local known = false
  for _, name in ipairs(protocol.ACTIONS) do
    if name == action then
      known = true
      break
    end
  end
  if not known then
    error("tools.server: unknown action " .. tostring(action))
  end
  self.handlers[action] = handler
end

function Server:unregister_handler(action)
  self.handlers[action] = nil
end

function Server:info()
  return {
    url = self.url,
    port = self.port,
    instance_id = self.instance_id,
    project_root = self.project_root,
  }
end

function Server:is_running()
  return self.state == "running"
end

--- Ensure sockets and timers are released when Neovim exits without an
-- explicit stop. The autocmd is idempotent because `stop` is idempotent.
function Server:_install_exit_handler()
  if not (vim.api and vim.api.nvim_create_augroup and vim.api.nvim_create_autocmd) then
    return
  end
  local group_name = "OpencodeNvimToolServer_" .. self.instance_id
  local ok, group = pcall(vim.api.nvim_create_augroup, group_name, { clear = true })
  if not ok then
    return
  end
  pcall(vim.api.nvim_create_autocmd, "VimLeavePre", {
    group = group,
    callback = function()
      self:stop()
    end,
  })
end

--- Start listening. Idempotent; a running server reports its current info.
function Server:start(callback)
  callback = callback or function() end
  if self.state == "running" then
    callback(nil, self:info())
    return self
  end
  if self.state == "starting" then
    table.insert(self._start_callbacks, callback)
    return self
  end
  self.state = "starting"
  local listener = uv.new_tcp()
  local ok, err = listener:bind("127.0.0.1", 0)
  if not ok then
    listener:close()
    self.state = "stopped"
    self:_log("error", "tool server bind failed")
    callback("cannot bind tool server: " .. tostring(err))
    return self
  end
  local sockname = listener:getsockname()
  self.port = sockname and sockname.port
  if not self.port then
    listener:close()
    self.state = "stopped"
    callback("cannot determine tool server port")
    return self
  end
  self.url = "http://127.0.0.1:" .. tostring(self.port)
  self.listener = listener
  local listen_ok, listen_err = listener:listen(128, function(connect_err)
    if connect_err then
      self:_log("error", "tool server accept failed")
      return
    end
    self:_accept()
  end)
  if not listen_ok then
    listener:close()
    self.listener = nil
    self.state = "stopped"
    self.url = nil
    self.port = nil
    callback("cannot listen on tool server: " .. tostring(listen_err))
    return self
  end
  self.state = "running"
  self:_install_exit_handler()
  self:_log("info", "tool server listening on " .. tostring(self.url))
  callback(nil, self:info())
  local queued = self._start_callbacks
  self._start_callbacks = {}
  for _, cb in ipairs(queued) do
    cb(nil, self:info())
  end
  return self
end

function Server:_accept()
  if self.state ~= "running" then
    return
  end
  local socket = uv.new_tcp()
  local peer = self.listener:accept(socket)
  if not peer then
    socket:close()
    return
  end
  local count = 0
  for _ in pairs(self.connections) do
    count = count + 1
  end
  if count >= self.limits.max_connections then
    local body = vim.json.encode(protocol.fail("SERVER_BUSY", "server busy"))
    local response = self:_response(503, body)
    self.rejected_sockets[socket] = true
    local function cleanup()
      self.rejected_sockets[socket] = nil
      if not socket:is_closing() then
        socket:close()
      end
    end
    local accepted, write_err = socket:write(response, cleanup)
    if not accepted then
      self:_log("warn", "tool server busy response failed: " .. tostring(write_err))
      cleanup()
    end
    return
  end
  local connection = {
    socket = socket,
    buffer = "",
    stage = "headers",
    content_length = nil,
    headers = nil,
    request = nil,
    closed = false,
    responded = false,
    timer = uv.new_timer(),
  }
  connection.timer:start(self.limits.header_timeout, 0, function()
    self:_fail_connection(connection, "SLOW_CONNECTION", "request headers timed out")
  end)
  self.connections[socket] = connection
  socket:read_start(function(err, chunk)
    self:_on_read(connection, err, chunk)
  end)
end

function Server:_close_connection(connection)
  if connection.closed then
    return
  end
  connection.closed = true
  if connection.handler_finish then
    local cancel_handler = connection.handler_finish
    connection.handler_finish = nil
    cancel_handler()
  end
  if connection.timer then
    connection.timer:stop()
    if not connection.timer:is_closing() then
      connection.timer:close()
    end
    connection.timer = nil
  end
  self.connections[connection.socket] = nil
  if not connection.socket:is_closing() then
    connection.socket:close()
  end
end

function Server:_response(status, body)
  local reason = STATUS_TEXT[status] or "Error"
  return table.concat({
    "HTTP/1.1 " .. tostring(status) .. " " .. reason,
    "Content-Type: application/json; charset=utf-8",
    "Content-Length: " .. tostring(#body),
    "Cache-Control: no-store",
    "Connection: close",
    "X-Content-Type-Options: nosniff",
    "",
    body,
  }, "\r\n")
end

--- Recursively replace the token in strings before JSON encoding, so escaped
-- values cannot leak it either. Cycles become a placeholder instead of
-- recursing forever.
function Server:_scrub_value(value, seen)
  if type(value) == "string" then
    return self:_scrub(value)
  end
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return "<cycle>"
  end
  seen[value] = true
  local copy = {}
  for key, item in pairs(value) do
    local new_key = type(key) == "string" and self:_scrub(key) or key
    copy[new_key] = self:_scrub_value(item, seen)
  end
  seen[value] = nil
  return copy
end

--- Serialize and send one response, then close the connection.
function Server:_send(connection, status, envelope)
  if connection.closed or connection.responded then
    return
  end
  connection.responded = true
  connection.stage = "done"
  if connection.timer then
    connection.timer:stop()
  end
  local ok, body = pcall(vim.json.encode, self:_scrub_value(envelope))
  if not ok then
    status = 500
    body = vim.json.encode(protocol.fail("INTERNAL_ERROR", "response encoding failed"))
    self:_log("error", "tool server response encoding failed")
  end
  body = self:_scrub(body)
  local socket = connection.socket
  local accepted, write_err = socket:write(self:_response(status, body), function(err)
    if err then
      self:_log("warn", "tool server write failed")
    end
    self:_close_connection(connection)
  end)
  if not accepted then
    self:_log("warn", "tool server write failed: " .. tostring(write_err))
    self:_close_connection(connection)
  end
end

function Server:_fail(connection, code, message, request_id, status)
  status = status or protocol.status_for_code(code)
  self:_send(connection, status, protocol.fail(code, self:_scrub(message), request_id))
end

function Server:_fail_connection(connection, code, message)
  if connection.closed then
    return
  end
  self:_fail(connection, code, message, nil)
end

function Server:_on_read(connection, err, chunk)
  if connection.closed or connection.stage == "done" then
    return
  end
  if err then
    self:_close_connection(connection)
    return
  end
  if not chunk then
    -- Peer closed before a complete request.
    self:_close_connection(connection)
    return
  end
  connection.buffer = connection.buffer .. chunk

  if connection.stage == "headers" then
    local header_end = connection.buffer:find("\r\n\r\n", 1, true)
    if not header_end then
      if #connection.buffer > self.limits.max_header_bytes then
        self:_fail_connection(connection, "HEADERS_TOO_LARGE", "request headers too large")
      end
      return
    end
    local head = connection.buffer:sub(1, header_end - 1)
    if #head > self.limits.max_header_bytes then
      self:_fail_connection(connection, "HEADERS_TOO_LARGE", "request headers too large")
      return
    end
    local parsed, parse_err = self:_parse_head(head)
    if not parsed then
      self:_fail_connection(connection, parse_err.code, parse_err.message)
      return
    end
    connection.headers = parsed.headers
    connection.request = parsed
    connection.buffer = connection.buffer:sub(header_end + 4)
    connection.stage = "body"

    -- Authenticate as early as possible, before reading any body.
    if not protocol.check_bearer(parsed.headers.authorization, self.token) then
      self:_fail_connection(connection, "UNAUTHORIZED", "missing or invalid bearer token", nil, 401)
      return
    end

    local transfer_encoding = parsed.headers["transfer-encoding"]
    if transfer_encoding then
      self:_fail_connection(connection, "INVALID_REQUEST", "transfer-encoding is not supported")
      return
    end
    if parsed.headers["content-length"] then
      local raw = parsed.headers["content-length"]
      if not raw:match("^%d+$") then
        self:_fail_connection(connection, "INVALID_HEADER", "invalid content-length")
        return
      end
      connection.content_length = tonumber(raw)
      if connection.content_length > self.limits.max_body_bytes then
        self:_fail_connection(connection, "PAYLOAD_TOO_LARGE", "request body too large")
        return
      end
    else
      connection.content_length = 0
    end
    if connection.timer then
      connection.timer:stop()
      connection.timer:start(self.limits.body_timeout, 0, function()
        self:_fail_connection(connection, "SLOW_CONNECTION", "request body timed out")
      end)
    end
  end

  if connection.stage == "body" then
    if #connection.buffer < connection.content_length then
      -- Guard against an attacker streaming more bytes than declared.
      if #connection.buffer > self.limits.max_body_bytes then
        self:_fail_connection(connection, "PAYLOAD_TOO_LARGE", "request body too large")
      end
      return
    end
    local body = connection.buffer:sub(1, connection.content_length)
    connection.stage = "done"
    if connection.timer then
      connection.timer:stop()
    end
    self:_handle_request(connection, body)
  end
end

local function parse_error(code, message)
  return nil, { code = code, message = message }
end

function Server:_parse_head(head)
  if #head > self.limits.max_header_bytes then
    return parse_error("HEADERS_TOO_LARGE", "request headers too large")
  end
  local first_end = head:find("\r\n", 1, true)
  local request_line, rest
  if first_end then
    request_line = head:sub(1, first_end - 1)
    rest = head:sub(first_end + 2)
  else
    request_line = head
    rest = ""
  end
  if #request_line > self.limits.max_request_line then
    return parse_error("HEADERS_TOO_LARGE", "request line too long")
  end
  local method, target, version = request_line:match("^(%u+) (%S+) (HTTP/%d%.%d)$")
  if not method then
    return parse_error("INVALID_REQUEST", "malformed request line")
  end
  if version ~= "HTTP/1.1" and version ~= "HTTP/1.0" then
    return parse_error("INVALID_REQUEST", "unsupported HTTP version")
  end
  if target:sub(1, 1) ~= "/" or target:find("#", 1, true) then
    return parse_error("INVALID_REQUEST", "invalid request target")
  end
  local path = target:match("^([^?]*)") or target
  local headers = {}
  local header_count = 0
  local lines = vim.split(rest, "\r\n", { plain = true })
  for _, line in ipairs(lines) do
    if line == "" then
      -- Trailing empty field after the final CRLF.
    else
      if line:sub(1, 1) == " " or line:sub(1, 1) == "\t" then
        return parse_error("INVALID_HEADER", "obsolete header folding is not supported")
      end
      local name, value = line:match("^([^:]+):[ \t]*(.-)[ \t]*$")
      if not name or not name:match("^[!#$%%&'*+%-.^_`|~%w]+$") then
        return parse_error("INVALID_HEADER", "malformed header")
      end
      header_count = header_count + 1
      if header_count > self.limits.max_headers then
        return parse_error("HEADERS_TOO_LARGE", "too many headers")
      end
      local key = name:lower()
      if key == "content-length" or key == "authorization" or key == "content-type" or key == "host" then
        if headers[key] ~= nil then
          return parse_error("INVALID_HEADER", "duplicate " .. key .. " header")
        end
        headers[key] = value
      elseif headers[key] then
        headers[key] = headers[key] .. ", " .. value
      else
        headers[key] = value
      end
    end
  end
  return { method = method, target = target, path = path, version = version, headers = headers }
end

function Server:_handle_request(connection, body)
  local request = connection.request
  local method = request.method
  local path = request.path

  if path == "/health" then
    if method ~= "GET" then
      self:_fail(connection, "METHOD_NOT_ALLOWED", "health only supports GET", nil, 405)
      return
    end
    local actions = vim.tbl_keys(self.handlers)
    table.sort(actions)
    self:_send(connection, 200, protocol.ok({
      status = "ok",
      instance_id = self.instance_id,
      project_root = self.project_root,
      pid = uv.os_getpid(),
      version = protocol.VERSION,
      actions = actions,
    }))
    return
  end

  local action = protocol.action_for_path(path)
  if not action then
    self:_fail(connection, "NOT_FOUND", "unknown route", nil, 404)
    return
  end
  if method ~= "POST" then
    self:_fail(connection, "METHOD_NOT_ALLOWED", "tools only support POST", nil, 405)
    return
  end
  local handler = self.handlers[action]
  if not handler then
    self:_fail(connection, "NOT_FOUND", "no handler registered for action", nil, 404)
    return
  end

  local decoded, decode_err
  if body == "" then
    self:_fail(connection, "INVALID_JSON", "request body must be JSON", nil)
    return
  end
  local decode_ok
  decode_ok, decoded = pcall(vim.json.decode, body)
  if not decode_ok then
    self:_fail(connection, "INVALID_JSON", "request body is not valid JSON", nil)
    return
  end
  local req, req_err = protocol.parse_request(decoded, action)
  if not req then
    -- Echo a usable request_id even when the rest of the envelope is
    -- invalid, so clients can correlate the failure with their request.
    local echoed_id
    if type(decoded) == "table" and type(decoded.request_id) == "string" then
      if #decoded.request_id > 0 and #decoded.request_id <= 128 then
        echoed_id = decoded.request_id
      end
    end
    self:_fail(connection, req_err.code, req_err.message, echoed_id, protocol.status_for_code(req_err.code))
    return
  end

  self:_invoke_handler(connection, action, handler, req)
end

function Server:_invoke_handler(connection, action, handler, req)
  local finished = false
  local handler_timer = uv.new_timer()
  local function cancel()
    if handler_timer then
      handler_timer:stop()
      if not handler_timer:is_closing() then
        handler_timer:close()
      end
      handler_timer = nil
    end
  end
  local function finish(result, err)
    if finished then
      return
    end
    finished = true
    connection.handler_finish = nil
    cancel()
    if err ~= nil then
      local normalized = protocol.normalize_error(err)
      self:_send(
        connection,
        protocol.status_for_code(normalized.code),
        protocol.fail(
          normalized.code,
          self:_scrub(normalized.message),
          self:_scrub(req.request_id),
          normalized.details
        )
      )
    else
      self:_send(connection, 200, protocol.ok(result, self:_scrub(req.request_id)))
    end
  end
  connection.handler_finish = function()
    finished = true
    cancel()
  end
  local ctx = {
    request_id = req.request_id,
    action = action,
    instance_id = self.instance_id,
    project_root = self.project_root,
    server = self,
    respond = finish,
  }
  handler_timer:start(self.limits.handler_timeout, 0, function()
    finish(nil, protocol.error("TIMEOUT", "action handler timed out"))
  end)

  local ok, result, err = pcall(handler, req.input, ctx)
  if not ok then
    self:_log("error", "tool handler " .. action .. " raised an error")
    finish(nil, protocol.error("INTERNAL_ERROR", "action failed"))
    return
  end
  if result ~= nil or err ~= nil then
    finish(result, err)
  end
  -- result == nil and err == nil: async handler; ctx.respond completes it.
end

--- Stop listening and close all connections. Idempotent.
function Server:stop(callback)
  callback = callback or function() end
  if self.state == "stopped" or self.state == "idle" then
    callback()
    return self
  end
  if self.state == "stopping" then
    table.insert(self._stop_callbacks, callback)
    return self
  end
  self.state = "stopping"
  if self.listener then
    self.listener:close()
    self.listener = nil
  end
  local connections = {}
  for _, connection in pairs(self.connections) do
    table.insert(connections, connection)
  end
  for _, connection in ipairs(connections) do
    self:_close_connection(connection)
  end
  self.connections = {}
  for socket in pairs(self.rejected_sockets) do
    if not socket:is_closing() then
      socket:close()
    end
  end
  self.rejected_sockets = {}
  self.state = "stopped"
  self.url = nil
  self.port = nil
  self:_log("info", "tool server stopped")
  callback()
  local queued = self._stop_callbacks
  self._stop_callbacks = {}
  for _, cb in ipairs(queued) do
    cb()
  end
  return self
end

function Server:close(callback)
  return self:stop(callback)
end

-- Module-level singleton convenience API. `start` reuses a running instance.
local singleton

function M.start(opts, callback)
  if singleton and (singleton.state == "running" or singleton.state == "starting") then
    return singleton:start(callback)
  end
  singleton = M.new(opts)
  singleton:start(callback)
  return singleton
end

function M.stop(callback)
  if not singleton then
    if callback then
      callback()
    end
    return
  end
  singleton:stop(callback)
  singleton = nil
end

function M.get()
  return singleton
end

M.Server = Server
M.DEFAULTS = DEFAULTS

return M
