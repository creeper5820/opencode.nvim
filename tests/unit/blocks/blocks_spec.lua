local root = vim.fn.getcwd()
if vim.fn.filereadable(root .. "/lua/opencode/blocks.lua") == 0 then
  root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h:h")
end
package.path = root .. "/?.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
test.describe("blocks", function()
test.it("projects fixture conversation into a stable state model", function()
local blocks = require("opencode.blocks")
local fixture = dofile(root .. "/tests/fixtures/conversation/basic.lua")

local failures = 0
local checks = 0
local function check(condition, message)
  checks = checks + 1
  if not condition then
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
  end
end
local function eq(actual, expected, message)
  check(actual == expected, message .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
end
local function find_node(model, id)
  return model:find(id)
end
local function build()
  local model = blocks.new()
  model:apply_batch({ generation = 1, snapshot = fixture.snapshot, events = fixture.events })
  return model
end

-- Tree shape, stable order and ownership.
local model = build()
local snapshot = model:get_snapshot()
eq(#snapshot.blocks, 5, "message and status roots")
eq(snapshot.blocks[1].id, "msg_user", "user message first")
eq(snapshot.blocks[2].id, "msg_assistant", "assistant message second")
eq(snapshot.blocks[1].content, "Please update a.lua", "user text content projected")
local assistant = snapshot.blocks[2]
eq(assistant.type, "assistant", "assistant block type")
eq(assistant.content, "Working on it. Streaming", "text delta updates the same assistant block")
local reasoning = find_node(model, "prt_reasoning")
check(reasoning ~= nil, "reasoning child exists")
eq(reasoning.type, "reasoning", "reasoning type")
eq(reasoning.parent_id, "msg_assistant", "reasoning parent")
eq(reasoning.message_id, "msg_assistant", "reasoning message")
local tool = find_node(model, "prt_tool")
check(tool ~= nil, "tool child exists")
eq(tool.type, "tool", "tool type")
eq(tool.parent_id, "msg_assistant", "tool belongs to assistant")
eq(tool.status, "completed", "tool status merged")
eq(tool.metadata.output, "updated", "tool output owned by tool")
eq(tool.metadata.input.filePath, "src/a.lua", "tool input owned by tool")
eq(#tool.metadata.diff.files, 2, "diff keeps both files")
eq(#tool.metadata.diff.files[1].hunks, 2, "diff keeps both hunks")
eq(tool.metadata.diff.files[2].hunks[1].lines[2].text, "+return b", "diff keeps complete lines")
eq(#assistant.children, 2, "text part is not duplicated as a child")

-- Permission lifecycle.
eq(model.execution, "compacting", "last status event wins")
local permission = find_node(model, "perm_1")
check(permission ~= nil, "permission status block exists")
eq(permission.type, "status", "permission block type")
eq(permission.status, "completed", "permission reply closes request")
eq(permission.parent_id, "prt_tool", "permission attaches to tool")

local waiting = blocks.new()
waiting:apply_batch({ generation = 1, snapshot = fixture.snapshot, events = fixture.events })
check(waiting:get_status().waiting_permission.perm_1 == nil, "replied permission is not pending")
local asked_only = blocks.new()
asked_only:apply_event({ id = "e1", type = "permission.asked", data = { id = "perm_x", sessionID = "ses_fixture" } })
eq(asked_only:get_status().execution, "waiting_permission", "asked sets waiting_permission")
asked_only:apply_event({ id = "e2", type = "permission.replied", data = { requestID = "perm_x", reply = "once" } })
eq(asked_only:get_status().execution, "streaming", "reply clears waiting_permission")

-- Retry, compaction and unknown detail.
local retry = waiting:find("retry:msg_assistant")
check(retry ~= nil, "retry status block")
eq(retry.metadata.kind, "retry", "retry kind")
local compaction = waiting:find("compaction")
check(compaction ~= nil, "compaction status block")
eq(compaction.status, "running", "compaction running")
local unknown = waiting:find("evt_unknown")
check(unknown ~= nil, "unknown block exists")
eq(unknown.type, "unknown", "unknown type")
eq(unknown.metadata.data.answer, 42, "unknown raw data preserved")

-- Revision changes only for affected nodes.
local before_tool = waiting:find("prt_tool").revision
local before_reasoning = waiting:find("prt_reasoning").revision
waiting:apply_event({
  id = "evt_delta_2",
  type = "message.part.delta",
  data = { messageID = "msg_assistant", partID = "prt_text", field = "text", delta = " More." },
})
eq(waiting:find("prt_tool").revision, before_tool, "tool revision unchanged by text delta")
eq(waiting:find("prt_reasoning").revision, before_reasoning, "reasoning revision unchanged")
eq(waiting:find("msg_assistant").content, "Working on it. Streaming More.", "delta appended")
local before_assistant = waiting:find("msg_assistant").revision
waiting:apply_event({
  id = "evt_tool_noop",
  type = "message.part.updated",
  data = { part = {
    id = "prt_tool", messageID = "msg_assistant", type = "tool", callID = "call_1", tool = "edit",
    state = { status = "completed", input = { filePath = "src/a.lua" }, output = "updated" },
    input = { filePath = "src/a.lua" }, output = "updated",
  } },
})
eq(waiting:find("msg_assistant").revision, before_assistant, "unchanged update does not bump revision")
eq(waiting:find("prt_tool").status, "completed", "tool remains completed")

-- Dedupe history/realtime and non-destructive overlap.
local dedup = build()
local function all_nodes(model_to_count)
  local out = {}
  local function walk(ids)
    for _, id in ipairs(ids or {}) do
      local node = model_to_count:find(id)
      if node then
        out[#out + 1] = node
        walk(node.children)
      end
    end
  end
  walk(model_to_count.roots)
  return out
end
local count = #all_nodes(dedup)
dedup:apply_event(fixture.overlap_event)
eq(#all_nodes(dedup), count, "overlapping part does not create duplicate block")
local baseline = dedup:find("prt_tool").revision
dedup:apply_event(fixture.overlap_event)
eq(dedup:find("prt_tool").revision, baseline, "duplicate event ignored")

-- Generation handling.
local generation = build()
local ignored = generation:apply_event({ id = "old", generation = 0, type = "message.part.delta", data = { messageID = "msg_assistant", partID = "prt_text", delta = "OLD" } })
eq(ignored, false, "old generation event ignored")
check(not generation:find("msg_assistant").content:find("OLD", 1, true), "old delta not applied")
local newer = blocks.new()
newer:apply_batch({ generation = 2, snapshot = fixture.snapshot })
newer:apply_batch({ generation = 3, snapshot = fixture.snapshot, events = { { id = "newer", type = "session.idle", data = {} } } })
eq(newer.generation, 3, "generation advances")
check(newer:apply_batch({ generation = 2, snapshot = fixture.snapshot }) == false, "older batch ignored")

-- Batched high-frequency deltas; no content loss.
local streamed = blocks.new()
streamed:apply_batch({ generation = 1, snapshot = { messages = { { info = { id = "m", role = "assistant", time = { created = 1 } }, parts = { { id = "p", messageID = "m", type = "text", text = "" } } } } } })
local events = {}
for index = 1, 100 do
  events[#events + 1] = {
    id = "d" .. index,
    type = "message.part.delta",
    data = { messageID = "m", partID = "p", field = "text", delta = tostring(index) .. "," },
  }
end
streamed:apply_batch({ generation = 1, events = events })
eq(streamed:find("m").content, (function()
  local out = {}
  for index = 1, 100 do
    out[#out + 1] = tostring(index) .. ","
  end
  return table.concat(out)
end)(), "batched deltas preserve all content")

-- V2-style envelope (`data` plus session.* deltas) adaptation boundary.
local v2 = blocks.new()
v2:apply_event({ id = "v2-m", type = "message.updated", data = { sessionID = "s", info = { id = "m2", role = "assistant", time = { created = 3 } } } })
v2:apply_event({ id = "v2-r1", type = "session.reasoning.started", data = { sessionID = "s", assistantMessageID = "m2", ordinal = 0 } })
v2:apply_event({ id = "v2-r2", type = "session.reasoning.delta", data = { sessionID = "s", assistantMessageID = "m2", ordinal = 0, delta = "think" } })
v2:apply_event({ id = "v2-r3", type = "session.reasoning.ended", data = { sessionID = "s", assistantMessageID = "m2", ordinal = 0, text = "thinking" } })
v2:apply_event({ id = "v2-t1", type = "session.tool.called", data = { sessionID = "s", assistantMessageID = "m2", id = "t1", name = "bash", input = { command = "true" } } })
v2:apply_event({ id = "v2-t2", type = "session.tool.success", data = { sessionID = "s", assistantMessageID = "m2", id = "t1", content = { { type = "text", text = "ok" } }, metadata = { exit = 0 } } })
local v2_assistant = v2:find("m2")
eq(#v2_assistant.children, 2, "V2 reasoning and tool children")
eq(v2:find("reasoning:m2:0").content, "thinking", "V2 reasoning delta/ended")
eq(v2:find("t1").status, "completed", "V2 tool success status")
eq(v2:find("t1").metadata.input.command, "true", "V2 tool input")
check(v2:find("t1").metadata.output ~= nil, "V2 tool output")

-- Legacy properties envelope remains a supported adapter boundary.
local legacy = blocks.new()
legacy:apply_event({ id = "legacy-m", type = "message.updated", properties = { info = { id = "lm", role = "assistant", time = { created = 4 } } } })
legacy:apply_event({ id = "legacy-p", type = "message.part.updated", properties = { part = { id = "lp", messageID = "lm", type = "text", text = "legacy" } } })
eq(legacy:find("lm").content, "legacy", "properties envelope normalized")

-- Subscriptions and deterministic replay.
local changes = {}
local unsubscribe = model:subscribe(function(change)
  changes[#changes + 1] = change
end)
model:apply_event({ id = "sub", type = "message.part.delta", data = { messageID = "msg_assistant", partID = "prt_text", delta = "!" } })
check(#changes == 1, "subscriber receives update")
check(#changes[1].changed >= 1, "change contains changed blocks")
unsubscribe()
model:apply_event({ id = "sub2", type = "message.part.delta", data = { messageID = "msg_assistant", partID = "prt_text", delta = "?" } })
eq(#changes, 1, "unsubscribe stops updates")

local first_replay = build():get_snapshot()
local second_replay = build():get_snapshot()
eq(first_replay.revision, second_replay.revision, "replay revision deterministic")
for index, node in ipairs(first_replay.blocks) do
  eq(node.id, second_replay.blocks[index].id, "root order deterministic " .. tostring(index))
end
eq(first_replay.blocks[2].content, second_replay.blocks[2].content, "content deterministic")

-- Error maps to assistant/status and execution.
local failed = blocks.new()
failed:apply_batch({ generation = 1, snapshot = fixture.snapshot })
failed:apply_event({ id = "err", type = "session.execution.failed", data = { sessionID = "ses_fixture", assistantMessageID = "msg_assistant", error = { message = "boom" } } })
eq(failed:find("msg_assistant").status, "failed", "assistant failed")
eq(failed:get_status().execution, "failed", "execution failed")
eq(failed:get_status().error.message, "boom", "error details preserved")

local function stable(value)
  if type(value) ~= "table" then
    return type(value) .. ":" .. tostring(value)
  end
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = { "{" }
  for _, key in ipairs(keys) do
    out[#out + 1] = tostring(key) .. "=" .. stable(value[key]) .. ";"
  end
  out[#out + 1] = "}"
  return table.concat(out)
end
eq(stable(build():get_snapshot()), stable(build():get_snapshot()), "full snapshot deterministic on replay")

if failures > 0 then
  error(string.format("%d/%d checks failed", failures, checks), 0)
end
print(string.format("blocks: %d checks passed", checks))
end)
end)
