-- Stateless OpenCode V2 API client.
--
-- Public API:
--
--   local client = require("opencode.client").new({
--     url = "http://127.0.0.1:4096",
--     headers = { Authorization = "Basic ..." }, -- optional
--     transport = nil,                           -- optional http-compatible module
--     timeout = 30000,                           -- optional normal-request timeout
--   })
--
--   client.info(callback)
--   client.list_sessions({ directory = root, limit = 20, ... }, callback)
--   client.create_session({ directory = root, title = "..." }, callback)
--   client.list_messages(session_id, callback)
--   client.list_messages(session_id, { limit = 20, order = "desc" }, callback)
--   client.prompt(session_id, { text = "..." }, callback)
--   client.command(session_id, { name = "...", text = "..." }, callback)
--   client.interrupt(session_id, { resume = true }, callback)
--   client.find_files({ location = { directory = root }, query = "..." }, callback)
--   client.list_files({ location = { directory = root }, path = "src" }, callback)
--   client.list_commands({ location = { directory = root } }, callback)
--   client.list_agents({ location = { directory = root } }, callback)
--   client.list_skills({ location = { directory = root } }, callback)
--   client.stream_events({ types = { "..." } }, handlers)
--
-- The module itself also exposes the same methods for callers wired to the
-- active plugin configuration.  Those use require("opencode").get_config() to
-- read only server.url/server.headers; they keep no session or project state.
--
-- Methods may be called with either dot or colon syntax.  They return an
-- idempotent cancel function.  Callbacks run at most once and receive
-- (err, data, response); `data` is the decoded JSON body (nil for 204/empty
-- responses) and `response` is the raw transport response when available.
--
-- Stream handlers are { on_headers, on_chunk, on_done }.  Chunks are passed
-- through exactly as received; the client does not parse SSE or merge events.
-- `on_headers` is called only for 2xx responses.  A non-2xx stream is buffered
-- and delivered as one API error from `on_done`.
--
-- Errors are tables:
--   { code = "invalid_argument" | "invalid_response" | "invalid_json"
--            | "http_error" | <transport code>,
--     message = "<display text>",
--     kind = "transport" (transport errors only),
--     status, status_text, headers, body, data, server_code, cause }
--
-- The client keeps no session, project or event state.  Every session ID and
-- location is supplied by the caller on each request.

local v2 = require("opencode.api.v2")

local unpack = table.unpack or unpack

local M = {}

local DEFAULT_TIMEOUT = 30000
local MAX_STREAM_ERROR_BODY = 256 * 1024

---@param code string
---@param message string
---@param extra table|nil
---@return table
local function api_error(code, message, extra)
  local err = { code = code, message = message }
  for key, value in pairs(extra or {}) do
    err[key] = value
  end
  return err
end

M.error = api_error

---@param err table|nil
---@return table
local function transport_error(err)
  if type(err) ~= "table" then
    return api_error("transport_error", tostring(err or "transport failed"))
  end
  return api_error(err.code or "transport_error", err.message or "transport failed", {
    kind = "transport",
    cause = err,
  })
end

---Decode a JSON body.  Empty bodies are successful nil values.
---@param body string|nil
---@return boolean ok
---@return any value
local function decode_json(body)
  if body == nil or body == "" then
    return true, nil
  end
  if type(body) ~= "string" then
    return false, "response body is not a string"
  end
  if body:match("^%s*$") then
    return true, nil
  end
  local ok, value = pcall(vim.json.decode, body)
  if not ok then
    return false, value
  end
  if value == vim.NIL then
    value = nil
  end
  return true, value
end

---@param data any
---@return string|nil
local function server_code(data)
  if type(data) ~= "table" then
    return nil
  end
  if type(data._tag) == "string" and data._tag ~= "" then
    return data._tag
  end
  if type(data.error) == "table" and type(data.error.type) == "string" and data.error.type ~= "" then
    return data.error.type
  end
  if type(data.type) == "string" and data.type ~= "" then
    return data.type
  end
  return nil
end

---@param response table
---@param data any
---@return string
local function display_message(response, data)
  if type(data) == "table" then
    if type(data.message) == "string" and data.message ~= "" then
      return data.message
    end
    local nested = data.error
    if type(nested) == "table" then
      if type(nested.message) == "string" and nested.message ~= "" then
        return nested.message
      end
      if type(nested.type) == "string" and nested.type ~= "" then
        return nested.type
      end
    elseif type(nested) == "string" and nested ~= "" then
      return nested
    end
    if type(data._tag) == "string" and data._tag ~= "" then
      return data._tag
    end
  end
  local body = response.body
  if type(body) == "string" then
    local trimmed = body:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" and #trimmed <= 512 then
      return trimmed
    end
  end
  local status = tonumber(response.status) or 0
  if type(response.status_text) == "string" and response.status_text ~= "" then
    return ("HTTP %d %s"):format(status, response.status_text)
  end
  return ("HTTP %d"):format(status)
end

---@param response table
---@param cause table|nil
---@return table
local function http_error(response, cause)
  local ok, data = decode_json(response.body)
  local err = api_error("http_error", display_message(response, data), {
    status = tonumber(response.status),
    status_text = response.status_text,
    headers = response.headers,
    body = response.body,
    data = ok and data or nil,
    server_code = server_code(ok and data or nil),
    cause = cause,
  })
  if not ok then
    err.json_error = tostring(data)
  end
  return err
end

---@param response table
---@param cause any
---@return table
local function invalid_json_error(response, cause)
  return api_error("invalid_json", "invalid JSON response: " .. tostring(cause), {
    status = tonumber(response.status),
    status_text = response.status_text,
    headers = response.headers,
    body = response.body,
    cause = cause,
  })
end

---@param response table|nil
---@return table|nil err
---@return any data
---@return table|nil response
local function parse_response(response)
  if type(response) ~= "table" then
    return api_error("invalid_response", "transport returned no response"), nil, nil
  end
  local status = tonumber(response.status)
  if not status then
    return api_error("invalid_response", "response is missing a numeric status"), nil, response
  end
  if status < 200 or status > 299 then
    return http_error(response), nil, response
  end
  local ok, data = decode_json(response.body)
  if not ok then
    return invalid_json_error(response, data), nil, response
  end
  return nil, data, response
end

---@param value table|nil
---@return table
local function copy_headers(value)
  local headers = {}
  for name, header_value in pairs(value or {}) do
    headers[name] = header_value
  end
  return headers
end

---@param base table
---@param extra table|nil
---@return table
local function merge_headers(base, extra)
  local headers = copy_headers(base)
  local existing = {}
  for name in pairs(headers) do
    existing[name:lower()] = name
  end
  for name, value in pairs(extra or {}) do
    local key = name:lower()
    local previous = existing[key]
    if previous and previous ~= name then
      headers[previous] = nil
    end
    headers[name] = value
    existing[key] = name
  end
  return headers
end

---@param headers table|nil
---@return table
local function validate_headers(headers)
  if headers == nil then
    return {}
  end
  if type(headers) ~= "table" then
    error("opencode.client: headers must be a table", 0)
  end
  local seen = {}
  local result = {}
  for name, value in pairs(headers) do
    if type(name) ~= "string" or name == "" then
      error("opencode.client: header names must be non-empty strings", 0)
    end
    if name:find("[\r\n]") then
      error("opencode.client: header names must not contain CR/LF", 0)
    end
    if type(value) ~= "string" and type(value) ~= "number" then
      error(("opencode.client: header %q must be a string or number"):format(name), 0)
    end
    if tostring(value):find("[\r\n]") then
      error(("opencode.client: header %q must not contain CR/LF"):format(name), 0)
    end
    local key = name:lower()
    if seen[key] then
      error(("opencode.client: duplicate header %q"):format(name), 0)
    end
    seen[key] = true
    result[name] = value
  end
  return result
end

---@param url string|nil
---@return string
local function normalize_url(url)
  if type(url) ~= "string" or url == "" then
    error("opencode.client: url must be a non-empty string", 0)
  end
  local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
  if not scheme then
    error("opencode.client: url must be an absolute http:// URL", 0)
  end
  scheme = scheme:lower()
  if scheme == "https" then
    error("opencode.client: HTTPS is not supported by this client (TLS transport is not implemented)", 0)
  end
  if scheme ~= "http" then
    error(("opencode.client: URL scheme %q is not supported; use http://"):format(scheme), 0)
  end
  if rest:find("%s") then
    error("opencode.client: url must not contain whitespace", 0)
  end
  if rest:find("[?#]") then
    error("opencode.client: url must not contain a query or fragment", 0)
  end
  local authority = rest:match("^([^/]+)")
  if not authority or authority == "" then
    error("opencode.client: url is missing a host", 0)
  end
  return (url:gsub("/+$", ""))
end

---@param base string
---@param spec table
---@return string
local function build_url(base, spec)
  local url = base .. spec.path
  if spec.query and spec.query ~= "" then
    url = url .. "?" .. spec.query
  end
  return url
end

---@param client table
---@param ... any
---@return table
local function args_without_self(client, ...)
  local args = { ... }
  if args[1] == client then
    table.remove(args, 1)
  end
  return args
end

---@param value any
---@return string|nil
local function validate_session_id(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  return value
end

---@param opts table
---@return string|nil directory
---@return table|nil err
local function directory_from(opts)
  if type(opts) ~= "table" then
    return nil, api_error("invalid_argument", "options must be a table")
  end
  local location = opts.location
  if location ~= nil and type(location) ~= "table" then
    return nil, api_error("invalid_argument", "options.location must be a table")
  end
  local directory = location and location.directory or opts.directory
  if type(directory) ~= "string" or directory == "" then
    return nil, api_error("invalid_argument", "directory must be a non-empty string")
  end
  return directory
end

---Resolve the explicit location used by V2 query routes.
---@param params table
---@return table|nil location
---@return table|nil err
local function query_location(params)
  if type(params) ~= "table" then
    return nil, api_error("invalid_argument", "query parameters must be a table")
  end
  local value = params.location
  if value == nil then
    value = params.directory
  end
  local directory
  if type(value) == "table" then
    directory = value.directory
  elseif type(value) == "string" then
    directory = value
  elseif value ~= nil then
    return nil, api_error("invalid_argument", "location must be a table or a directory string")
  end
  if type(directory) ~= "string" or directory == "" then
    return nil, api_error("invalid_argument", "location.directory must be a non-empty string")
  end
  return { directory = directory }
end

---@param source table
---@param names string[]
---@return table|nil fields
---@return table|nil err
local function collect_fields(source, names)
  local fields = {}
  for _, name in ipairs(names) do
    local value = source[name]
    if value ~= nil then
      local kind = type(value)
      if kind ~= "string" and kind ~= "number" then
        return nil, api_error("invalid_argument", name .. " must be a string or number")
      end
      fields[name] = value
    end
  end
  return fields
end

---@param source table
---@param names string[]
---@return table
local function collect_body_fields(source, names)
  local fields = {}
  for _, name in ipairs(names) do
    if source[name] ~= nil then
      fields[name] = source[name]
    end
  end
  return fields
end

---@param body table|nil
---@return string|nil encoded
---@return table|nil err
local function encode_body(body)
  if body == nil then
    return nil
  end
  local ok, encoded = pcall(vim.json.encode, body)
  if not ok then
    return nil, api_error("invalid_argument", "could not encode request body: " .. tostring(encoded))
  end
  return encoded
end

---@param client table
---@param spec table
---@param callback function
---@param accept string
---@return fun()|nil cancel
---@return table|nil err
local function perform(client, spec, callback, accept)
  if type(callback) ~= "function" then
    return nil, api_error("invalid_argument", "callback must be a function")
  end

  local encoded, encode_err = encode_body(spec.body)
  if encode_err then
    return nil, encode_err
  end

  local headers = merge_headers({ Accept = accept }, client._headers)
  if encoded ~= nil then
    headers = merge_headers({ ["Content-Type"] = "application/json" }, headers)
  end

  local opts = {
    method = spec.method,
    url = build_url(client._url, spec),
    headers = headers,
  }
  if encoded ~= nil then
    opts.body = encoded
  end
  if client._timeout then
    opts.timeout = client._timeout
  end

  local finished = false
  local function finish(err, data, response)
    if finished then
      return
    end
    finished = true
    callback(err, data, response)
  end

  local cancel, start_err = client._transport.request(opts, function(err, response)
    if finished then
      return
    end
    if err then
      finish(transport_error(err), nil, response)
      return
    end
    local response_err, data, raw = parse_response(response)
    finish(response_err, data, raw)
  end)
  if type(cancel) ~= "function" then
    finished = true
    return nil, transport_error(start_err)
  end

  return function()
    if finished then
      return
    end
    finished = true
    cancel()
  end
end

---@param client table
---@param spec table
---@param handlers table
---@param accept string
---@return fun()|nil cancel
---@return table|nil err
local function perform_stream(client, spec, handlers, accept)
  if type(handlers) ~= "table" then
    return nil, api_error("invalid_argument", "stream handlers must be a table")
  end
  for _, name in ipairs({ "on_headers", "on_chunk", "on_done" }) do
    if handlers[name] ~= nil and type(handlers[name]) ~= "function" then
      return nil, api_error("invalid_argument", name .. " must be a function")
    end
  end

  local headers = merge_headers({ Accept = accept }, client._headers)
  local opts = {
    method = spec.method,
    url = build_url(client._url, spec),
    headers = headers,
  }

  local state = {
    response = nil,
    status = nil,
    success = false,
    non_2xx = false,
    pending = {},
    error_parts = {},
    error_size = 0,
    cancelled = false,
    finished = false,
  }

  local function done(err)
    if state.finished or state.cancelled then
      return
    end
    state.finished = true
    if handlers.on_done then
      handlers.on_done(err)
    end
  end

  local function emit_chunk(chunk)
    if handlers.on_chunk then
      handlers.on_chunk(chunk)
    end
  end

  local wrapped = {
    on_headers = function(response)
      if state.finished or state.cancelled then
        return
      end
      state.response = response
      local status = type(response) == "table" and tonumber(response.status) or nil
      state.status = status
      if status and status >= 200 and status <= 299 then
        state.success = true
        if handlers.on_headers then
          handlers.on_headers(response)
        end
        if state.cancelled then
          return
        end
        local pending = state.pending
        state.pending = {}
        for _, chunk in ipairs(pending) do
          emit_chunk(chunk)
        end
      elseif status then
        state.non_2xx = true
        local pending = state.pending
        state.pending = {}
        for _, chunk in ipairs(pending) do
          if state.error_size < MAX_STREAM_ERROR_BODY then
            state.error_parts[#state.error_parts + 1] = chunk
            state.error_size = state.error_size + #chunk
          end
        end
      end
    end,
    on_chunk = function(chunk)
      if state.finished or state.cancelled then
        return
      end
      if state.success then
        emit_chunk(chunk)
      elseif state.non_2xx then
        if state.error_size < MAX_STREAM_ERROR_BODY then
          state.error_parts[#state.error_parts + 1] = chunk
          state.error_size = state.error_size + #chunk
        end
      else
        state.pending[#state.pending + 1] = chunk
      end
    end,
    on_done = function(err)
      if state.finished or state.cancelled then
        return
      end
      if state.non_2xx then
        local response = state.response or { status = state.status }
        response.body = table.concat(state.error_parts)
        done(http_error(response, err))
      elseif err then
        done(transport_error(err))
      elseif not state.status then
        done(api_error("invalid_response", "stream ended without response headers"))
      elseif not state.success then
        done(api_error("invalid_response", "stream response has an invalid status"))
      else
        done(nil)
      end
    end,
  }

  local cancel, start_err = client._transport.stream(opts, wrapped)
  if type(cancel) ~= "function" then
    return nil, transport_error(start_err)
  end

  return function()
    if state.cancelled then
      return
    end
    state.cancelled = true
    if not state.finished then
      cancel()
    end
  end
end

---Create a stateless client.
---@param opts table
---@return table
function M.new(opts)
  if type(opts) ~= "table" then
    error("opencode.client: new() expects a table", 0)
  end

  local transport = opts.transport or require("opencode.net.http")
  if type(transport) ~= "table"
    or type(transport.request) ~= "function"
    or type(transport.stream) ~= "function"
  then
    error("opencode.client: transport must provide request() and stream()", 0)
  end

  local timeout = opts.timeout
  if timeout == nil then
    timeout = DEFAULT_TIMEOUT
  elseif type(timeout) ~= "number" or timeout <= 0 then
    error("opencode.client: timeout must be a positive number", 0)
  end

  local client = {
    _url = normalize_url(opts.url or opts.base_url),
    _headers = validate_headers(opts.headers),
    _transport = transport,
    _timeout = timeout,
  }

  client.info = function(...)
    local args = args_without_self(client, ...)
    return perform(client, v2.info(), args[1], "application/json")
  end

  client.list_sessions = function(...)
    local args = args_without_self(client, ...)
    local opts, callback = args[1], args[2]
    local directory, dir_err = directory_from(opts)
    if dir_err then
      return nil, dir_err
    end
    local filters, filters_err = collect_fields(opts, {
      "limit", "order", "search", "parentID", "project", "subpath", "cursor",
    })
    if filters_err then
      return nil, filters_err
    end
    filters.directory = directory
    return perform(client, v2.list_sessions(filters), callback, "application/json")
  end

  client.create_session = function(...)
    local args = args_without_self(client, ...)
    local opts, callback = args[1], args[2]
    local directory, dir_err = directory_from(opts)
    if dir_err then
      return nil, dir_err
    end
    local location = {}
    if type(opts.location) == "table" then
      for key, value in pairs(opts.location) do
        location[key] = value
      end
    end
    location.directory = directory
    local payload = collect_body_fields(opts, {
      "id", "parentID", "title", "agent", "model", "metadata", "permissions",
    })
    payload.location = location
    return perform(client, v2.create_session(payload), callback, "application/json")
  end

  client.list_messages = function(...)
    local args = args_without_self(client, ...)
    local session_id = validate_session_id(args[1])
    if not session_id then
      return nil, api_error("invalid_argument", "session_id must be a non-empty string")
    end
    local filters, callback
    if type(args[2]) == "function" then
      callback = args[2]
      filters = {}
    else
      filters = args[2] or {}
      callback = args[3]
    end
    if type(filters) ~= "table" then
      return nil, api_error("invalid_argument", "message filters must be a table")
    end
    local query, query_err = collect_fields(filters, { "limit", "order", "cursor", "type" })
    if query_err then
      return nil, query_err
    end
    return perform(client, v2.list_messages(session_id, query), callback, "application/json")
  end

  client.find_files = function(...)
    local args = args_without_self(client, ...)
    local params, callback = args[1], args[2]
    local location, location_err = query_location(params)
    if location_err then
      return nil, location_err
    end
    local text = params.query
    if text == nil then
      text = ""
    end
    if type(text) ~= "string" then
      return nil, api_error("invalid_argument", "find query must be a string")
    end
    local filters = { query = text }
    if params.type ~= nil then
      if params.type ~= "file" and params.type ~= "directory" then
        return nil, api_error("invalid_argument", "find type must be \"file\" or \"directory\"")
      end
      filters.type = params.type
    end
    if params.limit ~= nil then
      local limit = params.limit
      if type(limit) ~= "number" or limit < 1 or limit ~= math.floor(limit) then
        return nil, api_error("invalid_argument", "find limit must be a positive integer")
      end
      filters.limit = limit
    end
    return perform(client, v2.find_files(location, filters), callback, "application/json")
  end

  client.list_files = function(...)
    local args = args_without_self(client, ...)
    local params, callback = args[1], args[2]
    local location, location_err = query_location(params)
    if location_err then
      return nil, location_err
    end
    local filters = {}
    if params.path ~= nil then
      if type(params.path) ~= "string" then
        return nil, api_error("invalid_argument", "file path must be a string")
      end
      if params.path ~= "" then
        filters.path = params.path
      end
    end
    return perform(client, v2.list_files(location, filters), callback, "application/json")
  end

  client.list_commands = function(...)
    local args = args_without_self(client, ...)
    local location, location_err = query_location(args[1])
    if location_err then
      return nil, location_err
    end
    return perform(client, v2.list_commands(location), args[2], "application/json")
  end

  client.list_agents = function(...)
    local args = args_without_self(client, ...)
    local location, location_err = query_location(args[1])
    if location_err then
      return nil, location_err
    end
    return perform(client, v2.list_agents(location), args[2], "application/json")
  end

  client.list_skills = function(...)
    local args = args_without_self(client, ...)
    local location, location_err = query_location(args[1])
    if location_err then
      return nil, location_err
    end
    return perform(client, v2.list_skills(location), args[2], "application/json")
  end

  client.prompt = function(...)
    local args = args_without_self(client, ...)
    local session_id = validate_session_id(args[1])
    if not session_id then
      return nil, api_error("invalid_argument", "session_id must be a non-empty string")
    end
    local params = args[2]
    if type(params) ~= "table" then
      return nil, api_error("invalid_argument", "prompt parameters must be a table")
    end
    if params.text ~= nil and type(params.text) ~= "string" then
      return nil, api_error("invalid_argument", "prompt text must be a string")
    end
    if params.text == nil and params.files == nil and params.agents == nil and params.skills == nil then
      return nil, api_error("invalid_argument", "prompt requires text or an attachment")
    end
    local payload = collect_body_fields(params, {
      "id", "text", "files", "agents", "skills", "metadata", "delivery", "resume",
    })
    return perform(client, v2.prompt(session_id, payload), args[3], "application/json")
  end

  client.command = function(...)
    local args = args_without_self(client, ...)
    local session_id = validate_session_id(args[1])
    if not session_id then
      return nil, api_error("invalid_argument", "session_id must be a non-empty string")
    end
    local params = args[2]
    if type(params) ~= "table" then
      return nil, api_error("invalid_argument", "command parameters must be a table")
    end
    if type(params.name) ~= "string" or params.name == "" then
      return nil, api_error("invalid_argument", "command name must be a non-empty string")
    end
    if params.text ~= nil and type(params.text) ~= "string" then
      return nil, api_error("invalid_argument", "command text must be a string")
    end
    local payload = collect_body_fields(params, { "name", "text", "files", "agents", "skills", "delivery" })
    return perform(client, v2.command(session_id, payload), args[3], "application/json")
  end

  client.interrupt = function(...)
    local args = args_without_self(client, ...)
    local session_id = validate_session_id(args[1])
    if not session_id then
      return nil, api_error("invalid_argument", "session_id must be a non-empty string")
    end
    local opts, callback = args[2], args[3]
    if type(opts) == "function" then
      callback = opts
      opts = {}
    end
    opts = opts or {}
    if type(opts) ~= "table" then
      return nil, api_error("invalid_argument", "interrupt options must be a table")
    end
    local query = {}
    if opts.resume ~= nil then
      if type(opts.resume) ~= "boolean" then
        return nil, api_error("invalid_argument", "interrupt resume must be a boolean")
      end
      query.resume = opts.resume
    end
    return perform(client, v2.interrupt(session_id, query), callback, "application/json")
  end

  client.stream_events = function(...)
    local args = args_without_self(client, ...)
    local opts, handlers = args[1], args[2]
    if handlers == nil and type(opts) == "table" and (opts.on_headers or opts.on_chunk or opts.on_done) then
      handlers = opts
      opts = {}
    end
    opts = opts or {}
    if type(opts) ~= "table" then
      return nil, api_error("invalid_argument", "stream options must be a table")
    end

    local filters = {}
    if opts.types ~= nil then
      if type(opts.types) == "string" then
        if opts.types ~= "" then
          filters.types = opts.types
        end
      elseif type(opts.types) == "table" then
        local types = {}
        for _, value in ipairs(opts.types) do
          if type(value) ~= "string" or value == "" then
            return nil, api_error("invalid_argument", "event types must be non-empty strings")
          end
          types[#types + 1] = value
        end
        if #types > 0 then
          filters.types = types
        end
      else
        return nil, api_error("invalid_argument", "event types must be a string or list of strings")
      end
    end

    return perform_stream(client, v2.stream_events(filters), handlers, "text/event-stream")
  end

  return client
end

---Build a client from the active plugin configuration.
---
---The module-level methods below use this helper so callers that already own
---session/project state (for example opencode.session) can use the module as a
---client without constructing an instance themselves.  No session or project
---state is retained here; only the configured server URL and headers are read.
---@return table
function M.from_config()
  local config = require("opencode").get_config()
  return M.new({
    url = config.server.url,
    headers = config.server.headers,
  })
end

local function delegate(name)
  return function(...)
    local args = args_without_self(M, ...)
    local client = M.from_config()
    return client[name](unpack(args))
  end
end

M.info = delegate("info")
M.list_sessions = delegate("list_sessions")
M.create_session = delegate("create_session")
M.list_messages = delegate("list_messages")
M.find_files = delegate("find_files")
M.list_files = delegate("list_files")
M.list_commands = delegate("list_commands")
M.list_agents = delegate("list_agents")
M.list_skills = delegate("list_skills")
M.prompt = delegate("prompt")
M.command = delegate("command")
M.interrupt = delegate("interrupt")
M.stream_events = delegate("stream_events")

return M
