-- Real-service SSE smoke test.  It only runs when an isolated test service is
-- explicitly configured through OPENCODE_TEST_SERVER_URL (the harness also
-- refuses the default 4096 endpoint).  It never touches the user's service.

local root = vim.fn.getcwd()
if vim.fn.filereadable(root .. "/lua/opencode/events.lua") == 0 then
  root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h:h")
end
package.path = root .. "/?.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
local harness = require("tests.support.harness")

test.describe("sync real service", function()
  local service, reason = harness.real_service()
  if test.skip_if(not service, "parses a live /api/event SSE stream", reason) then
    return
  end

  test.it("parses a live /api/event SSE stream", function()
    local http = require("opencode.net.http")
    local events = require("opencode.events")
    local parser = events.new()
    local seen = { count = 0, connected = false, parse_error = nil }
    local done = { finished = false, err = nil }
    local headers = vim.tbl_extend("force", service.headers or {}, {
      Accept = "text/event-stream",
    })

    local cancel, start_err = http.stream({
      method = "GET",
      url = service.url .. "/api/event",
      headers = headers,
    }, {
      on_chunk = function(chunk)
        local parsed, errors = parser:feed(chunk)
        for _, err in ipairs(errors) do
          seen.parse_error = seen.parse_error or err
        end
        for _, event in ipairs(parsed) do
          seen.count = seen.count + 1
          if event.type == "server.connected" then
            seen.connected = true
          end
        end
      end,
      on_done = function(err)
        done.finished = true
        done.err = err
      end,
    })
    test.truthy(cancel, "stream start: " .. tostring(start_err))

    local ok = vim.wait(10000, function()
      return seen.connected or done.finished
    end, 20)
    cancel()
    parser:reset()

    test.truthy(ok, "timed out waiting for a parsed event")
    test.falsy(done.err, "stream error: " .. tostring(done.err and done.err.message))
    test.falsy(seen.parse_error, "parse error: " .. tostring(seen.parse_error and seen.parse_error.message))
    test.truthy(seen.connected, "server.connected event parsed from the live stream")
  end)
end)
