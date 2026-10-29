local M = {}

M.passed = 0
M.failed = 0
M.skipped = 0
M.total = 0
M.failures = {}

local stack = {}

local function indent()
  return string.rep("  ", math.max(#stack - 1, 0))
end

local function full_name(name)
  local parts = {}
  for _, item in ipairs(stack) do
    parts[#parts + 1] = item
  end
  parts[#parts + 1] = name
  return table.concat(parts, " > ")
end

function M.describe(name, fn)
  stack[#stack + 1] = name
  local ok, err = pcall(fn)
  stack[#stack] = nil
  if not ok then
    M.total = M.total + 1
    M.failed = M.failed + 1
    local message = full_name("describe") .. ": " .. tostring(err)
    M.failures[#M.failures + 1] = message
    io.stdout:write("not ok - " .. message .. "\n")
  end
end

function M.it(name, fn)
  M.total = M.total + 1
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    M.passed = M.passed + 1
    io.stdout:write(("ok - %s%s\n"):format(indent(), full_name(name)))
  else
    M.failed = M.failed + 1
    local message = full_name(name) .. "\n" .. tostring(err)
    M.failures[#M.failures + 1] = message
    io.stdout:write(("not ok - %s%s\n"):format(indent(), message))
  end
end

function M.skip(name, reason)
  M.total = M.total + 1
  M.skipped = M.skipped + 1
  io.stdout:write(("skip - %s%s (%s)\n"):format(indent(), full_name(name), reason or "skipped"))
end

function M.skip_if(condition, name, reason)
  if condition then
    M.skip(name, reason)
    return true
  end
  return false
end

local function fail(message)
  error(message, 3)
end

function M.equal(expected, actual, message)
  if expected ~= actual then
    fail((message or "values differ") .. (": expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.deep_equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    fail((message or "values differ") .. (": expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.truthy(value, message)
  if not value then
    fail(message or "expected a truthy value")
  end
end

function M.falsy(value, message)
  if value then
    fail(message or ("expected a falsy value, got " .. vim.inspect(value)))
  end
end

function M.matches(pattern, value, message)
  if type(value) ~= "string" then
    fail((message or "expected a string") .. (": got " .. vim.inspect(value)))
  end
  if not value:match(pattern) then
    fail((message or "string did not match pattern") .. (": pattern %q, value %q"):format(pattern, value))
  end
end

function M.error_matches(pattern, fn, message)
  local ok, err = pcall(fn)
  if ok then
    fail(message or "expected an error")
  end
  local text = tostring(err)
  if not text:match(pattern) then
    fail((message or "error did not match pattern") .. (": pattern %q, error %q"):format(pattern, text))
  end
end

function M.reload()
  for name in pairs(package.loaded) do
    if name == "opencode" or name:match("^opencode%.") then
      package.loaded[name] = nil
    end
  end
end

function M.finish()
  io.stdout:write(("\n%d tests, %d passed, %d failed, %d skipped\n"):format(
    M.total, M.passed, M.failed, M.skipped
  ))
  for _, message in ipairs(M.failures) do
    io.stdout:write("\nFAILURE: " .. message .. "\n")
  end
  return M.failed == 0
end

return M
