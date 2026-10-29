local root = vim.fn.getcwd()
if vim.fn.filereadable(root .. "/lua/opencode/state.lua") == 0 then
  root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h:h")
end
package.path = root .. "/?.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
local fixture = dofile(root .. "/tests/fixtures/conversation/v2_inbox.lua")

test.describe("state V2 inbox", function()
  test.it("exposes V2 history and live inbox events through the state facade", function()
    local state = require("opencode.state")
    local model = state.new({
      session = { id = fixture.session_id },
      project = { root = "/tmp/opencode/v2-fixture-project" },
    })

    assert(model:apply_batch({ generation = 1, snapshot = fixture.snapshot }))
    test.equal("fix the real prompt", model:find(fixture.user_id).content)
    test.equal("I will inspect the file.", model:find(fixture.assistant_id).content)

    assert(model:apply_event(fixture.inbox_enqueued))
    assert(model:apply_event(fixture.inbox_delivered))
    local user = model:find(fixture.user_id)
    test.equal(true, user.metadata.inbox.enqueued)
    test.equal(true, user.metadata.inbox.delivered)
    test.equal("steer", user.metadata.inbox.delivery)

    local snapshot = model:get_snapshot()
    local users = 0
    for _, block in ipairs(snapshot.blocks) do
      if block.type == "user" then
        users = users + 1
      end
    end
    test.equal(1, users)
    test.equal(2, #snapshot.blocks)
    test.equal(fixture.session_id, snapshot.status.session.id)
    test.equal("/tmp/opencode/v2-fixture-project", snapshot.status.project.root)
  end)
end)
