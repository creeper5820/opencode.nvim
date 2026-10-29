-- Current-project session controller.
--
-- This module owns the single OpenCode session used by the current Neovim
-- project. It pins the project root on first use, restores the plugin's
-- recorded session when it still exists at the same location, creates a new
-- session when the record is missing or stale, and routes prompts, commands
-- and structured input through the stateless API client.
--
-- It never parses SSE, builds blocks, renders output or calls vim.notify.
--
-- Public callback convention (matches net/http and the API client):
--
--   callback(err, value)
--
--   err   nil or { code = string, message = string, ... }
--   value snapshot for ensure(); acceptance/interrupt result for
--         prompt/command/submit/interrupt
--
-- A successful submit means the server accepted the request. It never waits
-- for the Agent to finish executing. A successful interrupt with
-- interrupted=false is the server's idle no-op and is not an error.
--
-- Module singleton (assembled by task 10):
--
--   session.ensure(callback)
--   session.get_snapshot()
--   session.prompt(text, callback)
--   session.command(name, arguments, callback)
--   session.submit(input, callback)
--   session.interrupt(opts, callback)   -- opts.resume = boolean|nil
--
-- Dependency injection for independent use and tests:
--
--   local controller = session.new({
--     client = fake_client,          -- opencode.client contract
--     store = fake_store,            -- session_store-compatible instance
--     store_path = "/tmp/...",       -- used when store is omitted
--     config = { project = { root = "/project" } },
--     cwd = function() return vim.fn.getcwd() end,
--   })
--
-- ensure() coalesces concurrent callers into one list/create request. After a
-- reset() or destroy() any still-running client callback belongs to an old
-- generation and is ignored, including its caller callback.

local session_store = require("opencode.session_store")

local M = {}

local Controller = {}
Controller.__index = Controller

local function copy(value)
  if value == nil then
    return nil
  end
  return vim.deepcopy(value)
end

local function make_error(code, message)
  return { code = code, message = message }
end

local function normalize_error(err, fallback_code)
  if err == nil then
    return nil
  end
  if type(err) == "table" then
    local out = {}
    for key, value in pairs(err) do
      out[key] = value
    end
    if out.code == nil then
      out.code = fallback_code
    end
    if out.message == nil then
      out.message = tostring(err)
    end
    return out
  end
  return make_error(fallback_code, tostring(err))
end

local function canonicalize(path)
  return session_store.canonicalize(path)
end

local function call(callback, err, value)
  if type(callback) == "function" then
    callback(err, value)
  end
end

--- Parse the leading OpenCode command form (`/name arguments`).
-- Returns nil when the text is an ordinary prompt. A slash followed by more
-- path segments (`/tmp/file`) is not a command because the name must be
-- followed by whitespace or end of input.
--- @param text string|nil
--- @return string|nil name, string|nil arguments
local function parse_command(text)
  if type(text) ~= "string" then
    return nil
  end
  local name, rest = text:match("^%s*/([%w][%w%-_]*)(%s+.*)$")
  if name then
    return name, (rest:gsub("^%s+", ""))
  end
  name = text:match("^%s*/([%w][%w%-_]*)%s*$")
  if name then
    return name, ""
  end
  return nil
end

M.parse_command = parse_command

--- Unwrap common API response envelopes.
local function unwrap(value)
  local current = value
  for _ = 1, 4 do
    if type(current) ~= "table" then
      return current
    end
    if type(current.session) == "table" then
      current = current.session
    elseif type(current.info) == "table" then
      current = current.info
    elseif type(current.data) == "table"
      and current.id == nil
      and current.sessionID == nil
      and current.session_id == nil
    then
      current = current.data
    else
      break
    end
  end
  return current
end

local function session_id_of(value)
  local current = unwrap(value)
  if type(current) ~= "table" then
    return nil
  end
  local id = current.id or current.sessionID or current.session_id
  if type(id) == "string" and id ~= "" then
    return id
  end
  return nil
end

local function session_directory_of(value)
  local current = unwrap(value)
  if type(current) ~= "table" then
    return nil
  end
  if type(current.location) == "table" and type(current.location.directory) == "string" then
    return current.location.directory
  end
  if type(current.directory) == "string" then
    return current.directory
  end
  if type(current.project) == "table" and type(current.project.directory) == "string" then
    return current.project.directory
  end
  return nil
end

local function session_title_of(value)
  local current = unwrap(value)
  if type(current) == "table" and type(current.title) == "string" then
    return current.title
  end
  return nil
end

local function session_list(result)
  if type(result) ~= "table" then
    return {}
  end
  if vim.islist(result) then
    return result
  end
  if vim.islist(result.data) then
    return result.data
  end
  if vim.islist(result.sessions) then
    return result.sessions
  end
  if type(result.data) == "table" then
    if vim.islist(result.data.sessions) then
      return result.data.sessions
    end
    if vim.islist(result.data.items) then
      return result.data.items
    end
  end
  return {}
end

local function interrupted_of(result)
  if type(result) == "boolean" then
    return result
  end
  local current = unwrap(result)
  if type(current) == "table" and type(current.interrupted) == "boolean" then
    return current.interrupted
  end
  return false
end

local function find_session(result, id)
  for _, value in ipairs(session_list(result)) do
    if session_id_of(value) == id then
      return value
    end
  end
  return nil
end

local function valid_text(text)
  if type(text) ~= "string" then
    return nil, make_error("invalid_input", "prompt text must be a string")
  end
  if text:match("^%s*$") then
    return nil, make_error("empty_input", "prompt text must not be empty")
  end
  return text
end

local PROMPT_FIELDS = {
  id = true,
  text = true,
  files = true,
  agents = true,
  skills = true,
  metadata = true,
  delivery = true,
  resume = true,
}

local COMMAND_FIELDS = {
  files = true,
  agents = true,
  skills = true,
  delivery = true,
}

local function as_list(value)
  if type(value) ~= "table" then
    return { copy(value) }
  end
  if vim.islist(value) then
    return copy(value)
  end
  return { copy(value) }
end

local function prompt_options(input, kind)
  local options = {}
  for key, value in pairs(input) do
    if PROMPT_FIELDS[key] then
      options[key] = copy(value)
    end
  end
  if type(options.text) ~= "string" and type(input.value) == "string" then
    options.text = input.value
  end
  if options.files == nil and input.attachments ~= nil then
    options.files = copy(input.attachments)
  end
  if options.agents == nil then
    local agent = input.agent
    if agent == nil and kind == "agent" then
      agent = input.value or input.name
    end
    if agent ~= nil then
      options.agents = as_list(agent)
    end
  end
  if options.skills == nil then
    local skill = input.skill
    if skill == nil and kind == "skill" then
      skill = input.name or input.value
    end
    if skill ~= nil then
      options.skills = as_list(skill)
    end
  end
  return options
end

local function is_plain_text_input(input)
  for key in pairs(input) do
    if key ~= "text" and key ~= "kind" and key ~= "type" then
      return false
    end
  end
  return type(input.text) == "string"
end

local function command_options(input)
  local options = {}
  for key, value in pairs(input) do
    if COMMAND_FIELDS[key] then
      options[key] = copy(value)
    end
  end
  if options.files == nil and input.attachments ~= nil then
    options.files = copy(input.attachments)
  end
  if options.agents == nil and input.agent ~= nil then
    options.agents = as_list(input.agent)
  end
  if options.skills == nil and input.skill ~= nil then
    options.skills = as_list(input.skill)
  end
  return options
end

--- Create a controller. Dependencies are optional; omitted dependencies use
--- the active plugin configuration and lazy `opencode.client`.
--- @param opts table|nil
function M.new(opts)
  opts = opts or {}
  local store = opts.store
  if store == nil then
    store = session_store.new({ path = opts.store_path })
  end
  return setmetatable({
    opts = opts,
    client = opts.client,
    store = store,
    root = nil,
    session_id = nil,
    session_title = nil,
    status = "uninitialized",
    generation = 0,
    ensure_waiters = nil,
    submission_seq = 0,
    active_submission = nil,
    submission = { status = "idle" },
    interrupt_seq = 0,
    active_interrupt = nil,
    interrupt_state = { status = "idle" },
    last_error = nil,
    store_error = nil,
    destroyed = false,
  }, Controller)
end

function Controller:_config()
  if self.opts.config ~= nil then
    if type(self.opts.config) == "function" then
      return self.opts.config()
    end
    return self.opts.config
  end
  local ok, opencode = pcall(require, "opencode")
  if ok and type(opencode) == "table" and type(opencode.get_config) == "function" then
    local config_ok, config = pcall(opencode.get_config)
    if config_ok then
      return config
    end
  end
  return {}
end

function Controller:_resolve_root()
  if self.root then
    return self.root
  end
  local root
  local config = self:_config()
  if type(config) == "table" and type(config.project) == "table" then
    local configured = config.project.root
    if type(configured) == "string" and configured ~= "" then
      root = configured
    end
  end
  if root == nil then
    if type(self.opts.cwd) == "function" then
      root = self.opts.cwd()
    elseif type(self.opts.cwd) == "string" then
      root = self.opts.cwd
    else
      root = vim.fn.getcwd()
    end
  end
  local resolved = canonicalize(root)
  if not resolved then
    return nil, make_error("invalid_project_root", "cannot determine the project root")
  end
  self.root = resolved
  return resolved
end

function Controller:_get_client()
  if self.client then
    return self.client
  end
  local ok, client = pcall(require, "opencode.client")
  if not ok or type(client) ~= "table" then
    return nil, make_error("client_unavailable", "opencode.client is not available")
  end
  self.client = client
  return client
end

function Controller:_stale(generation, session_id)
  if self.destroyed or self.generation ~= generation then
    return true
  end
  if session_id ~= nil and self.session_id ~= session_id then
    return true
  end
  return false
end

function Controller:_store_get(root)
  local fn = type(self.store) == "table" and self.store.get or nil
  if type(fn) ~= "function" then
    return nil, "session store has no get method"
  end
  local ok, record, err = pcall(fn, self.store, root)
  if not ok then
    return nil, tostring(record)
  end
  return record, err
end

function Controller:_store_set(root, record)
  local fn = type(self.store) == "table" and self.store.set or nil
  if type(fn) ~= "function" then
    return nil, "session store has no set method"
  end
  local ok, saved, err = pcall(fn, self.store, root, record)
  if not ok then
    return nil, tostring(saved)
  end
  return saved, err
end

local function record_matches(record, root)
  if type(record) ~= "table" then
    return false
  end
  if type(record.id) ~= "string" or record.id == "" then
    return false
  end
  if type(record.directory) ~= "string" then
    return false
  end
  return canonicalize(record.directory) == root
end

function Controller:_session_matches(value, id)
  if session_id_of(value) ~= id then
    return false
  end
  local directory = session_directory_of(value)
  if directory ~= nil and canonicalize(directory) ~= self.root then
    return false
  end
  return true
end

function Controller:_adopt(value, id)
  self.session_id = id
  self.session_title = session_title_of(value)
  self.status = "ready"
  self.last_error = nil
end

function Controller:_clear_waiters()
  local waiters = self.ensure_waiters or {}
  self.ensure_waiters = nil
  return waiters
end

function Controller:_finish_ensure(generation)
  if self:_stale(generation) then
    return
  end
  self.status = "ready"
  local waiters = self:_clear_waiters()
  for _, callback in ipairs(waiters) do
    if self:_stale(generation) then
      return
    end
    call(callback, nil, self:get_snapshot())
  end
end

function Controller:_fail_ensure(err, generation)
  if self:_stale(generation) then
    return
  end
  local failure = normalize_error(err, "session_ensure_failed")
  self.status = "failed"
  self.last_error = copy(failure)
  local waiters = self:_clear_waiters()
  for _, callback in ipairs(waiters) do
    if self:_stale(generation) then
      return
    end
    call(callback, copy(failure), nil)
  end
end

function Controller:_restore(record, generation)
  local client, client_err = self:_get_client()
  if not client then
    self:_fail_ensure(client_err, generation)
    return
  end
  if type(client.list_sessions) ~= "function" then
    self:_fail_ensure(make_error("client_method_missing", "client.list_sessions is not available"), generation)
    return
  end
  local ok, call_err, start_err = pcall(client.list_sessions, client, { directory = self.root }, function(err, result)
    if self:_stale(generation) then
      return
    end
    if err ~= nil then
      self:_fail_ensure(normalize_error(err, "session_list_failed"), generation)
      return
    end
    local found = find_session(result, record.id)
    if not found or not self:_session_matches(found, record.id) then
      self:_create(generation)
      return
    end
    self:_adopt(found, record.id)
    self:_finish_ensure(generation)
  end)
  if not ok then
    if self.ensure_waiters ~= nil and not self:_stale(generation) then
      self:_fail_ensure(normalize_error(call_err, "session_list_failed"), generation)
    else
      error(call_err, 0)
    end
  elseif start_err ~= nil and self.ensure_waiters ~= nil and not self:_stale(generation) then
    self:_fail_ensure(normalize_error(start_err, "session_list_failed"), generation)
  end
end

function Controller:_create(generation)
  local client, client_err = self:_get_client()
  if not client then
    self:_fail_ensure(client_err, generation)
    return
  end
  if type(client.create_session) ~= "function" then
    self:_fail_ensure(make_error("client_method_missing", "client.create_session is not available"), generation)
    return
  end
  local ok, call_err, start_err = pcall(client.create_session, client, { directory = self.root }, function(err, result)
    if self:_stale(generation) then
      return
    end
    if err ~= nil then
      self:_fail_ensure(normalize_error(err, "session_create_failed"), generation)
      return
    end
    local id = session_id_of(result)
    if not id then
      self:_fail_ensure(make_error("session_create_failed", "session creation returned no session id"), generation)
      return
    end
    local directory = session_directory_of(result)
    if directory ~= nil and canonicalize(directory) ~= self.root then
      self:_fail_ensure(make_error(
        "session_location_mismatch",
        ("created session is at %q, expected %q"):format(directory, self.root)
      ), generation)
      return
    end

    self:_adopt(result, id)
    local saved, store_err = self:_store_set(self.root, {
      id = id,
      directory = self.root,
    })
    if not saved then
      self.store_error = normalize_error(store_err, "session_store_failed")
    else
      self.store_error = nil
    end
    self:_finish_ensure(generation)
  end)
  if not ok then
    if self.ensure_waiters ~= nil and not self:_stale(generation) then
      self:_fail_ensure(normalize_error(call_err, "session_create_failed"), generation)
    else
      error(call_err, 0)
    end
  elseif start_err ~= nil and self.ensure_waiters ~= nil and not self:_stale(generation) then
    self:_fail_ensure(normalize_error(start_err, "session_create_failed"), generation)
  end
end

--- Ensure a session exists for this project. Concurrent callers share one
--- restore/create request. The callback receives (err, snapshot).
--- @param callback fun(err: table|nil, snapshot: table|nil)
function Controller:ensure(callback)
  if callback ~= nil and type(callback) ~= "function" then
    error("session.ensure expects a callback function or nil", 0)
  end
  if self.destroyed then
    call(callback, make_error("session_destroyed", "session controller has been destroyed"), nil)
    return
  end
  if self.session_id then
    call(callback, nil, self:get_snapshot())
    return
  end
  if self.ensure_waiters then
    self.ensure_waiters[#self.ensure_waiters + 1] = callback
    return
  end

  self.ensure_waiters = { callback }
  self.status = "initializing"
  self.last_error = nil
  local generation = self.generation

  local root, root_err = self:_resolve_root()
  if not root then
    self:_fail_ensure(root_err, generation)
    return
  end

  local record, store_err = self:_store_get(root)
  if store_err ~= nil then
    self.store_error = normalize_error(store_err, "session_store_failed")
    record = nil
  end

  if record_matches(record, root) then
    self:_restore(record, generation)
  else
    self:_create(generation)
  end
end

--- Immutable snapshot of controller state.
--- @return table
function Controller:get_snapshot()
  local snapshot = {
    status = self.status,
    ready = self.session_id ~= nil and not self.destroyed,
    generation = self.generation,
    submission = self.submission.status,
    submission_id = self.submission.id,
    submission_kind = self.submission.kind,
    interrupt = copy(self.interrupt_state),
    error = copy(self.last_error),
  }
  if self.root then
    snapshot.project = { root = self.root }
  end
  if self.session_id then
    snapshot.session = {
      id = self.session_id,
      directory = self.root,
    }
    if self.session_title ~= nil then
      snapshot.session.title = self.session_title
    end
  end
  if self.submission.error ~= nil then
    snapshot.submission_error = copy(self.submission.error)
  end
  if self.store_error ~= nil then
    snapshot.store_error = copy(self.store_error)
  end
  return snapshot
end

function Controller:_fail_submission(kind, err, callback)
  local failure = normalize_error(err, "submit_failed")
  self.submission_seq = self.submission_seq + 1
  self.active_submission = {
    id = self.submission_seq,
    kind = kind,
    generation = self.generation,
    session_id = self.session_id,
  }
  self.submission = {
    id = self.submission_seq,
    status = "failed",
    kind = kind,
    error = copy(failure),
  }
  self.last_error = copy(failure)
  call(callback, failure, nil)
end

function Controller:_fail_interrupt(err, callback, resume)
  local failure = normalize_error(err, "interrupt_failed")
  self.interrupt_seq = self.interrupt_seq + 1
  self.active_interrupt = {
    id = self.interrupt_seq,
    generation = self.generation,
    session_id = self.session_id,
    resume = resume,
  }
  self.interrupt_state = {
    id = self.interrupt_seq,
    status = "failed",
    resume = resume,
    interrupted = false,
    error = copy(failure),
  }
  self.last_error = copy(failure)
  call(callback, failure, nil)
end

function Controller:_start_interrupt(resume, callback)
  if self.destroyed then
    self:_fail_interrupt(make_error("session_destroyed", "session controller has been destroyed"), callback, resume)
    return
  end
  if not self.session_id then
    self:_fail_interrupt(make_error("session_not_ready", "session is not ready"), callback, resume)
    return
  end
  local client, client_err = self:_get_client()
  if not client then
    self:_fail_interrupt(client_err, callback, resume)
    return
  end
  local method = client.interrupt
  if type(method) ~= "function" then
    self:_fail_interrupt(
      make_error("client_method_missing", "client.interrupt is not available"),
      callback,
      resume
    )
    return
  end

  local generation = self.generation
  local session_id = self.session_id
  self.interrupt_seq = self.interrupt_seq + 1
  local token = {
    id = self.interrupt_seq,
    generation = generation,
    session_id = session_id,
    resume = resume,
  }
  self.active_interrupt = token
  self.interrupt_state = {
    id = token.id,
    status = "interrupting",
    resume = resume,
    session_id = session_id,
  }

  local completed = false
  local function done(err, result)
    if completed then
      return
    end
    completed = true
    if self:_stale(generation, session_id) then
      return
    end
    if err ~= nil then
      local failure = normalize_error(err, "interrupt_failed")
      if self.active_interrupt == token then
        self.interrupt_state = {
          id = token.id,
          status = "failed",
          resume = resume,
          interrupted = false,
          error = copy(failure),
        }
        self.last_error = copy(failure)
      end
      call(callback, failure, nil)
      return
    end

    local interrupted = interrupted_of(result)
    if self.active_interrupt == token then
      self.interrupt_state = {
        id = token.id,
        status = interrupted and "interrupted" or "noop",
        resume = resume,
        interrupted = interrupted,
      }
    end
    call(callback, nil, {
      interrupted = interrupted,
      idle = not interrupted,
      resume = resume,
      session_id = session_id,
      interrupt_id = token.id,
      response = result,
    })
  end

  local params = {}
  if resume ~= nil then
    params.resume = resume
  end
  local ok, cancel, start_err = pcall(method, client, session_id, params, done)
  if not ok then
    if completed then
      error(cancel, 0)
    else
      done(make_error("client_error", tostring(cancel)))
    end
  elseif start_err ~= nil and not completed then
    done(start_err)
  end
end

--- Interrupt the execution owned by the current session. The session is
--- created/restored automatically when needed. `resume` is optional and is
--- forwarded to the client interrupt query. A successful idle no-op returns
--- interrupted=false and is not treated as an error.
--- @param opts table|fun(err: table|nil, result: table|nil)|nil
--- @param callback fun(err: table|nil, result: table|nil)|nil
function Controller:interrupt(opts, callback)
  if type(opts) == "function" and callback == nil then
    callback = opts
    opts = nil
  end
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    self:_fail_interrupt(make_error("invalid_input", "interrupt options must be a table"), callback, nil)
    return
  end
  local resume = opts.resume
  if resume ~= nil and type(resume) ~= "boolean" then
    self:_fail_interrupt(make_error("invalid_input", "interrupt resume must be a boolean"), callback, resume)
    return
  end
  self:ensure(function(ensure_err)
    if ensure_err ~= nil then
      self:_fail_interrupt(ensure_err, callback, resume)
      return
    end
    self:_start_interrupt(resume, callback)
  end)
end

function Controller:_start_submission(kind, method_name, params, callback)
  if self.destroyed then
    self:_fail_submission(kind, make_error("session_destroyed", "session controller has been destroyed"), callback)
    return
  end
  if not self.session_id then
    self:_fail_submission(kind, make_error("session_not_ready", "session is not ready"), callback)
    return
  end
  local client, client_err = self:_get_client()
  if not client then
    self:_fail_submission(kind, client_err, callback)
    return
  end
  local method = client[method_name]
  if type(method) ~= "function" then
    self:_fail_submission(
      kind,
      make_error("client_method_missing", "client." .. method_name .. " is not available"),
      callback
    )
    return
  end

  local generation = self.generation
  local session_id = self.session_id
  self.submission_seq = self.submission_seq + 1
  local token = {
    id = self.submission_seq,
    kind = kind,
    generation = generation,
    session_id = session_id,
  }
  self.active_submission = token
  self.submission = {
    id = token.id,
    status = "submitting",
    kind = kind,
  }
  self.last_error = nil

  local completed = false
  local function done(err, result)
    if completed then
      return
    end
    completed = true
    if self:_stale(generation, session_id) then
      return
    end
    if err ~= nil then
      local failure = normalize_error(err, "submit_failed")
      if self.active_submission == token then
        self.submission = {
          id = token.id,
          status = "failed",
          kind = kind,
          error = copy(failure),
        }
        self.last_error = copy(failure)
      end
      call(callback, failure, nil)
      return
    end
    if self.active_submission == token then
      self.submission = {
        id = token.id,
        status = "accepted",
        kind = kind,
      }
      self.last_error = nil
    end
    call(callback, nil, {
      accepted = true,
      kind = kind,
      session_id = session_id,
      submission_id = token.id,
      response = result,
    })
  end

  local ok, cancel, start_err = pcall(method, client, session_id, copy(params), done)
  if not ok then
    if completed then
      error(cancel, 0)
    else
      done(make_error("client_error", tostring(cancel)))
    end
  elseif start_err ~= nil and not completed then
    done(start_err)
  end
end

function Controller:_prompt_options(options, callback)
  if options.text == nil then
    if options.files == nil and options.agents == nil and options.skills == nil then
      self:_fail_submission(
        "prompt",
        make_error("invalid_input", "prompt requires text or structured content"),
        callback
      )
      return
    end
  else
    local value, err = valid_text(options.text)
    if not value then
      self:_fail_submission("prompt", err, callback)
      return
    end
    options.text = value
  end
  local params = copy(options)
  self:ensure(function(ensure_err)
    if ensure_err ~= nil then
      self:_fail_submission("prompt", ensure_err, callback)
      return
    end
    self:_start_submission("prompt", "prompt", params, callback)
  end)
end

--- Send a plain prompt. A session is created/restored automatically when
--- needed. Success means the server accepted the prompt.
--- @param text string
--- @param callback fun(err: table|nil, result: table|nil)
function Controller:prompt(text, callback)
  local value, err = valid_text(text)
  if not value then
    self:_fail_submission("prompt", err, callback)
    return
  end
  self:_prompt_options({ text = value }, callback)
end

--- Execute an OpenCode command. `arguments` maps to the command text field.
--- @param name string
--- @param arguments string|nil
--- @param callback fun(err: table|nil, result: table|nil)
function Controller:_command(name, arguments, extras, callback)
  if type(name) ~= "string" or name == "" then
    self:_fail_submission("command", make_error("invalid_input", "command name must be a non-empty string"), callback)
    return
  end
  if arguments ~= nil and type(arguments) ~= "string" then
    self:_fail_submission("command", make_error("invalid_input", "command arguments must be a string"), callback)
    return
  end
  local params = {
    name = name,
    text = arguments or "",
  }
  for key, value in pairs(extras or {}) do
    if COMMAND_FIELDS[key] then
      params[key] = copy(value)
    end
  end
  self:ensure(function(ensure_err)
    if ensure_err ~= nil then
      self:_fail_submission("command", ensure_err, callback)
      return
    end
    self:_start_submission("command", "command", params, callback)
  end)
end

function Controller:command(name, arguments, callback)
  return self:_command(name, arguments, nil, callback)
end

--- Route structured input. Strings are prompts unless they use the leading
--- `/command arguments` form. Tables accept:
---   { kind = "command", name = ..., arguments = ..., files|attachments|... }
---   { kind = "prompt"|"agent"|"skill", text = ..., files|agents|skills|... }
--- Structured fields are normalized to the client prompt/command contract:
--- files (attachments alias), agents (agent alias), skills (skill alias),
--- metadata, delivery and resume.
--- @param input string|table
--- @param callback fun(err: table|nil, result: table|nil)
function Controller:submit(input, callback)
  if type(input) == "string" then
    local name, arguments = parse_command(input)
    if name then
      self:command(name, arguments, callback)
    else
      self:prompt(input, callback)
    end
    return
  end
  if type(input) ~= "table" then
    self:_fail_submission("prompt", make_error("invalid_input", "submit expects a string or table"), callback)
    return
  end

  local kind = input.kind or input.type
  if kind == "command" then
    local name = input.name or input.command
    local arguments = input.arguments
    if arguments == nil then
      arguments = input.text or input.args or ""
    end
    self:_command(name, arguments, command_options(input), callback)
    return
  end

  if kind ~= nil and kind ~= "prompt" and kind ~= "agent" and kind ~= "skill" then
    self:_fail_submission(
      tostring(kind),
      make_error("invalid_input", "unsupported submit kind: " .. tostring(kind)),
      callback
    )
    return
  end

  if kind == nil and input.name ~= nil and input.arguments ~= nil and input.text == nil then
    self:_command(input.name, input.arguments, command_options(input), callback)
    return
  end

  if kind == nil and is_plain_text_input(input) then
    local name, arguments = parse_command(input.text)
    if name then
      self:command(name, arguments, callback)
      return
    end
  end

  self:_prompt_options(prompt_options(input, kind), callback)
end

--- Drop the current session so the next ensure() restores/creates it again.
--- The project root stays pinned. In-flight results from the old generation are
--- ignored, including their caller callbacks.
function Controller:reset()
  if self.destroyed then
    return
  end
  self.generation = self.generation + 1
  self.session_id = nil
  self.session_title = nil
  self.ensure_waiters = nil
  self.active_submission = nil
  self.status = "uninitialized"
  self.submission = { status = "idle" }
  self.active_interrupt = nil
  self.interrupt_state = { status = "idle" }
  self.last_error = nil
end

--- Permanently stop this controller. In-flight results are ignored.
function Controller:destroy()
  if self.destroyed then
    return
  end
  self.destroyed = true
  self.generation = self.generation + 1
  self.session_id = nil
  self.session_title = nil
  self.ensure_waiters = nil
  self.active_submission = nil
  self.status = "destroyed"
  self.submission = { status = "idle" }
  self.active_interrupt = nil
  self.interrupt_state = { status = "idle" }
  self.last_error = nil
end

local singleton = nil

local function default_controller()
  if singleton == nil then
    singleton = M.new()
  end
  return singleton
end

--- Replace the module singleton with a configured controller.
--- @param opts table|nil
--- @return table controller
function M.setup(opts)
  if singleton ~= nil then
    singleton:destroy()
  end
  singleton = M.new(opts)
  return singleton
end

function M.ensure(callback)
  return default_controller():ensure(callback)
end

function M.get_snapshot()
  return default_controller():get_snapshot()
end

function M.prompt(text, callback)
  return default_controller():prompt(text, callback)
end

function M.command(name, arguments, callback)
  return default_controller():command(name, arguments, callback)
end

function M.submit(input, callback)
  return default_controller():submit(input, callback)
end

function M.interrupt(opts, callback)
  return default_controller():interrupt(opts, callback)
end

--- Reset the singleton session, keeping the pinned project root.
function M.reset()
  default_controller():reset()
end

--- Destroy the singleton. A later call creates a fresh controller.
function M.destroy()
  if singleton ~= nil then
    singleton:destroy()
    singleton = nil
  end
end

return M
