-- Isolated real-OpenCode child. The parent starts a test-owned `opencode serve`
-- with its own XDG/HOME, random port and test password, then passes the URL and
-- Authorization header through the environment.

local repo = assert(vim.env.OPENCODE_NVIM_TEST_REPO, "OPENCODE_NVIM_TEST_REPO is required")
package.path = repo .. "/?.lua;" .. repo .. "/?/init.lua;" .. package.path

local function check(condition, message)
  if not condition then
    error(message, 2)
  end
end

local function wait_until(label, timeout, predicate)
  local ok = vim.wait(timeout or 15000, predicate, 30)
  check(ok, "timed out: " .. label)
end

local url = assert(vim.env.OPENCODE_TEST_SERVICE_URL, "OPENCODE_TEST_SERVICE_URL is required")
local auth = assert(vim.env.OPENCODE_TEST_AUTH_HEADER, "OPENCODE_TEST_AUTH_HEADER is required")
local root = vim.fn.getcwd()

local opencode = require("opencode")
opencode.setup({
  server = { url = url, headers = { Authorization = auth } },
  project = { root = root },
  tools = { enabled = false },
  sidebar = { width = 48, input_height = 8 },
})
opencode.open()

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function has_user_text(blocks, text)
  for _, block in ipairs(blocks or {}) do
    if block.type == "user" and type(block.content) == "string" and block.content:find(text, 1, true) then
      return true
    end
  end
  return false
end

local function has_event_status(blocks)
  for _, block in ipairs(blocks or {}) do
    local metadata = type(block.metadata) == "table" and block.metadata or {}
    if block.type == "status" and (metadata.kind == "error" or metadata.kind == "retry") then
      return true
    end
  end
  return false
end

local summary = {}
local ok, err = xpcall(function()
  wait_until("real session", 20000, function()
    local state = opencode.get_state()
    return state.session_id ~= nil and state.session ~= nil and state.session.session ~= nil
  end)
  wait_until("real sync", 20000, function()
    local state = opencode.get_state()
    return state.sync ~= nil and state.sync.connected == true
  end)

  local state = opencode.get_state()
  check(state.session.session.id ~= nil, "session id missing")
  check(state.ui.open == true, "sidebar did not open")
  check(state.completion.attached == true, "completion not attached")
  check(state.keybindings ~= nil and state.keybindings.input == true, "keybindings not attached")

  -- A fresh session is idle: the default Normal-mode Escape must be a readable
  -- no-op, not an error notification.
  require("opencode.ui").focus_input()
  feed("<Esc>")
  wait_until("idle interrupt", 10000, function()
    return opencode.get_state().last_interrupt ~= nil
  end)
  local idle = opencode.get_state().last_interrupt
  check(idle.err == nil, "idle interrupt returned an error: " .. vim.inspect(idle.err))
  check(idle.result ~= nil and idle.result.interrupted == false, "fresh session should be idle")
  check(idle.result.idle == true, "idle no-op should report idle=true")
  summary.idle = true

  -- Regular prompt acceptance, draft clearing, sync/render path.
  local input = opencode.get_state().ui.buffers.input
  vim.api.nvim_buf_set_lines(input, 0, -1, false, { "hello from the isolated e2e" })
  check(opencode.submit() == true, "prompt submit did not start")
  wait_until("prompt accepted and draft cleared", 20000, function()
    local current = opencode.get_state()
    return current.session.session ~= nil
      and current.session.submission == "accepted"
      and require("opencode.ui").get_draft() == ""
  end)
  summary.accepted = true
  -- The isolated service has no provider credentials. A real event batch must
  -- still reach the block model: either the user message or a session.step
  -- failure status block is acceptable proof of the SSE -> state -> renderer
  -- path without depending on model access.
  local synced_ok = vim.wait(20000, function()
    local blocks = opencode.get_state().blocks
    return has_user_text(blocks, "hello from the isolated e2e") or has_event_status(blocks)
  end, 50)
  if not synced_ok then
    local current = opencode.get_state()
    error("timed out: event batch applied; blocks=" .. vim.inspect(current.blocks)
      .. " status=" .. vim.inspect(current.status)
      .. " session=" .. vim.inspect(current.session)
      .. " sync_error=" .. vim.inspect(current.last_sync_error))
  end
  summary.events_applied = true
  summary.user_message = has_user_text(opencode.get_state().blocks, "hello from the isolated e2e")

  -- Best-effort actual interrupt: only assert when the isolated service
  -- reports an active stream. A model-less isolated server may finish or fail
  -- immediately, in which case the idle no-op above is the meaningful check.
  local started = false
  vim.api.nvim_buf_set_lines(input, 0, -1, false, { "second prompt for interrupt" })
  opencode.submit()
  local saw_execution = vim.wait(5000, function()
    local current = opencode.get_state()
    local execution = current.status and current.status.execution
    return execution == "streaming" or execution == "tool_running" or execution == "retrying"
  end, 50)
  if saw_execution then
    local done = false
    local interrupt_error
    local interrupt_result
    opencode.interrupt(function(interrupt_err, result)
      interrupt_error = interrupt_err
      interrupt_result = result
      done = true
    end)
    vim.wait(10000, function()
      return done
    end, 50)
    check(interrupt_error == nil, "actual interrupt failed: " .. vim.inspect(interrupt_error))
    check(interrupt_result ~= nil, "actual interrupt returned no result")
    summary.actual_interrupt = interrupt_result.interrupted == true and "interrupted" or "idle"
    started = true
  end
  if not started then
    summary.actual_interrupt = "no-active-execution"
  end

  summary.execution = opencode.get_state().status and opencode.get_state().status.execution or "unknown"
  io.stdout:write("ok real " .. vim.json.encode(summary) .. "\n")
  io.stdout:flush()
end, debug.traceback)

if not ok then
  io.stderr:write(tostring(err) .. "\n")
  pcall(opencode.stop)
  vim.cmd("cquit 1")
end
pcall(opencode.stop)
vim.cmd("qall!")
