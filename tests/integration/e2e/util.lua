local M = {}

function M.repo()
  return vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h:h")
end

function M.read(name)
  local path = M.repo() .. "/tests/integration/e2e/" .. name
  local lines = vim.fn.readfile(path)
  return table.concat(lines, "\n")
end

function M.base64(value)
  if type(vim.base64) == "table" and type(vim.base64.encode) == "function" then
    return vim.base64.encode(value)
  end
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local output = {}
  local index = 1
  while index <= #value do
    local a, b, c = value:byte(index, index + 2)
    local n = (a or 0) * 65536 + (b or 0) * 256 + (c or 0)
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    local c4 = n % 64
    output[#output + 1] = alphabet:sub(c1 + 1, c1 + 1)
    output[#output + 1] = alphabet:sub(c2 + 1, c2 + 1)
    output[#output + 1] = b and alphabet:sub(c3 + 1, c3 + 1) or "="
    output[#output + 1] = c and alphabet:sub(c4 + 1, c4 + 1) or "="
    index = index + 3
  end
  return table.concat(output)
end

function M.run_child(script_name, env, timeout)
  local harness = require("tests.support.harness").new()
  local result
  local ok, err = pcall(function()
    local extra = { OPENCODE_NVIM_TEST_REPO = M.repo() }
    for key, value in pairs(env or {}) do
      extra[key] = value
    end
    result = harness:spawn(M.read(script_name), {
      env = extra,
      timeout = timeout or 45000,
    })
  end)
  harness:cleanup()
  if not ok then
    error(err, 0)
  end
  return result
end

function M.child_env()
  return { OPENCODE_NVIM_TEST_REPO = M.repo() }
end

return M
