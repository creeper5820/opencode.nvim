-- 05A session controller unit tests: project pinning, restore/create,
-- prompt/command/submit routing, submission status and stale async results.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
local H = dofile(root .. "/tests/unit/session/helper.lua")
local session = require("opencode.session")
local session_store = require("opencode.session_store")

local function canonical(path)
  return session_store.canonicalize(path)
end

local function new_controller(opts)
  return H.controller(opts)
end

test.describe("session controller", function()
  test.it("pins the project root and coalesces concurrent ensure calls", H.case(function()
    local project = H.tempdir("project-a")
    local pinned = canonical(project)
    local create = H.capture()
    local client = H.fake_client({
      create_session = function(entry)
        create:take(entry)
      end,
    })
    local controller = session.new({
      client = client,
      store = H.fake_store(),
      cwd = function()
        return project
      end,
    })
    local first = H.collector()
    local second = H.collector()
    controller:ensure(first.callback)
    controller:ensure(second.callback)

    test.equal(1, client:count("create_session"), "only one session is created")
    test.truthy(create:pending(), "creation is still in flight")
    test.equal(pinned, create.entry.params.directory, "create uses the pinned root")

    -- The cwd changes while the first creation is in flight; the callback must
    -- not move the session to the new directory.
    project = H.tempdir("project-b")
    create:resolve(nil, { id = "ses_one", location = { directory = pinned } })

    test.equal(1, #first.calls, "first ensure callback")
    test.equal(1, #second.calls, "second ensure callback")
    test.falsy(first.calls[1].err, "first ensure succeeded")
    test.falsy(second.calls[1].err, "second ensure succeeded")
    local snapshot = first.calls[1].value
    test.equal("ses_one", snapshot.session.id)
    test.equal(pinned, snapshot.project.root, "root determined before cwd changed")

    local third = H.collector()
    controller:ensure(third.callback)
    test.equal(1, client:count("create_session"), "ready ensure does not create again")
    test.equal(1, #third.calls)
  end))

  test.it("restores a recorded session at the same location", H.case(function()
    local project = H.tempdir("restore")
    local record = { id = "ses_recorded", directory = project }
    local store = H.fake_store({ records = { [project] = record } })
    local client = H.fake_client({
      list_sessions = {
        result = {
          data = {
            { id = "ses_other", location = { directory = project } },
            { id = "ses_recorded", title = "Restored", location = { directory = project } },
          },
        },
      },
    })
    local controller = session.new({ client = client, store = store, config = { project = { root = project } } })
    local collected = H.collector()
    controller:ensure(collected.callback)

    test.equal(1, #collected.calls)
    test.falsy(collected.calls[1].err)
    test.equal("ses_recorded", collected.calls[1].value.session.id)
    test.equal("Restored", collected.calls[1].value.session.title)
    test.equal(0, client:count("create_session"), "valid record is not recreated")
    test.equal(1, client:count("list_sessions"), "record is verified against the service")
    test.equal(project, client:last("list_sessions").params.directory)
    test.equal(0, #store.set_calls, "existing record is not rewritten")
  end))

  test.it("creates a new session when the record is missing from the service", H.case(function()
    local project = H.tempdir("stale")
    local store = H.fake_store({ records = { [project] = { id = "ses_stale", directory = project } } })
    local client = H.fake_client({
      list_sessions = {
        result = {
          data = {
            { id = "ses_history_a", location = { directory = project } },
            { id = "ses_history_b", location = { directory = project } },
          },
        },
      },
      create_session = {
        result = { id = "ses_fresh", location = { directory = project } },
      },
    })
    local controller = session.new({ client = client, store = store, config = { project = { root = project } } })
    local collected = H.collector()
    controller:ensure(collected.callback)

    test.falsy(collected.calls[1].err)
    test.equal("ses_fresh", collected.calls[1].value.session.id)
    test.equal(1, client:count("create_session"), "new session created")
    test.equal(0, client:count("prompt"), "history sessions are never selected or prompted")
    test.equal("ses_fresh", store:record(project).id, "new record persisted")
  end))

  test.it("creates a new session when the recorded location no longer matches", H.case(function()
    local project = H.tempdir("location")
    local other = H.tempdir("other")
    local store = H.fake_store({ records = { [project] = { id = "ses_moved", directory = project } } })
    local client = H.fake_client({
      list_sessions = {
        result = { data = { { id = "ses_moved", location = { directory = other } } } },
      },
      create_session = {
        result = { id = "ses_local", location = { directory = project } },
      },
    })
    local controller = session.new({ client = client, store = store, config = { project = { root = project } } })
    local collected = H.collector()
    controller:ensure(collected.callback)

    test.falsy(collected.calls[1].err)
    test.equal("ses_local", collected.calls[1].value.session.id)
    test.equal(1, client:count("create_session"), "mismatched location is not restored")
  end))

  test.it("ignores records whose stored directory does not match the project", H.case(function()
    local project = H.tempdir("record-root")
    local other = H.tempdir("record-other")
    local store = H.fake_store({ records = { [project] = { id = "ses_wrong", directory = other } } })
    local client = H.fake_client({
      create_session = { result = { id = "ses_ok", location = { directory = project } } },
    })
    local controller = session.new({ client = client, store = store, config = { project = { root = project } } })
    local collected = H.collector()
    controller:ensure(collected.callback)

    test.falsy(collected.calls[1].err)
    test.equal("ses_ok", collected.calls[1].value.session.id)
    test.equal(0, client:count("list_sessions"), "invalid record is not validated against history")
    test.equal(1, client:count("create_session"))
  end))

  test.it("creates directly when no record exists and does not scan history", H.case(function()
    local project = H.tempdir("no-record")
    local client = H.fake_client({
      create_session = { result = { id = "ses_new", location = { directory = project } } },
    })
    local controller = session.new({ client = client, store = H.fake_store(), config = { project = { root = project } } })
    local collected = H.collector()
    controller:ensure(collected.callback)

    test.falsy(collected.calls[1].err)
    test.equal("ses_new", collected.calls[1].value.session.id)
    test.equal(0, client:count("list_sessions"))
    test.equal(1, client:count("create_session"))
  end))

  test.it("accepts a verified session without a location field", H.case(function()
    local project = H.tempdir("no-location")
    local store = H.fake_store({ records = { [project] = { id = "ses_recorded", directory = project } } })
    local client = H.fake_client({
      list_sessions = { result = { data = { { id = "ses_recorded" } } } },
    })
    local controller = session.new({ client = client, store = store, config = { project = { root = project } } })
    local collected = H.collector()
    controller:ensure(collected.callback)

    test.falsy(collected.calls[1].err)
    test.equal("ses_recorded", collected.calls[1].value.session.id)
    test.equal(0, client:count("create_session"))
  end))

  test.it("maps list errors to a unified error without creating", H.case(function()
    local project = H.tempdir("list-error")
    local store = H.fake_store({ records = { [project] = { id = "ses_recorded", directory = project } } })
    local list_error = { code = "list_failed", message = "cannot list" }
    local client = H.fake_client({
      list_sessions = function(entry)
        if list_error ~= nil then
          entry.callback(list_error)
        else
          entry.callback(nil, { data = { { id = "ses_recorded", location = { directory = project } } } })
        end
      end,
    })
    local controller = session.new({ client = client, store = store, config = { project = { root = project } } })
    local collected = H.collector()
    controller:ensure(collected.callback)

    test.equal(1, #collected.calls)
    test.deep_equal({ code = "list_failed", message = "cannot list" }, collected.calls[1].err)
    test.equal("failed", controller:get_snapshot().status)
    test.equal(0, client:count("create_session"), "verification failure does not duplicate the session")

    -- A later ensure retries instead of sticking to the failure.
    list_error = nil
    controller:ensure(H.collector().callback)
    test.equal("ready", controller:get_snapshot().status)
    test.equal(2, client:count("list_sessions"))
  end))

  test.it("rejects a created session at the wrong location", H.case(function()
    local project = H.tempdir("create-location")
    local other = H.tempdir("create-other")
    local store = H.fake_store()
    local client = H.fake_client({
      create_session = { result = { id = "ses_wrong", location = { directory = other } } },
    })
    local controller = session.new({ client = client, store = store, config = { project = { root = project } } })
    local collected = H.collector()
    controller:ensure(collected.callback)

    test.equal("session_location_mismatch", collected.calls[1].err.code)
    test.falsy(controller:get_snapshot().session)
    test.equal(0, #store.set_calls, "wrong session is not recorded")
  end))

  test.it("routes plain text to prompt and records acceptance", H.case(function()
    local controller, project = new_controller()
    controller:ensure()

    local collected = H.collector()
    controller:prompt("hello agent", collected.callback)

    local call = controller.client:last("prompt")
    test.truthy(call, "client.prompt called")
    test.equal("ses_auto", call.session_id)
    test.deep_equal({ text = "hello agent" }, call.params)
    test.equal(0, controller.client:count("command"))
    test.falsy(collected.calls[1].err)
    test.equal(true, collected.calls[1].value.accepted)
    test.equal("prompt", collected.calls[1].value.kind)
    test.equal("ses_auto", collected.calls[1].value.session_id)

    local snapshot = controller:get_snapshot()
    test.equal("accepted", snapshot.submission, "acceptance is visible")
    test.equal("prompt", snapshot.submission_kind)
    test.equal("ses_auto", snapshot.session.id)
    test.equal(canonical(project), snapshot.project.root)
  end))

  test.it("reports submitting then accepted before the Agent completes", H.case(function()
    local controller = new_controller()
    controller:ensure()
    local prompt = H.capture()
    controller.client = H.fake_client({
      prompt = function(entry)
        prompt:take(entry)
      end,
    })

    local collected = H.collector()
    controller:prompt("work", collected.callback)
    test.equal("submitting", controller:get_snapshot().submission)
    test.equal(0, #collected.calls, "callback waits for server acceptance only")

    prompt:resolve(nil, { accepted = true })
    test.equal("accepted", controller:get_snapshot().submission)
    test.equal(1, #collected.calls)
    test.falsy(collected.calls[1].err)
    test.equal(true, collected.calls[1].value.accepted)
  end))

  test.it("a newer validation failure is not overwritten by an older submission", H.case(function()
    local controller = new_controller()
    controller:ensure()
    local pending = H.capture()
    controller.client = H.fake_client({
      prompt = function(entry)
        pending:take(entry)
      end,
    })
    local old = H.collector()
    controller:prompt("valid request", old.callback)
    test.equal("submitting", controller:get_snapshot().submission)

    local invalid = H.collector()
    controller:prompt("  ", invalid.callback)
    test.equal("empty_input", invalid.calls[1].err.code)
    test.equal("failed", controller:get_snapshot().submission)

    pending:resolve(nil, { accepted = true })
    test.equal(1, #old.calls, "the old caller still gets its own acceptance")
    test.falsy(old.calls[1].err)
    test.equal("failed", controller:get_snapshot().submission, "newer failure state is preserved")
  end))

  test.it("maps prompt failures and never calls vim.notify", H.case(function()
    local controller = new_controller()
    controller:ensure()
    controller.client = H.fake_client({
      prompt = { error = { code = "bad_request", message = "invalid prompt", status = 400 } },
    })

    local notifications = {}
    local original = vim.notify
    vim.notify = function(...)
      notifications[#notifications + 1] = { ... }
    end
    local ok, err = pcall(function()
      local collected = H.collector()
      controller:prompt("nope", collected.callback)
      test.equal(1, #collected.calls)
      test.equal("bad_request", collected.calls[1].err.code)
      test.equal("invalid prompt", collected.calls[1].err.message)
      test.equal(400, collected.calls[1].err.status, "client error fields are preserved")

      local snapshot = controller:get_snapshot()
      test.equal("failed", snapshot.submission)
      test.equal("bad_request", snapshot.submission_error.code)
      test.equal("bad_request", snapshot.error.code)
    end)
    vim.notify = original
    if not ok then
      error(err, 0)
    end
    test.equal(0, #notifications, "session controller does not notify")
  end))

  test.it("routes commands through client.command", H.case(function()
    local controller = new_controller()
    controller:ensure()
    local collected = H.collector()
    controller:command("compact", "keep tests", collected.callback)

    local call = controller.client:last("command")
    test.equal("ses_auto", call.session_id)
    test.deep_equal({ name = "compact", text = "keep tests" }, call.params)
    test.equal(0, controller.client:count("prompt"))
    test.falsy(collected.calls[1].err)
    test.equal("command", collected.calls[1].value.kind)
    test.equal("accepted", controller:get_snapshot().submission)

    local empty = H.collector()
    controller:command("help", nil, empty.callback)
    test.deep_equal({ name = "help", text = "" }, controller.client:last("command").params)

    local structured = H.collector()
    controller:submit({
      kind = "command",
      name = "review",
      arguments = "all",
      attachments = { { uri = "file:///tmp/a" } },
      agents = { "reviewer" },
      skills = { "diff" },
    }, structured.callback)
    local params = controller.client:last("command").params
    test.equal("review", params.name)
    test.equal("all", params.text)
    test.deep_equal({ { uri = "file:///tmp/a" } }, params.files)
    test.deep_equal({ "reviewer" }, params.agents)
    test.deep_equal({ "diff" }, params.skills)
    test.falsy(structured.calls[1].err)
  end))

  test.it("interrupt auto-ensures and calls client.interrupt", H.case(function()
    local controller = new_controller()
    local collected = H.collector()
    controller:interrupt(collected.callback)

    test.equal(1, controller.client:count("create_session"), "session ensured first")
    local call = controller.client:last("interrupt")
    test.truthy(call, "client.interrupt called")
    test.equal("ses_auto", call.session_id)
    test.deep_equal({}, call.params)
    test.equal(1, #collected.calls)
    test.falsy(collected.calls[1].err)
    test.equal(true, collected.calls[1].value.interrupted)
    test.equal(false, collected.calls[1].value.idle)
    test.equal("interrupted", controller:get_snapshot().interrupt.status)
  end))

  test.it("interrupt forwards optional resume", H.case(function()
    local controller = new_controller()
    local collected = H.collector()
    controller:interrupt({ resume = true }, collected.callback)

    local call = controller.client:last("interrupt")
    test.equal("ses_auto", call.session_id)
    test.deep_equal({ resume = true }, call.params)
    test.falsy(collected.calls[1].err)
    test.equal(true, collected.calls[1].value.resume)
    test.equal(true, controller:get_snapshot().interrupt.resume)

    local no_resume = H.collector()
    controller:interrupt({}, no_resume.callback)
    test.deep_equal({}, controller.client:last("interrupt").params)
    test.equal(nil, no_resume.calls[1].value.resume)
  end))

  test.it("interrupt treats the idle no-op as success", H.case(function()
    local controller = new_controller()
    controller:ensure()
    controller.client = H.fake_client({
      interrupt = { result = { interrupted = false } },
    })

    local notifications = {}
    local original = vim.notify
    vim.notify = function(...)
      notifications[#notifications + 1] = { ... }
    end
    local ok, err = pcall(function()
      local collected = H.collector()
      controller:interrupt(collected.callback)
      test.equal(1, #collected.calls)
      test.falsy(collected.calls[1].err, "idle no-op is not an error")
      test.equal(false, collected.calls[1].value.interrupted)
      test.equal(true, collected.calls[1].value.idle)
      local snapshot = controller:get_snapshot()
      test.equal("noop", snapshot.interrupt.status)
      test.equal(false, snapshot.interrupt.interrupted)
      test.equal(nil, snapshot.interrupt.error)
      test.equal(nil, snapshot.error)
    end)
    vim.notify = original
    if not ok then
      error(err, 0)
    end
    test.equal(0, #notifications, "interrupt does not notify")
  end))

  test.it("maps interrupt errors without notifying", H.case(function()
    local controller = new_controller()
    controller:ensure()
    controller.client = H.fake_client({
      interrupt = { error = { code = "http_error", message = "interrupt failed", status = 500 } },
    })
    local collected = H.collector()
    controller:interrupt(collected.callback)

    test.equal(1, #collected.calls)
    test.equal("http_error", collected.calls[1].err.code)
    test.equal("interrupt failed", collected.calls[1].err.message)
    test.equal(500, collected.calls[1].err.status)
    local snapshot = controller:get_snapshot()
    test.equal("failed", snapshot.interrupt.status)
    test.equal("http_error", snapshot.interrupt.error.code)
    test.equal("http_error", snapshot.error.code)
  end))

  test.it("rejects invalid interrupt options before creating a session", H.case(function()
    local controller = new_controller()
    local collected = H.collector()
    controller:interrupt({ resume = "yes" }, collected.callback)

    test.equal("invalid_input", collected.calls[1].err.code)
    test.equal(0, controller.client:count("create_session"))
    test.equal(0, controller.client:count("interrupt"))
    test.equal("failed", controller:get_snapshot().interrupt.status)
  end))

  test.it("maps synchronous interrupt client errors", H.case(function()
    local controller = new_controller()
    controller:ensure()
    controller.client = {
      interrupt = function()
        return nil, { code = "transport_error", message = "connection refused" }
      end,
    }
    local collected = H.collector()
    controller:interrupt(collected.callback)

    test.equal(1, #collected.calls)
    test.deep_equal(
      { code = "transport_error", message = "connection refused" },
      collected.calls[1].err
    )
    test.equal("failed", controller:get_snapshot().interrupt.status)
  end))

  test.it("ignores an old interrupt result after the session changes", H.case(function()
    local create_count = 0
    local pending = H.capture()
    local client = H.fake_client({
      create_session = function(entry)
        create_count = create_count + 1
        entry.callback(nil, {
          id = create_count == 1 and "ses_old" or "ses_new",
          location = { directory = entry.params.directory },
        })
      end,
      interrupt = function(entry)
        pending:take(entry)
      end,
    })
    local controller = session.new({
      client = client,
      store = H.fake_store(),
      config = { project = { root = H.tempdir("interrupt-switch") } },
    })
    controller:ensure()
    local old = H.collector()
    controller:interrupt({ resume = true }, old.callback)
    test.equal("interrupting", controller:get_snapshot().interrupt.status)

    controller:reset()
    controller:ensure()
    test.equal("ses_new", controller:get_snapshot().session.id)

    pending:resolve(nil, { interrupted = true })
    test.equal(0, #old.calls, "old generation interrupt callback is dropped")
    test.equal("idle", controller:get_snapshot().interrupt.status)
    test.equal("ses_new", controller:get_snapshot().session.id)
  end))

  test.it("module-level interrupt delegates to the configured controller", H.case(function()
    local project = H.tempdir("module-project")
    session.setup({
      client = H.fake_client({
        create_session = { result = { id = "ses_module", location = { directory = project } } },
      }),
      store = H.fake_store(),
      config = { project = { root = project } },
    })
    local ensured = H.collector()
    session.ensure(ensured.callback)
    test.falsy(ensured.calls[1].err)

    local collected = H.collector()
    session.interrupt(collected.callback)
    test.falsy(collected.calls[1].err)
    test.equal(true, collected.calls[1].value.interrupted)
    test.equal("ses_module", session.get_snapshot().session.id)
    session.destroy()
  end))

  test.it("submit recognizes slash commands but leaves paths as prompts", H.case(function()
    local controller = new_controller()
    controller:ensure()

    controller:submit("/compact now", H.collector().callback)
    local command = controller.client:last("command")
    test.equal("compact", command.params.name)
    test.equal("now", command.params.text)
    test.equal(0, controller.client:count("prompt"))

    controller:submit("plain text", H.collector().callback)
    test.deep_equal({ text = "plain text" }, controller.client:last("prompt").params)

    controller:submit("/tmp/file.lua", H.collector().callback)
    test.deep_equal({ text = "/tmp/file.lua" }, controller.client:last("prompt").params)

    controller:submit({ text = "/help" }, H.collector().callback)
    test.equal("help", controller.client:last("command").params.name)
    test.equal(2, controller.client:count("command"))
  end))

  test.it("submit forwards structured prompt fields without flattening", H.case(function()
    local controller = new_controller()
    controller:ensure()
    local attachments = {
      { type = "file", path = "src/main.lua" },
      { type = "selection", text = "print(1)" },
    }
    local agent = { id = "build", name = "Build" }
    local payload = {
      kind = "prompt",
      text = "inspect this",
      attachments = attachments,
      agent = agent,
      model = { provider_id = "test", id = "model" },
    }
    local collected = H.collector()
    controller:submit(payload, collected.callback)

    local params = controller.client:last("prompt").params
    test.equal("inspect this", params.text)
    test.deep_equal(attachments, params.files, "attachments map to the client files field")
    test.deep_equal({ agent }, params.agents, "agent maps to the client agents field")
    test.equal(nil, params.kind, "routing kind is not sent to the API")
    test.equal(nil, params.attachments, "alias is normalized")
    test.equal(nil, params.agent, "alias is normalized")
    test.equal(nil, params.model, "unsupported fields are not forwarded")
    test.falsy(collected.calls[1].err)

    -- Mutating the caller's tables after submission must not change the
    -- request the client is still working with.
    attachments[1].path = "changed.lua"
    test.equal("src/main.lua", params.files[1].path)

    local direct = H.collector()
    controller:submit({
      kind = "agent",
      text = "direct fields",
      files = { { uri = "file:///tmp/a" } },
      agents = { "review" },
      skills = { "testing" },
      metadata = { source = "completion" },
    }, direct.callback)
    local direct_params = controller.client:last("prompt").params
    test.deep_equal({ { uri = "file:///tmp/a" } }, direct_params.files)
    test.deep_equal({ "review" }, direct_params.agents)
    test.deep_equal({ "testing" }, direct_params.skills)
    test.deep_equal({ source = "completion" }, direct_params.metadata)
    test.falsy(direct.calls[1].err)

    local attachment_only = H.collector()
    controller:submit({
      kind = "prompt",
      files = { { uri = "file:///tmp/only" } },
    }, attachment_only.callback)
    local only_params = controller.client:last("prompt").params
    test.equal(nil, only_params.text)
    test.deep_equal({ { uri = "file:///tmp/only" } }, only_params.files)
    test.falsy(attachment_only.calls[1].err)
  end))

  test.it("submit routes agent and skill kinds with their own fields", H.case(function()
    local controller = new_controller()
    controller:ensure()

    local agent_result = H.collector()
    controller:submit({ kind = "agent", text = "do it", name = "build" }, agent_result.callback)
    local agent_params = controller.client:last("prompt").params
    test.deep_equal({ "build" }, agent_params.agents)
    test.equal("do it", agent_params.text)
    test.falsy(agent_result.calls[1].err)

    local skill_result = H.collector()
    controller:submit({ kind = "skill", text = "use it", name = "sphinx" }, skill_result.callback)
    local skill_params = controller.client:last("prompt").params
    test.deep_equal({ "sphinx" }, skill_params.skills)
    test.falsy(skill_result.calls[1].err)

    local command_result = H.collector()
    controller:submit({ kind = "command", name = "init", arguments = "args" }, command_result.callback)
    test.deep_equal({ name = "init", text = "args" }, controller.client:last("command").params)
  end))

  test.it("maps synchronous client errors instead of hanging", H.case(function()
    local project = H.tempdir("sync-errors")
    local controller = session.new({
      client = {
        create_session = function()
          return nil, { code = "invalid_argument", message = "bad directory" }
        end,
      },
      store = H.fake_store(),
      config = { project = { root = project } },
    })
    local collected = H.collector()
    controller:ensure(collected.callback)
    test.equal(1, #collected.calls)
    test.deep_equal({ code = "invalid_argument", message = "bad directory" }, collected.calls[1].err)
    test.equal("failed", controller:get_snapshot().status)

    local prompt_controller = new_controller()
    prompt_controller:ensure()
    prompt_controller.client = {
      prompt = function()
        return nil, { code = "transport_error", message = "connection refused" }
      end,
    }
    local prompt_result = H.collector()
    prompt_controller:prompt("hello", prompt_result.callback)
    test.equal(1, #prompt_result.calls)
    test.deep_equal(
      { code = "transport_error", message = "connection refused" },
      prompt_result.calls[1].err
    )
    test.equal("failed", prompt_controller:get_snapshot().submission)
  end))

  test.it("rejects unsupported and empty input without calling the client", H.case(function()
    local controller = new_controller()
    controller:ensure()

    local empty = H.collector()
    controller:prompt("   ", empty.callback)
    test.equal("empty_input", empty.calls[1].err.code)
    test.equal(0, controller.client:count("prompt"))

    local unsupported = H.collector()
    controller:submit({ kind = "mystery", text = "x" }, unsupported.callback)
    test.equal("invalid_input", unsupported.calls[1].err.code)
    test.equal(0, controller.client:count("prompt"))
    test.equal(0, controller.client:count("command"))

    local bad_command = H.collector()
    controller:command("", "x", bad_command.callback)
    test.equal("invalid_input", bad_command.calls[1].err.code)
  end))

  test.it("prompt and command auto-ensure the session", H.case(function()
    local create = H.capture()
    local client = H.fake_client({
      create_session = function(entry)
        create:take(entry)
      end,
    })
    local controller = session.new({
      client = client,
      store = H.fake_store(),
      config = { project = { root = H.tempdir("auto") } },
    })
    local first = H.collector()
    local second = H.collector()
    controller:prompt("one", first.callback)
    controller:command("help", "", second.callback)

    test.equal(1, client:count("create_session"), "concurrent submissions share one ensure")
    create:resolve(nil, { id = "ses_auto", location = { directory = controller:get_snapshot().project.root } })

    test.equal(1, client:count("prompt"))
    test.equal(1, client:count("command"))
    test.falsy(first.calls[1].err)
    test.falsy(second.calls[1].err)
  end))

  test.it("ignores an old prompt result after the session changes", H.case(function()
    local create_count = 0
    local client = H.fake_client({
      create_session = function(entry)
        create_count = create_count + 1
        entry.callback(nil, {
          id = create_count == 1 and "ses_old" or "ses_new",
          location = { directory = entry.params.directory },
        })
      end,
    })
    local root_dir = H.tempdir("switch")
    local controller = session.new({
      client = client,
      store = H.fake_store(),
      config = { project = { root = root_dir } },
    })
    controller:ensure()

    local prompt = H.capture()
    controller.client.prompt = function(_, session_id, params, callback)
      prompt:take({ session_id = session_id, params = params, callback = callback })
    end
    local old = H.collector()
    controller:prompt("old request", old.callback)
    test.equal("submitting", controller:get_snapshot().submission)

    controller:reset()
    controller:ensure()
    test.equal("ses_new", controller:get_snapshot().session.id)

    prompt:resolve(nil, { accepted = true })
    test.equal(0, #old.calls, "old session result is ignored")
    test.equal("idle", controller:get_snapshot().submission)
    test.equal("ses_new", controller:get_snapshot().session.id)
  end))

  test.it("ignores an in-flight ensure after reset or destroy", H.case(function()
    local entries = {}
    local client = H.fake_client({
      create_session = function(entry)
        entries[#entries + 1] = entry
      end,
    })
    local controller = session.new({
      client = client,
      store = H.fake_store(),
      config = { project = { root = H.tempdir("stale-ensure") } },
    })
    local old = H.collector()
    controller:ensure(old.callback)
    test.equal(1, #entries)

    controller:reset()
    local fresh = H.collector()
    controller:ensure(fresh.callback)
    test.equal(2, #entries, "reset allows a new ensure")

    entries[2].callback(nil, {
      id = "ses_fresh",
      location = { directory = controller:get_snapshot().project.root },
    })
    test.equal(1, #fresh.calls)
    test.falsy(fresh.calls[1].err)
    test.equal("ses_fresh", controller:get_snapshot().session.id)

    entries[1].callback(nil, {
      id = "ses_old",
      location = { directory = controller:get_snapshot().project.root },
    })
    test.equal(0, #old.calls, "old ensure callback is ignored")

    controller:destroy()
    controller:ensure(function(err)
      test.equal("session_destroyed", err.code)
    end)
    test.equal(0, #old.calls)
  end))

  test.it("returns immutable snapshots", H.case(function()
    local controller = new_controller()
    controller:ensure()
    local first = controller:get_snapshot()
    first.session.id = "mutated"
    first.project.root = "/mutated"
    first.submission = "failed"

    local second = controller:get_snapshot()
    test.equal("ses_auto", second.session.id)
    test.equal(controller:get_snapshot().project.root, second.project.root)
    test.equal("idle", second.submission)
  end))

  test.it("recovers from an unreadable store and reports write failures", H.case(function()
    local project = H.tempdir("store-error")
    local client = H.fake_client({
      create_session = { result = { id = "ses_created", location = { directory = project } } },
    })
    local read_error = H.fake_store({ get_error = "invalid session store JSON" })
    local first = session.new({ client = client, store = read_error, config = { project = { root = project } } })
    local collected = H.collector()
    first:ensure(collected.callback)
    test.falsy(collected.calls[1].err)
    test.equal("ses_created", collected.calls[1].value.session.id)
    test.equal("ses_created", read_error:record(project).id, "new record replaces the corrupt one")
    test.falsy(first:get_snapshot().store_error, "successful write clears the store error")

    local write_error = H.fake_store({ set_error = "disk full" })
    local second = session.new({
      client = H.fake_client({
        create_session = { result = { id = "ses_second", location = { directory = project } } },
      }),
      store = write_error,
      config = { project = { root = project } },
    })
    local second_collected = H.collector()
    second:ensure(second_collected.callback)
    test.falsy(second_collected.calls[1].err, "session remains usable")
    test.equal("ses_second", second:get_snapshot().session.id)
    test.equal("session_store_failed", second:get_snapshot().store_error.code)
  end))

  test.it("parses command candidates consistently", function()
    test.deep_equal({ "compact", "now" }, { session.parse_command("/compact now") })
    test.deep_equal({ "help", "" }, { session.parse_command("  /help  ") })
    test.equal(nil, session.parse_command("/tmp/file.lua"))
    test.equal(nil, session.parse_command("plain"))
    test.equal(nil, session.parse_command(" /"))
  end)
end)
