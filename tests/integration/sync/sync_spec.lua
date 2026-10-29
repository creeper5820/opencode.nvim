-- Integration coverage for the 05B sync stream/history race using a fake
-- stream and fake history API.  No OpenCode service or UI is involved.

local root = vim.fn.getcwd()
if vim.fn.filereadable(root .. "/lua/opencode/sync.lua") == 0 then
  root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h:h")
end
package.path = root .. "/?.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
local sync = require("opencode.sync")

local function sse(event_type, properties)
  return "data: " .. vim.json.encode({
    type = event_type,
    properties = properties,
  }) .. "\n\n"
end

local function new_client()
  local client = {
    streams = {},
    histories = {},
    stream_cancels = 0,
    history_cancels = 0,
  }

  function client.stream_events(_, handlers)
    local stream = { handlers = handlers, cancelled = false }
    client.streams[#client.streams + 1] = stream
    return function()
      if not stream.cancelled then
        stream.cancelled = true
        client.stream_cancels = client.stream_cancels + 1
      end
    end
  end

  function client.list_messages(session_id, callback)
    local call = { session_id = session_id, callback = callback, cancelled = false }
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

local SNAPSHOT = {
  {
    info = { id = "msg_user", sessionID = "ses_a", role = "user" },
    parts = { { id = "prt", messageID = "msg_user", type = "text", text = "hi" } },
  },
}

local function wait_for(condition, label)
  local ok = vim.wait(2000, condition, 5)
  test.truthy(ok, label)
end

local function latest_stream(client)
  return client.streams[#client.streams]
end

test.describe("sync integration", function()
  test.it("buffers the subscription/history gap, reconnects and cleans up with real timers", function()
    local client = new_client()
    local batches = {}
    local errors = {}
    local syncer = assert(sync.new({
      client = client,
      session_id = "ses_a",
      location = { directory = "/tmp/opencode/project" },
      backoff = { initial = 5, factor = 2, max = 20 },
      on_batch = function(batch)
        batches[#batches + 1] = batch
      end,
      on_error = function(err)
        errors[#errors + 1] = err
      end,
    }))

    local ok = syncer:start()
    test.equal(true, ok)
    test.equal(1, #client.streams)
    test.equal(1, #client.histories)

    local first = latest_stream(client)
    first.handlers.on_chunk(sse("server.connected", { version = "1" }))
    first.handlers.on_chunk(sse("message.part.delta", { sessionID = "ses_a", delta = "A" }))

    vim.defer_fn(function()
      client.histories[1].callback(nil, SNAPSHOT)
    end, 5)
    wait_for(function()
      return #batches == 1
    end, "snapshot batch")

    test.equal("A", batches[1].events[2].data.delta)
    test.equal(1, batches[1].generation)

    first.handlers.on_chunk(sse("message.part.delta", { sessionID = "ses_a", delta = "B" }))
    test.equal(2, #batches)
    test.equal("B", batches[2].events[1].data.delta)

    first.handlers.on_done({ code = "read_error", message = "dropped" })
    wait_for(function()
      return #client.streams == 2
    end, "reconnect stream")
    test.equal("stream", errors[1].phase)

    first.handlers.on_chunk(sse("message.part.delta", { sessionID = "ses_a", delta = "stale" }))
    test.equal(2, #batches, "late chunk from the old stream is ignored")

    local second = latest_stream(client)
    second.handlers.on_chunk(sse("message.part.delta", { sessionID = "ses_a", delta = "C" }))
    test.equal(2, #batches, "new events wait for the new history snapshot")

    vim.defer_fn(function()
      client.histories[2].callback(nil, SNAPSHOT)
    end, 5)
    wait_for(function()
      return #batches == 3
    end, "new generation batch")
    test.equal(2, batches[3].generation)
    test.equal("C", batches[3].events[1].data.delta)

    test.equal(true, syncer:stop())
    test.equal(true, syncer:stop())
    test.equal(2, client.stream_cancels, "first reconnect closure and stopped live stream")
    test.equal(0, client.history_cancels, "completed histories need no cancel")

    second.handlers.on_chunk(sse("message.part.delta", { sessionID = "ses_a", delta = "later" }))
    vim.wait(40)
    test.equal(3, #batches, "stopped synchronizer ignores late chunks")
    test.equal(2, #client.streams, "stopped synchronizer schedules no reconnect")
  end)

  test.it("retries a failed history with the real scheduler and releases one complete batch", function()
    local client = new_client()
    local batches = {}
    local errors = {}
    local syncer = assert(sync.new({
      client = client,
      session_id = "ses_a",
      backoff = { initial = 5, factor = 2, max = 20 },
      on_batch = function(batch)
        batches[#batches + 1] = batch
      end,
      on_error = function(err)
        errors[#errors + 1] = err
      end,
    }))
    assert(syncer:start())
    local stream = latest_stream(client)
    stream.handlers.on_chunk(sse("message.part.delta", { sessionID = "ses_a", delta = "A" }))
    client.histories[1].callback({ code = "timeout", message = "slow" }, nil)
    test.equal(0, #batches)

    wait_for(function()
      return #client.histories == 2
    end, "history retry")
    stream.handlers.on_chunk(sse("message.part.delta", { sessionID = "ses_a", delta = "B" }))
    client.histories[2].callback(nil, SNAPSHOT)
    test.equal(1, #batches)
    test.equal(2, #batches[1].events, "buffer survives the failed history attempt")
    test.equal("A", batches[1].events[1].data.delta)
    test.equal("B", batches[1].events[2].data.delta)
    test.equal(1, errors[1].generation)
    syncer:stop()
  end)
end)
