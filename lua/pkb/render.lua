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

function M.render_inbox(notifications, inbox_show_all, horizon_duration, buf)
  -- Forecast/expand recurring tasks up to 90 days ahead in the inbox view
  local horizon_ts = os.time() + horizon_duration
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

  ----------------------------------------------------------------
  -- First pass: calculate total effort for each date
  ----------------------------------------------------------------

  local daily_effort = {}

  for _, n in ipairs(items) do
    local date = os.date("%Y-%m-%d", n.due_ts)
    local effort = get_effort_seconds(n)

    if effort > 0 then
      daily_effort[date] = (daily_effort[date] or 0) + effort
    end
  end

  ----------------------------------------------------------------
  -- Second pass: render
  ----------------------------------------------------------------

  local lines = {}
  local line_map = {}
  local current_date = nil

  for _, n in ipairs(items) do
    local item_date = os.date("%Y-%m-%d", n.due_ts)

    if item_date ~= current_date then
      current_date = item_date

      if #lines > 0 then
        table.insert(lines, "")
      end

      local heading = "## " .. current_date

      local total = daily_effort[current_date]

      if total and total > 0 then
        heading = heading .. " — total effort: " .. format_effort(total)
      end

      table.insert(lines, heading)
    end

    local status =
      n.dismissed and "[x]" or
      n.triggered and "[!]" or
      "[ ]"

    table.insert(
      lines,
      string.format(
        "%s %s | %s | due %s",
        status,
        n.line,
        n.file,
        os.date("%H:%M", n.due_ts)
      )
    )

    -- Map 1-based buffer line number to notification object
    line_map[#lines] = n
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"

  M._line_map[buf] = line_map
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
