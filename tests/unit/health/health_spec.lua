local test = require("tests.support.test")

test.describe("health", function()
  test.it("reports Neovim, vim.uv and the default configuration", function()
    test.reload()
    local health = require("opencode.health")
    local results = health.collect()

    local found_version = false
    local found_uv = false
    local found_config = false
    local found_url = false
    local mentions_curl = false
    for _, item in ipairs(results) do
      if item.level == "ok" and item.message:match("^Neovim %d") then
        found_version = true
      end
      if item.level == "ok" and item.message:match("vim%.uv") then
        found_uv = true
      end
      if item.level == "ok" and item.message:match("configuration is valid") then
        found_config = true
      end
      if item.level == "info" and item.message:match("http://127%.0%.0%.1:4096") then
        found_url = true
      end
      if item.message:lower():match("curl") then
        mentions_curl = true
      end
    end

    test.truthy(found_version, "expected a Neovim version result")
    test.truthy(found_uv, "expected a vim.uv result")
    test.truthy(found_config, "expected a configuration result")
    test.truthy(found_url, "expected the resolved server URL")
    test.falsy(mentions_curl, "health must not depend on curl")
  end)

  test.it("reports an error when configuration cannot be loaded", function()
    local health = require("opencode.health")
    local original = package.loaded["opencode"]
    package.loaded["opencode"] = {
      get_config = function()
        error("broken config")
      end,
    }
    local ok, results = pcall(health.collect)
    package.loaded["opencode"] = original
    test.truthy(ok, "collect must not raise")
    local found = false
    for _, item in ipairs(results) do
      if item.level == "error" and item.message:match("configuration is invalid") then
        found = true
      end
    end
    test.truthy(found, "expected a configuration error")
  end)

  test.it("reports an old Neovim and missing vim.uv as errors", function()
    local health = require("opencode.health")
    local saved_version = vim.version
    local saved_uv = vim.uv
    local ok, err = pcall(function()
      vim.version = function()
        return { major = 0, minor = 9, patch = 0 }
      end
      vim.uv = nil
      local results = health.collect()
      local found_old = false
      local found_uv = false
      for _, item in ipairs(results) do
        if item.level == "error" and item.message:match("too old") then
          found_old = true
        end
        if item.level == "error" and item.message:match("vim%.uv is unavailable") then
          found_uv = true
        end
      end
      test.truthy(found_old, "expected an old Neovim error")
      test.truthy(found_uv, "expected a missing vim.uv error")
    end)
    vim.version = saved_version
    vim.uv = saved_uv
    if not ok then
      error(err, 0)
    end
  end)

  test.it("reports an explicit error for an https configuration", function()
    local health = require("opencode.health")
    local original = package.loaded["opencode"]
    package.loaded["opencode"] = {
      get_config = function()
        return { server = { url = "https://127.0.0.1:4096" } }
      end,
    }
    local ok, results = pcall(health.collect)
    package.loaded["opencode"] = original
    test.truthy(ok, "collect must not raise")
    local found = false
    for _, item in ipairs(results) do
      if item.level == "error" and item.message:match("HTTPS") then
        found = true
      end
    end
    test.truthy(found, "expected an HTTPS unsupported error")
  end)

  test.it("check() can run in headless Neovim", function()
    package.loaded["opencode.health"] = nil
    local health = require("opencode.health")
    local ok, err = pcall(health.check)
    test.truthy(ok, "health.check failed: " .. tostring(err))
  end)
end)
