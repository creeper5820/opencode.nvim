-- Convert completion candidates into OpenCode submit payloads.
--
-- Submission rules follow the OpenCode V2 TUI:
--
--   * plain text                    -> session.prompt(text)
--   * `/name arguments` (known)     -> session.submit({ kind = "command", ... })
--                                      or session.command(name, arguments)
--   * agent mention                 -> session.submit({
--                                        kind = "agent", text = ...,
--                                        agents = { { name = id, mention = ... } },
--                                      })
--   * skill mention                 -> session.submit({
--                                        kind = "skill", text = ...,
--                                        skills = { { id = id, mention = ... } },
--                                      })
--   * file mention                  -> session.submit({
--                                        kind = "prompt", text = ...,
--                                        files = { { uri = "file://...", name = ...,
--                                                    mention = ... } },
--                                      })
--
-- Mentions use byte offsets in the final Neovim buffer text.  The TUI uses
-- the same start/end/text triple for its prompt parts.  A command carrying
-- attachments is reported as unsupported because the frozen session.command
-- contract only forwards `name` and `text`; silently dropping structured
-- attachments would be incorrect.

local util = require("opencode.completion.sources.util")

local M = {}

--- @param value any
--- @return boolean
local function non_empty_list(value)
  return type(value) == "table" and #value > 0
end

--- Locate the last occurrence of `needle` in `text` before `cursor`.
--- @param text string
--- @param needle string
--- @param cursor integer|nil
--- @return integer|nil start zero-based byte offset
local function last_occurrence(text, needle, cursor)
  if type(needle) ~= "string" or needle == "" then
    return nil
  end
  local limit = type(cursor) == "number" and math.max(0, math.min(#text, math.floor(cursor))) or #text
  local prefix = text:sub(1, limit)
  local found = nil
  local init = 1
  while true do
    local position = prefix:find(needle, init, true)
    if not position then
      break
    end
    found = position
    init = position + 1
  end
  return found and found - 1 or nil
end

--- @param candidate table
--- @param opts table
--- @param kind string
--- @return string
local function mention_text(candidate, opts, kind)
  local metadata = type(candidate.metadata) == "table" and candidate.metadata or {}
  local value = metadata.mention_text
  if type(value) ~= "string" or value == "" then
    if type(candidate.text) == "string" then
      value = candidate.text:match("^@[^%s]+")
    end
  end
  if type(value) ~= "string" or value == "" then
    if kind == "agent" then
      local id = metadata.id or metadata.name
      if type(id) == "string" then
        value = "@" .. id
      end
    elseif kind == "skill" then
      if type(metadata.id) == "string" then
        value = "@" .. metadata.id
      end
    elseif kind == "file" or kind == "directory" then
      local name = metadata.name or metadata.path
      if type(name) == "string" then
        value = "@" .. name
      end
    end
  end
  return type(value) == "string" and value or ""
end

--- @param candidate table
--- @param opts table
--- @param kind string
--- @return table mention
local function build_mention(candidate, opts, kind)
  local metadata = type(candidate.metadata) == "table" and candidate.metadata or {}
  local text = mention_text(candidate, opts, kind)
  local start = opts.start_col
  if type(start) ~= "number" then
    start = metadata.start_col
  end
  if type(start) ~= "number" then
    start = last_occurrence(opts.text or candidate.text or "", text, opts.cursor)
  end
  if type(start) ~= "number" then
    start = 0
  end
  start = math.max(0, math.floor(start))
  return {
    start = start,
    ["end"] = start + #text,
    text = text,
  }
end

--- @param text string
--- @param name string
--- @return string arguments
local function command_arguments(text, name)
  local parsed_name, parsed_arguments = util.parse_command(text)
  if parsed_name == name then
    return parsed_arguments or ""
  end
  local prefix = "/" .. name
  if text:sub(1, #prefix) == prefix then
    local rest = text:sub(#prefix + 1)
    if rest:match("^[ \t\n]") then
      return rest:gsub("^[ \t\n]+", "")
    end
  end
  return ""
end

--- Build the structured input for a candidate.  `opts.text` is the final
--- prompt text after insertion and `opts.start_col` is the 0-based byte
--- column of the mention/command start (normally 07A's result start_col).
--- @param candidate table
--- @param opts table|nil
--- @return table|nil input
--- @return table|nil err
function M.build(candidate, opts)
  opts = opts or {}
  if type(candidate) ~= "table" then
    return nil, util.error("invalid_candidate", "completion candidate must be a table")
  end
  local metadata = type(candidate.metadata) == "table" and candidate.metadata or {}
  local kind = candidate.kind or metadata.type
  local text = opts.text
  if type(text) ~= "string" then
    text = candidate.text
  end
  if type(text) ~= "string" then
    return nil, util.error("invalid_candidate", "completion candidate has no text")
  end

  if kind == "command" then
    if non_empty_list(opts.files) or non_empty_list(opts.agents) or non_empty_list(opts.skills) then
      return nil, util.error(
        "unsupported_command_attachments",
        "the command session contract cannot carry files, agents or skills attachments"
      )
    end
    local name = metadata.name
    if type(name) ~= "string" or name == "" then
      local parsed = util.parse_command(text)
      name = parsed
    end
    if type(name) ~= "string" or name == "" then
      return nil, util.error("invalid_candidate", "command candidate has no name")
    end
    local arguments = opts.arguments
    if type(arguments) ~= "string" then
      arguments = command_arguments(text, name)
    end
    return {
      kind = "command",
      name = name,
      arguments = arguments,
      text = text,
    }
  end

  if kind == "agent" then
    local id = metadata.id or (type(metadata.attachment) == "table" and metadata.attachment.name) or candidate.name
    if type(id) ~= "string" or id == "" then
      id = type(candidate.text) == "string" and candidate.text:match("^@([^%s]+)") or nil
    end
    if type(id) ~= "string" or id == "" then
      return nil, util.error("invalid_candidate", "agent candidate has no id")
    end
    return {
      kind = "agent",
      text = text,
      agents = {
        {
          name = id,
          mention = build_mention(candidate, opts, kind),
        },
      },
    }
  end

  if kind == "skill" then
    local id = metadata.id or (type(metadata.attachment) == "table" and metadata.attachment.id) or candidate.name
    if type(id) ~= "string" or id == "" then
      id = type(candidate.text) == "string" and candidate.text:match("^@([^%s]+)") or nil
    end
    if type(id) ~= "string" or id == "" then
      return nil, util.error("invalid_candidate", "skill candidate has no id")
    end
    return {
      kind = "skill",
      text = text,
      skills = {
        {
          id = id,
          mention = build_mention(candidate, opts, kind),
        },
      },
    }
  end

  if kind == "file" or kind == "directory" then
    local candidate_path = metadata.path
    if type(candidate_path) ~= "string" and type(candidate.text) == "string" then
      candidate_path = candidate.text:match("^@([^%s]+)")
    end
    local is_directory = kind == "directory"
      or metadata.is_directory == true
      or metadata.file_type == "directory"
      or metadata.type == "directory"
    if is_directory then
      -- Directories are navigation entries in the TUI; they are not prompt
      -- attachments.  Keep the text as an ordinary prompt if submitted.
      return { kind = "prompt", text = text, directory = true }
    end
    local uri = metadata.uri
    if type(uri) ~= "string" or uri == "" then
      uri = type(metadata.attachment) == "table" and metadata.attachment.uri or nil
    end
    local absolute = metadata.absolute_path
    if (type(uri) ~= "string" or uri == "") and type(absolute) == "string" and absolute ~= "" then
      uri = util.file_uri(absolute)
    end
    if type(uri) ~= "string" or uri == "" then
      local directory = opts.location or opts.directory
      if type(directory) == "function" then
        local ok, value = pcall(directory)
        if ok then
          directory = value
        else
          directory = nil
        end
      end
      local directory_path = util.directory(directory)
      if directory_path and type(candidate_path) == "string" then
        uri = util.file_uri(util.absolute_path(directory_path, candidate_path))
      end
    end
    if type(uri) ~= "string" or uri == "" then
      return nil, util.error("invalid_candidate", "file candidate has no URI or path")
    end
    local name = metadata.name
    if type(name) ~= "string" or name == "" then
      name = candidate_path or text:gsub("^@", ""):gsub("%s+$", "")
    end
    local attachment = {
      uri = uri,
      name = name,
      mention = build_mention(candidate, opts, kind),
    }
    if type(metadata.description) == "string" and metadata.description ~= "" then
      attachment.description = metadata.description
    end
    return {
      kind = "prompt",
      text = text,
      files = { attachment },
    }
  end

  if kind == nil or kind == "text" or kind == "prompt" then
    return { kind = "prompt", text = text }
  end

  return nil, util.error("unsupported_kind", "unsupported completion kind: " .. tostring(kind))
end

--- @param session table
--- @param callback function
--- @return function
local function callback_of(callback)
  local completed = false
  return function(err, result)
    if completed then
      return
    end
    completed = true
    if type(callback) == "function" then
      callback(err, result)
    end
  end
end

--- Invoke a session method in either module style (`session.prompt(text, cb)`)
--- or controller style (`controller:prompt(text, cb)`).  Module functions have
--- one fewer parameter than controller methods because the controller passes
--- itself explicitly.
--- @param session table
--- @param name string
--- @param ... any
--- @return boolean ok
--- @return any result
local function invoke_session(session, name, ...)
  local method = session[name]
  if type(method) ~= "function" then
    return false, name .. " is not available"
  end
  local module_arity = ({ submit = 2, prompt = 2, command = 3 })[name]
  local ok, info = pcall(debug.getinfo, method, "u")
  if ok and type(info) == "table" then
    if info.isvararg or (module_arity ~= nil and info.nparams == module_arity) then
      return pcall(method, ...)
    end
  end
  return pcall(method, session, ...)
end

--- Route a built input through the frozen session API.  Plain prompts use
--- `session.prompt`; commands use `session.submit` (or `session.command`);
--- structured attachments require `session.submit`.
--- @param session table
--- @param input table
--- @param callback function
function M.route(session, input, callback)
  local finish = callback_of(callback)
  if type(session) ~= "table" then
    finish(util.error("invalid_session", "a session object is required for submission"))
    return
  end
  if type(input) ~= "table" then
    finish(util.error("invalid_input", "submission input must be a table"))
    return
  end

  local ok, err = pcall(function()
    if input.kind == "command" then
      if type(session.submit) == "function" then
        local called, failure = invoke_session(session, "submit", input, finish)
        if not called then
          error(failure)
        end
        return
      end
      if type(session.command) == "function" then
        local called, failure = invoke_session(session, "command", input.name, input.arguments, finish)
        if not called then
          error(failure)
        end
        return
      end
      error("session.submit or session.command is required for command input")
    end

    if non_empty_list(input.files) or non_empty_list(input.agents) or non_empty_list(input.skills) then
      if type(session.submit) ~= "function" then
        error("session.submit is required for structured attachments")
      end
      local called, failure = invoke_session(session, "submit", input, finish)
      if not called then
        error(failure)
      end
      return
    end

    if type(session.prompt) == "function" then
      local called, failure = invoke_session(session, "prompt", input.text, finish)
      if not called then
        error(failure)
      end
      return
    end
    if type(session.submit) == "function" then
      local called, failure = invoke_session(session, "submit", input.text, finish)
      if not called then
        error(failure)
      end
      return
    end
    error("session.prompt or session.submit is required for prompt input")
  end)
  if not ok then
    finish(util.error("unsupported_session", tostring(err)))
  end
end

--- Build and submit a completion candidate.
--- @param session table
--- @param candidate table
--- @param opts table|nil
--- @param callback function|nil
function M.submit(session, candidate, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}
  local input, err = M.build(candidate, opts)
  if not input then
    callback_of(callback)(err)
    return
  end
  M.route(session, input, callback)
end

--- @param names table|string[]|nil
--- @param name string
--- @return boolean
function M.known_command(names, name)
  if type(names) == "function" then
    local ok, value = pcall(names, name)
    return ok and value ~= nil and value ~= false
  end
  if type(names) ~= "table" then
    return false
  end
  if names[name] then
    return true
  end
  for _, value in ipairs(names) do
    if type(value) == "string" and value == name then
      return true
    end
    if type(value) == "table" and value.name == name then
      return true
    end
  end
  return false
end

--- Submit free-form text.  If the text starts with a known command, it is
--- routed as a command; otherwise it is a plain prompt.  `opts.command_names`
--- may be a name set, an array of names/command tables, or a predicate.
--- @param session table
--- @param text string
--- @param opts table|nil
--- @param callback function|nil
function M.submit_text(session, text, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}
  local finish = callback_of(callback)
  if type(text) ~= "string" then
    finish(util.error("invalid_input", "prompt text must be a string"))
    return
  end
  local name, arguments = util.parse_command(text)
  if name and name ~= "" and M.known_command(opts.command_names or opts.commands, name) then
    M.route(session, {
      kind = "command",
      name = name,
      arguments = arguments or "",
      text = text,
    }, finish)
    return
  end

  if type(session) == "table" and type(session.prompt) == "function" then
    local called, err = invoke_session(session, "prompt", text, finish)
    if not called then
      finish(util.error("unsupported_session", tostring(err)))
    end
    return
  end
  if type(session) == "table" and type(session.submit) == "function" then
    local called, err = invoke_session(session, "submit", text, finish)
    if not called then
      finish(util.error("unsupported_session", tostring(err)))
    end
    return
  end
  finish(util.error("invalid_session", "session.prompt or session.submit is required for prompt input"))
end

return M
