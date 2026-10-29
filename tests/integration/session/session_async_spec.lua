-- 05A session integration tests: asynchronous client callbacks, coalescing,
-- persistence across controllers and stale-result suppression. No real
-- OpenCode service is used here; task 10 owns the end-to-end smoke test.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
local H = dofile(root .. "/tests/unit/session/helper.lua")
local session = require("opencode.session")
local store_mod = require("opencode.session_store")

test.describe("session controller async", function()
  test.it("one delayed creation serves all concurrent ensure callers", H.case(function()
    local project = H.tempdir("async-project")
    local client = H.fake_client({
      create_session = function(entry)
        vim.defer_fn(function()
          entry.callback(nil, { id = "ses_async", location = { directory = project } })
        end, 10)
      end,
    })
    local controller = session.new({
      client = client,
      store = H.fake_store(),
      config = { project = { root = project } },
    })
    local first = H.collector()
    local second = H.collector()
    local third = H.collector()
    controller:ensure(first.callback)
    controller:ensure(second.callback)
    controller:ensure(third.callback)

    test.equal(1, client:count("create_session"), "one create request")
    test.equal(0, #first.calls, "callbacks wait for the server")
    test.truthy(H.wait_until(function()
      return #first.calls == 1 and #second.calls == 1 and #third.calls == 1
    end), "all callers complete")

    test.equal("ses_async", first.calls[1].value.session.id)
    test.equal("ses_async", second.calls[1].value.session.id)
    test.equal("ses_async", third.calls[1].value.session.id)
    test.equal(1, client:count("create_session"))
  end))

  test.it("reports submitting until an async prompt is accepted", H.case(function()
    local project = H.tempdir("async-prompt")
    local accept
    local client = H.fake_client({
      prompt = function(entry)
        accept = entry.callback
      end,
    })
    local controller = session.new({
      client = client,
      store = H.fake_store(),
      config = { project = { root = project } },
    })
    local ensured = H.collector()
    controller:ensure(ensured.callback)
    test.falsy(ensured.calls[1].err)

    local collected = H.collector()
    controller:prompt("async work", collected.callback)
    test.equal("submitting", controller:get_snapshot().submission)
    test.equal(0, #collected.calls)

    vim.defer_fn(function()
      accept(nil, { accepted = true })
    end, 10)
    test.truthy(H.wait_until(function()
      return #collected.calls == 1
    end), "prompt callback completes")
    test.falsy(collected.calls[1].err)
    test.equal(true, collected.calls[1].value.accepted)
    test.equal("accepted", controller:get_snapshot().submission)
  end))

  test.it("treats an async idle interrupt as success", H.case(function()
    local project = H.tempdir("async-interrupt")
    local finish
    local client = H.fake_client({
      interrupt = function(entry)
        finish = entry.callback
      end,
    })
    local controller = session.new({
      client = client,
      store = H.fake_store(),
      config = { project = { root = project } },
    })
    local ensured = H.collector()
    controller:ensure(ensured.callback)
    test.falsy(ensured.calls[1].err)

    local collected = H.collector()
    controller:interrupt({ resume = false }, collected.callback)
    test.equal("interrupting", controller:get_snapshot().interrupt.status)
    test.equal(0, #collected.calls)

    vim.defer_fn(function()
      finish(nil, { interrupted = false })
    end, 10)
    test.truthy(H.wait_until(function()
      return #collected.calls == 1
    end), "interrupt callback completes")
    test.falsy(collected.calls[1].err, "idle no-op succeeds")
    test.equal(false, collected.calls[1].value.interrupted)
    test.equal(true, collected.calls[1].value.idle)
    test.equal("noop", controller:get_snapshot().interrupt.status)
  end))

  test.it("drops an async interrupt result after reset", H.case(function()
    local project = H.tempdir("async-interrupt-reset")
    local finish
    local create_count = 0
    local client = H.fake_client({
      create_session = function(entry)
        create_count = create_count + 1
        entry.callback(nil, {
          id = create_count == 1 and "ses_one" or "ses_two",
          location = { directory = entry.params.directory },
        })
      end,
      interrupt = function(entry)
        finish = entry.callback
      end,
    })
    local controller = session.new({
      client = client,
      store = H.fake_store(),
      config = { project = { root = project } },
    })
    local ensured = H.collector()
    controller:ensure(ensured.callback)
    test.falsy(ensured.calls[1].err)
    test.equal("ses_one", controller:get_snapshot().session.id)

    local collected = H.collector()
    controller:interrupt(collected.callback)
    controller:reset()
    local fresh = H.collector()
    controller:ensure(fresh.callback)
    test.falsy(fresh.calls[1].err)
    test.equal("ses_two", controller:get_snapshot().session.id)

    finish(nil, { interrupted = true })
    vim.wait(20)
    test.equal(0, #collected.calls, "old generation callback is dropped")
    test.equal("idle", controller:get_snapshot().interrupt.status)
    test.equal("ses_two", controller:get_snapshot().session.id)
  end))

  test.it("restores a session persisted by an earlier controller", H.case(function()
    local project = H.tempdir("persisted")
    local path = H.tempdir("persist-state") .. "/sessions.json"
    local first_client = H.fake_client({
      create_session = { result = { id = "ses_persisted", location = { directory = project } } },
    })
    local first = session.new({
      client = first_client,
      store_path = path,
      config = { project = { root = project } },
    })
    local ensured = H.collector()
    first:ensure(ensured.callback)
    test.falsy(ensured.calls[1].err)
    test.equal("ses_persisted", first:get_snapshot().session.id)
    test.equal("ses_persisted", store_mod.new({ path = path }):get(project).id)

    local second_client = H.fake_client({
      list_sessions = {
        result = { data = { { id = "ses_persisted", location = { directory = project } } } },
      },
    })
    local second = session.new({
      client = second_client,
      store_path = path,
      config = { project = { root = project } },
    })
    local restored = H.collector()
    second:ensure(restored.callback)
    test.falsy(restored.calls[1].err)
    test.equal("ses_persisted", restored.calls[1].value.session.id)
    test.equal(0, second_client:count("create_session"), "restored instead of created")
  end))

  test.it("drops an async ensure result after destroy", H.case(function()
    local project = H.tempdir("destroyed")
    local finish
    local client = H.fake_client({
      create_session = function(entry)
        finish = entry.callback
      end,
    })
    local controller = session.new({
      client = client,
      store = H.fake_store(),
      config = { project = { root = project } },
    })
    local collected = H.collector()
    controller:ensure(collected.callback)
    test.equal(1, client:count("create_session"))

    controller:destroy()
    finish(nil, { id = "ses_late", location = { directory = project } })
    vim.wait(20)
    test.equal(0, #collected.calls, "destroyed controller ignores late callbacks")
    test.equal("destroyed", controller:get_snapshot().status)
    test.falsy(controller:get_snapshot().session)
  end))

  test.it("drops an async prompt result after the session is switched", H.case(function()
    local project = H.tempdir("switch-async")
    local create_count = 0
    local pending_prompt
    local client = H.fake_client({
      create_session = function(entry)
        create_count = create_count + 1
        vim.defer_fn(function()
          entry.callback(nil, {
            id = create_count == 1 and "ses_one" or "ses_two",
            location = { directory = project },
          })
        end, 5)
      end,
      prompt = function(entry)
        pending_prompt = entry.callback
      end,
    })
    local controller = session.new({
      client = client,
      store = H.fake_store(),
      config = { project = { root = project } },
    })
    local ensured = H.collector()
    controller:ensure(ensured.callback)
    test.truthy(H.wait_until(function()
      return #ensured.calls == 1
    end))
    test.equal("ses_one", controller:get_snapshot().session.id)

    local old = H.collector()
    controller:prompt("old request", old.callback)
    test.truthy(pending_prompt)

    controller:reset()
    controller:ensure()
    controller:ensure()
    test.truthy(H.wait_until(function()
      return controller:get_snapshot().session ~= nil
    end))
    test.equal("ses_two", controller:get_snapshot().session.id)

    pending_prompt(nil, { accepted = true })
    test.equal(0, #old.calls, "old prompt acceptance is not delivered")
    test.equal("idle", controller:get_snapshot().submission, "new session status is untouched")
  end))
end)
