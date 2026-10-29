-- 05A session store unit tests: persisted project -> session mapping.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local test = require("tests.support.test")
local H = dofile(root .. "/tests/unit/session/helper.lua")
local store_mod = require("opencode.session_store")
local uv = vim.uv or vim.loop

local function write(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd, err = uv.fs_open(path, "w", 384)
  assert(fd, tostring(err))
  assert(uv.fs_write(fd, data, 0))
  assert(uv.fs_close(fd))
end

local function read(path)
  local fd = assert(uv.fs_open(path, "r", 0))
  local stat = assert(uv.fs_fstat(fd))
  local data = assert(uv.fs_read(fd, stat.size, 0))
  uv.fs_close(fd)
  return data
end

local function perms(path)
  local stat = uv.fs_stat(path)
  return stat and bit.band(stat.mode, 511) or nil
end

local function entries(dir)
  local names = {}
  local iter = uv.fs_scandir(dir)
  while iter do
    local name = uv.fs_scandir_next(iter)
    if not name then
      break
    end
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

test.describe("session store", function()
  test.it("defaults to the Neovim state directory", function()
    test.equal(
      vim.fs.joinpath(vim.fn.stdpath("state"), "opencode", "sessions.json"),
      store_mod.default_path()
    )
  end)

  test.it("writes private files atomically and reads records back", H.case(function()
    local base = H.tempdir("store")
    local path = base .. "/nested/state/sessions.json"
    local project = H.tempdir("store-project")
    local store = store_mod.new({ path = path })

    local ok, err = store:set(project, { id = "ses_one", directory = project })
    test.truthy(ok, tostring(err))
    test.equal(448, perms(vim.fs.dirname(path)), "store directory mode")
    test.equal(384, perms(path), "store file mode")
    test.deep_equal({ "sessions.json" }, entries(vim.fs.dirname(path)), "no temp files remain")

    local record = store:get(project)
    test.deep_equal({ id = "ses_one", directory = store_mod.canonicalize(project) }, record)
    test.equal(nil, store:get(H.tempdir("store-other")))

    local decoded = vim.json.decode(read(path))
    test.equal(store_mod.SCHEMA_VERSION, decoded.schema)
    test.equal("ses_one", decoded.sessions[store_mod.canonicalize(project)].id)
  end))

  test.it("replaces one project record without dropping other projects", H.case(function()
    local path = H.tempdir("multi") .. "/sessions.json"
    local first = H.tempdir("project-one")
    local second = H.tempdir("project-two")
    local store = store_mod.new({ path = path })

    test.truthy(store:set(first, { id = "ses_first", directory = first }))
    test.truthy(store:set(second, { id = "ses_second", directory = second }))
    test.truthy(store:set(first, { id = "ses_first_new", directory = first }))

    test.equal("ses_first_new", store:get(first).id)
    test.equal("ses_second", store:get(second).id)
  end))

  test.it("canonicalizes roots and record directories", H.case(function()
    local real = H.tempdir("real-project")
    local link = H.tempdir("link-parent") .. "/project-link"
    local ok, err = uv.fs_symlink(real, link)
    assert(ok, tostring(err))
    local path = H.tempdir("canonical") .. "/sessions.json"
    local store = store_mod.new({ path = path })

    test.truthy(store:set(link, { id = "ses_link", directory = link }))
    local record = store:get(real)
    test.truthy(record)
    test.equal("ses_link", record.id)
    test.equal(store_mod.canonicalize(real), record.directory)
  end))

  test.it("rejects mismatched record locations", H.case(function()
    local project = H.tempdir("mismatch-project")
    local other = H.tempdir("mismatch-other")
    local store = store_mod.new({ path = H.tempdir("mismatch") .. "/sessions.json" })

    local ok, err = store:set(project, { id = "ses_bad", directory = other })
    test.equal(nil, ok)
    test.matches("location mismatch", err)

    write(store.path, vim.json.encode({
      schema = store_mod.SCHEMA_VERSION,
      sessions = {
        [store_mod.canonicalize(project)] = {
          id = "ses_bad",
          directory = store_mod.canonicalize(other),
        },
      },
    }))
    local record, get_err = store:get(project)
    test.equal(nil, record)
    test.matches("location mismatch", get_err)
  end))

  test.it("removes only the requested record", H.case(function()
    local path = H.tempdir("remove") .. "/sessions.json"
    local first = H.tempdir("remove-one")
    local second = H.tempdir("remove-two")
    local store = store_mod.new({ path = path })
    assert(store:set(first, { id = "ses_first", directory = first }))
    assert(store:set(second, { id = "ses_second", directory = second }))

    test.truthy(store:remove(first))
    test.equal(nil, store:get(first))
    test.equal("ses_second", store:get(second).id)
    test.truthy(store:remove(first), "remove is idempotent")
    test.truthy(store:remove(second))
    test.equal(nil, store:get(second), "empty store reloads cleanly")
  end))

  test.it("reports corrupt stores but recovers on the next write", H.case(function()
    local path = H.tempdir("corrupt") .. "/sessions.json"
    local project = H.tempdir("corrupt-project")
    write(path, "{not json")

    local store = store_mod.new({ path = path })
    local data, err = store:load()
    test.equal(nil, data)
    test.matches("invalid session store JSON", err)
    local record, get_err = store:get(project)
    test.equal(nil, record)
    test.matches("invalid session store JSON", get_err)

    test.truthy(store:set(project, { id = "ses_recovered", directory = project }))
    test.equal("ses_recovered", store:get(project).id)
  end))

  test.it("rejects unsupported schemas and malformed records", H.case(function()
    local base = H.tempdir("schema")
    local project = H.tempdir("schema-project")
    local path = base .. "/sessions.json"
    write(path, vim.json.encode({ schema = 99, sessions = {} }))
    local store = store_mod.new({ path = path })
    local data, err = store:load()
    test.equal(nil, data)
    test.matches("unsupported session store schema", err)

    write(path, vim.json.encode({
      schema = store_mod.SCHEMA_VERSION,
      sessions = {
        [store_mod.canonicalize(project)] = { id = "", directory = store_mod.canonicalize(project) },
      },
    }))
    local record, record_err = store:get(project)
    test.equal(nil, record)
    test.matches("invalid session record", record_err)
  end))

  test.it("rejects invalid input paths", H.case(function()
    test.error_matches("non%-empty string", function()
      store_mod.new({ path = "" })
    end)
    local store = store_mod.new({ path = H.tempdir("invalid") .. "/sessions.json" })
    local project = H.tempdir("invalid-project")
    test.equal(nil, store:set(project, { id = "", directory = project }))
    test.equal(nil, store:get(""))
  end))
end)
