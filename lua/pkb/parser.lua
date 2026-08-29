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
  return line:match("recur::([%w]+)")
end

--- Calculate the next due epoch timestamp based on recur rule
--- @param current_ts number Epoch timestamp
--- @param recur_str string e.g. "3d", "daily", "1w", "1m"
--- @return number Next epoch timestamp
function M.calculate_next_due(current_ts, recur_str)
  local num, unit = recur_str:match("^(%d*)(%a+)$")
  num = tonumber(num) or 1

  if unit == "daily" then unit = "d" end
  if unit == "weekly" then unit = "w" end
  if unit == "monthly" then unit = "m" end

  local date_tbl = os.date("*t", current_ts)

  if unit == "d" then
    date_tbl.day = date_tbl.day + num
  elseif unit == "w" then
    date_tbl.day = date_tbl.day + (num * 7)
  elseif unit == "m" then
    date_tbl.month = date_tbl.month + num
  end

  return os.time(date_tbl)
end

return M
