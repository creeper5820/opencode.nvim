local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local t = dofile(root .. "/tests/unit/net/support.lua")
local http = require("opencode.net.http")

local function new_stream(opts, handlers)
  local state = {
    headers = nil,
    header_count = 0,
    chunks = {},
    chunk_count = 0,
    done = false,
    done_count = 0,
    err = nil,
  }
  local wrapped = {
    on_headers = function(response)
      state.header_count = state.header_count + 1
      state.headers = response
      if handlers.on_headers then
        handlers.on_headers(response)
      end
    end,
    on_chunk = function(chunk)
      state.chunk_count = state.chunk_count + 1
      state.chunks[#state.chunks + 1] = chunk
      if handlers.on_chunk then
        handlers.on_chunk(chunk)
      end
    end,
    on_done = function(err)
      state.done_count = state.done_count + 1
      state.done = true
      state.err = err
      if handlers.on_done then
        handlers.on_done(err)
      end
    end,
  }
  local cancel, start_err = http.stream(opts, wrapped)
  t.truthy(cancel, "cancel function")
  t.eq(start_err, nil, "start error")
  state.cancel = cancel
  return state
end

local function wait_done(state, timeout)
  t.wait(function()
    return state.done
  end, timeout or 2000, "stream done")
end

local function received_body(state)
  return table.concat(state.chunks)
end

t.test("chunked stream delivers headers, multiple chunks and one done", function()
  local srv = t.server(function(client)
    t.write_parts(client, {
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
      "4\r\nab",
      "cd\r\n",
      "3\r\nefg\r\n",
      "0\r\n\r\n",
    }, 3)
  end)
  local state = new_stream({ url = "http://127.0.0.1:" .. srv.port .. "/api/event" }, {})
  wait_done(state)
  t.eq(state.err, nil)
  t.eq(state.header_count, 1)
  t.eq(state.headers.status, 200)
  t.eq(state.done_count, 1)
  t.eq(received_body(state), "abcdefg")
  t.truthy(state.chunk_count >= 2, "expected multiple chunks")
  state.cancel()
  state.cancel()
  vim.wait(50)
  t.eq(state.done_count, 1)
end)

t.test("stream callback order is headers, chunks, then done", function()
  local srv = t.server(function(client)
    client:write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\n")
  end)
  local order = {}
  local done = false
  local done_err
  local cancel, start_err = http.stream({
    url = "http://127.0.0.1:" .. srv.port .. "/",
  }, {
    on_headers = function()
      order[#order + 1] = "headers"
    end,
    on_chunk = function()
      order[#order + 1] = "chunk"
    end,
    on_done = function(err)
      order[#order + 1] = "done"
      done_err = err
      done = true
    end,
  })
  t.truthy(cancel, "cancel function")
  t.eq(start_err, nil)
  t.wait(function()
    return done
  end, 2000, "stream done")
  t.eq(done_err, nil)
  t.eq(order[1], "headers")
  t.eq(order[#order], "done")
  for i = 2, #order - 1 do
    t.eq(order[i], "chunk", "callback " .. i)
  end
  cancel()
  cancel()
  vim.wait(30)
  t.eq(order[#order], "done")
end)

t.test("content-length stream delivers chunks", function()
  local srv = t.server(function(client)
    t.write_parts(client, {
      "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello",
      " wor",
      "ld",
    }, 3)
  end)
  local state = new_stream({ url = "http://127.0.0.1:" .. srv.port .. "/" }, {})
  wait_done(state)
  t.eq(state.err, nil)
  t.eq(received_body(state), "hello world")
  t.eq(state.done_count, 1)
end)

t.test("close-delimited stream finishes on EOF", function()
  local srv = t.server(function(client)
    client:write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: one\n\n", function()
      client:close()
    end)
  end)
  local state = new_stream({ url = "http://127.0.0.1:" .. srv.port .. "/api/event" }, {})
  wait_done(state)
  t.eq(state.err, nil)
  t.eq(received_body(state), "data: one\n\n")
  t.eq(state.done_count, 1)
end)

t.test("cancel inside on_chunk stops delivery and is idempotent", function()
  local srv = t.server(function(client)
    t.write_parts(client, {
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
      "3\r\none\r\n",
      "3\r\ntwo\r\n",
      "5\r\nthree\r\n",
      "0\r\n\r\n",
    }, 10)
  end)
  local state
  state = new_stream({ url = "http://127.0.0.1:" .. srv.port .. "/" }, {
    on_chunk = function()
      state.cancel()
      state.cancel()
    end,
  })
  vim.wait(200)
  t.eq(state.chunk_count, 1)
  t.eq(state.done_count, 0)
  t.eq(received_body(state), "one")
end)

t.test("cancel inside on_headers delivers no body or done", function()
  local srv = t.server(function(client)
    t.write_parts(client, {
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
      "3\r\none\r\n",
      "0\r\n\r\n",
    }, 10)
  end)
  local state
  state = new_stream({ url = "http://127.0.0.1:" .. srv.port .. "/" }, {
    on_headers = function()
      state.cancel()
    end,
  })
  vim.wait(200)
  t.eq(state.header_count, 1)
  t.eq(state.chunk_count, 0)
  t.eq(state.done_count, 0)
end)

t.test("stream timeout reports timeout once", function()
  local srv = t.server(function() end)
  local state = new_stream({ url = "http://127.0.0.1:" .. srv.port .. "/", timeout = 80 }, {})
  wait_done(state)
  t.eq(state.err.code, "timeout")
  t.eq(state.done_count, 1)
  t.eq(state.chunk_count, 0)
end)

t.test("stream invalid chunk size reports protocol error", function()
  local srv = t.server(function(client)
    client:write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nnope\r\n")
  end)
  local state = new_stream({ url = "http://127.0.0.1:" .. srv.port .. "/", timeout = 1000 }, {})
  wait_done(state)
  t.eq(state.err.code, "invalid_chunk_size")
  t.eq(state.done_count, 1)
end)

t.test("stream premature EOF reports protocol error", function()
  local srv = t.server(function(client)
    client:write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nab", function()
      client:close()
    end)
  end)
  local state = new_stream({ url = "http://127.0.0.1:" .. srv.port .. "/", timeout = 1000 }, {})
  wait_done(state)
  t.eq(state.err.code, "premature_eof")
end)

t.test("stream HTTPS is rejected synchronously", function()
  local cancel, err = http.stream({ url = "https://127.0.0.1:1/api/event" }, {
    on_headers = function() end,
  })
  t.eq(cancel, nil)
  t.eq(err.code, "https_not_supported")
end)

t.test("stream POST sends body and receives response", function()
  local seen
  local srv = t.server(function(client, request)
    seen = request
    client:write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
  end)
  local state = new_stream({
    method = "POST",
    url = "http://127.0.0.1:" .. srv.port .. "/api/session",
    headers = { ["Content-Type"] = "application/json" },
    body = "{}",
  }, {})
  wait_done(state)
  t.eq(state.err, nil)
  t.eq(seen.body, "{}")
  t.matches(seen.head, "\r\nContent%-Length: 2\r\n")
  t.eq(received_body(state), "ok")
end)

local shared_test = package.loaded["tests.support.test"]
if shared_test then
  t.run_shared(shared_test)
else
  t.run()
end
