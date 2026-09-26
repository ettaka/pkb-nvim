local notifier = require("pkb.notifier")
local parser = require("pkb.parser")

local M = {}

--- Agenda provider for calendar.nvim
--- @param year number
--- @param month number
--- @param day number
--- @return table List of formatted agenda items for the date
function M. get_pkb_day_agenda(year, month, day)
  local target_date = string.format("%04d-%02d-%02d", year, month, day)
  local day_entries = {}

  -- Expand recurring tasks up to 90 days ahead
  local horizon_ts = os.time() + (90 * 86400)
  local all_entries = parser.expand_recurring_tasks(notifier.notifications or {}, horizon_ts)

  for _, entry in ipairs(all_entries) do
    local is_done = entry.line and entry.line:match("^%s*%- %[[xX]%]")
    if not is_done and entry.due_ts then
      local entry_date = os.date("%Y-%m-%d", entry.due_ts)
      if entry_date == target_date then
        table.insert(day_entries, entry)
      end
    end
  end

  -- Sort entries by due time
  table.sort(day_entries, function(a, b)
    return a.due_ts < b.due_ts
  end)

  -- Format task lines into clean agenda strings ("HH:MM - Task title")
  local agenda = {}
  for _, entry in ipairs(day_entries) do
    local time_str = os.date("%H:%M", entry.due_ts)

    -- Strip markdown checkboxes and PKB tags for clean display
    local clean_line = entry.line
      :gsub("^%s*%- %[[ %]]%s*", "")
      :gsub("^%s*%- %s*", "")
      :gsub("%s*due::%S+", "")
      :gsub("%s*notify::%S+", "")
      :gsub("%s*recur::%S+", "")
      :gsub("%s*effort::%S+", "")
      :gsub("%s*task::%S+", "")

    table.insert(agenda, string.format("%s - %s", time_str, clean_line))
  end

  return agenda
end

return M
