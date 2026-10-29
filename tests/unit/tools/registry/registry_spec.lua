-- 09A registry unit tests (isolated temp directories under /tmp/opencode).

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":h:h:h:h:h")
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local T = dofile(root .. "/tests/unit/tools/server/helper.lua")
local registry = require("opencode.tools.registry")
local uv = vim.uv

local TOKEN = "registry-secret-token-abcdef"

local function new_dir()
  return T.tempdir("registry") .. "/nested/registry"
end

local function entry(instance_id, overrides)
  local value = {
    schema = registry.SCHEMA_VERSION,
    instance_id = instance_id,
    project_root = T.tempdir("project"),
    url = "http://127.0.0.1:32123",
    token = TOKEN,
    pid = uv.os_getpid(),
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function perms(path)
  local stat = uv.fs_stat(path)
  return stat and bit.band(stat.mode, 511) or nil
end

local function dir_entries(dir)
  local entries = {}
  local iter = uv.fs_scandir(dir)
  if not iter then
    return entries
  end
  while true do
    local name, kind = uv.fs_scandir_next(iter)
    if not name then
      break
    end
    table.insert(entries, { name = name, kind = kind })
  end
  return entries
end

T.test("registry dir is 0700 and entries are 0600", function()
  local dir = new_dir()
  local value = entry("inst-perm")
  local path, err = registry.register(value, { dir = dir })
  T.assert(path, tostring(err))
  T.eq(448, perms(dir), "registry directory mode")
  T.eq(384, perms(path), "registry entry mode")
  T.eq(dir .. "/inst-perm.json", path)
end)

T.test("entries store canonical project roots, url, token, pid and schema", function()
  local dir = new_dir()
  local real = T.tempdir("real-project")
  local link = T.tempdir("link-parent") .. "/project-link"
  local ok, err = uv.fs_symlink(real, link)
  T.assert(ok, tostring(err))
  local path = registry.register(entry("inst-schema", { project_root = link }), { dir = dir })
  T.assert(path)
  local fd = uv.fs_open(path, "r", 0)
  local stat = uv.fs_fstat(fd)
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  local decoded = vim.json.decode(data)
  T.eq(registry.SCHEMA_VERSION, decoded.schema)
  T.eq("inst-schema", decoded.instance_id)
  T.eq(registry.canonicalize(real), decoded.project_root)
  T.eq("http://127.0.0.1:32123", decoded.url)
  T.eq(TOKEN, decoded.token)
  T.eq(uv.os_getpid(), decoded.pid)
  T.eq("number", type(decoded.started_at))
end)

T.test("canonicalize resolves symlinks and normalizes relative paths", function()
  local real = T.tempdir("canon-real")
  local link = T.tempdir("canon-link") .. "/link"
  T.assert(uv.fs_symlink(real, link))
  T.eq(registry.canonicalize(real), registry.canonicalize(link))
  local nested = real .. "/a/../b/./c"
  T.eq(real .. "/b/c", registry.canonicalize(nested))
  T.eq(nil, registry.canonicalize(nil))
  T.eq(nil, registry.canonicalize(""))
end)

T.test("registration is atomic and leaves no temp files", function()
  local dir = new_dir()
  local value = entry("inst-atomic")
  T.assert(registry.register(value, { dir = dir }))
  T.assert(registry.register(entry("inst-atomic", { token = "second-token-value" }), { dir = dir }))
  local names = dir_entries(dir)
  local json, tmp = 0, 0
  for _, item in ipairs(names) do
    if item.name:match("%.json$") then
      json = json + 1
    end
    if item.name:find(".tmp.", 1, true) then
      tmp = tmp + 1
    end
  end
  T.eq(1, json)
  T.eq(0, tmp, "temporary files must be renamed away")
  local stored = registry.get("inst-atomic", { dir = dir })
  T.eq("second-token-value", stored.token)
end)

T.test("multiple instances for one project do not overwrite each other", function()
  local dir = new_dir()
  local project = T.tempdir("multi-project")
  T.assert(registry.register(entry("inst-a", { project_root = project }), { dir = dir }))
  T.assert(registry.register(entry("inst-b", { project_root = project }), { dir = dir }))
  local list = registry.list({ dir = dir })
  T.eq(2, #list)
  T.eq("inst-a", list[1].instance_id)
  T.eq("inst-b", list[2].instance_id)
  local found = registry.find(project, { dir = dir })
  T.eq(2, #found)
  T.eq(0, #registry.find(project .. "/subdir", { dir = dir }), "subdirectory must not match")
  registry.unregister("inst-a", { dir = dir })
  T.eq(1, #registry.list({ dir = dir }))
  T.eq("inst-b", registry.list({ dir = dir })[1].instance_id)
end)

T.test("find only matches the canonical project root", function()
  local dir = new_dir()
  local project_a = T.tempdir("proj-a")
  local project_b = T.tempdir("proj-b")
  T.assert(registry.register(entry("inst-a", { project_root = project_a }), { dir = dir }))
  T.assert(registry.register(entry("inst-b", { project_root = project_b }), { dir = dir }))
  local found = registry.find(project_a, { dir = dir })
  T.eq(1, #found)
  T.eq("inst-a", found[1].instance_id)
  T.eq(0, #registry.find(T.tempdir("other"), { dir = dir }))
end)

T.test("find matches the canonical target of a symlinked project path", function()
  local dir = new_dir()
  local real = T.tempdir("find-real")
  local link = T.tempdir("find-link-parent") .. "/project"
  T.assert(uv.fs_symlink(real, link))
  T.assert(registry.register(entry("inst-link", { project_root = real }), { dir = dir }))
  local found = registry.find(link, { dir = dir })
  T.eq(1, #found)
  T.eq("inst-link", found[1].instance_id)
end)

T.test("stale entries are detected and cleaned, live entries kept", function()
  local dir = new_dir()
  local dead_pid = tonumber(vim.fn.system("sh -c 'echo $$'"):match("%d+"))
  T.assert(dead_pid and dead_pid > 0)
  vim.wait(50)
  T.assert(registry.register(entry("inst-dead", { pid = dead_pid }), { dir = dir }))
  T.assert(registry.register(entry("inst-live"), { dir = dir }))
  local dead = registry.get("inst-dead", { dir = dir })
  local live = registry.get("inst-live", { dir = dir })
  T.eq(true, registry.is_stale(dead))
  T.eq(false, registry.is_stale(live))

  local removed = registry.cleanup({ dir = dir })
  T.eq(1, #removed)
  T.eq("inst-dead", removed[1].instance_id)
  T.eq("<redacted>", removed[1].token, "cleanup results must redact tokens")
  T.eq(nil, registry.get("inst-dead", { dir = dir }))
  T.assert(registry.get("inst-live", { dir = dir }))
end)

T.test("malformed and foreign files are ignored, never deleted", function()
  local dir = new_dir()
  registry.ensure_dir({ dir = dir })
  local junk = dir .. "/notes.txt"
  local handle = assert(io.open(junk, "w"))
  handle:write("not a registry entry")
  handle:close()
  local invalid = dir .. "/inst-invalid.json"
  handle = assert(io.open(invalid, "w"))
  handle:write("{broken")
  handle:close()
  T.eq(0, #registry.list({ dir = dir }))
  local removed = registry.cleanup({ dir = dir })
  T.eq(0, #removed)
  T.assert(uv.fs_stat(junk), "foreign file must survive cleanup")
  T.assert(uv.fs_stat(invalid), "malformed file must survive cleanup")
end)

T.test("invalid instance ids and entries are rejected", function()
  local dir = new_dir()
  T.eq(nil, registry.register(entry("../escape"), { dir = dir }))
  T.eq(nil, registry.register(entry("ok", { token = "" }), { dir = dir }))
  T.eq(nil, registry.register(entry("ok", { url = "http://example.com:1" }), { dir = dir }))
  T.eq(nil, registry.register(entry("ok", { pid = 0 }), { dir = dir }))
  T.eq(nil, registry.path("../x", { dir = dir }))
  T.eq(nil, registry.get("../x", { dir = dir }))
end)

T.test("entry validation matches the TypeScript consumer expectations", function()
  local dir = new_dir()
  T.eq(nil, registry.register(entry("inst-port-high", {
    url = "http://127.0.0.1:70000",
  }), { dir = dir }))
  T.eq(nil, registry.register(entry("inst-port-zero", {
    url = "http://127.0.0.1:0",
  }), { dir = dir }))
  T.eq(nil, registry.register(entry("inst-host", {
    url = "http://localhost:32123",
  }), { dir = dir }))
  T.eq(nil, registry.register(entry("inst-pid-float", { pid = 1.5 }), { dir = dir }))

  local valid = entry("inst-valid")
  T.eq(valid, registry.validate_entry(valid))
  local relative = vim.deepcopy(valid)
  relative.project_root = "relative/path"
  T.eq(nil, registry.validate_entry(relative))
end)

T.test("health_check rejects an invalid entry without echoing the token", function()
  local value = entry("inst-invalid-url", {
    url = "http://127.0.0.1:70000",
  })
  local result
  registry.health_check(value, { timeout = 100 }, function(ok, err)
    result = { ok = ok, err = err }
  end)
  T.assert(result, "invalid entry must fail synchronously")
  T.eq(false, result.ok)
  T.not_contains(result.err, TOKEN)
end)

T.test("redact never exposes the token", function()
  local redacted = registry.redact(entry("inst-redact"))
  T.eq("<redacted>", redacted.token)
  T.not_contains(vim.json.encode(redacted), TOKEN)
  T.eq(TOKEN, entry("inst-redact").token, "redact returns a copy")
end)

T.test("OPENCODE_NVIM_REGISTRY_DIR overrides the default directory", function()
  local dir = T.tempdir("env-registry")
  local old = vim.env.OPENCODE_NVIM_REGISTRY_DIR
  vim.env.OPENCODE_NVIM_REGISTRY_DIR = dir
  local ok, err = pcall(function()
    T.eq(vim.fs.normalize(dir), registry.dir())
  end)
  vim.env.OPENCODE_NVIM_REGISTRY_DIR = old
  if not ok then
    error(err, 0)
  end
end)

local function fake_health_server(expected_token, expected_instance, keep_open)
  local listener = uv.new_tcp()
  assert(listener:bind("127.0.0.1", 0))
  local port = listener:getsockname().port
  local peers = {}
  listener:listen(8, function()
    local socket = uv.new_tcp()
    listener:accept(socket)
    table.insert(peers, socket)
    local buffer = ""
    socket:read_start(function(err, chunk)
      if err or not chunk then
        socket:close()
        return
      end
      buffer = buffer .. chunk
      if not buffer:find("\r\n\r\n", 1, true) then
        return
      end
      local authorized = buffer:find("Authorization: Bearer " .. expected_token, 1, true) ~= nil
      local status, body
      if not authorized then
        status = 401
        body = vim.json.encode({ version = 1, ok = false, error = { code = "UNAUTHORIZED" } })
      else
        status = 200
        body = vim.json.encode({
          version = 1,
          ok = true,
          result = { status = "ok", instance_id = expected_instance },
        })
      end
      local response = table.concat({
        "HTTP/1.1 " .. status .. " OK",
        "Content-Type: application/json",
        "Content-Length: " .. #body,
        "Connection: close",
        "",
        body,
      }, "\r\n")
      socket:write(response, function()
        if not keep_open and not socket:is_closing() then
          socket:close()
        end
      end)
    end)
  end)
  return {
    port = port,
    stop = function()
      listener:close()
      for _, socket in ipairs(peers) do
        if not socket:is_closing() then
          socket:close()
        end
      end
    end,
  }
end

T.test("health_check accepts a Content-Length response without waiting for EOF", function()
  local fake = fake_health_server(TOKEN, "inst-content-length", true)
  local value = entry("inst-content-length", {
    url = "http://127.0.0.1:" .. tostring(fake.port),
  })
  local result
  registry.health_check(value, { timeout = 1000 }, function(ok, err)
    result = { ok = ok, err = err }
  end)
  T.assert(T.wait_for(function()
    return result ~= nil
  end, 2000), "health check did not finish")
  T.eq(true, result.ok, tostring(result.err))
  fake.stop()
end)

T.test("health_check times out against a silent peer", function()
  local listener = uv.new_tcp()
  T.assert(listener:bind("127.0.0.1", 0))
  local port = listener:getsockname().port
  local peers = {}
  listener:listen(8, function()
    local socket = uv.new_tcp()
    listener:accept(socket)
    table.insert(peers, socket)
  end)
  local ok, err = pcall(function()
    local value = entry("inst-silent", {
      url = "http://127.0.0.1:" .. tostring(port),
    })
    local result
    registry.health_check(value, { timeout = 100 }, function(success, message)
      result = { ok = success, err = message }
    end)
    T.assert(T.wait_for(function()
      return result ~= nil
    end, 1500), "health check did not time out")
    T.eq(false, result.ok)
    T.contains(result.err, "timed out")
    T.not_contains(result.err, TOKEN)
  end)
  for _, socket in ipairs(peers) do
    if not socket:is_closing() then
      socket:close()
    end
  end
  listener:close()
  if not ok then
    error(err, 0)
  end
end)

T.test("health_check verifies token, status, envelope and instance id", function()
  local fake = fake_health_server(TOKEN, "inst-health")
  local value = entry("inst-health", {
    url = "http://127.0.0.1:" .. tostring(fake.port),
  })
  local result
  registry.health_check(value, { timeout = 1000 }, function(ok, err)
    result = { ok = ok, err = err }
  end)
  T.assert(T.wait_for(function()
    return result ~= nil
  end, 2000), "health check did not finish")
  T.eq(true, result.ok, tostring(result.err))

  local wrong = vim.deepcopy(value)
  wrong.token = "wrong-token"
  result = nil
  registry.health_check(wrong, { timeout = 1000 }, function(ok, err)
    result = { ok = ok, err = err }
  end)
  T.assert(T.wait_for(function()
    return result ~= nil
  end, 2000))
  T.eq(false, result.ok)
  T.contains(result.err, "rejected")

  result = nil
  registry.health_check(entry("inst-other", {
    url = value.url,
  }), { timeout = 1000 }, function(ok, err)
    result = { ok = ok, err = err }
  end)
  T.assert(T.wait_for(function()
    return result ~= nil
  end, 2000))
  T.eq(false, result.ok)
  T.contains(result.err, "mismatch")

  fake.stop()
end)

local shared_test = package.loaded["tests.support.test"]
if shared_test then
  T.run_shared(shared_test)
else
  T.run()
end
