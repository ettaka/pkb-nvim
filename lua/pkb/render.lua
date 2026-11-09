local M = {}

local parser = require("pkb.parser")

M._line_map = M._line_map or {}

-- Return effort in seconds from an effort::... tag in n.line.
--
-- Examples:
--   effort::1min
--   effort::10min
--   effort::1h
--   effort::2.5h
--   effort::1day
--   effort::2day
local function get_effort_seconds(n)
  local line = tostring(n.line or "")

  -- Find the effort tag.
  local start = line:find("effort::", 1, true)

  if not start then
    return 0
  end

  -- Everything after "effort::"
  local effort = line:sub(start + #"effort::")

  -- Extract number and unit.
  local value, unit = effort:match("^([%d%.]+)(%a+)")

  if not value or not unit then
    return 0
  end

  value = tonumber(value)

  if unit == "min" then
    return value * 60
  elseif unit == "h" then
    return value * 60 * 60
  elseif unit == "day" then
    return value * 24 * 60 * 60
  end

  return 0
end

-- Convert seconds into something readable.
local function format_effort(seconds)
  if seconds <= 0 then
    return nil
  end

  local days = math.floor(seconds / 86400)
  seconds = seconds % 86400

  local hours = math.floor(seconds / 3600)
  seconds = seconds % 3600

  local minutes = math.floor(seconds / 60)

  local parts = {}

  if days > 0 then
    table.insert(parts, days .. "d")
  end

  if hours > 0 then
    table.insert(parts, hours .. "h")
  end

  if minutes > 0 then
    table.insert(parts, minutes .. "min")
  end

  return table.concat(parts, " ")
end

local function find_conflicts(items)
  local conflicts = {}
  -- Group items by date
  local by_date = {}
  for _, item in ipairs(items) do
    local date = os.date("%Y-%m-%d", item.due_ts)
    by_date[date] = by_date[date] or {}
    table.insert(by_date[date], item)
  end

  for _, date_items in pairs(by_date) do
    for i = 1, #date_items do
      for j = i + 1, #date_items do
        local a, b = date_items[i], date_items[j]
        local a_start = a.due_ts
        local a_effort = get_effort_seconds(a)
        local a_end = a_start + (a_effort > 0 and a_effort or 1800) -- default to 30 mins if no effort specified

        local b_start = b.due_ts
        local b_effort = get_effort_seconds(b)
        local b_end = b_start + (b_effort > 0 and b_effort or 1800)

        -- Check overlap: max(start_a, start_b) < min(end_a, end_b)
        if math.max(a_start, b_start) < math.min(a_end, b_end) then
          conflicts[a.id] = true
          conflicts[b.id] = true
        end
      end
    end
  end

  return conflicts
end

--- Task text for display: without the checkbox / list marker and the PKB tags.
function M.display_text(line)
  local text = tostring(line or "")
    :gsub("^%s*%- %[[ xX]%]%s*", "") -- "- [ ] " checkbox
    :gsub("^%s*%- %s*", "")           -- plain list marker
  for _, tag in ipairs({ "due", "notify", "recur", "effort", "task" }) do
    text = text:gsub("%s*" .. tag .. "::%S+", "")
  end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local SLOT_WIDTH = 11 -- "08:00–09:30"

--- Display column (0-based) where a task's text starts: "[ ] " + slot + two spaces. Wrapped lines indent to it.
M.TEXT_COLUMN = 4 + SLOT_WIDTH + 2

local function pad(s, width)
  return s .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(s)))
end

--- os.date for `ts` in local time, or at a fixed UTC offset (seconds) when one is given.
local function date_at(fmt, ts, tz_offset)
  if tz_offset then return os.date("!" .. fmt, ts + tz_offset) end
  return os.date(fmt, ts)
end

local function day_number(ts, tz_offset)
  local d = date_at("*t", ts, tz_offset)
  return math.floor(os.time({ year = d.year, month = d.month, day = d.day, hour = 12 }) / 86400 + 0.5)
end

--- "08:00–08:30" (start to start + effort), "08:00" without effort, "22:00–03:00+1d" past midnight.
--- tz_offset (seconds east of UTC): show the slot at that fixed offset instead of local time.
function M.time_slot(n, tz_offset)
  local start = date_at("%H:%M", n.due_ts, tz_offset)
  local effort = get_effort_seconds(n)
  if effort <= 0 then return start end
  local finish = n.due_ts + effort
  local slot = start .. "–" .. date_at("%H:%M", finish, tz_offset)
  local days = day_number(finish, tz_offset) - day_number(n.due_ts, tz_offset)
  if days > 0 then slot = slot .. "+" .. days .. "d" end
  return slot
end

local function display_file(file, root)
  root = root and root:gsub("/+$", "")
  if root and root ~= "" and file:sub(1, #root + 1) == root .. "/" then
    return file:sub(#root + 2)
  end
  return vim.fn.fnamemodify(file, ":t")
end

local function end_of_day(date, tz_offset) -- "YYYY-MM-DD" -> epoch of 23:59:59 local (or at tz_offset)
  local y, m, d = date:match("^(%d+)%-(%d+)%-(%d+)$")
  if tz_offset then
    return require("timestamps.parser").parse_iso(date .. "T23:59Z") + 59 - tz_offset
  end
  return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 23, min = 59, sec = 59 })
end

--- Render the inbox into `buf`: tasks grouped by day, each with its time slot.
--- opts.root: PKB root, files are shown relative to it.
--- opts.focus_date ("YYYY-MM-DD"): this day is always shown (an empty section if it has no tasks), and
--- recurring tasks are expanded at least up to it. Returns the row of its heading.
--- opts.tz_offset (seconds east of UTC) and opts.tz_label: show times and days at that fixed offset, under a
--- "Times in <label>" header.
--- @return integer|nil focus_row
function M.render_inbox(notifications, inbox_show_all, horizon_duration, buf, opts)
  opts = opts or {}
  local horizon_ts = os.time() + horizon_duration
  if opts.focus_date then
    horizon_ts = math.max(horizon_ts, end_of_day(opts.focus_date, opts.tz_offset))
  end
  local raw_items = parser.expand_recurring_tasks(notifications, horizon_ts)

  local items = {}
  for _, n in ipairs(raw_items) do
    if not n.line:match("^%s*%- %[[xX]%]") then
      if inbox_show_all or not n.dismissed then
        table.insert(items, n)
      end
    end
  end

  table.sort(items, function(a, b)
    return a.due_ts < b.due_ts
  end)

  local conflicts = find_conflicts(items)

  -- Group by day (items are sorted, so days come in order); add the focus day if it has no tasks.
  local days, by_date = {}, {}
  for _, n in ipairs(items) do
    local date = date_at("%Y-%m-%d", n.due_ts, opts.tz_offset)
    if not by_date[date] then
      by_date[date] = { date = date, items = {}, effort = 0 }
      table.insert(days, by_date[date])
    end
    table.insert(by_date[date].items, n)
    by_date[date].effort = by_date[date].effort + get_effort_seconds(n)
  end
  if opts.focus_date and not by_date[opts.focus_date] then
    table.insert(days, { date = opts.focus_date, items = {}, effort = 0 })
    table.sort(days, function(a, b) return a.date < b.date end)
  end

  local lines = {}
  local line_map = {}
  local focus_row
  if opts.tz_offset then
    table.insert(lines, "Times in " .. (opts.tz_label or "another offset"))
  end

  for _, day in ipairs(days) do
    if #lines > 0 then
      table.insert(lines, "")
    end

    local heading = "## " .. day.date
    if day.effort > 0 then
      heading = heading .. " — total effort: " .. format_effort(day.effort)
    end
    table.insert(lines, heading)
    if day.date == opts.focus_date then focus_row = #lines end

    if #day.items == 0 then
      table.insert(lines, "  (no tasks)")
    end

    for _, n in ipairs(day.items) do
      local status =
        n.dismissed and "[x]" or
        n.triggered and "[!]" or
        "[ ]"

      local text = M.display_text(n.line)
      if parser.parse_recurrence(n.line) then text = text .. " ↻" end
      if conflicts[n.id] then text = text .. "  ⚠️ CONFLICT" end

      table.insert(lines, ("%s %s  %s  · %s"):format(status, pad(M.time_slot(n, opts.tz_offset), SLOT_WIDTH), text, display_file(n.file, opts.root)))

      -- Map 1-based buffer line number to notification object
      line_map[#lines] = n
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"

  M._line_map[buf] = line_map
  return focus_row
end

function M.get_notification_at_cursor(buf)
  buf = buf or vim.api.nvim_get_current_buf()

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]

  local line_map = M._line_map[buf]

  if line_map then
    return line_map[row]
  end

  return nil
end

return M
