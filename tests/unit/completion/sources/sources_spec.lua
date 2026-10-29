-- Unit tests for OpenCode completion sources (task 07B).
--
-- All network access is faked.  Run through tests/run.sh so HOME, XDG_* and
-- temporary paths are isolated under /tmp/opencode.

local test = require("tests.support.test")
local sources = require("opencode.completion.sources")

local this = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(this, ":p:h")
local repo = vim.fn.fnamemodify(dir, ":h:h:h:h")
local tui = dofile(repo .. "/tests/fixtures/completion/tui_v2.lua")

local function response(location, data)
  return {
    location = { directory = location },
    data = data,
  }
end

local function make_client(handlers)
  handlers = handlers or {}
  local client = { calls = {} }

  local function invoke(name, params, callback)
    local entry = {
      name = name,
      params = params,
      callback = callback,
    }
    client.calls[#client.calls + 1] = entry
    local handler = handlers[name]
    if handler == nil then
      callback(nil, response(params.location and params.location.directory, {}))
    elseif type(handler) == "function" then
      return handler(entry, client)
    elseif handler.error ~= nil then
      callback(handler.error)
    else
      callback(nil, handler.result or response(params.location and params.location.directory, {}))
    end
  end

  function client.find_files(_, params, callback)
    return invoke("find_files", params, callback)
  end

  function client.list_files(_, params, callback)
    return invoke("list_files", params, callback)
  end

  function client.list_commands(_, params, callback)
    return invoke("list_commands", params, callback)
  end

  function client.list_agents(_, params, callback)
    return invoke("list_agents", params, callback)
  end

  function client.list_skills(_, params, callback)
    return invoke("list_skills", params, callback)
  end

  function client:count(name)
    local count = 0
    for _, entry in ipairs(self.calls) do
      if entry.name == name then
        count = count + 1
      end
    end
    return count
  end

  function client:last(name)
    for index = #self.calls, 1, -1 do
      if self.calls[index].name == name then
        return self.calls[index]
      end
    end
    return nil
  end

  return client
end

local function make_session()
  local session = { calls = {} }
  function session.submit(input, callback)
    session.calls[#session.calls + 1] = { name = "submit", input = input }
    if callback then
      callback(nil, { accepted = true })
    end
  end
  function session.prompt(text, callback)
    session.calls[#session.calls + 1] = { name = "prompt", text = text }
    if callback then
      callback(nil, { accepted = true })
    end
  end
  function session.command(name, arguments, callback)
    session.calls[#session.calls + 1] = { name = "command", command = name, arguments = arguments }
    if callback then
      callback(nil, { accepted = true })
    end
  end
  function session:last()
    return self.calls[#self.calls]
  end
  return session
end

local function run_query(source, before, opts)
  opts = opts or {}
  local result
  local request = {
    before_cursor = before,
    line = before,
    col = #before,
    lnum = opts.lnum or 1,
    context = opts.context,
  }
  local handle = source:query(request, function(value)
    result = value
  end)
  return result, handle
end

local function wait_for(predicate)
  return vim.wait(1000, predicate, 5)
end

local function find_candidate(items, kind, text)
  for _, item in ipairs(items or {}) do
    if item.kind == kind and item.text == text then
      return item
    end
  end
  return nil
end

test.describe("trigger semantics", function()
  test.it("command completion only opens at prompt index zero", function()
    local trigger = sources.parse_trigger("/he", 1)
    test.truthy(trigger)
    test.equal("command", trigger.type)
    test.equal(tui.triggers.command, trigger.trigger)
    test.equal(0, trigger.start_col)
    test.equal("he", trigger.query)
    test.equal(nil, sources.parse_trigger("hello /he", 1))
    test.equal(nil, sources.parse_trigger("/tmp/file", 1))
    test.equal(nil, sources.parse_trigger("/help ", 1))
    test.equal(nil, sources.parse_trigger("/he", 2))
  end)

  test.it("mentions require a token boundary and no whitespace", function()
    local trigger = sources.parse_trigger("hello @src/a b", 1)
    test.equal(nil, trigger)

    trigger = sources.parse_trigger("hello @src/a", 1)
    test.truthy(trigger)
    test.equal("mention", trigger.type)
    test.equal(tui.triggers.mention, trigger.trigger)
    test.equal("src/a", trigger.query)
    test.equal(6, trigger.start_col)

    test.equal(nil, sources.parse_trigger("mail@address", 1))
    test.equal(nil, sources.parse_trigger("@a b", 1))
    test.equal("mention", sources.parse_trigger("@a/b", 1).type)
  end)

  test.it("parses TUI line ranges and byte offsets", function()
    local trigger = sources.parse_trigger("héllo @src/ü.txt#12-14", 1)
    test.truthy(trigger)
    test.equal("src/ü.txt", trigger.query)
    test.equal(12, trigger.line_range.start)
    test.equal(14, trigger.line_range["end"])
    -- "héllo " is 7 bytes in UTF-8; @ is at byte index 8, zero-based 7.
    test.equal(7, trigger.start_col)

    trigger = sources.parse_trigger("@file#9", 1)
    test.equal("file", trigger.query)
    test.equal(9, trigger.line_range.start)
    test.equal(nil, trigger.line_range["end"])
  end)

  test.it("parses commands like the TUI", function()
    local name, arguments = sources.parse_command("/help me now")
    test.equal("help", name)
    test.equal("me now", arguments)
    name, arguments = sources.parse_command("/help")
    test.equal("help", name)
    test.equal("", arguments)
    test.equal(nil, sources.parse_command("hello"))
  end)
end)

test.describe("command source", function()
  test.it("queries the location and inserts a command", function()
    local client = make_client({
      list_commands = {
        result = response("/project/a", {
          { name = "help", description = "Show help" },
          { name = "review", description = "Review changes" },
        }),
      },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local result = run_query(source, "/hel")

    test.truthy(result)
    test.equal(true, result.ok)
    test.equal(1, #result.items)
    test.equal("/help ", result.items[1].text)
    test.equal("command", result.items[1].kind)
    test.equal("Show help", result.items[1].info)
    test.equal("command", result.items[1].metadata.kind)
    test.equal("help", result.items[1].metadata.name)
    test.equal(0, result.start_col)
    test.equal("/project/a", client:last("list_commands").params.location.directory)
  end)

  test.it("caches per location and invalidates by kind", function()
    local client = make_client({
      list_commands = {
        result = response("/project/a", {
          { name = "help", description = "Show help" },
        }),
      },
    })
    local current = "/project/a"
    local source = sources.new({
      client = client,
      location = function()
        return current
      end,
    })

    run_query(source, "/")
    run_query(source, "/h")
    test.equal(1, client:count("list_commands"))

    current = "/project/b"
    run_query(source, "/")
    test.equal(2, client:count("list_commands"))
    test.equal("/project/b", client:last("list_commands").params.location.directory)

    source:invalidate("command")
    run_query(source, "/")
    test.equal(3, client:count("list_commands"))
  end)

  test.it("does not treat a second slash or whitespace as a command", function()
    local client = make_client()
    local source = sources.new({ client = client, location = "/project/a" })
    local result = run_query(source, "/tmp/file")
    test.equal(true, result.ok)
    test.equal(0, #result.items)
    test.equal(0, client:count("list_commands"))

    result = run_query(source, "/help ")
    test.equal(true, result.ok)
    test.equal(0, #result.items)
    test.equal(0, client:count("list_commands"))
  end)

  test.it("routes commands through submit, never prompt", function()
    local client = make_client({
      list_commands = {
        result = response("/project/a", {
          { name = "help", description = "Show help" },
        }),
      },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local result = run_query(source, "/he")
    local candidate = result.items[1]

    local session = make_session()
    sources.submit(session, candidate, { text = "/help now" })
    local call = session:last()
    test.equal("submit", call.name)
    test.equal("command", call.input.kind)
    test.equal("help", call.input.name)
    test.equal("now", call.input.arguments)
    test.equal(1, #session.calls)

    local fallback = make_session()
    fallback.submit = nil
    sources.submit(fallback, candidate, { text = "/help now" })
    test.equal("command", fallback:last().name)
    test.equal("help", fallback:last().command)
    test.equal("now", fallback:last().arguments)

    local text_session = make_session()
    sources.submit_text(text_session, "/help now", { command_names = { help = true } })
    test.equal("submit", text_session:last().name)
    test.equal("command", text_session:last().input.kind)
    test.equal("now", text_session:last().input.arguments)
  end)

  test.it("does not mistake paths for commands on free-form submit", function()
    local session = make_session()
    sources.submit_text(session, "/tmp/file", { command_names = { help = true } })
    test.equal("prompt", session:last().name)
    test.equal("/tmp/file", session:last().text)

    sources.submit_text(session, "/unknown arg", { command_names = { help = true } })
    test.equal("prompt", session:last().name)
  end)
end)

test.describe("agent source", function()
  test.it("filters hidden and primary agents and inserts @id", function()
    local agents = {
      { id = "build", name = "Build", mode = "primary", hidden = false },
      { id = "reviewer", name = "Reviewer", mode = "subagent", description = "Reviews" },
      { id = "hidden", name = "Hidden", mode = "all", hidden = true },
      { id = "general", name = "General", mode = "all" },
      { id = "no-mode", name = "No mode" },
    }
    local client = make_client({
      list_agents = { result = response("/project/a", agents) },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local result = run_query(source, "hello @rev")

    test.equal(true, result.ok)
    test.equal(1, #result.items)
    local item = result.items[1]
    test.equal("@reviewer ", item.text)
    test.equal("agent", item.kind)
    test.equal("reviewer", item.metadata.id)
    test.equal("Reviews", item.info)
    test.equal(6, result.start_col)
    test.equal("@reviewer", item.metadata.mention_text)
  end)

  test.it("builds a structured agent attachment", function()
    local client = make_client({
      list_agents = {
        result = response("/project/a", {
          { id = "reviewer", name = "Reviewer", mode = "subagent", description = "Reviews" },
        }),
      },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local candidate = run_query(source, "@rev").items[1]
    local input, err = sources.build_submission(candidate, {
      text = "@reviewer please review",
      start_col = 0,
    })

    test.equal(nil, err)
    test.equal("agent", input.kind)
    test.equal("@reviewer please review", input.text)
    test.equal(1, #input.agents)
    test.equal("reviewer", input.agents[1].name)
    test.deep_equal({ start = 0, ["end"] = 9, text = "@reviewer" }, input.agents[1].mention)
  end)

  test.it("submits agent attachments through session.submit", function()
    local client = make_client({
      list_agents = {
        result = response("/project/a", {
          { id = "reviewer", name = "Reviewer", mode = "subagent" },
        }),
      },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local candidate = run_query(source, "@rev").items[1]
    local session = make_session()
    source = sources.new({ client = client, location = "/project/a", session = session })
    source:submit(candidate, { text = "hi @reviewer", start_col = 3 })

    local call = session:last()
    test.equal("submit", call.name)
    test.equal("agent", call.input.kind)
    test.equal("reviewer", call.input.agents[1].name)
    test.equal(3, call.input.agents[1].mention.start)
    test.equal(12, call.input.agents[1].mention["end"])
  end)
end)

test.describe("skill source", function()
  test.it("inserts skill ids and builds skill attachments", function()
    local client = make_client({
      list_skills = {
        result = response("/project/a", {
          { id = "skill-review", name = "Review", description = "Review code" },
          { id = "skill-test", name = "Test", description = "Run tests" },
        }),
      },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local result = run_query(source, "@sk")

    test.equal(true, result.ok)
    test.equal(2, #result.items)
    local item = find_candidate(result.items, "skill", "@skill-review ")
    test.truthy(item)
    test.equal("skill-review", item.metadata.id)
    test.equal("@skill-review", item.metadata.mention_text)

    local input, err = sources.build_submission(item, {
      text = "@skill-review check this",
      start_col = 0,
    })
    test.equal(nil, err)
    test.equal("skill", input.kind)
    test.equal(1, #input.skills)
    test.equal("skill-review", input.skills[1].id)
    test.deep_equal({ start = 0, ["end"] = 13, text = "@skill-review" }, input.skills[1].mention)
  end)

  test.it("submits skills through session.submit", function()
    local client = make_client({
      list_skills = {
        result = response("/project/a", {
          { id = "skill-review", name = "Review" },
        }),
      },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local candidate = run_query(source, "@skill").items[1]
    local session = make_session()
    sources.submit(session, candidate, { text = "@skill-review", start_col = 0 })
    test.equal("submit", session:last().name)
    test.equal("skill", session:last().input.kind)
    test.equal("skill-review", session:last().input.skills[1].id)
  end)
end)

test.describe("filesystem source", function()
  test.it("find passes the project location and preserves spaces and Unicode", function()
    local client = make_client({
      find_files = {
        result = response("/project/a", {
          { path = "src/a b/ü.txt", type = "file" },
          { path = "src/dir", type = "directory" },
        }),
      },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local result = run_query(source, "look @ü")

    test.equal(true, result.ok)
    test.equal(2, #result.items)
    local params = client:last("find_files").params
    test.equal("/project/a", params.location.directory)
    test.equal("ü", params.query)
    test.equal(tui.mention.file_find_limit, params.limit)

    local file = find_candidate(result.items, "file", "@src/a b/ü.txt ")
    test.truthy(file)
    test.equal("src/a b/ü.txt", file.metadata.path)
    test.equal("file:///project/a/src/a%20b/%C3%BC.txt", file.metadata.uri)
    test.equal("@src/a b/ü.txt", file.metadata.mention_text)
    test.equal(5, result.start_col)

    local directory = find_candidate(result.items, "file", "@src/dir/")
    test.truthy(directory)
    test.equal(true, directory.metadata.is_directory)
  end)

  test.it("appends TUI line ranges and builds a file attachment", function()
    local client = make_client({
      find_files = {
        result = response("/project/a", {
          { path = "src/a b/ü.txt", type = "file" },
        }),
      },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local result = run_query(source, "@src/ü.txt#12-14")
    local item = result.items[1]
    test.equal("@src/a b/ü.txt#12-14 ", item.text)
    test.equal(12, item.metadata.line_range.start)
    test.equal(14, item.metadata.line_range["end"])

    local input, err = sources.build_submission(item, {
      text = "hello @src/a b/ü.txt#12-14 ",
      start_col = 6,
    })
    test.equal(nil, err)
    test.equal("prompt", input.kind)
    test.equal(1, #input.files)
    test.equal("file:///project/a/src/a%20b/%C3%BC.txt", input.files[1].uri)
    test.equal("src/a b/ü.txt#12-14", input.files[1].name)
    test.deep_equal({
      start = 6,
      ["end"] = 6 + #"@src/a b/ü.txt#12-14",
      text = "@src/a b/ü.txt#12-14",
    }, input.files[1].mention)
  end)

  test.it("list uses the filesystem list route and requested path", function()
    local client = make_client({
      list_files = {
        result = response("/project/a", {
          { path = "src/one.lua", type = "file" },
        }),
      },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local result
    source:list("src", function(err, entries)
      result = { err = err, entries = entries }
    end)
    test.equal(nil, result.err)
    test.equal(1, #result.entries)
    local params = client:last("list_files").params
    test.equal("/project/a", params.location.directory)
    test.equal("src", params.path)
  end)

  test.it("optional file caching is per query and invalidatable", function()
    local client = make_client({
      find_files = {
        result = response("/project/a", {
          { path = "src/one.lua", type = "file" },
        }),
      },
    })
    local source = sources.new({
      client = client,
      location = "/project/a",
      file_cache_ttl = 5000,
    })
    run_query(source, "@one")
    run_query(source, "@one")
    test.equal(1, client:count("find_files"))

    source:invalidate("file")
    run_query(source, "@one")
    test.equal(2, client:count("find_files"))
  end)
end)

test.describe("combined source", function()
  test.it("queries skills, agents and files for @ and keeps metadata", function()
    local client = make_client({
      find_files = {
        result = response("/project/a", {
          { path = "src/a.lua", type = "file" },
        }),
      },
      list_agents = {
        result = response("/project/a", {
          { id = "reviewer", name = "Reviewer", mode = "subagent" },
        }),
      },
      list_skills = {
        result = response("/project/a", {
          { id = "skill-review", name = "Review" },
        }),
      },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local result = run_query(source, "@rev")

    test.equal(true, result.ok)
    test.equal(3, #result.items)
    test.equal("skill", result.items[1].kind)
    test.equal("agent", result.items[2].kind)
    test.equal("file", result.items[3].kind)
    test.equal("/project/a", client:last("find_files").params.location.directory)
    test.equal("/project/a", client:last("list_agents").params.location.directory)
    test.equal("/project/a", client:last("list_skills").params.location.directory)
  end)

  test.it("only queries commands for a command trigger", function()
    local client = make_client({
      list_commands = {
        result = response("/project/a", {
          { name = "help", description = "Show help" },
        }),
      },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local result = run_query(source, "/he")
    test.equal(true, result.ok)
    test.equal(1, #result.items)
    test.equal(0, client:count("find_files"))
    test.equal(0, client:count("list_agents"))
    test.equal(0, client:count("list_skills"))
  end)

  test.it("keeps successful sources when one source fails", function()
    local client = make_client({
      find_files = { error = { code = "boom", message = "find failed" } },
      list_agents = {
        result = response("/project/a", {
          { id = "reviewer", name = "Reviewer", mode = "subagent" },
        }),
      },
      list_skills = {
        result = response("/project/a", {
          { id = "skill-review", name = "Review" },
        }),
      },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local result = run_query(source, "@rev")
    test.equal(true, result.ok)
    test.equal(2, #result.items)
    test.equal("file", result.errors[1].kind)
    test.equal("boom", result.errors[1].error.code)
  end)

  test.it("reports an error when every source fails", function()
    local client = make_client({
      find_files = { error = { code = "file_failed", message = "no files" } },
      list_agents = { error = { code = "agent_failed", message = "no agents" } },
      list_skills = { error = { code = "skill_failed", message = "no skills" } },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local result = run_query(source, "@rev")
    test.equal(false, result.ok)
    test.truthy(result.error)
    test.equal("skill_failed", result.error.code)
    test.equal(3, #result.errors)
  end)

  test.it("reports a missing location without calling the client", function()
    local client = make_client()
    local source = sources.new({ client = client })
    local result = run_query(source, "@rev")
    test.equal(false, result.ok)
    test.equal("missing_location", result.error.code)
    test.equal(0, #client.calls)
  end)

  test.it("cancels in-flight source work and ignores late callbacks", function()
    local captured
    local cancelled = 0
    local client = make_client({
      find_files = function(entry)
        entry.callback(nil, response("/project/a", {}))
      end,
      list_skills = function(entry)
        entry.callback(nil, response("/project/a", {}))
      end,
      list_agents = function(entry)
        captured = entry
        return function()
          cancelled = cancelled + 1
        end
      end,
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local called = false
    local handle = source:query({
      before_cursor = "@rev",
      line = "@rev",
      col = 4,
      lnum = 1,
    }, function()
      called = true
    end)
    test.truthy(handle)
    handle()
    captured.callback(nil, response("/project/a", {
      { id = "reviewer", name = "Reviewer", mode = "subagent" },
    }))
    test.equal(false, called)
    test.equal(1, cancelled)
  end)

  test.it("clears cache when the client is replaced", function()
    local first = make_client({
      list_commands = {
        result = response("/project/a", {
          { name = "first", description = "First" },
        }),
      },
    })
    local second = make_client({
      list_commands = {
        result = response("/project/a", {
          { name = "second", description = "Second" },
        }),
      },
    })
    local source = sources.new({ client = first, location = "/project/a" })
    local result = run_query(source, "/")
    test.equal("first", result.items[1].metadata.name)
    source:set_client(second)
    result = run_query(source, "/")
    test.equal("second", result.items[1].metadata.name)
  end)

  test.it("reports unsupported candidate kinds explicitly", function()
    local input, err = sources.build_submission({
      kind = "reference",
      text = "@some-reference ",
      metadata = { type = "reference" },
    })
    test.equal(nil, input)
    test.equal("unsupported_kind", err.code)
  end)
end)

test.describe("adapter boundaries", function()
  test.it("accepts nested client method names", function()
    local client = {
      file = {
        find = function(_, params, callback)
          callback(nil, response(params.location.directory, {
            { path = "nested.lua", type = "file" },
          }))
        end,
      },
      agent = {
        list = function(_, params, callback)
          callback(nil, response(params.location.directory, {}))
        end,
      },
      skill = {
        list = function(_, params, callback)
          callback(nil, response(params.location.directory, {}))
        end,
      },
    }
    local source = sources.new({ client = client, location = "/project/a" })
    local result = run_query(source, "@nested")
    test.equal(true, result.ok)
    test.equal(1, #result.items)
    test.equal("@nested.lua ", result.items[1].text)
  end)

  test.it("reports a missing endpoint instead of constructing a request", function()
    local source = sources.new({ client = {}, location = "/project/a" })
    local result = run_query(source, "/he")
    test.equal(false, result.ok)
    test.equal("endpoint_unavailable", result.error.code)
  end)

  test.it("accepts two-argument fake client methods", function()
    local client = {
      find_files = function(params, callback)
        callback(nil, response(params.location.directory, {
          { path = "plain.lua", type = "file" },
        }))
      end,
      list_agents = function(params, callback)
        callback(nil, response(params.location.directory, {}))
      end,
      list_skills = function(params, callback)
        callback(nil, response(params.location.directory, {}))
      end,
    }
    local source = sources.new({ client = client, location = "/project/a" })
    local result = run_query(source, "@plain")
    test.equal(true, result.ok)
    test.equal(1, #result.items)
    test.equal("@plain.lua ", result.items[1].text)
  end)

  test.it("accepts controller-style session methods", function()
    local controller = {}
    function controller:submit(input, callback)
      self.received = input
      callback(nil, { accepted = true })
    end
    function controller:prompt(text, callback)
      self.prompt_text = text
      callback(nil, { accepted = true })
    end
    function controller:command(name, arguments, callback)
      self.command_name = name
      self.command_arguments = arguments
      callback(nil, { accepted = true })
    end

    sources.submit_text(controller, "hello")
    test.equal("hello", controller.prompt_text)

    sources.submit_text(controller, "/help now", { command_names = { help = true } })
    test.equal("help", controller.received.kind == "command" and controller.received.name or nil)
    test.equal("now", controller.received.arguments)
  end)
end)

test.describe("07A metadata contract", function()
  test.it("candidates reach the core with metadata intact", function()
    local core = require("opencode.completion.core")
    local client = make_client({
      find_files = {
        result = response("/project/a", {
          { path = "src/a.lua", type = "file" },
        }),
      },
      list_agents = {
        result = response("/project/a", {
          { id = "reviewer", name = "Reviewer", mode = "subagent" },
        }),
      },
      list_skills = {
        result = response("/project/a", {
          { id = "skill-review", name = "Review" },
        }),
      },
    })
    local source = sources.new({ client = client, location = "/project/a" })
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "@rev" })
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, 4 })

    test.truthy("attach", core.attach(bufnr, { source = source }))
    test.truthy("trigger", core.trigger(bufnr))
    local candidates = core.get_candidates(bufnr)
    test.equal(3, #candidates)
    for _, candidate in ipairs(candidates) do
      test.truthy(candidate.metadata)
      test.equal("opencode", candidate.metadata.source)
      test.equal(candidate.kind, candidate.metadata.type)
    end
    test.equal(0, core.get_state(bufnr).cached.start_col)

    core.detach(bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
