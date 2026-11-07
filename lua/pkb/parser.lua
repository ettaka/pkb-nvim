---------------------------------------------------------------
-- TIMESTAMP PARSER (Z / H / +offset support)
---------------------------------------------------------------
local M = {}

local parse_iso = require('timestamps.parser').parse_iso

M.DEFAULT_NOTIFY = "30min"

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

  -- 6. Construct the entry; state from the previous scan is matched afterwards (carry_state)
  new_state[id] = {
    id = id,
    line = line,
    file = file,
    line_num = line_num,
    due_ts = due_ts,
    notify_ts = notify_ts,
    triggered = false,
    dismissed = false,
    auto_snoozed_until = nil,
  }
end

---------------------------------------------------------------
-- STATE ACROSS RESCANS
---------------------------------------------------------------
local TASK_ID_PATTERN = require("pkb.task_id").TAG_PATTERN

-- State of tasks with a task:: id that disappeared in a rescan, keyed "id@due_ts", so a task that is
-- cut from one note and pasted into another (two saves, a rescan in between) keeps its state.
local vanished, vanished_count = {}, 0
local VANISHED_MAX = 1000

local function by_position(a, b)
  if a.file ~= b.file then return a.file < b.file end
  return a.line_num < b.line_num
end

local function sorted_values(t)
  local list = {}
  for _, v in pairs(t) do table.insert(list, v) end
  table.sort(list, by_position)
  return list
end

--- Copy triggered/dismissed/snooze state from the previous scan to the matching task in this one.
--- A task is matched (1) by exact line text in the same file, identical lines paired in order, else
--- (2) by task:: id with the same due time (survives edits to the text and moves between files,
---     also when the task was missing from the scans in between).
--- Anything else, including a changed due date, starts fresh. Line numbers are not used: they
--- shift whenever lines are added or removed above a task.
local function carry_state(old, new)
  local old_list, new_list = sorted_values(old), sorted_values(new)
  local used, matched = {}, {}

  local by_text = {}
  for _, e in ipairs(old_list) do
    local key = e.file .. "\0" .. e.line
    by_text[key] = by_text[key] or {}
    table.insert(by_text[key], e)
  end
  for _, n in ipairs(new_list) do
    for _, e in ipairs(by_text[n.file .. "\0" .. n.line] or {}) do
      if not used[e] then used[e], matched[n] = true, e; break end
    end
  end

  local by_task = {}
  for _, e in ipairs(old_list) do
    local tid = not used[e] and e.line:match(TASK_ID_PATTERN)
    if tid then
      by_task[tid] = by_task[tid] or {}
      table.insert(by_task[tid], e)
    end
  end
  for _, n in ipairs(new_list) do
    local tid = not matched[n] and n.line:match(TASK_ID_PATTERN)
    for _, e in ipairs(tid and by_task[tid] or {}) do
      if not used[e] and e.due_ts == n.due_ts then used[e], matched[n] = true, e; break end
    end
    local key = tid and not matched[n] and (tid .. "@" .. n.due_ts)
    if key and vanished[key] then
      matched[n], vanished[key] = vanished[key], nil
      vanished_count = vanished_count - 1
    end
  end

  -- Remember tasks with an id that are gone from this scan
  for _, e in ipairs(old_list) do
    local tid = not used[e] and e.line:match(TASK_ID_PATTERN)
    if tid and e.due_ts then
      if vanished_count >= VANISHED_MAX then vanished, vanished_count = {}, 0 end
      local key = tid .. "@" .. e.due_ts
      if not vanished[key] then vanished_count = vanished_count + 1 end
      vanished[key] = { triggered = e.triggered, dismissed = e.dismissed, auto_snoozed_until = e.auto_snoozed_until }
    end
  end

  for n, e in pairs(matched) do
    n.triggered, n.dismissed, n.auto_snoozed_until = e.triggered, e.dismissed, e.auto_snoozed_until
  end
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

local function walk(notifications, path, new_state)
  local handle = vim.loop.fs_scandir(path)
  if not handle then return end

  while true do
    local name, typ = vim.loop.fs_scandir_next(handle)
    if not name then break end
    local full = path .. "/" .. name

    if typ == "file" and name:match("%.md$") then
      scan_file(notifications, full, new_state)
    elseif typ == "directory" then
      walk(notifications, full, new_state)
    end
  end
end

--- Scan `path` recursively into `new_state` (keyed "file:line"), carrying state over from
--- `notifications` (the previous scan) to the same tasks.
function M.scan_dir(notifications, path, new_state)
  if type(path) ~= "string" then return end
  walk(notifications, path, new_state)
  carry_state(notifications or {}, new_state)
end

--- Scan only `files` (markdown paths, as full-scan keys) into `new_state`, carrying state over from
--- `notifications`, which should hold the previous entries of those files. Missing files add nothing.
function M.scan_files(notifications, files, new_state)
  for _, file in ipairs(files) do
    if file:match("%.md$") then scan_file(notifications, file, new_state) end
  end
  carry_state(notifications or {}, new_state)
end

local warned_rules = {} -- "file:line rule" -> true: warn once per session, not on every inbox render

local function warn_bad_rule(entry, err)
  local key = (entry.id or "") .. " " .. err
  if warned_rules[key] then return end
  warned_rules[key] = true
  vim.notify(("[PKB Notify] %s (%s:%s)"):format(err, entry.file or "?", tostring(entry.line_num or "?")),
    vim.log.levels.WARN)
end

--- Expand recurring tasks up to a given horizon timestamp
--- @param notifications table Map of notifications
--- @param horizon_ts number Epoch timestamp horizon
--- @return table List of all entries including virtual recurring instances
function M.expand_recurring_tasks(notifications, horizon_ts)
  local expanded = {}

  for id, entry in pairs(notifications) do
    table.insert(expanded, entry)

    local recur_str = M.parse_recurrence(entry.line)
    if recur_str and entry.due_ts then
      local current_ts = entry.due_ts
      while true do
        local next_ts, err = M.calculate_next_due_advanced(current_ts, recur_str)
        if not next_ts then
          warn_bad_rule(entry, err)
          break
        end
        if next_ts <= current_ts then break end -- never loop without moving forward
        current_ts = next_ts
        if current_ts > horizon_ts then
          break
        end

        local virtual_entry = vim.tbl_deep_extend("force", {}, entry, {
          id = id .. "_" .. current_ts,
          due_ts = current_ts,
          is_virtual = true,
        })
        table.insert(expanded, virtual_entry)
      end
    end
  end

  return expanded
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

-- Unit names a plain rule may use, as { unit, count multiplier }.
local UNITS = {}
for unit, names in pairs({
  d = { "d", "day", "days", "daily" },
  w = { "w", "week", "weeks", "weekly" },
  m = { "m", "month", "months", "monthly" },
  y = { "y", "year", "years", "yearly", "annually" },
}) do
  for _, name in ipairs(names) do UNITS[name] = { unit } end
end
UNITS.biweekly, UNITS.fortnightly, UNITS.bimonthly = { "w", 2 }, { "w", 2 }, { "m", 2 }

--- Calculate the next due epoch timestamp based on recur rule
--- @param current_ts number Epoch timestamp
--- @param recur_str string e.g. "3d", "daily", "biweekly", "1w", "1m", "yearly"
--- @return number|nil next Next epoch timestamp, or nil for a rule it does not understand
--- @return string|nil err Why the rule is invalid
function M.calculate_next_due(current_ts, recur_str)
  local num, name = recur_str:match("^(%d*)(%a+)$")
  local unit = name and UNITS[name:lower()]
  if not unit then
    return nil, ("Unknown recurrence '%s': unknown unit (use e.g. 3d, 2w, 3m, 1y, daily, 3months)"):format(recur_str)
  end
  -- biweekly etc. carry their own count; a number in front multiplies it (3monthly = every 3 months)
  num = (tonumber(num) or 1) * (unit[2] or 1)
  unit = unit[1]
  if num < 1 then
    return nil, ("Unknown recurrence '%s': the count must be at least 1"):format(recur_str)
  end

  local date_tbl = os.date("*t", current_ts)

  if unit == "d" then
    date_tbl.day = date_tbl.day + num
  elseif unit == "w" then
    date_tbl.day = date_tbl.day + (num * 7)
  elseif unit == "m" or unit == "y" then
    -- Move to the 1st of the target month first, then clamp the day to that month's length,
    -- so e.g. Jan 31 + 1 month is Feb 28/29 rather than overflowing into March.
    local day = date_tbl.day
    date_tbl.day = 1
    if unit == "m" then
      date_tbl.month = date_tbl.month + num
    else
      date_tbl.year = date_tbl.year + num
    end
    local last_day = os.date("*t", os.time({ year = date_tbl.year, month = date_tbl.month + 1, day = 0, hour = 12 })).day
    date_tbl.day = math.min(day, last_day)
  end

  -- os.date("*t") records whether current_ts was in summer time. Keeping that flag would make
  -- os.time() shift the result by an hour when the new date is in the other half of the year;
  -- clearing it lets the system decide, so the task keeps its wall-clock time.
  date_tbl.isdst = nil
  return os.time(date_tbl)
end

function M.calculate_next_due_advanced(current_ts, recur_str)
  local current_date = os.date("*t", current_ts)

  -- Check for expressions like: "1st_tue", "2nd_wed", "last_fri"
  local nth_str, day_str = recur_str:match("^(%w+)_(%a+)$")
  if nth_str and day_str then
    if not weekday_map[day_str:lower()] then
      return nil, ("Unknown recurrence '%s': invalid weekday '%s'"):format(recur_str, day_str)
    end
    
    local target_wday = weekday_map[day_str:lower()]
    local nth = nil

    if nth_str == "1st" then nth = 1
    elseif nth_str == "2nd" then nth = 2
    elseif nth_str == "3rd" then nth = 3
    elseif nth_str == "4th" then nth = 4
    elseif nth_str == "last" then nth = -1
    else
      return nil, ("Unknown recurrence '%s': invalid ordinal '%s' (use 1st, 2nd, 3rd, 4th or last)"):format(recur_str, nth_str)
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

function M.find_log_insertion_index(lines, target_section)
  local section_idx = nil
  local insert_idx = #lines + 1

  for i, line in ipairs(lines) do
    if line:match("^#%s+" .. target_section .. "$") then
      section_idx = i
      break
    end
  end

  if section_idx then
    for i = section_idx + 1, #lines do
      if lines[i]:match("^#+%s+") then
        insert_idx = i
        break
      end
    end
    while insert_idx > section_idx + 1 and lines[insert_idx - 1] == "" do
      insert_idx = insert_idx - 1
    end
    return section_idx, insert_idx
  end

  return nil, nil
end

return M
