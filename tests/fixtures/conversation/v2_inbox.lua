-- Synthetic, sanitized V2 conversation fixture. Shapes mirror OpenCode v2.0.x:
--
--   * history messages are Session.Message.Info objects directly:
--       { id, time, type = "user", text } or
--       { id, time, type = "assistant", content = { text/reasoning/tool } }
--   * public SSE events are framed as:
--       { id = "evt_...", type = "session.inbox.enqueued", data = {...} }
--     05B forwards the decoded event object as event.data, so 05C unwraps the
--     nested `data` payload.
--
-- IDs are fixed synthetic values, paths point at /tmp/opencode, and no user
-- session, project or credential data is present.
local M = {}

M.session_id = "ses_v2_fixture"
M.location = { directory = "/tmp/opencode/v2-fixture-project" }
M.user_id = "msg_v2_user"
M.assistant_id = "msg_v2_assistant"

M.snapshot = {
  session_id = M.session_id,
  location = M.location,
  messages = {
    {
      id = M.user_id,
      time = { created = 1000 },
      type = "user",
      text = "fix the real prompt",
      metadata = { source = "fixture" },
    },
    {
      id = M.assistant_id,
      time = { created = 1001, completed = 1003 },
      type = "assistant",
      agent = "build",
      model = { providerID = "test", modelID = "fixture" },
      content = {
        {
          type = "text",
          text = "I will inspect the file.",
        },
        {
          type = "reasoning",
          text = "Read before editing.",
          time = { created = 1001, completed = 1002 },
        },
        {
          type = "tool",
          id = "tool_v2_fixture",
          name = "bash",
          executed = true,
          state = {
            status = "completed",
            input = { command = "true" },
            content = { { type = "text", text = "ok" } },
            metadata = { exit = 0 },
          },
          time = { created = 1002, completed = 1003 },
        },
      },
      finish = "stop",
    },
  },
}

local function inbox_event(id, created, payload)
  return {
    type = "session.inbox.enqueued",
    data = {
      id = id,
      created = created,
      type = "session.inbox.enqueued",
      location = M.location,
      data = {
        sessionID = M.session_id,
        inboxID = M.user_id,
        item = {
          type = "user",
          payload = payload or { text = "fix the real prompt" },
          delivery = "steer",
        },
      },
      durable = {
        aggregateID = M.session_id,
        seq = 1,
        version = 1,
      },
    },
  }
end

M.inbox_enqueued = inbox_event("evt_v2_enqueued", 1000, {
  text = "fix the real prompt",
  metadata = { source = "fixture" },
})

M.inbox_enqueued_duplicate = inbox_event("evt_v2_enqueued_replayed", 1000, {
  text = "fix the real prompt",
  metadata = { source = "fixture" },
})

M.inbox_delivered = {
  type = "session.inbox.delivered",
  data = {
    id = "evt_v2_delivered",
    created = 1001,
    type = "session.inbox.delivered",
    location = M.location,
    data = {
      sessionID = M.session_id,
      inboxID = M.user_id,
    },
    durable = {
      aggregateID = M.session_id,
      seq = 4,
      version = 1,
    },
  },
}

M.inbox_delivered_duplicate = {
  type = "session.inbox.delivered",
  data = {
    id = "evt_v2_delivered_replayed",
    created = 1001,
    type = "session.inbox.delivered",
    location = M.location,
    data = {
      sessionID = M.session_id,
      inboxID = M.user_id,
    },
    durable = {
      aggregateID = M.session_id,
      seq = 4,
      version = 1,
    },
  },
}

M.execution_started = {
  type = "session.execution.started",
  data = {
    id = "evt_v2_execution_started",
    created = 1000,
    type = "session.execution.started",
    location = M.location,
    data = { sessionID = M.session_id },
    durable = { aggregateID = M.session_id, seq = 2, version = 1 },
  },
}

-- Order mirrors the 05B first batch: history snapshot followed by buffered
-- live events. Applying this batch must merge the user message, not duplicate
-- it.
M.events = {
  M.execution_started,
  M.inbox_enqueued,
  M.inbox_delivered,
}

return M
