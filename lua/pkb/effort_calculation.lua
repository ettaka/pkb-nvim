local M = {}

local notifier = require("pkb.notifier")
local parser = require("pkb.parser")


--- Extract effort tag (`effort::<value><unit>`) from a task line and return duration in hours.
--- Supports: `min` (minutes), `h` (hours), `day` (days).
---
--- Examples:
---   effort::30min -> 0.5
---   effort::2h    -> 2.0
---   effort::1day  -> 24.0
local function get_effort_hours(line)
  line = tostring(line or "")
  local start = line:find("effort::", 1, true)
  if not start then
    return 0
  end

  local effort = line:sub(start + #"effort::")
  local value, unit = effort:match("^([%d%.]+)(%a+)")
  if not value or not unit then
    return 0
  end

  value = tonumber(value) or 0

  if unit == "min" then
    return value / 60
  elseif unit == "h" then
    return value
  elseif unit == "day" then
    return value * 24
  end

  return 0
end

--- Retrieves total planned task duration in hours for a specific date (year, month, day)
function M.get_tasks_duration(year, month, day)
  local target_date = string.format("%04d-%02d-%02d", year, month, day)
  local total_hours = 0

  -- Define a horizon of 90 days ahead for forecasting recurring effort
  local horizon_ts = os.time() + (90 * 86400)
  local all_entries = parser.expand_recurring_tasks(notifier.notifications or {}, horizon_ts)

  for _, entry in ipairs(all_entries) do
    local is_done = entry.line and entry.line:match("^%s*%- %[[xX]%]")
    if not is_done and entry.due_ts then
      local entry_date = os.date("%Y-%m-%d", entry.due_ts)
      if entry_date == target_date then
        total_hours = total_hours + get_effort_hours(entry.line)
      end
    end
  end

  return total_hours
end

--- Retrieves total planned task duration in hours for a specific date
--- (Integrate with your task provider/data source or state here)
--- @param year number
--- @param month number
--- @param day number
--- @return number
function M.get_day_effort(year, month, day)
  if type(M.get_tasks_duration) == "function" then
    return M.get_tasks_duration(year, month, day) or 0
  end
  return 0
end

return M
