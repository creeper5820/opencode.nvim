-- Embedded official OpenCode TUI terminal.
--
-- Neovim owns only the PTY lifecycle and window visibility.  The official
-- `opencode` process remains the sole renderer, composer and viewport owner.
-- Hiding the window keeps the job alive; `stop()` terminates only the job this
-- module started.

local uv = vim.uv or vim.loop

local M = {}

local Terminal = {}
Terminal.__index = Terminal

local function valid_buf(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function error_message(err)
  if type(err) == "table" then
    return type(err.message) == "string" and err.message or tostring(err)
  end
  return tostring(err)
end

local function normalize_cmd(cmd)
  if type(cmd) == "string" then
    return { cmd }
  end
  return vim.deepcopy(cmd)
end

local function absolute_directory(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local expanded = vim.fn.expand(path)
  if vim.fn.isdirectory(expanded) ~= 1 then
    return nil, ("directory %q does not exist"):format(path)
  end
  return (vim.fn.fnamemodify(expanded, ":p"):gsub("/$", ""))
end

--- Build the argv used to start the official TUI.
--- @param opts table|nil Per-open options: directory, session, continue, prompt, args
--- @param config table|nil Resolved plugin configuration
--- @return string[] cmd
--- @return string cwd
--- @return table|nil error
function M.build_command(opts, config)
  opts = opts or {}
  config = config or {}
  local session = config.session or {}
  local cmd = normalize_cmd(config.cmd or "opencode")
  if type(cmd) ~= "table" or #cmd == 0 then
    return nil, nil, { code = "invalid_cmd", message = "cmd must be a non-empty string or list" }
  end

  for _, arg in ipairs(config.args or {}) do
    cmd[#cmd + 1] = arg
  end
  for _, arg in ipairs(opts.args or {}) do
    cmd[#cmd + 1] = arg
  end

  local session_id = opts.session
  if session_id == nil then
    session_id = opts.session_id
  end
  if session_id == nil then
    session_id = session.id
  end
  local continue = opts.continue
  if continue == nil then
    continue = session.continue
  end
  local prompt = opts.prompt
  if prompt == nil then
    prompt = session.prompt
  end

  if type(session_id) == "string" and session_id ~= "" then
    cmd[#cmd + 1] = "--session"
    cmd[#cmd + 1] = session_id
  elseif continue then
    cmd[#cmd + 1] = "--continue"
  end
  if type(prompt) == "string" and prompt ~= "" then
    cmd[#cmd + 1] = "--prompt"
    cmd[#cmd + 1] = prompt
  end

  local directory = opts.directory or opts.cwd or config.cwd or (config.project and config.project.root)
  local cwd
  if directory == nil or directory == "" then
    cwd = vim.fn.getcwd()
  else
    local resolved, dir_error = absolute_directory(directory)
    if not resolved then
      return nil, nil, { code = "invalid_directory", message = dir_error }
    end
    cwd = resolved
  end
  cmd[#cmd + 1] = cwd

  return cmd, cwd, nil
end

--- Create one terminal controller.  The plugin owns one controller per setup.
--- @param opts table|nil
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    config = opts.config or {},
    notify = opts.notify,
    on_exit = opts.on_exit,
    env = opts.env,
    state = {
      buf = nil,
      win = nil,
      job = nil,
      chan = nil,
      pid = nil,
      running = false,
      cwd = nil,
      cmd = nil,
      started_at = nil,
      exit_code = nil,
      generation = 0,
      stopping = false,
    },
    autocmds = {},
  }, Terminal)
end

function Terminal:_notify(message, level)
  local fn = self.notify
  if type(fn) == "function" then
    pcall(fn, message, level or vim.log.levels.INFO)
  end
end

function Terminal:_clear_autocmds()
  for _, id in ipairs(self.autocmds) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  self.autocmds = {}
end

function Terminal:_watch_window(win)
  if not valid_win(win) then
    return
  end
  if vim.fn.exists("##WinClosed") == 0 then
    return
  end
  local ok, id = pcall(vim.api.nvim_create_autocmd, "WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if self.state.win == win then
        self.state.win = nil
      end
    end,
  })
  if ok and id then
    self.autocmds[#self.autocmds + 1] = id
  end
end

function Terminal:_set_window_options(win)
  pcall(function()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].cursorline = false
    vim.wo[win].wrap = false
    vim.wo[win].list = false
    vim.wo[win].spell = false
  end)
end

function Terminal:_resize(win)
  local window = self.config.window or {}
  local layout = window.layout or "right"
  local size = window.size or 80
  if layout == "right" or layout == "left" then
    pcall(vim.api.nvim_win_set_width, win, math.max(1, math.min(size, vim.o.columns - 1)))
  else
    pcall(vim.api.nvim_win_set_height, win, math.max(1, math.min(size, vim.o.lines - 2)))
  end
end

function Terminal:_show_window()
  if valid_win(self.state.win) and vim.api.nvim_win_get_buf(self.state.win) == self.state.buf then
    pcall(vim.api.nvim_set_current_win, self.state.win)
    return self.state.win
  end
  self.state.win = nil
  if not valid_buf(self.state.buf) then
    return nil, "OpenCode terminal buffer is not valid"
  end

  local window = self.config.window or {}
  local layout = window.layout or "right"
  local command
  if layout == "right" then
    command = "botright vertical split"
  elseif layout == "left" then
    command = "topleft vertical split"
  elseif layout == "above" then
    command = "topleft split"
  else
    command = "botright split"
  end
  local ok, err = pcall(vim.cmd, command)
  if not ok then
    return nil, "cannot create OpenCode window: " .. error_message(err)
  end

  local win = vim.api.nvim_get_current_win()
  local buf_ok, buf_err = pcall(vim.api.nvim_win_set_buf, win, self.state.buf)
  if not buf_ok then
    pcall(vim.api.nvim_win_close, win, true)
    return nil, "cannot attach OpenCode buffer: " .. error_message(buf_err)
  end
  self.state.win = win
  self:_set_window_options(win)
  self:_resize(win)
  self:_watch_window(win)
  return win
end

--- Show and focus the terminal window, creating it if necessary.
--- @return boolean ok
--- @return string|nil error
function Terminal:focus()
  if not self:is_running() then
    return false, "OpenCode is not running"
  end
  local win, err = self:_show_window()
  if not win then
    return false, err
  end
  pcall(vim.api.nvim_set_current_win, win)
  return true
end

function Terminal:is_running()
  return self.state.running == true and self.state.job ~= nil and self.state.chan ~= nil
end

function Terminal:is_open()
  return valid_win(self.state.win)
    and self.state.win ~= nil
    and valid_buf(self.state.buf)
    and vim.api.nvim_win_get_buf(self.state.win) == self.state.buf
end

function Terminal:is_warm()
  local started = self.state.started_at
  if not started then
    return false
  end
  local delay = (self.config.paste and self.config.paste.ready_delay) or 0
  return (uv.hrtime() - started) / 1e6 >= delay
end

function Terminal:send(data)
  if type(data) ~= "string" then
    return false, "terminal input must be a string"
  end
  if not self:is_running() then
    return false, "OpenCode is not running"
  end
  local ok, err = pcall(vim.api.nvim_chan_send, self.state.chan, data)
  if not ok then
    return false, error_message(err)
  end
  return true
end

local function protect_paste(text)
  text = tostring(text or "")
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  text = text:gsub("%z", "")
  -- The bracketed-paste terminator must never appear inside pasted content.
  text = text:gsub("\27%[201~", "[201~")
  return text
end

--- Paste text into the TUI composer.  This never submits.
--- @param text string
--- @param opts table|nil { bracketed = boolean }
--- @return boolean ok
--- @return string|nil error
function Terminal:paste(text, opts)
  opts = opts or {}
  if self:is_running() and not self:is_warm() then
    local delay = (self.config.paste and self.config.paste.ready_delay) or 0
    local started = self.state.started_at or uv.hrtime()
    local remaining = delay - (uv.hrtime() - started) / 1e6
    if remaining > 0 then
      -- Let the freshly started TUI enter raw mode before injecting paste.
      -- This is a short, bounded UI wait, not a renderer loop.
      vim.wait(math.min(remaining, 1000))
    end
  end
  local value = protect_paste(text)
  local bracketed = opts.bracketed
  if bracketed == nil then
    bracketed = not (self.config.paste and self.config.paste.bracketed == false)
  end
  if bracketed then
    return self:send("\27[200~" .. value .. "\27[201~")
  end
  return self:send(value)
end

--- Submit the TUI composer with a distinct Enter event.
--- @param opts table|nil { delay = number }
--- @return boolean ok
function Terminal:submit(opts)
  opts = opts or {}
  local delay = opts.delay
  if delay == nil then
    delay = self.config.paste and self.config.paste.submit_delay or 0
  end
  if delay > 0 then
    local generation = self.state.generation
    vim.defer_fn(function()
      if self.state.generation == generation then
        self:send("\r")
      end
    end, delay)
    return true
  end
  return self:send("\r")
end

--- A channel-shaped object used by input routing and selection actions.
--- @return table|nil
function Terminal:channel()
  if not self:is_running() then
    return nil
  end
  local terminal = self
  return {
    kind = "terminal",
    terminal = terminal,
    send = function(_, data)
      return terminal:send(data)
    end,
    paste = function(_, text, opts)
      return terminal:paste(text, opts)
    end,
    submit = function(_, opts)
      return terminal:submit(opts)
    end,
    is_alive = function()
      return terminal:is_running()
    end,
  }
end

function Terminal:_cleanup_buffer()
  local buf = self.state.buf
  self.state.buf = nil
  if valid_buf(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

function Terminal:_on_exit(job, code)
  if self.state.job ~= job and self.state.job ~= nil then
    return
  end
  local was_stopping = self.state.stopping
  self.state.running = false
  self.state.job = nil
  self.state.chan = nil
  self.state.pid = nil
  self.state.exit_code = code
  self:_clear_autocmds()
  local win = self.state.win
  self.state.win = nil
  if valid_win(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end

  if not was_stopping then
    self:_notify(("OpenCode exited%s"):format(type(code) == "number" and (" (code " .. code .. ")") or ""),
      code == 0 and vim.log.levels.INFO or vim.log.levels.WARN)
    local callback = self.on_exit
    if type(callback) == "function" then
      pcall(callback, code, self:get_state())
    end
  end
  pcall(self._cleanup_buffer, self)
  self.state.generation = self.state.generation + 1
end

function Terminal:_spawn(cmd, cwd)
  local buf = vim.api.nvim_create_buf(false, true)
  if not valid_buf(buf) then
    return false, "cannot create OpenCode terminal buffer"
  end
  pcall(function()
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].undolevels = -1
  end)

  self.state.generation = self.state.generation + 1
  local generation = self.state.generation
  self.state.buf = buf
  self.state.cwd = cwd
  self.state.cmd = vim.deepcopy(cmd)
  self.state.exit_code = nil
  self.state.stopping = false

  local exit_callback = function(job, code)
    vim.schedule(function()
      if self.state.generation == generation then
        self:_on_exit(job, code)
      end
    end)
  end

  local opts = {
    cwd = cwd,
    on_exit = exit_callback,
  }
  if self.env ~= nil then
    opts.env = self.env
  end

  local ok, job = pcall(function()
    return vim.api.nvim_buf_call(buf, function()
      return vim.fn.termopen(cmd, opts)
    end)
  end)
  if not ok or type(job) ~= "number" or job <= 0 then
    self.state.buf = nil
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return false, "cannot start OpenCode: " .. error_message(job)
  end

  self.state.job = job
  -- In Neovim a job id is also its channel id for nvim_chan_send().
  self.state.chan = job
  self.state.pid = vim.fn.jobpid(job)
  self.state.running = self.state.chan ~= nil and self.state.chan > 0
  self.state.started_at = uv.hrtime()

  local win, win_err = self:_show_window()
  if not win then
    self:stop()
    return false, win_err
  end

  local ok_watch = pcall(vim.api.nvim_create_autocmd, "BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if self.state.buf == buf and self.state.running then
        self:stop()
      end
    end,
  })
  if ok_watch then
    -- The autocmd id is not needed for cleanup; BufWipeout is one-shot.
  end

  return true
end

--- Open the TUI or reveal the existing window.  A live job is never restarted
--- by this call; use `stop()` before opening with different session flags.
--- @param opts table|nil
--- @return boolean ok
--- @return string|nil error
function Terminal:open(opts)
  opts = opts or {}
  if self:is_running() then
    local win, err = self:_show_window()
    if not win then
      return false, err
    end
    return true
  end

  self:_clear_autocmds()
  if valid_buf(self.state.buf) then
    pcall(vim.api.nvim_buf_delete, self.state.buf, { force = true })
  end
  self.state.buf = nil
  self.state.win = nil

  local cmd, cwd, build_error = M.build_command(opts, self.config)
  if not cmd then
    return false, build_error and build_error.message or "cannot build OpenCode command"
  end
  local ok, err = self:_spawn(cmd, cwd)
  if not ok then
    return false, err
  end
  if opts.focus ~= false then
    self:focus()
  end
  return true
end

--- Hide the terminal window without stopping the OpenCode process.
function Terminal:close()
  if valid_win(self.state.win) then
    pcall(vim.api.nvim_win_close, self.state.win, true)
  end
  self.state.win = nil
  return true
end

--- Stop only the process owned by this controller and delete its buffer.
function Terminal:stop(opts)
  opts = opts or {}
  self.state.stopping = true
  local job = self.state.job
  local pid = self.state.pid
  self.state.generation = self.state.generation + 1

  if job and job > 0 then
    pcall(vim.fn.jobstop, job)
    local ok, code = pcall(vim.fn.jobwait, { job }, opts.timeout or 1000)
    if not ok then
      code = -1
    end
    if type(code) ~= "table" then
      code = { code }
    end
    if code[1] == -1 and pid and pid > 0 then
      pcall(uv.kill, pid, 15)
      vim.uv.sleep(20)
      local alive, result = pcall(uv.kill, pid, 0)
      if alive and result == 0 then
        pcall(uv.kill, pid, 9)
      end
    end
  end

  self:_clear_autocmds()
  if valid_win(self.state.win) then
    pcall(vim.api.nvim_win_close, self.state.win, true)
  end
  self.state.win = nil
  self.state.job = nil
  self.state.chan = nil
  self.state.pid = nil
  self.state.running = false
  self.state.stopping = false
  self.state.exit_code = nil
  self:_cleanup_buffer()
  return true
end

--- @return table
function Terminal:get_state()
  return {
    open = self:is_open(),
    running = self:is_running(),
    warm = self:is_warm(),
    buffer = self.state.buf,
    window = self.state.win,
    job = self.state.job,
    channel = self.state.chan,
    pid = self.state.pid,
    cwd = self.state.cwd,
    cmd = self.state.cmd and vim.deepcopy(self.state.cmd) or nil,
    started_at = self.state.started_at,
    exit_code = self.state.exit_code,
  }
end

M.Terminal = Terminal
M.build_command = M.build_command

return M
