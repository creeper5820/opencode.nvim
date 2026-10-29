local root = vim.fn.getcwd()
if vim.fn.filereadable(root .. "/lua/opencode/state.lua") == 0 then
  root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h:h")
end
package.path = root .. "/?.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
test.describe("state", function()
test.it("projects fixture conversation into a stable state model", function()
local state = require("opencode.state")
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

local model = state.new({
  session_id = "ses_fixture",
  session = { id = "ses_fixture", title = "Fixture" },
  project = { root = "/tmp/opencode/fixture-project" },
  agent = { id = "build", name = "Build" },
  model = { provider_id = "test", id = "model" },
})
eq(model:get_status().session.title, "Fixture", "initial session metadata")
eq(model:get_status().agent.name, "Build", "initial agent metadata")

local changes = {}
local unsubscribe = model:subscribe(function(change, subject)
  changes[#changes + 1] = { change = change, subject = subject }
end)

model:apply_batch({ generation = 1, snapshot = fixture.snapshot, events = fixture.events })
local snapshot = model:get_snapshot()
eq(snapshot.blocks[2].type, "assistant", "block snapshot available through state")
eq(snapshot.status.execution, "compacting", "execution projected")
eq(snapshot.status.session.id, "ses_fixture", "snapshot session id")
eq(snapshot.status.project.root, "/tmp/opencode/fixture-project", "project retained")
check(#changes >= 1, "subscriber receives batch change")
eq(changes[#changes].subject, model, "subscriber receives state object")

-- Partial updates must not clear other dimensions.
model:set_connection("reconnecting")
eq(model:get_status().connection, "reconnecting", "connection updated")
eq(model:get_status().submission, "idle", "submission preserved")
eq(model:get_status().execution, "compacting", "execution preserved")
model:set_submission("submitting")
eq(model:get_status().submission, "submitting", "submission updated")
eq(model:get_status().connection, "reconnecting", "connection preserved")
model:update({ execution = "idle" })
eq(model:get_status().execution, "idle", "execution updated")
eq(model:get_status().submission, "submitting", "submission preserved after update")
model:update({ session = { title = "Renamed" } })
eq(model:get_status().session.title, "Renamed", "nested metadata merged")
eq(model:get_status().session.id, "ses_fixture", "nested metadata not replaced")

-- Session event enriches state metadata without affecting blocks.
model:apply_event({
  id = "session-event",
  type = "session.updated",
  data = { sessionID = "ses_fixture", info = { id = "ses_fixture", title = "From event" } },
})
eq(model:get_status().session.title, "From event", "event session metadata merged")
check(model:find("msg_assistant") ~= nil, "blocks intact after session metadata event")

-- Permission wait is visible in status and remains until reply.
local waiting = state.new({ session_id = "s" })
waiting:apply_batch({ generation = 1, snapshot = { messages = {
  { info = { id = "a", role = "assistant", time = { created = 1 } }, parts = {
    { id = "t", messageID = "a", type = "tool", callID = "c", tool = "bash", state = { status = "running" } },
  } },
} } })
waiting:apply_event({ id = "ask", type = "permission.asked", data = {
  id = "p", sessionID = "s", permission = "bash",
  tool = { messageID = "a", callID = "c" },
} })
eq(waiting:get_status().execution, "waiting_permission", "waiting permission exposed")
eq(waiting:get_status().waiting_permission.p.pending, true, "pending permission details")
waiting:apply_event({ id = "other", type = "message.part.delta", data = { messageID = "a", partID = "t", field = "input", delta = "x" } })
eq(waiting:get_status().execution, "waiting_permission", "ordinary events do not clear waiting")
waiting:apply_event({ id = "reply", type = "permission.replied", data = { requestID = "p", reply = "once" } })
eq(waiting:get_status().execution, "streaming", "reply clears waiting")

-- Old generation events cannot overwrite current state.
local stable = state.new()
stable:apply_batch({ generation = 5, snapshot = fixture.snapshot })
local content = stable:find("msg_assistant").content
eq(stable:apply_event({ id = "stale", generation = 4, type = "message.part.delta", data = { messageID = "msg_assistant", partID = "prt_text", delta = "STALE" } }), false, "stale generation rejected")
eq(stable:find("msg_assistant").content, content, "stale event did not alter content")

unsubscribe()
local count = #changes
model:set_connection("offline")
eq(#changes, count, "unsubscribe stops state notifications")
model:destroy()

if failures > 0 then
  error(string.format("%d/%d checks failed", failures, checks), 0)
end
print(string.format("state: %d checks passed", checks))
end)
end)
