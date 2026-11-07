---------------------------------------------------------------
-- TASK IDS
-- The one definition of the task id format. An id is "t-" plus the local time it was created,
-- to the minute (t-2026-11-07T09:15). A task carries it as a tag, task::t-2026-11-07T09:15;
-- elsewhere (daily-note log, other notes) the bare id is used as a reference.
---------------------------------------------------------------
local M = {}

--- Lua pattern for a bare id.
M.PATTERN = "t%-%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d"

--- Lua pattern for the tag; the capture is the id.
M.TAG_PATTERN = "task::(" .. M.PATTERN .. ")"

--- A new id for local time `ts` (default: now).
--- Ids are minute-resolution: two ids created in the same minute are equal, so use new_unique()
--- (or notifier.new_task_id) when creating an id for a new task.
--- @param ts number|nil
--- @return string
function M.new(ts)
  return "t-" .. os.date("%Y-%m-%dT%H:%M", ts)
end

local issued = {} -- ids handed out by new_unique() in this session

--- Set of ids (tagged or bare references) found in `lines`, added to `into` if given.
--- @return table<string, true>
function M.collect(lines, into)
  into = into or {}
  for _, line in ipairs(lines) do
    for id in line:gmatch(M.PATTERN) do into[id] = true end
  end
  return into
end

--- A new id that is not in `taken` (a set) and was not handed out before in this session.
--- Starts at the minute of `ts` (default: now) and moves to the next free minute, keeping the format.
function M.new_unique(taken, ts)
  ts = ts or os.time()
  local id = M.new(ts)
  while (taken and taken[id]) or issued[id] do
    ts = ts + 60
    id = M.new(ts)
  end
  issued[id] = true
  return id
end

--- The tag form of an id: task::<id>.
function M.tag(id)
  return "task::" .. id
end

--- The id of the task:: tag in `line`, or nil.
function M.from_line(line)
  return line:match(M.TAG_PATTERN)
end

--- `line` with every task::<id> tag turned into a bare <id> reference.
function M.untag(line)
  return (line:gsub(M.TAG_PATTERN, "%1"))
end

--- The id (bare or tagged) under 0-based column `col` of `line`; else the first id on the line; else nil.
function M.at(line, col)
  local first
  for start, id in line:gmatch("()(" .. M.PATTERN .. ")") do
    first = first or id
    if col + 1 >= start and col + 1 <= start + #id - 1 then
      return id
    end
  end
  return first
end

--- The id under the cursor in the current window (see M.at).
function M.under_cursor()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  return M.at(vim.api.nvim_get_current_line(), col)
end

return M
