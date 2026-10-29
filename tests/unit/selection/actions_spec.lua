local test = require("tests.support.test")
local channel = require("opencode.channel")
local context = require("opencode.context")
local selection = require("opencode.actions.selection")

local function reset()
  pcall(selection._reset)
end

local function scratch(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "lua"
  return buf
end

local function visual(buf)
  return {
    buffer = buf,
    mode = "v",
    start = { row = 1, col = 1 },
    ["end"] = { row = 1, col = 5 },
  }
end

local function formatted(buf)
  local extracted = assert(context.from_selection(buf, visual(buf)))
  return assert(context.format(extracted))
end

test.describe("selection to TUI composer", function()
  test.it("pastes formatted context without submitting", function()
    reset()
    local buf = scratch({ "local x = 1", "return x" })
    local fake = channel.new()
    selection.setup({ channel = fake, focus_input = false, open = false, notify = false })
    local ok, err = selection.send_selection({ selection = visual(buf), buffer = buf, focus_input = false })
    test.truthy(ok, tostring(err))
    test.equal(1, #fake.pasted)
    test.equal(formatted(buf), fake.pasted[1].text)
    test.equal(0, fake.submitted)
    test.equal(1, #fake.events)
    test.equal("paste", fake.events[1].type)
    reset()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  test.it("pastes question + context and submits in a separate event", function()
    reset()
    local buf = scratch({ "local x = 1", "return x" })
    local fake = channel.new()
    selection.setup({ channel = fake, focus_input = false, open = false, notify = false, submit_delay = 0 })
    local ok, qstate = selection.question_selection({
      selection = visual(buf),
      buffer = buf,
      submit_delay = 0,
    })
    test.truthy(ok, tostring(qstate))
    vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "Why this?", "Second line" })
    test.truthy(selection._submit_question(qstate))
    test.equal(1, #fake.pasted)
    test.equal("Why this?\nSecond line\n\n" .. formatted(buf), fake.pasted[1].text)
    test.equal(1, fake.submitted)
    test.equal(2, #fake.events)
    test.equal("paste", fake.events[1].type)
    test.equal("submit", fake.events[2].type)
    test.falsy(selection.is_question_open())
    reset()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  test.it("keeps ordinary text inside paste, never interprets it as shortcuts", function()
    reset()
    local buf = scratch({ "local x = 1" })
    local fake = channel.new()
    selection.setup({ channel = fake, focus_input = false, open = false, notify = false, submit_delay = 0 })
    local ok, qstate = selection.question_selection({ selection = visual(buf), buffer = buf, submit_delay = 0 })
    test.truthy(ok, tostring(qstate))
    vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "<C-x>n :q /exit" })
    test.truthy(selection._submit_question(qstate))
    test.equal("<C-x>n :q /exit\n\n" .. formatted(buf), fake.pasted[1].text)
    test.equal(1, fake.submitted)
    test.equal(0, #fake.sent)
    reset()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  test.it("cancels without sending anything", function()
    reset()
    local buf = scratch({ "local x = 1" })
    local fake = channel.new()
    selection.setup({ channel = fake, focus_input = false, open = false, notify = false })
    local ok, qstate = selection.question_selection({ selection = visual(buf), buffer = buf })
    test.truthy(ok, tostring(qstate))
    test.truthy(selection.cancel_question(qstate))
    test.equal(0, #fake.events)
    test.falsy(selection.is_question_open())
    reset()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  test.it("rejects empty questions and keeps the float open", function()
    reset()
    local buf = scratch({ "local x = 1" })
    local fake = channel.new()
    selection.setup({ channel = fake, focus_input = false, open = false, notify = false })
    local ok, qstate = selection.question_selection({ selection = visual(buf), buffer = buf })
    test.truthy(ok, tostring(qstate))
    test.equal(false, selection._submit_question(qstate))
    test.equal(0, #fake.events)
    test.truthy(selection.is_question_open())
    selection.cancel_question(qstate)
    reset()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  test.it("keeps the float when the terminal channel is dead", function()
    reset()
    local buf = scratch({ "local x = 1" })
    local fake = channel.new({ alive = false })
    selection.setup({ channel = fake, focus_input = false, open = false, notify = false })
    local ok, err = selection.send_selection({ selection = visual(buf), buffer = buf })
    test.equal(false, ok)
    test.matches("not running", err)

    local qok, qstate = selection.question_selection({ selection = visual(buf), buffer = buf })
    test.truthy(qok, tostring(qstate))
    vim.api.nvim_buf_set_lines(qstate.buf, 0, -1, false, { "Question" })
    test.equal(false, selection._submit_question(qstate))
    test.truthy(selection.is_question_open())
    selection.cancel_question(qstate)
    reset()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
