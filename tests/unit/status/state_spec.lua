local test = require("tests.support.test")
local status = require("opencode.status")

local function contains(haystack, needle)
  test.truthy(
    type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
    ("expected %q in %q"):format(needle, tostring(haystack))
  )
end

local function absent(haystack, needle)
  test.falsy(
    type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
    ("did not expect %q in %q"):format(needle, tostring(haystack))
  )
end

local snapshot = {
  session = { id = "ses_1", title = "Fix login" },
  project = { root = "/tmp/opencode/project" },
  agent = { id = "build", name = "Build" },
  model = { provider_id = "anthropic", id = "claude-sonnet" },
  connection = "connected",
  submission = "idle",
  execution = "streaming",
}

test.describe("opencode.status state merging", function()
  test.it("updates one dimension without clearing the others", function()
    status.reset()
    status.update(snapshot)

    status.set_connection("reconnecting")
    local state = status.get_state()
    test.equal("reconnecting", state.connection)
    test.equal("idle", state.submission)
    test.equal("streaming", state.execution)
    test.equal("ses_1", state.session.id)
    test.equal("Fix login", state.session.title)

    status.set_submission("submitting")
    state = status.get_state()
    test.equal("reconnecting", state.connection)
    test.equal("submitting", state.submission)
    test.equal("streaming", state.execution)

    status.set_execution("tool_running")
    state = status.get_state()
    test.equal("reconnecting", state.connection)
    test.equal("submitting", state.submission)
    test.equal("tool_running", state.execution)
    test.equal("anthropic", state.model.provider_id)
  end)

  test.it("accepts partial literal updates and a nested 05C status table", function()
    status.reset()
    status.update({
      generation = 1,
      session = { id = "ses_1" },
      status = {
        session = { title = "From status" },
        connection = "connected",
        execution = "streaming",
      },
    })
    local line = status.render(status.get_state(), "message")
    contains(line, "Session: From status")
    contains(line, "Connection: connected")
    contains(line, "Execution: streaming")

    status.update({ submission = "submitting" })
    line = status.render(status.get_state(), "message")
    contains(line, "Submission: submitting")
    contains(line, "Execution: streaming")
  end)

  test.it("keeps waiting_permission across ordinary execution progress", function()
    status.reset()
    status.update({
      session = { id = "ses_1" },
      execution = "waiting_permission",
      waiting_permission = { request_1 = { tool = "edit" } },
    })
    local line = status.render(status.get_state(), "message")
    contains(line, "Execution: waiting permission")

    status.set_execution("tool_running")
    line = status.render(status.get_state(), "message")
    contains(line, "Execution: tool running")
    contains(line, "Permission: waiting permission")

    status.update({ execution = "idle" })
    line = status.render(status.get_state(), "message")
    contains(line, "Execution: idle")
    contains(line, "Permission: waiting permission")

    status.update({ waiting_permission = {} })
    line = status.render(status.get_state(), "message")
    absent(line, "waiting permission")
  end)

  test.it("degraded fields do not inherit stale values from another session", function()
    status.reset()
    status.update({
      generation = 1,
      session = { id = "a", title = "Session A" },
      project = { root = "/tmp/a" },
      agent = { name = "Build" },
      model = { provider_id = "p", id = "m" },
      execution = "streaming",
    })
    test.truthy(status.update({ generation = 2, session = { id = "b", title = "Session B" } }))

    local state = status.get_state()
    test.equal("b", state.session.id)
    test.equal(nil, state.project)
    test.equal(nil, state.agent)
    test.equal(nil, state.model)
    test.equal(nil, state.execution)
    test.equal(nil, state.submission)

    local line = status.render(state, "message")
    contains(line, "Session: Session B")
    absent(line, "Session A")
    absent(line, "Project:")
    absent(line, "Execution:")
  end)

  test.it("ignores stale generations and old sessions", function()
    status.reset()
    status.update({ generation = 1, session = { id = "a", title = "Session A" }, execution = "streaming" })
    status.update({ generation = 2, session = { id = "b", title = "Session B" }, execution = "idle" })

    test.falsy(status.update({
      generation = 1,
      session = { id = "a", title = "Session A" },
      execution = "failed",
    }))
    local line = status.render(status.get_state(), "message")
    contains(line, "Session: Session B")
    contains(line, "Execution: idle")
    absent(line, "failed")

    test.falsy(status.update({
      generation = 2,
      session = { id = "a", title = "Session A" },
      execution = "failed",
    }))
    line = status.render(status.get_state(), "message")
    contains(line, "Session: Session B")
    absent(line, "failed")

    test.falsy(status.set_execution("failed", { generation = 1 }))
    test.falsy(status.set_connection("offline", { generation = 1, session_id = "b" }))
    test.equal("idle", status.get_state().execution)
    test.equal(nil, status.get_state().connection)

    test.truthy(status.set_execution("tool_running", { generation = 3, session_id = "b" }))
    test.equal("tool_running", status.get_state().execution)
  end)

  test.it("supports an explicit session switch at the same generation", function()
    status.reset()
    status.update({ generation = 1, session = { id = "a", title = "Session A" }, execution = "streaming" })
    test.truthy(status.update({ generation = 1, session = { id = "b", title = "Session B" }, switch = true }))
    local line = status.render(status.get_state(), "message")
    contains(line, "Session: Session B")
    absent(line, "streaming")
  end)

  test.it("notifies only for actionable failure transitions", function()
    local original_notify = vim.notify
    local calls = {}
    vim.notify = function(message, level)
      calls[#calls + 1] = { message = message, level = level }
    end
    local ok, err = pcall(function()
      status.reset()
      status.update({ connection = "connected", submission = "idle", execution = "idle" })
      status.set_connection("reconnecting")
      status.set_submission("submitting")
      status.set_execution("streaming")
      status.update({ execution = "retrying" })
      test.equal(0, #calls)

      status.set_submission("failed", { error = { message = "rejected", code = "E_SUBMIT" } })
      test.equal(1, #calls)
      test.matches("submission failed", calls[1].message)
      test.matches("rejected", calls[1].message)
      test.equal(vim.log.levels.ERROR, calls[1].level)

      status.set_submission("failed", { error = "rejected again" })
      test.equal(1, #calls)

      status.set_submission("idle")
      status.set_submission("failed", { error = "rejected once more" })
      test.equal(2, #calls)

      status.set_execution("failed", { error = "boom" })
      test.equal(3, #calls)
      test.matches("execution failed", calls[3].message)
      test.matches("boom", calls[3].message)

      status.update({ execution = "failed", error = "boom" })
      test.equal(3, #calls)

      status.set_execution("idle")
      status.set_execution("failed", { error = "boom again" })
      test.equal(4, #calls)
    end)
    vim.notify = original_notify
    if not ok then
      error(err, 0)
    end
  end)

  test.it("consumes opencode.state status snapshots", function()
    status.reset()
    local state = require("opencode.state").new({
      session = { id = "ses_1", title = "Fix login" },
      project = { root = "/tmp/opencode/project" },
      agent = { id = "build", name = "Build" },
      model = { provider_id = "anthropic", id = "claude-sonnet" },
    })
    local unsubscribe = state:subscribe(function(change)
      status.update(change.status, { generation = change.generation })
    end)
    local ok, err = pcall(function()
      state:update({ connection = "reconnecting", execution = "streaming" })
      local line = status.render(status.get_state(), "message")
      contains(line, "Session: Fix login")
      contains(line, "Project: project")
      contains(line, "Agent: Build")
      contains(line, "Model: anthropic/claude-sonnet")
      contains(line, "Connection: reconnecting")
      contains(line, "Execution: streaming")

      state:apply_event({
        type = "permission.asked",
        data = { id = "permission_1", permission = "edit" },
      })
      line = status.render(status.get_state(), "message")
      contains(line, "Execution: waiting permission")

      state:apply_event({
        type = "permission.replied",
        data = { requestID = "permission_1", reply = "always" },
      })
      line = status.render(status.get_state(), "message")
      absent(line, "waiting permission")
    end)
    unsubscribe()
    state:destroy()
    if not ok then
      error(err, 0)
    end
  end)

  test.it("retains state across detach and exposes it after reattach", function()
    status.reset()
    status.update(snapshot)
    status.detach()
    test.falsy(status.is_attached())
    test.falsy(status.is_spinning())
    test.equal("Fix login", status.get_state().session.title)

    status.update({ connection = "offline" })
    test.equal("offline", status.get_state().connection)
    test.equal("streaming", status.get_state().execution)

    status.detach({ reset = true })
    test.equal(nil, status.get_state().session)
    test.equal(nil, status.get_state().connection)
  end)
end)
