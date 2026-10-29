-- Wiring check: the synchronizer must work with the real 02B API client
-- contract (dot methods, raw SSE chunks, err-first callbacks) without any
-- OpenCode service.  Transport and scheduler are fakes.

local root = vim.fn.getcwd()
if vim.fn.filereadable(root .. "/lua/opencode/sync.lua") == 0 then
  root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h:h")
end
package.path = root .. "/?.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
local client_ok, client_module = pcall(require, "opencode.client")
local sync = require("opencode.sync")

local function sse(event_type, properties)
  return "data: " .. vim.json.encode({
    type = event_type,
    properties = properties,
  }) .. "\n\n"
end

local function fake_transport()
  local transport = { requests = {}, streams = {}, stream_cancel_count = 0 }

  function transport.request(opts, callback)
    local entry = { opts = opts, callback = callback, cancelled = false }
    transport.requests[#transport.requests + 1] = entry
    return function()
      entry.cancelled = true
    end
  end

  function transport.stream(opts, handlers)
    local entry = { opts = opts, handlers = handlers, cancelled = false }
    transport.streams[#transport.streams + 1] = entry
    return function()
      if not entry.cancelled then
        entry.cancelled = true
        transport.stream_cancel_count = transport.stream_cancel_count + 1
      end
    end
  end

  function transport:respond(index, response)
    self.requests[index].callback(nil, response)
  end

  function transport:headers(index, response)
    self.streams[index].handlers.on_headers(response)
  end

  function transport:chunk(index, chunk)
    self.streams[index].handlers.on_chunk(chunk)
  end

  function transport:done(index, err)
    self.streams[index].handlers.on_done(err)
  end

  return transport
end

local function fake_scheduler()
  local scheduler = { queue = {} }
  function scheduler:schedule(fn)
    self.queue[#self.queue + 1] = fn
    return function() end
  end
  function scheduler:run_next()
    local fn = table.remove(self.queue, 1)
    if fn then
      fn()
    end
  end
  return scheduler
end

local SNAPSHOT = {
  {
    info = { id = "msg_user", sessionID = "ses_a", role = "user" },
    parts = { { id = "prt", messageID = "msg_user", type = "text", text = "hi" } },
  },
}

test.describe("sync client wiring", function()
  if test.skip_if(
    not client_ok or type(client_module) ~= "table" or type(client_module.new) ~= "function",
    "syncs through the real stateless client with a fake transport",
    "opencode.client is not available"
  ) then
    return
  end

  test.it("syncs through the real stateless client with a fake transport", function()
    local transport = fake_transport()
    local scheduler = fake_scheduler()
    local batches = {}
    local errors = {}
    local client = client_module.new({
      url = "http://127.0.0.1:4199",
      transport = transport,
    })
    local syncer = assert(sync.new({
      client = client,
      session_id = "ses_a",
      location = { directory = "/tmp/opencode/project" },
      schedule = function(fn)
        return scheduler:schedule(fn)
      end,
      on_batch = function(batch)
        batches[#batches + 1] = batch
      end,
      on_error = function(err)
        errors[#errors + 1] = err
      end,
    }))

    assert(syncer:start())
    test.equal(1, #transport.streams)
    test.equal(1, #transport.requests)
    test.matches("/api/event$", transport.streams[1].opts.url)
    test.matches("/api/session/ses_a/message$", transport.requests[1].opts.url)
    test.equal("text/event-stream", transport.streams[1].opts.headers.Accept)

    transport:headers(1, { status = 200 })
    transport:chunk(1, sse("message.part.delta", { sessionID = "ses_a", delta = "A" }))
    test.equal(0, #batches)

    transport:respond(1, {
      status = 200,
      headers = { ["content-type"] = "application/json" },
      body = vim.json.encode({ data = SNAPSHOT, cursor = { next = nil } }),
    })
    test.equal(1, #batches)
    test.equal(1, batches[1].generation)
    test.equal(1, #batches[1].snapshot.messages)
    test.equal("A", batches[1].events[1].data.delta)

    transport:chunk(1, sse("message.part.delta", { sessionID = "ses_a", delta = "B" }))
    test.equal(2, #batches)
    test.equal("B", batches[2].events[1].data.delta)

    transport:done(1, { code = "read_error", message = "dropped" })
    test.equal(1, errors[1].generation)
    transport:chunk(1, sse("message.part.delta", { sessionID = "ses_a", delta = "late" }))
    test.equal(2, #batches)

    scheduler:run_next()
    test.equal(2, #transport.streams)
    test.equal(2, #transport.requests)
    transport:headers(2, { status = 200 })
    transport:chunk(2, sse("message.part.delta", { sessionID = "ses_a", delta = "C" }))
    test.equal(2, #batches)

    transport:respond(2, {
      status = 200,
      headers = { ["content-type"] = "application/json" },
      body = vim.json.encode({ data = SNAPSHOT, cursor = { next = nil } }),
    })
    test.equal(3, #batches)
    test.equal(2, batches[3].generation)
    test.equal("C", batches[3].events[1].data.delta)

    assert(syncer:stop())
    assert(syncer:stop())
    test.equal(1, transport.stream_cancel_count)
    transport:chunk(2, sse("message.part.delta", { sessionID = "ses_a", delta = "later" }))
    test.equal(3, #batches)
  end)
end)
