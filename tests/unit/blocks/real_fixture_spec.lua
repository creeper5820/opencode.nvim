local root = vim.fn.getcwd()
if vim.fn.filereadable(root .. "/lua/opencode/blocks.lua") == 0 then
  root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h:h")
end
package.path = root .. "/?.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")

local function stable(value)
  if type(value) ~= "table" then
    return type(value) .. ":" .. tostring(value)
  end
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local out = { "{" }
  for _, key in ipairs(keys) do
    out[#out + 1] = tostring(key) .. "=" .. stable(value[key]) .. ";"
  end
  out[#out + 1] = "}"
  return table.concat(out)
end

test.describe("blocks real fixture replay", function()
  local path = vim.env.OPENCODE_TEST_CONVERSATION_FIXTURE
  if test.skip_if(
    not path or path == "",
    "replays a captured sanitized conversation fixture",
    "OPENCODE_TEST_CONVERSATION_FIXTURE is not set"
  ) then
    return
  end
  if test.skip_if(
    path:sub(1, #"/tmp/opencode/") ~= "/tmp/opencode/",
    "replays a captured sanitized conversation fixture",
    "fixture path must be under /tmp/opencode"
  ) then
    return
  end

  test.it("replays a captured sanitized conversation fixture deterministically", function()
    local ok, fixture = pcall(dofile, path)
    test.truthy(ok, "fixture must load: " .. tostring(fixture))
    test.truthy(type(fixture) == "table", "fixture must return a table")
    test.truthy(type(fixture.snapshot) == "table", "fixture.snapshot is required")
    test.truthy(type(fixture.events) == "table", "fixture.events is required")

    local blocks = require("opencode.blocks")
    local function replay()
      local model = blocks.new()
      model:apply_batch({
        generation = fixture.generation or 1,
        snapshot = fixture.snapshot,
        events = fixture.events,
      })
      return model
    end
    local first = replay():get_snapshot()
    local second = replay():get_snapshot()
    test.equal(stable(first), stable(second), "same fixture must replay identically")
    test.truthy(#first.blocks > 0, "fixture must produce blocks")
    for _, block in ipairs(first.blocks) do
      test.truthy(block.id ~= nil, "block id is required")
      test.truthy(type(block.sequence) == "number" and block.sequence > 0, "block sequence is required")
      test.truthy(type(block.children) == "table", "block children is required")
      test.truthy(type(block.metadata) == "table", "block metadata is required")
      test.truthy(type(block.revision) == "number", "block revision is required")
    end
  end)
end)
