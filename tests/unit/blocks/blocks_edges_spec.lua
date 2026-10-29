local root = vim.fn.getcwd()
if vim.fn.filereadable(root .. "/lua/opencode/blocks.lua") == 0 then
  root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h:h")
end
package.path = root .. "/?.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")

local function collect(model)
  local out = {}
  local function walk(ids)
    for _, id in ipairs(ids or {}) do
      local node = model:find(id)
      if node then
        out[#out + 1] = node
        walk(node.children)
      end
    end
  end
  walk(model.roots)
  return out
end

local function sorted_keys(value)
  local keys = {}
  for key in pairs(value or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

local diff = {
  files = {
    {
      path = "src/a.lua",
      status = "modified",
      hunks = {
        { header = "@@ -1,1 +1,2 @@", lines = {
          { type = "context", text = " local x = 1" },
          { type = "add", text = "+local y = 2" },
        } },
        { header = "@@ -9,1 +10,1 @@", lines = {
          { type = "remove", text = "-old" },
          { type = "add", text = "+new" },
        } },
      },
    },
    {
      path = "src/b.lua",
      status = "added",
      hunks = {
        { header = "@@ -0,0 +1,1 @@", lines = { { type = "add", text = "+return true" } } },
      },
    },
  },
}

test.describe("blocks projection edges", function()
  test.it("assigns schema fields and stable sequence numbers", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    model:apply_batch({
      generation = 1,
      snapshot = {
        session_id = "ses",
        messages = {
          {
            info = { id = "u", role = "user", time = { created = 1, completed = 2 } },
            parts = { { id = "ut", messageID = "u", type = "text", text = "hello" } },
          },
          {
            info = { id = "a", role = "assistant", time = { created = 3 } },
            parts = {
              { id = "at", messageID = "a", type = "text", text = "answer" },
              {
                id = "tool",
                messageID = "a",
                type = "tool",
                callID = "call",
                tool = "edit",
                state = { status = "completed", input = { filePath = "a" }, output = "ok", metadata = { diff = diff } },
              },
            },
          },
        },
      },
    })

    local user = model:find("u")
    local assistant = model:find("a")
    local tool = model:find("tool")
    test.equal("user", user.type)
    test.equal("completed", user.status)
    test.equal("hello", user.content)
    test.equal("assistant", assistant.type)
    test.equal("streaming", assistant.status)
    test.equal("answer", assistant.content)
    test.equal("a", tool.parent_id)
    test.equal("tool", tool.type)
    test.equal("completed", tool.status)
    test.equal("ok", tool.metadata.output)
    test.equal("a", tool.metadata.input.filePath)
    test.equal(2, #tool.metadata.diff.files)
    test.equal(2, #tool.metadata.diff.files[1].hunks)
    test.equal("+return true", tool.metadata.diff.files[2].hunks[1].lines[1].text)

    local all = model:get_all_blocks()
    test.equal(#all, #collect(model), "flat helper includes every node once")
    test.equal("u", all[1].id)
    test.equal("a", all[2].id)
    test.equal("tool", all[3].id)

    local seen = {}
    local previous = 0
    for _, node in ipairs(collect(model)) do
      test.truthy(type(node.sequence) == "number" and node.sequence > 0, "sequence must be a positive number")
      test.falsy(seen[node.sequence], "sequence numbers must be unique")
      seen[node.sequence] = true
      test.truthy(node.sequence >= previous, "sequence numbers must follow creation order")
      previous = node.sequence
    end
  end)

  test.it("attaches diff parts to their tool call and keeps every hunk", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    model:apply_batch({
      generation = 1,
      snapshot = {
        messages = {
          {
            info = { id = "m", role = "assistant", time = { created = 1 } },
            parts = {
              {
                id = "tool",
                messageID = "m",
                type = "tool",
                callID = "call-1",
                tool = "edit",
                state = { status = "running" },
              },
              {
                id = "diff-part",
                messageID = "m",
                type = "file",
                callID = "call-1",
                status = "completed",
                diff = diff,
              },
            },
          },
        },
      },
    })
    local tool = model:find("tool")
    local diff_block = model:find("diff-part")
    test.equal("tool", tool.type)
    test.equal("diff", diff_block.type)
    test.equal("tool", diff_block.parent_id)
    test.equal("diff-part", tool.children[1])
    test.equal("@@ -9,1 +10,1 @@", diff_block.metadata.diff.files[1].hunks[2].header)
    test.equal("+return true", diff_block.content.files[2].hunks[1].lines[1].text)
  end)

  test.it("rebinds parts that arrive before their message", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    model:apply_event({
      id = "p-text",
      type = "message.part.updated",
      data = { part = { id = "text", messageID = "late", type = "text", text = "early text" } },
    })
    model:apply_event({
      id = "p-tool",
      type = "message.part.updated",
      data = {
        part = {
          id = "late-tool",
          messageID = "late",
          type = "tool",
          callID = "late-call",
          tool = "bash",
          state = { status = "running", input = { command = "true" } },
        },
      },
    })
    test.equal(nil, model:find("late"))
    test.equal(nil, model:find("late-tool").parent_id)
    model:apply_event({
      id = "m-late",
      type = "message.updated",
      data = { info = { id = "late", role = "assistant", time = { created = 1 } } },
    })
    test.equal("early text", model:find("late").content)
    test.equal("late", model:find("late-tool").parent_id)
    test.equal("late-tool", model:find("late").children[1])
    test.equal(1, #model.roots)
  end)

  test.it("reparents permissions and diffs when their tool arrives later", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    model:apply_event({
      id = "ask-first",
      type = "permission.asked",
      data = { id = "perm-first", sessionID = "s", callID = "late-call", messageID = "m", permission = "bash" },
    })
    test.equal(nil, model:find("perm-first").parent_id)
    model:apply_event({
      id = "late-message",
      type = "message.updated",
      data = { info = { id = "m", role = "assistant", time = { created = 1 } } },
    })
    model:apply_event({
      id = "late-tool",
      type = "message.part.updated",
      data = { part = {
        id = "late-tool-id", messageID = "m", type = "tool", callID = "late-call", tool = "bash",
        state = { status = "running" },
      } },
    })
    test.equal("late-tool-id", model:find("perm-first").parent_id)
    test.equal("m", model:find("late-tool-id").parent_id)
    test.equal("late-tool-id", model:find("m").children[1])
  end)

  test.it("keeps user completion, derives execution and clears stale failure on reset", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    local snapshot = {
      messages = {
        {
          info = { id = "u", role = "user", time = { created = 1, completed = 2 } },
          parts = { { id = "ut", messageID = "u", type = "text", text = "go" } },
        },
        {
          info = { id = "a", role = "assistant", time = { created = 3 } },
          parts = {
            { id = "at", messageID = "a", type = "text", text = "working" },
            {
              id = "tool",
              messageID = "a",
              type = "tool",
              callID = "c",
              tool = "bash",
              state = { status = "running" },
            },
          },
        },
      },
    }
    model:apply_batch({ generation = 1, snapshot = snapshot })
    test.equal("completed", model:find("u").status)
    test.equal("tool_running", model:get_status().execution)
    model:apply_event({
      id = "err",
      type = "session.error",
      data = { messageID = "a", error = { message = "boom" } },
    })
    test.equal("failed", model:find("a").status)
    test.equal("failed", model:get_status().execution)
    test.equal("boom", model:get_status().error.message)

    model:apply_batch({
      generation = 2,
      snapshot = {
        messages = {
          {
            info = { id = "a2", role = "assistant", time = { created = 4, completed = 5 } },
            parts = { { id = "at2", messageID = "a2", type = "text", text = "done" } },
          },
        },
      },
    })
    test.equal("idle", model:get_status().execution)
    test.equal(nil, model:get_status().error)
    test.equal(nil, model:find("a"))
    test.equal(nil, model:find("error:a"))
  end)

  test.it("dedupes repeated native IDs without revising unrelated nodes", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    model:apply_event({
      id = "m",
      type = "message.updated",
      data = { info = { id = "m", role = "assistant", time = { created = 1 } } },
    })
    model:apply_event({
      id = "p",
      type = "message.part.updated",
      data = { part = { id = "t", messageID = "m", type = "text", text = "a" } },
    })
    model:apply_event({
      id = "tool",
      type = "message.part.updated",
      data = { part = {
        id = "tool", messageID = "m", type = "tool", callID = "c", tool = "read",
        state = { status = "completed", input = { path = "x" }, output = "body" },
      } },
    })
    local message_revision = model:find("m").revision
    local tool_revision = model:find("tool").revision
    local ignored = model:apply_event({
      id = "p",
      type = "message.part.updated",
      data = { part = { id = "t", messageID = "m", type = "text", text = "changed" } },
    })
    test.equal(false, ignored)
    test.equal("a", model:find("m").content)
    test.equal(message_revision, model:find("m").revision)

    model:apply_event({
      id = "tool-overlap",
      type = "message.part.updated",
      data = { part = {
        id = "tool", messageID = "m", type = "tool", callID = "c", tool = "read",
        state = { status = "completed", input = { path = "x" }, output = "body" },
      } },
    })
    test.equal(tool_revision, model:find("tool").revision)
    test.equal(message_revision, model:find("m").revision)
  end)

  test.it("advances generation from event envelopes and rejects older batches", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    test.equal(true, model:apply_batch({ generation = 1, snapshot = { messages = {} } }))
    test.equal(true, model:apply_batch({
      generation = 1,
      events = { { id = "advance", generation = 3, type = "session.idle", data = {} } },
    }))
    test.equal(3, model.generation)
    test.equal(false, model:apply_batch({ generation = 2, snapshot = { messages = {} } }))
    test.equal(3, model.generation)
  end)

  test.it("maps permissions, retry, compaction and unknown events", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    model:apply_event({
      id = "ask",
      type = "permission.asked",
      data = { id = "perm", sessionID = "s", permission = "bash", tool = { messageID = "m", callID = "c" } },
    })
    test.equal("waiting_permission", model:get_status().execution)
    test.equal(true, model:get_status().waiting_permission.perm.pending)
    test.equal("status", model:find("perm").type)
    model:apply_event({ id = "idle-while-waiting", type = "session.idle", data = {} })
    test.equal("waiting_permission", model:get_status().execution, "idle does not clear a pending permission")
    model:apply_event({
      id = "update",
      type = "permission.updated",
      data = { id = "perm", status = "replied", reply = "once" },
    })
    test.equal("completed", model:find("perm").status)
    test.equal("streaming", model:get_status().execution)
    test.equal(nil, model:get_status().waiting_permission.perm)

    model:apply_event({ id = "retry", type = "session.retry.scheduled", data = { messageID = "m", attempt = 3 } })
    test.equal("retrying", model:get_status().execution)
    test.equal(3, model:get_status().retry.attempt)
    model:apply_event({ id = "compact", type = "session.compaction.started", data = { reason = "auto" } })
    test.equal("compacting", model:get_status().execution)
    model:apply_event({ id = "future", type = "session.future.event", data = { value = 7 } })
    local unknown = model:find("future")
    test.equal("unknown", unknown.type)
    test.equal("session.future.event", unknown.content)
    test.equal(7, unknown.metadata.data.value)
    test.equal("session.future.event", unknown.metadata.raw.type)
  end)

  test.it("accepts a snapshot message map in deterministic creation order", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    model:apply_batch({
      generation = 1,
      snapshot = {
        session_id = "s",
        messages = {
          second = {
            info = { id = "second", role = "assistant", time = { created = 20 } },
            parts = { { id = "b", messageID = "second", type = "text", text = "B" } },
          },
          first = {
            info = { id = "first", role = "user", time = { created = 10, completed = 11 } },
            parts = { { id = "a", messageID = "first", type = "text", text = "A" } },
          },
        },
      },
    })
    local snapshot = model:get_snapshot()
    test.equal("first", snapshot.blocks[1].id)
    test.equal("second", snapshot.blocks[2].id)
    test.equal("A", snapshot.blocks[1].content)
    test.equal("B", snapshot.blocks[2].content)
  end)

  test.it("removes a message and all descendants", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    model:apply_batch({
      generation = 1,
      snapshot = {
        messages = {
          {
            info = { id = "m", role = "assistant", time = { created = 1 } },
            parts = {
              { id = "tool", messageID = "m", type = "tool", callID = "c", tool = "bash", state = { status = "running" } },
            },
          },
        },
      },
    })
    model:apply_event({
      id = "ask",
      type = "permission.asked",
      data = { id = "perm", sessionID = "s", permission = "bash", tool = { messageID = "m", callID = "c" } },
    })
    test.equal("tool", model:find("perm").parent_id)
    model:apply_event({ id = "remove", type = "message.removed", data = { messageID = "m" } })
    test.equal(nil, model:find("m"))
    test.equal(nil, model:find("tool"))
    test.equal(nil, model:find("perm"))
    test.equal(0, #model.roots)
  end)

  test.it("emits a full deterministic reset change for subscribers", function()
    local blocks = require("opencode.blocks")
    local model = blocks.new()
    local changes = {}
    model:subscribe(function(change)
      changes[#changes + 1] = change
    end)
    model:apply_batch({
      generation = 4,
      snapshot = {
        messages = {
          {
            info = { id = "m", role = "assistant", time = { created = 1, completed = 2 } },
            parts = { { id = "t", messageID = "m", type = "text", text = "x" } },
          },
        },
      },
    })
    test.equal(1, #changes)
    test.equal("reset", changes[1].kind)
    test.equal(4, changes[1].generation)
    test.equal("m", changes[1].blocks[1].id)
    test.equal("x", changes[1].blocks[1].content)
    test.equal("idle", changes[1].status.execution)

    local first = model:get_snapshot()
    local second = blocks.new()
    second:apply_batch({
      generation = 4,
      snapshot = {
        messages = {
          {
            info = { id = "m", role = "assistant", time = { created = 1, completed = 2 } },
            parts = { { id = "t", messageID = "m", type = "text", text = "x" } },
          },
        },
      },
    })
    local other = second:get_snapshot()
    test.equal(first.revision, other.revision)
    test.equal(#first.blocks, #other.blocks)
    test.equal(first.blocks[1].sequence, other.blocks[1].sequence)
    test.equal(first.blocks[1].revision, other.blocks[1].revision)
    test.deep_equal(sorted_keys(first.status.waiting_permission), sorted_keys(other.status.waiting_permission))
  end)
end)
