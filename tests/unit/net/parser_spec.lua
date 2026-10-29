local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local t = dofile(root .. "/tests/unit/net/support.lua")
local parser = require("opencode.net.parser")
local http = require("opencode.net.http")

local function parse_all(chunks, opts)
  local p = parser.new(opts)
  local events = {}
  for _, chunk in ipairs(chunks) do
    local fed, err = p:feed(chunk)
    if not fed then
      return nil, err, p
    end
    for _, event in ipairs(fed) do
      events[#events + 1] = event
    end
  end
  return events, nil, p
end

local function body_of(events)
  local parts = {}
  for _, event in ipairs(events) do
    if event.type == "chunk" then
      parts[#parts + 1] = event.data
    end
  end
  return table.concat(parts)
end

local function event_types(events)
  local types = {}
  for _, event in ipairs(events) do
    types[#types + 1] = event.type
  end
  return table.concat(types, ",")
end

t.test("content-length response split at every byte", function()
  local raw = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 11\r\n\r\nhello world"
  local chunks = {}
  for i = 1, #raw do
    chunks[i] = raw:sub(i, i)
  end
  local events, err = parse_all(chunks)
  t.eq(err, nil, "parse error")
  t.eq(body_of(events), "hello world")
  t.eq(events[1].type, "headers")
  t.eq(events[1].response.status, 200)
  t.eq(events[1].response.status_text, "OK")
  t.eq(events[1].response.headers["content-type"], "text/plain")
  t.eq(events[#events].type, "complete")
end)

t.test("content-length zero completes after headers", function()
  local events, err = parse_all({ "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n" })
  t.eq(err, nil)
  t.eq(event_types(events), "headers,complete")
  t.eq(body_of(events), "")
end)

t.test("HEAD response has no body", function()
  local events, err = parse_all({ "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n" }, { head_request = true })
  t.eq(err, nil)
  t.eq(event_types(events), "headers,complete")
end)

t.test("chunked response split at every byte", function()
  local raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: yes\r\n\r\n"
  local chunks = {}
  for i = 1, #raw do
    chunks[i] = raw:sub(i, i)
  end
  local events, err = parse_all(chunks)
  t.eq(err, nil)
  t.eq(body_of(events), "hello world")
  t.eq(events[#events].type, "complete")
end)

local function every_two_way_split(raw, expected)
  for i = 1, #raw - 1 do
    local events, err = parse_all({ raw:sub(1, i), raw:sub(i + 1) })
    if not events then
      error(("split at byte %d failed: %s"):format(i, err and err.message or "unknown error"), 0)
    end
    t.eq(body_of(events), expected, "body after split at byte " .. i)
    t.eq(events[#events].type, "complete", "completion after split at byte " .. i)
  end
end

t.test("content-length response accepts every two-way split", function()
  every_two_way_split(
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 11\r\n\r\nhello world",
    "hello world"
  )
end)

t.test("chunked response accepts every two-way split", function()
  every_two_way_split(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\n\r\n",
    "hello world"
  )
end)

t.test("identical duplicate content-length is accepted", function()
  local events, err = parse_all({
    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello",
  })
  t.eq(err, nil)
  t.eq(body_of(events), "hello")
end)

t.test("chunk extensions and duplicated response headers", function()
  local raw = "HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nTransfer-Encoding: chunked\r\n\r\n3;foo=bar\r\nabc\r\n0\r\n\r\n"
  local events, err = parse_all({ raw })
  t.eq(err, nil)
  t.eq(body_of(events), "abc")
  t.eq(events[1].response.headers["set-cookie"], "a=1, b=2")
end)

t.test("close-delimited body completes on EOF", function()
  local p = parser.new()
  local events = assert(p:feed("HTTP/1.1 200 OK\r\n\r\npartial"))
  t.eq(events[1].type, "headers")
  t.eq(body_of(events), "partial")
  local eof_events, err = p:finish()
  t.eq(err, nil)
  t.eq(body_of(eof_events), "")
  t.eq(eof_events[#eof_events].type, "complete")
end)

t.test("100 Continue is skipped before final response", function()
  local raw = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok"
  local events, err = parse_all({ raw })
  t.eq(err, nil)
  t.eq(events[1].response.status, 201)
  t.eq(body_of(events), "ok")
end)

t.test("invalid status line", function()
  local events, err = parse_all({ "NOTHTTP 200 OK\r\n\r\n" })
  t.eq(events, nil)
  t.eq(err.code, "invalid_status_line")
end)

t.test("invalid content length", function()
  local _, err = parse_all({ "HTTP/1.1 200 OK\r\nContent-Length: nope\r\n\r\n" })
  t.eq(err and err.code, "invalid_content_length")
end)

t.test("conflicting content length headers", function()
  local _, err = parse_all({ "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n" })
  t.eq(err and err.code, "invalid_content_length")
end)

t.test("invalid chunk size", function()
  local _, err = parse_all({ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n" })
  t.eq(err and err.code, "invalid_chunk_size")
end)

t.test("invalid chunk terminator", function()
  local _, err = parse_all({
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nabXX\r\n0\r\n\r\n",
  })
  t.eq(err and err.code, "invalid_chunk")
end)

t.test("invalid header line", function()
  local _, err = parse_all({ "HTTP/1.1 200 OK\r\nBroken header\r\n\r\n" })
  t.eq(err and err.code, "invalid_header")
end)

t.test("premature EOF in content-length body", function()
  local p = parser.new()
  assert(p:feed("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nab"))
  local _, err = p:finish()
  t.eq(err and err.code, "premature_eof")
end)

t.test("premature EOF in headers", function()
  local p = parser.new()
  assert(p:feed("HTTP/1.1 200 OK\r\nContent-Ty"))
  local _, err = p:finish()
  t.eq(err and err.code, "premature_eof")
end)

t.test("premature EOF before chunk terminator", function()
  local p = parser.new()
  assert(p:feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n"))
  local _, err = p:finish()
  t.eq(err and err.code, "premature_eof")
end)

t.test("unsupported transfer encoding", function()
  local _, err = parse_all({ "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n" })
  t.eq(err and err.code, "unsupported_transfer_encoding")
end)

t.test("parser ignores input after completion", function()
  local p = parser.new()
  local events = assert(p:feed("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx"))
  t.eq(events[#events].type, "complete")
  local more, err = p:feed("garbage")
  t.eq(err, nil)
  t.eq(#more, 0)
end)

t.test("URL parsing and percent encoding", function()
  local url = assert(http.parse_url("http://127.0.0.1:4096/a b/ü?q=x y&z=1#frag"))
  t.eq(url.host, "127.0.0.1")
  t.eq(url.port, 4096)
  t.eq(url.host_header, "127.0.0.1:4096")
  t.eq(url.path, "/a%20b/%C3%BC?q=x%20y&z=1")
end)

t.test("URL preserves valid escapes and root path", function()
  local url = assert(http.parse_url("http://example.test"))
  t.eq(url.path, "/")
  t.eq(url.host_header, "example.test")
  local again = assert(http.parse_url("http://example.test/a%2Fb?x=%20"))
  t.eq(again.path, "/a%2Fb?x=%20")
end)

t.test("HTTPS is rejected explicitly", function()
  local url, err = http.parse_url("https://127.0.0.1:4096/api")
  t.eq(url, nil)
  t.eq(err.code, "https_not_supported")
end)

t.test("request rejects HTTPS synchronously", function()
  local cancel, err = http.request({ url = "https://127.0.0.1:1/" }, function() end)
  t.eq(cancel, nil)
  t.eq(err.code, "https_not_supported")
end)

t.test("invalid URL and timeout validation", function()
  local _, err = http.request({ url = "ftp://x/" }, function() end)
  t.eq(err.code, "invalid_url")
  local _, timeout_err = http.request({ url = "http://127.0.0.1:1/", timeout = -1 }, function() end)
  t.eq(timeout_err.code, "invalid_request")
end)

local shared_test = package.loaded["tests.support.test"]
if shared_test then
  t.run_shared(shared_test)
else
  t.run()
end
