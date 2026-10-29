-- Instance registry for local Neovim tool servers.
--
-- Each instance is stored as <registry_dir>/<instance_id>.json:
--   { "schema": 1, "instance_id": "...", "project_root": "/canonical/abs",
--     "url": "http://127.0.0.1:<port>", "token": "<secret>", "pid": 123,
--     "started_at": 1700000000 }
--
-- Directory mode is 0700 and files are written atomically with mode 0600.
-- Tokens must never be logged or included in user-visible errors.

local uv = vim.uv or vim.loop

local M = {}

M.SCHEMA_VERSION = 1
M.FILE_MODE = 384 -- 0600
M.DIR_MODE = 448 -- 0700

local function default_dir()
  local override = vim.env.OPENCODE_NVIM_REGISTRY_DIR
  if type(override) == "string" and override ~= "" then
    return vim.fs.normalize(vim.fn.fnamemodify(override, ":p"))
  end
  return vim.fs.joinpath(vim.fn.stdpath("state"), "opencode", "tools")
end

local function registry_dir(opts)
  local dir = opts and opts.dir or default_dir()
  if type(dir) ~= "string" or dir == "" then
    error("registry.dir must be a non-empty string")
  end
  dir = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p"))
  if #dir > 1 then
    dir = dir:gsub("/+$", "")
  end
  return dir
end

local function delimited(dir)
  local sep = package.config:sub(1, 1)
  if dir:sub(-1) ~= "/" and dir:sub(-1) ~= sep then
    return dir .. sep
  end
  return dir
end

function M.dir(opts)
  return registry_dir(opts)
end

--- Canonicalize a project path using realpath when possible.
-- Returns an absolute path without a trailing slash, or nil for invalid input.
function M.canonicalize(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local resolved = uv.fs_realpath(path)
  if resolved then
    path = resolved
  else
    path = vim.fn.fnamemodify(path, ":p")
  end
  path = vim.fs.normalize(path)
  if #path > 1 then
    path = path:gsub("/+$", "")
  end
  if path == "" then
    path = "/"
  end
  return path
end

local function valid_instance_id(id)
  return type(id) == "string"
    and #id > 0
    and #id <= 128
    and id:match("^[A-Za-z0-9][A-Za-z0-9._-]*$") ~= nil
end

function M.valid_instance_id(id)
  return valid_instance_id(id)
end

function M.path(instance_id, opts)
  if not valid_instance_id(instance_id) then
    return nil, "invalid instance_id"
  end
  return delimited(registry_dir(opts)) .. instance_id .. ".json"
end

local function chmod(path, mode)
  local ok, err = uv.fs_chmod(path, mode)
  if not ok then
    return nil, err
  end
  return true
end

--- Create the registry directory with 0700 permissions.
function M.ensure_dir(opts)
  local dir = registry_dir(opts)
  local current = dir
  local stack = {}
  while current and current ~= "" and current ~= "/" do
    local stat = uv.fs_stat(current)
    if stat then
      if stat.type ~= "directory" then
        return nil, "registry path is not a directory"
      end
      break
    end
    table.insert(stack, 1, current)
    local parent = vim.fs.dirname(current)
    if parent == current then
      break
    end
    current = parent
  end
  for _, item in ipairs(stack) do
    local ok, err = uv.fs_mkdir(item, M.DIR_MODE)
    if not ok and not uv.fs_stat(item) then
      return nil, "cannot create registry directory: " .. tostring(err)
    end
  end
  local ok, err = chmod(dir, M.DIR_MODE)
  if not ok then
    return nil, "cannot set registry directory permissions: " .. tostring(err)
  end
  return true
end

function M.validate_entry(entry)
  if type(entry) ~= "table" or vim.islist(entry) then
    return nil, "entry must be an object"
  end
  if entry.schema ~= M.SCHEMA_VERSION then
    return nil, "unsupported entry schema"
  end
  if not valid_instance_id(entry.instance_id) then
    return nil, "invalid instance_id"
  end
  if
    type(entry.project_root) ~= "string"
    or entry.project_root == ""
    or entry.project_root:sub(1, 1) ~= "/"
  then
    return nil, "invalid project_root"
  end
  if type(entry.url) ~= "string" then
    return nil, "invalid url"
  end
  local port = tonumber(entry.url:match("^http://127%.0%.0%.1:(%d+)$") or "")
  if not port or port < 1 or port > 65535 then
    return nil, "invalid url"
  end
  if type(entry.token) ~= "string" or entry.token == "" then
    return nil, "invalid token"
  end
  if type(entry.pid) ~= "number" or entry.pid <= 0 or entry.pid % 1 ~= 0 then
    return nil, "invalid pid"
  end
  return entry
end

--- Return a copy with secrets removed, suitable for logging.
function M.redact(entry)
  if type(entry) ~= "table" then
    return entry
  end
  local copy = vim.deepcopy(entry)
  if copy.token then
    copy.token = "<redacted>"
  end
  return copy
end

local function encode(entry)
  return vim.json.encode(entry)
end

local function atomic_write(path, data)
  local tmp = string.format("%s.tmp.%d.%x", path, uv.os_getpid(), uv.hrtime())
  local fd, err = uv.fs_open(tmp, "wx", M.FILE_MODE)
  if not fd then
    return nil, "cannot create registry entry: " .. tostring(err)
  end
  local cleanup = function()
    pcall(uv.fs_close, fd)
    pcall(uv.fs_unlink, tmp)
  end
  local offset = 0
  while offset < #data do
    local written, write_err = uv.fs_write(fd, data:sub(offset + 1), offset)
    if not written or written <= 0 then
      cleanup()
      return nil, "cannot write registry entry: " .. tostring(write_err or "short write")
    end
    offset = offset + written
  end
  if uv.fs_fsync then
    uv.fs_fsync(fd)
  end
  local closed, cerr = uv.fs_close(fd)
  if not closed then
    cleanup()
    return nil, "cannot close registry entry: " .. tostring(cerr)
  end
  local renamed, rerr = uv.fs_rename(tmp, path)
  if not renamed then
    pcall(uv.fs_unlink, tmp)
    return nil, "cannot publish registry entry: " .. tostring(rerr)
  end
  chmod(path, M.FILE_MODE)
  -- Best-effort directory sync so the rename survives a crash. Some
  -- platforms/filesystems do not allow opening directories for fsync.
  local dir_fd = uv.fs_open(vim.fs.dirname(path), "r", 0)
  if dir_fd then
    pcall(uv.fs_fsync, dir_fd)
    pcall(uv.fs_close, dir_fd)
  end
  return true
end

--- Register (or update) one instance.
-- Returns the registry file path, or nil, error. The token is required.
function M.register(entry, opts)
  if type(entry) ~= "table" then
    return nil, "entry must be an object"
  end
  local root = M.canonicalize(entry.project_root)
  if not root then
    return nil, "invalid project_root"
  end
  local record = {
    schema = entry.schema or M.SCHEMA_VERSION,
    instance_id = entry.instance_id,
    project_root = root,
    url = entry.url,
    token = entry.token,
    pid = entry.pid,
    started_at = entry.started_at or os.time(),
  }
  local _, verr = M.validate_entry(record)
  if verr then
    return nil, verr
  end
  local path, perr = M.path(entry.instance_id, opts)
  if not path then
    return nil, perr
  end
  local ok, derr = M.ensure_dir(opts)
  if not ok then
    return nil, derr
  end
  local written, werr = atomic_write(path, encode(record))
  if not written then
    return nil, werr
  end
  return path
end

function M.unregister(instance_id, opts)
  local path = M.path(instance_id, opts)
  if not path then
    return nil, "invalid instance_id"
  end
  if not uv.fs_stat(path) then
    return true
  end
  local ok, err = uv.fs_unlink(path)
  if not ok then
    return nil, "cannot remove registry entry: " .. tostring(err)
  end
  return true
end

local function read_entry(path)
  local fd = uv.fs_open(path, "r", 0)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  if not stat or stat.size > 64 * 1024 then
    uv.fs_close(fd)
    return nil
  end
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if type(data) ~= "string" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  local valid = M.validate_entry(decoded)
  return valid and decoded or nil
end

--- List valid registry entries. Invalid files are ignored, never deleted.
function M.list(opts)
  local dir = registry_dir(opts)
  local ok, iter = pcall(uv.fs_scandir, dir)
  if not ok or not iter then
    return {}
  end
  local entries = {}
  while true do
    local name, kind = uv.fs_scandir_next(iter)
    if not name then
      break
    end
    if (kind == "file" or kind == nil) and name:match("^[A-Za-z0-9][A-Za-z0-9._-]*%.json$") then
      local entry = read_entry(delimited(dir) .. name)
      if entry then
        table.insert(entries, entry)
      end
    end
  end
  table.sort(entries, function(a, b)
    return a.instance_id < b.instance_id
  end)
  return entries
end

function M.get(instance_id, opts)
  local path = M.path(instance_id, opts)
  if not path then
    return nil, "invalid instance_id"
  end
  local entry = read_entry(path)
  if not entry then
    return nil, "instance not found"
  end
  return entry
end

--- Return entries whose canonical project root matches.
function M.find(project_root, opts)
  local root = M.canonicalize(project_root)
  if not root then
    return {}
  end
  local matches = {}
  for _, entry in ipairs(M.list(opts)) do
    if entry.project_root == root then
      table.insert(matches, entry)
    end
  end
  return matches
end

--- True when the recorded process is gone or the entry is invalid.
function M.is_stale(entry)
  local valid = M.validate_entry(entry)
  if not valid then
    return true
  end
  -- luv returns 0 on success and (nil, err) when the process is gone.
  local ok, ret, err = pcall(uv.kill, entry.pid, 0)
  if not ok then
    return true
  end
  if ret == 0 or ret == true then
    return false
  end
  if type(err) == "string" and err:match("EPERM") then
    return false
  end
  return true
end

--- Remove registry entries whose recorded process no longer exists.
-- Returns the removed entries (tokens redacted).
function M.cleanup(opts)
  local removed = {}
  for _, entry in ipairs(M.list(opts)) do
    if M.is_stale(entry) then
      local ok = M.unregister(entry.instance_id, opts)
      if ok then
        table.insert(removed, M.redact(entry))
      end
    end
  end
  return removed
end

--- Record a local HTTP response for the tiny health probe.
local function parse_http_response(data)
  local status = data:match("^HTTP/1%.[01] (%d%d%d)")
  if not status then
    return nil
  end
  local head_end = data:find("\r\n\r\n", 1, true)
  if not head_end then
    return nil
  end
  local headers = {}
  local head = data:sub(1, head_end - 1)
  for line in head:gmatch("[^\r\n]+") do
    local name, value = line:match("^([^:]+):%s*(.*)$")
    if name then
      headers[name:lower()] = value
    end
  end
  return tonumber(status), headers, data:sub(head_end + 4)
end

--- Probe GET /health for an entry. Callback receives ok, error.
-- Verifies status 200, envelope, and matching instance_id. The token is sent
-- only in the request header and never logged.
function M.health_check(entry, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}
  callback = callback or function() end
  local called = false
  local function finish(ok, err)
    if called then
      return
    end
    called = true
    callback(ok, err)
  end
  local _, invalid = M.validate_entry(entry)
  if invalid then
    finish(false, "invalid instance entry: " .. tostring(invalid))
    return
  end
  local parsed = entry.url:match("^http://127%.0%.0%.1:(%d+)$")
  if not parsed then
    finish(false, "invalid instance url")
    return
  end
  local timeout = opts.timeout or 1000
  local socket = uv.new_tcp()
  local timer
  local buffer = ""
  local function close()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    if socket and not socket:is_closing() then
      socket:close()
    end
  end
  local function fail(message)
    close()
    finish(false, message)
  end
  local function evaluate(status, body)
    if status ~= 200 then
      fail("health check rejected")
      return
    end
    local ok, decoded = pcall(vim.json.decode, body)
    if not ok or type(decoded) ~= "table" or not decoded.ok then
      fail("health check invalid envelope")
      return
    end
    if
      type(decoded.result) ~= "table"
      or decoded.result.instance_id ~= entry.instance_id
    then
      fail("health check instance mismatch")
      return
    end
    close()
    finish(true)
  end
  -- Evaluate as soon as a Content-Length response is complete, or at EOF
  -- for responses framed by connection close.
  local function maybe_complete(at_eof)
    local status, headers, body = parse_http_response(buffer)
    if not status then
      return false
    end
    local expected = tonumber(headers["content-length"] or "")
    if expected then
      if #body < expected then
        return false
      end
      evaluate(status, body:sub(1, expected))
      return true
    end
    if not at_eof then
      return false
    end
    evaluate(status, body)
    return true
  end
  timer = uv.new_timer()
  timer:start(timeout, 0, function()
    fail("health check timed out")
  end)
  socket:connect("127.0.0.1", tonumber(parsed), function(err)
    if err then
      fail("health check connection failed")
      return
    end
    local req = table.concat({
      "GET /health HTTP/1.1",
      "Host: 127.0.0.1:" .. parsed,
      "Authorization: Bearer " .. entry.token,
      "Connection: close",
      "",
      "",
    }, "\r\n")
    local wrote = socket:write(req)
    if not wrote then
      fail("health check write failed")
    end
  end)
  socket:read_start(function(err, chunk)
    if err then
      fail("health check read failed")
      return
    end
    if not chunk then
      if not maybe_complete(true) then
        fail("health check invalid response")
      end
      return
    end
    buffer = buffer .. chunk
    if #buffer > 64 * 1024 then
      fail("health check response too large")
      return
    end
    maybe_complete(false)
  end)
end

return M
