-- Headless tests for lua/opencode/tools/notify.lua.
-- Run through tests/headless/tools/notify/run.sh so the environment is
-- isolated under /tmp/opencode.

local this = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(this, ":p:h")
local repo = vim.fn.fnamemodify(dir, ":h:h:h:h")
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path

local BASE = "/tmp/opencode/"
for _, name in ipairs({
  "HOME",
  "XDG_CONFIG_HOME",
  "XDG_DATA_HOME",
  "XDG_STATE_HOME",
  "XDG_CACHE_HOME",
  "XDG_RUNTIME_DIR",
  "TMPDIR",
}) do
  local value = vim.env[name]
  if type(value) ~= "string" or value:sub(1, #BASE) ~= BASE then
    io.stderr:write(("refusing to run notify tests: %s is not isolated under /tmp/opencode; use run.sh\n"):format(name))
    vim.cmd("cquit 2")
  end
end

local protocol = require("opencode.tools.protocol")
local notify = require("opencode.tools.notify")

local total = 0
local passed = 0
local skipped = 0
local failures = {}

local function test(name, fn)
  total = total + 1
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    io.stdout:write("ok - " .. name .. "\n")
  else
    failures[#failures + 1] = name .. "\n" .. tostring(err)
    io.stdout:write("not ok - " .. name .. "\n")
  end
end

local function check(condition, message)
  if not condition then
    error(message or "assertion failed", 2)
  end
end

local function eq(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    error(("%s: expected %s, got %s"):format(label or "value", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function capture()
  local calls = {}
  local handler = notify.handler({
    notify = function(message, level)
      calls[#calls + 1] = { message = message, level = level }
    end,
  })
  return handler, calls
end

local function expect_error(result, err, code, label)
  check(result == nil, (label or "error") .. ": expected nil result, got " .. vim.inspect(result))
  check(type(err) == "table", (label or "error") .. ": expected a structured error, got " .. vim.inspect(err))
  eq(err.code, code, (label or "error") .. " code")
  check(protocol.ERROR_CODES[code] ~= nil, (label or "error") .. ": code is defined by 09A")
  check(type(err.message) == "string" and #err.message > 0, (label or "error") .. ": message is non-empty")
end

local function expect_ok(result, err, label)
  check(err == nil, (label or "notify") .. ": unexpected error " .. vim.inspect(err))
  check(type(result) == "table", (label or "notify") .. ": expected a result table, got " .. vim.inspect(result))
end

test("defaults to info and calls the notification API", function()
  local handler, calls = capture()
  local result, err = handler({ message = "hello" })
  expect_ok(result, err)
  eq(result.notified, true, "notified")
  eq(result.level, "info", "default level")
  eq(#calls, 1, "one notification")
  eq(calls[1].message, "hello", "message forwarded")
  eq(calls[1].level, vim.log.levels.INFO, "info log level")
end)

test("warn and error levels map to vim.log.levels", function()
  local handler, calls = capture()
  local result, err = handler({ message = "careful", level = "warn" })
  expect_ok(result, err)
  eq(result.level, "warn", "warn result")
  eq(calls[1].level, vim.log.levels.WARN, "warn log level")

  result, err = handler({ message = "broken", level = "error" })
  expect_ok(result, err)
  eq(result.level, "error", "error result")
  eq(calls[2].level, vim.log.levels.ERROR, "error log level")
end)

test("unsupported levels are rejected without notifying", function()
  local handler, calls = capture()
  for _, level in ipairs({ "warning", "INFO", "", 3 }) do
    local result, err = handler({ message = "text", level = level })
    expect_error(result, err, protocol.ERROR_CODES.INVALID_REQUEST, tostring(level))
  end
  eq(#calls, 0, "nothing was notified")
end)

test("empty, missing and non-string messages are rejected", function()
  local handler, calls = capture()
  local cases = {
    { input = { message = "" }, label = "empty" },
    { input = { message = "   " }, label = "whitespace only" },
    { input = {}, label = "missing" },
    { input = { message = 7 }, label = "number" },
    { input = { message = vim.NIL }, label = "null" },
  }
  for _, case in ipairs(cases) do
    local result, err = handler(case.input)
    expect_error(result, err, protocol.ERROR_CODES.INVALID_REQUEST, case.label)
  end
  eq(#calls, 0, "nothing was notified")
end)

test("the maximum message size is enforced", function()
  local handler, calls = capture()
  local exact = string.rep("x", notify.MAX_MESSAGE_BYTES)
  local result, err = handler({ message = exact })
  expect_ok(result, err)
  eq(#calls, 1, "max-size message accepted")

  local result2, err2 = handler({ message = exact .. "x" })
  expect_error(result2, err2, protocol.ERROR_CODES.INVALID_REQUEST, "oversized")
  eq(err2.details.max_bytes, notify.MAX_MESSAGE_BYTES, "limit in details")
  eq(err2.details.actual_bytes, notify.MAX_MESSAGE_BYTES + 1, "actual size in details")
  eq(#calls, 1, "oversized message not notified")
end)

test("a custom size limit can be injected", function()
  local calls = {}
  local handler = notify.handler({
    max_message_bytes = 4,
    notify = function(message, level)
      calls[#calls + 1] = { message = message, level = level }
    end,
  })
  local result, err = handler({ message = "1234" })
  expect_ok(result, err)
  result, err = handler({ message = "12345" })
  expect_error(result, err, protocol.ERROR_CODES.INVALID_REQUEST, "custom limit")
  eq(err.details.max_bytes, 4, "custom limit in details")
  eq(#calls, 1, "only the accepted message was notified")
end)

test("the default path calls vim.notify", function()
  local original = vim.notify
  local calls = {}
  vim.notify = function(message, level)
    calls[#calls + 1] = { message = message, level = level }
  end
  local ok, result, err = pcall(function()
    return notify.handle({ message = "from vim.notify" })
  end)
  vim.notify = original

  check(ok, "handler raised: " .. tostring(result))
  expect_ok(result, err)
  eq(#calls, 1, "vim.notify called once")
  eq(calls[1].message, "from vim.notify", "vim.notify message")
  eq(calls[1].level, vim.log.levels.INFO, "vim.notify info level")
end)

test("a failing notification API becomes a structured action failure", function()
  local handler = notify.handler({
    notify = function()
      error("boom")
    end,
  })
  local result, err = handler({ message = "will fail" })
  expect_error(result, err, protocol.ERROR_CODES.ACTION_FAILED, "notify failure")
  check(err.message:find("notification", 1, true) ~= nil, "error explains the action")
end)

test("the request token and original message are not echoed", function()
  local handler, calls = capture()
  local secret = "super-secret-token"
  local ctx = { token = secret }

  local result, err = handler({ message = "safe text" }, ctx)
  expect_ok(result, err)
  eq(calls[1].message, "safe text", "only the message is notified")
  check(not vim.json.encode(result):find(secret, 1, true), "token absent from result")
  check(not vim.json.encode(result):find("safe text", 1, true), "message not echoed in result")

  result, err = handler({ message = string.rep("y", notify.MAX_MESSAGE_BYTES + 1) }, ctx)
  expect_error(result, err, protocol.ERROR_CODES.INVALID_REQUEST, "oversized")
  check(not vim.json.encode(err):find(secret, 1, true), "token absent from error")
end)

test("handler responds when invoked from a libuv callback", function()
  local calls = {}
  local handler = notify.handler({
    notify = function(message, level)
      calls[#calls + 1] = { message = message, level = level }
    end,
  })
  local done = false
  local result, response_err
  local timer = vim.uv.new_timer()
  timer:start(0, 0, function()
    handler({ message = "async notify", level = "warn" }, {
      respond = function(value, err)
        result, response_err = value, err
        done = true
      end,
    })
  end)
  local waited = vim.wait(2000, function()
    return done
  end, 10)
  timer:stop()
  timer:close()

  check(waited, "handler did not call ctx.respond")
  expect_ok(result, response_err)
  eq(result.level, "warn", "async level")
  eq(#calls, 1, "async notification sent")
  eq(calls[1].message, "async notify", "async message")
end)

io.stdout:write(("\nNotify tests: %d total, %d passed, %d failed, %d skipped\n"):format(
  total,
  passed,
  #failures,
  skipped
))
for _, failure in ipairs(failures) do
  io.stderr:write("FAIL " .. failure .. "\n")
end
if #failures > 0 then
  vim.cmd("cquit 1")
end
vim.cmd("qall!")
