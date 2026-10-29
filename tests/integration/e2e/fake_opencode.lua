-- Minimal OpenCode V2-compatible HTTP server used by the isolated e2e wiring
-- tests. It implements only the routes exercised by the client/session/sync
-- stack and records every request so tests can assert routing.
--
-- This is test-only code. It binds 127.0.0.1 on an ephemeral port, never reads
-- user configuration and is always stopped by its owning test process.

local uv = vim.uv or vim.loop

local M = {}

local function send(socket, status, body, headers)
  local lines = {
    "HTTP/1.1 " .. tostring(status) .. " " .. (status == 200 and "OK" or "Error"),
    "Content-Type: application/json",
    "Content-Length: " .. tostring(#body),
    "Connection: close",
  }
  for name, value in pairs(headers or {}) do
    lines[#lines + 1] = name .. ": " .. value
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = body
  local payload = table.concat(lines, "\r\n")
  socket:write(payload, function()
    if not socket:is_closing() then
      socket:close()
    end
  end)
end

local function json(socket, value)
  send(socket, 200, vim.json.encode(value))
end

local function location_of(server)
  return { directory = server.root }
end

local function emit(server, event)
  local payload = "data: " .. vim.json.encode(event) .. "\n\n"
  for socket in pairs(server.streams) do
    if not socket:is_closing() then
      socket:write(payload)
    end
  end
end

local function handle(server, socket, request)
  local method = request.method
  local path = request.path
  local body = {}
  if request.body ~= "" then
    local ok, decoded = pcall(vim.json.decode, request.body)
    if ok and type(decoded) == "table" then
      body = decoded
    end
  end
  server.requests[#server.requests + 1] = {
    method = method,
    path = path,
    body = body,
    query = request.target,
  }

  if method == "GET" and path == "/api/event" then
    socket:write(
      "HTTP/1.1 200 OK\r\n"
        .. "Content-Type: text/event-stream\r\n"
        .. "Cache-Control: no-store\r\n"
        .. "Connection: keep-alive\r\n\r\n"
    )
    server.streams[socket] = true
    return
  end

  if method == "GET" and path == "/api/session" then
    json(socket, { location = location_of(server), data = server.sessions })
    return
  end
  if method == "POST" and path == "/api/session" then
    server.create_count = server.create_count + 1
    local id = "ses_test_" .. tostring(server.create_count)
    local session = { id = id, location = location_of(server), title = "Test session " .. id }
    server.sessions[#server.sessions + 1] = session
    server.current_session = session
    json(socket, { data = session })
    return
  end
  if method == "GET" and path:match("^/api/session/[^/]+/message$") then
    json(socket, { location = location_of(server), data = server.messages })
    return
  end
  if method == "POST" and path:match("^/api/session/[^/]+/prompt$") then
    server.prompt_count = server.prompt_count + 1
    server.prompts[#server.prompts + 1] = body
    local message_id = "msg_" .. tostring(server.prompt_count)
    server.messages[#server.messages + 1] = {
      info = {
        id = message_id,
        sessionID = server.current_session and server.current_session.id,
        role = "user",
        time = { created = os.time() },
      },
      parts = {
        {
          id = "part_" .. tostring(server.prompt_count),
          messageID = message_id,
          sessionID = server.current_session and server.current_session.id,
          type = "text",
          text = body.text or "",
        },
      },
    }
    emit(server, {
      type = "message.updated",
      properties = {
        info = server.messages[#server.messages].info,
      },
    })
    emit(server, {
      type = "message.part.updated",
      properties = {
        part = server.messages[#server.messages].parts[1],
      },
    })
    json(socket, { data = { accepted = true } })
    return
  end
  if method == "POST" and path:match("^/api/session/[^/]+/command$") then
    server.command_count = server.command_count + 1
    server.commands[#server.commands + 1] = body
    json(socket, { data = { accepted = true } })
    return
  end
  if method == "POST" and path:match("^/api/session/[^/]+/interrupt$") then
    server.interrupt_count = server.interrupt_count + 1
    server.interrupts[#server.interrupts + 1] = {
      path = path,
      query = request.target,
    }
    json(socket, { data = { interrupted = server.interrupt_result or false } })
    return
  end
  if method == "GET" and path == "/api/command" then
    json(socket, {
      location = location_of(server),
      data = {
        { name = "smoke", description = "Smoke command" },
      },
    })
    return
  end
  if method == "GET" and path == "/api/agent" then
    json(socket, {
      location = location_of(server),
      data = {
        { id = "build", name = "build", description = "Build agent" },
      },
    })
    return
  end
  if method == "GET" and path == "/api/skill" then
    json(socket, {
      location = location_of(server),
      data = {
        { id = "review", name = "review", description = "Review skill" },
      },
    })
    return
  end
  if method == "GET" and path == "/api/fs/find" then
    json(socket, {
      location = location_of(server),
      data = {
        { path = "src/sample.lua", type = "file" },
      },
    })
    return
  end
  if method == "GET" and path == "/api/info" then
    json(socket, { data = { version = "test" } })
    return
  end

  send(socket, 404, vim.json.encode({ error = { type = "not_found", message = path } }))
end

local function parse_request(buffer)
  local header_end = buffer:find("\r\n\r\n", 1, true)
  if not header_end then
    return nil
  end
  local head = buffer:sub(1, header_end - 1)
  local method, target = head:match("^(%u+)%s+(%S+)%s+HTTP/")
  if not method or not target then
    return nil
  end
  local headers = {}
  for line in head:gmatch("[^\r\n]+") do
    local name, value = line:match("^([^:]+):%s*(.*)$")
    if name then
      headers[name:lower()] = value
    end
  end
  local length = tonumber(headers["content-length"] or "0") or 0
  local body_start = header_end + 4
  if #buffer < body_start - 1 + length then
    return nil
  end
  return {
    method = method,
    target = target,
    path = target:match("^([^?]*)") or target,
    body = buffer:sub(body_start, body_start + length - 1),
  }, body_start + length - 1
end

--- Start the fake service.
--- @param opts table { root = string }
--- @return table server
function M.start(opts)
  opts = opts or {}
  local server = {
    root = vim.fs.normalize(opts.root or vim.fn.getcwd()),
    requests = {},
    sessions = {},
    messages = {},
    prompts = {},
    commands = {},
    interrupts = {},
    streams = {},
    connections = {},
    create_count = 0,
    prompt_count = 0,
    command_count = 0,
    interrupt_count = 0,
    interrupt_result = false,
    state = "idle",
  }
  local listener = uv.new_tcp()
  assert(listener:bind("127.0.0.1", 0), "fake OpenCode server failed to bind")
  local address = listener:getsockname()
  server.port = address.port
  server.url = "http://127.0.0.1:" .. tostring(server.port)
  server.listener = listener
  server.state = "running"
  listener:listen(128, function(err)
    if err or server.state ~= "running" then
      return
    end
    local socket = uv.new_tcp()
    if not listener:accept(socket) then
      socket:close()
      return
    end
    local connection = { buffer = "", socket = socket }
    server.connections[socket] = connection
    socket:read_start(function(read_err, chunk)
      if read_err or not chunk then
        server.connections[socket] = nil
        if not socket:is_closing() then
          socket:close()
        end
        return
      end
      connection.buffer = connection.buffer .. chunk
      local request, consumed = parse_request(connection.buffer)
      if request then
        connection.buffer = connection.buffer:sub(consumed + 1)
        handle(server, socket, request)
      end
    end)
  end)

  function server.stop()
    if server.state == "stopped" then
      return
    end
    server.state = "stopped"
    pcall(listener.close, listener)
    for socket in pairs(server.streams) do
      if not socket:is_closing() then
        socket:close()
      end
    end
    server.streams = {}
    for socket in pairs(server.connections) do
      if not socket:is_closing() then
        socket:close()
      end
    end
    server.connections = {}
  end

  function server.emit(event)
    emit(server, event)
  end

  return server
end

return M
