local source = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(source, ":p:h:h")
local BASE = "/tmp/opencode"

local USAGE = [[
Usage: bash tests/run.sh [path ...]

Runs every *_spec.lua file under tests/unit by default. Each path may be a
single test file or a directory; directories are searched recursively.

The environment must already be isolated by tests/run.sh. Direct Neovim
invocations are refused unless HOME, all XDG directories, TMPDIR and the
shada file point inside /tmp/opencode.
]]

local function under_base(value)
  return type(value) == "string"
    and #value > #BASE
    and value:sub(1, #BASE + 1) == BASE .. "/"
    and not value:find("%.%.")
end

local function refuse(message)
  io.stderr:write("refusing to run tests: " .. message .. "\n")
  io.stderr:write("use tests/run.sh to create an isolated environment\n")
  vim.cmd("cquit 2")
end

local required_env = {
  "HOME",
  "XDG_CONFIG_HOME",
  "XDG_DATA_HOME",
  "XDG_STATE_HOME",
  "XDG_CACHE_HOME",
  "XDG_RUNTIME_DIR",
  "TMPDIR",
}
for _, name in ipairs(required_env) do
  if not under_base(vim.env[name]) then
    refuse(("%s is not isolated under %s"):format(name, BASE))
  end
end

for _, name in ipairs({ "config", "data", "state", "cache" }) do
  if not under_base(vim.fn.stdpath(name)) then
    refuse(("stdpath(%q) is not isolated under %s"):format(name, BASE))
  end
end

if vim.o.shadafile ~= "NONE" and not under_base(vim.o.shadafile) then
  refuse(("shada file %q is not isolated under %s"):format(vim.o.shadafile, BASE))
end

vim.opt.runtimepath:prepend(repo)
package.path = repo .. "/?.lua;" .. repo .. "/?/init.lua;" .. package.path

local requested = {}
for _, value in ipairs(_G.arg or {}) do
  if value == "--help" or value == "-h" then
    io.stdout:write(USAGE)
    vim.cmd("cquit 0")
  elseif value:sub(1, 1) == "-" then
    io.stderr:write("unknown option: " .. value .. "\n" .. USAGE)
    vim.cmd("cquit 2")
  else
    requested[#requested + 1] = value
  end
end

local test = require("tests.support.test")

local function resolve_path(value)
  local direct = vim.fn.fnamemodify(value, ":p")
  if vim.fn.filereadable(direct) == 1 or vim.fn.isdirectory(direct) == 1 then
    return direct:gsub("/$", "")
  end
  return repo .. "/" .. value
end

local files = {}
for _, value in ipairs(requested) do
  local path = resolve_path(value)
  if vim.fn.isdirectory(path) == 1 then
    vim.list_extend(files, vim.fn.glob(path .. "/**/*_spec.lua", false, true))
  else
    files[#files + 1] = path
  end
end
if #files == 0 then
  files = vim.fn.glob(repo .. "/tests/unit/**/*_spec.lua", false, true)
end
table.sort(files)

if #files == 0 then
  io.stderr:write("no test files found under tests/unit/**/*_spec.lua\n")
  vim.cmd("cquit 1")
end

for _, file in ipairs(files) do
  local display = file
  if file:sub(1, #repo + 1) == repo .. "/" then
    display = file:sub(#repo + 2)
  end
  io.stdout:write(("\n== %s ==\n"):format(display))
  local ok, err = pcall(dofile, file)
  if not ok then
    test.total = test.total + 1
    test.failed = test.failed + 1
    test.failures[#test.failures + 1] = file .. ": " .. tostring(err)
    io.stdout:write("not ok - " .. file .. ": " .. tostring(err) .. "\n")
  end
end

local ok = test.finish()
vim.cmd(ok and "cquit 0" or "cquit 1")
