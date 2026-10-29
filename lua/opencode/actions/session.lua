-- Session actions exposed to the semantic keybinding layer.
--
-- `session_action.interrupt` calls the session controller's interrupt method
-- and normalizes its callback contract for a keybinding action:
--
--   action.interrupt(controller, function(err, result) ... end)
--
-- The controller owns session creation and the API call.  It already treats an
-- idle interrupt (`{ interrupted = false }`) as success; this wrapper also
-- tolerates explicit idle error codes so an idle press never becomes a
-- misleading error notification.  The action layer never calls vim.notify.

local M = {}

local function make_error(code, message, extra)
  local err = {
    code = code,
    message = message,
  }
  if type(extra) == "table" then
    for name, value in pairs(extra) do
      err[name] = value
    end
  end
  return err
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  return vim.deepcopy(value)
end

local function normalize_error(err, fallback_code)
  if type(err) == "table" then
    local out = copy(err)
    if out.code == nil then
      out.code = fallback_code
    end
    if out.message == nil then
      out.message = tostring(err)
    end
    return out
  end
  return make_error(fallback_code, tostring(err))
end

local IDLE_CODES = {
  idle = true,
  no_active_execution = true,
  no_active_session = true,
  not_running = true,
  interrupt_idle = true,
}

local function is_idle_error(err)
  if type(err) ~= "table" then
    return false
  end
  if err.idle == true then
    return true
  end
  return type(err.code) == "string" and IDLE_CODES[err.code] == true
end

local function normalize_result(value)
  local interrupted
  if type(value) == "boolean" then
    interrupted = value
  elseif type(value) == "table" and type(value.interrupted) == "boolean" then
    interrupted = value.interrupted
  end
  if interrupted == nil then
    interrupted = false
  end
  return {
    interrupted = interrupted,
    idle = type(value) == "table" and value.idle == true or interrupted == false,
    result = copy(value),
  }
end

--- Interrupt the execution owned by the controller's current session.
---
--- @param controller table session controller/module with `interrupt(callback)`
--- @param callback fun(err: table|nil, result: table|nil)|nil
--- @return table|nil handle
function M.interrupt(controller, callback)
  if type(callback) ~= "function" then
    callback = nil
  end

  local function finish(err, result)
    if callback then
      callback(err, result)
    end
  end

  if type(controller) ~= "table" or type(controller.interrupt) ~= "function" then
    local err = make_error(
      "interrupt_unavailable",
      "session controller does not provide interrupt()"
    )
    finish(err, nil)
    return nil
  end

  local completed = false
  local function done(err, value)
    if completed then
      return
    end
    completed = true
    if err ~= nil then
      if is_idle_error(err) then
        finish(nil, {
          interrupted = false,
          idle = true,
          result = copy(err),
        })
      else
        finish(normalize_error(err, "interrupt_failed"), nil)
      end
      return
    end
    finish(nil, normalize_result(value))
  end

  local ok, start, start_err = pcall(controller.interrupt, controller, done)
  if not ok then
    if completed then
      error(start, 0)
    end
    done(make_error("interrupt_failed", tostring(start)))
    return nil
  end

  if start_err ~= nil and not completed then
    done(normalize_error(start_err, "interrupt_failed"))
    return nil
  end

  if start ~= nil and not completed then
    if type(start) == "table" and start.code ~= nil then
      done(normalize_error(start, "interrupt_failed"))
    elseif type(start) == "table" or type(start) == "boolean" then
      done(nil, start)
    elseif type(start) == "string" then
      done(make_error("interrupt_failed", start))
    end
  end

  return nil
end

return M
