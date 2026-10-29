-- Synthetic, sanitized conversation fixture. No captured user data.
--
-- Adapter shapes exercised here:
--   snapshot = { session_id, location, messages = { { info, parts } } }
--   events   = { { id, sequence, type, data } } (the 05B output contract)
--   diff     = { files = { { path, status, hunks = { { header, lines } } } } }
--
-- The message/part fields mirror native OpenCode v1 envelopes. The same
-- projection also accepts { type, properties } envelopes and V2
-- session.text/reasoning/tool/compaction events. A captured fixture can be
-- replayed by tests/unit/blocks/real_fixture_spec.lua when
-- OPENCODE_TEST_CONVERSATION_FIXTURE points at a sanitized file under
-- /tmp/opencode; that test is skipped unless explicitly configured.
local M = {}

local diff = {
  files = {
    {
      path = "src/a.lua",
      status = "modified",
      hunks = {
        {
          header = "@@ -10,4 +10,5 @@",
          lines = {
            { type = "context", text = " local value = get_value()" },
            { type = "remove", text = " return value" },
            { type = "add", text = " return value or default" },
            { type = "add", text = " end" },
          },
        },
        {
          header = "@@ -30,2 +31,2 @@",
          lines = {
            { type = "remove", text = "-old" },
            { type = "add", text = "+new" },
          },
        },
      },
    },
    {
      path = "src/b.lua",
      status = "added",
      hunks = {
        {
          header = "@@ -0,0 +1,2 @@",
          lines = {
            { type = "add", text = "+local b = true" },
            { type = "add", text = "+return b" },
          },
        },
      },
    },
  },
}
M.diff = diff

M.snapshot = {
  session_id = "ses_fixture",
  location = { directory = "/tmp/opencode/fixture-project" },
  messages = {
    {
      info = {
        id = "msg_user",
        sessionID = "ses_fixture",
        role = "user",
        time = { created = 1 },
      },
      parts = {
        { id = "prt_user_text", messageID = "msg_user", type = "text", text = "Please update a.lua" },
      },
    },
    {
      info = {
        id = "msg_assistant",
        sessionID = "ses_fixture",
        role = "assistant",
        parentID = "msg_user",
        time = { created = 2 },
        cost = 0,
      },
      parts = {
        { id = "prt_text", messageID = "msg_assistant", type = "text", text = "Working on it." },
        {
          id = "prt_tool",
          messageID = "msg_assistant",
          type = "tool",
          callID = "call_1",
          tool = "edit",
          state = {
            status = "running",
            input = { filePath = "src/a.lua" },
          },
          input = { filePath = "src/a.lua" },
          diff = diff,
        },
      },
    },
  },
}

-- Events use the 05B contract { id, sequence, type, data }.
M.events = {
  {
    id = "evt_delta_1",
    sequence = 1,
    type = "message.part.delta",
    data = { sessionID = "ses_fixture", messageID = "msg_assistant", partID = "prt_text", field = "text", delta = " Streaming" },
  },
  {
    id = "evt_reasoning",
    sequence = 2,
    type = "message.part.updated",
    data = {
      sessionID = "ses_fixture",
      part = { id = "prt_reasoning", messageID = "msg_assistant", type = "reasoning", text = "Check the diff first." },
    },
  },
  {
    id = "evt_tool_done",
    sequence = 3,
    type = "message.part.updated",
    data = {
      sessionID = "ses_fixture",
      part = {
        id = "prt_tool",
        messageID = "msg_assistant",
        type = "tool",
        callID = "call_1",
        tool = "edit",
        state = {
          status = "completed",
          input = { filePath = "src/a.lua" },
          output = "updated",
          metadata = { diff = diff },
        },
        input = { filePath = "src/a.lua" },
        output = "updated",
        diff = diff,
      },
    },
  },
  {
    id = "evt_permission_asked",
    sequence = 4,
    type = "permission.asked",
    data = {
      id = "perm_1",
      sessionID = "ses_fixture",
      permission = "edit",
      patterns = { "src/a.lua" },
      tool = { messageID = "msg_assistant", callID = "call_1" },
      metadata = { command = "edit src/a.lua" },
    },
  },
  {
    id = "evt_permission_replied",
    sequence = 5,
    type = "permission.replied",
    data = { sessionID = "ses_fixture", requestID = "perm_1", reply = "once" },
  },
  {
    id = "evt_retry",
    sequence = 6,
    type = "session.retry.scheduled",
    data = {
      sessionID = "ses_fixture",
      assistantMessageID = "msg_assistant",
      attempt = 2,
      at = 100,
      error = { message = "rate limited" },
    },
  },
  {
    id = "evt_compaction",
    sequence = 7,
    type = "session.compaction.started",
    data = { sessionID = "ses_fixture", reason = "auto" },
  },
  {
    id = "evt_unknown",
    sequence = 8,
    type = "session.future.thing",
    data = { sessionID = "ses_fixture", answer = 42 },
  },
}

M.overlap_event = {
  id = "evt_tool_overlap",
  sequence = 9,
  type = "message.part.updated",
  data = {
    sessionID = "ses_fixture",
    part = {
      id = "prt_tool",
      messageID = "msg_assistant",
      type = "tool",
      callID = "call_1",
      tool = "edit",
      state = { status = "completed", input = { filePath = "src/a.lua" }, output = "updated" },
      input = { filePath = "src/a.lua" },
      output = "updated",
    },
  },
}

return M
