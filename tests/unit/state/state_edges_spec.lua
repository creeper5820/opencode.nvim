local root = vim.fn.getcwd()
if vim.fn.filereadable(root .. "/lua/opencode/state.lua") == 0 then
  root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h:h")
end
package.path = root .. "/?.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")

test.describe("state facade edges", function()
  test.it("clears explicit error and retry without dropping other dimensions", function()
    local state = require("opencode.state")
    local model = state.new({
      session = { id = "s", title = "Session" },
      project = { root = "/tmp/opencode/project" },
      agent = { id = "build", name = "Build" },
      model = { provider_id = "test", id = "m" },
    })
    model:update({ error = { message = "boom" }, retry = { attempt = 2 }, execution = "failed" })
    test.equal("boom", model:get_status().error.message)
    test.equal(2, model:get_status().retry.attempt)
    model:update({ error = false, retry = false })
    test.equal(nil, model:get_status().error)
    test.equal(nil, model:get_status().retry)
    test.equal("failed", model:get_status().execution)
    test.equal("Session", model:get_status().session.title)
    test.equal("Build", model:get_status().agent.name)
    test.equal("test", model:get_status().model.provider_id)

    model:update({ status = { connection = "offline", execution = "interrupted", error = { message = "nested" } } })
    test.equal("offline", model:get_status().connection)
    test.equal("interrupted", model:get_status().execution)
    test.equal("nested", model:get_status().error.message)
    test.equal("Session", model:get_status().session.title)
  end)

  test.it("keeps location in sync with session events and snapshots", function()
    local state = require("opencode.state")
    local model = state.new({ session_id = "s" })
    model:apply_event({
      id = "move",
      type = "session.moved",
      data = { sessionID = "s", location = { directory = "/tmp/opencode/one" } },
    })
    test.equal("/tmp/opencode/one", model:get_status().location.directory)
    test.equal("/tmp/opencode/one", model:get_snapshot().location.directory)
    model:apply_batch({
      generation = 1,
      snapshot = {
        session_id = "s",
        location = { directory = "/tmp/opencode/two" },
        messages = {},
      },
    })
    test.equal("/tmp/opencode/two", model:get_status().location.directory)
    test.equal("/tmp/opencode/two", model:get_snapshot().location.directory)
  end)

  test.it("rejects old generation reset without merging its metadata", function()
    local state = require("opencode.state")
    local model = state.new({ session = { id = "s", title = "Current" } })
    model:apply_batch({ generation = 5, snapshot = { session_id = "s", messages = {} } })
    local accepted = model:reset({
      generation = 4,
      session_id = "old",
      session = { id = "old", title = "Old" },
      messages = {},
    }, 4)
    test.equal(false, accepted)
    test.equal(5, model:get_snapshot().generation)
    test.equal("Current", model:get_status().session.title)
    test.equal("s", model:get_status().session.id)
  end)
end)
