-- Adapter between the completion sources and the stateless OpenCode client.
--
-- The current public client covers sessions, prompts, commands and events but
-- not the V2 filesystem/command/agent/skill query routes.  Completion sources
-- therefore talk to this adapter instead of reaching into client internals.
--
-- Canonical client methods (callback style, same shape as opencode.client):
--
--   client.find_files(_, params, callback)
--   client.list_files(_, params, callback)
--   client.list_commands(_, params, callback)
--   client.list_agents(_, params, callback)
--   client.list_skills(_, params, callback)
--
-- params for queries:
--
--   find_files   = { location = { directory = root }, query = text,
--                    type = "file"|"directory"|nil, limit = n }
--   list_files   = { location = { directory = root }, path = relative|abs }
--   list_commands/agents/skills = { location = { directory = root } }
--
-- callback is `(err, data, response)`; `data` is normally the V2
-- `{ location, data }` envelope.  Methods are called as
-- `method(client, params, callback)` (the convention already used by
-- opencode.session); a plain two-argument `(params, callback)` fake is also
-- accepted.  For integration convenience the adapter also accepts nested
-- `client.file.find/list`, `client.fs.find/list`,
-- `client.filesystem.find/list` and `client.completion.*` names, plus a few
-- snake_case aliases.
--
-- A method call may return a cancel function, a table with
-- cancel/abort/stop, or `(cancel, err)`.  If the route is missing the adapter
-- reports `endpoint_unavailable`; it never invents an HTTP request.

local util = require("opencode.completion.sources.util")

local M = {}

local METHOD_SPECS = {
  find_files = {
    label = "find_files",
    aliases = { "file_find", "fs_find", "filesystem_find" },
    nested = {
      { "file", "find" },
      { "fs", "find" },
      { "filesystem", "find" },
      { "completion", "find_files" },
    },
  },
  list_files = {
    label = "list_files",
    aliases = { "file_list", "fs_list", "filesystem_list" },
    nested = {
      { "file", "list" },
      { "fs", "list" },
      { "filesystem", "list" },
      { "completion", "list_files" },
    },
  },
  list_commands = {
    label = "list_commands",
    aliases = { "command_list" },
    nested = {
      { "command", "list" },
      { "completion", "list_commands" },
    },
  },
  list_agents = {
    label = "list_agents",
    aliases = { "agent_list" },
    nested = {
      { "agent", "list" },
      { "completion", "list_agents" },
    },
  },
  list_skills = {
    label = "list_skills",
    aliases = { "skill_list" },
    nested = {
      { "skill", "list" },
      { "completion", "list_skills" },
    },
  },
}

M.METHOD_SPECS = METHOD_SPECS

local Api = {}
Api.__index = Api

--- @param client table|nil
--- @param opts table|nil
--- @return table
function M.new(client, opts)
  return setmetatable({
    client = client,
    opts = opts or {},
  }, Api)
end

--- Replace the client and let the owner invalidate its caches.
--- @param client table|nil
function Api:set_client(client)
  self.client = client
end

--- @param name string
--- @return table|nil spec
function M.method_spec(name)
  return METHOD_SPECS[name]
end

--- @param path string[]
--- @return function|nil method
--- @return table|nil owner
--- @return string|nil label
local function nested_method(client, path)
  local owner = client
  for index = 1, #path - 1 do
    if type(owner) ~= "table" then
      return nil
    end
    owner = owner[path[index]]
  end
  if type(owner) ~= "table" then
    return nil
  end
  local method = owner[path[#path]]
  if type(method) == "function" then
    return method, owner, table.concat(path, ".")
  end
  return nil
end

--- Call a client method using the project convention `(self, params, cb)`.
--- A plain two-argument `(params, cb)` fake is also accepted so sources can be
--- exercised without a full client implementation.
--- @param method function
--- @param owner table
--- @param params table
--- @param callback function
--- @return boolean ok
--- @return any first
--- @return any second
local function call_method(method, owner, params, callback)
  local ok, info = pcall(debug.getinfo, method, "u")
  if ok and type(info) == "table" and info.nparams == 2 and not info.isvararg then
    return pcall(method, params, callback)
  end
  return pcall(method, owner, params, callback)
end

--- @param name string
--- @return function|nil method
--- @return table|nil owner
--- @return string|nil label
function Api:_resolve(name)
  local spec = METHOD_SPECS[name]
  if not spec or type(self.client) ~= "table" then
    return nil
  end
  local client = self.client

  local direct = client[spec.label]
  if type(direct) == "function" then
    return direct, client, spec.label
  end
  for _, alias in ipairs(spec.aliases) do
    local method = client[alias]
    if type(method) == "function" then
      return method, client, alias
    end
  end
  for _, path in ipairs(spec.nested) do
    local method, owner, label = nested_method(client, path)
    if method then
      return method, owner, label
    end
  end
  return nil
end

--- @param name string
--- @return boolean
function Api:has(name)
  local method = self:_resolve(name)
  return method ~= nil
end

--- Invoke one query route.
--- @param name string
--- @param params table
--- @param callback fun(err: table|nil, data: any, response: any)
--- @return function|nil cancel
--- @return table|nil immediate_err
function Api:call(name, params, callback)
  if type(callback) ~= "function" then
    return nil, util.error("invalid_argument", "callback must be a function")
  end
  local spec = METHOD_SPECS[name]
  if not spec then
    return nil, util.error("unknown_endpoint", "unknown completion endpoint: " .. tostring(name))
  end
  local method, owner, label = self:_resolve(name)
  if not method then
    local err = util.error(
      "endpoint_unavailable",
      ("client does not provide %s; completion needs a client adapter or the corresponding OpenCode V2 route"):format(
        name
      ),
      { endpoint = name, expected = spec.label }
    )
    callback(err, nil, nil)
    return nil
  end

  local finished = false
  local function done(err, data, response)
    if finished then
      return
    end
    finished = true
    callback(util.normalize_error(err, name .. "_failed"), data, response)
  end

  local ok, first, second = call_method(method, owner, params, done)
  if not ok then
    done(util.error("client_error", ("%s failed: %s"):format(label or name, tostring(first))))
    return nil
  end

  if finished then
    return nil
  end

  if second ~= nil then
    done(second, nil, nil)
    return nil
  end

  local cancel = util.normalize_cancel(first)
  if cancel then
    return cancel
  end

  -- A few project clients report synchronous argument errors as the first
  -- return value instead of calling the callback.
  if type(first) == "string" and first ~= "" then
    done(util.error("client_error", first))
  elseif type(first) == "table" and (first.code ~= nil or first.message ~= nil or first.kind ~= nil) then
    done(first, nil, nil)
  end
  return nil
end

return M
