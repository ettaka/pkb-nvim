---------------------------------------------------------------
-- TIMESTAMP PARSER (Z / H / +offset support)
---------------------------------------------------------------
local M = {}

local parse_iso = require('timestamps.parser').parse_iso

M.DEFAULT_NOTIFY = "15min"

function M.setup(opts)
  opts = opts or {}
  if opts.default_notify then
    M.DEFAULT_NOTIFY = opts.default_notify
  end
end

function M.parse_notify(str)
  local n = tonumber(str:match("(%d+)"))
  if not n then return 0 end
  if str:match("min") then return n * 60 end
  if str:match("h")   then return n * 3600 end
  if str:match("day") then return n * 86400 end
  return 0
end

---------------------------------------------------------------
-- PARSE LINE
---------------------------------------------------------------
local function parse_line(notifications, line, line_num, file, new_state, is_in_code_block)
  -- 1. Bail out immediately if we are reading inside a markdown code block
  if is_in_code_block then return end

  -- 2. Detect and skip documentation lines or template examples completely
  -- This skips lines containing [Z/H...], YYYY-MM-DD, or template brackets
  if line:match("%[Z/H") or line:match("YYYY%-MM%-DD") or line:match("due::.*%[.*%]") then
    return
  end

  -- 3. Extract the raw due string tag (stops matching at spaces)
  local due_str = line:match("due::([^%s]+)")
  if not due_str then return end

  -- 4. Clean trailing punctuation from due_str copy for validation check
  local clean_due_str = due_str:match("^([%w%-%+:]+)") or due_str
  local due_ts = parse_iso(clean_due_str)
  
  if not due_ts then
    -- A real mistake was found on an intended user line: print warning
    vim.notify(
      string.format("[PKB Notify] Invalid date configuration '%s' in file: %s (Line %s)", due_str, file, tostring(line_num)),
      vim.log.levels.WARN
    )
    
    -- Assign a safe placeholder timestamp far in the future
    due_ts = os.time() + 99999999 
  end

  -- 5. Read notification configurations
  local notify_str = line:match("notify::([%w]+)") or M.DEFAULT_NOTIFY
  local notify_ts = due_ts - M.parse_notify(notify_str)
  
  if not line_num then return end
  local id = string.format("%s:%d", file, line_num)

  -- Preserve existing state across rescans
  local existing = notifications[id]

  -- 6. Construct and save the entry state safely
  new_state[id] = {
    id = id,
    line = line,
    file = file,
    line_num = line_num,
    due_ts = due_ts,
    notify_ts = notify_ts,
    triggered = existing and existing.triggered or false,
    dismissed = existing and existing.dismissed or false,
    auto_snoozed_until = existing and existing.auto_snoozed_until or nil,
  }
end

local function scan_file(notifications, file, new_state)
  local ok, lines = pcall(vim.fn.readfile, file)
  if not ok then return end

  local is_in_code_block = false
  for line_num, line in ipairs(lines) do
    -- Detect start or end of markdown code blocks
    if line:match("^%s*```") then
      is_in_code_block = not is_in_code_block
    end
    parse_line(notifications, line, line_num, file, new_state, is_in_code_block)
  end
end

function M.scan_dir(notifications, path, new_state)
  local handle = vim.loop.fs_scandir(path)
  if not handle then return end

  while true do
    local name, typ = vim.loop.fs_scandir_next(handle)
    if not name then break end
    local full = path .. "/" .. name

    if typ == "file" and name:match("%.md$") then
      scan_file(notifications, full, new_state)
    elseif typ == "directory" then
      M.scan_dir(notifications, full, new_state)
    end
  end
end

-- In lua/pkb/parser.lua

--- Parse recur::<value> tag from line (e.g. recur::daily, recur::3d, recur::1w, recur::1m)
--- @param line string
--- @return string|nil
function M.parse_recurrence(line)
  line = tostring(line or "")
  return line:match("recur::([%w_]+)")
end

local weekday_map = {
  sun = 1, sunday = 1,
  mon = 2, monday = 2,
  tue = 3, tuesday = 3,
  wed = 4, wednesday = 4,
  thu = 5, thursday = 5,
  fri = 6, friday = 6,
  sat = 7, saturday = 7,
}

--- Get epoch timestamp for the N-th occurrence of a weekday in a given month/year
--- @param year number e.g. 2026
--- @param month number 1-12
--- @param target_wday number 1=Sun, 2=Mon, ..., 7=Sat
--- @param nth number 1=1st, 2=2nd, 3=3rd, 4=4th, -1=last
--- @param ref_date table Standard date table containing hour, min, sec to preserve time
--- @return number Epoch timestamp
local function get_nth_weekday_of_month(year, month, target_wday, nth, ref_date)
  if nth > 0 then
    -- Find the 1st day of the month
    local first_day_ts = os.time({ year = year, month = month, day = 1, hour = 12 })
    local first_wday = os.date("*t", first_day_ts).wday

    -- Calculate first matching weekday of month
    local day_offset = (target_wday - first_wday) % 7
    local day_of_month = 1 + day_offset + (nth - 1) * 7

    return os.time({
      year = year,
      month = month,
      day = day_of_month,
      hour = ref_date.hour,
      min = ref_date.min,
      sec = ref_date.sec,
    })
  else
    -- Negative nth (e.g. -1 for last weekday of month)
    -- Find day 0 of next month (which is last day of current month)
    local last_day_ts = os.time({ year = year, month = month + 1, day = 0, hour = 12 })
    local last_date = os.date("*t", last_day_ts)
    local last_wday = last_date.wday

    local day_offset = (last_wday - target_wday) % 7
    local day_of_month = last_date.day - day_offset - (math.abs(nth) - 1) * 7

    return os.time({
      year = year,
      month = month,
      day = day_of_month,
      hour = ref_date.hour,
      min = ref_date.min,
      sec = ref_date.sec,
    })
  end
end

--- Calculate the next due epoch timestamp based on recur rule
--- @param current_ts number Epoch timestamp
--- @param recur_str string e.g. "3d", "daily", "biweekly", "1w", "1m", "yearly"
--- @return number Next epoch timestamp
function M.calculate_next_due(current_ts, recur_str)
  local num, unit = recur_str:match("^(%d*)(%a+)$")
  num = tonumber(num) or 1

  -- Preset aliases
  if unit == "daily" then unit = "d"
  elseif unit == "weekly" then unit = "w"
  elseif unit == "biweekly" or unit == "fortnightly" then
    num = 2
    unit = "w"
  elseif unit == "monthly" then unit = "m"
  elseif unit == "bimonthly" then
    num = 2
    unit = "m"
  elseif unit == "yearly" or unit == "annually" then unit = "y"
  end

  local date_tbl = os.date("*t", current_ts)

  if unit == "d" then
    date_tbl.day = date_tbl.day + num
  elseif unit == "w" then
    date_tbl.day = date_tbl.day + (num * 7)
  elseif unit == "m" then
    date_tbl.month = date_tbl.month + num
  elseif unit == "y" then
    date_tbl.year = date_tbl.year + num
  end

  return os.time(date_tbl)
end

function M.calculate_next_due_advanced(current_ts, recur_str)
  local current_date = os.date("*t", current_ts)

  -- Check for expressions like: "1st_tue", "2nd_wed", "last_fri"
  local nth_str, day_str = recur_str:match("^(%w+)_(%a+)$")
  if nth_str and day_str and weekday_map[day_str:lower()] then
    local target_wday = weekday_map[day_str:lower()]
    local nth = nil

    if nth_str == "1st" then nth = 1
    elseif nth_str == "2nd" then nth = 2
    elseif nth_str == "3rd" then nth = 3
    elseif nth_str == "4th" then nth = 4
    elseif nth_str == "last" then nth = -1
    end

    if nth then
      -- Target next month (or current month if today is before the occurrence)
      local next_month = current_date.month + 1
      local next_year = current_date.year

      local candidate_ts = get_nth_weekday_of_month(current_date.year, current_date.month, target_wday, nth, current_date)
      
      -- If candidate timestamp is still in the future, return it
      if candidate_ts > current_ts then
        return candidate_ts
      end

      -- Otherwise move to next month
      return get_nth_weekday_of_month(next_year, next_month, target_wday, nth, current_date)
    end
  end

  -- Fallback to standard units (d, w, m, y, biweekly)
  return M.calculate_next_due(current_ts, recur_str)
end

return M
