-- Public plugin facade and cross-module wiring.
--
-- The modules in this repository are deliberately independent:
--
--   client   stateless HTTP API
--   session  current-project session controller
--   sync     SSE + history synchronizer
--   state    block model + status dimensions
--   ui       two real Neovim windows
--   render   message buffer renderer
--   completion engine + OpenCode sources
--   status   window-local winbar
--   tools    optional local HTTP server used by the companion plugin
--
-- This file is the only place that assembles those pieces.  Other modules do
-- not require each other's UI or session state.

local config = require("opencode.config")
local session_store = require("opencode.session_store")

local uv = vim.uv or vim.loop

local M = {}

local resolved = nil
local runtime = nil

local KEYMAP_DESC = {
  toggle = "OpenCode: toggle sidebar",
  send_selection = "OpenCode: send selection to draft",
  question_selection = "OpenCode: ask about selection",
}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  return vim.deepcopy(value)
end

local function valid_buf(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function loaded_buf(buf)
  return valid_buf(buf) and vim.api.nvim_buf_is_loaded(buf)
end

local function valid_win(win)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function notify(message, level)
  pcall(vim.notify, message, level or vim.log.levels.INFO)
end

local function error_message(err)
  if type(err) == "table" then
    return type(err.message) == "string" and err.message or tostring(err.code or err)
  end
  return tostring(err)
end

local function canonical(path)
  return session_store.canonicalize(path)
end

local function current_root(rt)
  if rt.root and rt.root ~= "" then
    return rt.root
  end
  local configured = rt.config.project and rt.config.project.root
  if type(configured) == "string" and configured ~= "" then
    return canonical(configured)
  end
  return canonical(vim.fn.getcwd())
end

local function current_ui()
  return require("opencode.ui")
end

local function current_renderer()
  return require("opencode.render")
end

local function current_completion()
  return require("opencode.completion.core")
end

local function current_status()
  return require("opencode.status")
end

local function current_keybindings()
  local ok, module = pcall(require, "opencode.keybindings")
  if ok and type(module) == "table" then
    return module
  end
  return nil
end

local function current_session_action()
  local ok, module = pcall(require, "opencode.actions.session")
  if ok and type(module) == "table" then
    return module
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Tool server (optional companion side)
-- ---------------------------------------------------------------------------

local function random_token()
  local ok, bytes = pcall(function()
    local fd = uv.fs_open("/dev/urandom", "r", 0)
    if not fd then
      return nil
    end
    local data = uv.fs_read(fd, 32, 0)
    uv.fs_close(fd)
    return data
  end)
  if ok and type(bytes) == "string" and #bytes >= 16 then
    return (bytes:gsub(".", function(char)
      return ("%02x"):format(char:byte())
    end))
  end
  local seed = table.concat({
    tostring(uv.os_getpid()),
    tostring(uv.hrtime()),
    tostring(os.time()),
    tostring(math.random()),
    tostring({}),
  }, ":")
  return vim.fn.sha256(seed)
end

local function new_instance_id()
  return ("nvim-%d-%s"):format(uv.os_getpid(), tostring(uv.hrtime()):gsub("[^%w]", ""))
end

local function stop_tools(rt)
  local tools = rt.tools
  rt.tools = nil
  if not tools then
    return
  end
  if tools.server then
    pcall(tools.server.stop, tools.server)
  end
  if tools.instance_id then
    local registry = require("opencode.tools.registry")
    pcall(registry.unregister, tools.instance_id, tools.registry_opts)
  end
end

--- Start the local tool server for a project root. Never raises: companion
--- problems and bind failures are reported as non-blocking state.
local function start_tools(rt, root)
  if not (rt.config.tools and rt.config.tools.enabled) then
    return
  end
  if runtime ~= rt or not root or root == "" then
    return
  end
  if rt.tools and rt.tools.root == root and rt.tools.server and rt.tools.server:is_running() then
    return
  end
  stop_tools(rt)

  local ok_server, server = pcall(function()
    local module = require("opencode.tools.server")
    local open = require("opencode.tools.open")
    local notify_action = require("opencode.tools.notify")
    local diff = require("opencode.tools.diff")
    return module.new({
      token = random_token(),
      instance_id = rt.config.tools.instance_id or new_instance_id(),
      project_root = root,
      handlers = {
        open = open.handler({ project_root = root }),
        notify = notify_action.handler(),
        diff = diff.handler({ project_root = root }),
      },
    })
  end)
  if not ok_server then
    rt.tools = { error = { code = "tool_server_failed", message = error_message(server) }, root = root }
    return
  end

  local tools = {
    server = server,
    token = server.token,
    instance_id = server.instance_id,
    root = root,
    registry_opts = rt.config.tools.registry_dir and { dir = rt.config.tools.registry_dir } or nil,
  }
  rt.tools = tools

  server:start(function(start_err, info)
    if runtime ~= rt or rt.tools ~= tools then
      pcall(server.stop, server)
      return
    end
    if start_err then
      tools.error = { code = "tool_server_start_failed", message = tostring(start_err) }
      rt.tools = tools
      return
    end
    local registry = require("opencode.tools.registry")
    local path, register_err = registry.register({
      schema = registry.SCHEMA_VERSION,
      instance_id = tools.instance_id,
      project_root = root,
      url = info.url,
      token = tools.token,
      pid = uv.os_getpid(),
      started_at = os.time(),
    }, tools.registry_opts)
    if not path then
      tools.error = { code = "tool_registry_failed", message = tostring(register_err) }
      pcall(server.stop, server)
      return
    end
    tools.url = info.url
    tools.port = info.port
    tools.registry_path = path
  end)
end

-- ---------------------------------------------------------------------------
-- UI attachment
-- ---------------------------------------------------------------------------

local function completion_context(rt)
  local root = rt.root
  if not root then
    return { location = nil, session_id = rt.session_id }
  end
  return {
    location = { directory = root },
    directory = root,
    project_root = root,
    session_id = rt.session_id,
  }
end

local function status_snapshot(rt)
  if rt.state then
    return rt.state:get_status()
  end
  local snapshot = rt.session and rt.session:get_snapshot() or {}
  return {
    session = snapshot.session,
    project = snapshot.project,
    connection = "connecting",
    submission = snapshot.submission,
  }
end

local function report_keybinding_diagnostics(rt, diagnostics)
  for _, item in ipairs(diagnostics or {}) do
    if item.level == "warn" or item.level == "error" then
      local key = tostring(item.code) .. "\0" .. tostring(item.message)
      if not rt.keybinding_seen[key] then
        rt.keybinding_seen[key] = true
        notify("OpenCode keybindings: " .. tostring(item.message), vim.log.levels.WARN)
      end
    end
  end
end

local function attach_buffer_keybindings(rt, buf)
  if not (rt.config.keybindings and rt.config.keybindings.enabled) then
    return
  end
  if not loaded_buf(buf) then
    return
  end
  local keybindings = current_keybindings()
  if not keybindings then
    return
  end
  if keybindings.is_attached(buf) and rt.keybinding_buffers[buf] then
    return
  end
  local action = current_session_action()
  local interrupt = function()
    if runtime ~= rt then
      return
    end
    if not action then
      notify("OpenCode interrupt is unavailable", vim.log.levels.ERROR)
      return
    end
    action.interrupt(rt.session, function(err, result)
      if runtime ~= rt then
        return
      end
      rt.last_interrupt = {
        err = copy(err),
        result = copy(result),
        at = os.time(),
      }
      if err ~= nil then
        notify("OpenCode interrupt failed: " .. error_message(err), vim.log.levels.ERROR)
        return
      end
      if result and result.interrupted == true then
        if rt.state then
          rt.state:set_execution("interrupted")
        end
        if rt.config.status.enabled then
          pcall(current_status().set_execution, "interrupted")
        end
      end
    end)
  end

  local opts = {
    actions = { ["session.interrupt"] = interrupt },
    read_cli = rt.config.keybindings.read_cli,
    overrides = rt.config.keybindings.overrides,
    sequence_timeout = rt.config.keybindings.sequence_timeout,
  }
  if rt.config.keybindings.cli_path ~= nil then
    opts.cli_path = rt.config.keybindings.cli_path
  end
  local ok, state, attach_err = pcall(keybindings.attach, buf, opts)
  if not ok then
    rt.keybinding_error = { code = "keybindings_failed", message = error_message(state) }
    return
  end
  if not state then
    rt.keybinding_error = attach_err
    return
  end
  rt.keybinding_buffers[buf] = true
  rt.keybinding_error = nil
  report_keybinding_diagnostics(rt, state.diagnostics)
end

local function attach_keybindings(rt, buffers)
  if not (rt.config.keybindings and rt.config.keybindings.enabled) then
    return
  end
  attach_buffer_keybindings(rt, buffers.messages)
  attach_buffer_keybindings(rt, buffers.input)
end

local function detach_component_buffers(rt)
  local keybindings = current_keybindings()
  if keybindings then
    for buf in pairs(rt.keybinding_buffers) do
      pcall(keybindings.detach, buf)
    end
  end
  rt.keybinding_buffers = {}
  if rt.completion_buffer then
    pcall(current_completion().detach, rt.completion_buffer)
    rt.completion_buffer = nil
  end
  rt.completion_context_key = nil
end

--- Re-attach renderer/completion/status/keybindings to the current UI
--- buffers and windows. Cheap and idempotent; called after open/rebuild.
local function ensure_ui(rt)
  if runtime ~= rt then
    return
  end
  local ui = current_ui()
  if not ui.is_open() then
    return
  end
  local buffers = ui.get_buffers()
  local windows = ui.get_windows()

  local renderer = current_renderer()
  if loaded_buf(buffers.messages) and valid_win(windows.messages) then
    if not renderer.is_attached() or renderer.get_buffer() ~= buffers.messages then
      pcall(renderer.attach, {
        buffer = buffers.messages,
        window = windows.messages,
        lookup = rt.state,
      })
      if rt.state then
        pcall(renderer.reset, rt.state:get_blocks(), rt.state)
      end
    elseif rt.renderer_window ~= windows.messages then
      pcall(renderer.attach_window, windows.messages)
    end
    rt.renderer_window = windows.messages
  end

  if rt.config.completion.enabled and loaded_buf(buffers.input) then
    local completion = current_completion()
    if rt.completion_buffer ~= buffers.input or not completion.is_attached(buffers.input) then
      if rt.completion_buffer and rt.completion_buffer ~= buffers.input then
        pcall(completion.detach, rt.completion_buffer)
      end
      local attached = completion.attach(buffers.input, {
        source = rt.source,
        context = completion_context(rt),
        auto = rt.config.completion.auto,
        minimum_length = rt.config.completion.minimum_length,
        debounce = rt.config.completion.debounce,
      })
      rt.completion_buffer = attached and buffers.input or nil
      rt.completion_context_key = nil
    end
    if rt.completion_buffer == buffers.input then
      local context = completion_context(rt)
      local context_key = tostring(context.session_id) .. "\0" .. tostring(rt.root)
      if rt.completion_context_key ~= context_key then
        rt.completion_context_key = context_key
        pcall(completion.refresh_context, buffers.input, context)
      end
    end
  end

  if rt.config.status.enabled and valid_win(windows.messages) and valid_win(windows.input) then
    local status = current_status()
    local changed = rt.status_windows == nil
      or rt.status_windows.messages ~= windows.messages
      or rt.status_windows.input ~= windows.input
    if changed then
      pcall(status.attach, {
        message_window = windows.messages,
        input_window = windows.input,
        submit_hint = rt.config.status.submit_hint,
        spinner_interval = rt.config.status.spinner_interval,
      })
      rt.status_windows = { messages = windows.messages, input = windows.input }
    end
    local snapshot = status_snapshot(rt)
    local generation = rt.state and rt.state.model and rt.state.model.generation or nil
    pcall(status.update, snapshot, generation and { generation = generation } or nil)
  end

  attach_keybindings(rt, buffers)
end

-- ---------------------------------------------------------------------------
-- Session / synchronization
-- ---------------------------------------------------------------------------

local function stop_sync(rt)
  if rt.syncer then
    pcall(rt.syncer.stop, rt.syncer)
  end
  rt.syncer = nil
  if rt.unsubscribe then
    pcall(rt.unsubscribe)
  end
  rt.unsubscribe = nil
  if rt.state then
    pcall(rt.state.destroy, rt.state)
  end
  rt.state = nil
  rt.session_id = nil
  rt.root = nil
  if current_renderer().is_attached() then
    pcall(current_renderer().reset, {})
  end
end

local function invalidate_completion_from_events(rt, events)
  if not rt.source then
    return
  end
  for _, event in ipairs(events or {}) do
    local kind = type(event) == "table" and event.type or nil
    if type(kind) == "string" then
      if kind == "command.updated" or kind == "command.list" then
        pcall(rt.source.invalidate, rt.source, "command")
      elseif kind == "agent.updated" or kind == "agent.list" then
        pcall(rt.source.invalidate, rt.source, "agent")
      elseif kind == "skill.updated" or kind == "skill.list" then
        pcall(rt.source.invalidate, rt.source, "skill")
      elseif kind == "file.edited" or kind == "file.watcher.updated" or kind == "file.list" then
        pcall(rt.source.invalidate, rt.source, "file")
      end
    end
  end
end

local function on_state_change(rt, change)
  if runtime ~= rt then
    return
  end
  local renderer = current_renderer()
  if renderer.is_attached() then
    pcall(renderer.apply_change, change)
  end
  if rt.config.status.enabled and change.status then
    local generation = change.generation
    pcall(current_status().update, change.status, generation and { generation = generation } or nil)
  end
end

local function on_connection(rt, value)
  if runtime ~= rt then
    return
  end
  local connection = value
  if value == "synced" then
    connection = "connected"
  elseif value == "disconnected" then
    connection = "reconnecting"
  end
  if rt.state then
    rt.state:set_connection(connection)
  elseif rt.config.status.enabled then
    pcall(current_status().set_connection, connection)
  end
end

local function start_sync(rt, id, root)
  if runtime ~= rt then
    return
  end
  stop_sync(rt)
  if rt.config.status.enabled then
    -- Generations are scoped to one synchronizer. Reset the status display so
    -- a new session's generation 1 is not rejected as stale.
    pcall(current_status().detach, { reset = true })
    rt.status_windows = nil
  end

  local state_mod = require("opencode.state")
  local sync = require("opencode.sync")
  local state_object = state_mod.new({
    session = { id = id },
    project = root and { root = root } or nil,
    location = root and { directory = root } or nil,
  })
  rt.state = state_object
  rt.session_id = id
  rt.root = root

  rt.unsubscribe = state_object:subscribe(function(change)
    on_state_change(rt, change)
  end)
  state_object:update({
    session = { id = id },
    project = root and { root = root } or nil,
    location = root and { directory = root } or nil,
    connection = "connecting",
  })

  local syncer, sync_err = sync.new({
    client = rt.client,
    session_id = id,
    location = root and { directory = root } or nil,
    on_batch = function(batch)
      if runtime ~= rt or rt.state ~= state_object then
        return
      end
      state_object:apply_batch(batch)
      invalidate_completion_from_events(rt, batch.events)
    end,
    on_error = function(err)
      if runtime ~= rt then
        return
      end
      rt.last_sync_error = copy(err)
      if type(err) == "table" and (err.phase == "history" or err.phase == "stream") then
        if rt.state then
          rt.state:set_connection("reconnecting")
        elseif rt.config.status.enabled then
          pcall(current_status().set_connection, "reconnecting")
        end
      end
    end,
    on_connection = function(value)
      on_connection(rt, value)
    end,
  })
  if not syncer then
    rt.last_sync_error = sync_err
    notify("OpenCode sync failed: " .. error_message(sync_err), vim.log.levels.WARN)
    return
  end
  rt.syncer = syncer
  local ok, start_err = syncer:start()
  if not ok then
    rt.last_sync_error = start_err
    notify("OpenCode sync failed: " .. error_message(start_err), vim.log.levels.WARN)
    return
  end
  ensure_ui(rt)
end

local function ensure_session(rt, callback)
  if runtime ~= rt then
    if callback then
      callback({ code = "stale_runtime", message = "OpenCode runtime is no longer active" })
    end
    return
  end
  rt.session:ensure(function(err, snapshot)
    if runtime ~= rt then
      return
    end
    if err ~= nil then
      rt.last_session_error = copy(err)
      if rt.state then
        rt.state:set_connection("offline")
      elseif rt.config.status.enabled then
        pcall(current_status().set_connection, "offline")
      end
      if callback then
        callback(err)
      end
      return
    end
    rt.last_session_error = nil
    local session = snapshot.session or {}
    local id = session.id
    local root = snapshot.project and snapshot.project.root or session.directory or current_root(rt)
    if not id then
      local missing = { code = "session_missing", message = "OpenCode returned no session id" }
      rt.last_session_error = missing
      if callback then
        callback(missing)
      end
      return
    end
    rt.session_snapshot = snapshot
    if id ~= rt.session_id or not rt.syncer then
      start_sync(rt, id, root)
    elseif rt.state then
      rt.state:update({
        session = session,
        project = snapshot.project,
        location = root and { directory = root } or nil,
      })
    end
    start_tools(rt, root)
    ensure_ui(rt)
    if callback then
      callback(nil, snapshot)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Submission
-- ---------------------------------------------------------------------------

local function selected_input(rt, text)
  if not (rt.config.completion and rt.config.completion.enabled) then
    return text
  end
  local ui = current_ui()
  local input_buf = ui.get_buffers().input
  if not loaded_buf(input_buf) then
    return text
  end
  local completion = current_completion()
  local candidate = completion.get_selected(input_buf)
  if type(candidate) ~= "table" then
    return text
  end
  local metadata = type(candidate.metadata) == "table" and candidate.metadata or {}
  local matched = false
  if candidate.kind == "command" then
    local name = metadata.name
    matched = type(name) == "string"
      and text:match("^%s*/" .. vim.pesc(name) .. "%s") ~= nil
  elseif type(metadata.mention_text) == "string" and metadata.mention_text ~= "" then
    matched = text:find(metadata.mention_text, 1, true) ~= nil
  end
  if not matched then
    return text
  end
  local input, build_err = rt.source:build_submission(candidate, {
    text = text,
    cursor = #text,
    start_col = metadata.start_col,
    location = rt.root and { directory = rt.root } or nil,
  })
  if not input then
    rt.last_completion_error = build_err
    return text
  end
  return input
end

local function submit_text(rt, text, done)
  ensure_session(rt, function(session_err)
    if session_err ~= nil then
      done(session_err)
      return
    end
    if rt.state then
      rt.state:set_submission("submitting")
    end
    if rt.config.status.enabled then
      pcall(current_status().set_submission, "submitting")
    end
    local input = selected_input(rt, text)
    rt.session:submit(input, function(err, result)
      if runtime ~= rt then
        done(err or { code = "stale_runtime", message = "OpenCode runtime is no longer active" })
        return
      end
      if err ~= nil then
        if rt.state then
          rt.state:set_submission("failed", err)
        end
        if rt.config.status.enabled then
          pcall(current_status().set_submission, "failed", { error = err })
        end
        done(err)
        return
      end
      if rt.state then
        rt.state:set_submission("idle")
      end
      if rt.config.status.enabled then
        pcall(current_status().set_submission, "idle")
      end
      rt.last_submission = copy(result)
      done(nil)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Keymaps / commands / autocmds
-- ---------------------------------------------------------------------------

local function uninstall_keymaps(rt)
  for _, mapping in ipairs(rt.mappings or {}) do
    local current = vim.fn.maparg(mapping.lhs, mapping.mode, false, true)
    if type(current) == "table" and current.desc == mapping.desc then
      pcall(vim.keymap.del, mapping.mode, mapping.lhs)
    end
  end
  rt.mappings = {}
end

local function install_keymap(rt, mode, lhs, callback, desc)
  if lhs == false or lhs == nil or lhs == "" then
    return
  end
  local ok = pcall(vim.keymap.set, mode, lhs, callback, {
    silent = true,
    desc = desc,
  })
  if ok then
    rt.mappings[#rt.mappings + 1] = { mode = mode, lhs = lhs, desc = desc }
  end
end

local function install_keymaps(rt)
  local keymaps = rt.config.keymaps or {}
  install_keymap(rt, "n", keymaps.toggle, function()
    M.toggle()
  end, KEYMAP_DESC.toggle)
  install_keymap(rt, "x", keymaps.send_selection, function()
    require("opencode.actions.selection").send_selection()
  end, KEYMAP_DESC.send_selection)
  install_keymap(rt, "x", keymaps.question_selection, function()
    require("opencode.actions.selection").question_selection()
  end, KEYMAP_DESC.question_selection)
end

local function install_commands(rt)
  local function command(name, fn, opts)
    opts = opts or {}
    opts.force = true
    pcall(vim.api.nvim_create_user_command, name, fn, opts)
  end
  command("OpenCode", function(args)
    local sub = vim.trim(args.args or "")
    if sub == "" or sub == "toggle" then
      M.toggle()
    elseif sub == "open" then
      M.open()
    elseif sub == "close" then
      M.close()
    elseif sub == "submit" then
      M.submit()
    elseif sub == "interrupt" then
      M.interrupt()
    elseif sub == "reset" then
      M.reset_session()
    elseif sub == "health" then
      M.print_health()
    else
      notify("OpenCode: unknown subcommand: " .. sub, vim.log.levels.WARN)
    end
  end, {
    nargs = "?",
    complete = function()
      return { "toggle", "open", "close", "submit", "interrupt", "reset", "health" }
    end,
    desc = "OpenCode client",
  })
  command("OpenCodeToggle", function()
    M.toggle()
  end, { desc = "Toggle the OpenCode sidebar" })
  command("OpenCodeSubmit", function()
    M.submit()
  end, { desc = "Submit the OpenCode input" })
  command("OpenCodeHealth", function()
    M.print_health()
  end, { desc = "Show OpenCode health information" })
  rt.commands = { "OpenCode", "OpenCodeToggle", "OpenCodeSubmit", "OpenCodeHealth" }
end

local function schedule_check(rt)
  vim.schedule(function()
    if runtime ~= rt then
      return
    end
    if current_ui().is_open() then
      ensure_ui(rt)
    end
  end)
end

local function install_autocmds(rt)
  local group = vim.api.nvim_create_augroup("OpencodeNvimIntegration", { clear = true })
  rt.augroup = group
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "WinClosed", "BufWipeout" }, {
    group = group,
    callback = function()
      schedule_check(rt)
    end,
  })
end

local function install_exit_handler(rt)
  local group = vim.api.nvim_create_augroup("OpencodeNvimExit", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.stop()
    end,
  })
  rt.exit_group = group
end

-- ---------------------------------------------------------------------------
-- Runtime lifecycle
-- ---------------------------------------------------------------------------

local function teardown_runtime()
  local rt = runtime
  runtime = nil
  if not rt then
    return
  end
  stop_tools(rt)
  stop_sync(rt)
  if rt.session then
    pcall(rt.session.destroy, rt.session)
  end
  if rt.completion_buffer then
    pcall(current_completion().detach, rt.completion_buffer)
  end
  detach_component_buffers(rt)
  pcall(current_status().detach, { reset = true })
  pcall(current_renderer().detach)
  pcall(require("opencode.actions.selection")._reset)
  local ui = current_ui()
  pcall(ui.on_submit, nil)
  uninstall_keymaps(rt)
  if rt.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, rt.augroup)
  end
  if rt.exit_group then
    pcall(vim.api.nvim_del_augroup_by_id, rt.exit_group)
  end
end

local function new_runtime(cfg)
  local client = require("opencode.client").new({
    url = cfg.server.url,
    headers = cfg.server.headers,
  })
  local controller = require("opencode.session").setup({
    client = client,
    config = function()
      return resolved or cfg
    end,
  })
  local sources = require("opencode.completion.sources").new({
    client = client,
    session = controller,
    location = function()
      return current_root(runtime or { config = cfg })
    end,
    limit = cfg.completion.limit,
    cache_ttl = cfg.completion.cache_ttl,
    file_cache_ttl = cfg.completion.file_cache_ttl,
  })
  return {
    config = cfg,
    client = client,
    session = controller,
    source = sources,
    mappings = {},
    keybinding_buffers = {},
    keybinding_seen = {},
  }
end

--- Configure and fully assemble the plugin. Safe to call repeatedly; the
--- previous runtime, keymaps, tool registry entry and subscriptions are
--- replaced. Companion absence never makes setup fail.
--- @param opts table|nil
--- @return table resolved configuration
function M.setup(opts)
  teardown_runtime()
  resolved = config.resolve(opts)
  local rt = new_runtime(resolved)
  runtime = rt

  local ui = current_ui()
  ui.setup({
    sidebar = resolved.sidebar,
    keymaps = { submit = resolved.keymaps.submit },
  })
  require("opencode.actions.selection").setup({
    ui = ui,
    session = rt.session,
    submit_key = resolved.keymaps.submit,
    on_question = function()
      if runtime == rt then
        ensure_session(rt)
      end
    end,
  })
  ui.on_submit(function(text, done)
    if runtime ~= rt then
      done({ code = "stale_runtime", message = "OpenCode runtime is no longer active" })
      return
    end
    submit_text(rt, text, done)
  end)

  install_keymaps(rt)
  install_commands(rt)
  install_autocmds(rt)
  install_exit_handler(rt)

  if resolved.tools.enabled and resolved.project.root ~= nil then
    start_tools(rt, canonical(resolved.project.root))
  end
  if ui.is_open() then
    ensure_ui(rt)
    ensure_session(rt)
  end
  return resolved
end

--- Return the active configuration, resolving defaults on first use.
--- @return table
function M.get_config()
  if resolved == nil then
    resolved = config.resolve(nil)
  end
  return resolved
end

local function ensure_runtime()
  if runtime == nil then
    M.setup(nil)
  end
  return runtime
end

--- Open the sidebar, ensure a session and attach all UI components.
function M.open()
  local rt = ensure_runtime()
  current_ui().open()
  ensure_ui(rt)
  ensure_session(rt)
  return true
end

--- Close the sidebar. Session subscriptions stay alive; reopening reattaches.
function M.close()
  current_ui().close()
  return true
end

function M.toggle()
  if current_ui().is_open() then
    return M.close()
  end
  return M.open()
end

function M.is_open()
  return current_ui().is_open()
end

--- Submit the current sidebar draft. The UI clears the draft only after the
--- server accepts the request.
--- @return boolean
function M.submit()
  local rt = ensure_runtime()
  local ui = current_ui()
  if not ui.is_open() then
    M.open()
  end
  if runtime ~= rt then
    return false
  end
  return ui.submit()
end

--- Ensure the current-project session exists and its synchronizer is running.
--- @param callback fun(err: table|nil, snapshot: table|nil)|nil
function M.ensure(callback)
  local rt = ensure_runtime()
  ensure_session(rt, callback)
end

--- Interrupt the current execution through the session action layer.
--- @param opts table|fun(err: table|nil, result: table|nil)|nil
--- @param callback fun(err: table|nil, result: table|nil)|nil
function M.interrupt(opts, callback)
  if type(opts) == "function" and callback == nil then
    callback = opts
    opts = nil
  end
  local rt = ensure_runtime()
  local action = current_session_action()
  if not action then
    if callback then
      callback({ code = "interrupt_unavailable", message = "session action is unavailable" })
    end
    return
  end
  if opts == nil then
    action.interrupt(rt.session, callback)
    return
  end
  -- Preserve the session action wrapper while forwarding interrupt options.
  local original = rt.session.interrupt
  rt.session.interrupt = function(_, done)
    return original(rt.session, opts, done)
  end
  local ok, err = pcall(action.interrupt, rt.session, callback)
  rt.session.interrupt = original
  if not ok and callback then
    callback({ code = "interrupt_failed", message = tostring(err) })
  end
end

--- Drop the current session and create/restore a fresh one. The old syncer is
--- stopped before the new session is requested.
function M.reset_session()
  local rt = ensure_runtime()
  stop_sync(rt)
  rt.session_snapshot = nil
  rt.last_interrupt = nil
  rt.session:reset()
  if rt.config.status.enabled then
    pcall(current_status().detach, { reset = true })
  end
  if current_ui().is_open() then
    ensure_ui(rt)
    ensure_session(rt)
  end
end

--- Start the local tool server for the current project (idempotent).
function M.start_tools()
  local rt = ensure_runtime()
  local root = current_root(rt)
  start_tools(rt, root)
  return rt.tools
end

--- Stop the local tool server and unregister its instance.
function M.stop_tools()
  if runtime then
    stop_tools(runtime)
  end
end

--- Stop all runtime resources. Safe to call more than once.
function M.stop()
  teardown_runtime()
end

--- Return a redacted, test-friendly snapshot of the assembled runtime.
--- @return table
function M.get_state()
  if runtime == nil then
    return { configured = false, config = resolved }
  end
  local rt = runtime
  local ui = current_ui()
  local session = rt.session:get_snapshot()
  local status_object = rt.state and rt.state:get_status() or nil
  local tools = nil
  if rt.tools then
    tools = {
      running = rt.tools.server ~= nil and rt.tools.server:is_running() or false,
      url = rt.tools.url,
      port = rt.tools.port,
      root = rt.tools.root,
      instance_id = rt.tools.instance_id,
      registry_path = rt.tools.registry_path,
      error = copy(rt.tools.error),
    }
  end
  local keybindings = current_keybindings()
  local keybinding_info = nil
  if keybindings then
    local message_state = loaded_buf(ui.get_buffers().messages)
      and keybindings.get_state(ui.get_buffers().messages) or nil
    keybinding_info = {
      message = message_state ~= nil,
      input = keybindings.is_attached(ui.get_buffers().input),
      diagnostics = message_state and copy(message_state.diagnostics) or {},
      error = copy(rt.keybinding_error),
    }
  end
  return {
    configured = true,
    config = rt.config,
    session = session,
    session_id = rt.session_id,
    root = rt.root,
    sync = rt.syncer and rt.syncer:get_state() or nil,
    status = status_object,
    blocks = rt.state and rt.state:get_blocks() or {},
    ui = {
      open = ui.is_open(),
      buffers = ui.get_buffers(),
      windows = ui.get_windows(),
    },
    completion = {
      attached = rt.completion_buffer ~= nil
        and current_completion().is_attached(rt.completion_buffer) or false,
      buffer = rt.completion_buffer,
      candidates = rt.completion_buffer
        and current_completion().get_candidates(rt.completion_buffer) or {},
      selected = rt.completion_buffer
        and current_completion().get_selected(rt.completion_buffer) or nil,
    },
    keybindings = keybinding_info,
    tools = tools,
    last_submission = copy(rt.last_submission),
    last_interrupt = copy(rt.last_interrupt),
    last_sync_error = copy(rt.last_sync_error),
    last_session_error = copy(rt.last_session_error),
  }
end

--- Health-style information including OpenCode keybinding diagnostics. The
--- core :checkhealth output lives in opencode.health; this entry point keeps
--- 08A's non-blocking diagnostics available without changing that module.
--- @return table[] { level, message }
function M.health()
  local results = require("opencode.health").collect()
  local keybindings = current_keybindings()
  local cfg = M.get_config()
  if not keybindings then
    results[#results + 1] = {
      level = "info",
      message = "OpenCode semantic keybindings are not installed",
    }
  elseif not cfg.keybindings.enabled then
    results[#results + 1] = {
      level = "info",
      message = "OpenCode semantic keybindings are disabled",
    }
  else
    local ok, diagnostics = pcall(keybindings.health, {
      cli_path = cfg.keybindings.cli_path,
      read_cli = cfg.keybindings.read_cli,
      overrides = cfg.keybindings.overrides,
      sequence_timeout = cfg.keybindings.sequence_timeout,
    })
    if not ok then
      results[#results + 1] = {
        level = "warn",
        message = "cannot resolve OpenCode keybindings: " .. tostring(diagnostics),
      }
    else
      for _, item in ipairs(diagnostics) do
        results[#results + 1] = {
          level = item.level,
          message = "keybindings: " .. item.message,
        }
      end
    end
  end
  if runtime and runtime.tools and runtime.tools.error then
    results[#results + 1] = {
      level = "warn",
      message = "tool server: " .. error_message(runtime.tools.error),
    }
  end
  return results
end

--- Print M.health() to the command line.
function M.print_health()
  for _, item in ipairs(M.health()) do
    local line = ("[opencode] %s: %s"):format(item.level, item.message)
    if item.level == "error" then
      vim.api.nvim_err_writeln(line)
    else
      vim.api.nvim_out_write(line .. "\n")
    end
  end
end

--- Read, write and submit helpers used by integration tests and small user
--- mappings. They intentionally delegate to the UI.
function M.set_draft(text)
  return current_ui().set_draft(text)
end

function M.get_draft()
  return current_ui().get_draft()
end

function M.send_selection(opts)
  return require("opencode.actions.selection").send_selection(opts)
end

function M.question_selection(opts)
  return require("opencode.actions.selection").question_selection(opts)
end

return M
