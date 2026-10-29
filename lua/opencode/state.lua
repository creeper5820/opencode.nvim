-- Session state facade: block tree plus connection/submission/execution state.
-- Pure data only; no SSE parsing, network calls or UI access.
local blocks = require("opencode.blocks")
local M = {}

local function copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local out = {}
  seen[value] = out
  for k, v in pairs(value) do
    out[copy(k, seen)] = copy(v, seen)
  end
  return out
end

local function first(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if value ~= nil then
      return value
    end
  end
  return nil
end

local function merge(target, source)
  target = target or {}
  for key, value in pairs(source or {}) do
    if type(value) == "table" and type(target[key]) == "table" then
      target[key] = merge(target[key], value)
    else
      target[key] = copy(value)
    end
  end
  return target
end

local function v2_payload(kind, data)
  if type(data) == "table"
    and kind ~= nil
    and data.type == kind
    and type(data.data) == "table"
  then
    return data.data
  end
  return data
end

local State = {}
State.__index = State

local function build(options)
  options = options or {}
  local self = setmetatable({}, State)
  self.model = blocks.new(options)
  self.meta = {
    session = options.session and copy(options.session) or nil,
    project = options.project and copy(options.project) or nil,
    agent = options.agent and copy(options.agent) or nil,
    model = options.model and copy(options.model) or nil,
  }
  self.location = options.location and copy(options.location) or nil
  self.subscriber_wrappers = {}
  return self
end

function M.new(options)
  return build(options)
end

function State:_merge_meta(source)
  if type(source) ~= "table" then
    return
  end
  for _, key in ipairs({ "session", "project", "agent", "model" }) do
    if source[key] ~= nil then
      self.meta[key] = merge(self.meta[key], source[key])
    end
  end
  if source.session_id ~= nil then
    self.model.session_id = source.session_id
  elseif type(source.session) == "table" and source.session.id ~= nil then
    self.model.session_id = source.session.id
  end
  if source.location ~= nil then
    self.location = copy(source.location)
    self.model.location = copy(source.location)
  end
end

function State:update(partial)
  if type(partial) ~= "table" then
    return
  end
  local source = type(partial.status) == "table" and partial.status or partial
  self:_merge_meta(source)
  if source.connection ~= nil then
    self.model.connection = source.connection
  end
  if source.submission ~= nil then
    self.model.submission = source.submission
  end
  if source.execution ~= nil then
    if self.model:_has_pending_permission() then
      self.model.execution = "waiting_permission"
    else
      self.model.execution = source.execution
    end
  end
  if source.error == false then
    self.model.last_error = nil
  elseif source.error ~= nil then
    self.model.last_error = copy(source.error)
  end
  if source.retry == false then
    self.model.retry = nil
  elseif source.retry ~= nil then
    self.model.retry = copy(source.retry)
  end
  if source.compaction ~= nil then
    self.model.compaction = source.compaction
  end
  self.model.changed = {}
  self.model.removed = {}
  self.model:_flush("status")
end

function State:apply_event(event, generation)
  local kind = type(event) == "table" and first(event.type, event.event) or nil
  local data = type(event) == "table" and first(event.data, event.properties, event.payload) or nil
  data = v2_payload(kind, data)
  local gen = generation or (type(event) == "table" and first(event.generation, event.gen, event.sync_generation)) or nil
  if gen ~= nil and gen < self.model.generation then
    return false
  end
  if type(data) == "table" then
    if kind == "session.created" or kind == "session.updated" then
      local info = first(data.info, data)
      self:_merge_meta({
        session = info,
        session_id = first(info.id, data.sessionID, data.session_id),
        location = first(data.location, info.location, self.location),
      })
    elseif kind == "session.moved" then
      self:_merge_meta({ location = first(data.location, self.location) })
    end
  end
  return self.model:apply_event(event, gen)
end

function State:apply_batch(batch)
  if type(batch) ~= "table" then
    return false
  end
  local generation = first(batch.generation, batch.snapshot and batch.snapshot.generation)
  if generation ~= nil and generation < self.model.generation then
    return false
  end
  if batch.snapshot then
    self:_merge_meta(batch.snapshot)
  end
  local result = self.model:apply_batch(batch)
  if result and batch.snapshot then
    self.location = first(batch.snapshot.location, self.location)
  end
  return result
end

function State:reset(snapshot, generation)
  generation = first(generation, type(snapshot) == "table" and snapshot.generation or nil)
  if generation ~= nil and generation < self.model.generation then
    return false
  end
  if snapshot then
    self:_merge_meta(snapshot)
  end
  return self.model:reset(snapshot, generation)
end

function State:set_connection(value)
  self.model:set_connection(value)
end

function State:set_submission(value, error_value)
  self.model:set_submission(value, error_value)
end

function State:set_execution(value)
  self.model:set_execution(value)
end

function State:subscribe(callback)
  if type(callback) ~= "function" then
    return function() end
  end
  local wrapper = function(change, model)
    local status = model:get_status()
    status.session = merge(status.session or {}, self.meta.session)
    status.project = copy(self.meta.project)
    status.agent = copy(self.meta.agent)
    status.model = copy(self.meta.model)
    status.location = copy(self.location)
    change.status = status
    callback(change, self)
  end
  self.subscriber_wrappers[wrapper] = self.model:subscribe(wrapper)
  local active = true
  return function()
    if not active then
      return
    end
    active = false
    local unsubscribe = self.subscriber_wrappers[wrapper]
    self.subscriber_wrappers[wrapper] = nil
    if unsubscribe then
      unsubscribe()
    end
  end
end

function State:get_status()
  local status = self.model:get_status()
  status.session = merge(status.session or {}, self.meta.session)
  status.project = copy(self.meta.project)
  status.agent = copy(self.meta.agent)
  status.model = copy(self.meta.model)
  status.location = copy(self.location)
  return status
end

function State:get_blocks()
  return self.model:get_blocks()
end

function State:get_all_blocks()
  return self.model:get_all_blocks()
end

function State:find(block_id)
  return self.model:find(block_id)
end

function State:get_snapshot()
  local snapshot = self.model:get_snapshot()
  snapshot.status = self:get_status()
  return snapshot
end

function State:destroy()
  self.subscriber_wrappers = {}
  self.model:destroy()
end

return M
