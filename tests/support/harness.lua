local M = {}

local OPENCODE_TMP = "/tmp/opencode"

local function is_under(path, base)
  return type(path) == "string"
    and (path == base or path:sub(1, #base + 1) == base .. "/")
    and not path:find("%.%.")
end

local function normalize_base(value)
  local path = vim.fn.fnamemodify(value, ":p"):gsub("/$", "")
  if not is_under(path, OPENCODE_TMP) then
    error(("opencode test harness: base %q must be inside %s"):format(value, OPENCODE_TMP), 0)
  end
  return path
end

local configured_base = vim.env.OPENCODE_NVIM_TEST_BASE
local BASE = configured_base and configured_base ~= "" and normalize_base(configured_base) or "/tmp/opencode"
local active = {}
local exit_handler_installed = false
local sequence = 0
local process_alive
local MINIMAL_INIT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/tests/minimal_init.lua"

local function ensure_dir(path, mode)
  local ok = vim.fn.mkdir(path, "p")
  if ok == 0 and vim.fn.isdirectory(path) == 0 then
    error("opencode test harness: could not create " .. path, 0)
  end
  if mode then
    local changed, err = vim.uv.fs_chmod(path, mode)
    if not changed then
      error(("opencode test harness: could not chmod %s: %s"):format(path, tostring(err)), 0)
    end
  end
end

local function install_exit_handler()
  if exit_handler_installed then
    return
  end
  exit_handler_installed = true
  local group = vim.api.nvim_create_augroup("OpencodeNvimTestHarness", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for harness in pairs(active) do
        pcall(harness.cleanup, harness)
      end
    end,
  })
end

local function is_within_root(path)
  return is_under(path, BASE) and path ~= BASE
end

M.__index = M

--- Create an isolated environment. Nothing is spawned yet.
function M.new()
  install_exit_handler()
  ensure_dir(BASE)
  sequence = sequence + 1
  local unique = ("%d-%d-%d"):format(vim.uv.os_getpid(), vim.uv.hrtime(), sequence)
  local root = ("%s/nvim-%s"):format(BASE, unique)
  local paths = {
    root = root,
    home = root .. "/home",
    config = root .. "/config",
    data = root .. "/data",
    state = root .. "/state",
    cache = root .. "/cache",
    runtime = root .. "/runtime",
    project = root .. "/project",
    tmp = root .. "/tmp",
    shada = root .. "/state/shada/main.shada",
    service = root .. "/service",
    registry = root .. "/registry",
  }
  for _, dir in ipairs({
    paths.root, paths.home, paths.config, paths.data, paths.state,
    paths.cache, paths.project, paths.tmp,
    vim.fn.fnamemodify(paths.shada, ":h"),
    paths.service, paths.registry,
  }) do
    ensure_dir(dir)
  end
  ensure_dir(paths.runtime, 448) -- 0700, as required for XDG_RUNTIME_DIR
  vim.fn.writefile({ "isolated test project" }, paths.project .. "/README")

  local harness = setmetatable({
    paths = paths,
    env = {},
    jobs = {},
    pids = {},
    children = {},
    cleanups = {},
    script_counter = 0,
    cleaned = false,
  }, M)

  harness.env = {
    HOME = paths.home,
    XDG_CONFIG_HOME = paths.config,
    XDG_DATA_HOME = paths.data,
    XDG_STATE_HOME = paths.state,
    XDG_CACHE_HOME = paths.cache,
    XDG_RUNTIME_DIR = paths.runtime,
    TMPDIR = paths.tmp,
    NVIM_APPNAME = "opencode-test",
    OPENCODE_NVIM_TEST_BASE = paths.root .. "/harness",
    PATH = vim.env.PATH or "/usr/local/bin:/usr/bin:/bin",
    LANG = "C.UTF-8",
    TERM = "dumb",
  }
  active[harness] = true
  return harness
end

--- Build a complete child environment. Values passed here are merged over the
--- isolated defaults; nothing from the user's Neovim is inherited by child
--- processes because they are launched through `env -i`.
function M:build_env(extra)
  local env = {}
  for key, value in pairs(self.env) do
    env[key] = value
  end
  for key, value in pairs(extra or {}) do
    if type(key) ~= "string" then
      error("opencode test harness: environment keys must be strings", 0)
    end
    local text = tostring(value)
    if key == "HOME" or key == "TMPDIR" or key:match("^XDG_") then
      if not is_within_root(text) then
        error(("opencode test harness: refusing to point %s outside %s"):format(key, BASE), 0)
      end
    elseif key == "OPENCODE_NVIM_TEST_BASE" then
      if not is_under(text, OPENCODE_TMP) then
        error(("opencode test harness: refusing to point %s outside %s"):format(key, OPENCODE_TMP), 0)
      end
    end
    env[key] = text
  end
  return env
end

function M:command_prefix(extra_env)
  local env = self:build_env(extra_env)
  local names = vim.tbl_keys(env)
  table.sort(names)
  local env_bin = vim.fn.exepath("env")
  if env_bin == "" then
    env_bin = "/usr/bin/env"
  end
  local cmd = { env_bin, "-i" }
  for _, key in ipairs(names) do
    cmd[#cmd + 1] = key .. "=" .. env[key]
  end
  return cmd
end

function M:register_job(job, pid)
  if job and job > 0 then
    self.jobs[job] = true
  end
  if pid and pid > 0 then
    self.pids[pid] = true
  end
end

function M:unregister_job(job, pid)
  if job then
    self.jobs[job] = nil
  end
  if pid then
    self.pids[pid] = nil
  end
end

local function resolve_cwd(harness, cwd)
  local path = cwd or harness.paths.project
  path = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
  if not is_within_root(path) then
    error(("opencode test harness: cwd must be inside %s"):format(BASE), 0)
  end
  ensure_dir(path)
  return path
end

local function append_lines(target, data)
  for _, line in ipairs(data or {}) do
    if line ~= "" then
      target[#target + 1] = line
    end
  end
end

--- Spawn an isolated headless Neovim running a Lua script.
--- @param script string Lua source executed with `nvim -l`.
--- @param opts table|nil { timeout = ms, env = table, cwd = string }
--- @return table { code, stdout, stderr, pid }
function M:spawn(script, opts)
  opts = opts or {}
  self.script_counter = self.script_counter + 1
  local script_path = ("%s/test-%03d.lua"):format(self.paths.tmp, self.script_counter)
  vim.fn.writefile(vim.split(script, "\n", { plain = true }), script_path)

  local cmd = self:command_prefix(opts.env)
  for _, arg in ipairs({
    vim.v.progpath, "--headless", "-n", "--noplugin", "-u", MINIMAL_INIT,
    "-i", self.paths.shada, "-l", script_path,
  }) do
    cmd[#cmd + 1] = arg
  end

  local stdout = {}
  local stderr = {}
  local job
  job = vim.fn.jobstart(cmd, {
    cwd = resolve_cwd(self, opts.cwd),
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      append_lines(stdout, data)
    end,
    on_stderr = function(_, data)
      append_lines(stderr, data)
    end,
  })
  if job <= 0 then
    error("opencode test harness: failed to start headless Neovim", 0)
  end

  local pid = vim.fn.jobpid(job)
  self:register_job(job, pid)
  local code = vim.fn.jobwait({ job }, opts.timeout or 30000)[1]
  if code == -1 then
    pcall(vim.fn.jobstop, job)
    local stopped = vim.fn.jobwait({ job }, 1000)[1]
    if stopped == -1 then
      if pid and pid > 0 and process_alive(pid) then
        pcall(vim.uv.kill, pid, 15)
      end
      vim.uv.sleep(20)
      if pid and pid > 0 and process_alive(pid) then
        pcall(vim.uv.kill, pid, 9)
      end
    end
  end
  if not (pid and pid > 0 and process_alive(pid)) then
    self:unregister_job(job, pid)
  end

  local result = {
    code = code,
    stdout = table.concat(stdout, "\n"),
    stderr = table.concat(stderr, "\n"),
    pid = pid,
  }
  self.children[#self.children + 1] = result
  return result
end

--- Start a background process in the isolated environment. The returned
--- handle is registered with this harness; cleanup() stops it even when a test
--- fails without calling stop_process(). Use this for test-owned OpenCode
--- services or other helpers, never for a user's process.
--- @param cmd string[] executable and arguments
--- @param opts table|nil { env = table, cwd = string }
--- @return table { job, pid, code, done, stdout, stderr }
function M:start_process(cmd, opts)
  opts = opts or {}
  if type(cmd) ~= "table" or #cmd == 0 then
    error("opencode test harness: start_process expects a non-empty command list", 0)
  end
  local full = self:command_prefix(opts.env)
  vim.list_extend(full, cmd)

  local handle = { done = false, code = nil, stdout = {}, stderr = {} }
  local job
  job = vim.fn.jobstart(full, {
    cwd = resolve_cwd(self, opts.cwd),
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      append_lines(handle.stdout, data)
    end,
    on_stderr = function(_, data)
      append_lines(handle.stderr, data)
    end,
    on_exit = function(_, code)
      handle.code = code
      handle.done = true
      self:unregister_job(job, handle.pid)
    end,
  })
  if job <= 0 then
    error("opencode test harness: failed to start background process", 0)
  end

  handle.job = job
  handle.pid = vim.fn.jobpid(job)
  self:register_job(job, handle.pid)
  return handle
end

--- Wait for a background process. Returns the exit code, or nil on timeout.
function M:wait_process(handle, timeout)
  if handle.done then
    return handle.code
  end
  local code = vim.fn.jobwait({ handle.job }, timeout or 30000)[1]
  if code == -1 then
    return nil
  end
  handle.code = code
  handle.done = true
  self:unregister_job(handle.job, handle.pid)
  return code
end

--- Stop one background process started by start_process(). Idempotent.
function M:stop_process(handle)
  if not handle.job or handle.done then
    return true
  end
  pcall(vim.fn.jobstop, handle.job)
  local code = vim.fn.jobwait({ handle.job }, 1000)[1]
  if code == -1 and handle.pid and process_alive(handle.pid) then
    pcall(vim.uv.kill, handle.pid, 15)
    code = vim.fn.jobwait({ handle.job }, 1000)[1]
  end
  if code == -1 and handle.pid and process_alive(handle.pid) then
    pcall(vim.uv.kill, handle.pid, 9)
    code = vim.fn.jobwait({ handle.job }, 1000)[1]
  end
  if code ~= -1 then
    handle.code = code
    handle.done = true
  end
  if not (handle.pid and process_alive(handle.pid)) then
    handle.done = true
    self:unregister_job(handle.job, handle.pid)
  end
  return handle.done
end

--- Find a currently free loopback port. This reserves a port for the time of
--- the call only; callers must use it immediately in their own service.
function M:free_port()
  local tcp = vim.uv.new_tcp()
  assert(tcp, "opencode test harness: failed to create TCP handle")
  local call_ok, bound, bind_error = pcall(function()
    if tcp.bind then
      return tcp:bind("127.0.0.1", 0)
    end
    return vim.uv.tcp_bind(tcp, "127.0.0.1", 0)
  end)
  if not call_ok or not bound then
    tcp:close()
    error("opencode test harness: failed to reserve a port: " .. tostring(call_ok and bind_error or bound), 0)
  end
  local ok, address = pcall(function()
    return tcp:getsockname()
  end)
  tcp:close()
  if not ok or not address then
    error("opencode test harness: failed to read the reserved port", 0)
  end
  return address.port
end

--- Register an extra cleanup action owned by this harness.
function M:add_cleanup(fn)
  if type(fn) ~= "function" then
    error("opencode test harness: add_cleanup expects a function", 0)
  end
  self.cleanups[#self.cleanups + 1] = fn
end

process_alive = function(pid)
  if not pid or pid <= 0 then
    return false
  end
  local ok, result = pcall(vim.uv.kill, pid, 0)
  return ok and (result == 0 or result == true)
end

--- Stop only processes started through this harness and delete only its own
--- root directory. Idempotent.
function M:cleanup()
  if self.cleaned then
    return
  end
  self.cleaned = true

  for _, fn in ipairs(self.cleanups) do
    pcall(fn)
  end

  for job in pairs(self.jobs) do
    pcall(vim.fn.jobstop, job)
  end
  self.jobs = {}

  local tracked = {}
  for pid in pairs(self.pids) do
    tracked[#tracked + 1] = pid
    if process_alive(pid) then
      pcall(vim.uv.kill, pid, 15)
    end
  end
  if #tracked > 0 then
    vim.uv.sleep(20)
  end
  for _, pid in ipairs(tracked) do
    if process_alive(pid) then
      pcall(vim.uv.kill, pid, 9)
    end
  end
  self.pids = {}

  if is_within_root(self.paths.root) then
    pcall(vim.fn.delete, self.paths.root, "rf")
  end
  active[self] = nil
end

return M
