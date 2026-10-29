local root = vim.fn.getcwd()
if vim.fn.filereadable(root .. "/lua/opencode/events.lua") == 0 then
  root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h:h")
end
package.path = root .. "/?.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
local events = require("opencode.events")

local function feed(parser, chunks)
  local parsed, errors = {}, {}
  for _, chunk in ipairs(chunks) do
    local got, got_errors = parser:feed(chunk)
    for _, event in ipairs(got) do
      parsed[#parsed + 1] = event
    end
    for _, err in ipairs(got_errors) do
      errors[#errors + 1] = err
    end
  end
  local tail, tail_errors = parser:finish()
  for _, event in ipairs(tail) do
    parsed[#parsed + 1] = event
  end
  for _, err in ipairs(tail_errors) do
    errors[#errors + 1] = err
  end
  return parsed, errors
end

local function parse_text(text)
  return feed(events.new(), { text })
end

test.describe("opencode.events", function()
  test.it("parses one event split at every byte boundary", function()
    local text = table.concat({
      "event: message.part.delta",
      "id: evt_1",
      'data: {"type":"message.part.delta","properties":{"sessionID":"ses_a","delta":"hi"}}',
      "",
      "",
    }, "\n")

    for split = 1, #text - 1 do
      local parser = events.new()
      local first, first_errors = parser:feed(text:sub(1, split))
      local second, second_errors = parser:feed(text:sub(split + 1))
      local all = {}
      for _, event in ipairs(first) do
        all[#all + 1] = event
      end
      for _, event in ipairs(second) do
        all[#all + 1] = event
      end
      test.equal(0, #first_errors, "no first half errors at split " .. split)
      test.equal(0, #second_errors, "no second half errors at split " .. split)
      test.equal(1, #all, "one event at split " .. split)
      test.equal("message.part.delta", all[1].type)
      test.equal("evt_1", all[1].id)
      test.equal("ses_a", all[1].data.sessionID)
      test.equal("hi", all[1].data.delta)
    end

    local one_byte = events.new()
    local parsed, errors = {}, {}
    for index = 1, #text do
      local got, got_errors = one_byte:feed(text:sub(index, index))
      for _, event in ipairs(got) do
        parsed[#parsed + 1] = event
      end
      for _, err in ipairs(got_errors) do
        errors[#errors + 1] = err
      end
    end
    test.equal(1, #parsed, "one event from single-byte chunks")
    test.equal(0, #errors)
  end)

  test.it("parses multiple events in one chunk and supports CRLF, LF and CR", function()
    local text = table.concat({
      'data: {"type":"first","properties":{"n":1}}',
      "",
      "",
      'data: {"type":"second","properties":{"n":2}}',
      "",
      "",
    }, "\r\n") .. 'data: {"type":"third","properties":{"n":3}}\r\r'

    local parsed, errors = parse_text(text)
    test.equal(0, #errors)
    test.equal(3, #parsed)
    test.equal("first", parsed[1].type)
    test.equal(1, parsed[1].data.n)
    test.equal("second", parsed[2].type)
    test.equal(2, parsed[2].data.n)
    test.equal("third", parsed[3].type)
    test.equal(3, parsed[3].data.n)
  end)

  test.it("handles CRLF split between chunks", function()
    local parser = events.new()
    local first = parser:feed('data: {"type":"x","properties":{}}\r')
    test.equal(0, #first, "trailing CR waits for a possible LF")
    local second = parser:feed("\n\r")
    test.equal(0, #second, "blank line is still incomplete")
    local third = parser:feed("\n")
    test.equal(1, #third)
    test.equal("x", third[1].type)
  end)

  test.it("joins multiple data lines and ignores comments and unknown fields", function()
    local text = table.concat({
      ": keepalive",
      "retry: 1500",
      "unknown: ignored",
      'data: {"type":"joined",',
      'data: "properties":{"value":"a"}}',
      "",
      "",
    }, "\n")
    local parser = events.new()
    local parsed, errors = parser:feed(text)
    test.equal(0, #errors)
    test.equal(1, #parsed)
    test.equal("joined", parsed[1].type)
    test.equal("a", parsed[1].data.value)
    test.equal(1500, parser.retry)
  end)

  test.it("uses the SSE event field, attaches id only to its own event, and keeps last_event_id", function()
    local text = table.concat({
      "id: 42",
      "event: custom",
      'data: {"type":"payload","properties":{"x":1}}',
      "",
      "",
      'data: {"type":"next","properties":{"x":2}}',
      "",
      "",
    }, "\n")
    local parser = events.new()
    local parsed, errors = parser:feed(text)
    test.equal(0, #errors)
    test.equal(2, #parsed)
    test.equal("custom", parsed[1].type)
    test.equal("42", parsed[1].id)
    test.equal(1, parsed[1].data.x)
    test.equal("next", parsed[2].type)
    test.equal(nil, parsed[2].id, "id is not copied onto later events")
    test.equal("42", parser.last_event_id)
  end)

  test.it("reports invalid JSON and keeps subsequent events", function()
    local on_error = {}
    local parser = events.new({ on_error = function(err)
      on_error[#on_error + 1] = err
    end })
    local text = table.concat({
      "data: {not json",
      "",
      "",
      'data: {"type":"ok","properties":{"n":1}}',
      "",
      "",
    }, "\n")
    local parsed, errors = parser:feed(text)
    test.equal(1, #errors)
    test.equal("invalid_event_data", errors[1].code)
    test.equal(1, #on_error)
    test.equal(1, #parsed)
    test.equal("ok", parsed[1].type)
    test.equal(1, parsed[1].data.n)
  end)

  test.it("rejects non-object payloads without crashing", function()
    local parsed, errors = parse_text(table.concat({
      "data: [1,2]",
      "",
      "",
      "data: 42",
      "",
      "",
      'data: {"type":"ok","properties":{}}',
      "",
      "",
    }, "\n"))
    test.equal(2, #errors)
    test.equal("invalid_event_payload", errors[1].code)
    test.equal("invalid_event_payload", errors[2].code)
    test.equal(1, #parsed)
    test.equal("ok", parsed[1].type)
  end)

  test.it("discards an incomplete trailing event and reset starts a fresh stream", function()
    local parser = events.new()
    local partial = parser:feed('data: {"type":"partial","properties":{}}\n')
    test.equal(0, #partial)
    local tail = parser:finish()
    test.equal(0, #tail)
    parser:reset()
    local parsed = parser:feed('data: {"type":"complete","properties":{}}\n\n')
    test.equal(1, #parsed)
    test.equal("complete", parsed[1].type)
  end)

  test.it("does not fabricate sequence and preserves native envelope id/sequence", function()
    local parsed, errors = parse_text(table.concat({
      'data: {"id":"evt_9","sequence":9,"type":"message.part.updated","properties":{"sessionID":"ses_a"}}',
      "",
      "",
      'data: {"type":"session.text.delta","sessionID":"ses_a","delta":"x"}',
      "",
      "",
    }, "\n"))
    test.equal(0, #errors)
    test.equal(2, #parsed)
    test.equal("evt_9", parsed[1].id)
    test.equal(9, parsed[1].sequence)
    test.equal("ses_a", parsed[1].data.sessionID)
    test.equal(nil, parsed[1].data.type, "v1 properties are exposed as data")
    test.equal(nil, parsed[2].id)
    test.equal(nil, parsed[2].sequence)
    test.equal("session.text.delta", parsed[2].type)
    test.equal("ses_a", parsed[2].data.sessionID)
    test.equal("x", parsed[2].data.delta)
  end)

  test.it("strips a leading UTF-8 BOM", function()
    local parsed, errors = parse_text("\239\187\191" .. 'data: {"type":"bom","properties":{}}\n\n')
    test.equal(0, #errors)
    test.equal(1, #parsed)
    test.equal("bom", parsed[1].type)
  end)

  test.it("ignores blocks with no data and lines with no colon", function()
    local parsed, errors = parse_text(table.concat({
      "event: empty",
      ": comment",
      "",
      "plain-field-without-colon",
      'data:{"type":"plain","properties":{}}',
      "",
      "",
    }, "\n"))
    test.equal(0, #errors)
    test.equal(1, #parsed)
    test.equal("plain", parsed[1].type)
  end)

  test.it("exposes parse() for complete streams", function()
    local parsed, errors = events.parse(
      'data: {"type":"a","properties":{"n":1}}\n\ndata: {"type":"b","properties":{"n":2}}\n\n'
    )
    test.equal(0, #errors)
    test.equal(2, #parsed)
    test.equal("a", parsed[1].type)
    test.equal("b", parsed[2].type)
  end)
end)
