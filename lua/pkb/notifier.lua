-- ============================================================
-- PKB Notifier — Consolidated Digest & Smart Auto-Snooze
-- ============================================================

local M = {}

local parser = require("pkb.parser")
local task_id = require("pkb.task_id")

---------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------
M.DEFAULT_NOTIFY = "30min"     -- First reminder, when a task has no notify:: tag
M.REMIND_BEFORE = { "15min", "10min", "5min", "0min" } -- Follow-up reminders before due
M.POLL_INTERVAL = 30000        -- Poll every 30 seconds (ms)
M.SNOOZE_INTERVAL = 30 * 60    -- Longest snooze ([q] in the digest), in seconds
M.DEFAULT_HORIZON = 90 * 86400

function M.setup(opts)
  opts = opts or {}
  if opts.pkb_root then
    M.PKB_ROOT = opts.pkb_root
  end
  if opts.device_is_phone ~= nil then
    M.DEVICE_IS_PHONE = opts.device_is_phone
  end
  if opts.default_notify then
    M.DEFAULT_NOTIFY = opts.default_notify
    -- The parser applies the default while scanning, so it needs the value too.
    parser.setup({ default_notify = opts.default_notify })
  end
  if opts.poll_interval then
    M.POLL_INTERVAL = opts.poll_interval
  end
  if opts.snooze_interval then
    M.SNOOZE_INTERVAL = opts.snooze_interval
  end
  if opts.remind_before then
    M.REMIND_BEFORE = opts.remind_before
  end
  if opts.default_horizon then
    M.DEFAULT_HORIZON = opts.default_horizon * 86400
  end
end

local scan_dir = require("pkb.parser").scan_dir

local termux_notification = require("pkb.termux_notification")
local phone_notify_digest = termux_notification.phone_notify_digest

local show_next_popup = require("pkb.ui").show_next_popup
local phone_notify = require("pkb.termux_notification").phone_notify
local render_inbox = require("pkb.render").render_inbox
local get_notification_at_cursor = require("pkb.render").get_notification_at_cursor

---------------------------------------------------------------
-- STATE
---------------------------------------------------------------
-- Keyed by stable ID: "path/to/file.md:line_num"
M.notifications = {}
M.active_popups = {}
M.popup_queue = {}
M.popup_active = false
M.timer = nil
M.inbox_show_all = false

---------------------------------------------------------------
-- REMINDERS
-- A task first pops up at notify:: before due. Snoozing it hides it until the next follow-up reminder
-- (REMIND_BEFORE), but never for longer than SNOOZE_INTERVAL; after the last follow-up it comes back
-- every SNOOZE_INTERVAL until it is done, skipped or dismissed.
---------------------------------------------------------------
--- When a task snoozed at `now` should pop up again.
function M.snooze_until(entry, now)
  local wake = now + M.SNOOZE_INTERVAL
  for _, before in ipairs(M.REMIND_BEFORE) do
    local ts = entry.due_ts - parser.parse_notify(before)
    if ts > now and ts < wake then wake = ts end
  end
  return wake
end

---------------------------------------------------------------
-- TIMER TICK / EVALUATION LOGIC
---------------------------------------------------------------
local function check_notifications()
  local now = os.time()
  local pending_due = {}
  local seen_ids = {}

  for _, entry in pairs(M.notifications) do
    -- Filter out completed markdown checkmarks.
    local is_done = entry.line:match("^%s*%- %[[xX]%]")

    if not is_done and not entry.dismissed then
      local is_due = now >= entry.notify_ts
      local snooze_expired =
        not entry.auto_snoozed_until
        or now >= entry.auto_snoozed_until

      if is_due and snooze_expired then
        entry.auto_snoozed_until = nil
        entry.triggered = true
        
        -- Keep only one instance per unique file/task ID in the pending batch
        if not seen_ids[entry.id] then
          seen_ids[entry.id] = true
          table.insert(pending_due, entry)
        end
      end
    end
  end

  if #pending_due == 0 then
    return
  end

  -- Sort newly triggered notifications by due timestamp.
  table.sort(pending_due, function(a, b)
    return a.due_ts < b.due_ts
  end)

  -- Send consolidated phone notification.
  phone_notify_digest(pending_due, M.DEVICE_IS_PHONE)

  -- Add newly triggered notifications to the Neovim queue (ensuring no duplicates in queue)
  local queue_ids = {}
  for _, existing in ipairs(M.popup_queue) do
    queue_ids[existing.id] = true
  end

  for _, entry in ipairs(pending_due) do
    if not queue_ids[entry.id] then
      queue_ids[entry.id] = true
      table.insert(M.popup_queue, entry)
    end
  end

  -- Show the digest, or update the existing one.
  show_next_popup(M.popup_queue, M.snooze_until)
end

local function start_timer()
  if not M.timer then
    M.timer = vim.loop.new_timer()
    M.timer:start(0, M.POLL_INTERVAL, vim.schedule_wrap(function()
      check_notifications()
    end))
  end
end

---------------------------------------------------------------
-- NOTE EDITING
---------------------------------------------------------------
--- Change a note on disk or, if it is open, in its buffer.
--- `edit(lines)` changes `lines` in place and returns false to cancel.
--- An open buffer is changed in place so unsaved edits survive. It is written only if it had no
--- unsaved changes before; otherwise it stays modified and the user is told to save it.
--- @return boolean applied
local function update_note(path, edit)
  local bufnr = vim.fn.bufnr(path)
  local in_buffer = bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr)

  local old
  if in_buffer then
    old = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if #old == 1 and old[1] == "" and vim.fn.filereadable(path) == 0 then old = {} end -- new, empty buffer
  elseif vim.fn.filereadable(path) == 1 then
    old = vim.fn.readfile(path)
  else
    old = {}
  end

  local lines = vim.list_extend({}, old)
  if edit(lines) == false then return false end

  if not in_buffer then
    vim.fn.writefile(lines, path)
    return true
  end

  -- Replace only the changed range, so cursor, marks and undo stay as local as possible.
  local first = 1
  while first <= #old and first <= #lines and old[first] == lines[first] do first = first + 1 end
  local old_last, new_last = #old, #lines
  while old_last >= first and new_last >= first and old[old_last] == lines[new_last] do
    old_last, new_last = old_last - 1, new_last - 1
  end
  local was_modified = vim.bo[bufnr].modified
  vim.api.nvim_buf_set_lines(bufnr, first - 1, old_last, false, vim.list_slice(lines, first, new_last))

  if was_modified then
    vim.notify(
      ("[PKB] Updated %s in its buffer. It has unsaved changes, so save it (:w) to keep this change.")
        :format(vim.fn.fnamemodify(path, ":t")),
      vim.log.levels.WARN
    )
  else
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent noautocmd write") end)
  end
  return true
end

--- Index of the entry's task line in `lines`: its scanned line number if the text still matches,
--- otherwise the only line with exactly the same text. nil if it is gone or ambiguous.
local function locate_task(lines, entry)
  if not entry.line then return lines[entry.line_num] and entry.line_num or nil end
  if lines[entry.line_num] == entry.line then return entry.line_num end
  local found
  for i, l in ipairs(lines) do
    if l == entry.line then
      if found then return nil end
      found = i
    end
  end
  return found
end

local function warn_not_found(entry)
  vim.notify(
    ("[PKB] Task not found in %s (changed since the last scan?): %s")
      :format(vim.fn.fnamemodify(entry.file, ":t"), entry.line or ("line " .. entry.line_num)),
    vim.log.levels.WARN
  )
end

local function log_to_daily_note(entry, completed_line)
  if not M.PKB_ROOT then return end

  local date_str = os.date("%Y-%m-%d", entry.due_ts)
  local note_path = M.PKB_ROOT .. "/" .. date_str .. ".md"

  update_note(note_path, function(lines)
    if #lines == 0 then
      table.insert(lines, "# " .. date_str)
      table.insert(lines, "")
      table.insert(lines, "# morning")
      table.insert(lines, "")
      table.insert(lines, "# afternoon")
      table.insert(lines, "")
      table.insert(lines, "# evening")
      table.insert(lines, "")
    end

    local current_hour = tonumber(os.date("%H"))
    local target_section = "morning"
    if current_hour >= 12 and current_hour < 18 then
      target_section = "afternoon"
    elseif current_hour >= 18 then
      target_section = "evening"
    end

    local section_idx, insert_idx = parser.find_log_insertion_index(lines, target_section)

    if section_idx and insert_idx then
      table.insert(lines, insert_idx, "- " .. completed_line)
    else
      table.insert(lines, "")
      table.insert(lines, target_section)
      table.insert(lines, "- " .. completed_line)
    end
  end)
  return note_path
end

--- A new task id that no known task uses and that does not appear in `lines` (e.g. the note being
--- edited, which may also hold completed tasks and references).
--- @param lines string[]|nil
function M.new_task_id(lines)
  local taken = task_id.collect(lines or {})
  for _, e in pairs(M.notifications) do task_id.collect({ e.line }, taken) end
  return task_id.new_unique(taken)
end

--- The task's id and its line, appending a new task::<id> tag if it has none.
local function ensure_task_id(line, lines)
  local id = task_id.from_line(line)
  if id then
    return id, line
  end
  id = M.new_task_id(lines)
  return id, line .. " " .. task_id.tag(id)
end

--- Warns that a task's recur:: rule is invalid; returns false so update_note leaves the note unchanged.
local function refuse_bad_rule(err)
  vim.notify("[PKB Notify] " .. err .. ". Task not changed; fix its recur:: tag.", vim.log.levels.WARN)
  return false
end

--- Completes a task by changing due:: -> old::, appending done::, and spawning the next instance if recurring.
--- @param entry table Notification entry object
function M.complete_task(entry)
  if not entry or not entry.file or not entry.line_num then return end

  local completed_line
  local applied = update_note(entry.file, function(lines)
    local idx = locate_task(lines, entry)
    if not idx then warn_not_found(entry); return false end

    local original_line = lines[idx]
    local due_str = original_line:match("due::([^%s]+)")
    if not due_str then return false end

    -- Ensure the task has a task::<id>
    local _, updated_original_line = ensure_task_id(original_line, lines)

    local now_iso = require('timestamps.actions').get_timestamp_now()
    local recur_str = parser.parse_recurrence(updated_original_line)
    local next_ts
    if recur_str and entry.due_ts then
      local err
      next_ts, err = parser.calculate_next_due_advanced(entry.due_ts, recur_str)
      if not next_ts then return refuse_bad_rule(err) end
    end

    -- 1. Transform current line: change due:: to old:: and append done::
    completed_line = updated_original_line:gsub("due::" .. vim.pesc(due_str), "old::" .. due_str)
    if recur_str then
      -- Strip recur:: from completed log entry so history stays clean
      completed_line = completed_line:gsub("%s*recur::" .. vim.pesc(recur_str), "")
    end
    completed_line = completed_line .. " done::" .. now_iso

    lines[idx] = completed_line

    -- 2. If task is recurring, calculate next due date and append new active task
    if next_ts then
      local next_iso = require('timestamps.actions').get_timestamp(next_ts)

      -- Construct new task line with next due date and original recur tag
      local next_line = updated_original_line:gsub("due::" .. vim.pesc(due_str), "due::" .. next_iso)
    
      -- Insert new line immediately after completed task
      table.insert(lines, idx + 1, next_line)
    end
  end)
  if not applied then return end

  -- 3. Log to daily note with source file & task::<id> tag (retaining only t-ref for references)
  local relative_file = vim.fn.fnamemodify(entry.file, ":t")
  local logged_line = task_id.untag(completed_line)
  local log_line = string.format("%s (from %s)", logged_line, relative_file)
  local daily_note = log_to_daily_note(entry, log_line)

  -- Mark as dismissed in memory and rescan only the notes that changed
  entry.dismissed = true
  M.rescan_files({ entry.file, daily_note })
end

--- Skips a task. For recurring tasks, archives the current instance as `skipped::` and creates
--- the next occurrence. For non-recurring tasks, defers the due date by 1 day (or archives as skipped).
--- @param entry table Notification entry object
function M.skip_task(entry)
  if not entry or not entry.file or not entry.line_num then return end

  local applied = update_note(entry.file, function(lines)
    local idx = locate_task(lines, entry)
    if not idx then warn_not_found(entry); return false end

    local original_line = lines[idx]
    local due_str = original_line:match("due::([^%s]+)")
    if not due_str then return false end

    local now_iso = require('timestamps.actions').get_timestamp_now()
    local recur_str = parser.parse_recurrence(original_line)

    if recur_str and entry.due_ts then
      local next_ts, err = parser.calculate_next_due_advanced(entry.due_ts, recur_str)
      if not next_ts then return refuse_bad_rule(err) end

      -- 1. Archive current recurring instance as skipped
      local skipped_line = original_line:gsub("due::" .. vim.pesc(due_str), "old::" .. due_str)
      skipped_line = skipped_line:gsub("%s*recur::" .. vim.pesc(recur_str), "")
      skipped_line = skipped_line .. " skipped::" .. now_iso
      lines[idx] = skipped_line

      -- 2. Spawn next recurrence instance
      local next_iso = require('timestamps.actions').get_timestamp(next_ts)
      local next_line = original_line:gsub("due::" .. vim.pesc(due_str), "due::" .. next_iso)
      table.insert(lines, idx + 1, next_line)
    else
      -- For non-recurring tasks, advance due date by 1 day (24 hours)
      local next_ts = (entry.due_ts or os.time()) + 86400
      local next_iso = require('timestamps.actions').get_timestamp(next_ts)
      lines[idx] = original_line:gsub("due::" .. vim.pesc(due_str), "due::" .. next_iso)
    end
  end)
  if not applied then return end

  -- Rescan the changed note
  M.rescan_files({ entry.file })
end

---------------------------------------------------------------
-- COMMANDS & PUBLIC API
---------------------------------------------------------------
--- True if PKB_ROOT is a usable folder. Otherwise warns (once per root value) and returns false.
local warned_root = false
local function root_ok()
  local root = M.PKB_ROOT
  if root and vim.fn.isdirectory(root) == 1 then
    warned_root = false
    return true
  end
  local key = tostring(root)
  if warned_root ~= key then
    warned_root = key
    vim.notify(
      root
        and ("[PKB] PKB root folder not found: %s (notifications are off)"):format(root)
        or "[PKB] No PKB root folder configured: set pkb_root in setup() (e.g. from $PKB_ROOT); notifications are off",
      vim.log.levels.WARN
    )
  end
  return false
end

--- Finish a (full or partial) rescan: drop stale popups, start the poll timer, report.
local function after_rescan()
  -- Clean up popup_queue to keep only active, non-dismissed, non-done unique entries
  local valid_queue = {}
  local seen_queue_ids = {}
  for _, entry in ipairs(M.popup_queue) do
    local fresh = M.notifications[entry.id]
    local is_done = fresh and fresh.line and fresh.line:match("^%s*%- %[[xX]%]")
    if fresh and not fresh.dismissed and not is_done and not seen_queue_ids[entry.id] then
      seen_queue_ids[entry.id] = true
      table.insert(valid_queue, fresh)
    end
  end
  M.popup_queue = valid_queue

  local count = 0
  for _ in pairs(M.notifications) do count = count + 1 end

  start_timer()

  print("PKB notifications rescanned: " .. count)
end

--- Full rescan of PKB_ROOT (startup, :PKBNotify, :PKBInbox).
function M.notify()
  if not root_ok() then return end

  local new_state = {}
  scan_dir(M.notifications, M.PKB_ROOT, new_state)
  M.notifications = new_state
  after_rescan()
end

--- The key a full scan uses for `path` (PKB_ROOT .. "/" .. relative path) if it is a markdown file
--- inside PKB_ROOT, else nil. Handles relative paths, "." / "..", and symlinks (e.g. ~/pkb -> elsewhere).
local function pkb_key(path)
  local function canonical(p)
    return vim.fs.normalize(vim.fn.resolve(vim.fs.normalize(vim.fn.fnamemodify(p, ":p"))))
  end
  if not path:match("%.md$") then return nil end
  local root = canonical(M.PKB_ROOT):gsub("/+$", "")
  local full = canonical(path)
  if full:sub(1, #root + 1) ~= root .. "/" then return nil end
  return M.PKB_ROOT .. "/" .. full:sub(#root + 2)
end

--- Rescan only these notes (e.g. the one just saved); every other note keeps its entries.
--- State follows tasks as in a full scan. Paths outside PKB_ROOT or not *.md are ignored.
--- @param paths string[]
function M.rescan_files(paths)
  if not root_ok() then return end

  local keys, wanted = {}, {}
  for _, p in ipairs(paths) do
    local key = pkb_key(p)
    if key and not wanted[key] then
      wanted[key] = true
      table.insert(keys, key)
    end
  end
  if #keys == 0 then return end

  local previous, kept = {}, {}
  for id, e in pairs(M.notifications) do
    if wanted[e.file] then previous[id] = e else kept[id] = e end
  end
  local fresh = {}
  parser.scan_files(previous, keys, fresh)
  for id, e in pairs(fresh) do kept[id] = e end

  M.notifications = kept
  after_rescan()
end

local pending_paths, pending_timer = {}, nil

--- Rescan `path` after `delay_ms` (default 500); notes queued in the meantime are rescanned together.
--- Meant for BufWritePost, so a burst of saves costs one partial rescan.
function M.queue_rescan(path, delay_ms)
  pending_paths[path] = true
  pending_timer = pending_timer or vim.uv.new_timer()
  pending_timer:stop()
  pending_timer:start(delay_ms or 500, 0, vim.schedule_wrap(function()
    local paths = vim.tbl_keys(pending_paths)
    pending_paths = {}
    M.rescan_files(paths)
  end))
end

--- Open the inbox in the current window: tasks by day, each with its time slot.
--- opts.date ("YYYY-MM-DD"): put the cursor on that day; it is shown even if it has no tasks.
--- A fixed UTC offset for the inbox: "Z"/"UTC", "H"/"S" (home offsets of timestamps-nvim), "+hh:mm", "-hh", "+h".
--- @return integer|nil seconds east of UTC
--- @return string label ("UTC-06:00") or the error message
function M.parse_tz(tz)
  local s = tz
  if s == "Z" or s == "UTC" then return 0, "UTC" end
  if s == "H" or s == "S" then
    local P = require("timestamps.parser")
    s = s == "H" and P.HOME_TZ or P.HOME_SUMMER_TZ
  end
  local sign, hh, mm = s:match("^([%+%-])(%d%d?):(%d%d)$")
  if not sign then
    sign, hh = s:match("^([%+%-])(%d%d?)$")
    mm = "0"
  end
  hh, mm = tonumber(hh), tonumber(mm)
  if not sign or hh > 14 or mm > 59 then
    return nil, ("[PKB] Inbox tz must be a UTC offset like -06:00, +05:30, -6, Z, H or S, got %s"):format(tz)
  end
  local offset = (sign == "-" and -1 or 1) * (hh * 3600 + mm * 60)
  if offset == 0 then return 0, "UTC" end
  return offset, ("UTC%s%02d:%02d"):format(sign, hh, mm)
end

function M.inbox(opts)
  opts = opts or {}
  if opts.date and not opts.date:match("^%d%d%d%d%-%d%d%-%d%d$") then
    vim.notify("[PKB] Inbox date must be YYYY-MM-DD, got " .. opts.date, vim.log.levels.WARN)
    return
  end
  local tz_offset, tz_label
  if opts.tz then
    tz_offset, tz_label = M.parse_tz(opts.tz)
    if not tz_offset then
      vim.notify(tz_label, vim.log.levels.WARN)
      return
    end
  end
  M.notify()

  if vim.tbl_isempty(M.notifications) and not opts.date then
    vim.notify("No PKB notifications", vim.log.levels.INFO)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local render_opts = { root = M.PKB_ROOT, focus_date = opts.date, tz_offset = tz_offset, tz_label = tz_label }
  -- Long lines (narrow phone screens) wrap at a word and continue under the task text, not under the status.
  -- [0] makes these local to the inbox buffer in its window (like :setlocal), so the next buffer is unaffected.
  -- The text column can change between renders (a past-midnight slot widens it), so it is set after each one.
  local function render()
    local focus, text_column = render_inbox(M.notifications, M.inbox_show_all, M.DEFAULT_HORIZON, buf, render_opts)
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.wo[win][0].breakindentopt = "shift:" .. text_column
    end
    return focus, text_column
  end

  local focus_row, text_column = render()
  vim.api.nvim_set_current_buf(buf)
  local wo = vim.wo[0][0]
  wo.wrap = true
  wo.linebreak = true
  wo.breakindent = true
  wo.breakindentopt = "shift:" .. text_column
  if focus_row then
    vim.api.nvim_win_set_cursor(0, { focus_row, 0 })
  end

  -- d → dismiss
  vim.keymap.set("n", "d", function()
    local n = get_notification_at_cursor(buf)
    if n then
      n.dismissed = true
      render()
    end
  end, { buffer = buf })

  -- <CR> → open task
  vim.keymap.set("n", "<CR>", function()
    local n = get_notification_at_cursor(buf)
    if not n then return end

    vim.cmd("edit " .. vim.fn.fnameescape(n.file))
    vim.api.nvim_win_set_cursor(0, {1, 0})
    vim.fn.search(vim.fn.escape(n.line, "\\/.*$^~[]"), "W")

  end, { buffer = buf })

  -- t → toggle view
  vim.keymap.set("n", "t", function()
    M.inbox_show_all = not M.inbox_show_all
    render()
  end, { buffer = buf })

  -- q → close
  vim.keymap.set("n", "q", function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, { buffer = buf })

  -- c → complete task (due:: -> old::, done::, + next recur)
  vim.keymap.set("n", "c", function()
    local n = get_notification_at_cursor(buf)
    if n then
      M.complete_task(n)
      render()
    end
  end, { buffer = buf })

  -- s → skip task
  vim.keymap.set("n", "s", function()
    local n = get_notification_at_cursor(buf)
    if n then
      M.skip_task(n)
      render()
    end
  end, { buffer = buf })
end

--- Open the inbox on a day (calendar-nvim's open_day callback).
function M.open_day(year, month, day)
  M.inbox({ date = string.format("%04d-%02d-%02d", year, month, day) })
end

-- User commands are defined in plugin/pkb.lua, not here, so requiring this module has no side effects.

return M
