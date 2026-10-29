local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local t = dofile(root .. "/tests/unit/net/support.lua")
local http = require("opencode.net.http")

local function completed_request(opts)
  local state = {
    done = false,
    count = 0,
    err = nil,
    response = nil,
  }
  local cancel, start_err = http.request(opts, function(err, response)
    state.count = state.count + 1
    state.done = true
    state.err = err
    state.response = response
  end)
  t.truthy(cancel, "cancel function")
  t.eq(start_err, nil, "start error")
  return state, cancel
end

local function wait_done(state, timeout)
  t.wait(function()
    return state.done
  end, timeout or 2000, "request callback")
end

t.test("GET sends request line, Host and custom headers", function()
  local seen
  local srv = t.server(function(client, request)
    seen = request
    local body = "ok"
    client:write("HTTP/1.1 200 OK\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body)
  end)
  local state = completed_request({
    method = "GET",
    url = "http://127.0.0.1:" .. srv.port .. "/api/info?x=1",
    headers = { ["X-Test"] = "yes", Accept = "application/json" },
  })
  wait_done(state)
  t.eq(state.err, nil, "error")
  t.eq(state.count, 1)
  t.eq(state.response.status, 200)
  t.eq(state.response.body, "ok")
  t.eq(state.response.headers["content-length"], "2")
  t.matches(seen.head, "^GET /api/info%?x=1 HTTP/1%.1\r\n")
  t.matches(seen.head, "\r\nHost: 127%.0%.0%.1:" .. srv.port .. "\r\n")
  t.matches(seen.head, "\r\nX%-Test: yes\r\n")
  t.matches(seen.head, "\r\nAccept: application/json\r\n")
  t.matches(seen.head, "\r\nConnection: close\r\n")
end)

t.test("POST sends Content-Length and body", function()
  local seen
  local srv = t.server(function(client, request)
    seen = request
    client:write("HTTP/1.1 201 Created\r\nContent-Length: 7\r\n\r\ncreated")
  end)
  local state = completed_request({
    method = "post",
    url = "http://127.0.0.1:" .. srv.port .. "/api/session",
    headers = { ["Content-Type"] = "application/json" },
    body = '{"a":1}',
  })
  wait_done(state)
  t.eq(state.err, nil)
  t.eq(state.response.status, 201)
  t.eq(state.response.body, "created")
  t.matches(seen.head, "^POST /api/session HTTP/1%.1\r\n")
  t.matches(seen.head, "\r\nContent%-Length: 7\r\n")
  t.eq(seen.body, '{"a":1}')
end)

t.test("non-2xx status and body are preserved", function()
  local srv = t.server(function(client)
    client:write("HTTP/1.1 404 Not Found\r\nContent-Length: 4\r\n\r\nnope")
  end)
  local state = completed_request({ url = "http://127.0.0.1:" .. srv.port .. "/missing" })
  wait_done(state)
  t.eq(state.err, nil)
  t.eq(state.response.status, 404)
  t.eq(state.response.status_text, "Not Found")
  t.eq(state.response.body, "nope")
end)

t.test("response fragmented at arbitrary positions", function()
  local srv = t.server(function(client)
    t.write_parts(client, {
      "HTTP/1.1 200 OK\r\nContent-Le",
      "ngth: 11\r\nContent-Ty",
      "pe: text/plain\r\n\r\nhel",
      "lo wor",
      "ld",
    }, 2)
  end)
  local state = completed_request({ url = "http://127.0.0.1:" .. srv.port .. "/" })
  wait_done(state)
  t.eq(state.err, nil)
  t.eq(state.response.body, "hello world")
  t.eq(state.response.headers["content-type"], "text/plain")
end)

t.test("response headers are lowercase", function()
  local srv = t.server(function(client)
    client:write("HTTP/1.1 200 OK\r\nX-MiXeD-Case: Value\r\nContent-Length: 0\r\n\r\n")
  end)
  local state = completed_request({ url = "http://127.0.0.1:" .. srv.port .. "/" })
  wait_done(state)
  t.eq(state.response.headers["x-mixed-case"], "Value")
end)

t.test("timeout returns unified error and cleans up", function()
  local srv = t.server(function() end)
  local state = completed_request({
    url = "http://127.0.0.1:" .. srv.port .. "/slow",
    timeout = 80,
  })
  wait_done(state, 2000)
  t.eq(state.err.code, "timeout")
  t.truthy(state.err.message)
  t.eq(state.response, nil)
  t.cleanup()
  vim.wait(20)
  local counts = t.handle_counts()
  t.eq(counts.timer or 0, 0, "timer handles after timeout")
  t.eq(counts.tcp or 0, 0, "tcp handles after timeout")
end)

t.test("cancel closes socket and timer and is idempotent", function()
  local srv = t.server(function() end)
  local calls = 0
  local cancel = assert(http.request({
    url = "http://127.0.0.1:" .. srv.port .. "/",
    timeout = 5000,
  }, function()
    calls = calls + 1
  end))
  t.wait(function()
    return (t.handle_counts().timer or 0) == 1
  end, 500, "request timer")
  cancel()
  cancel()
  t.wait(function()
    return (t.handle_counts().timer or 0) == 0
  end, 500, "timer handles after cancel")
  t.cleanup()
  vim.wait(20)
  t.eq(t.handle_counts().tcp or 0, 0, "tcp handles after cancel")
  t.eq(calls, 0, "callback after cancel")
end)

t.test("close-delimited response completes when the server closes", function()
  local srv = t.server(function(client)
    client:write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nbody until eof", function()
      client:close()
    end)
  end)
  local state = completed_request({ url = "http://127.0.0.1:" .. srv.port .. "/" })
  wait_done(state)
  t.eq(state.err, nil)
  t.eq(state.response.body, "body until eof")
  t.eq(state.response.headers["content-type"], "text/plain")
end)

t.test("invalid request options fail synchronously", function()
  local function rejection(opts)
    local cancel, req_err = http.request(opts, function() end)
    t.eq(cancel, nil)
    t.truthy(req_err)
    return req_err.code
  end

  t.eq(rejection({
    url = "http://127.0.0.1:1/",
    headers = { ["Bad Header"] = "x" },
  }), "invalid_header")
  t.eq(rejection({
    url = "http://127.0.0.1:1/",
    headers = { ["X-Test"] = "ok\r\nInjected: yes" },
  }), "invalid_header")
  t.eq(rejection({ url = "http://127.0.0.1:1/", body = {} }), "invalid_request")
  t.eq(rejection({ url = "http://127.0.0.1:1/", method = "GE T" }), "invalid_request")
  t.eq(rejection({ url = "http://127.0.0.1:1/", timeout = 0 }), "invalid_request")
end)

t.test("connect error returns unified error", function()
  local srv = t.server(function() end)
  local port = srv.port
  srv.handle:close()
  t.cleanup()
  local state = completed_request({ url = "http://127.0.0.1:" .. port .. "/", timeout = 1000 })
  wait_done(state)
  t.eq(state.err.code, "connect_failed")
end)

t.test("invalid status line is a protocol error", function()
  local srv = t.server(function(client)
    client:write("garbage\r\n\r\n")
  end)
  local state = completed_request({ url = "http://127.0.0.1:" .. srv.port .. "/", timeout = 1000 })
  wait_done(state)
  t.eq(state.err.code, "invalid_status_line")
end)

t.test("premature EOF is a protocol error", function()
  local srv = t.server(function(client)
    client:write("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort", function()
      client:close()
    end)
  end)
  local state = completed_request({ url = "http://127.0.0.1:" .. srv.port .. "/", timeout = 1000 })
  wait_done(state)
  t.eq(state.err.code, "premature_eof")
  t.eq(state.response, nil)
end)

t.test("normal callback fires at most once", function()
  local srv = t.server(function(client)
    client:write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
  end)
  local state = completed_request({ url = "http://127.0.0.1:" .. srv.port .. "/" })
  wait_done(state)
  vim.wait(100)
  t.eq(state.count, 1)
end)

t.test("cancel before response suppresses callback and is idempotent", function()
  local srv = t.server(function() end)
  local count = 0
  local cancel = assert(http.request({ url = "http://127.0.0.1:" .. srv.port .. "/", timeout = 5000 }, function()
    count = count + 1
  end))
  cancel()
  cancel()
  vim.wait(150)
  t.eq(count, 0)
end)

t.test("URL path and query are percent-encoded on the wire", function()
  local seen
  local srv = t.server(function(client, request)
    seen = request
    client:write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
  end)
  local state = completed_request({
    url = "http://127.0.0.1:" .. srv.port .. "/api/a b/ü?q=x y&z=%2F#ignored",
  })
  wait_done(state)
  t.eq(state.err, nil)
  t.matches(seen.head, "^GET /api/a%%20b/%%C3%%BC%?q=x%%20y&z=%%2F HTTP/1%.1\r\n")
end)

t.test("response can be split at every byte", function()
  local raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"
  local srv = t.server(function(client)
    local parts = {}
    for i = 1, #raw do
      parts[i] = raw:sub(i, i)
    end
    t.write_parts(client, parts, 1)
  end)
  local state = completed_request({ url = "http://127.0.0.1:" .. srv.port .. "/" })
  wait_done(state, 3000)
  t.eq(state.err, nil)
  t.eq(state.response.body, "abc")
end)

t.test("hostname is resolved and Host preserves hostname", function()
  local seen
  local srv = t.server(function(client, request)
    seen = request
    client:write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
  end)
  local state = completed_request({ url = "http://localhost:" .. srv.port .. "/" })
  wait_done(state, 3000)
  t.eq(state.err, nil)
  t.matches(seen.head, "\r\nHost: localhost:" .. srv.port .. "\r\n")
end)

t.test("HEAD request ignores declared response body", function()
  local srv = t.server(function(client)
    client:write("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n")
  end)
  local state = completed_request({ method = "HEAD", url = "http://127.0.0.1:" .. srv.port .. "/" })
  wait_done(state)
  t.eq(state.err, nil)
  t.eq(state.response.body, "")
end)

local shared_test = package.loaded["tests.support.test"]
if shared_test then
  t.run_shared(shared_test)
else
  t.run()
end
