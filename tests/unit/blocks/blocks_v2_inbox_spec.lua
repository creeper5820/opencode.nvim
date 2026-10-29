local root = vim.fn.getcwd()
if vim.fn.filereadable(root .. "/lua/opencode/blocks.lua") == 0 then
  root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h:h")
end
package.path = root .. "/?.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
local fixture = dofile(root .. "/tests/fixtures/conversation/v2_inbox.lua")

local function user_blocks(model)
  local found = {}
  for _, block in ipairs(model:get_blocks()) do
    if block.type == "user" then
      found[#found + 1] = block
    end
  end
  return found
end

test.describe("blocks V2 inbox and history", function()
  test.it("projects V2 direct history entries and assistant content", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    assert(model:apply_batch({ generation = 1, snapshot = fixture.snapshot }))

    local user = model:find(fixture.user_id)
    test.truthy(user, "V2 user history entry becomes a user block")
    test.equal("user", user.type)
    test.equal("completed", user.status)
    test.equal("fix the real prompt", user.content)
    test.equal(user.id, user.message_id)

    local assistant = model:find(fixture.assistant_id)
    test.truthy(assistant, "V2 assistant history entry")
    test.equal("assistant", assistant.type)
    test.equal("completed", assistant.status)
    test.equal("I will inspect the file.", assistant.content)

    local reasoning = model:find("reasoning:" .. fixture.assistant_id .. ":0")
    test.truthy(reasoning, "V2 reasoning content becomes a reasoning block")
    test.equal("reasoning", reasoning.type)
    test.equal("Read before editing.", reasoning.content)
    test.equal(fixture.assistant_id, reasoning.parent_id)

    local tool = model:find("tool_v2_fixture")
    test.truthy(tool, "V2 tool content becomes a tool block")
    test.equal("tool", tool.type)
    test.equal("completed", tool.status)
    test.equal("bash", tool.content)
    test.equal("true", tool.metadata.input.command)
    test.truthy(type(tool.metadata.output) == "table", "V2 state.content becomes tool output")
    test.equal("ok", tool.metadata.output[1].text)
    test.equal(fixture.assistant_id, tool.parent_id)
    test.equal(2, #assistant.children)
    for _, node in ipairs({ user, assistant, reasoning, tool }) do
      test.truthy(type(node.sequence) == "number" and node.sequence > 0, "positive stable sequence")
    end
  end)

  test.it("merges V2 inbox events with history without duplicating the user message", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    assert(model:apply_batch({ generation = 1, snapshot = fixture.snapshot }))
    local roots = #model.roots
    local user = model:find(fixture.user_id)
    local baseline = user.revision

    assert(model:apply_event(fixture.inbox_enqueued))
    test.equal(roots, #model.roots, "enqueued event must not create a second root")
    test.equal(1, #user_blocks(model), "enqueued event must not create a second user block")
    user = model:find(fixture.user_id)
    test.equal("fix the real prompt", user.content)
    test.equal(true, user.metadata.inbox.enqueued)
    test.equal("steer", user.metadata.inbox.delivery)
    test.equal("fix the real prompt", user.metadata.inbox.payload.text)
    local enqueued_revision = user.revision

    local duplicate_id = model:apply_event(fixture.inbox_enqueued)
    test.equal(false, duplicate_id, "native evt_ id de-duplicates an exact replay")
    model:apply_event(fixture.inbox_enqueued_duplicate)
    user = model:find(fixture.user_id)
    test.equal(1, #user_blocks(model), "replayed enqueued event keeps one user block")
    test.equal(enqueued_revision, user.revision, "identical replay does not bump revision")

    assert(model:apply_event(fixture.inbox_delivered))
    user = model:find(fixture.user_id)
    test.equal(true, user.metadata.inbox.delivered)
    test.equal(1, #user_blocks(model), "delivered event keeps one user block")
    local delivered_revision = user.revision
    model:apply_event(fixture.inbox_delivered_duplicate)
    user = model:find(fixture.user_id)
    test.equal(delivered_revision, user.revision, "replayed delivery does not bump revision")
    test.equal(baseline + 2, user.revision, "only enqueue metadata and delivery changed the block")
  end)

  test.it("keeps a live user block when history arrives later", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    assert(model:apply_event(fixture.inbox_enqueued))
    assert(model:apply_event(fixture.inbox_delivered))
    local user = model:find(fixture.user_id)
    test.truthy(user, "live enqueued event creates the user block")
    test.equal("fix the real prompt", user.content)
    test.equal(1000, user.metadata.info.time.created)
    test.equal(true, user.metadata.inbox.delivered)
    test.equal(1, #model.roots)

    assert(model:apply_batch({ generation = 2, snapshot = fixture.snapshot }))
    test.equal(1, #user_blocks(model), "history reset merges the same native id")
    test.equal("fix the real prompt", model:find(fixture.user_id).content)
    test.equal(2, #model.roots, "user and assistant history roots")
  end)

  test.it("records delivery that arrives before enqueue without an empty block", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    assert(model:apply_event(fixture.inbox_delivered))
    test.equal(0, #model.roots, "delivery alone must not create an empty user message")
    assert(model:apply_event(fixture.inbox_enqueued))
    local user = model:find(fixture.user_id)
    test.truthy(user)
    test.equal(true, user.metadata.inbox.delivered, "pending delivery is applied to the enqueued message")
    test.equal(1, #user_blocks(model))
  end)

  test.it("uses native V2 event ids for unknown block de-duplication", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    local event = {
      type = "session.future.changed",
      data = {
        id = "evt_v2_future",
        type = "session.future.changed",
        data = { sessionID = fixture.session_id, value = 7 },
      },
    }
    assert(model:apply_event(event))
    test.truthy(model:find("evt_v2_future"))
    test.equal(7, model:find("evt_v2_future").metadata.data.value)
    test.equal(false, model:apply_event(event), "same native event id is ignored")
    test.equal(1, #model.roots)
  end)
end)
