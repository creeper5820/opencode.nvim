-- Minimal, dependency-free test helper for 09A. Runs inside an isolated
-- headless Neovim; all temp paths live under /tmp/opencode.

local uv = vim.uv or vim.loop

local M = {}

local tests = {}

function M.test(name, fn)
  table.insert(tests, { name = name, fn = fn })
end

function M.run()
  local failed = 0
  for _, case in ipairs(tests) do
    local ok, err = pcall(case.fn)
    if ok then
      io.write("ok   " .. case.name .. "\n")
    else
      failed = failed + 1
      io.write("FAIL " .. case.name .. "\n     " .. tostring(err) .. "\n")
    end
  end
  io.write(string.format("\n%d passed, %d failed\n", #tests - failed, failed))
  io.flush()
  M.cleanup_tempdirs()
  os.exit(failed == 0 and 0 or 1)
end

--- Register collected cases with tests/support/test (tests/run.sh).
function M.run_shared(test)
  for _, case in ipairs(tests) do
    test.it(case.name, function()
      local ok, err = pcall(case.fn)
      M.cleanup_tempdirs()
      if not ok then
        error(err, 0)
      end
    end)
  end
end

function M.fail(message)
  error(message, 2)
end

function M.assert(condition, message)
  if not condition then
    M.fail(message or "assertion failed")
  end
end

function M.eq(expected, actual, message)
  if expected ~= actual then
    M.fail(
      (message or "values differ")
        .. string.format(": expected %q, got %q", tostring(expected), tostring(actual))
    )
  end
end

function M.match(pattern, value, message)
  if type(value) ~= "string" or not value:match(pattern) then
    M.fail((message or "pattern mismatch") .. string.format(": %q !~ %q", pattern, tostring(value)))
  end
end

function M.contains(haystack, needle, message)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    M.fail((message or "substring missing") .. ": " .. tostring(needle))
  end
end

function M.not_contains(haystack, needle, message)
  if type(haystack) == "string" and haystack:find(needle, 1, true) then
    M.fail((message or "unexpected substring") .. ": " .. tostring(needle))
  end
end

--- Create an isolated temp directory under /tmp/opencode and track it.
function M.tempdir(label)
  local base = "/tmp/opencode"
  if not uv.fs_stat(base) then
    uv.fs_mkdir(base, 448)
  end
  local dir = string.format("%s/09a-%s-%d-%x", base, label or "test", uv.os_getpid(), uv.hrtime())
  local ok, err = uv.fs_mkdir(dir, 448)
  assert(ok, "cannot create temp dir: " .. tostring(err))
  table.insert(M._tempdirs, dir)
  return dir
end
M._tempdirs = {}

function M.cleanup_tempdirs()
  for _, dir in ipairs(M._tempdirs) do
    if dir:match("^/tmp/opencode/09a%-") then
      vim.fn.delete(dir, "rf")
    end
  end
  M._tempdirs = {}
end

if vim.api and vim.api.nvim_create_autocmd then
  local group = vim.api.nvim_create_augroup("OpencodeNvim09ATestCleanup", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.cleanup_tempdirs()
    end,
  })
end

local function parse_response(data)
  local header_end = data:find("\r\n\r\n", 1, true)
  if not header_end then
    return nil, "incomplete response"
  end
  local head = data:sub(1, header_end - 1)
  local body = data:sub(header_end + 4)
  local status = tonumber(head:match("^HTTP/1%.[01] (%d%d%d)"))
  if not status then
    return nil, "invalid status line"
  end
  local headers = {}
  for line in head:gmatch("[^\r\n]+") do
    local name, value = line:match("^([^:]+):%s*(.*)$")
    if name then
      headers[name:lower()] = value
    end
  end
  local decoded
  if body ~= "" then
    local ok, value = pcall(vim.json.decode, body)
    if ok then
      decoded = value
    end
  end
  return { status = status, headers = headers, body = body, json = decoded }
end

--- Send raw chunks to the server and collect the response.
-- `chunks` is a list of strings. `opts.delay` inserts a timer between chunks.
-- `opts.abort_after` closes the socket after sending that many chunks.
-- Returns the parsed response or nil, error.
function M.exchange(port, chunks, opts)
  opts = opts or {}
  local done = false
  local response, failure
  local buffer = ""
  local socket = uv.new_tcp()
  local timer = uv.new_timer()
  local index = 0
  local function finish(result, err)
    if done then
      return
    end
    done = true
    response, failure = result, err
  end
  local function close()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
    if socket and not socket:is_closing() then
      socket:close()
    end
  end
  local function send_next()
    if done then
      return
    end
    index = index + 1
    if not chunks[index] then
      return
    end
    if opts.abort_after and index >= opts.abort_after then
      close()
      finish(nil, "aborted")
      return
    end
    socket:write(chunks[index])
    if chunks[index + 1] then
      timer:start(opts.delay or 10, 0, send_next)
    end
  end
  timer:start(opts.timeout or 4000, 0, function()
    close()
    finish(nil, "timeout")
  end)
  socket:connect("127.0.0.1", port, function(err)
    if err then
      close()
      finish(nil, "connect failed: " .. tostring(err))
      return
    end
    send_next()
  end)
  socket:read_start(function(err, chunk)
    if err then
      close()
      finish(nil, "read failed: " .. tostring(err))
      return
    end
    if not chunk then
      local parsed, parse_err = parse_response(buffer)
      close()
      finish(parsed, parse_err)
      return
    end
    buffer = buffer .. chunk
    local parsed, parse_err = parse_response(buffer)
    if parsed and parsed.headers["content-length"] then
      local expected = tonumber(parsed.headers["content-length"])
      local header_end = buffer:find("\r\n\r\n", 1, true)
      if expected and header_end and #buffer - header_end - 3 >= expected then
        close()
        finish(parsed)
      end
    end
  end)
  vim.wait(opts.timeout or 4000, function()
    return done
  end, 5)
  if not done then
    close()
    return nil, "request timed out"
  end
  if failure then
    return nil, failure
  end
  return response
end

function M.request(port, opts)
  opts = opts or {}
  local body = opts.body
  if type(body) == "table" then
    body = vim.json.encode(body)
  end
  body = body or ""
  local headers = {
    "Host: 127.0.0.1:" .. tostring(port),
    "Connection: close",
  }
  if opts.token then
    table.insert(headers, "Authorization: Bearer " .. opts.token)
  end
  if opts.headers then
    for _, line in ipairs(opts.headers) do
      table.insert(headers, line)
    end
  end
  if body ~= "" and not opts.no_content_length then
    table.insert(headers, "Content-Length: " .. tostring(#body))
  end
  local raw = table.concat({
    (opts.method or "GET") .. " " .. (opts.path or "/health") .. " HTTP/1.1",
    table.concat(headers, "\r\n"),
    "",
    body,
  }, "\r\n")
  if opts.chunks then
    return M.exchange(port, opts.chunks, opts)
  end
  return M.exchange(port, { raw }, opts)
end

--- Wait for the server to be reachable/closed without raising.
function M.wait_for(fn, timeout)
  return vim.wait(timeout or 2000, fn, 5)
end

return M
