-- OpenCode two-window sidebar.
--
-- The sidebar is made of two real Neovim windows: a read-only messages window
-- on top and a regular editable input window below.  Focus is managed by
-- Neovim's native window commands; this module never installs global mode
-- handlers or terminal key injection.
--
-- Integration points:
--   local ui = require("opencode.ui")
--   ui.setup({ width = 48, input_height = 8, keymaps = { submit = "<C-s>" } })
--   ui.on_submit(function(text, done) ... done(nil) end)
--   ui.open() -- or ui.toggle()
--   ui.get_buffers().messages / .input
--   ui.get_windows().messages / .input

local M = {}

local defaults = {
  width = 48,
  input_height = 8,
  submit = "<C-s>",
}

local state = {
  width = defaults.width,
  input_height = defaults.input_height,
  submit_key = defaults.submit,
  submit_callback = nil,
  mapped_submit_key = nil,
  submitting = false,
  open = false,
  message_buf = nil,
  input_buf = nil,
  message_win = nil,
  input_win = nil,
  draft = "",
  return_win = nil,
}

local function valid_buf(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function loaded_buf(buf)
  return valid_buf(buf) and vim.api.nvim_buf_is_loaded(buf)
end

local function buf_lines(buf)
  if not valid_buf(buf) then
    return {}
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok then
    return {}
  end
  return lines
end

local function buffer_text(buf)
  return table.concat(buf_lines(buf), "\n")
end

local function draft_from_buffer()
  if loaded_buf(state.input_buf) then
    local text = buffer_text(state.input_buf)
    state.draft = text
    return text
  end
  return state.draft
end

local function set_input_lines(text)
  if not loaded_buf(state.input_buf) then
    return
  end
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end
  local ok = pcall(vim.api.nvim_buf_set_lines, state.input_buf, 0, -1, false, lines)
  if ok then
    state.draft = text or ""
  end
end

local function set_message_options(buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "opencode_messages"
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function attach_draft_tracking(buf)
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if valid_buf(buf) then
        state.draft = buffer_text(buf)
      end
    end,
  })
end

local function ensure_input_mapping()
  local buf = state.input_buf
  if not valid_buf(buf) then
    return
  end

  local key = state.submit_key
  if state.mapped_submit_key and state.mapped_submit_key ~= key then
    for _, mode in ipairs({ "i", "n" }) do
      pcall(vim.keymap.del, mode, state.mapped_submit_key, { buffer = buf })
    end
    state.mapped_submit_key = nil
  end

  if key == false or key == nil or key == "" then
    return
  end
  if state.mapped_submit_key == key then
    return
  end

  for _, mode in ipairs({ "i", "n" }) do
    vim.keymap.set(mode, key, function()
      M.submit()
    end, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = "OpenCode: submit input",
    })
  end
  state.mapped_submit_key = key
end

local function ensure_message_mapping()
  local buf = state.message_buf
  if not valid_buf(buf) then
    return
  end

  -- Paging is deliberately buffer-local.  Native gg/G/visual/registers and
  -- fold commands stay untouched.
  local paging = {
    ["<C-d>"] = "\4",
    ["<C-u>"] = "\21",
    ["<C-f>"] = "\6",
    ["<C-b>"] = "\2",
  }
  for lhs, native in pairs(paging) do
    vim.keymap.set("n", lhs, function()
      local win = state.message_win
      if not valid_win(win) then
        win = vim.api.nvim_get_current_win()
      end
      if valid_win(win) then
        -- v:count is 0 when no count was typed; passing it through would turn
        -- default half/full-page scrolling into a one-line scroll.
        local count = vim.v.count
        local command = count > 0 and (tostring(count) .. native) or native
        vim.api.nvim_win_call(win, function()
          vim.cmd("normal! " .. command)
        end)
      end
    end, {
      buffer = buf,
      silent = true,
      desc = "OpenCode: scroll messages",
    })
  end
end

local function ensure_message_buffer()
  if loaded_buf(state.message_buf) then
    return
  end
  if valid_buf(state.message_buf) then
    -- Unloading a scratch buffer discards its lines; recreate it so callers
    -- never attach a renderer to a permanently unloaded buffer.
    pcall(vim.api.nvim_buf_delete, state.message_buf, { force = true })
  end

  local buf = vim.api.nvim_create_buf(false, true)
  state.message_buf = buf
  set_message_options(buf)
  ensure_message_mapping()
end

local function ensure_input_buffer()
  if loaded_buf(state.input_buf) then
    return
  end
  if valid_buf(state.input_buf) then
    -- An unloaded scratch buffer has already lost its lines; recreate it from
    -- the draft instead of leaving an empty editable area behind.
    pcall(vim.api.nvim_buf_delete, state.input_buf, { force = true })
  end

  local buf = vim.api.nvim_create_buf(false, true)
  state.input_buf = buf
  -- A recreated buffer needs its buffer-local mappings again.
  state.mapped_submit_key = nil
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "opencode_input"
  vim.bo[buf].modifiable = true
  vim.bo[buf].modified = false

  local draft = state.draft or ""
  if draft ~= "" then
    set_input_lines(draft)
  end

  attach_draft_tracking(buf)
  ensure_input_mapping()
  ensure_message_mapping()
end

local function ensure_buffers()
  ensure_message_buffer()
  ensure_input_buffer()
end

local function configure_window(win, is_input)
  if not valid_win(win) then
    return
  end
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = true
  vim.wo[win].winfixwidth = true
  vim.wo[win].list = false
  vim.wo[win].spell = false
  if is_input then
    vim.wo[win].winfixheight = true
  end
end

local function apply_sizes()
  if valid_win(state.message_win) then
    pcall(vim.api.nvim_win_set_width, state.message_win, state.width)
  end
  if valid_win(state.input_win) then
    pcall(vim.api.nvim_win_set_width, state.input_win, state.width)
    pcall(vim.api.nvim_win_set_height, state.input_win, state.input_height)
  end
end

local function remember_return_window(win)
  if valid_win(win) and win ~= state.message_win and win ~= state.input_win then
    state.return_win = win
  end
end

local function is_sidebar_window(win)
  return win == state.message_win or win == state.input_win
end

local function window_shows(win, buf)
  return valid_win(win) and loaded_buf(buf) and vim.api.nvim_win_get_buf(win) == buf
end

-- Create or repair the two-window layout without creating duplicate windows.
local function ensure_layout()
  ensure_buffers()

  if not valid_win(state.message_win) then
    if valid_win(state.input_win) then
      state.message_win = vim.api.nvim_open_win(state.message_buf, false, {
        split = "above",
        win = state.input_win,
      })
    else
      local origin = state.return_win
      if not valid_win(origin) or is_sidebar_window(origin) then
        origin = vim.api.nvim_get_current_win()
      end
      remember_return_window(origin)
      state.message_win = vim.api.nvim_open_win(state.message_buf, true, {
        split = "right",
        win = origin,
      })
    end
    configure_window(state.message_win, false)
  end

  if not valid_win(state.input_win) then
    state.input_win = vim.api.nvim_open_win(state.input_buf, true, {
      split = "below",
      win = state.message_win,
    })
    configure_window(state.input_win, true)
  end

  if vim.api.nvim_win_get_buf(state.message_win) ~= state.message_buf then
    vim.api.nvim_win_set_buf(state.message_win, state.message_buf)
  end
  if vim.api.nvim_win_get_buf(state.input_win) ~= state.input_buf then
    vim.api.nvim_win_set_buf(state.input_win, state.input_buf)
  end

  apply_sizes()
  state.open = true
end

function M.setup(opts)
  opts = opts or {}
  if opts.width ~= nil then
    assert(type(opts.width) == "number" and opts.width > 0, "sidebar width must be a positive number")
    state.width = opts.width
  end
  if opts.input_height ~= nil then
    assert(type(opts.input_height) == "number" and opts.input_height > 0, "sidebar input_height must be a positive number")
    state.input_height = opts.input_height
  end

  if opts.sidebar then
    if opts.sidebar.width ~= nil then
      assert(type(opts.sidebar.width) == "number" and opts.sidebar.width > 0, "sidebar width must be a positive number")
      state.width = opts.sidebar.width
    end
    if opts.sidebar.input_height ~= nil then
      assert(type(opts.sidebar.input_height) == "number" and opts.sidebar.input_height > 0, "sidebar input_height must be a positive number")
      state.input_height = opts.sidebar.input_height
    end
  end

  local key = opts.submit
  if opts.keymaps and opts.keymaps.submit ~= nil then
    key = opts.keymaps.submit
  end
  if key ~= nil then
    assert(key == false or type(key) == "string", "submit keymap must be a string or false")
    state.submit_key = key
  end

  if state.open or valid_buf(state.input_buf) then
    ensure_input_mapping()
  end
  if state.open then
    apply_sizes()
  end
  return M
end

function M.open()
  local current = vim.api.nvim_get_current_win()
  if valid_win(current) and not is_sidebar_window(current) then
    remember_return_window(current)
  end
  ensure_layout()
  M.focus_input()
  return true
end

function M.close()
  local current = vim.api.nvim_get_current_win()
  local target = state.return_win
  local focus_target = valid_win(target) and not is_sidebar_window(target) and target or nil

  if valid_win(state.input_win) then
    pcall(vim.api.nvim_win_close, state.input_win, true)
  end
  if valid_win(state.message_win) then
    pcall(vim.api.nvim_win_close, state.message_win, true)
  end
  state.input_win = nil
  state.message_win = nil
  state.open = false

  if valid_win(current) and not is_sidebar_window(current) then
    focus_target = current
  end
  if focus_target and valid_win(focus_target) then
    pcall(vim.api.nvim_set_current_win, focus_target)
  end
  return true
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.is_open()
  -- A wiped, unloaded or replaced buffer can leave the windows valid while the
  -- sidebar is no longer usable; report that as closed so toggle/open repairs it.
  return window_shows(state.message_win, state.message_buf)
    and window_shows(state.input_win, state.input_buf)
end

function M.focus_input()
  if not M.is_open() then
    remember_return_window(vim.api.nvim_get_current_win())
    ensure_layout()
  end
  if valid_win(state.input_win) then
    vim.api.nvim_set_current_win(state.input_win)
    return true
  end
  return false
end

function M.focus_messages()
  if not M.is_open() then
    remember_return_window(vim.api.nvim_get_current_win())
    ensure_layout()
  end
  if valid_win(state.message_win) then
    vim.api.nvim_set_current_win(state.message_win)
    return true
  end
  return false
end

function M.get_buffers()
  ensure_buffers()
  return {
    messages = state.message_buf,
    message = state.message_buf,
    message_buffer = state.message_buf,
    input = state.input_buf,
    input_buffer = state.input_buf,
  }
end

function M.get_windows()
  return {
    messages = valid_win(state.message_win) and state.message_win or nil,
    message = valid_win(state.message_win) and state.message_win or nil,
    message_window = valid_win(state.message_win) and state.message_win or nil,
    input = valid_win(state.input_win) and state.input_win or nil,
    input_window = valid_win(state.input_win) and state.input_win or nil,
  }
end

function M.get_draft()
  return draft_from_buffer()
end

function M.set_draft(text)
  text = text or ""
  state.draft = text
  if valid_buf(state.input_buf) then
    set_input_lines(text)
  end
  return text
end

function M.append_draft(text)
  text = text or ""
  local current = M.get_draft()
  if text == "" then
    return current
  end
  if current ~= "" and not current:match("\n$") then
    current = current .. "\n"
  end
  return M.set_draft(current .. text)
end

function M.on_submit(callback)
  assert(callback == nil or type(callback) == "function", "on_submit expects a function or nil")
  state.submit_callback = callback
end

-- Submit the current draft.  The callback receives (text, done); calling
-- done(nil) or done(false) means the server accepted the input.  The draft is
-- cleared only after acceptance and only when it was not edited meanwhile.
function M.submit()
  if state.submitting then
    return false
  end
  local text = M.get_draft()
  if text:match("^%s*$") then
    return false
  end
  local callback = state.submit_callback
  if not callback then
    return false
  end

  state.submitting = true
  local finished = false
  local function done(err)
    if finished then
      return
    end
    finished = true
    state.submitting = false
    if err == nil or err == false then
      if M.get_draft() == text then
        M.set_draft("")
      end
    end
  end

  local ok, err = pcall(callback, text, done)
  if not ok then
    if not finished then
      finished = true
      state.submitting = false
    end
    error(err)
  end
  return true
end

-- Test/maintenance helper: reset only this module's resources.  Buffers and
-- windows created by the user are left alone.
function M._reset()
  M.close()
  if valid_buf(state.message_buf) then
    pcall(vim.api.nvim_buf_delete, state.message_buf, { force = true })
  end
  if valid_buf(state.input_buf) then
    pcall(vim.api.nvim_buf_delete, state.input_buf, { force = true })
  end
  state.message_buf = nil
  state.input_buf = nil
  state.draft = ""
  state.submit_callback = nil
  state.mapped_submit_key = nil
  state.submitting = false
  state.return_win = nil
  state.width = defaults.width
  state.input_height = defaults.input_height
  state.submit_key = defaults.submit
end

return M
