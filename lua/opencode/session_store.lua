-- Persistent project -> session mapping for the session controller.
--
-- The file is a small JSON object kept in Neovim's state directory:
--
--   <stdpath("state")>/opencode/sessions.json
--
--   {
--     "schema": 1,
--     "sessions": {
--       "/canonical/project/root": {
--         "id": "ses_...",
--         "directory": "/canonical/project/root"
--       }
--     }
--   }
--
-- The directory is created with mode 0700 and the file is replaced atomically
-- with mode 0600, mirroring the tool registry layout. Corrupt or unreadable
-- stores never crash the controller; callers decide whether to recover.

local uv = vim.uv or vim.loop

local M = {}

M.SCHEMA_VERSION = 1
M.FILE_MODE = 384 -- 0600
M.DIR_MODE = 448 -- 0700

local function default_dir()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "opencode")
end

--- Default session record location.
--- @return string
function M.default_path()
  return vim.fs.joinpath(default_dir(), "sessions.json")
end

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if #path > 1 then
    path = path:gsub("/+$", "")
  end
  if path == "" then
    path = "/"
  end
  return path
end

--- Canonicalize a project path using realpath when possible.
--- @param path string|nil
--- @return string|nil
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
  return normalize_path(path)
end

local function chmod(path, mode)
  local ok, err = uv.fs_chmod(path, mode)
  if not ok then
    return nil, err
  end
  return true
end

local function ensure_dir(path)
  local dir = vim.fs.dirname(path)
  local current = dir
  local stack = {}
  while current and current ~= "" and current ~= "/" do
    local stat = uv.fs_stat(current)
    if stat then
      if stat.type ~= "directory" then
        return nil, "session store parent is not a directory"
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
      return nil, "cannot create session store directory: " .. tostring(err)
    end
  end
  local ok, err = chmod(dir, M.DIR_MODE)
  if not ok then
    return nil, "cannot set session store directory permissions: " .. tostring(err)
  end
  return true
end

local function atomic_write(path, data)
  local tmp = string.format("%s.tmp.%d.%x", path, uv.os_getpid(), uv.hrtime())
  local fd, err = uv.fs_open(tmp, "wx", M.FILE_MODE)
  if not fd then
    return nil, "cannot create session store file: " .. tostring(err)
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
      return nil, "cannot write session store file: " .. tostring(write_err or "short write")
    end
    offset = offset + written
  end
  if uv.fs_fsync then
    uv.fs_fsync(fd)
  end
  local closed, cerr = uv.fs_close(fd)
  if not closed then
    cleanup()
    return nil, "cannot close session store file: " .. tostring(cerr)
  end
  local renamed, rerr = uv.fs_rename(tmp, path)
  if not renamed then
    pcall(uv.fs_unlink, tmp)
    return nil, "cannot publish session store file: " .. tostring(rerr)
  end
  chmod(path, M.FILE_MODE)
  local dir_fd = uv.fs_open(vim.fs.dirname(path), "r", 0)
  if dir_fd then
    pcall(uv.fs_fsync, dir_fd)
    pcall(uv.fs_close, dir_fd)
  end
  return true
end

local function read_file(path)
  local stat = uv.fs_stat(path)
  if not stat then
    return nil
  end
  if stat.type ~= "file" then
    return nil, "session store path is not a file"
  end
  if stat.size > 4 * 1024 * 1024 then
    return nil, "session store file is too large"
  end
  local fd, err = uv.fs_open(path, "r", 0)
  if not fd then
    return nil, "cannot open session store file: " .. tostring(err)
  end
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if type(data) ~= "string" then
    return nil, "cannot read session store file"
  end
  return data
end

local function valid_record(record)
  return type(record) == "table"
    and not vim.islist(record)
    and type(record.id) == "string"
    and record.id ~= ""
    and type(record.directory) == "string"
    and record.directory ~= ""
end

local function empty_data()
  return { schema = M.SCHEMA_VERSION, sessions = {} }
end

local Store = {}
Store.__index = Store

--- Create a store bound to one file.
--- @param opts table|nil { path = string }
function M.new(opts)
  opts = opts or {}
  local path = opts.path or M.default_path()
  path = normalize_path(path)
  if not path then
    error("session_store.path must be a non-empty string", 0)
  end
  return setmetatable({ path = path }, Store)
end

--- Read the whole store. Missing files return an empty store; malformed files
--- return nil and an error string without modifying the file.
--- @return table|nil, string|nil
function Store:load()
  local data, err = read_file(self.path)
  if err then
    return nil, err
  end
  if not data then
    return empty_data()
  end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok or type(decoded) ~= "table" or vim.islist(decoded) then
    return nil, "invalid session store JSON"
  end
  if decoded.schema ~= M.SCHEMA_VERSION then
    return nil, "unsupported session store schema"
  end
  if type(decoded.sessions) ~= "table" or vim.islist(decoded.sessions) then
    return nil, "invalid session store sessions"
  end
  return decoded
end

--- Return the record for a project root, or nil when none exists.
--- @param root string
--- @return table|nil, string|nil
function Store:get(root)
  local key = M.canonicalize(root)
  if not key then
    return nil, "invalid project root"
  end
  local data, err = self:load()
  if not data then
    return nil, err
  end
  local record = data.sessions[key]
  if record == nil then
    return nil
  end
  if not valid_record(record) then
    return nil, "invalid session record"
  end
  if M.canonicalize(record.directory) ~= key then
    return nil, "session record location mismatch"
  end
  return {
    id = record.id,
    directory = key,
  }
end

--- Persist one session record, replacing any previous record for the root.
--- @param root string
--- @param record table { id = string, directory = string }
--- @return boolean|nil, string|nil
function Store:set(root, record)
  local key = M.canonicalize(root)
  if not key then
    return nil, "invalid project root"
  end
  if not valid_record(record) then
    return nil, "invalid session record"
  end
  local directory = M.canonicalize(record.directory)
  if directory ~= key then
    return nil, "session record location mismatch"
  end

  local data = self:load()
  if not data then
    -- A corrupt store cannot be merged; recover by replacing it.
    data = empty_data()
  end
  data.sessions[key] = {
    id = record.id,
    directory = key,
  }
  local ok, err = ensure_dir(self.path)
  if not ok then
    return nil, err
  end
  local sessions = data.sessions
  if next(sessions) == nil then
    sessions = vim.empty_dict()
  end
  local encoded = vim.json.encode({
    schema = M.SCHEMA_VERSION,
    sessions = sessions,
  })
  local written, write_err = atomic_write(self.path, encoded)
  if not written then
    return nil, write_err
  end
  return true
end

--- Remove the record for one project root. Idempotent for valid stores.
--- @param root string
--- @return boolean|nil, string|nil
function Store:remove(root)
  local key = M.canonicalize(root)
  if not key then
    return nil, "invalid project root"
  end
  local data, err = self:load()
  if not data then
    return nil, err
  end
  if data.sessions[key] == nil then
    return true
  end
  data.sessions[key] = nil
  local ok, dir_err = ensure_dir(self.path)
  if not ok then
    return nil, dir_err
  end
  local sessions = data.sessions
  if next(sessions) == nil then
    sessions = vim.empty_dict()
  end
  local written, write_err = atomic_write(self.path, vim.json.encode({
    schema = M.SCHEMA_VERSION,
    sessions = sessions,
  }))
  if not written then
    return nil, write_err
  end
  return true
end

return M
