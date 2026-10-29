-- 04 selection actions with fake UI and fake 05A session controller.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
local context = require("opencode.context")
local actions = require("opencode.actions.selection")

local original_cwd = vim.fn.getcwd()
local original_selection = vim.o.selection
local buffers = {}

local function cleanup()
  actions._reset()
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  buffers = {}
  vim.o.selection = original_selection
  pcall(vim.cmd, "silent! only")
  pcall(vim.cmd, "silent! enew!")
  pcall(vim.cmd, "silent! cd " .. vim.fn.fnameescape(original_cwd))
end

local function case(fn)
  return function()
    local ok, err = pcall(fn)
    cleanup()
    if not ok then
      error(err, 0)
    end
  end
end

local function scratch(lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  buffers[#buffers + 1] = buf
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = filetype or ""
  return buf
end

local function fake_ui()
  local ui = {
    draft = "",
    appends = {},
    opens = 0,
    focuses = 0,
    submit_calls = 0,
    on_submit_calls = 0,
  }
  function ui.append_draft(text)
    ui.appends[#ui.appends + 1] = text
    if ui.draft ~= "" and not ui.draft:match("\n$") then
      ui.draft = ui.draft .. "\n"
    end
    ui.draft = ui.draft .. text
    return ui.draft
  end
  function ui.get_draft()
    return ui.draft
  end
  function ui.set_draft(text)
    ui.draft = text or ""
  end
  function ui.open()
    ui.opens = ui.opens + 1
    return true
  end
  function ui.focus_input()
    ui.focuses = ui.focuses + 1
    return true
  end
  function ui.on_submit(callback)
    ui.on_submit_calls = ui.on_submit_calls + 1
    ui.callback = callback
  end
  function ui.submit()
    ui.submit_calls = ui.submit_calls + 1
    return true
  end
  return ui
end

local function fake_session(mode)
  local session = {
    prompts = {},
    mode = mode or "success",
    pending = nil,
  }
  function session.prompt(_, text, callback)
    session.prompts[#session.prompts + 1] = text
    if session.mode == "pending" then
      session.pending = { text = text, callback = callback }
    elseif session.mode == "error" then
      callback({ code = "rejected", message = "server rejected prompt" })
    elseif session.mode == "throw" then
      error("fake transport failure")
    else
      callback(nil, { accepted = true })
    end
  end
  return session
end

local function expected_text(buf, selection)
  local extracted = assert(context.from_selection(buf, selection))
  return assert(context.format(extracted))
end

local function clear_marks()
  vim.fn.setpos("'<", { 0, 0, 0, 0 })
  vim.fn.setpos("'>", { 0, 0, 0, 0 })
end

test.describe("selection actions", function()
  test.it("appends selections in order without submitting or prompting", case(function()
    local buf = scratch({ "alpha", "beta", "gamma" }, "lua")
    local ui = fake_ui()
    local session = fake_session()
    ui.draft = "existing draft"
    actions.setup({ ui = ui, session = session, notify = false })

    local first_selection = { mode = "V", start = { row = 1 }, ["end"] = { row = 2 } }
    local second_selection = { mode = "v", start = { row = 3, col = 2 }, ["end"] = { row = 3, col = 4 } }
    test.truthy(actions.send_selection({ buffer = buf, selection = first_selection }))
    test.truthy(actions.send_selection({ buffer = buf, selection = second_selection }))

    local first = expected_text(buf, first_selection)
    local second = expected_text(buf, second_selection)
    test.equal(2, #ui.appends)
    test.equal(first, ui.appends[1])
    test.equal(second, ui.appends[2])
    test.equal("existing draft\n" .. first .. "\n" .. second, ui.draft, "draft is never overwritten")
    test.equal(2, ui.opens, "sidebar opens for each append")
    test.equal(2, ui.focuses, "input is focused for each append")
    test.equal(0, #session.prompts, "send_selection never calls prompt")
    test.equal(0, ui.submit_calls, "send_selection never submits")
    test.equal(0, ui.on_submit_calls, "send_selection does not install submit callbacks")
  end))

  test.it("uses the same formatted context for send and question", case(function()
    local buf = scratch({ "local value = 1", "print(value)" }, "lua")
    local ui = fake_ui()
    local session = fake_session()
    actions.setup({ ui = ui, session = session, notify = false })

    local selection = { mode = "V", start = { row = 1 }, ["end"] = { row = 2 } }
    test.truthy(actions.send_selection({ buffer = buf, selection = selection }))
    local sent = ui.appends[1]
    local draft_after_send = ui.draft

    local opens_before_question = ui.opens
    local opened, qstate = actions.question_selection({ buffer = buf, selection = selection })
    test.truthy(opened, tostring(qstate))
    local state = actions.get_question_state()
    test.equal(sent, state.formatted, "both entry points share the exact context")
    test.equal("lua", state.context.filetype)

    vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "Explain this" })
    test.truthy(actions._submit_question())
    test.equal(1, #session.prompts)
    test.equal("Explain this\n\n" .. sent, session.prompts[1])
    test.falsy(actions.is_question_open())
    test.equal("Explain this", actions.get_last_question())
    test.equal(opens_before_question + 1, ui.opens, "the question opens the sidebar once")
    test.equal(opens_before_question + 1, ui.focuses)
    test.equal(draft_after_send, ui.draft, "question does not touch the sidebar draft")
  end))

  test.it("does not submit empty or whitespace-only questions", case(function()
    local buf = scratch({ "alpha" }, "lua")
    local ui = fake_ui()
    local session = fake_session()
    actions.setup({ ui = ui, session = session, notify = false })

    local opened, qstate = actions.question_selection({
      buffer = buf,
      selection = { mode = "V", start = { row = 1 }, ["end"] = { row = 1 } },
    })
    test.truthy(opened)
    test.falsy(actions._submit_question(), "empty float is not submitted")
    test.equal(0, #session.prompts)
    test.truthy(actions.is_question_open())

    vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "   ", "\t" })
    test.falsy(actions._submit_question(), "whitespace-only float is not submitted")
    test.equal(0, #session.prompts)
    test.truthy(actions.is_question_open())
    test.equal("empty_input", actions.get_question_state().error.code)
  end))

  test.it("keeps the float and content on failure, then retries", case(function()
    local buf = scratch({ "alpha" }, "lua")
    local ui = fake_ui()
    local session = fake_session("error")
    local notices = {}
    actions.setup({
      ui = ui,
      session = session,
      notify = function(message, level)
        notices[#notices + 1] = { message = message, level = level }
      end,
    })

    local opened, qstate = actions.question_selection({
      buffer = buf,
      selection = { mode = "v", start = { row = 1, col = 1 }, ["end"] = { row = 1, col = 3 } },
    })
    test.truthy(opened)
    vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "keep me" })
    test.truthy(actions._submit_question())
    test.equal(1, #session.prompts)
    test.truthy(actions.is_question_open(), "failed submission keeps the float")
    test.deep_equal({ "keep me" }, vim.api.nvim_buf_get_lines(qstate.buf, 0, -1, false))
    test.equal("server rejected prompt", actions.get_question_state().error.message)
    test.equal(1, #notices, "failure is displayed")
    test.truthy(notices[1].message:find("server rejected prompt", 1, true))

    session.mode = "success"
    test.truthy(actions._submit_question(), "retry is allowed after failure")
    test.equal(2, #session.prompts)
    test.falsy(actions.is_question_open())
    test.equal("keep me", actions.get_last_question())
    test.equal(1, ui.opens)
  end))

  test.it("blocks duplicate submissions and cancels without any request", case(function()
    local buf = scratch({ "alpha" }, "lua")
    local ui = fake_ui()
    local session = fake_session("pending")
    actions.setup({ ui = ui, session = session, notify = false })

    local opened, qstate = actions.question_selection({
      buffer = buf,
      selection = { mode = "V", start = { row = 1 }, ["end"] = { row = 1 } },
    })
    test.truthy(opened)
    vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "one request" })
    test.truthy(actions._submit_question())
    test.falsy(actions._submit_question(), "second submission is ignored while pending")
    test.equal(1, #session.prompts)
    test.truthy(actions.get_question_state().submitting)

    test.truthy(actions.cancel_question())
    test.falsy(actions.is_question_open())
    -- The in-flight callback must not close or mutate a newer float.
    session.pending.callback(nil, { accepted = true })
    test.equal(0, ui.opens, "cancelled request does not open the sidebar")

    session.mode = "success"
    local reopened, second = actions.question_selection({
      buffer = buf,
      selection = { mode = "V", start = { row = 1 }, ["end"] = { row = 1 } },
    })
    test.truthy(reopened)
    vim.api.nvim_buf_set_lines(second.buf, 0, -1, false, { "unused" })
    test.truthy(actions.cancel_question())
    test.equal(1, #session.prompts, "cancel sends nothing")
  end))

  test.it("accepts the frozen plain session.prompt(text, callback) contract", case(function()
    local buf = scratch({ "alpha" }, "lua")
    local ui = fake_ui()
    local session = { prompts = {} }
    function session.prompt(text, callback)
      session.prompts[#session.prompts + 1] = text
      callback(nil, { accepted = true })
    end
    actions.setup({ ui = ui, session = session, notify = false })

    local opened, qstate = actions.question_selection({
      buffer = buf,
      selection = { mode = "V", start = { row = 1 }, ["end"] = { row = 1 } },
    })
    test.truthy(opened)
    vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "plain contract" })
    test.truthy(actions._submit_question())
    test.equal(1, #session.prompts)
    test.truthy(session.prompts[1]:find("plain contract", 1, true))
    test.falsy(actions.is_question_open())
    test.equal(1, ui.opens)
  end))

  test.it("rejects calls without a Visual selection", case(function()
    scratch({ "alpha" }, "lua")
    local ui = fake_ui()
    local session = fake_session()
    actions.setup({ ui = ui, session = session, notify = false })
    clear_marks()

    local ok, err = actions.send_selection()
    test.falsy(ok)
    test.truthy(tostring(err):find("selection", 1, true))
    local qok, qerr = actions.question_selection()
    test.falsy(qok)
    test.truthy(tostring(qerr):find("selection", 1, true))
    test.equal(0, #ui.appends)
    test.equal(0, ui.opens)
    test.equal(0, #session.prompts)
  end))

  test.it("turns a synchronous session exception into a retryable failure", case(function()
    local buf = scratch({ "alpha" }, "lua")
    local ui = fake_ui()
    local session = fake_session("throw")
    local notices = {}
    actions.setup({
      ui = ui,
      session = session,
      notify = function(message)
        notices[#notices + 1] = message
      end,
    })

    local opened, qstate = actions.question_selection({
      buffer = buf,
      selection = { mode = "V", start = { row = 1 }, ["end"] = { row = 1 } },
    })
    test.truthy(opened)
    vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "retry this" })
    test.truthy(actions._submit_question())
    test.truthy(actions.is_question_open())
    test.equal(1, #notices)
    test.truthy(notices[1]:find("fake transport failure", 1, true))
    test.deep_equal({ "retry this" }, vim.api.nvim_buf_get_lines(qstate.buf, 0, -1, false))

    session.mode = "success"
    test.truthy(actions._submit_question())
    test.falsy(actions.is_question_open())
  end))
end)
