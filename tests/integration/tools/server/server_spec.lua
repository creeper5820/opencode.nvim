-- 09A integration: real loopback server + registry + health probe.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":h:h:h:h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local T = dofile(root .. "/tests/unit/tools/server/helper.lua")
local server_mod = require("opencode.tools.server")
local registry = require("opencode.tools.registry")
local uv = vim.uv

local TOKEN = "integration-secret-token"

local function start_server(instance_id, project_root, handlers)
  local server = server_mod.new({
    token = TOKEN,
    instance_id = instance_id,
    project_root = project_root,
    handlers = handlers or { open = function(input) return { opened = input.path } end },
  })
  local info
  server:start(function(err, value)
    assert(not err, tostring(err))
    info = value
  end)
  assert(info, "server did not start")
  return server, info
end

local function register(info, project_root, opts)
  return registry.register({
    instance_id = info.instance_id,
    project_root = project_root,
    url = info.url,
    token = TOKEN,
    pid = uv.os_getpid(),
  }, opts)
end

local function wait_health(entry, opts, timeout)
  local result
  registry.health_check(entry, opts or { timeout = 1000 }, function(ok, err)
    result = { ok = ok, err = err }
  end)
  assert(T.wait_for(function()
    return result ~= nil
  end, timeout or 2000), "health check did not finish")
  return result
end

T.test("server registers a random loopback URL and passes health checks", function()
  local registry_dir = T.tempdir("registry") .. "/instances"
  local project = T.tempdir("project")
  local server, info = start_server("integration-one", project)
  local ok, err = pcall(function()
    T.match("^http://127%.0%.0%.1:%d+$", info.url)
    T.assert(info.port > 0)
    T.assert(info.port ~= 80)

    local path, register_err = register(info, project, { dir = registry_dir })
    T.assert(path, tostring(register_err))
    T.eq(registry_dir .. "/integration-one.json", path)

    local entry = registry.get("integration-one", { dir = registry_dir })
    T.assert(entry)
    T.eq(TOKEN, entry.token)
    T.eq(info.url, entry.url)

    local health = wait_health(entry)
    T.eq(true, health.ok, tostring(health.err))

    local found = registry.find(project, { dir = registry_dir })
    T.eq(1, #found)
    T.eq("integration-one", found[1].instance_id)

    local response = T.request(info.port, { path = "/health", token = TOKEN })
    T.eq(200, response.status)
    T.not_contains(response.body, TOKEN, "health response leaked token")
    T.eq(info.instance_id, response.json.result.instance_id)

    local unauthorized = T.request(info.port, { path = "/health", token = "bad" })
    T.eq(401, unauthorized.status)

    local tool = T.request(info.port, {
      method = "POST",
      path = "/tools/open",
      token = TOKEN,
      body = {
        version = 1,
        request_id = "integration-1",
        action = "open",
        input = { path = "README.md" },
      },
    })
    T.eq(200, tool.status)
    T.eq("README.md", tool.json.result.opened)

    registry.unregister("integration-one", { dir = registry_dir })
    T.eq(nil, registry.get("integration-one", { dir = registry_dir }))
  end)
  server:stop()
  if not ok then
    error(err, 0)
  end
end)

T.test("two instances in one project are independently discoverable", function()
  local registry_dir = T.tempdir("registry") .. "/instances"
  local project = T.tempdir("project")
  local server_a, info_a = start_server("integration-a", project)
  local server_b, info_b = start_server("integration-b", project)
  local ok, err = pcall(function()
    T.assert(register(info_a, project, { dir = registry_dir }))
    T.assert(register(info_b, project, { dir = registry_dir }))
    local found = registry.find(project, { dir = registry_dir })
    T.eq(2, #found)
    T.eq("integration-a", found[1].instance_id)
    T.eq("integration-b", found[2].instance_id)
    T.assert(info_a.url ~= info_b.url, "instances must use distinct ports")

    for _, entry in ipairs(found) do
      T.eq(true, wait_health(entry).ok)
    end

    registry.unregister("integration-a", { dir = registry_dir })
    found = registry.find(project, { dir = registry_dir })
    T.eq(1, #found)
    T.eq("integration-b", found[1].instance_id)
  end)
  server_a:stop()
  server_b:stop()
  if not ok then
    error(err, 0)
  end
end)

T.test("stopped instances fail health checks and can be unregistered", function()
  local registry_dir = T.tempdir("registry") .. "/instances"
  local project = T.tempdir("project")
  local server, info = start_server("integration-stopped", project)
  T.assert(register(info, project, { dir = registry_dir }))
  local entry = registry.get("integration-stopped", { dir = registry_dir })
  T.eq(true, wait_health(entry).ok)
  server:stop()

  local health = wait_health(entry, { timeout = 500 }, 1500)
  T.eq(false, health.ok)
  T.eq(true, registry.unregister("integration-stopped", { dir = registry_dir }))
  T.eq(0, #registry.find(project, { dir = registry_dir }))
end)

T.test("start/stop do not leak listeners across repeated cycles", function()
  local project = T.tempdir("project")
  local server = server_mod.new({
    token = TOKEN,
    instance_id = "integration-cycle",
    project_root = project,
  })
  local ports = {}
  for i = 1, 3 do
    local info
    server:start(function(err, value)
      T.eq(nil, err)
      info = value
    end)
    T.assert(info)
    T.request(info.port, { path = "/health", token = TOKEN })
    ports[i] = info.port
    server:stop()
    local closed = T.request(info.port, { path = "/health", token = TOKEN, timeout = 500 })
    T.eq(nil, closed, "stopped port must refuse connections")
  end
  T.eq(3, #ports)
end)

local shared_test = package.loaded["tests.support.test"]
if shared_test then
  T.run_shared(shared_test)
else
  T.run()
end
