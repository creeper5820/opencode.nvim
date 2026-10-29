local root = vim.fn.getcwd()
if vim.fn.filereadable(root .. "/lua/opencode/sync.lua") == 0 then
  root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h:h")
end
package.path = root .. "/?.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
local sync = require("opencode.sync")

local function sse(event_type, data, id)
  local lines = {}
  if id ~= nil then
    lines[#lines + 1] = "id: " .. tostring(id)
  end
  if event_type ~= nil then
    lines[#lines + 1] = "event: " .. event_type
  end
  if type(data) == "string" then
    lines[#lines + 1] = "data: " .. data
  else
    lines[#lines + 1] = "data: " .. vim.json.encode(data)
  end
  return table.concat(lines, "\n") .. "\n\n"
end

local function v1(event_type, properties, id)
  return sse(nil, { type = event_type, properties = properties }, id)
end

local function v2(event_type, data, id)
  local payload = { type = event_type }
  for key, value in pairs(data or {}) do
    payload[key] = value
  end
  return sse(nil, payload, id)
end

local function new_client()
  local client = {
    streams = {},
    histories = {},
    stream_cancels = 0,
    history_cancels = 0,
  }

  function client.stream_events(opts, handlers)
    local stream = {
      opts = opts,
      handlers = handlers,
      cancelled = false,
    }
    client.streams[#client.streams + 1] = stream
    return function()
      if not stream.cancelled then
        stream.cancelled = true
        client.stream_cancels = client.stream_cancels + 1
      end
    end
  end

  function client.list_messages(session_id, callback)
    local call = {
      session_id = session_id,
      callback = callback,
      cancelled = false,
    }
    client.histories[#client.histories + 1] = call
    return function()
      if not call.cancelled then
        call.cancelled = true
        client.history_cancels = client.history_cancels + 1
      end
    end
  end

  return client
end

local function new_scheduler()
  local scheduler = { items = {}, delays = {} }

  function scheduler:schedule(fn, delay)
    local item = {
      fn = fn,
      delay = delay,
      cancelled = false,
    }
    self.items[#self.items + 1] = item
    self.delays[#self.delays + 1] = delay
    return function()
      item.cancelled = true
    end
  end

  function scheduler:run_next()
    while #self.items > 0 do
      local item = table.remove(self.items, 1)
      if not item.cancelled then
        item.fn()
        return item.delay
      end
    end
    return nil
  end

  function scheduler:pending()
    local count = 0
    for _, item in ipairs(self.items) do
      if not item.cancelled then
        count = count + 1
      end
    end
    return count
  end

  function scheduler:last_delay()
    return self.delays[#self.delays]
  end

  return scheduler
end

local function setup(options)
  options = options or {}
  local client = options.client or new_client()
  local scheduler = new_scheduler()
  local env = {
    client = client,
    scheduler = scheduler,
    batches = {},
    errors = {},
    connections = {},
  }
  env.syncer = assert(sync.new({
    client = client,
    session_id = options.session_id or "ses_a",
    location = options.location,
    types = options.types,
    backoff = { initial = 10, factor = 2, max = 40 },
    schedule = function(fn, delay)
      return scheduler:schedule(fn, delay)
    end,
    on_batch = function(batch)
      env.batches[#env.batches + 1] = batch
    end,
    on_error = function(err)
      env.errors[#env.errors + 1] = err
    end,
    on_connection = function(state, generation)
      env.connections[#env.connections + 1] = {
        state = state,
        generation = generation,
      }
    end,
  }))
  return env
end

local function start(env)
  local ok, generation = env.syncer:start()
  test.equal(true, ok, "start succeeds")
  test.equal("number", type(generation), "start returns a generation")
  test.equal(1, #env.client.streams, "one subscription")
  test.equal(1, #env.client.histories, "one history request")
  return generation
end

local function current_stream(env)
  return env.client.streams[#env.client.streams]
end

local function emit(stream, chunk)
  stream.handlers.on_chunk(chunk)
end

local function resolve_history(env, index, response)
  env.client.histories[index].callback(nil, response)
end

local function fail_history(env, index, err)
  env.client.histories[index].callback(err)
end

local function event_types(batch)
  local out = {}
  for _, event in ipairs(batch.events) do
    out[#out + 1] = event.type
  end
  return out
end

local SNAPSHOT = {
  {
    info = { id = "msg_user", sessionID = "ses_a", role = "user" },
    parts = {
      { id = "prt_user", messageID = "msg_user", type = "text", text = "hello" },
    },
  },
}

test.describe("opencode.sync", function()
  test.it("subscribes first, buffers gap events and releases snapshot plus ordered events", function()
    local env = setup({
      location = { directory = "/tmp/opencode/project" },
    })
    local generation = start(env)
    local stream = current_stream(env)

    stream.handlers.on_headers({ status = 200 })
    emit(stream, v1("server.connected", { version = "1.0" }))
    emit(stream, v1("message.part.delta", { sessionID = "ses_a", partID = "p1", delta = "A" }))
    emit(stream, v1("message.part.delta", { sessionID = "ses_a", partID = "p1", delta = "B" }))

    test.equal(0, #env.batches, "nothing is released before history")
    resolve_history(env, 1, SNAPSHOT)

    test.equal(1, #env.batches, "one snapshot batch")
    local batch = env.batches[1]
    test.equal(generation, batch.generation)
    test.equal("ses_a", batch.snapshot.session_id)
    test.equal("/tmp/opencode/project", batch.snapshot.location.directory)
    test.equal(1, #batch.snapshot.messages, "history array becomes snapshot.messages")
    test.equal(3, #batch.events, "all gap events are preserved")
    test.deep_equal({ "server.connected", "message.part.delta", "message.part.delta" }, event_types(batch))
    test.equal("A", batch.events[2].data.delta)
    test.equal("B", batch.events[3].data.delta)
    test.equal(nil, batch.events[2].sequence, "no fabricated sequence")

    emit(stream, v1("message.part.delta", { sessionID = "ses_a", partID = "p1", delta = "C" }))
    test.equal(2, #env.batches, "live event batch")
    test.equal(generation, env.batches[2].generation)
    test.equal(nil, env.batches[2].snapshot, "live batches have no snapshot")
    test.equal(1, #env.batches[2].events)
    test.equal("C", env.batches[2].events[1].data.delta)

    local states = {}
    for _, item in ipairs(env.connections) do
      states[#states + 1] = item.state
    end
    test.deep_equal({ "connected", "synced" }, states)
  end)

  test.it("keeps buffering across history failures and never releases a partial batch", function()
    local env = setup()
    local generation = start(env)
    local stream = current_stream(env)

    emit(stream, v1("message.part.delta", { sessionID = "ses_a", delta = "A" }))
    fail_history(env, 1, { code = "timeout", message = "history slow" })
    fail_history(env, 1, { code = "timeout", message = "history slow" })

    test.equal(0, #env.batches, "failed history releases nothing")
    test.equal(1, #env.errors, "duplicate history callback is ignored")
    test.equal("timeout", env.errors[1].code)
    test.equal("history", env.errors[1].phase)
    test.equal(generation, env.errors[1].generation)
    test.equal(1, env.scheduler:pending(), "history retry scheduled")
    test.equal(10, env.scheduler:last_delay(), "first backoff delay")

    emit(stream, v1("message.part.delta", { sessionID = "ses_a", delta = "B" }))
    test.equal(1, #env.client.histories, "retry has not run yet")

    env.scheduler:run_next()
    test.equal(2, #env.client.histories, "history retried after backoff")
    test.equal(0, #env.batches, "still buffering")

    resolve_history(env, 2, { messages = SNAPSHOT, extra = true })
    test.equal(1, #env.batches)
    local batch = env.batches[1]
    test.equal(generation, batch.generation)
    test.equal(true, batch.snapshot.extra, "extra history fields are preserved")
    test.deep_equal({ "message.part.delta", "message.part.delta" }, event_types(batch))
    test.equal("A", batch.events[1].data.delta)
    test.equal("B", batch.events[2].data.delta)
  end)

  test.it("rejects a malformed history response without releasing the buffer", function()
    local env = setup()
    start(env)
    local stream = current_stream(env)
    emit(stream, v1("message.part.delta", { sessionID = "ses_a", delta = "A" }))
    resolve_history(env, 1, { not_messages = true })

    test.equal(0, #env.batches)
    test.equal(1, #env.errors)
    test.equal("invalid_history_response", env.errors[1].code)
    test.equal(1, env.scheduler:pending(), "history retry scheduled")

    env.scheduler:run_next()
    resolve_history(env, 2, SNAPSHOT)
    test.equal(1, #env.batches)
    test.equal(1, #env.batches[1].events)
    test.equal("A", env.batches[1].events[1].data.delta)
  end)

  test.it("handles duplicate history callbacks at most once", function()
    local env = setup()
    start(env)
    local stream = current_stream(env)
    emit(stream, v1("message.part.delta", { sessionID = "ses_a", delta = "A" }))
    resolve_history(env, 1, SNAPSHOT)
    resolve_history(env, 1, {})
    test.equal(1, #env.batches)
    test.equal(1, #env.batches[1].events)
  end)

  test.it("duplicate start does not create another subscription", function()
    local env = setup()
    local generation = start(env)
    local ok, again = env.syncer:start()
    test.equal(true, ok)
    test.equal(generation, again)
    test.equal(1, #env.client.streams)
    test.equal(1, #env.client.histories)
  end)

  test.it("stop is idempotent and ignores late chunks and history callbacks", function()
    local env = setup()
    start(env)
    local stream = current_stream(env)
    local history = env.client.histories[1]
    emit(stream, v1("message.part.delta", { sessionID = "ses_a", delta = "A" }))

    test.equal(true, env.syncer:stop())
    test.equal(true, env.syncer:stop())
    test.equal(1, env.client.stream_cancels, "stream cancelled once")
    test.equal(1, env.client.history_cancels, "history cancelled once")
    test.equal(0, env.scheduler:pending())

    stream.handlers.on_chunk(v1("message.part.delta", { sessionID = "ses_a", delta = "late" }))
    history.callback(nil, SNAPSHOT)
    test.equal(0, #env.batches, "late callbacks are ignored")
    test.equal(0, #env.errors)

    local state = env.syncer:get_state()
    test.equal(true, state.stopped)
    test.equal("stopped", state.phase)
  end)

  test.it("stop cancels a scheduled reconnect and can start again", function()
    local env = setup()
    start(env)
    resolve_history(env, 1, SNAPSHOT)
    current_stream(env).handlers.on_done({ code = "read_error", message = "boom" })
    test.equal(1, env.scheduler:pending())

    env.syncer:stop()
    test.equal(0, env.scheduler:pending())
    env.scheduler:run_next()
    test.equal(1, #env.client.streams, "cancelled reconnect does not open a stream")

    local ok, generation = env.syncer:start()
    test.equal(true, ok)
    test.equal("number", type(generation))
    test.equal(2, #env.client.streams, "start after stop subscribes again")
  end)

  test.it("reconnects with a new generation, drops old chunks and refetches history", function()
    local env = setup()
    local first_generation = start(env)
    local first_stream = current_stream(env)
    resolve_history(env, 1, SNAPSHOT)
    test.equal(1, #env.batches)
    emit(first_stream, v1("message.part.delta", { sessionID = "ses_a", delta = "live" }))
    test.equal(2, #env.batches)

    first_stream.handlers.on_done({ code = "read_error", message = "disconnected" })
    test.equal("stream", env.errors[1].phase)
    test.equal("read_error", env.errors[1].code)
    test.equal(1, env.scheduler:pending())

    emit(first_stream, v1("message.part.delta", { sessionID = "ses_a", delta = "stale" }))
    test.equal(2, #env.batches, "late chunk from the old stream is ignored")

    env.scheduler:run_next()
    test.equal(2, #env.client.streams)
    test.equal(2, #env.client.histories)
    test.equal(first_generation + 1, env.syncer:get_state().generation)

    local second_stream = current_stream(env)
    emit(second_stream, v1("message.part.delta", { sessionID = "ses_a", delta = "new" }))
    test.equal(2, #env.batches, "new events stay buffered until history returns")

    resolve_history(env, 2, SNAPSHOT)
    test.equal(3, #env.batches)
    local batch = env.batches[3]
    test.equal(first_generation + 1, batch.generation)
    test.truthy(batch.snapshot, "new generation has a snapshot")
    test.equal(1, #batch.events)
    test.equal("new", batch.events[1].data.delta)
  end)

  test.it("ignores history that resolves after a reconnect", function()
    local env = setup()
    start(env)
    local first_stream = current_stream(env)
    first_stream.handlers.on_done({ code = "read_error", message = "disconnected" })
    env.scheduler:run_next()

    resolve_history(env, 1, SNAPSHOT)
    test.equal(0, #env.batches, "old generation history is ignored")

    resolve_history(env, 2, SNAPSHOT)
    test.equal(1, #env.batches)
    test.equal(2, env.batches[1].generation)
  end)

  test.it("applies exponential backoff and resets it after a live connection", function()
    local env = setup()
    start(env)
    resolve_history(env, 1, SNAPSHOT)

    current_stream(env).handlers.on_done({ code = "read_error", message = "one" })
    env.scheduler:run_next()
    current_stream(env).handlers.on_done({ code = "read_error", message = "two" })
    env.scheduler:run_next()
    current_stream(env).handlers.on_done({ code = "read_error", message = "three" })
    env.scheduler:run_next()
    current_stream(env).handlers.on_done({ code = "read_error", message = "four" })
    test.deep_equal({ 10, 20, 40, 40 }, env.scheduler.delays)

    env.scheduler:run_next()
    local stream = current_stream(env)
    emit(stream, v1("server.connected", {}))
    stream.handlers.on_done({ code = "read_error", message = "after live" })
    test.equal(10, env.scheduler.delays[#env.scheduler.delays], "backoff resets after a live chunk")
  end)

  test.it("reports a clean stream close and reconnects", function()
    local env = setup()
    start(env)
    resolve_history(env, 1, SNAPSHOT)
    current_stream(env).handlers.on_done(nil)
    test.equal(1, #env.errors)
    test.equal("stream_closed", env.errors[1].code)
    test.equal(1, env.scheduler:pending())
  end)

  test.it("filters other sessions and other locations while keeping global events", function()
    local project = "/tmp/opencode/project"
    local env = setup({ location = { directory = project } })
    start(env)
    resolve_history(env, 1, SNAPSHOT)
    local stream = current_stream(env)

    local chunk = table.concat({
      v1("message.part.delta", { sessionID = "ses_a", delta = "target" }),
      v1("message.part.delta", { sessionID = "ses_b", delta = "other-session" }),
      v1("message.part.delta", {
        sessionID = "ses_a",
        location = { directory = "/tmp/opencode/other" },
        delta = "other-location",
      }),
      v1("server.heartbeat", { location = { directory = "/tmp/opencode/other" } }),
      v1("server.heartbeat", {}),
      v1("message.part.delta", { sessionID = "ses_a", delta = "target-no-location" }),
      v1("session.created", { info = { id = "ses_b" } }),
      v1("session.created", { info = { id = "ses_a" } }),
      v1("message.part.delta", {
        sessionID = "ses_a",
        location = { directory = project .. "/" },
        delta = "target-trailing-slash",
      }),
      v1("server.tick", { project = { directory = "/tmp/opencode/other" } }),
      v1("server.tick", { project = { directory = project } }),
    }, "")

    emit(stream, chunk)
    test.equal(2, #env.batches, "snapshot batch plus one live batch")
    local events = env.batches[2].events
    test.equal(6, #events)
    test.deep_equal({
      "message.part.delta",
      "server.heartbeat",
      "message.part.delta",
      "session.created",
      "message.part.delta",
      "server.tick",
    }, event_types(env.batches[2]))
    test.equal("target", events[1].data.delta)
    test.equal("target-no-location", events[3].data.delta)
    test.equal("ses_a", events[4].data.info.id)
    test.equal("target-trailing-slash", events[5].data.delta)
    test.equal(project, events[6].data.project.directory)
  end)

  test.it("does not resync on the first server.connected received while live", function()
    local env = setup()
    start(env)
    resolve_history(env, 1, SNAPSHOT)
    local stream = current_stream(env)

    emit(stream, v1("server.connected", {}))
    test.equal(1, #env.client.histories, "first connect confirms the stream")
    test.equal(2, #env.batches)

    emit(stream, v1("server.connected", {}))
    test.equal(2, #env.client.histories, "second connect starts a resync generation")
    test.equal(1, #env.client.streams, "resync keeps the existing subscription")
    test.equal("syncing", env.syncer:get_state().phase)
  end)

  test.it("resyncs on a later server.connected and splits the in-flight chunk", function()
    local env = setup()
    start(env)
    local stream = current_stream(env)
    emit(stream, v1("server.connected", {}))
    emit(stream, v1("message.part.delta", { sessionID = "ses_a", delta = "A" }))
    resolve_history(env, 1, SNAPSHOT)
    test.equal(1, #env.batches)
    test.equal(2, #env.batches[1].events)

    emit(stream, table.concat({
      v1("message.part.delta", { sessionID = "ses_a", delta = "before-resync" }),
      v1("server.connected", {}),
      v1("message.part.delta", { sessionID = "ses_a", delta = "after-resync" }),
    }, ""))

    test.equal(2, #env.batches)
    test.equal(1, env.batches[2].generation, "old generation events flush first")
    test.equal(1, #env.batches[2].events)
    test.equal("before-resync", env.batches[2].events[1].data.delta)
    test.equal(2, #env.client.histories, "resync requests history")
    test.equal(2, env.syncer:get_state().buffered, "connected and delta are buffered")

    resolve_history(env, 2, SNAPSHOT)
    test.equal(3, #env.batches)
    local batch = env.batches[3]
    test.equal(2, batch.generation)
    test.equal(2, #batch.events)
    test.equal("server.connected", batch.events[1].type)
    test.equal("after-resync", batch.events[2].data.delta)
  end)

  test.it("starts a new generation when history fails and the stream then disconnects", function()
    local env = setup()
    start(env)
    local stream = current_stream(env)
    emit(stream, v1("message.part.delta", { sessionID = "ses_a", delta = "A" }))
    fail_history(env, 1, { code = "timeout", message = "slow" })
    test.equal(1, env.scheduler:pending())

    stream.handlers.on_done({ code = "read_error", message = "down" })
    test.equal(1, env.scheduler:pending(), "history retry replaced by reconnect timer")
    env.scheduler:run_next()
    test.equal(2, #env.client.streams)
    test.equal(2, #env.client.histories)
    test.equal(0, #env.batches, "old generation never released")

    resolve_history(env, 2, SNAPSHOT)
    test.equal(1, #env.batches)
    test.equal(2, env.batches[1].generation)
    test.equal(0, #env.batches[1].events)
  end)

  test.it("validates configuration before subscribing", function()
    local syncer = assert(sync.new({}))
    local ok, err = syncer:start()
    test.equal(nil, ok)
    test.equal("invalid_config", err.code)

    local client = new_client()
    syncer = assert(sync.new({ client = client }))
    ok, err = syncer:start()
    test.equal(nil, ok)
    test.equal("invalid_config", err.code)
    test.equal(0, #client.streams)

    syncer = assert(sync.new({ client = client, session_id = "ses_a", backoff = { initial = 0 } }))
    ok, err = syncer:start()
    test.equal(nil, ok)
    test.equal("invalid_config", err.code)
    test.equal(0, #client.streams)
  end)

  test.it("normalizes an empty history response and preserves the caller table", function()
    local env = setup()
    start(env)
    local response = { messages = SNAPSHOT }
    resolve_history(env, 1, response)
    test.equal(1, #env.batches)
    test.equal(1, #env.batches[1].snapshot.messages)

    local env2 = setup()
    start(env2)
    local second = { message = SNAPSHOT }
    resolve_history(env2, 1, second)
    test.equal(1, #env2.batches)
    test.equal(1, #env2.batches[1].snapshot.messages)
    test.equal(nil, second.messages, "history response was not mutated")

    local env3 = setup()
    start(env3)
    resolve_history(env3, 1, {})
    test.equal(1, #env3.batches)
    test.equal(0, #env3.batches[1].snapshot.messages, "empty history is a valid empty snapshot")

    local env4 = setup()
    start(env4)
    resolve_history(env4, 1, { data = SNAPSHOT, cursor = { next = "x" } })
    test.equal(1, #env4.batches)
    test.equal(1, #env4.batches[1].snapshot.messages, "02B { data = messages } responses are accepted")
    test.equal("x", env4.batches[1].snapshot.cursor.next)
  end)

  test.it("exposes sync.start convenience", function()
    local client = new_client()
    local syncer, err = sync.start({
      client = client,
      session_id = "ses_a",
      on_batch = function() end,
    })
    test.truthy(syncer)
    test.equal(nil, err)
    test.equal(1, #client.streams)
    test.equal(1, #client.histories)
    syncer:stop()
  end)
end)
