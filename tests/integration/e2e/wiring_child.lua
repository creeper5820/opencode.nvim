-- Isolated child Neovim script for the wiring e2e test. Everything runs in
-- the temporary XDG/project environment created by tests/support/harness.

local repo = assert(vim.env.OPENCODE_NVIM_TEST_REPO, "OPENCODE_NVIM_TEST_REPO is required")
package.path = repo .. "/?.lua;" .. repo .. "/?/init.lua;" .. package.path

local function check(condition, message)
  if not condition then
    error(message, 2)
  end
end

local function wait_until(label, timeout, predicate)
  local ok = vim.wait(timeout or 5000, predicate, 20)
  check(ok, "timed out: " .. label)
end

local function request_count(server, kind)
  return server[kind] or 0
end

local function has_user_text(blocks, text)
  for _, block in ipairs(blocks or {}) do
    if block.type == "user" and type(block.content) == "string" and block.content:find(text, 1, true) then
      return true
    end
  end
  return false
end

local root = vim.fn.getcwd()
vim.fn.mkdir(root .. "/src", "p")
vim.fn.writefile({
  "local value = 1",
  "local other = 2",
  "return value",
}, root .. "/src/sample.lua")

local fake = dofile(repo .. "/tests/integration/e2e/fake_opencode.lua")
local server = fake.start({ root = root })
local opencode = require("opencode")
local ui = require("opencode.ui")
local core = require("opencode.completion.core")
local keybindings = require("opencode.keybindings")
local status = require("opencode.status")
local renderer = require("opencode.render")
local selection = require("opencode.actions.selection")

local function base_config(extra)
  local cfg = {
    server = { url = server.url, headers = {} },
    project = { root = root },
    sidebar = { width = 40, input_height = 6 },
    tools = { enabled = false },
  }
  for key, value in pairs(extra or {}) do
    cfg[key] = value
  end
  return cfg
end

local ok, err = xpcall(function()
  opencode.setup(base_config())
  opencode.open()

  wait_until("session created", 8000, function()
    local state = opencode.get_state()
    return state.session_id ~= nil and state.session ~= nil and state.session.session ~= nil
  end)
  wait_until("history synchronized", 8000, function()
    local state = opencode.get_state()
    return state.sync ~= nil and state.sync.connected == true
  end)

  local health = opencode.health()
  check(type(health) == "table" and #health > 0, "combined health is empty")
  local state = opencode.get_state()
  check(state.session.session.id == "ses_test_1", "unexpected session id")
  check(state.root == vim.fs.normalize(root), "unexpected project root")
  check(ui.is_open(), "sidebar should be open")
  check(renderer.is_attached(), "renderer should be attached")
  check(renderer.get_buffer() == state.ui.buffers.messages, "renderer buffer mismatch")
  check(state.completion.attached, "completion should be attached")
  check(status.is_attached(), "status should be attached")
  check(status.get_state().session ~= nil, "status session should be set")
  check(keybindings.is_attached(state.ui.buffers.messages), "messages keybindings")
  check(keybindings.is_attached(state.ui.buffers.input), "input keybindings")

  local code_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(code_buf, 0, -1, false, { "local x = 1" })
  check(not keybindings.is_attached(code_buf), "ordinary buffer must not be attached")
  vim.api.nvim_buf_delete(code_buf, { force = true })

  local normal_esc = vim.fn.maparg("<Esc>", "n", false, true)
  check(type(normal_esc) == "table" and normal_esc.buffer == 1, "Normal Escape mapping missing")
  local insert_esc = vim.fn.maparg("<Esc>", "i", false, true)
  check(type(insert_esc) ~= "table" or insert_esc.buffer ~= 1, "Insert Escape must stay native")

  local input = state.ui.buffers.input
  vim.api.nvim_buf_set_lines(input, 0, -1, false, { "hello e2e" })
  check(opencode.submit() == true, "submit should start")
  wait_until("prompt accepted and draft cleared", 8000, function()
    return request_count(server, "prompt_count") == 1 and ui.get_draft() == ""
  end)
  wait_until("user block rendered", 8000, function()
    local current = opencode.get_state()
    return has_user_text(current.blocks, "hello e2e")
  end)
  local lines = renderer.get_lines()
  check(table.concat(lines, "\n"):find("hello e2e", 1, true) ~= nil, "renderer did not show prompt")

  -- Command completion query through the wired source, then command routing.
  vim.api.nvim_buf_set_lines(input, 0, -1, false, { "/smo" })
  ui.focus_input()
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  check(core.trigger(input, "manual") == true, "completion trigger failed")
  local candidates_ok = vim.wait(8000, function()
    local candidates = core.get_candidates(input)
    for _, candidate in ipairs(candidates) do
      if candidate.kind == "command" and candidate.text == "/smoke " then
        return true
      end
    end
    return false
  end, 20)
  if not candidates_ok then
    error("timed out: command candidates; requests=" .. vim.inspect(server.requests)
      .. " state=" .. vim.inspect(core.get_state(input)))
  end
  vim.api.nvim_buf_set_lines(input, 0, -1, false, { "/smoke now" })
  check(opencode.submit() == true, "command submit should start")
  wait_until("command routed", 8000, function()
    return request_count(server, "command_count") == 1 and ui.get_draft() == ""
  end)
  check(request_count(server, "prompt_count") == 1, "command must not be sent as prompt")
  check(server.commands[1].name == "smoke", "wrong command name")
  check(server.commands[1].text == "now", "wrong command arguments")

  -- <leader>os appends context without submitting.
  vim.cmd("tabnew")
  local file_buf = vim.fn.bufadd(root .. "/src/sample.lua")
  vim.fn.bufload(file_buf)
  vim.api.nvim_set_current_buf(file_buf)
  local file_tab = vim.api.nvim_get_current_tabpage()
  local file_win = vim.api.nvim_get_current_win()
  vim.cmd("normal! ggVj")
  check(opencode.send_selection() == true, "send_selection failed")
  wait_until("selection appended", 5000, function()
    local draft = ui.get_draft()
    return draft:find("src/sample.lua", 1, true) ~= nil
      and draft:find("local value = 1", 1, true) ~= nil
  end)
  check(request_count(server, "prompt_count") == 1, "selection must not submit")
  check(request_count(server, "command_count") == 1, "selection must not submit commands")

  -- <leader>oq opens a float and submits the question with context.
  vim.api.nvim_set_current_tabpage(file_tab)
  vim.api.nvim_set_current_win(file_win)
  vim.cmd("normal! ggVj")
  local question_ok, question_state = opencode.question_selection()
  check(question_ok == true and type(question_state) == "table", "question float did not open")
  vim.api.nvim_buf_set_lines(question_state.buf, 0, -1, false, { "What is this?" })
  check(selection.submit_question(question_state) == true, "question submit did not start")
  wait_until("question accepted", 8000, function()
    return request_count(server, "prompt_count") == 2 and not selection.is_question_open()
  end)
  check(server.prompts[2].text:find("What is this?", 1, true) ~= nil, "question text missing")
  check(server.prompts[2].text:find("local value = 1", 1, true) ~= nil, "question context missing")

  -- Session reset stops the old syncer and starts a new subscription. The
  -- fake service forgets the old session so restore falls through to create.
  local old_id = opencode.get_state().session_id
  server.sessions = {}
  opencode.reset_session()
  wait_until("session switched", 8000, function()
    local current = opencode.get_state()
    return current.session_id ~= nil and current.session_id ~= old_id
      and current.sync ~= nil and current.sync.connected == true
  end)
  check(server.create_count >= 2, "session switch should create a new session")
  wait_until("status switched", 5000, function()
    local status_state = require("opencode.status").get_state()
    local current_id = opencode.get_state().session_id
    local shown = type(status_state.session) == "table" and status_state.session.id or nil
    return shown == current_id
  end)

  -- Wiping the input buffer must rebuild and re-attach completion/keybindings.
  local old_input = ui.get_buffers().input
  vim.api.nvim_buf_delete(old_input, { force = true })
  opencode.open()
  wait_until("UI rebuilt", 5000, function()
    local current = opencode.get_state()
    return current.ui.buffers.input ~= old_input
      and current.completion.attached == true
      and keybindings.is_attached(current.ui.buffers.input)
  end)

  -- Double Escape configuration and Normal-mode-only behavior.
  opencode.setup(base_config({
    keybindings = { overrides = { ["session.interrupt"] = "escapeescape" }, sequence_timeout = 150 },
  }))
  opencode.open()
  wait_until("double-escape session", 8000, function()
    local current = opencode.get_state()
    return current.session_id ~= nil and current.sync ~= nil and current.sync.connected == true
  end)
  local kb_state = keybindings.get_state(opencode.get_state().ui.buffers.messages)
  check(kb_state ~= nil, "keybinding state missing")
  check(kb_state.resolved.bindings["session.interrupt"].keys[1] == "<Esc><Esc>", "double escape not resolved")

  local before = request_count(server, "interrupt_count")
  ui.focus_input()
  local feed = function(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end
  feed("ihello<Esc>")
  vim.wait(50)
  check(request_count(server, "interrupt_count") == before, "Insert Escape must not interrupt")
  feed("<Esc>")
  vim.wait(220)
  check(request_count(server, "interrupt_count") == before, "single Escape must not interrupt double binding")
  feed("<Esc><Esc>")
  wait_until("double escape interrupt", 5000, function()
    return request_count(server, "interrupt_count") == before + 1
  end)
  wait_until("interrupt result", 5000, function()
    return opencode.get_state().last_interrupt ~= nil
  end)
  local interrupt = opencode.get_state().last_interrupt
  check(
    interrupt ~= nil and interrupt.err == nil,
    "interrupt returned an error: " .. vim.inspect(interrupt and interrupt.err)
      .. " requests=" .. vim.inspect(server.requests)
  )
  check(interrupt.result ~= nil and interrupt.result.idle == true, "idle interrupt no-op expected")
  check(interrupt.result.interrupted == false, "idle interrupt should report interrupted=false")

  -- Existing buffer-local mappings are reported even when the target buffer is
  -- not the current buffer, and are never overwritten.
  local messages = opencode.get_state().ui.buffers.messages
  ui.focus_input()
  keybindings.detach(messages)
  vim.keymap.set("n", "<Esc>", function() end, {
    buffer = messages,
    silent = true,
    desc = "e2e existing mapping",
  })
  opencode.setup(base_config())
  local diagnostics = opencode.get_state().keybindings
    and opencode.get_state().keybindings.diagnostics or {}
  local conflict = false
  for _, item in ipairs(diagnostics) do
    if item.code == "mapping_conflict" then
      conflict = true
      break
    end
  end
  check(conflict, "mapping conflict was not reported: " .. vim.inspect(diagnostics))
  local existing = false
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(messages, "n")) do
    if map.desc == "e2e existing mapping" then
      existing = true
      break
    end
  end
  check(existing, "existing mapping was overwritten")
  pcall(vim.keymap.del, "n", "<Esc>", { buffer = messages })

  -- false disables the public keymaps while commands remain available.
  opencode.setup(base_config({
    keymaps = { toggle = false, send_selection = false, question_selection = false, submit = false },
  }))
  check(vim.fn.maparg("<leader>oo", "n") == "", "toggle false should remove mapping")
  check(vim.fn.maparg("<leader>os", "x") == "", "send_selection false should remove mapping")
  check(vim.fn.maparg("<leader>oq", "x") == "", "question_selection false should remove mapping")
  check(vim.fn.exists(":OpenCode") == 2, "OpenCode command should still exist")

  opencode.stop()
  server.stop()
  io.stdout:write("ok wiring\n")
  io.stdout:flush()
end, debug.traceback)

if not ok then
  io.stderr:write(tostring(err) .. "\n")
  pcall(server.stop)
  vim.cmd("cquit 1")
end
vim.cmd("qall!")
