-- Headless tests for lua/opencode/tools/open.lua.
-- Run through tests/headless/tools/open/run.sh so the environment and project
-- are isolated under /tmp/opencode.

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
    io.stderr:write(("refusing to run open tests: %s is not isolated under /tmp/opencode; use run.sh\n"):format(name))
    vim.cmd("cquit 2")
  end
end

local protocol = require("opencode.tools.protocol")
local open = require("opencode.tools.open")

local project = vim.env.TMPDIR .. "/project"
local outside = vim.env.TMPDIR .. "/outside"
vim.fn.mkdir(project, "p")
vim.fn.mkdir(outside, "p")

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

local function skip(name, reason)
  total = total + 1
  skipped = skipped + 1
  io.stdout:write(("skip - %s (%s)\n"):format(name, reason))
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

local function write(relative, lines)
  local path = project .. "/" .. relative
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines or { "" }, path)
  return path
end

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local function fresh()
  vim.cmd("silent! tabonly")
  vim.cmd("silent! only")
  vim.cmd("silent! enew!")
  local keep = vim.api.nvim_get_current_buf()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if bufnr ~= keep and vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
  vim.bo[keep].buftype = ""
  vim.bo[keep].modified = false
end

local function handler()
  return open.handler({ project_root = project })
end

local function call(input, ctx)
  return handler()(input, ctx or { project_root = project })
end

local function expect_error(result, err, code, label)
  check(result == nil, (label or "error") .. ": expected nil result, got " .. vim.inspect(result))
  check(type(err) == "table", (label or "error") .. ": expected a structured error, got " .. vim.inspect(err))
  eq(err.code, code, (label or "error") .. " code")
  check(protocol.ERROR_CODES[code] ~= nil, (label or "error") .. ": code is defined by 09A")
  check(type(err.message) == "string" and #err.message > 0, (label or "error") .. ": message is non-empty")
end

local function expect_ok(result, err, label)
  check(err == nil, (label or "open") .. ": unexpected error " .. vim.inspect(err))
  check(type(result) == "table", (label or "open") .. ": expected a result table, got " .. vim.inspect(result))
end

test("relative path opens inside the project without changing content", function()
  fresh()
  local path = write("src/alpha.lua", { "first", "second", "third" })
  local before = read(path)
  local result, err = call({ path = "src/alpha.lua", line = 2, column = 3 })
  expect_ok(result, err)

  eq(result.opened, true, "opened")
  eq(result.reused, false, "new buffer")
  eq(result.path, "src/alpha.lua", "relative result path")
  eq(result.line, 2, "result line")
  eq(result.column, 3, "result column")
  check(type(result.buffer) == "number" and result.buffer > 0, "buffer id")
  check(type(result.window) == "number" and result.window > 0, "window id")
  eq(vim.api.nvim_buf_get_name(0), path, "current buffer name")
  eq(vim.api.nvim_win_get_cursor(0), { 2, 2 }, "1-based column becomes byte col")
  eq(read(path), before, "file content unchanged")
  eq(vim.bo[vim.api.nvim_get_current_buf()].modified, false, "buffer not modified")
end)

test("absolute path inside the project opens with defaults", function()
  fresh()
  local path = write("src/beta.lua", { "beta" })
  local result, err = call({ path = path })
  expect_ok(result, err)

  eq(result.path, "src/beta.lua", "project-relative result")
  eq(result.line, open.DEFAULT_LINE, "default line")
  eq(result.column, open.DEFAULT_COLUMN, "default column")
  eq(vim.api.nvim_buf_get_name(0), path, "absolute input uses the same file")
  eq(vim.api.nvim_win_get_cursor(0), { 1, 0 }, "default cursor")
end)

test("missing, directory, escaping and malformed paths are rejected", function()
  fresh()
  local outside_file = outside .. "/secret.lua"
  vim.fn.writefile({ "secret" }, outside_file)

  local result, err = call({ path = "missing.lua" })
  expect_error(result, err, protocol.ERROR_CODES.NOT_FOUND, "missing file")
  eq(err.details.path, "missing.lua", "missing file details")

  result, err = call({ path = "src" })
  expect_error(result, err, protocol.ERROR_CODES.INVALID_REQUEST, "directory")

  result, err = call({ path = "../outside/secret.lua" })
  expect_error(result, err, protocol.ERROR_CODES.INVALID_REQUEST, "relative escape")

  result, err = call({ path = outside_file })
  expect_error(result, err, protocol.ERROR_CODES.INVALID_REQUEST, "absolute escape")

  result, err = call({ path = "" })
  expect_error(result, err, protocol.ERROR_CODES.INVALID_REQUEST, "empty path")

  result, err = call({ path = "bad\0path" })
  expect_error(result, err, protocol.ERROR_CODES.INVALID_REQUEST, "NUL path")
end)

test("symlinks cannot escape the project root", function()
  fresh()
  local outside_file = outside .. "/linked.lua"
  vim.fn.writefile({ "outside" }, outside_file)
  local link = project .. "/escape.lua"
  pcall(vim.uv.fs_unlink, link)
  local ok = pcall(vim.uv.fs_symlink, outside_file, link)
  if not ok or vim.fn.getftype(link) ~= "link" then
    skip("symlinks cannot escape the project root", "symlinks unavailable")
    return
  end

  local result, err = call({ path = "escape.lua" })
  expect_error(result, err, protocol.ERROR_CODES.INVALID_REQUEST, "symlink escape")
end)

test("invalid line and column are structured errors", function()
  fresh()
  write("src/positions.lua", { "abc", "defg" })
  local cases = {
    { line = 0, label = "line zero" },
    { line = -1, label = "negative line" },
    { line = 3, label = "line past EOF" },
    { line = 1.5, label = "fractional line" },
    { line = "1", label = "string line" },
    { column = 0, label = "column zero" },
    { column = 5, line = 1, label = "column past EOL" },
    { column = 6, line = 2, label = "column past second line" },
    { column = 2.5, label = "fractional column" },
  }
  for _, case in ipairs(cases) do
    local input = { path = "src/positions.lua", line = case.line, column = case.column }
    local result, err = call(input)
    expect_error(result, err, protocol.ERROR_CODES.INVALID_REQUEST, case.label)
  end
  eq(read(project .. "/src/positions.lua"), "abc\ndefg", "invalid positions do not write")
end)

test("an existing buffer is reused and never reloaded", function()
  fresh()
  local path = write("src/reuse.lua", { "original" })
  local first, first_err = call({ path = "src/reuse.lua" })
  expect_ok(first, first_err)
  vim.api.nvim_buf_set_lines(first.buffer, 0, -1, false, { "edited only in memory" })

  local second, second_err = call({ path = "src/reuse.lua", line = 1, column = 1 })
  expect_ok(second, second_err)

  eq(second.buffer, first.buffer, "same buffer")
  eq(second.reused, true, "reuse reported")
  eq(vim.api.nvim_buf_get_lines(second.buffer, 0, -1, false), { "edited only in memory" }, "buffer content kept")
  eq(read(path), "original", "file content untouched")
end)

test("an unloaded matching buffer is reused by number", function()
  fresh()
  write("src/hidden.lua", { "hidden" })
  local first, first_err = call({ path = "src/hidden.lua" })
  expect_ok(first, first_err)
  vim.cmd("silent! enew")

  local second, second_err = call({ path = "src/hidden.lua" })
  expect_ok(second, second_err)
  eq(second.buffer, first.buffer, "buffer number reused")
  eq(second.reused, true, "unloaded buffer still counts as reuse")
  eq(vim.api.nvim_get_current_buf(), first.buffer, "buffer shown again")
end)

test("an existing target window is focused instead of duplicated", function()
  fresh()
  write("src/multi.lua", { "one", "two" })
  local first, first_err = call({ path = "src/multi.lua" })
  expect_ok(first, first_err)
  local target_win = vim.api.nvim_get_current_win()

  vim.cmd("vsplit")
  vim.cmd("silent! enew")
  local other_win = vim.api.nvim_get_current_win()
  check(other_win ~= target_win, "split created a second window")
  local window_count = #vim.api.nvim_list_wins()

  local second, second_err = call({ path = "src/multi.lua", line = 2, column = 1 })
  expect_ok(second, second_err)

  eq(vim.api.nvim_get_current_win(), target_win, "focused existing window")
  eq(vim.api.nvim_win_get_buf(target_win), first.buffer, "target window still shows the file")
  eq(#vim.api.nvim_list_wins(), window_count, "no extra window")
  eq(vim.api.nvim_win_get_cursor(target_win), { 2, 0 }, "cursor in target window")
end)

test("the current window wins when several windows show the target", function()
  fresh()
  write("src/current.lua", { "current" })
  local first, first_err = call({ path = "src/current.lua" })
  expect_ok(first, first_err)
  vim.cmd("vsplit")
  local current_win = vim.api.nvim_get_current_win()
  eq(vim.api.nvim_win_get_buf(current_win), first.buffer, "both windows show the file")

  local second, second_err = call({ path = "src/current.lua" })
  expect_ok(second, second_err)
  eq(vim.api.nvim_get_current_win(), current_win, "current window stays current")
  eq(second.buffer, first.buffer, "same buffer")
end)

test("a file not shown anywhere opens in the current window", function()
  fresh()
  write("src/one.lua", { "one" })
  write("src/two.lua", { "two" })
  local first, first_err = call({ path = "src/one.lua" })
  expect_ok(first, first_err)

  vim.cmd("vsplit")
  vim.cmd("silent! enew")
  local current_win = vim.api.nvim_get_current_win()
  local window_count = #vim.api.nvim_list_wins()

  local second, second_err = call({ path = "src/two.lua" })
  expect_ok(second, second_err)
  eq(vim.api.nvim_get_current_win(), current_win, "current window used")
  eq(vim.api.nvim_win_get_buf(current_win), second.buffer, "current window shows new file")
  eq(#vim.api.nvim_list_wins(), window_count, "window count unchanged")
end)

test("a target window in another tab is selected", function()
  fresh()
  write("src/tabbed.lua", { "tabbed" })
  local first, first_err = call({ path = "src/tabbed.lua" })
  expect_ok(first, first_err)
  local target_win = vim.api.nvim_get_current_win()
  local target_tab = vim.api.nvim_get_current_tabpage()

  vim.cmd("tabnew")
  local other_tab = vim.api.nvim_get_current_tabpage()
  check(other_tab ~= target_tab, "new tab created")

  local second, second_err = call({ path = "src/tabbed.lua" })
  expect_ok(second, second_err)
  eq(vim.api.nvim_get_current_win(), target_win, "target window selected")
  eq(vim.api.nvim_get_current_tabpage(), target_tab, "target tab selected")
end)

test("handler responds when invoked from a libuv callback", function()
  fresh()
  write("src/async.lua", { "async" })
  local done = false
  local result, response_err
  local timer = vim.uv.new_timer()
  timer:start(0, 0, function()
    handler()({ path = "src/async.lua", line = 1, column = 1 }, {
      project_root = project,
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
  eq(result.path, "src/async.lua", "async result")
  eq(vim.api.nvim_buf_get_name(0), project .. "/src/async.lua", "async buffer opened")
end)

test("the request token is never included in results or errors", function()
  fresh()
  write("src/token.lua", { "token" })
  local secret = "super-secret-token"
  local ctx = { project_root = project, token = secret }

  local result, err = call({ path = "src/token.lua" }, ctx)
  expect_ok(result, err)
  check(not vim.json.encode(result):find(secret, 1, true), "token absent from result")

  result, err = call({ path = "missing.lua" }, ctx)
  expect_error(result, err, protocol.ERROR_CODES.NOT_FOUND, "missing")
  check(not vim.json.encode(err):find(secret, 1, true), "token absent from error")
end)

io.stdout:write(("\nOpen tests: %d total, %d passed, %d failed, %d skipped\n"):format(
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
