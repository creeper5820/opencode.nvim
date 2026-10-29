-- Pure conversation block projection for OpenCode sessions.
-- This module never performs I/O, parses SSE or touches UI state.
--
-- Input boundary (the only places raw OpenCode schemas are interpreted):
--   * 05B batch: { generation, snapshot, events }
--   * 05B event: { id, sequence, type, data }
--   * native v1 envelope: { type, properties } (properties is treated as data)
--   * native v2 session.* events: session.text.*, session.reasoning.*,
--     session.tool.* and session.compaction.*
--   * snapshot message entries: { info, parts } (info/parts may also be
--     inlined, and a map keyed by message id is accepted)
--
-- Stable IDs come from native IDs (message id, part id, permission/request id,
-- tool call id, or event id). Rows are normalized here; unknown event fields
-- are preserved under metadata.raw/metadata.data, never guessed by renderers.
-- Sorting/order uses snapshot order and native event order, not fabricated
-- cross-session sequence numbers.
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

local function shallow_copy(value)
  local out = {}
  for k, v in pairs(value or {}) do
    out[k] = v
  end
  return out
end

-- Merge adapter-provided tables without mutating either source. Values from
-- `overrides` win; nested tables are merged one level deep where possible.
local function merge_tables(base, overrides)
  local out = copy(base or {})
  for key, value in pairs(overrides or {}) do
    if type(value) == "table" and type(out[key]) == "table" then
      out[key] = merge_tables(out[key], value)
    else
      out[key] = copy(value)
    end
  end
  return out
end

local function sorted_keys(value)
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function equal(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for key, value in pairs(a) do
    if not equal(value, b[key]) then
      return false
    end
  end
  for key in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
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

local function event_data(event)
  return first(event.data, event.properties, event.payload, {})
end

local function event_id(event)
  return first(event.id, event.event_id, event.eventID)
end

local function event_type(event)
  return first(event.type, event.event, event.name)
end

local function event_generation(event)
  return first(event.generation, event.gen, event.sync_generation)
end

local function session_id_of(event, data)
  return first(event.session_id, event.sessionID, data.sessionID, data.session_id)
end

local function new_block(fields)
  local block = {
    id = fields.id,
    message_id = fields.message_id,
    parent_id = fields.parent_id,
    children = fields.children or {},
    sequence = fields.sequence, -- nil is filled by Model:_new_block
    type = fields.type or "unknown",
    status = fields.status or "completed",
    content = fields.content,
    metadata = fields.metadata or {},
    revision = fields.revision or 1,
  }
  return block
end

local function message_role(info)
  return first(info.role, info.type)
end

local function message_time(info, field)
  local time = type(info) == "table" and info.time or nil
  if type(time) ~= "table" then
    return nil
  end
  return time[field]
end

local function message_created(info)
  return first(message_time(info, "created"), info.created, info.created_at, 0)
end

local function part_type(part)
  return first(part.type, part.kind)
end

local function error_message(value)
  if type(value) == "string" then
    return value
  end
  if type(value) ~= "table" then
    return nil
  end
  local data_message = type(value.data) == "table" and value.data.message or nil
  local nested = first(value.message, value.msg, value.error, data_message, value.name)
  if type(nested) == "table" then
    return error_message(nested)
  end
  if nested ~= nil then
    return tostring(nested)
  end
  return nil
end

local Model = {}
Model.__index = Model

function M.new(options)
  options = options or {}
  local self = setmetatable({}, Model)
  self.generation = options.generation or 0
  self.revision = 0
  self.sequence = 0
  self.roots = {}
  self.blocks = {}
  self.messages = {}
  self.message_order = {}
  self.parts = {}
  self.part_order = {}
  self.tool_calls = {}
  self.permissions = {}
  self.seen_events = {}
  self.subscribers = {}
  self.session_id = options.session_id
  self.location = options.location
  self.connection = options.connection or "connected"
  self.submission = options.submission or "idle"
  self.execution = options.execution or "idle"
  self.last_error = nil
  self.retry = nil
  self.compaction = nil
  return self
end

function Model:_next_sequence()
  self.sequence = self.sequence + 1
  return self.sequence
end

function Model:_touch(block)
  block.revision = (block.revision or 0) + 1
  self.revision = self.revision + 1
end

function Model:_changed(block)
  self.changed[block.id] = block
end

function Model:_remove(block_id)
  local block = self.blocks[block_id]
  if not block then
    return
  end
  -- Descendants keep a parent_id that no longer exists otherwise. Remove them
  -- first so tool diffs/permissions do not become unreachable orphans.
  for _, child_id in ipairs(copy(block.children or {})) do
    if self.blocks[child_id] then
      self:_remove(child_id)
    end
  end
  self.removed[block_id] = true
  if block.parent_id and self.blocks[block.parent_id] then
    local parent = self.blocks[block.parent_id]
    local children = {}
    for _, child_id in ipairs(parent.children) do
      if child_id ~= block_id then
        children[#children + 1] = child_id
      end
    end
    parent.children = children
    self:_touch(parent)
    self:_changed(parent)
  else
    local roots = {}
    for _, root_id in ipairs(self.roots) do
      if root_id ~= block_id then
        roots[#roots + 1] = root_id
      end
    end
    self.roots = roots
  end
  self.blocks[block_id] = nil
  self.changed[block_id] = nil
  if block.message_id and self.messages[block.message_id] == block then
    self.messages[block.message_id] = nil
    local order = {}
    for _, id in ipairs(self.message_order) do
      if id ~= block_id then
        order[#order + 1] = id
      end
    end
    self.message_order = order
  end
  if self.parts[block_id] then
    self.parts[block_id] = nil
  end
  return block
end

function Model:_attach(block, parent_id)
  block.parent_id = parent_id
  if parent_id and self.blocks[parent_id] then
    local parent = self.blocks[parent_id]
    parent.children = parent.children or {}
    parent.children[#parent.children + 1] = block.id
    self:_touch(parent)
    self:_changed(parent)
  else
    block.parent_id = nil
    self.roots[#self.roots + 1] = block.id
  end
  self.blocks[block.id] = block
  self:_changed(block)
end

function Model:_new_block(fields)
  if fields.id == nil then
    return nil
  end
  local block = new_block(fields)
  if block.sequence == nil then
    block.sequence = self:_next_sequence()
  end
  self:_attach(block, fields.parent_id)
  return block
end

function Model:_replace(block, fields, parent_id)
  local before = shallow_copy(block)
  local changed = false
  for _, key in ipairs({ "message_id", "type", "status", "content", "metadata" }) do
    local value = fields[key]
    if value ~= nil and not equal(block[key], value) then
      block[key] = value
      changed = true
    end
  end
  if parent_id ~= nil and parent_id ~= block.parent_id then
    if block.parent_id and self.blocks[block.parent_id] then
      local parent = self.blocks[block.parent_id]
      local children = {}
      for _, id in ipairs(parent.children) do
        if id ~= block.id then
          children[#children + 1] = id
        end
      end
      parent.children = children
      self:_touch(parent)
      self:_changed(parent)
    else
      -- A part can be materialized before its message exists. Remove it from
      -- the root list when it is attached to the message afterwards.
      local roots = {}
      for _, root_id in ipairs(self.roots) do
        if root_id ~= block.id then
          roots[#roots + 1] = root_id
        end
      end
      self.roots = roots
    end
    self:_attach(block, parent_id)
    changed = true
  end
  if changed and not equal(block, before) then
    self:_touch(block)
    self:_changed(block)
    return true
  end
  return false
end

function Model:_ensure_message(info)
  if not info or not info.id then
    return nil
  end
  local id = info.id
  local existing = self.messages[id]
  local role = message_role(info) or "assistant"
  if existing then
    local fields = {
      type = role == "user" and "user" or "assistant",
      status = message_time(info, "completed") and "completed" or (existing.status or "streaming"),
      metadata = shallow_copy(existing.metadata),
    }
    fields.metadata.info = copy(info)
    if info.error then
      fields.status = "failed"
      fields.metadata.error = copy(info.error)
    end
    self:_replace(existing, fields)
    return existing
  end
  local status = "streaming"
  if info.error then
    status = "failed"
  elseif message_time(info, "completed") then
    status = "completed"
  elseif role == "user" then
    status = "completed"
  end
  local block = self:_new_block({
    id = id,
    message_id = id,
    type = role == "user" and "user" or "assistant",
    status = status,
    content = "",
    metadata = { info = copy(info) },
    sequence = self:_next_sequence(),
  })
  self.messages[id] = block
  self.message_order[#self.message_order + 1] = id
  -- A part may arrive before its message. Re-materialize any parts that were
  -- recorded while the message had no block so they are not orphaned.
  for _, part_id in ipairs(copy(self.part_order[id] or {})) do
    local record = self.parts[part_id]
    if record then
      self:_upsert_part(record.data)
    end
  end
  return block
end

function Model:_set_message_status(block, status, error_value)
  if not block then
    return
  end
  local metadata = shallow_copy(block.metadata)
  if error_value then
    metadata.error = copy(error_value)
  end
  self:_replace(block, { status = status, metadata = metadata })
end

function Model:_text_content(message_block)
  local ids = self.part_order[message_block.message_id] or {}
  local chunks = {}
  for _, part_id in ipairs(ids) do
    local part = self.parts[part_id]
    if part and part.type == "text" then
      local text = first(part.data.text, part.data.content)
      if type(text) == "string" and text ~= "" then
        chunks[#chunks + 1] = text
      end
    end
  end
  return table.concat(chunks, "\n")
end

function Model:_recompute_assistant(message_block)
  if not message_block then
    return
  end
  local content = self:_text_content(message_block)
  if content ~= message_block.content then
    self:_replace(message_block, { content = content })
  end
end

function Model:_tool_block_for(call_id)
  if call_id == nil then
    return nil
  end
  local part_id = self.tool_calls[call_id]
  local block = part_id and self.blocks[part_id] or nil
  if not block then
    block = self.blocks[call_id]
  end
  if block and block.type == "tool" then
    return block
  end
  return nil
end

-- When a tool block appears after a permission/diff child, attach the waiting
-- child to the tool instead of leaving it at the message/root level.
function Model:_rebind_call_children(call_id, tool_block)
  if call_id == nil or not tool_block then
    return
  end
  for _, id in ipairs(sorted_keys(self.blocks)) do
    local block = self.blocks[id]
    if block and block.id ~= tool_block.id and block.parent_id ~= tool_block.id then
      local metadata = block.metadata or {}
      local part = type(metadata.part) == "table" and metadata.part or {}
      local block_call = first(metadata.call_id, part.callID, part.call_id)
      if block_call == call_id then
        self:_replace(block, {}, tool_block.id)
      end
    end
  end
end

function Model:_has_running_tool()
  for _, message_id in ipairs(self.message_order) do
    local message = self.messages[message_id]
    for _, child_id in ipairs(message and message.children or {}) do
      local child = self.blocks[child_id]
      if child and child.type == "tool" and (child.status == "running" or child.status == "pending") then
        return true
      end
    end
  end
  return false
end

function Model:_upsert_part(part)
  if not part or not part.id then
    return
  end
  local record = self.parts[part.id]
  local message_id = first(part.messageID, part.message_id, record and record.message_id)
  local message_block = message_id and self.messages[message_id] or nil
  if not message_block and part.sessionID then
    -- Legacy synthetic input may use the session id where a message id is
    -- expected. Do not apply this fallback when a real message id was given.
    message_block = self.messages[part.sessionID]
  end
  local kind = part_type(part) or (record and record.type) or "unknown"
  local previous_message_id = record and record.message_id or nil
  if not record then
    record = { id = part.id, message_id = message_id, type = kind, data = {} }
    self.parts[part.id] = record
  end
  if previous_message_id ~= message_id and previous_message_id ~= nil then
    local previous = self.part_order[previous_message_id] or {}
    local next_order = {}
    for _, id in ipairs(previous) do
      if id ~= part.id then
        next_order[#next_order + 1] = id
      end
    end
    self.part_order[previous_message_id] = #next_order > 0 and next_order or nil
  end
  if message_id ~= nil then
    local order = self.part_order[message_id] or {}
    local present = false
    for _, id in ipairs(order) do
      if id == part.id then
        present = true
        break
      end
    end
    if not present then
      order[#order + 1] = part.id
    end
    self.part_order[message_id] = order
  end
  local data = copy(part)
  data.type = kind
  record.data = data
  record.type = kind
  record.message_id = message_id

  local block = self.blocks[part.id]
  local state = type(part.state) == "table" and part.state or {}
  if kind == "text" then
    if message_block then
      self:_recompute_assistant(message_block)
    end
    return nil
  elseif kind == "reasoning" then
    local text = first(part.text, part.content, state.text, state.content)
    if text == nil and block then
      text = block.content
    end
    local status = first(part.status, state.status, block and block.status)
    if not status then
      local time = (type(part.time) == "table" and part.time) or state.time or {}
      status = time["end"] and "completed" or (time.start and "streaming" or "completed")
    end
    local metadata = merge_tables(part.metadata, state.metadata)
    metadata.part = data
    if not block then
      block = self:_new_block({
        id = part.id,
        message_id = message_id,
        parent_id = message_block and message_block.id or nil,
        type = "reasoning",
        status = status,
        content = text or "",
        metadata = metadata,
      })
    else
      self:_replace(block, {
        status = status,
        content = text or "",
        metadata = metadata,
      }, message_block and message_block.id or nil)
    end
    return block
  elseif kind == "tool" then
    local call_id = first(part.callID, part.call_id, part.id)
    if call_id then
      self.tool_calls[call_id] = part.id
    end
    local input = first(part.input, state.input)
    local output = first(part.output, state.output)
    local metadata = merge_tables(state.metadata, part.metadata)
    metadata.part = data
    metadata.kind = metadata.kind or "tool"
    metadata.tool = first(metadata.tool, part.tool, part.name, state.tool)
    metadata.title = first(metadata.title, part.title, state.title)
    if input ~= nil then
      metadata.input = copy(input)
    end
    if output ~= nil then
      metadata.output = copy(output)
    end
    local diff = first(
      part.diff,
      state.diff,
      state.metadata and state.metadata.diff,
      part.metadata and part.metadata.diff,
      metadata.diff
    )
    if diff ~= nil then
      metadata.diff = copy(diff)
    end
    local error_value = first(part.error, state.error, metadata.error)
    if error_value ~= nil then
      metadata.error = copy(error_value)
    end
    local status = first(part.status, state.status, metadata.status)
    if not status then
      if error_value ~= nil then
        status = "failed"
      elseif output ~= nil or (state.time and state.time["end"]) then
        status = "completed"
      else
        status = "running"
      end
    elseif error_value ~= nil and (status == "running" or status == "pending" or status == "streaming") then
      status = "failed"
    end
    local title = first(part.title, part.name, part.tool, state.title, block and block.content, "")
    if not block then
      block = self:_new_block({
        id = part.id,
        message_id = message_id,
        parent_id = message_block and message_block.id or nil,
        type = "tool",
        status = status,
        content = title,
        metadata = metadata,
      })
    else
      self:_replace(block, {
        status = status,
        content = title,
        metadata = metadata,
      }, message_block and message_block.id or nil)
    end
    self:_rebind_call_children(call_id, block)
    if error_value ~= nil then
      self:_set_message_status(message_block, "failed", error_value)
    end
    if status == "running" or status == "pending" then
      self.execution = "tool_running"
    elseif self.execution == "tool_running" and not self:_has_running_tool() then
      self.execution = "streaming"
    end
    return block
  elseif kind == "file" or kind == "patch" or kind == "diff" or kind == "snapshot" then
    local diff = first(part.diff, part.patch, state.diff, state.patch, part.text, part.content)
    local call_id = first(part.callID, part.call_id, state.callID, state.call_id)
    local parent = self:_tool_block_for(call_id) or message_block
    local metadata = merge_tables(state.metadata, part.metadata)
    metadata.part = data
    metadata.kind = metadata.kind or "diff"
    metadata.diff = copy(diff)
    local status = first(part.status, state.status) or "completed"
    if not block then
      block = self:_new_block({
        id = part.id,
        message_id = message_id,
        parent_id = parent and parent.id or nil,
        type = "diff",
        status = status,
        content = diff or "",
        metadata = metadata,
      })
    else
      local previous_parent = block.parent_id
      self:_replace(block, { status = status, content = diff or "", metadata = metadata }, parent and parent.id or previous_parent)
    end
    return block
  end

  local metadata = merge_tables({ part = data, raw = copy(part) }, part.metadata)
  if not block then
    block = self:_new_block({
      id = part.id,
      message_id = message_id,
      parent_id = message_block and message_block.id or nil,
      type = "unknown",
      status = first(part.status, "unknown"),
      content = "",
      metadata = metadata,
    })
  else
    self:_replace(block, { metadata = metadata }, message_block and message_block.id or nil)
  end
  return block
end

function Model:_append_delta(data)
  local part_id = first(data.partID, data.part_id, data.id)
  local field = first(data.field, "text")
  local delta = first(data.delta, data.text, "")
  if not part_id or type(delta) ~= "string" then
    return
  end
  local record = self.parts[part_id]
  if not record then
    -- Some producers omit the part.updated event before deltas.
    local message_id = first(data.messageID, data.message_id)
    local block = self.messages[message_id]
    if block and block.type == "assistant" then
      if field == "text" then
        self:_replace(block, { content = (block.content or "") .. delta })
        return block
      end
    end
    return
  end
  local current = record.data[field]
  if type(current) ~= "string" then
    current = record.data.text or record.data.content or ""
  end
  record.data[field] = current .. delta
  if record.type == "reasoning" then
    local block = self.blocks[part_id]
    if block then
      self:_replace(block, {
        content = first(record.data.text, record.data.content, block.content) or "",
        metadata = { part = copy(record.data) },
      })
      return block
    end
  elseif record.type == "text" then
    local block = self.messages[record.message_id]
    self:_recompute_assistant(block)
    return block
  elseif record.type == "tool" then
    local block = self.blocks[part_id]
    if block then
      local metadata = copy(block.metadata)
      metadata.input = first(record.data.input, metadata.input)
      metadata.output = first(record.data.output, metadata.output)
      metadata.part = copy(record.data)
      self:_replace(block, { metadata = metadata })
      return block
    end
  end
end

function Model:_remove_part(data)
  local part_id = first(data.partID, data.part_id, data.id)
  if not part_id then
    return
  end
  local record = self.parts[part_id]
  local message_id = record and record.message_id or first(data.messageID, data.message_id)
  if record then
    self.parts[part_id] = nil
    if message_id ~= nil then
      local order = self.part_order[message_id] or {}
      local next_order = {}
      for _, id in ipairs(order) do
        if id ~= part_id then
          next_order[#next_order + 1] = id
        end
      end
      self.part_order[message_id] = #next_order > 0 and next_order or nil
    end
  end
  self:_remove(part_id)
  local message = self.messages[message_id]
  if record and record.type == "text" then
    self:_recompute_assistant(message)
  end
end

function Model:_remove_message(data)
  local message_id = first(data.messageID, data.message_id, data.id)
  local block = self.messages[message_id]
  if not block then
    return
  end
  local children = copy(block.children or {})
  for _, child_id in ipairs(children) do
    self:_remove(child_id)
  end
  self:_remove(message_id)
  self.parts = self.parts or {}
  local order = self.part_order[message_id] or {}
  for _, id in ipairs(order) do
    self.parts[id] = nil
  end
  self.part_order[message_id] = nil
end

function Model:_permission_block(permission)
  local id = first(permission.id, permission.requestID, permission.request_id)
  if not id then
    return nil
  end
  local tool = type(permission.tool) == "table" and permission.tool or {}
  local call_id = first(tool.callID, tool.call_id, permission.callID, permission.call_id)
  local tool_block = self:_tool_block_for(call_id)
  local message_id = first(
    tool.messageID,
    tool.message_id,
    permission.messageID,
    permission.message_id,
    tool_block and tool_block.message_id
  )
  local block = self.blocks[id]
  local metadata = {
    kind = "permission",
    permission = copy(permission),
    request_id = id,
    call_id = call_id,
  }
  local status = first(permission.status, "waiting")
  if status == "asked" or status == "pending" then
    status = "waiting"
  elseif status == "replied" or status == "approved" then
    status = "completed"
  end
  local content = first(permission.permission, permission.title, permission.type, "permission requested")
  local parent_id = tool_block and tool_block.id or nil
  if not block then
    block = self:_new_block({
      id = id,
      message_id = message_id,
      parent_id = parent_id,
      type = "status",
      status = status,
      content = content,
      metadata = metadata,
    })
  else
    self:_replace(block, {
      message_id = message_id,
      status = status,
      content = content,
      metadata = metadata,
    }, parent_id)
  end
  return block
end

function Model:_pending_permissions()
  local pending = {}
  for _, id in ipairs(sorted_keys(self.permissions)) do
    local permission = self.permissions[id]
    if permission.pending then
      pending[id] = copy(permission)
    end
  end
  return pending
end

function Model:_has_pending_permission()
  for _, permission in pairs(self.permissions) do
    if permission.pending then
      return true
    end
  end
  return false
end

function Model:_refresh_execution()
  if self:_has_pending_permission() then
    self.execution = "waiting_permission"
    return
  end
  if self.last_error then
    self.execution = "failed"
  elseif self.compaction == "running" then
    self.execution = "compacting"
  elseif self.retry then
    self.execution = "retrying"
  elseif self.execution == "waiting_permission" then
    self.execution = "streaming"
  end
end

function Model:_ask_permission(data)
  local permission = copy(data)
  local id = first(permission.id, permission.requestID, permission.request_id)
  if not id then
    return nil
  end
  local status = first(permission.status)
  if status == "replied" or status == "approved" or status == "completed" then
    return self:_reply_permission(permission)
  end
  if self.permissions[id] and self.permissions[id].pending == false then
    return self.blocks[id]
  end
  self.permissions[id] = { pending = true, data = permission }
  local block = self:_permission_block(permission)
  self.execution = "waiting_permission"
  return block
end

function Model:_reply_permission(data)
  local id = first(data.requestID, data.request_id, data.id, data.permissionID)
  if not id then
    return nil
  end
  local current = self.permissions[id]
  if not current then
    current = { data = copy(data) }
    self.permissions[id] = current
  end
  current.pending = false
  current.reply = copy(data)
  local block = self.blocks[id]
  if block then
    local metadata = copy(block.metadata)
    metadata.reply = copy(data)
    self:_replace(block, { status = "completed", metadata = metadata })
  end
  self:_refresh_execution()
  return block
end

function Model:_status_block(id, kind, content, status, metadata)
  local block = self.blocks[id]
  metadata = metadata or {}
  if metadata.kind == nil then
    metadata.kind = kind
  end
  local fields = {
    type = "status",
    status = status or "completed",
    content = content or "",
    metadata = metadata,
  }
  if not block then
    return self:_new_block({
      id = id,
      type = fields.type,
      status = fields.status,
      content = fields.content,
      metadata = fields.metadata,
    })
  end
  self:_replace(block, fields)
  return block
end

function Model:_session_error(data)
  local error_value = first(data.error, data)
  local message = error_message(error_value) or "session error"
  local message_id = first(data.assistantMessageID, data.messageID, data.message_id)
  self.last_error = copy(error_value)
  self.execution = "failed"
  if message_id and self.messages[message_id] then
    self:_set_message_status(self.messages[message_id], "failed", error_value)
  end
  local seed = tostring(first(data.messageID, data.message_id, message_id, event_id(data), message) or "session")
  local id = "error:" .. seed:gsub("%s+", " "):sub(1, 80)
  return self:_status_block(id, "error", message, "failed", {
    kind = "error",
    error = copy(error_value),
    raw = copy(data),
  })
end

function Model:_retry(data)
  local message_id = first(data.assistantMessageID, data.messageID, data.message_id)
  local error_value = first(data.error, data.reason, data.message)
  self.retry = {
    attempt = first(data.attempt, 1),
    at = first(data.at, data.time),
    error = copy(error_value),
    message_id = message_id,
  }
  self.execution = "retrying"
  local id = "retry:" .. tostring(message_id or first(data.id, "session"))
  local content = "retrying"
  if self.retry.attempt then
    content = "retrying (attempt " .. tostring(self.retry.attempt) .. ")"
  end
  local message = error_message(error_value)
  if message then
    content = content .. ": " .. message
  end
  return self:_status_block(id, "retry", content, "retrying", {
    kind = "retry",
    retry = copy(self.retry),
    raw = copy(data),
  })
end

function Model:_compaction(data, phase)
  self.compaction = phase
  self.execution = phase == "running" and "compacting" or self.execution
  local id = "compaction"
  if phase == "running" then
    self.execution = "compacting"
  elseif phase == "failed" then
    self.last_error = copy(first(data.error, data))
    self.execution = "failed"
  elseif self.execution == "compacting" then
    self.execution = "streaming"
  end
  local content = phase == "running" and "compacting"
    or phase == "failed" and ("compaction failed: " .. tostring(error_message(data.error) or "error"))
    or "compacted"
  return self:_status_block(id, "compaction", content, phase, {
    kind = "compaction",
    phase = phase,
    raw = copy(data),
  })
end

function Model:_unknown(event, data)
  local id = event_id(event) or ("unknown:" .. tostring(self:_next_sequence()))
  local block = self.blocks[id]
  if block then
    self:_replace(block, {
      status = "unknown",
      content = tostring(event_type(event) or "unknown event"),
      metadata = { raw = copy(event), data = copy(data) },
    })
    return block
  end
  return self:_new_block({
    id = id,
    type = "unknown",
    status = "unknown",
    content = tostring(event_type(event) or "unknown event"),
    metadata = { raw = copy(event), data = copy(data) },
  })
end

-- Event adapter map (native v1/v2 -> model):
--   message.updated            -> user/assistant block
--   message.part.updated       -> text content, reasoning/tool/diff/unknown child
--   message.part.delta         -> same part block / assistant content
--   message.removed|part.removed
--   permission.asked|updated   -> status block + waiting_permission
--   permission.replied         -> resolve status block
--   session.error              -> error status block + failed assistant
--   session.retry*             -> retry status block
--   session.compaction.*       -> compaction status block
--   session.execution.*|status|idle -> execution dimension
--   session.text.*             -> assistant content
--   session.reasoning.*        -> reasoning child
--   session.tool.*             -> tool child (input/output/diff)
--   anything else              -> unknown block preserving raw event/data
-- Fields that are not confirmed by a live capture stay in metadata.raw or
-- metadata.part; renderers do not infer them from raw SSE.
function Model:_apply_one(event)
  local kind = event_type(event)
  local data = event_data(event)
  if type(data) ~= "table" then
    data = { value = data }
  end
  self.session_id = first(self.session_id, session_id_of(event, data))
  if kind == "message.updated" then
    self:_ensure_message(first(data.info, data.message, data))
  elseif kind == "message.removed" then
    self:_remove_message(data)
  elseif kind == "message.part.updated" then
    local part = first(data.part, data)
    local message_info = first(data.info, data.message)
    if message_info then
      self:_ensure_message(message_info)
    end
    self:_upsert_part(part)
  elseif kind == "message.part.delta" then
    self:_append_delta(data)
  elseif kind == "message.part.removed" then
    self:_remove_part(data)
  elseif kind == "permission.asked" or kind == "permission.updated" then
    self:_ask_permission(data)
  elseif kind == "permission.replied" then
    self:_reply_permission(data)
  elseif kind == "session.error" then
    self:_session_error(data)
  elseif kind == "session.retry" or kind == "session.retry.scheduled" then
    self:_retry(data)
  elseif kind == "session.compacted" or kind == "session.compaction.ended" then
    self:_compaction(data, "completed")
  elseif kind == "session.compaction.started" then
    self:_compaction(data, "running")
  elseif kind == "session.compaction.failed" then
    self:_compaction(data, "failed")
  elseif kind == "session.execution.failed" or kind == "session.step.failed" then
    local message_id = first(data.assistantMessageID, data.messageID, data.message_id)
    if message_id and self.messages[message_id] then
      self:_set_message_status(self.messages[message_id], "failed", data.error)
    end
    self:_session_error(data)
  elseif kind == "session.execution.interrupted" then
    self.execution = "interrupted"
  elseif kind == "session.execution.started" then
    self.execution = "streaming"
    self.last_error = nil
  elseif kind == "session.execution.succeeded" then
    self.execution = self:_has_pending_permission() and "waiting_permission" or "idle"
    self.last_error = nil
    self.retry = nil
    self.compaction = nil
  elseif kind == "session.idle" then
    self.execution = self:_has_pending_permission() and "waiting_permission" or "idle"
    self.retry = nil
    self.compaction = nil
  elseif kind == "session.status" then
    local status = first(data.status, data)
    local status_type = type(status) == "table" and first(status.type, status.status) or status
    if status_type == "retry" then
      self:_retry(status)
    elseif status_type == "idle" then
      self.execution = self:_has_pending_permission() and "waiting_permission" or "idle"
      self.retry = nil
      self.compaction = nil
    elseif status_type == "busy" then
      self.execution = "streaming"
    end
  elseif kind == "server.connected" then
    self.connection = "connected"
  elseif kind == "session.moved" then
    self.location = first(data.location, self.location)
  elseif kind == "session.created" or kind == "session.updated" then
    local info = first(data.info, data)
    self.session_id = first(info.id, data.sessionID, data.session_id, self.session_id)
    self.location = first(data.location, info.location, self.location)
  elseif kind == "session.text.started" or kind == "session.text.ended" then
    local message_id = first(data.assistantMessageID, data.messageID, data.message_id)
    local block = self.messages[message_id]
    if block then
      if kind == "session.text.ended" then
        self:_replace(block, { content = first(data.text, block.content), status = "completed" })
      else
        self:_set_message_status(block, "streaming")
      end
    end
  elseif kind == "session.text.delta" then
    local message_id = first(data.assistantMessageID, data.messageID, data.message_id)
    local block = self.messages[message_id]
    if block then
      self:_replace(block, { content = (block.content or "") .. tostring(first(data.delta, data.text, "")) })
    end
  elseif kind == "session.reasoning.started" or kind == "session.reasoning.ended" then
    local message_id = first(data.assistantMessageID, data.messageID, data.message_id)
    local id = "reasoning:" .. tostring(message_id) .. ":" .. tostring(first(data.ordinal, 0))
    local content = first(data.text, "")
    local block = self.blocks[id]
    local message_block = self.messages[message_id]
    if not block then
      block = self:_new_block({
        id = id,
        message_id = message_id,
        parent_id = message_block and message_block.id or nil,
        type = "reasoning",
        status = kind == "session.reasoning.ended" and "completed" or "streaming",
        content = content,
        metadata = { event = copy(data) },
      })
    else
      self:_replace(block, {
        status = kind == "session.reasoning.ended" and "completed" or block.status,
        content = kind == "session.reasoning.ended" and content or block.content,
      })
    end
  elseif kind == "session.reasoning.delta" then
    local message_id = first(data.assistantMessageID, data.messageID, data.message_id)
    local id = "reasoning:" .. tostring(message_id) .. ":" .. tostring(first(data.ordinal, 0))
    local block = self.blocks[id]
    if block then
      self:_replace(block, { content = (block.content or "") .. tostring(first(data.delta, "")) })
    else
      local message_block = self.messages[message_id]
      self:_new_block({
        id = id,
        message_id = message_id,
        parent_id = message_block and message_block.id or nil,
        type = "reasoning",
        status = "streaming",
        content = tostring(first(data.delta, "")),
      })
    end
  elseif kind == "session.tool.input.started" or kind == "session.tool.input.ended" then
    local message_id = first(data.assistantMessageID, data.messageID, data.message_id)
    local id = first(data.id, data.callID)
    if not id then
      return self:_unknown(event, data)
    end
    local block = id and self.blocks[id]
    local message_block = self.messages[message_id]
    local metadata = block and copy(block.metadata) or { kind = "tool", input = "" }
    metadata.kind = metadata.kind or "tool"
    metadata.tool = first(metadata.tool, data.name, data.tool, block and block.content)
    metadata.input = kind == "session.tool.input.ended" and first(data.text, "") or metadata.input
    if not block then
      block = self:_new_block({
        id = id,
        message_id = message_id,
        parent_id = message_block and message_block.id or nil,
        type = "tool",
        status = "running",
        content = tostring(first(data.name, data.tool, id, "tool")),
        metadata = metadata,
      })
    else
      self:_replace(block, { metadata = metadata })
    end
    self.execution = "tool_running"
  elseif kind == "session.tool.input.delta" then
    local id = first(data.id, data.callID)
    local block = id and self.blocks[id]
    if block then
      local metadata = copy(block.metadata)
      metadata.input = tostring(metadata.input or "") .. tostring(first(data.delta, ""))
      self:_replace(block, { metadata = metadata })
      self.execution = "tool_running"
    end
  elseif kind == "session.tool.called" or kind == "session.tool.success" or kind == "session.tool.failed" then
    local message_id = first(data.assistantMessageID, data.messageID, data.message_id)
    local id = first(data.id, data.callID)
    if not id then
      return self:_unknown(event, data)
    end
    local message_block = self.messages[message_id]
    local block = self.blocks[id]
    local metadata = block and copy(block.metadata) or {}
    metadata.kind = "tool"
    metadata.input = copy(first(data.input, metadata.input))
    metadata.output = copy(first(data.content, data.output, metadata.output))
    metadata.metadata = copy(first(data.metadata, metadata.metadata))
    metadata.diff = copy(first(data.diff, data.metadata and data.metadata.diff, metadata.diff))
    metadata.event = copy(data)
    local status = kind == "session.tool.success" and "completed"
      or kind == "session.tool.failed" and "failed"
      or "running"
    if not block then
      block = self:_new_block({
        id = id,
        message_id = message_id,
        parent_id = message_block and message_block.id or nil,
        type = "tool",
        status = status,
        content = tostring(first(data.name, data.tool, id, "tool")),
        metadata = metadata,
      })
    else
      self:_replace(block, { status = status, metadata = metadata })
    end
    self:_rebind_call_children(first(data.callID, data.call_id, id), block)
    if kind == "session.tool.failed" then
      self:_set_message_status(message_block, "failed", data.error)
      self.last_error = copy(data.error)
    elseif kind == "session.tool.called" then
      self.execution = "tool_running"
    elseif kind == "session.tool.success"
      and self.execution == "tool_running"
      and not self:_has_running_tool() then
      self.execution = "streaming"
    end
  elseif kind == "session.tool.progress" then
    local id = first(data.id, data.callID)
    local block = id and self.blocks[id]
    if block then
      local metadata = copy(block.metadata)
      metadata.progress = copy(data.metadata)
      self:_replace(block, { metadata = metadata })
    end
  else
    self:_unknown(event, data)
  end
end

function Model:reset(snapshot, generation)
  snapshot = snapshot or {}
  generation = first(generation, snapshot.generation)
  if generation ~= nil and generation < self.generation then
    return false
  end
  if generation ~= nil then
    self.generation = generation
  end
  self.roots = {}
  self.blocks = {}
  self.messages = {}
  self.message_order = {}
  self.parts = {}
  self.part_order = {}
  self.tool_calls = {}
  self.permissions = {}
  self.seen_events = {}
  self.sequence = 0
  self.last_error = nil
  self.retry = nil
  self.compaction = nil
  self.session_id = first(snapshot.session_id, snapshot.sessionID, snapshot.session and snapshot.session.id, self.session_id)
  self.location = first(snapshot.location, self.location)
  local messages = first(snapshot.messages, snapshot.message, {})
  if type(messages) ~= "table" then
    messages = {}
  end
  local entries = {}
  if messages[1] ~= nil or next(messages) == nil then
    entries = messages
  else
    -- A map keyed by message id is an accepted adapter input. Sort by creation
    -- time, then stable id, so replay remains deterministic.
    local keys = sorted_keys(messages)
    table.sort(keys, function(a, b)
      local entry_a, entry_b = messages[a], messages[b]
      local info_a = type(entry_a) == "table" and first(entry_a.info, entry_a.message, entry_a) or {}
      local info_b = type(entry_b) == "table" and first(entry_b.info, entry_b.message, entry_b) or {}
      local created_a = message_created(type(info_a) == "table" and info_a or {})
      local created_b = message_created(type(info_b) == "table" and info_b or {})
      if created_a ~= created_b then
        return created_a < created_b
      end
      return tostring(a) < tostring(b)
    end)
    for _, key in ipairs(keys) do
      entries[#entries + 1] = messages[key]
    end
  end
  for _, entry in ipairs(entries) do
    if type(entry) == "table" then
      local info = first(entry.info, entry.message, entry)
      if type(info) ~= "table" then
        info = {}
      end
      local message = self:_ensure_message(info)
      local parts = first(entry.parts, entry.part, info.parts, {})
      if type(parts) == "table" then
        for _, part in ipairs(parts) do
          self:_upsert_part(part)
        end
      end
      if message and message.status ~= "failed" then
        if message_time(info, "completed") then
          self:_set_message_status(message, "completed")
        elseif message.type == "assistant" and #(self.part_order[message.id] or {}) > 0 then
          self:_set_message_status(message, "streaming")
        end
      end
    end
  end
  local snapshot_status = type(snapshot.status) == "table" and snapshot.status or {}
  if snapshot_status.connection ~= nil then
    self.connection = snapshot_status.connection
  end
  if snapshot_status.submission ~= nil then
    self.submission = snapshot_status.submission
  end
  if snapshot_status.execution ~= nil then
    self.execution = snapshot_status.execution
  else
    self.execution = "idle"
    for _, message_id in ipairs(self.message_order) do
      local message = self.messages[message_id]
      if message and message.type == "assistant" and message.status == "streaming" then
        self.execution = "streaming"
      end
      for _, child_id in ipairs(message and message.children or {}) do
        local child = self.blocks[child_id]
        if child and child.type == "tool" and (child.status == "running" or child.status == "pending") then
          self.execution = "tool_running"
        end
      end
    end
  end
  if snapshot_status.error ~= nil then
    self.last_error = copy(snapshot_status.error)
  end
  self.changed = {}
  self.removed = {}
  for id, block in pairs(self.blocks) do
    self.changed[id] = block
  end
  self.revision = self.revision + 1
  return true
end

function Model:_flush(kind)
  -- A pending permission is the strongest visible execution state: ordinary
  -- idle/tool updates must not silently make it look like the session stalled
  -- or continued without an answer.
  if self:_has_pending_permission() then
    self.execution = "waiting_permission"
  end
  local changed = {}
  for _, id in ipairs(sorted_keys(self.changed)) do
    changed[#changed + 1] = copy(self.changed[id])
  end
  local removed = sorted_keys(self.removed)
  local change = {
    kind = kind,
    generation = self.generation,
    revision = self.revision,
    changed = changed,
    removed = removed,
    roots = copy(self.roots),
    blocks = kind == "reset" and self:get_blocks() or nil,
    status = self:get_status(),
  }
  self.changed = {}
  self.removed = {}
  for _, callback in ipairs(copy(self.subscribers)) do
    callback(change, self)
  end
  return change
end

function Model:apply_event(event, generation)
  if type(event) ~= "table" then
    return false
  end
  local gen = first(generation, event_generation(event))
  if gen ~= nil then
    if gen < self.generation then
      return false
    end
    if gen > self.generation then
      self.generation = gen
    end
  end
  local id = event_id(event)
  if id and self.seen_events[id] then
    return false
  end
  self.changed = self.changed or {}
  self.removed = self.removed or {}
  self:_apply_one(event)
  if id then
    self.seen_events[id] = true
  end
  self:_flush("update")
  return true
end

function Model:apply_batch(batch)
  if type(batch) ~= "table" then
    return false
  end
  local generation = first(batch.generation, batch.snapshot and batch.snapshot.generation, self.generation)
  if generation ~= nil and generation < self.generation then
    return false
  end
  self.changed = {}
  self.removed = {}
  if batch.snapshot then
    self:reset(batch.snapshot, generation)
  elseif generation then
    self.generation = generation
  end
  for _, event in ipairs(batch.events or {}) do
    local gen = first(event_generation(event), generation)
    if gen == nil or gen >= self.generation then
      if gen ~= nil and gen > self.generation then
        self.generation = gen
      end
      local id = event_id(event)
      if not id or not self.seen_events[id] then
        self:_apply_one(event)
        if id then
          self.seen_events[id] = true
        end
      end
    end
  end
  self:_flush(batch.snapshot and "reset" or "update")
  return true
end

function Model:set_connection(value)
  if self.connection ~= value then
    self.connection = value
    self:_flush("status")
  end
end

function Model:set_submission(value, error_value)
  self.submission = value
  if error_value ~= nil then
    self.last_error = copy(error_value)
  end
  self:_flush("status")
end

function Model:set_execution(value)
  if self:_has_pending_permission() then
    value = "waiting_permission"
  end
  self.execution = value
  self:_flush("status")
end

function Model:subscribe(callback)
  if type(callback) ~= "function" then
    return function() end
  end
  self.subscribers[#self.subscribers + 1] = callback
  local subscribed = true
  return function()
    if not subscribed then
      return
    end
    subscribed = false
    for index, value in ipairs(self.subscribers) do
      if value == callback then
        table.remove(self.subscribers, index)
        break
      end
    end
  end
end

function Model:get_blocks()
  local result = {}
  for _, id in ipairs(self.roots) do
    if self.blocks[id] then
      result[#result + 1] = copy(self.blocks[id])
    end
  end
  return result
end

--- Flat list in tree order, useful for renderers that consume a block array
--- plus a lookup. Orphaned blocks are appended by sequence/id for recovery.
function Model:get_all_blocks()
  local result = {}
  local seen = {}
  local function walk(id)
    local block = self.blocks[id]
    if not block or seen[id] then
      return
    end
    seen[id] = true
    result[#result + 1] = copy(block)
    for _, child_id in ipairs(block.children or {}) do
      walk(child_id)
    end
  end
  for _, id in ipairs(self.roots) do
    walk(id)
  end
  local orphans = {}
  for id in pairs(self.blocks) do
    if not seen[id] then
      orphans[#orphans + 1] = id
    end
  end
  table.sort(orphans, function(a, b)
    local block_a, block_b = self.blocks[a], self.blocks[b]
    if block_a.sequence ~= block_b.sequence then
      return block_a.sequence < block_b.sequence
    end
    return tostring(a) < tostring(b)
  end)
  for _, id in ipairs(orphans) do
    walk(id)
  end
  return result
end

function Model:get_status()
  return {
    session = self.session_id and { id = self.session_id },
    connection = self.connection,
    submission = self.submission,
    execution = self.execution,
    waiting_permission = self:_pending_permissions(),
    error = copy(self.last_error),
    retry = copy(self.retry),
    compaction = self.compaction,
  }
end

function Model:get_snapshot()
  return {
    generation = self.generation,
    revision = self.revision,
    session_id = self.session_id,
    location = copy(self.location),
    blocks = self:get_blocks(),
    roots = copy(self.roots),
    all_blocks = self:get_all_blocks(),
    status = self:get_status(),
  }
end

function Model:find(block_id)
  local block = self.blocks[block_id]
  return block and copy(block)
end

function Model:destroy()
  self.subscribers = {}
end

return M
