-- 09A server unit/integration tests (real loopback HTTP, isolated process).

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":h:h:h:h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local T = dofile(root .. "/tests/unit/tools/server/helper.lua")
local server_mod = require("opencode.tools.server")
local protocol = require("opencode.tools.protocol")

local TOKEN = "unit-secret-token-0123456789"

local function temp_project()
  return T.tempdir("project")
end

local function new_server(opts)
  opts = opts or {}
  opts.token = TOKEN
  opts.instance_id = opts.instance_id or string.format("test-%x", vim.uv.hrtime())
  opts.project_root = opts.project_root or temp_project()
  local server = server_mod.new(opts)
  local info
  server:start(function(err, value)
    assert(not err, tostring(err))
    info = value
  end)
  assert(info, "server did not start")
  return server, info
end

local function with_server(opts, fn)
  local server, info = new_server(opts)
  local ok, err = pcall(fn, server, info)
  server:stop()
  if not ok then
    error(err, 0)
  end
end

local function body_for(action, input, extra)
  local value = {
    version = 1,
    request_id = "req-1",
    action = action,
    input = input or {},
  }
  for key, item in pairs(extra or {}) do
    value[key] = item
  end
  return value
end

local function post(info, action, value, token)
  return T.request(info.port, {
    method = "POST",
    path = "/tools/" .. action,
    token = token or TOKEN,
    body = value,
  })
end

T.test("health and tool routes require the bearer token", function()
  with_server({}, function(_, info)
    local res = T.request(info.port, { path = "/health" })
    T.eq(401, res.status, "health without token")
    T.eq("UNAUTHORIZED", res.json.error.code)
    T.not_contains(res.body, TOKEN, "token leaked in unauthenticated response")

    res = T.request(info.port, { path = "/health", token = "wrong-token" })
    T.eq(401, res.status, "health with wrong token")
    T.eq(false, res.json.ok)

    res = T.request(info.port, {
      method = "POST",
      path = "/tools/open",
      token = "wrong-token",
      body = body_for("open", { path = "a.txt" }),
    })
    T.eq(401, res.status, "tool with wrong token")
    T.eq("UNAUTHORIZED", res.json.error.code)

    res = T.request(info.port, { path = "/health", token = TOKEN })
    T.eq(200, res.status)
    T.eq(true, res.json.ok)
    T.eq(info.instance_id, res.json.result.instance_id)
    T.eq("ok", res.json.result.status)
    T.not_contains(res.body, TOKEN, "token leaked in health response")
  end)
end)

T.test("authenticated handler success maps to the success envelope", function()
  local seen
  with_server({
    handlers = {
      open = function(input, ctx)
        seen = { input = input, ctx = ctx }
        return { opened = input.path, echo = TOKEN, pid = vim.uv.os_getpid() }
      end,
    },
  }, function(_, info)
    local res = post(info, "open", body_for("open", { path = "lua/init.lua" }))
    T.eq(200, res.status)
    T.eq(true, res.json.ok)
    T.eq(1, res.json.version)
    T.eq("req-1", res.json.request_id)
    T.eq("lua/init.lua", res.json.result.opened)
    T.eq("lua/init.lua", seen.input.path, "handler receives input")
    T.eq("req-1", seen.ctx.request_id)
    T.eq(info.instance_id, seen.ctx.instance_id)
    T.not_contains(res.body, TOKEN, "token leaked in success response")
    T.contains(res.body, "<redacted>")
  end)
end)

T.test("missing or malformed credentials are rejected on every route", function()
  with_server({
    handlers = { open = function() return {} end },
  }, function(_, info)
    local res = T.request(info.port, {
      method = "POST",
      path = "/tools/open",
      body = body_for("open", {}),
    })
    T.eq(401, res.status, "tool without token")
    T.eq("UNAUTHORIZED", res.json.error.code)
    T.not_contains(res.body, TOKEN)

    res = T.request(info.port, {
      method = "POST",
      path = "/tools/open",
      headers = { "Authorization: " .. TOKEN },
      body = body_for("open", {}),
    })
    T.eq(401, res.status, "token without bearer scheme")
    T.eq("UNAUTHORIZED", res.json.error.code)

    res = T.request(info.port, { path = "/unknown" })
    T.eq(401, res.status, "unknown route without token")
    T.eq("UNAUTHORIZED", res.json.error.code)
  end)
end)

T.test("handler failure, thrown errors and async responders are normalized", function()
  with_server({
    handlers = {
      notify = function(input, ctx)
        if input.mode == "error" then
          return nil, { code = "ACTION_FAILED", message = "bad " .. TOKEN }
        end
        if input.mode == "throw" then
          error("handler exploded with " .. TOKEN)
        end
        if input.mode == "async" then
          vim.defer_fn(function()
            ctx.respond({ delivered = true })
          end, 10)
          return nil
        end
        return { delivered = true }
      end,
    },
  }, function(_, info)
    local res = post(info, "notify", body_for("notify", { mode = "error" }))
    T.eq(422, res.status)
    T.eq("ACTION_FAILED", res.json.error.code)
    T.not_contains(res.body, TOKEN, "handler failure must not leak token")
    T.contains(res.body, "<redacted>")

    res = post(info, "notify", body_for("notify", { mode = "throw" }))
    T.eq(500, res.status)
    T.eq("INTERNAL_ERROR", res.json.error.code)
    T.eq("action failed", res.json.error.message)
    T.not_contains(res.body, TOKEN)

    res = post(info, "notify", body_for("notify", { mode = "async" }))
    T.eq(200, res.status)
    T.eq(true, res.json.result.delivered)
  end)
end)

T.test("handler error details are scrubbed before serialization", function()
  with_server({
    handlers = {
      notify = function()
        return nil, {
          code = "ACTION_FAILED",
          message = "cannot notify",
          details = { token = TOKEN, nested = { value = TOKEN } },
        }
      end,
    },
  }, function(_, info)
    local res = post(info, "notify", body_for("notify", {}))
    T.eq(422, res.status)
    T.eq("ACTION_FAILED", res.json.error.code)
    T.not_contains(res.body, TOKEN, "token leaked through error details")
    T.contains(res.body, "<redacted>")
  end)
end)

T.test("logs and info never expose the token", function()
  local logs = {}
  with_server({
    logger = function(level, message)
      logs[#logs + 1] = tostring(level) .. ":" .. tostring(message)
    end,
    handlers = {
      notify = function()
        return nil, { code = "ACTION_FAILED", message = "bad " .. TOKEN }
      end,
    },
  }, function(server, info)
    T.assert(server:info(), "server has info")
    T.eq(nil, server:info().token, "info must not expose the token")
    local res = post(info, "notify", body_for("notify", {}))
    T.eq(422, res.status)
    T.not_contains(table.concat(logs, "\n"), TOKEN, "logs leaked the token")
  end)
end)

T.test("handler timeout returns TIMEOUT and ignores a late response", function()
  local late = false
  with_server({
    limits = { handler_timeout = 100 },
    handlers = {
      notify = function(_, ctx)
        vim.defer_fn(function()
          ctx.respond({ late = true })
          late = true
        end, 250)
      end,
    },
  }, function(_, info)
    local res = post(info, "notify", body_for("notify", {}))
    T.eq(504, res.status)
    T.eq("TIMEOUT", res.json.error.code)
    T.assert(
      T.wait_for(function()
        return late
      end, 1500),
      "late responder was not invoked"
    )
    res = T.request(info.port, { path = "/health", token = TOKEN })
    T.eq(200, res.status, "server survives handler timeouts")
  end)
end)

T.test("async handler via ctx.respond completes exactly once", function()
  with_server({
    handlers = {
      diff = function(_, ctx)
        vim.defer_fn(function()
          ctx.respond({ shown = true })
          ctx.respond({ shown = "late" })
        end, 10)
      end,
    },
  }, function(_, info)
    local res = post(info, "diff", body_for("diff", { text = "x" }))
    T.eq(200, res.status)
    T.eq(true, res.json.result.shown)
  end)
end)

T.test("invalid JSON and malformed envelopes return structured errors", function()
  with_server({
    handlers = { open = function() return {} end },
  }, function(_, info)
    local res = T.request(info.port, {
      method = "POST",
      path = "/tools/open",
      token = TOKEN,
      body = "{not json",
    })
    T.eq(400, res.status)
    T.eq("INVALID_JSON", res.json.error.code)

    res = post(info, "open", body_for("open", {}, { version = 99 }))
    T.eq(400, res.status)
    T.eq("INVALID_REQUEST", res.json.error.code)
    T.eq("req-1", res.json.request_id, "failure echoes a usable request_id")

    res = post(info, "open", body_for("open", {}, { request_id = "" }))
    T.eq(400, res.status)
    T.eq("INVALID_REQUEST", res.json.error.code)
    T.eq(nil, res.json.request_id)

    res = post(info, "open", body_for("notify", {}))
    T.eq(400, res.status)
    T.eq("INVALID_REQUEST", res.json.error.code)
    T.eq("req-1", res.json.request_id)

    res = post(info, "open", "null")
    T.eq(400, res.status)
    T.eq("INVALID_REQUEST", res.json.error.code)
  end)
end)

T.test("handlers can be injected, replaced and removed at runtime", function()
  with_server({}, function(server, info)
    local res = post(info, "open", body_for("open", {}))
    T.eq(404, res.status, "no handler before injection")

    server:register_handler("open", function()
      return { revision = 1 }
    end)
    res = post(info, "open", body_for("open", {}))
    T.eq(200, res.status)
    T.eq(1, res.json.result.revision)

    server:register_handler("open", function()
      return { revision = 2 }
    end)
    res = post(info, "open", body_for("open", {}))
    T.eq(200, res.status)
    T.eq(2, res.json.result.revision)

    server:unregister_handler("open")
    res = post(info, "open", body_for("open", {}))
    T.eq(404, res.status, "handler removed")
  end)
end)

T.test("unknown routes, methods, and missing handlers are rejected", function()
  with_server({}, function(_, info)
    local res = T.request(info.port, { path = "/nope", token = TOKEN })
    T.eq(404, res.status)
    T.eq("NOT_FOUND", res.json.error.code)

    res = T.request(info.port, { path = "/tools/open", token = TOKEN })
    T.eq(405, res.status)
    T.eq("METHOD_NOT_ALLOWED", res.json.error.code)

    res = T.request(info.port, { method = "POST", path = "/health", token = TOKEN, body = "{}" })
    T.eq(405, res.status)

    res = post(info, "open", body_for("open", {}))
    T.eq(404, res.status)
    T.eq("NOT_FOUND", res.json.error.code)
  end)
end)

T.test("body and header size limits are enforced", function()
  with_server({
    limits = { max_body_bytes = 64, max_header_bytes = 256 },
    handlers = { open = function() return {} end },
  }, function(_, info)
    local big = string.rep("x", 200)
    local res = post(info, "open", { version = 1, request_id = "r", action = "open", input = big })
    T.eq(413, res.status)
    T.eq("PAYLOAD_TOO_LARGE", res.json.error.code)

    res = T.request(info.port, {
      path = "/health",
      token = TOKEN,
      headers = { "X-Big: " .. string.rep("a", 400) },
    })
    T.eq(431, res.status)
    T.eq("HEADERS_TOO_LARGE", res.json.error.code)
  end)
end)

T.test("duplicate/conflicting headers and unsupported transfer encoding are rejected", function()
  with_server({
    handlers = { open = function() return {} end },
  }, function(_, info)
    local body = vim.json.encode(body_for("open", {}))
    local res = T.request(info.port, {
      method = "POST",
      path = "/tools/open",
      token = TOKEN,
      body = body,
      no_content_length = true,
      headers = {
        "Content-Length: " .. tostring(#body),
        "Content-Length: " .. tostring(#body),
      },
    })
    T.eq(400, res.status)
    T.eq("INVALID_HEADER", res.json.error.code)

    res = T.request(info.port, {
      path = "/health",
      token = TOKEN,
      headers = { "Authorization: Bearer " .. TOKEN },
    })
    T.eq(400, res.status)
    T.eq("INVALID_HEADER", res.json.error.code)

    res = T.request(info.port, {
      method = "POST",
      path = "/tools/open",
      token = TOKEN,
      body = body,
      headers = { "Transfer-Encoding: chunked" },
    })
    T.eq(400, res.status)
    T.eq("INVALID_REQUEST", res.json.error.code)
  end)
end)

T.test("half packets are buffered until the request is complete", function()
  with_server({
    handlers = { open = function(input) return { ok = input.value } end },
  }, function(_, info)
    local body = vim.json.encode(body_for("open", { value = 42 }))
    local raw = table.concat({
      "POST /tools/open HTTP/1.1",
      "Host: 127.0.0.1:" .. tostring(info.port),
      "Authorization: Bearer " .. TOKEN,
      "Content-Length: " .. tostring(#body),
      "Connection: close",
      "",
      body,
    }, "\r\n")
    local cut = math.floor(#raw / 2)
    local res = T.exchange(info.port, { raw:sub(1, cut), raw:sub(cut + 1) }, { delay = 20 })
    T.assert(res, "no response for split request")
    T.eq(200, res.status)
    T.eq(42, res.json.result.ok)
  end)
end)

T.test("the connection limit rejects excess connections with SERVER_BUSY", function()
  with_server({
    limits = { max_connections = 1, header_timeout = 5000 },
    handlers = { open = function() return {} end },
  }, function(_, info)
    local idle = vim.uv.new_tcp()
    local connected = false
    idle:connect("127.0.0.1", info.port, function(err)
      if not err then
        connected = true
      end
    end)
    T.assert(T.wait_for(function()
      return connected
    end, 1000), "idle connection was not established")
    vim.wait(50)

    local res = T.request(info.port, { path = "/health", token = TOKEN })
    T.eq(503, res.status)
    T.eq("SERVER_BUSY", res.json.error.code)

    idle:close()
    res = T.request(info.port, { path = "/health", token = TOKEN })
    T.eq(200, res.status, "server accepts requests after the idle peer leaves")
  end)
end)

T.test("bodies split across packets are reassembled", function()
  with_server({
    handlers = { open = function(input) return { ok = input.value } end },
  }, function(_, info)
    local body = vim.json.encode(body_for("open", { value = 42 }))
    local raw = table.concat({
      "POST /tools/open HTTP/1.1",
      "Host: 127.0.0.1:" .. tostring(info.port),
      "Authorization: Bearer " .. TOKEN,
      "Content-Length: " .. tostring(#body),
      "Connection: close",
      "",
      body,
    }, "\r\n")
    local body_start = #raw - #body + 1
    local res = T.exchange(info.port, {
      raw:sub(1, body_start - 1),
      raw:sub(body_start, body_start + 4),
      raw:sub(body_start + 5),
    }, { delay = 15 })
    T.assert(res, "no response for split body")
    T.eq(200, res.status)
    T.eq(42, res.json.result.ok)
  end)
end)

T.test("slow header writes time out and do not wedge the server", function()
  with_server({ limits = { header_timeout = 120 } }, function(_, info)
    local res = T.exchange(info.port, { "GET /health HTTP/1.1\r\nHost: x\r\n" }, { timeout = 2000 })
    T.assert(res, "no timeout response")
    T.eq(408, res.status)
    T.eq("SLOW_CONNECTION", res.json.error.code)

    res = T.request(info.port, { path = "/health", token = TOKEN })
    T.eq(200, res.status, "server still accepts requests")
  end)
end)

T.test("slow body writes time out with a structured error", function()
  with_server({ limits = { body_timeout = 120 } }, function(_, info)
    local body = vim.json.encode(body_for("open", {}))
    local head = table.concat({
      "POST /tools/open HTTP/1.1",
      "Host: 127.0.0.1:" .. tostring(info.port),
      "Authorization: Bearer " .. TOKEN,
      "Content-Length: " .. tostring(#body),
      "Connection: close",
      "",
      "",
    }, "\r\n")
    local res = T.exchange(info.port, { head .. body:sub(1, 1) }, { timeout = 2000 })
    T.assert(res, "no timeout response")
    T.eq(408, res.status)
    T.eq("SLOW_CONNECTION", res.json.error.code)

    res = T.request(info.port, { path = "/health", token = TOKEN })
    T.eq(200, res.status)
  end)
end)

T.test("abrupt disconnects do not affect subsequent requests", function()
  with_server({}, function(_, info)
    local result, err = T.exchange(info.port, {
      "POST /tools/open HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer " .. TOKEN .. "\r\n",
    }, { abort_after = 1 })
    T.eq(nil, result)
    T.eq("aborted", err)

    local res = T.request(info.port, { path = "/health", token = TOKEN })
    T.eq(200, res.status)
  end)
end)

T.test("concurrent requests are all answered", function()
  with_server({
    handlers = {
      open = function(input) return { value = input.value } end,
    },
  }, function(_, info)
    local uv = vim.uv
    local pending = 8
    local results = {}
    local body = vim.json.encode(body_for("open", { value = 7 }))
    local raw = table.concat({
      "POST /tools/open HTTP/1.1",
      "Host: 127.0.0.1:" .. tostring(info.port),
      "Authorization: Bearer " .. TOKEN,
      "Content-Length: " .. tostring(#body),
      "Connection: close",
      "",
      body,
    }, "\r\n")
    for i = 1, 8 do
      local idx = i
      local socket = uv.new_tcp()
      local buffer = ""
      socket:connect("127.0.0.1", info.port, function()
        socket:write(raw)
      end)
      socket:read_start(function(err, chunk)
        if err then
          results[idx] = { err = err }
          return
        end
        if not chunk then
          local status = tonumber(buffer:match("^HTTP/1%.[01] (%d%d%d)"))
          results[idx] = { status = status, body = buffer }
          pending = pending - 1
          socket:close()
          return
        end
        buffer = buffer .. chunk
      end)
    end
    T.assert(T.wait_for(function()
      return pending == 0
    end, 3000), "concurrent requests timed out")
    for i = 1, #results do
      T.eq(200, results[i].status, "request " .. i)
      T.contains(results[i].body, '"value":7')
    end
  end)
end)

T.test("start and stop are idempotent, and restart works", function()
  local server = server_mod.new({
    token = TOKEN,
    instance_id = "lifecycle-1",
    project_root = temp_project(),
    handlers = { open = function() return {} end },
  })
  local first
  server:start(function(err, info)
    T.eq(nil, err)
    first = info
  end)
  T.assert(first and first.url, "no URL on first start")
  server:start(function(err, info)
    T.eq(nil, err)
    T.eq(first.url, info.url, "start is idempotent")
  end)
  local res = T.request(first.port, { path = "/health", token = TOKEN })
  T.eq(200, res.status)

  server:stop()
  server:stop()
  T.eq(false, server:is_running())

  local second
  server:start(function(err, info)
    T.eq(nil, err)
    second = info
  end)
  T.assert(second and second.url, "restart failed")
  res = T.request(second.port, { path = "/health", token = TOKEN })
  T.eq(200, res.status)
  server:stop()
end)

T.test("VimLeavePre cleanup stops the listener", function()
  local server, info = new_server({ instance_id = "exit-handler" })
  T.eq(true, server:is_running())
  local ok, err = pcall(vim.api.nvim_exec_autocmds, "VimLeavePre", {
    group = "OpencodeNvimToolServer_exit-handler",
  })
  server:stop()
  T.assert(ok, tostring(err))
  T.eq(false, server:is_running())
  local res = T.request(info.port, { path = "/health", token = TOKEN, timeout = 500 })
  T.eq(nil, res, "listener closed on VimLeavePre")
end)

T.test("module-level singleton start/stop is idempotent", function()
  local project = temp_project()
  local first
  server_mod.start({
    token = TOKEN,
    instance_id = "singleton-1",
    project_root = project,
  }, function(err, info)
    T.eq(nil, err)
    first = info
  end)
  local second
  server_mod.start({ token = "ignored", project_root = project }, function(err, info)
    T.eq(nil, err)
    second = info
  end)
  T.eq(first.url, second.url)
  server_mod.stop()
  server_mod.stop()
  T.eq(nil, server_mod.get())
end)

T.test("protocol helpers validate envelopes and bearer tokens", function()
  T.eq("open", protocol.action_for_path("/tools/open"))
  T.eq(nil, protocol.action_for_path("/tools/unknown"))
  T.eq(nil, protocol.action_for_path("/health"))
  T.eq(true, protocol.check_bearer("Bearer " .. TOKEN, TOKEN))
  T.eq(false, protocol.check_bearer("Bearer wrong", TOKEN))
  T.eq(false, protocol.check_bearer("Basic " .. TOKEN, TOKEN))
  T.eq(false, protocol.check_bearer("Bearer ", TOKEN))

  local request, err = protocol.parse_request(body_for("open", { path = "a" }), "open")
  T.assert(request, tostring(err))
  T.eq("a", request.input.path)

  request, err = protocol.parse_request(body_for("open", {}), "notify")
  T.eq(nil, request)
  T.eq("INVALID_REQUEST", err.code)

  request = protocol.parse_request({ version = 1, request_id = "r", action = "open" }, "open")
  T.assert(request)
  T.eq("table", type(request.input))

  local ok = protocol.ok({ value = 1 }, "r")
  T.eq(true, ok.ok)
  local fail = protocol.fail("NOT_FOUND", "missing", "r")
  T.eq(false, fail.ok)
  T.eq("NOT_FOUND", fail.error.code)

  local normalized = protocol.normalize_error("plain failure")
  T.eq("ACTION_FAILED", normalized.code)
  T.eq("plain failure", normalized.message)

  T.eq(503, protocol.status_for_code("SERVER_BUSY"))
  T.eq(504, protocol.status_for_code("TIMEOUT"))
end)

local shared_test = package.loaded["tests.support.test"]
if shared_test then
  T.run_shared(shared_test)
else
  T.run()
end
