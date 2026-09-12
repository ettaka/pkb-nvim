local M = {}

----------------------------------------------------------------
-- DIGEST STATE
--
-- There is only ever one notification popup.
--
-- popup_queue:
--   Notifications waiting to be added to the digest.
--
-- popup_batch:
--   Notifications currently displayed in the digest.
--
-- popup_win / popup_buf:
--   The single floating window and its buffer.
----------------------------------------------------------------

local popup_win = nil
local popup_buf = nil
local popup_batch = {}

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

local function popup_is_valid()
  return popup_win ~= nil
    and vim.api.nvim_win_is_valid(popup_win)
end

local function clear_popup_state()
  popup_win = nil
  popup_buf = nil
  popup_batch = {}
end

local function close_popup()
  if popup_is_valid() then
    vim.api.nvim_win_close(popup_win, true)
  end

  clear_popup_state()
end

----------------------------------------------------------------
-- Render the current digest into the existing buffer.
----------------------------------------------------------------

local function render_digest(snooz_interval)
  if not popup_buf
      or not vim.api.nvim_buf_is_valid(popup_buf) then
    return
  end

  local lines = {
    string.format(
      "🔔 PKB Digest — %d Tasks Need Attention",
      #popup_batch
    ),
    "",
  }

  for i, entry in ipairs(popup_batch) do
    table.insert(
      lines,
      string.format("%d. %s", i, entry.line)
    )

    table.insert(
      lines,
      string.format(
        "   Due: %s | File: %s",
        os.date("%Y-%m-%d %H:%M", entry.due_ts),
        entry.file
      )
    )

    table.insert(lines, "")
  end

  table.insert(
    lines,
    "[Enter] open inbox  |  [q] snooze all (" ..
      math.floor(snooz_interval / 60) .. "m)"
  )

  vim.bo[popup_buf].modifiable = true

  vim.api.nvim_buf_set_lines(
    popup_buf,
    0,
    -1,
    false,
    lines
  )

  vim.bo[popup_buf].modifiable = false

  -- Keep the window height correct if the digest grows.
  if popup_is_valid() then
    local width = math.min(90, vim.o.columns - 4)
    local height = #lines + 2

    vim.api.nvim_win_set_config(popup_win, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      border = "rounded",
      style = "minimal",
    })
  end
end

----------------------------------------------------------------
-- Create the digest popup.
----------------------------------------------------------------

local function create_popup(snooz_interval)
  if #popup_batch == 0 then
    return
  end

  if vim.fn.mode() ~= "n" then
    vim.cmd("stopinsert")
  end

  popup_buf = vim.api.nvim_create_buf(false, true)

  vim.bo[popup_buf].bufhidden = "wipe"
  vim.bo[popup_buf].modifiable = false

  -- Render once so that we know the required height.
  local lines = {
    string.format(
      "🔔 PKB Digest — %d Tasks Need Attention",
      #popup_batch
    ),
    "",
  }

  for i, entry in ipairs(popup_batch) do
    table.insert(
      lines,
      string.format("%d. %s", i, entry.line)
    )

    table.insert(
      lines,
      string.format(
        "   Due: %s | File: %s",
        os.date("%Y-%m-%d %H:%M", entry.due_ts),
        entry.file
      )
    )

    table.insert(lines, "")
  end

  table.insert(
    lines,
    "[Enter] open inbox  |  [q] snooze all (" ..
      math.floor(snooz_interval / 60) .. "m)"
  )

  vim.bo[popup_buf].modifiable = true

  vim.api.nvim_buf_set_lines(
    popup_buf,
    0,
    -1,
    false,
    lines
  )

  vim.bo[popup_buf].modifiable = false

  local width = math.min(90, vim.o.columns - 4)
  local height = #lines + 2

  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  popup_win = vim.api.nvim_open_win(popup_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    style = "minimal",
  })

  ----------------------------------------------------------------
  -- ENTER
  --
  -- The digest is opened as a whole. Individual tasks are not
  -- selected here; PKBInbox handles the task list.
  ----------------------------------------------------------------

  vim.keymap.set("n", "<CR>", function()
    if not popup_is_valid() then
      return
    end

    close_popup()

    require("pkb.notifier").inbox()
  end, {
    buffer = popup_buf,
    nowait = true,
    silent = true,
  })

  ----------------------------------------------------------------
  -- Q
  --
  -- Snooze everything currently shown in the digest.
  ----------------------------------------------------------------

  vim.keymap.set("n", "q", function()
    if not popup_is_valid() then
      return
    end

    local snooze_until = os.time() + snooz_interval

    for _, entry in ipairs(popup_batch) do
      entry.auto_snoozed_until = snooze_until
    end

    close_popup()
  end, {
    buffer = popup_buf,
    nowait = true,
    silent = true,
  })

  ----------------------------------------------------------------
  -- D
  --
  -- Optional: keep your existing dismiss behavior for a single
  -- notification only when the digest contains exactly one task.
  --
  -- For multiple tasks, do nothing because the digest represents
  -- the whole batch.
  ----------------------------------------------------------------

  vim.keymap.set("n", "d", function()
    if not popup_is_valid() then
      return
    end

    if #popup_batch == 1 then
      popup_batch[1].dismissed = true
      close_popup()
    end
  end, {
    buffer = popup_buf,
    nowait = true,
    silent = true,
  })
end

----------------------------------------------------------------
-- SHOW / UPDATE DIGEST
--
-- This is the only public function needed by the caller.
--
-- New notifications are appended to the existing digest if one
-- is already visible.
----------------------------------------------------------------

function M.show_next_popup(popup_queue, snooz_interval)
  ----------------------------------------------------------------
  -- Move everything waiting in the queue into the current batch,
  -- ensuring uniqueness by task ID.
  ----------------------------------------------------------------

  local batch_ids = {}
  for _, entry in ipairs(popup_batch) do
    batch_ids[entry.id] = true
  end

  while #popup_queue > 0 do
    local entry = table.remove(popup_queue, 1)
    if not batch_ids[entry.id] then
      batch_ids[entry.id] = true
      table.insert(popup_batch, entry)
    end
  end

  if #popup_batch == 0 then
    return
  end

  ----------------------------------------------------------------
  -- If the digest already exists, simply update it.
  ----------------------------------------------------------------

  if popup_is_valid() then
    render_digest(snooz_interval)
    return
  end

  ----------------------------------------------------------------
  -- No digest exists, so create the one floating window.
  ----------------------------------------------------------------

  vim.schedule(function()
    if #popup_batch == 0 then
      return
    end

    if popup_is_valid() then
      render_digest(snooz_interval)
      return
    end

    create_popup(snooz_interval)
  end)
end

return M
