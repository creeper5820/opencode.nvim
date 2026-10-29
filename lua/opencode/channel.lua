-- Test-friendly terminal channel.
--
-- Production code uses terminal:channel().  Tests can inject this fake channel
-- into selection actions and the router to verify exact PTY writes without
-- starting OpenCode or touching a user instance.

local M = {}

--- @param opts table|nil { alive = boolean }
--- @return table
function M.new(opts)
  opts = opts or {}
  local fake = {
    kind = "fake",
    events = {},
    sent = {},
    pasted = {},
    submitted = 0,
    alive = opts.alive ~= false,
  }

  local function record(event)
    fake.events[#fake.events + 1] = event
  end

  function fake:send(data)
    if not self.alive then
      return false, "fake terminal is closed"
    end
    self.sent[#self.sent + 1] = data
    record({ type = "send", data = data })
    return true
  end

  function fake:paste(text, paste_opts)
    if not self.alive then
      return false, "fake terminal is closed"
    end
    self.pasted[#self.pasted + 1] = { text = text, opts = paste_opts }
    record({ type = "paste", text = text, opts = paste_opts })
    return true
  end

  function fake:submit(submit_opts)
    if not self.alive then
      return false, "fake terminal is closed"
    end
    self.submitted = self.submitted + 1
    record({ type = "submit", opts = submit_opts })
    return true
  end

  function fake:is_alive()
    return self.alive
  end

  function fake:close()
    self.alive = false
  end

  function fake:clear()
    self.events = {}
    self.sent = {}
    self.pasted = {}
    self.submitted = 0
  end

  function fake:last(kind)
    for index = #self.events, 1, -1 do
      if self.events[index].type == kind then
        return self.events[index]
      end
    end
    return nil
  end

  return fake
end

return M
