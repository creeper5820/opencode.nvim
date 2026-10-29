local test = require("tests.support.test")
local status = require("opencode.status")

local function contains(haystack, needle)
  test.truthy(
    type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
    ("expected %q in %q"):format(needle, tostring(haystack))
  )
end

local function absent(haystack, needle)
  test.falsy(
    type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
    ("did not expect %q in %q"):format(needle, tostring(haystack))
  )
end

local full = {
  session = { id = "ses_1", title = "Fix login" },
  project = { root = "/tmp/opencode/project" },
  agent = { id = "build", name = "Build" },
  model = { provider_id = "anthropic", id = "claude-sonnet" },
  connection = "connected",
  submission = "idle",
  execution = "streaming",
}

test.describe("opencode.status render", function()
  test.it("renders all message fields", function()
    local line = status.render(full, "message")
    contains(line, "Session: Fix login")
    contains(line, "Project: project")
    contains(line, "Agent: Build")
    contains(line, "Model: anthropic/claude-sonnet")
    contains(line, "Connection: connected")
    contains(line, "Submission: idle")
    contains(line, "Execution: streaming")
  end)

  test.it("renders a compact input line with the submit hint", function()
    local line = status.render(full, "input", { submit_hint = "Submit <C-s>" })
    contains(line, "Session: Fix login")
    contains(line, "Connection: connected")
    contains(line, "Submission: idle")
    contains(line, "Execution: streaming")
    contains(line, "Submit <C-s>")
    absent(line, "Project:")
    absent(line, "Agent:")
    absent(line, "Model:")
  end)

  test.it("omits unavailable fields instead of inventing defaults", function()
    local line = status.render({ connection = "connected" }, "message")
    test.equal("Connection: connected", line)
    absent(line, "Session:")
    absent(line, "Project:")
    absent(line, "Agent:")
    absent(line, "Model:")
    absent(line, "Submission:")
    absent(line, "Execution:")

    test.equal("", status.render({}, "message"))
    test.equal("", status.render(nil, "input"))
  end)

  test.it("falls back from a missing title to the session id", function()
    local line = status.render({ session = { id = "ses_abc" } }, "message")
    test.equal("Session: ses_abc", line)
  end)

  test.it("shows a model provider only when that is all that exists", function()
    local line = status.render({ model = { provider_id = "anthropic" } }, "message")
    test.equal("Model: anthropic", line)
  end)

  test.it("keeps every state visually distinct", function()
    local executions = {
      idle = "Execution: idle",
      streaming = "Execution: streaming",
      tool_running = "Execution: tool running",
      retrying = "Execution: retrying",
      compacting = "Execution: compacting",
      waiting_permission = "Execution: waiting permission",
      interrupted = "Execution: interrupted",
      failed = "Execution: failed",
    }
    for value, expected in pairs(executions) do
      local line = status.render({ execution = value }, "message")
      test.equal(expected, line)
    end

    test.equal("Connection: reconnecting", status.render({ connection = "reconnecting" }, "message"))
    test.equal("Submission: submitting", status.render({ submission = "submitting" }, "message"))
    test.equal("Submission: failed", status.render({ submission = "failed" }, "message"))
  end)

  test.it("shows a persistent waiting-permission hint", function()
    local line = status.render({
      execution = "tool_running",
      waiting_permission = { request_1 = { tool = "edit" } },
    }, "message")
    contains(line, "Execution: tool running")
    contains(line, "Permission: waiting permission")

    line = status.render({
      execution = "idle",
      waiting_permission = { request_1 = {}, request_2 = {} },
    }, "message")
    contains(line, "Permission: waiting permission (2)")

    line = status.render({ execution = "waiting_permission" }, "message")
    test.equal("Execution: waiting permission", line)
  end)

  test.it("escapes statusline metacharacters and control characters", function()
    local line = status.render({
      session = { id = "ses", title = "100% done\nline2\t{evil} %{expr}" },
    }, "message")
    absent(line, "\n")
    absent(line, "\t")
    contains(line, "100%% done line2 {evil} %%{expr}")
  end)

  test.it("truncates long single-byte and multi-byte titles safely", function()
    local ascii = status.render({ session = { id = "s", title = string.rep("x", 200) } }, "message")
    local text = ascii:match("^Session: (.*)$")
    test.equal(40, vim.fn.strchars(text))
    test.matches("…$", text)

    local unicode = status.render({ session = { id = "s", title = string.rep("汉", 80) } }, "message")
    local unicode_text = unicode:match("^Session: (.*)$")
    test.equal(40, vim.fn.strchars(unicode_text))
    test.equal(unicode_text, vim.fn.strcharpart(unicode_text, 0, 40))
  end)

  test.it("honours an explicit display width", function()
    local line = status.render(full, "message", { width = 32 })
    test.truthy(vim.fn.strdisplaywidth(line) <= 32)
    test.matches("…$", line)
  end)

  test.it("renders the spinner only when supplied", function()
    local line = status.render(full, "message")
    absent(line, "Execution: streaming · /")

    local spinning = status.render(full, "message", { spinner = "/" })
    contains(spinning, "Execution: streaming · /")
  end)
end)
