local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
local support = dofile(root .. "/tests/unit/client/support.lua")
local client_module = require("opencode.client")

local function new_client(transport, opts)
  opts = opts or {}
  return client_module.new({
    url = opts.url or "http://127.0.0.1:4123",
    headers = opts.headers,
    timeout = opts.timeout,
    transport = transport,
  })
end

local function noop() end

test.describe("opencode client", function()
  test.it("info sends GET /api/info with auth and decodes JSON", function()
    local transport = support.transport()
    local client = new_client(transport, { headers = { Authorization = "Basic abc" } })
    local calls = {}

    local cancel = client.info(function(err, data, response)
      calls[#calls + 1] = { err = err, data = data, response = response }
    end)

    test.truthy(cancel, "cancel function")
    test.equal(1, #transport.requests)
    local request = transport.requests[1]
    test.equal("GET", request.opts.method)
    test.equal("http://127.0.0.1:4123/api/info", request.opts.url)
    test.equal("Basic abc", support.header(request.opts.headers, "authorization"))
    test.equal("application/json", support.header(request.opts.headers, "accept"))
    test.equal(nil, request.opts.body)

    transport:respond(1, {
      status = 200,
      status_text = "OK",
      headers = { ["content-type"] = "application/json" },
      body = '{"version":"2.0.31","pid":42}',
    })

    test.equal(1, #calls)
    test.equal(nil, calls[1].err)
    test.equal("2.0.31", calls[1].data.version)
    test.equal(42, calls[1].data.pid)
    test.equal(200, calls[1].response.status)
  end)

  test.it("supports colon syntax", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}
    client:info(function(err)
      calls[#calls + 1] = { err = err }
    end)
    test.equal(1, #transport.requests)
    transport:respond(1, { status = 200, body = "{}" })
    test.equal(1, #calls)
    test.equal(nil, calls[1].err)
  end)

  test.it("list_sessions sends directory and pagination filters", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}

    client.list_sessions({
      directory = "/tmp/opencode/project a/ü",
      limit = 25,
      order = "desc",
      search = "x+y",
      parentID = "ses/parent",
      project = "project id",
      subpath = "src",
      cursor = "a+b=c",
    }, function(err, data)
      calls[#calls + 1] = { err = err, data = data }
    end)

    test.equal(1, #transport.requests)
    local path, query = support.split_url(transport.requests[1].opts.url)
    test.equal("/api/session", path)
    test.equal("/tmp/opencode/project a/ü", query.directory)
    test.equal("25", query.limit)
    test.equal("desc", query.order)
    test.equal("x+y", query.search)
    test.equal("ses/parent", query.parentID)
    test.equal("project id", query.project)
    test.equal("src", query.subpath)
    test.equal("a+b=c", query.cursor)
    test.equal(nil, query["location[directory]"])
    test.matches("directory=%%2Ftmp%%2Fopencode%%2Fproject%%20a%%2F%%C3%%BC", transport.requests[1].opts.url)

    transport:respond(1, { status = 200, body = '{"data":[],"cursor":{"previous":null,"next":null}}' })
    test.equal(nil, calls[1].err)
    test.deep_equal({}, calls[1].data.data)
  end)

  test.it("list_sessions accepts location.directory", function()
    local transport = support.transport()
    local client = new_client(transport)
    client.list_sessions({ location = { directory = "/tmp/x" } }, noop)
    local _, query = support.split_url(transport.requests[1].opts.url)
    test.equal("/tmp/x", query.directory)
  end)

  test.it("create_session posts an explicit location body", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}

    client.create_session({
      directory = "/tmp/opencode/project",
      title = "Smoke",
      agent = "build",
      model = { providerID = "opencode", id = "big-pickle" },
      metadata = { source = "test" },
    }, function(err, data)
      calls[#calls + 1] = { err = err, data = data }
    end)

    local request = transport.requests[1]
    test.equal("POST", request.opts.method)
    test.equal("http://127.0.0.1:4123/api/session", request.opts.url)
    test.equal("application/json", support.header(request.opts.headers, "content-type"))

    local body = support.body(request)
    test.equal("/tmp/opencode/project", body.location.directory)
    test.equal("Smoke", body.title)
    test.equal("build", body.agent)
    test.equal("opencode", body.model.providerID)
    test.equal("big-pickle", body.model.id)
    test.equal("test", body.metadata.source)
    test.equal(nil, body.directory)

    transport:respond(1, {
      status = 200,
      body = '{"data":{"id":"ses_1","location":{"directory":"/tmp/opencode/project"}}}',
    })
    test.equal(nil, calls[1].err)
    test.equal("ses_1", calls[1].data.data.id)
  end)

  test.it("create_session preserves extra location fields", function()
    local transport = support.transport()
    local client = new_client(transport)
    client.create_session({ location = { directory = "/tmp/x", workspaceID = "wrk_1" } }, noop)
    local body = support.body(transport.requests[1])
    test.equal("/tmp/x", body.location.directory)
    test.equal("wrk_1", body.location.workspaceID)
  end)

  test.it("list_messages encodes the session id and query", function()
    local transport = support.transport()
    local client = new_client(transport)

    client.list_messages("ses/a b?ü%2F", {
      limit = 10,
      order = "asc",
      cursor = "cursor value",
      type = "user",
    }, noop)

    local path, query = support.split_url(transport.requests[1].opts.url)
    test.equal("/api/session/ses%2Fa%20b%3F%C3%BC%252F/message", path)
    test.equal("10", query.limit)
    test.equal("asc", query.order)
    test.equal("cursor value", query.cursor)
    test.equal("user", query.type)
  end)

  test.it("list_messages accepts callback as the second argument", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}
    client.list_messages("ses_1", function(err, data)
      calls[#calls + 1] = { err = err, data = data }
    end)
    test.equal("http://127.0.0.1:4123/api/session/ses_1/message", transport.requests[1].opts.url)
    transport:respond(1, { status = 200, body = '{"data":[],"cursor":{"previous":null,"next":null}}' })
    test.equal(nil, calls[1].err)
    test.deep_equal({}, calls[1].data.data)
  end)

  test.it("find_files sends the V2 fs find query and preserves the envelope", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}

    local cancel = client.find_files({
      location = { directory = "/tmp/opencode/project a/ü" },
      query = "al pha",
      type = "file",
      limit = 20,
    }, function(err, data)
      calls[#calls + 1] = { err = err, data = data }
    end)

    test.truthy(cancel, "cancel function")
    local path, query = support.split_url(transport.requests[1].opts.url)
    test.equal("/api/fs/find", path)
    test.equal("/tmp/opencode/project a/ü", query["location[directory]"])
    test.equal("al pha", query.query)
    test.equal("file", query.type)
    test.equal("20", query.limit)

    transport:respond(1, {
      status = 200,
      body = '{"location":{"directory":"/tmp/opencode/project a/ü"},"data":[{"path":"alpha.txt","type":"file"}]}',
    })
    test.equal(nil, calls[1].err)
    test.equal("/tmp/opencode/project a/ü", calls[1].data.location.directory)
    test.equal("alpha.txt", calls[1].data.data[1].path)
  end)

  test.it("find_files defaults the query and omits optional filters", function()
    local transport = support.transport()
    local client = new_client(transport)
    client.find_files({ location = { directory = "/tmp/project" } }, noop)
    local path, query = support.split_url(transport.requests[1].opts.url)
    test.equal("/api/fs/find", path)
    test.equal("/tmp/project", query["location[directory]"])
    test.equal("", query.query)
    test.equal(nil, query.type)
    test.equal(nil, query.limit)
  end)

  test.it("list_files sends path only when present", function()
    local transport = support.transport()
    local client = new_client(transport)

    client.list_files({ location = { directory = "/tmp/project" }, path = "src/lib" }, noop)
    local path, query = support.split_url(transport.requests[1].opts.url)
    test.equal("/api/fs/list", path)
    test.equal("/tmp/project", query["location[directory]"])
    test.equal("src/lib", query.path)

    client.list_files({ directory = "/tmp/other" }, noop)
    local second_path, second_query = support.split_url(transport.requests[2].opts.url)
    test.equal("/api/fs/list", second_path)
    test.equal("/tmp/other", second_query["location[directory]"])
    test.equal(nil, second_query.path)
  end)

  test.it("completion query routes preserve V2 envelopes", function()
    local transport = support.transport()
    local client = new_client(transport)
    local cases = {
      { name = "list_commands", path = "/api/command", body = '{"location":{"directory":"/tmp/project"},"data":[{"name":"init"}]}' },
      { name = "list_agents", path = "/api/agent", body = '{"location":{"directory":"/tmp/project"},"data":[{"id":"build"}]}' },
      { name = "list_skills", path = "/api/skill", body = '{"location":{"directory":"/tmp/project"},"data":[{"id":"opencode"}]}' },
    }

    for index, case in ipairs(cases) do
      local calls = {}
      local cancel = client[case.name](client, { location = { directory = "/tmp/project" } }, function(err, data)
        calls[#calls + 1] = { err = err, data = data }
      end)
      test.truthy(cancel, case.name .. " cancel")
      local path, query = support.split_url(transport.requests[index].opts.url)
      test.equal(case.path, path, case.name .. " path")
      test.equal("/tmp/project", query["location[directory]"], case.name .. " location")
      transport:respond(index, { status = 200, body = case.body })
      test.equal(nil, calls[1].err, case.name .. " error")
      test.equal("/tmp/project", calls[1].data.location.directory, case.name .. " envelope location")
      test.truthy(calls[1].data.data[1], case.name .. " envelope data")
    end
  end)

  test.it("completion query cancellation is forwarded", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}
    local cancel = client.list_agents({ location = { directory = "/tmp/project" } }, function()
      calls[#calls + 1] = true
    end)
    cancel()
    cancel()
    test.equal(1, transport.requests[1].cancel_count)
    transport:respond(1, { status = 200, body = '{"data":[]}' })
    test.equal(0, #calls)
  end)

  test.it("completion query arguments are validated before dispatch", function()
    local transport = support.transport()
    local client = new_client(transport)

    local cancel, err = client.find_files({}, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.find_files({ location = { directory = "/tmp/project" }, query = 42 }, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.find_files({ location = { directory = "/tmp/project" }, type = "other" }, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.find_files({ location = { directory = "/tmp/project" }, limit = 0 }, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.list_files({ location = { directory = "/tmp/project" }, path = 42 }, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.list_commands({}, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.list_agents(nil, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.list_skills({ location = { directory = "" } }, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    test.equal(0, #transport.requests)
  end)

  test.it("completion adapter resolves all new query methods", function()
    local api_mod = require("opencode.completion.sources.api")
    local transport = support.transport()
    local client = new_client(transport)
    local api = api_mod.new(client)
    local cases = {
      { name = "find_files", path = "/api/fs/find", body = '{"location":{"directory":"/tmp/project"},"data":[{"path":"a.txt"}]}' },
      { name = "list_files", path = "/api/fs/list", body = '{"location":{"directory":"/tmp/project"},"data":[{"path":"a.txt"}]}' },
      { name = "list_commands", path = "/api/command", body = '{"location":{"directory":"/tmp/project"},"data":[{"name":"init"}]}' },
      { name = "list_agents", path = "/api/agent", body = '{"location":{"directory":"/tmp/project"},"data":[{"id":"build"}]}' },
      { name = "list_skills", path = "/api/skill", body = '{"location":{"directory":"/tmp/project"},"data":[{"id":"opencode"}]}' },
    }

    for index, case in ipairs(cases) do
      test.truthy(api:has(case.name), case.name .. " available")
      local calls = {}
      local cancel = api:call(case.name, { location = { directory = "/tmp/project" } }, function(err, data)
        calls[#calls + 1] = { err = err, data = data }
      end)
      test.truthy(cancel, case.name .. " cancel")
      local path = support.split_url(transport.requests[index].opts.url)
      test.equal(case.path, path, case.name .. " path")
      transport:respond(index, { status = 200, body = case.body })
      test.equal(nil, calls[1].err, case.name .. " error")
      test.truthy(calls[1].data.data[1], case.name .. " data")
    end
  end)

  test.it("prompt and command use different endpoints and bodies", function()
    local transport = support.transport()
    local client = new_client(transport)

    client.prompt("ses_1", {
      text = "hello",
      files = { { uri = "file:///tmp/a", name = "a" } },
      metadata = { source = "test" },
    }, noop)
    client.command("ses_1", { name = "review", text = "a b" }, noop)

    local prompt_request = transport.requests[1]
    local command_request = transport.requests[2]
    test.equal("POST", prompt_request.opts.method)
    test.equal("http://127.0.0.1:4123/api/session/ses_1/prompt", prompt_request.opts.url)
    test.equal("POST", command_request.opts.method)
    test.equal("http://127.0.0.1:4123/api/session/ses_1/command", command_request.opts.url)

    local prompt_body = support.body(prompt_request)
    test.equal("hello", prompt_body.text)
    test.equal("file:///tmp/a", prompt_body.files[1].uri)
    test.equal("test", prompt_body.metadata.source)
    test.equal(nil, prompt_body.name)

    local command_body = support.body(command_request)
    test.equal("review", command_body.name)
    test.equal("a b", command_body.text)
    test.equal(nil, command_body.metadata)
  end)

  test.it("204 responses succeed with nil data", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}
    client.command("ses_1", { name = "review", text = "" }, function(err, data, response)
      calls[#calls + 1] = { err = err, data = data, response = response }
    end)
    transport:respond(1, { status = 204, status_text = "No Content", headers = {}, body = "" })
    test.equal(1, #calls)
    test.equal(nil, calls[1].err)
    test.equal(nil, calls[1].data)
    test.equal(204, calls[1].response.status)
  end)

  test.it("interrupt posts to the session interrupt endpoint without a body", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}

    local cancel = client.interrupt("ses_1", function(err, data)
      calls[#calls + 1] = { err = err, data = data }
    end)

    test.truthy(cancel, "cancel function")
    local request = transport.requests[1]
    test.equal("POST", request.opts.method)
    test.equal("http://127.0.0.1:4123/api/session/ses_1/interrupt", request.opts.url)
    test.equal(nil, request.opts.body)
    test.equal("application/json", support.header(request.opts.headers, "accept"))
    test.equal(nil, support.header(request.opts.headers, "content-type"))

    transport:respond(1, { status = 200, body = '{"interrupted":false}' })
    test.equal(nil, calls[1].err)
    test.equal(false, calls[1].data.interrupted)
  end)

  test.it("interrupt passes an optional resume query", function()
    local transport = support.transport()
    local client = new_client(transport)

    client.interrupt("ses_1", { resume = true }, noop)
    client.interrupt("ses_1", { resume = false }, noop)

    local first_path, first_query = support.split_url(transport.requests[1].opts.url)
    local second_path, second_query = support.split_url(transport.requests[2].opts.url)
    test.equal("/api/session/ses_1/interrupt", first_path)
    test.equal("/api/session/ses_1/interrupt", second_path)
    test.equal("true", first_query.resume)
    test.equal("false", second_query.resume)
    test.equal(nil, first_query.directory)
  end)

  test.it("interrupt validates arguments, maps errors and forwards cancellation", function()
    local transport = support.transport()
    local client = new_client(transport)

    local cancel, err = client.interrupt("", noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.interrupt("ses_1", "bad options", noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.interrupt("ses_1", { resume = "true" }, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)
    test.equal(0, #transport.requests)

    local calls = {}
    cancel = client.interrupt("ses_1", function()
      calls[#calls + 1] = true
    end)
    cancel()
    cancel()
    test.equal(1, transport.requests[1].cancel_count)
    transport:respond(1, { status = 200, body = '{"interrupted":false}' })
    test.equal(0, #calls)

    local failures = {}
    client.interrupt("ses_1", function(request_err)
      failures[#failures + 1] = request_err
    end)
    transport:respond(2, {
      status = 404,
      status_text = "Not Found",
      body = '{"_tag":"SessionNotFoundError","message":"Session not found"}',
    })
    test.equal("http_error", failures[1].code)
    test.equal(404, failures[1].status)
    test.equal("Session not found", failures[1].message)
  end)

  test.it("non-2xx responses become http_error with JSON details", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}
    client.command("ses_1", { name = "nope" }, function(err, data)
      calls[#calls + 1] = { err = err, data = data }
    end)

    local body = '{"_tag":"CommandNotFoundError","command":"nope","message":"Command not found: nope"}'
    transport:respond(1, { status = 404, status_text = "Not Found", headers = {}, body = body })

    local err = calls[1].err
    test.equal("http_error", err.code)
    test.equal(404, err.status)
    test.equal("Not Found", err.status_text)
    test.equal("CommandNotFoundError", err.server_code)
    test.equal("Command not found: nope", err.message)
    test.equal("nope", err.data.command)
    test.equal(body, err.body)
    test.equal(nil, calls[1].data)
  end)

  test.it("non-2xx responses with nested provider errors are mapped", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}
    client.prompt("ses_1", { text = "x" }, function(err)
      calls[#calls + 1] = err
    end)
    transport:respond(1, {
      status = 500,
      status_text = "Internal Server Error",
      body = '{"error":{"type":"provider.quota","message":"free usage limit reached"}}',
    })
    test.equal("http_error", calls[1].code)
    test.equal("provider.quota", calls[1].server_code)
    test.equal("free usage limit reached", calls[1].message)
  end)

  test.it("non-2xx responses with non-JSON bodies still map to http_error", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}
    client.info(function(err)
      calls[#calls + 1] = err
    end)
    transport:respond(1, { status = 502, status_text = "Bad Gateway", body = "upstream exploded" })
    test.equal("http_error", calls[1].code)
    test.equal(502, calls[1].status)
    test.equal("upstream exploded", calls[1].message)
    test.equal(nil, calls[1].data)
    test.truthy(calls[1].json_error)
  end)

  test.it("invalid JSON on a 2xx response becomes invalid_json", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}
    client.info(function(err, data)
      calls[#calls + 1] = { err = err, data = data }
    end)
    transport:respond(1, {
      status = 200,
      status_text = "OK",
      headers = { ["content-type"] = "application/json" },
      body = "{not json",
    })
    test.equal("invalid_json", calls[1].err.code)
    test.equal(200, calls[1].err.status)
    test.equal("{not json", calls[1].err.body)
    test.truthy(calls[1].err.cause)
    test.equal(nil, calls[1].data)
  end)

  test.it("empty and null success bodies return nil data", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}

    client.info(function(err, data)
      calls[#calls + 1] = { err = err, data = data }
    end)
    transport:respond(1, { status = 200, body = "null" })
    client.info(function(err, data)
      calls[#calls + 1] = { err = err, data = data }
    end)
    transport:respond(2, { status = 200, body = "   " })

    test.equal(nil, calls[1].err)
    test.equal(nil, calls[1].data)
    test.equal(nil, calls[2].err)
    test.equal(nil, calls[2].data)
  end)

  test.it("transport errors are mapped and preserve the transport code", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}
    client.info(function(err)
      calls[#calls + 1] = err
    end)
    transport:fail(1, { code = "connect_failed", message = "connection failed" })
    test.equal("connect_failed", calls[1].code)
    test.equal("connection failed", calls[1].message)
    test.equal("transport", calls[1].kind)
    test.equal("connect_failed", calls[1].cause.code)
  end)

  test.it("synchronous transport start errors are returned", function()
    local transport = support.transport()
    transport.request_start_error = { code = "invalid_request", message = "bad request" }
    local client = new_client(transport)
    local calls = {}
    local cancel, err = client.info(function()
      calls[#calls + 1] = true
    end)
    test.equal(nil, cancel)
    test.equal("invalid_request", err.code)
    test.equal("transport", err.kind)
    test.equal(0, #calls)
  end)

  test.it("cancel is forwarded and suppresses the callback", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}
    local cancel = client.info(function()
      calls[#calls + 1] = true
    end)

    cancel()
    cancel()
    test.equal(1, transport.requests[1].cancel_count)
    test.equal(1, transport.request_cancel_count)

    transport:respond(1, { status = 200, body = "{}" })
    test.equal(0, #calls)
  end)

  test.it("cancel after completion does not reach the transport", function()
    local transport = support.transport()
    local client = new_client(transport)
    local cancel = client.info(noop)
    transport:respond(1, { status = 200, body = "{}" })
    cancel()
    test.equal(0, transport.requests[1].cancel_count)
  end)

  test.it("callbacks run at most once", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}
    client.info(function()
      calls[#calls + 1] = true
    end)
    transport:complete(1, { status = 200, body = "{}" })
    test.equal(1, #calls)
  end)

  test.it("stream_events forwards raw chunks without merging", function()
    local transport = support.transport()
    local client = new_client(transport, { headers = { Authorization = "Bearer token" } })
    local events = {}
    local chunks = {}

    local cancel = client.stream_events({ types = { "session.text.delta", "session.step.started" } }, {
      on_headers = function(response)
        events[#events + 1] = "headers:" .. tostring(response.status)
      end,
      on_chunk = function(chunk)
        events[#events + 1] = "chunk"
        chunks[#chunks + 1] = chunk
      end,
      on_done = function(err)
        events[#events + 1] = "done:" .. tostring(err)
      end,
    })

    test.truthy(cancel, "cancel function")
    local request = transport.streams[1]
    local path, query = support.split_url(request.opts.url)
    test.equal("GET", request.opts.method)
    test.equal("/api/event", path)
    test.equal("session.text.delta,session.step.started", query.types)
    test.equal("text/event-stream", support.header(request.opts.headers, "accept"))
    test.equal("Bearer token", support.header(request.opts.headers, "authorization"))

    transport:stream_headers(1, { status = 200, status_text = "OK", headers = {} })
    transport:stream_chunk(1, "data: one\n\n")
    transport:stream_chunk(1, "data: two\n\n")
    transport:stream_done(1, nil)

    test.deep_equal({ "headers:200", "chunk", "chunk", "done:nil" }, events)
    test.deep_equal({ "data: one\n\n", "data: two\n\n" }, chunks)
  end)

  test.it("stream_events accepts a handlers-only table", function()
    local transport = support.transport()
    local client = new_client(transport)
    local chunks = {}
    client.stream_events({
      on_chunk = function(chunk)
        chunks[#chunks + 1] = chunk
      end,
    })
    test.equal(1, #transport.streams)
    transport:stream_headers(1, { status = 200 })
    transport:stream_chunk(1, "hello")
    test.deep_equal({ "hello" }, chunks)
  end)

  test.it("cancel is forwarded to stream transport", function()
    local transport = support.transport()
    local client = new_client(transport)
    local chunks = {}
    local cancel = client.stream_events({}, {
      on_chunk = function(chunk)
        chunks[#chunks + 1] = chunk
      end,
    })

    cancel()
    cancel()
    test.equal(1, transport.streams[1].cancel_count)
    test.equal(1, transport.stream_cancel_count)

    transport:stream_headers(1, { status = 200 })
    transport:stream_chunk(1, "late")
    test.deep_equal({}, chunks)
  end)

  test.it("non-2xx streams become one http_error from on_done", function()
    local transport = support.transport()
    local client = new_client(transport)
    local headers = 0
    local chunks = {}
    local calls = {}

    client.stream_events({}, {
      on_headers = function()
        headers = headers + 1
      end,
      on_chunk = function(chunk)
        chunks[#chunks + 1] = chunk
      end,
      on_done = function(err)
        calls[#calls + 1] = err
      end,
    })

    transport:stream_headers(1, { status = 401, status_text = "Unauthorized" })
    transport:stream_chunk(1, '{"error":{"type":"authentication_error",')
    transport:stream_chunk(1, '"message":"bad token"}}')
    transport:stream_done(1)

    test.equal(0, headers)
    test.deep_equal({}, chunks)
    test.equal(1, #calls)
    test.equal("http_error", calls[1].code)
    test.equal(401, calls[1].status)
    test.equal("authentication_error", calls[1].server_code)
    test.equal("bad token", calls[1].message)
    test.equal("authentication_error", calls[1].data.error.type)
  end)

  test.it("stream transport errors become API errors", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}
    client.stream_events({}, {
      on_done = function(err)
        calls[#calls + 1] = err
      end,
    })
    transport:stream_done(1, { code = "read_error", message = "stream closed" })
    test.equal("read_error", calls[1].code)
    test.equal("stream closed", calls[1].message)
    test.equal("transport", calls[1].kind)
  end)

  test.it("stream completion without headers is an invalid response", function()
    local transport = support.transport()
    local client = new_client(transport)
    local calls = {}
    client.stream_events({}, {
      on_done = function(err)
        calls[#calls + 1] = err
      end,
    })
    transport:stream_done(1, nil)
    test.equal("invalid_response", calls[1].code)
  end)

  test.it("synchronous stream start errors are returned", function()
    local transport = support.transport()
    transport.stream_start_error = { code = "connect_failed", message = "connection failed" }
    local client = new_client(transport)
    local cancel, err = client.stream_events({}, { on_chunk = noop })
    test.equal(nil, cancel)
    test.equal("connect_failed", err.code)
    test.equal("transport", err.kind)
  end)

  test.it("module-level methods delegate to a configured client", function()
    local transport = support.transport()
    local instance = new_client(transport)
    local original = client_module.from_config
    client_module.from_config = function()
      return instance
    end

    local ok, err = pcall(function()
      local calls = {}
      client_module.list_sessions(client_module, { directory = "/project/a" }, function(callback_err, data)
        calls[#calls + 1] = { err = callback_err, data = data }
      end)
      test.equal(1, #transport.requests)
      local _, query = support.split_url(transport.requests[1].opts.url)
      test.equal("/project/a", query.directory)

      transport:respond(1, { status = 200, body = '{"data":[]}' })
      test.equal(nil, calls[1].err)

      local interrupt_calls = {}
      client_module.interrupt(client_module, "ses_1", { resume = true }, function(callback_err, data)
        interrupt_calls[#interrupt_calls + 1] = { err = callback_err, data = data }
      end)
      test.equal(2, #transport.requests)
      local _, interrupt_query = support.split_url(transport.requests[2].opts.url)
      test.equal("true", interrupt_query.resume)
      transport:respond(2, { status = 200, body = '{"interrupted":false}' })
      test.equal(nil, interrupt_calls[1].err)
      test.equal(false, interrupt_calls[1].data.interrupted)

      local agent_calls = {}
      client_module.list_agents(client_module, { location = { directory = "/project/a" } }, function(callback_err, data)
        agent_calls[#agent_calls + 1] = { err = callback_err, data = data }
      end)
      test.equal(3, #transport.requests)
      local path, agent_query = support.split_url(transport.requests[3].opts.url)
      test.equal("/api/agent", path)
      test.equal("/project/a", agent_query["location[directory]"])
      transport:respond(3, { status = 200, body = '{"location":{"directory":"/project/a"},"data":[]}' })
      test.equal(nil, agent_calls[1].err)
      test.equal("/project/a", agent_calls[1].data.location.directory)

      local cancel, validation_err = client_module.list_sessions(client_module, {}, noop)
      test.equal(nil, cancel)
      test.equal("invalid_argument", validation_err.code)
    end)

    client_module.from_config = original
    if not ok then
      error(err, 0)
    end
  end)

  test.it("does not keep or choose a session or project", function()
    local transport = support.transport()
    local client = new_client(transport)

    client.list_sessions({ directory = "/project/a" }, noop)
    client.prompt("ses_1", { text = "hello" }, noop)
    client.list_sessions({ directory = "/project/b" }, noop)

    local _, first_query = support.split_url(transport.requests[1].opts.url)
    local _, second_query = support.split_url(transport.requests[3].opts.url)
    test.equal("/project/a", first_query.directory)
    test.equal("/project/b", second_query.directory)
    test.equal("http://127.0.0.1:4123/api/session/ses_1/prompt", transport.requests[2].opts.url)
    test.equal(nil, rawget(client, "session_id"))
    test.equal(nil, rawget(client, "directory"))
  end)

  test.it("validates required arguments before starting a request", function()
    local transport = support.transport()
    local client = new_client(transport)

    local cancel, err = client.info("not a function")
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.list_sessions({}, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.list_sessions(nil, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.create_session({}, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.list_messages("", noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.prompt("ses_1", {}, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.prompt("ses_1", { text = 42 }, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.command("ses_1", {}, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.command("ses_1", { name = "x", text = 42 }, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.stream_events({}, nil)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.stream_events({ types = { 1 } }, { on_chunk = noop })
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    cancel, err = client.list_sessions({ directory = "/x", limit = true }, noop)
    test.equal(nil, cancel)
    test.equal("invalid_argument", err.code)

    test.equal(0, #transport.requests)
    test.equal(0, #transport.streams)
  end)

  test.it("extra headers override defaults without duplicates", function()
    local transport = support.transport()
    local client = new_client(transport, {
      headers = {
        authorization = "Bearer token",
        accept = "application/vnd.opencode+json",
        ["content-type"] = "application/vnd.opencode+json",
      },
    })

    client.prompt("ses_1", { text = "hi" }, noop)
    local headers = transport.requests[1].opts.headers
    test.equal("Bearer token", support.header(headers, "Authorization"))
    test.equal("application/vnd.opencode+json", support.header(headers, "Accept"))
    test.equal("application/vnd.opencode+json", support.header(headers, "Content-Type"))

    local counts = {}
    for name in pairs(headers) do
      local key = name:lower()
      counts[key] = (counts[key] or 0) + 1
    end
    test.equal(1, counts.authorization)
    test.equal(1, counts.accept)
    test.equal(1, counts["content-type"])
  end)

  test.it("constructor rejects invalid configuration", function()
    test.error_matches("HTTPS", function()
      client_module.new({ url = "https://127.0.0.1:4123" })
    end)
    test.error_matches("missing a host", function()
      client_module.new({ url = "http://" })
    end)
    test.error_matches("query or fragment", function()
      client_module.new({ url = "http://127.0.0.1:4123?x=1" })
    end)
    test.error_matches("transport", function()
      client_module.new({ url = "http://127.0.0.1:4123", transport = {} })
    end)
    test.error_matches("timeout", function()
      client_module.new({ url = "http://127.0.0.1:4123", transport = support.transport(), timeout = 0 })
    end)
    test.error_matches("duplicate header", function()
      client_module.new({
        url = "http://127.0.0.1:4123",
        transport = support.transport(),
        headers = { Authorization = "a", authorization = "b" },
      })
    end)
    test.error_matches("CR/LF", function()
      client_module.new({
        url = "http://127.0.0.1:4123",
        transport = support.transport(),
        headers = { ["X-Test"] = "a\r\nb" },
      })
    end)
  end)
end)
