local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
local harness = require("tests.support.harness")
local client_module = require("opencode.client")

local unpack = table.unpack or unpack
local BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(value)
  local out = {}
  local index = 1
  while index <= #value do
    local first = value:byte(index) or 0
    local second = value:byte(index + 1)
    local third = value:byte(index + 2)

    out[#out + 1] = BASE64:sub(math.floor(first / 4) + 1, math.floor(first / 4) + 1)
    out[#out + 1] = BASE64:sub((first % 4) * 16 + math.floor((second or 0) / 16) + 1,
      (first % 4) * 16 + math.floor((second or 0) / 16) + 1)
    if second then
      out[#out + 1] = BASE64:sub((second % 16) * 4 + math.floor((third or 0) / 64) + 1,
        (second % 16) * 4 + math.floor((third or 0) / 64) + 1)
    else
      out[#out + 1] = "="
    end
    if third then
      out[#out + 1] = BASE64:sub(third % 64 + 1, third % 64 + 1)
    else
      out[#out + 1] = "="
    end
    index = index + 3
  end
  return table.concat(out)
end

local function auth_headers()
  local explicit = vim.env.OPENCODE_TEST_AUTH_HEADER
  if explicit and explicit ~= "" then
    return { Authorization = explicit }
  end
  local password = vim.env.OPENCODE_TEST_SERVER_PASSWORD
  if password and password ~= "" then
    local username = vim.env.OPENCODE_TEST_SERVER_USERNAME or "opencode"
    return { Authorization = "Basic " .. base64(username .. ":" .. password) }
  end
  return {}
end

local function acquire_service(h)
  local service, reason = harness.real_service()
  if service then
    return {
      url = service.url,
      headers = auth_headers(),
      external = true,
    }
  end

  local bin = vim.env.OPENCODE_TEST_BIN
  if not bin or bin == "" then
    return nil, reason
      or "set OPENCODE_TEST_SERVER_URL or OPENCODE_TEST_BIN to run the isolated real-service smoke"
  end

  local executable = vim.fn.exepath(bin)
  if executable == "" and vim.fn.executable(bin) == 1 then
    executable = vim.fn.fnamemodify(bin, ":p")
  end
  if executable == "" then
    return nil, ("OPENCODE_TEST_BIN %q is not executable"):format(bin)
  end

  local port = h:free_port()
  local password = ("client-smoke-%d-%d"):format(vim.uv.os_getpid(), vim.uv.hrtime())
  local process = h:start_process({
    executable,
    "serve",
    "--hostname",
    "127.0.0.1",
    "--port",
    tostring(port),
  }, {
    cwd = h.paths.project,
    env = h:build_env({
      OPENCODE_SERVER_PASSWORD = password,
      OPENCODE_DISABLE_AUTOUPDATE = "1",
    }),
  })

  return {
    url = ("http://127.0.0.1:%d"):format(port),
    headers = { Authorization = "Basic " .. base64("opencode:" .. password) },
    process = process,
    external = false,
  }
end

local function process_log(service)
  if not service.process then
    return ""
  end
  local lines = {}
  vim.list_extend(lines, service.process.stdout or {})
  vim.list_extend(lines, service.process.stderr or {})
  return table.concat(lines, "\n")
end

local function wait_ready(service, timeout)
  local client = client_module.new({
    url = service.url,
    headers = service.headers,
    timeout = 1000,
  })
  local deadline = vim.uv.now() + timeout
  local last_err

  while vim.uv.now() < deadline do
    if service.process and service.process.done then
      return nil, "OpenCode service exited\n" .. process_log(service)
    end

    local state = { done = false }
    local cancel = client.info(function(err, data)
      state.done = true
      state.err = err
      state.data = data
    end)
    if type(cancel) ~= "function" then
      state.done = true
      state.err = "request did not start"
    end

    vim.wait(1100, function()
      return state.done
    end, 10)
    if not state.done and type(cancel) == "function" then
      cancel()
    end
    if state.data then
      return state.data
    end
    last_err = state.err
    vim.wait(100)
  end

  return nil, ("service did not become ready: %s\n%s"):format(vim.inspect(last_err), process_log(service))
end

local function invoke(method, ...)
  local args = { ... }
  local state = { done = false }
  args[#args + 1] = function(err, data)
    state.done = true
    state.err = err
    state.data = data
  end

  local cancel, start_err = method(unpack(args))
  if type(cancel) ~= "function" then
    state.done = true
    state.err = start_err or { code = "request_not_started", message = "request did not start" }
  end
  if not vim.wait(20000, function()
    return state.done
  end, 20) then
    if type(cancel) == "function" then
      cancel()
    end
    error("client request timed out", 0)
  end
  if state.err then
    error("client request failed: " .. vim.inspect(state.err), 0)
  end
  return state.data
end

local h = harness.new()
vim.fn.writefile({ "client smoke file" }, h.paths.project .. "/client-smoke.txt")
local commands_dir = h.paths.project .. "/.opencode/commands"
vim.fn.mkdir(commands_dir, "p")
vim.fn.writefile({
  "---",
  "description: Client smoke command",
  "---",
  "Reply with: $ARGUMENTS",
}, commands_dir .. "/client-smoke.md")

local service, reason = acquire_service(h)
if not service then
  h:cleanup()
  test.skip("real OpenCode client smoke", reason)
  return
end

test.it("real OpenCode client smoke", function()
  local ok, failure = xpcall(function()
    local info, ready_err = wait_ready(service, 20000)
    if not info then
      error(ready_err, 0)
    end
    test.matches("^%d", info.version, "service version")

    require("opencode").setup({
      server = {
        url = service.url,
        headers = service.headers,
      },
    })
    local configured_info = invoke(client_module.info, client_module)
    test.equal(info.version, configured_info.version, "module-level configured client")

    local project = h.paths.project
    local configured_agents = invoke(client_module.list_agents, client_module, {
      location = { directory = project },
    })
    test.equal(project, configured_agents.location.directory, "module-level query client")
    local client = client_module.new({
      url = service.url,
      headers = service.headers,
      timeout = 15000,
    })

    local created = invoke(client.create_session, client, {
      directory = project,
      title = "client smoke",
    })
    test.truthy(created.data, "created session")
    local session_id = created.data.id
    test.matches("^ses_", session_id, "session id")
    test.equal(project, created.data.location.directory)

    local interrupted = invoke(client.interrupt, client, session_id, { resume = true })
    test.equal(false, interrupted.interrupted, "idle interrupt is a no-op")

    local sessions = invoke(client.list_sessions, client, { directory = project })
    local found = false
    for _, session in ipairs(sessions.data or {}) do
      if session.id == session_id then
        found = true
      end
    end
    test.truthy(found, "created session appears in list_sessions")

    local found_files = invoke(client.find_files, client, {
      location = { directory = project },
      query = "client-smoke",
      limit = 20,
    })
    test.equal(project, found_files.location.directory)
    local found_file = false
    for _, entry in ipairs(found_files.data or {}) do
      if entry.path == "client-smoke.txt" then
        found_file = true
      end
    end
    test.truthy(found_file, "find_files sees the smoke file")

    local listed_files = invoke(client.list_files, client, { location = { directory = project } })
    test.equal(project, listed_files.location.directory)
    local listed_file = false
    for _, entry in ipairs(listed_files.data or {}) do
      if entry.path == "client-smoke.txt" then
        listed_file = true
      end
    end
    test.truthy(listed_file, "list_files sees the smoke file")

    local commands = invoke(client.list_commands, client, { location = { directory = project } })
    test.equal(project, commands.location.directory)
    test.truthy(vim.islist(commands.data), "list_commands returns a list")

    local agents = invoke(client.list_agents, client, { location = { directory = project } })
    test.equal(project, agents.location.directory)
    test.truthy(vim.islist(agents.data), "list_agents returns a list")
    test.truthy(#agents.data > 0, "list_agents returns at least one agent")

    local skills = invoke(client.list_skills, client, { location = { directory = project } })
    test.equal(project, skills.location.directory)
    test.truthy(vim.islist(skills.data), "list_skills returns a list")

    local prompt_text = "client smoke prompt"
    local prompted = invoke(client.prompt, client, session_id, { text = prompt_text })
    test.equal(session_id, prompted.data.sessionID)
    test.equal("user", prompted.data.type)

    local messages = invoke(client.list_messages, client, session_id)
    local found_message = false
    for _, message in ipairs(messages.data or {}) do
      if message.type == "user" and message.text == prompt_text then
        found_message = true
      end
    end
    test.truthy(found_message, "prompt appears in list_messages")

    invoke(client.command, client, session_id, {
      name = "client-smoke",
      text = "command arguments",
    })
  end, debug.traceback)

  h:cleanup()
  if not ok then
    error(failure, 0)
  end
end)
