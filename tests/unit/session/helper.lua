-- Shared fakes and temp-directory helpers for 05A session tests.
-- Runs inside the isolated headless Neovim started by tests/run.sh. All
-- temporary paths stay under /tmp/opencode.

local uv = vim.uv or vim.loop

local M = {}

local tempdirs = {}

function M.tempdir(label)
  local base = "/tmp/opencode"
  if not uv.fs_stat(base) then
    uv.fs_mkdir(base, 448)
  end
  local dir = string.format("%s/nvim-05a-%s-%d-%x", base, label or "tmp", uv.os_getpid(), uv.hrtime())
  local ok, err = uv.fs_mkdir(dir, 448)
  assert(ok, "cannot create session test temp dir: " .. tostring(err))
  tempdirs[#tempdirs + 1] = dir
  return dir
end

function M.cleanup()
  for _, dir in ipairs(tempdirs) do
    if dir:match("^/tmp/opencode/nvim%-05a%-") then
      vim.fn.delete(dir, "rf")
    end
  end
  tempdirs = {}
end

--- Wrap a test body so its temp directories are removed even on assertion
--- failure.
function M.case(fn)
  return function()
    local ok, err = pcall(fn)
    M.cleanup()
    if not ok then
      error(err, 0)
    end
  end
end

function M.wait_until(predicate, timeout)
  return vim.wait(timeout or 1000, predicate, 5)
end

--- Simple in-memory session_store replacement.
--- opts.records maps project roots to records.
--- opts.get_error / opts.set_error simulate disk failures.
function M.fake_store(opts)
  opts = opts or {}
  local records = {}
  for root, record in pairs(opts.records or {}) do
    records[root] = vim.deepcopy(record)
  end
  local store = {
    path = "/tmp/opencode/fake-sessions.json",
    get_calls = {},
    set_calls = {},
    get_error = opts.get_error,
    set_error = opts.set_error,
  }
  function store:get(root)
    self.get_calls[#self.get_calls + 1] = root
    if self.get_error ~= nil then
      return nil, self.get_error
    end
    local record = records[root]
    return record and vim.deepcopy(record) or nil
  end
  function store:set(root, record)
    self.set_calls[#self.set_calls + 1] = {
      root = root,
      record = vim.deepcopy(record),
    }
    if self.set_error ~= nil then
      return nil, self.set_error
    end
    records[root] = vim.deepcopy(record)
    return true
  end
  function store:remove(root)
    records[root] = nil
    return true
  end
  function store:record(root)
    return records[root] and vim.deepcopy(records[root]) or nil
  end
  return store
end

local function default_create_result(entry)
  return {
    id = "ses_auto",
    location = { directory = entry.params.directory },
  }
end

local function default_list_result()
  return { data = {} }
end

local function default_submit_result()
  return { accepted = true }
end

--- Fake opencode.client.
--
-- handlers[name] may be:
--   - nil: a successful default response
--   - a function(entry, client): take control and call entry.callback later
--   - { result = value } or { error = value }
--
-- entry = {
--   name, args, params, session_id, callback
-- }
function M.fake_client(handlers)
  handlers = handlers or {}
  local client = { calls = {} }

  local defaults = {
    create_session = default_create_result,
    list_sessions = default_list_result,
    prompt = default_submit_result,
    command = default_submit_result,
    interrupt = function()
      return { interrupted = true }
    end,
  }

  local function invoke(name, args)
    local entry = {
      name = name,
      args = args,
      callback = args[#args],
    }
    if name == "create_session" or name == "list_sessions" then
      entry.params = args[1]
    else
      entry.session_id = args[1]
      entry.params = args[2]
    end
    client.calls[#client.calls + 1] = entry

    local handler = handlers[name]
    if handler == nil then
      entry.callback(nil, defaults[name](entry))
    elseif type(handler) == "function" then
      handler(entry, client)
    elseif handler.error ~= nil then
      entry.callback(handler.error)
    else
      entry.callback(nil, handler.result == nil and defaults[name](entry) or handler.result)
    end
  end

  function client.create_session(_, params, callback)
    invoke("create_session", { params, callback })
  end

  function client.list_sessions(_, params, callback)
    invoke("list_sessions", { params, callback })
  end

  function client.prompt(_, session_id, params, callback)
    invoke("prompt", { session_id, params, callback })
  end

  function client.command(_, session_id, params, callback)
    invoke("command", { session_id, params, callback })
  end

  function client.interrupt(_, session_id, opts, callback)
    invoke("interrupt", { session_id, opts, callback })
  end

  function client:count(name)
    local count = 0
    for _, entry in ipairs(self.calls) do
      if entry.name == name then
        count = count + 1
      end
    end
    return count
  end

  function client:last(name)
    for index = #self.calls, 1, -1 do
      if self.calls[index].name == name then
        return self.calls[index]
      end
    end
    return nil
  end

  return client
end

--- Cap a client callback so the test can complete it explicitly.
function M.capture()
  local captured = { calls = 0 }
  function captured:take(entry)
    self.entry = entry
    self.calls = self.calls + 1
  end
  function captured:resolve(err, result)
    assert(self.entry, "callback was not captured")
    local entry = self.entry
    self.entry = nil
    entry.callback(err, result)
  end
  function captured:pending()
    return self.entry ~= nil
  end
  return captured
end

--- Collector callback for (err, value).
function M.collector()
  local collected = { calls = {} }
  function collected.callback(err, value)
    collected.calls[#collected.calls + 1] = { err = err, value = value }
  end
  return collected
end

--- Create a controller with fake dependencies.
function M.controller(opts)
  opts = opts or {}
  local root = opts.root or M.tempdir("project")
  local config = opts.config
  if config == nil then
    config = { project = { root = root } }
  end
  local options = {
    client = opts.client or M.fake_client(),
    store = opts.store or M.fake_store(),
    config = config,
    cwd = opts.cwd,
  }
  local controller = require("opencode.session").new(options)
  return controller, root, options.client, options.store
end

return M
