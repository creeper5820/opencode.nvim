local test = require("tests.support.test")
local session_action = require("opencode.actions.session")

local function collector()
  local calls = {}
  return calls, function(err, result)
    calls[#calls + 1] = { err = err, result = result }
  end
end

local function controller_with(fn)
  return {
    interrupt = fn,
  }
end

test.describe("opencode.actions.session interrupt", function()
  test.it("calls controller.interrupt and normalizes a successful result", function()
    local calls, callback = collector()
    local called = 0
    local controller = controller_with(function(_, done)
      called = called + 1
      done(nil, { interrupted = true, idle = false, extra = "value" })
    end)

    session_action.interrupt(controller, callback)
    test.equal(1, called)
    test.equal(1, #calls)
    test.equal(nil, calls[1].err)
    test.equal(true, calls[1].result.interrupted)
    test.equal(false, calls[1].result.idle)
    test.equal("value", calls[1].result.result.extra)
  end)

  test.it("treats an idle no-op result as success", function()
    local calls, callback = collector()
    local controller = controller_with(function(_, done)
      done(nil, { interrupted = false, idle = true })
    end)

    session_action.interrupt(controller, callback)
    test.equal(nil, calls[1].err)
    test.equal(false, calls[1].result.interrupted)
    test.equal(true, calls[1].result.idle)
  end)

  test.it("normalizes explicit idle error codes to an idle no-op", function()
    local calls, callback = collector()
    local controller = controller_with(function(_, done)
      done({ code = "idle", message = "nothing is running" })
    end)

    session_action.interrupt(controller, callback)
    test.equal(nil, calls[1].err)
    test.equal(false, calls[1].result.interrupted)
    test.equal(true, calls[1].result.idle)
    test.equal("idle", calls[1].result.result.code)
  end)

  test.it("forwards real interrupt errors without notifying", function()
    local notifications = 0
    local original = vim.notify
    vim.notify = function()
      notifications = notifications + 1
    end
    local calls, callback = collector()
    local controller = controller_with(function(_, done)
      done({ code = "http_error", message = "interrupt failed", status = 500 })
    end)

    local ok, err = pcall(session_action.interrupt, controller, callback)
    vim.notify = original
    if not ok then
      error(err, 0)
    end
    test.equal("http_error", calls[1].err.code)
    test.equal("interrupt failed", calls[1].err.message)
    test.equal(500, calls[1].err.status)
    test.equal(0, notifications)
  end)

  test.it("reports a missing controller method without throwing", function()
    local calls, callback = collector()
    session_action.interrupt({}, callback)
    test.equal("interrupt_unavailable", calls[1].err.code)
    test.falsy(calls[1].result)
  end)

  test.it("calls the callback at most once", function()
    local calls, callback = collector()
    local controller = controller_with(function(_, done)
      done(nil, { interrupted = true })
      done(nil, { interrupted = true })
    end)

    session_action.interrupt(controller, callback)
    test.equal(1, #calls)
  end)

  test.it("turns a synchronous throw into an error callback", function()
    local calls, callback = collector()
    local controller = controller_with(function()
      error("boom")
    end)

    local ok, err = pcall(session_action.interrupt, controller, callback)
    if not ok then
      error(err, 0)
    end
    test.equal("interrupt_failed", calls[1].err.code)
    test.matches("boom", calls[1].err.message)
  end)

  test.it("accepts a controller that returns a result synchronously", function()
    local calls, callback = collector()
    local controller = controller_with(function()
      return { interrupted = true, idle = false }
    end)

    session_action.interrupt(controller, callback)
    test.equal(nil, calls[1].err)
    test.equal(true, calls[1].result.interrupted)
    test.equal(false, calls[1].result.idle)
  end)

  test.it("accepts a controller that returns a synchronous error", function()
    local calls, callback = collector()
    local controller = controller_with(function()
      return nil, { code = "transport_error", message = "connection refused" }
    end)

    session_action.interrupt(controller, callback)
    test.equal("transport_error", calls[1].err.code)
    test.equal("connection refused", calls[1].err.message)
  end)
end)
