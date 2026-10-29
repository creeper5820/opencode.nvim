-- Minimal self-contained test harness for the HTTP transport tests.
-- No dependency on tests/support (owned by another task).

local uv = vim.uv or vim.loop

local M = {}

M.tests = {}

function M.test(name, fn)
  M.tests[#M.tests + 1] = { name = name, fn = fn }
end

local function fail(message)
  error(message, 3)
end

function M.eq(actual, expected, label)
  if actual ~= expected then
    fail((label or "value") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
  end
end

function M.truthy(value, label)
  if not value then
    fail((label or "value") .. " is not truthy")
  end
end

function M.matches(value, pattern, label)
  if type(value) ~= "string" or not value:match(pattern) then
    fail((label or "value") .. ": " .. vim.inspect(value) .. " does not match " .. pattern)
  end
end

function M.wait(condition, timeout, label)
  local ok = vim.wait(timeout or 2000, condition, 5)
  if not ok then
    fail((label or "condition") .. " timed out")
  end
end

M.servers = {}
M.timers = {}

---Count live libuv handles by type. Used to verify that cancelled and timed
---out requests release their sockets and timers.
function M.handle_counts()
  local counts = {}
  uv.walk(function(handle)
    local ok, kind = pcall(handle.get_type, handle)
    kind = ok and kind or "unknown"
    counts[kind] = (counts[kind] or 0) + 1
  end)
  return counts
end

local function close_handle(handle)
  if not handle or handle:is_closing() then
    return
  end
  pcall(handle.read_stop, handle)
  pcall(handle.close, handle)
end

function M.new_timer()
  local timer = assert(uv.new_timer())
  M.timers[#M.timers + 1] = timer
  return timer
end

function M.cleanup()
  for _, timer in ipairs(M.timers) do
    if not timer:is_closing() then
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
    end
  end
  M.timers = {}
  for _, server in ipairs(M.servers) do
    for _, client in ipairs(server.clients) do
      close_handle(client)
    end
    close_handle(server.handle)
  end
  M.servers = {}
  vim.wait(20)
end

---Start a fake HTTP server on 127.0.0.1 with an ephemeral port.
---`handler(client, request)` is called exactly once after a complete request
---has been received.  `request` contains the raw text plus parsed helpers.
function M.server(handler)
  local server = assert(uv.new_tcp())
  assert(server:bind("127.0.0.1", 0))
  local address = server:getsockname()
  local state = {
    handle = server,
    port = address.port,
    clients = {},
    handler = handler,
  }
  M.servers[#M.servers + 1] = state

  assert(server:listen(16, function(listen_err)
    if listen_err then
      return
    end
    local client = uv.new_tcp()
    if not client then
      return
    end
    server:accept(client)
    state.clients[#state.clients + 1] = client

    local buffer = ""
    local dispatched = false
    client:read_start(function(read_err, data)
      if read_err then
        return
      end
      if data == nil then
        return
      end
      buffer = buffer .. data
      if dispatched then
        return
      end
      local header_end = buffer:find("\r\n\r\n", 1, true)
      if not header_end then
        return
      end
      local header_text = buffer:sub(1, header_end + 3)
      local content_length = tonumber(header_text:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
      if #buffer < header_end + 3 + content_length then
        return
      end
      dispatched = true
      local request = {
        raw = buffer:sub(1, header_end + 3 + content_length),
        head = header_text,
        body = buffer:sub(header_end + 4, header_end + 3 + content_length),
      }
      handler(client, request)
    end)
  end))

  return state
end

---Write `parts` in order, spacing writes by `delay` ms.  Returns a timer
---that cleanup will close.
function M.write_parts(client, parts, delay, on_error)
  local timer = M.new_timer()
  local index = 1
  local function step()
    if index > #parts then
      timer:stop()
      return
    end
    local part = parts[index]
    index = index + 1
    client:write(part, function(write_err)
      if write_err then
        timer:stop()
        if on_error then
          on_error(write_err)
        end
      end
    end)
    if index <= #parts then
      timer:start(delay or 5, 0, step)
    else
      timer:stop()
    end
  end
  step()
  return timer
end

function M.run()
  local passed, failed = 0, 0
  for _, case in ipairs(M.tests) do
    local ok, test_err = pcall(case.fn)
    if ok then
      passed = passed + 1
      io.stdout:write("PASS " .. case.name .. "\n")
    else
      failed = failed + 1
      io.stdout:write("FAIL " .. case.name .. "\n  " .. tostring(test_err) .. "\n")
    end
    M.cleanup()
  end
  io.stdout:write(string.format("%d passed, %d failed\n", passed, failed))
  os.exit(failed == 0 and 0 or 1)
end

---Register collected cases with tests/support/test when loaded by
---tests/run.sh, so the shared runner executes every net spec.
function M.run_shared(shared_test)
  for _, case in ipairs(M.tests) do
    shared_test.it(case.name, function()
      M.cleanup()
      local ok, test_err = pcall(case.fn)
      M.cleanup()
      if not ok then
        error(test_err, 0)
      end
    end)
  end
end

return M
