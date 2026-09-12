-- ============================================================
-- PKB Notifier — Consolidated Digest & Smart Auto-Snooze
-- ============================================================

local M = {}
---------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------
M.DEFAULT_NOTIFY = "15min"
M.POLL_INTERVAL = 30000        -- Poll every 30 seconds (ms)
M.SNOOZE_INTERVAL = 30 * 60    -- Auto-snooze for 30 minutes (seconds) when closed with [q]
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
  end
  if opts.poll_interval then
    M.POLL_INTERVAL = opts.poll_interval
  end
  if opts.snooze_interval then
    M.SNOOZE_INTERVAL = opts.snooze_interval
  end
  if opts.default_horizon then
    M.DEFAULT_HORIZON = opts.default_horizon * 86400
  end
end

local parser = require("pkb.parser")
parser.setup({ DEFAULT_NOTIFY = M.DEFAULT_NOTIFY })
local scan_dir = require("pkb.parser").scan_dir

local termux_notification = require("pkb.termux_notification")
phone_notify_digest = termux_notification.phone_notify_digest

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
  show_next_popup(M.popup_queue, M.SNOOZE_INTERVAL)
end

local function start_timer()
  if not M.timer then
    M.timer = vim.loop.new_timer()
    M.timer:start(0, M.POLL_INTERVAL, vim.schedule_wrap(function()
      check_notifications()
    end))
  end
end

local function log_to_daily_note(entry, completed_line)
  if not M.PKB_ROOT then return end

  local date_str = os.date("%Y-%m-%d", entry.due_ts)
  local note_path = M.PKB_ROOT .. "/" .. date_str .. ".md"

  local lines = {}
  if vim.fn.filereadable(note_path) == 1 then
    lines = vim.fn.readfile(note_path)
  else
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

  vim.fn.writefile(lines, note_path)
end

--- Completes a task by changing due:: -> old::, appending done::, and spawning the next instance if recurring.
--- @param entry table Notification entry object
function M.complete_task(entry)
  if not entry or not entry.file or not entry.line_num then return end

  local ok, lines = pcall(vim.fn.readfile, entry.file)
  if not ok or not lines[entry.line_num] then return end

  local original_line = lines[entry.line_num]
  local due_str = original_line:match("due::([^%s]+)")
  if not due_str then return end

  local now_iso = require('timestamps.actions').get_timestamp_now()
  local recur_str = parser.parse_recurrence(original_line)

  -- 1. Transform current line: change due:: to old:: and append done::
  local completed_line = original_line:gsub("due::" .. vim.pesc(due_str), "old::" .. due_str)
  if recur_str then
    -- Strip recur:: from completed log entry so history stays clean
    completed_line = completed_line:gsub("%s*recur::" .. vim.pesc(recur_str), "")
  end
  completed_line = completed_line .. " done::" .. now_iso

  lines[entry.line_num] = completed_line

  -- 2. If task is recurring, calculate next due date and append new active task
  if recur_str and entry.due_ts then
    local next_ts = parser.calculate_next_due_advanced(entry.due_ts, recur_str)
    local next_iso = require('timestamps.actions').get_timestamp(next_ts)

    -- Construct new task line with next due date and original recur tag
    local next_line = original_line:gsub("due::" .. vim.pesc(due_str), "due::" .. next_iso)
    
    -- Insert new line immediately after completed task
    table.insert(lines, entry.line_num + 1, next_line)
  end

  -- Write changes back to file
  vim.fn.writefile(lines, entry.file)
  log_to_daily_note(entry, completed_line)

  -- Reload current buffer if open in Neovim
  local bufnr = vim.fn.bufnr(entry.file)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("edit!")
    end)
  end

  -- Mark as dismissed in memory and rescan
  entry.dismissed = true
  M.notify()
end

---------------------------------------------------------------
-- COMMANDS & PUBLIC API
---------------------------------------------------------------
function M.notify()
  local new_state = {}
  scan_dir(M.notifications, M.PKB_ROOT, new_state)

  M.notifications = new_state

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

function M.inbox()
  M.notify()
  local function get_notification_list()
    local list = {}
    for _, n in pairs(M.notifications) do
      table.insert(list, n)
    end
    return list
  end

  if #get_notification_list() == 0 then
    vim.notify("No PKB notifications", vim.log.levels.INFO)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  render_inbox(M.notifications, M.inbox_show_all, M.DEFAULT_HORIZON, buf)
  vim.api.nvim_set_current_buf(buf)

  -- d → dismiss
  vim.keymap.set("n", "d", function()
    local n = get_notification_at_cursor(buf)
    if n then
      n.dismissed = true
      render_inbox(M.notifications, M.inbox_show_all, M.DEFAULT_HORIZON, buf)
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
    render_inbox(M.notifications, M.inbox_show_all, M.DEFAULT_HORIZON, buf)
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
      render_inbox(M.notifications, M.inbox_show_all, M.DEFAULT_HORIZON, buf)
    end
  end, { buffer = buf })
end

---------------------------------------------------------------
-- SETUP
---------------------------------------------------------------
vim.api.nvim_create_user_command("PKBNotify", M.notify, {})
vim.api.nvim_create_user_command("PKBInbox",  M.inbox,  {})

return M
