-- pkb.notifier: rescans, and the code paths that REWRITE note files (complete/skip).
-- Everything runs in a temporary PKB_ROOT. Known issue numbers refer to the PKB guide (toolsrc pkb-dev/AGENTS.md).
local H = require("tests.helpers")
local t = H.suite()

local notifier, find = require("tests.pkb").notifier, require("tests.pkb").find

local function read(path) return vim.fn.readfile(path) end

---------------------------------------------------------------- notify / rescan
t.test("notify() scans PKB_ROOT and drops tasks that disappeared", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z", "- [ ] b due::2026-11-10T09:00Z" })
  local n = notifier(root)
  n.notify()
  H.eq(vim.tbl_count(n.notifications), 2)
  H.write(f, { "- [ ] a due::2026-11-10T08:00Z" })
  n.notify()
  H.eq(vim.tbl_count(n.notifications), 1)
end)

---------------------------------------------------------------- missing PKB root (known issue 9)
local function warnings()
  return vim.tbl_filter(function(m) return m:find("PKB", 1, true) and m:find("root", 1, true) end, H.messages)
end

t.test("notify() without pkb_root warns instead of crashing", function()
  local n = notifier(nil)
  n.notify()
  H.eq(#warnings(), 1, vim.inspect(H.messages))
  H.has(warnings()[1], "pkb_root")
  H.eq(n.timer, nil, "no poll timer without a root")
end)

t.test("notify() with a missing pkb_root folder warns instead of scanning", function()
  local root = H.tmpdir() .. "/not-there"
  local n = notifier(root)
  n.notify()
  H.eq(#warnings(), 1, vim.inspect(H.messages))
  H.has(warnings()[1], root)
  H.eq(n.notifications, {})
end)

t.test("the missing-root warning is shown once, not on every rescan", function()
  local n = notifier(nil)
  n.notify()
  n.notify()
  n.notify()
  H.eq(#warnings(), 1)
end)

t.test("inbox() without pkb_root does not crash", function()
  local n = notifier(nil)
  n.inbox()
  H.ok(#warnings() >= 1)
end)

t.test("setting pkb_root later makes notify() work", function()
  local n = notifier(nil)
  n.notify()
  local root = H.tmpdir()
  H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z" })
  n.setup({ pkb_root = root })
  n.notify()
  H.eq(vim.tbl_count(n.notifications), 1)
end)

t.test("scan_dir ignores a nil path", function()
  local out = {}
  require("pkb.parser").scan_dir({}, nil, out)
  H.eq(out, {})
end)

t.test("setup{default_notify} is used when a task has no notify:: tag", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z" })
  local n = notifier(root, { default_notify = "1h" })
  n.notify()
  local e = find(n, "- [ ] a")
  H.eq(e.due_ts - e.notify_ts, 3600)
end)

t.test("default notify is 30min when setup does not set it", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z" })
  local n = notifier(root)
  n.notify()
  local e = find(n, "- [ ] a")
  H.eq(e.due_ts - e.notify_ts, 1800)
end)

t.test("explicit notify:: wins over setup{default_notify}", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z notify::2h" })
  local n = notifier(root, { default_notify = "1day" })
  n.notify()
  local e = find(n, "- [ ] a")
  H.eq(e.due_ts - e.notify_ts, 7200)
end)

t.test("calling setup again changes the default for the next scan", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z" })
  local n = notifier(root, { default_notify = "1h" })
  n.notify()
  n.setup({ default_notify = "30min" })
  n.notify()
  local e = find(n, "- [ ] a")
  H.eq(e.due_ts - e.notify_ts, 1800)
end)

---------------------------------------------------------------- reminders and snooze
-- The first reminder is at notify:: (default 30min) before due. Snoozing ([q]) hides a task until the next
-- follow-up reminder (15, 10, 5 and 0 min before due), but never for longer than the snooze interval (30 min).
local DUE = 1000000

local function wakes(n, entry, from, count)
  local out, now = {}, from
  for _ = 1, count do
    now = n.snooze_until(entry, now)
    table.insert(out, (now - DUE) / 60)
  end
  return out
end

t.test("snoozing after the first reminder wakes at 15, 10, 5 and 0 min before due, then every 30 min", function()
  local n = notifier(H.tmpdir())
  H.eq(wakes(n, { due_ts = DUE }, DUE - 1800, 7), { -15, -10, -5, 0, 30, 60, 90 })
end)

t.test("snoozing between follow-ups wakes at the next one", function()
  local n = notifier(H.tmpdir())
  H.eq(wakes(n, { due_ts = DUE }, DUE - 12 * 60, 1), { -10 })
end)

t.test("an early first reminder snoozes 30 min at a time until the follow-ups", function()
  local n = notifier(H.tmpdir())
  H.eq(wakes(n, { due_ts = DUE }, DUE - 7200, 6), { -90, -60, -30, -15, -10, -5 })
end)

t.test("a short notify:: only gets the follow-ups after it", function()
  local n = notifier(H.tmpdir())
  H.eq(wakes(n, { due_ts = DUE }, DUE - 600, 3), { -5, 0, 30 })
end)

t.test("setup{remind_before} sets the follow-ups; {} turns them off", function()
  local n = notifier(H.tmpdir(), { remind_before = { "20min", "1min" } })
  H.eq(wakes(n, { due_ts = DUE }, DUE - 1800, 3), { -20, -1, 29 })
  n.setup({ remind_before = {} })
  H.eq(wakes(n, { due_ts = DUE }, DUE - 1800, 2), { 0, 30 })
end)

t.test("setup{snooze_interval} caps the snooze", function()
  local n = notifier(H.tmpdir(), { snooze_interval = 300 })
  H.eq(wakes(n, { due_ts = DUE }, DUE - 1800, 7), { -25, -20, -15, -10, -5, 0, 5 })
end)

t.test("[q] in the digest popup snoozes each task until its own next reminder", function()
  local n = notifier(H.tmpdir())
  local now = os.time()
  local a = { id = "a", line = "- [ ] a", file = "t.md", due_ts = now + 14 * 60, notify_ts = now - 60 }
  local b = { id = "b", line = "- [ ] b", file = "t.md", due_ts = now + 3600, notify_ts = now - 60 }
  local ui = require("pkb.ui")
  ui.show_next_popup({ a, b }, n.snooze_until)
  local win
  vim.wait(1000, function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then win = w end
    end
    return win ~= nil
  end)
  assert(win, "no popup")
  local buf = vim.api.nvim_win_get_buf(win)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  H.has(lines[#lines], "[q] snooze all (next at " .. os.date("%H:%M", now + 4 * 60) .. ")")
  vim.api.nvim_buf_call(buf, function() vim.fn.maparg("q", "n", false, true).callback() end)
  H.eq({ a.auto_snoozed_until - now, b.auto_snoozed_until - now }, { 4 * 60, 1800 })
  H.ok(not vim.api.nvim_win_is_valid(win))
end)

---------------------------------------------------------------- state follows the task (known issue 3)
-- Dismissed/triggered/snoozed state is matched by line text (same file), else by task:: id with the same due time.

--- Scan, dismiss the task containing `needle`, rewrite the file, rescan; returns the notifier.
local function dismiss_then_rewrite(root, path, before, needle, after)
  H.write(path, before)
  local n = notifier(root)
  n.notify()
  local e = find(n, needle)
  e.dismissed, e.triggered, e.auto_snoozed_until = true, true, 42
  H.write(path, after)
  n.notify()
  return n
end

t.test("dismissed state follows the task when lines above it are inserted", function()
  local root = H.tmpdir()
  local n = dismiss_then_rewrite(root, root .. "/t.md",
    { "- [ ] a due::2026-11-10T08:00Z" }, "- [ ] a",
    { "- [ ] new due::2026-11-11T08:00Z", "- [ ] a due::2026-11-10T08:00Z" })
  H.eq(find(n, "- [ ] a").dismissed, true, "task a")
  H.eq(find(n, "- [ ] new").dismissed, false, "new task")
end)

t.test("all state (dismissed, triggered, snooze) follows the task when lines above are removed", function()
  local root = H.tmpdir()
  local n = dismiss_then_rewrite(root, root .. "/t.md",
    { "intro", "more intro", "- [ ] a due::2026-11-10T08:00Z" }, "- [ ] a",
    { "- [ ] a due::2026-11-10T08:00Z" })
  local e = find(n, "- [ ] a")
  H.eq({ e.dismissed, e.triggered, e.auto_snoozed_until, e.line_num }, { true, true, 42, 1 })
end)

t.test("a task that takes over a dismissed task's line number starts fresh", function()
  local root = H.tmpdir()
  local n = dismiss_then_rewrite(root, root .. "/t.md",
    { "- [ ] a due::2026-11-10T08:00Z", "- [ ] b due::2026-11-10T09:00Z" }, "- [ ] a",
    { "- [ ] b due::2026-11-10T09:00Z" })
  H.eq(find(n, "- [ ] b").dismissed, false)
end)

t.test("identical task lines keep their own state, in order", function()
  local root = H.tmpdir()
  local f = root .. "/t.md"
  H.write(f, { "- [ ] same due::2026-11-10T08:00Z", "- [ ] same due::2026-11-10T08:00Z" })
  local n = notifier(root)
  n.notify()
  n.notifications[f .. ":1"].dismissed = true
  H.write(f, { "header", "- [ ] same due::2026-11-10T08:00Z", "- [ ] same due::2026-11-10T08:00Z" })
  n.notify()
  H.eq({ n.notifications[f .. ":2"].dismissed, n.notifications[f .. ":3"].dismissed }, { true, false })
end)

t.test("changing a task's due date gives a fresh reminder", function()
  local root = H.tmpdir()
  local n = dismiss_then_rewrite(root, root .. "/t.md",
    { "- [ ] a due::2026-11-10T08:00Z" }, "- [ ] a",
    { "- [ ] a due::2026-11-12T08:00Z" })
  H.eq(find(n, "- [ ] a").dismissed, false)
end)

t.test("with a task:: id, state survives editing the description", function()
  local root = H.tmpdir()
  local n = dismiss_then_rewrite(root, root .. "/t.md",
    { "- [ ] call bank due::2026-11-10T08:00Z task::t-2026-01-01T10:00" }, "call bank",
    { "- [ ] call the bank about the loan due::2026-11-10T08:00Z task::t-2026-01-01T10:00" })
  H.eq(find(n, "about the loan").dismissed, true)
end)

t.test("with a task:: id, state survives moving the task to another file", function()
  local root = H.tmpdir()
  H.write(root .. "/b.md", {})
  local n = dismiss_then_rewrite(root, root .. "/a.md",
    { "- [ ] call bank due::2026-11-10T08:00Z task::t-2026-01-01T10:00" }, "call bank", {})
  H.write(root .. "/b.md", { "# moved", "- [ ] call bank due::2026-11-10T08:00Z task::t-2026-01-01T10:00" })
  n.notify()
  local e = find(n, "call bank")
  H.eq({ e.file, e.dismissed }, { root .. "/b.md", true })
end)

t.test("with a task:: id, changing the due date still gives a fresh reminder", function()
  local root = H.tmpdir()
  local n = dismiss_then_rewrite(root, root .. "/t.md",
    { "- [ ] call bank due::2026-11-10T08:00Z task::t-2026-01-01T10:00" }, "call bank",
    { "- [ ] call bank due::2026-11-11T08:00Z task::t-2026-01-01T10:00" })
  H.eq(find(n, "call bank").dismissed, false)
end)

t.test("completing a recurring task: the next instance is not dismissed", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", { "- [ ] stretch due::2026-11-10T08:00Z recur::daily" })
  local n = notifier(root)
  n.notify()
  n.complete_task(find(n, "stretch"))
  local next_entry = find(n, "recur::daily")
  H.eq({ next_entry.dismissed, next_entry.triggered }, { false, false })
end)

---------------------------------------------------------------- complete_task
t.test("complete: due:: -> old::, done:: appended, task id added", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/tasks.md", { "# t", "- [ ] write report due::2026-11-10T08:00Z effort::2h" })
  local n = notifier(root)
  n.notify()
  n.complete_task(find(n, "write report"))
  local lines = read(f)
  H.eq(#lines, 2, "no extra line for a non-recurring task")
  local l = lines[2]
  H.has(l, "old::2026-11-10T08:00Z")
  H.ok(not l:find("due::", 1, true), "due:: still present: " .. l)
  H.ok(l:match("task::t%-%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d"), "no task id: " .. l)
  H.ok(l:match("done::%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d"), "no done:: timestamp: " .. l)
  H.has(l, "effort::2h")
end)

t.test("complete: two tasks completed in the same minute get different ids", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z", "- [ ] b due::2026-11-10T09:00Z" })
  local n = notifier(root)
  n.notify()
  n.complete_task(find(n, "- [ ] a"))
  n.complete_task(find(n, "- [ ] b"))
  local ids = vim.tbl_map(function(l) return require("pkb.task_id").from_line(l) end, read(f))
  H.ok(ids[1] and ids[2] and ids[1] ~= ids[2], vim.inspect(read(f)))
end)

t.test("new_task_id avoids ids used by tasks and in the given lines", function()
  local root = H.tmpdir()
  local now = require("pkb.task_id").new()
  H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z task::" .. now })
  local n = notifier(root)
  n.notify()
  local next_min = require("pkb.task_id").new(os.time() + 60)
  local id = n.new_task_id({ "ref " .. next_min })
  H.ok(id ~= now and id ~= next_min, id)
end)

t.test("complete: an existing task id is kept, not duplicated", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "- [ ] x due::2026-11-10T08:00Z task::t-2026-01-01T10:00" })
  local n = notifier(root)
  n.notify()
  n.complete_task(find(n, "- [ ] x"))
  local l = read(f)[1]
  local _, count = l:gsub("task::", "")
  H.eq(count, 1, l)
  H.has(l, "task::t-2026-01-01T10:00")
end)

t.test("complete recurring: next instance inserted below with the next due date", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "- [ ] water plants due::2026-11-10T08:00Z recur::2d", "- [ ] other" })
  local n = notifier(root)
  n.notify()
  n.complete_task(find(n, "water plants"))
  local lines = read(f)
  H.eq(#lines, 3)
  H.has(lines[1], "old::2026-11-10T08:00Z")
  H.ok(not lines[1]:find("recur::", 1, true), "recur:: kept on the completed line: " .. lines[1])
  H.has(lines[2], "recur::2d")
  H.ok(not lines[2]:find("done::", 1, true), "next instance marked done: " .. lines[2])
  -- 2 days later, same instant; written in local time with the current zone suffix
  local next_due = require("timestamps.parser").parse_iso(lines[2]:match("due::(%S+)"))
  H.eq(next_due, 1794297600 + 2 * 86400)
  H.eq(lines[3], "- [ ] other")
end)

t.test("complete: logged to the daily note of the due date", function()
  local root = H.tmpdir()
  H.write(root .. "/tasks.md", { "- [ ] write report due::2026-11-10T08:00Z" })
  local n = notifier(root)
  n.notify()
  n.complete_task(find(n, "write report"))
  local note = root .. "/" .. os.date("%Y-%m-%d", 1794297600) .. ".md"
  H.eq(vim.fn.filereadable(note), 1, "daily note not created")
  local lines = read(note)
  local headings = vim.tbl_filter(function(l) return l:match("^# ") end, lines)
  H.eq(headings, { "# 2026-11-10", "# morning", "# afternoon", "# evening" })
  local logged = vim.tbl_filter(function(l) return l:find("write report", 1, true) end, lines)
  H.eq(#logged, 1)
  H.has(logged[1], "(from tasks.md)")
  H.ok(logged[1]:match("^%- %- %[ %] write report"), logged[1])
  H.ok(logged[1]:find(" t-", 1, true) and not logged[1]:find("task::", 1, true), "task:: not shortened: " .. logged[1])
end)

t.test("complete: appends to an existing daily note without losing content", function()
  local root = H.tmpdir()
  H.write(root .. "/tasks.md", { "- [ ] write report due::2026-11-10T08:00Z" })
  local existing = { "# 2026-11-10", "", "# morning", "- coffee", "", "# afternoon", "- lunch", "", "# evening", "- sleep" }
  local note = H.write(root .. "/2026-11-10.md", existing)
  local n = notifier(root)
  n.notify()
  n.complete_task(find(n, "write report"))
  local lines = read(note)
  H.eq(#lines, #existing + 1)
  local without = vim.tbl_filter(function(l) return not l:find("write report", 1, true) end, lines)
  H.eq(without, existing)
end)

t.test("complete recurring writes the next instance at the same local time across DST", function()
  -- autumn: due in summer time (+03:00), next instance in winter time (H = +02:00); spring: the reverse
  for _, c in ipairs({
    { "2026-10-24T09:00+03:00", "2026-10-25T09:00H" },
    { "2026-03-28T09:00H", "2026-03-29T09:00S" },
  }) do
    local root = H.tmpdir()
    local f = H.write(root .. "/t.md", { "- [ ] stretch due::" .. c[1] .. " recur::daily" })
    local n = notifier(root)
    n.notify()
    n.complete_task(find(n, "stretch"))
    local next_line = read(f)[2]
    local parse = require("timestamps.parser").parse_iso
    H.eq(parse(next_line:match("due::(%S+)")), parse(c[2]), next_line) -- 09:00 local on the next day
    H.has(next_line, "recur::daily")
  end
end)

---------------------------------------------------------------- open buffers (known issue 1)
-- When a note is open in a buffer, the change is made in the buffer. Unsaved edits are kept; the buffer is
-- written only if it had no unsaved changes before.

--- Open path in the current window, optionally replace its lines without saving.
local function open(path, unsaved_lines)
  vim.cmd.edit(vim.fn.fnameescape(path))
  if unsaved_lines then vim.api.nvim_buf_set_lines(0, 0, -1, false, unsaved_lines) end
  return vim.api.nvim_get_current_buf()
end
local function buf_lines(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end

t.test("complete keeps unsaved edits in an open buffer of the same file", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z", "notes" })
  local n = notifier(root)
  n.notify()
  local buf = open(f, { "- [ ] a due::2026-11-10T08:00Z", "notes I have not saved yet" })
  n.complete_task(find(n, "- [ ] a"))
  local lines = buf_lines(buf)
  H.eq(lines[2], "notes I have not saved yet")
  H.has(lines[1], "old::2026-11-10T08:00Z")
  H.eq(vim.bo[buf].modified, true, "buffer should stay modified")
  H.eq(read(f), { "- [ ] a due::2026-11-10T08:00Z", "notes" }, "disk must not change before the user saves")
  H.has(table.concat(H.messages, "\n"), "unsaved")
end)

t.test("complete finds the task when unsaved edits moved it", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z", "- [ ] b due::2026-11-10T09:00Z" })
  local n = notifier(root)
  n.notify()
  local buf = open(f, { "new line", "- [ ] a due::2026-11-10T08:00Z", "- [ ] b due::2026-11-10T09:00Z" })
  n.complete_task(find(n, "- [ ] a")) -- scanned from disk as line 1
  local lines = buf_lines(buf)
  H.eq(lines[1], "new line")
  H.has(lines[2], "old::2026-11-10T08:00Z")
  H.eq(lines[3], "- [ ] b due::2026-11-10T09:00Z")
end)

t.test("complete does nothing when the task line was changed in the buffer", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z" })
  local n = notifier(root)
  n.notify()
  local buf = open(f, { "- [ ] a due::2026-11-12T08:00Z" })
  n.complete_task(find(n, "- [ ] a"))
  H.eq(buf_lines(buf), { "- [ ] a due::2026-11-12T08:00Z" })
  H.eq(read(f), { "- [ ] a due::2026-11-10T08:00Z" })
  H.has(table.concat(H.messages, "\n"), "not found")
end)

t.test("complete does nothing when the task line is ambiguous in the buffer", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z" })
  local n = notifier(root)
  n.notify()
  local dup = { "x", "- [ ] a due::2026-11-10T08:00Z", "- [ ] a due::2026-11-10T08:00Z" }
  local buf = open(f, dup)
  n.complete_task(find(n, "- [ ] a"))
  H.eq(buf_lines(buf), dup)
end)

t.test("complete in an open buffer without unsaved edits saves it", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z" })
  local n = notifier(root)
  n.notify()
  local buf = open(f)
  n.complete_task(find(n, "- [ ] a"))
  H.has(buf_lines(buf)[1], "old::")
  H.has(read(f)[1], "old::")
  H.eq(vim.bo[buf].modified, false)
end)

t.test("complete logs into an open daily note without losing its unsaved edits", function()
  local root = H.tmpdir()
  H.write(root .. "/tasks.md", { "- [ ] write report due::2026-11-10T08:00Z" })
  local note = H.write(root .. "/2026-11-10.md", { "# 2026-11-10", "", "# morning", "", "# afternoon", "", "# evening", "" })
  local n = notifier(root)
  n.notify()
  local buf = open(note, { "# 2026-11-10", "unsaved thought", "", "# morning", "", "# afternoon", "", "# evening", "" })
  n.complete_task(find(n, "write report"))
  local lines = buf_lines(buf)
  H.eq(lines[2], "unsaved thought")
  H.eq(#vim.tbl_filter(function(l) return l:find("write report", 1, true) end, lines), 1)
end)

t.test("skip keeps unsaved edits in an open buffer", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "- [ ] gym due::2026-11-10T08:00Z recur::weekly", "notes" })
  local n = notifier(root)
  n.notify()
  local buf = open(f, { "- [ ] gym due::2026-11-10T08:00Z recur::weekly", "unsaved notes" })
  n.skip_task(find(n, "gym"))
  local lines = buf_lines(buf)
  H.ok(lines[1]:match("skipped::%d"), lines[1])
  H.has(lines[2], "recur::weekly")
  H.eq(lines[3], "unsaved notes")
end)

t.test(":PKBComplete in a modified buffer completes the line under the cursor", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z", "- [ ] b due::2026-11-10T09:00Z" })
  notifier(root).notify()
  vim.cmd.source(H.root .. "/plugin/pkb.lua")
  local buf = open(f, { "- [ ] b due::2026-11-10T09:00Z", "- [ ] a due::2026-11-10T08:00Z" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- on "a", which is line 1 on disk
  vim.cmd("PKBComplete")
  local lines = buf_lines(buf)
  H.eq(lines[1], "- [ ] b due::2026-11-10T09:00Z")
  H.has(lines[2], "- [ ] a old::2026-11-10T08:00Z")
end)

---------------------------------------------------------------- skip_task
t.test("skip recurring: archived as skipped::, next instance created", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "- [ ] gym due::2026-11-10T08:00Z recur::weekly" })
  local n = notifier(root)
  n.notify()
  n.skip_task(find(n, "gym"))
  local lines = read(f)
  H.eq(#lines, 2)
  H.has(lines[1], "old::2026-11-10T08:00Z")
  H.ok(lines[1]:match("skipped::%d"), lines[1])
  H.ok(not lines[1]:find("recur::", 1, true), lines[1])
  H.has(lines[2], "recur::weekly")
  H.eq(require("timestamps.parser").parse_iso(lines[2]:match("due::(%S+)")), 1794297600 + 7 * 86400)
end)

t.test("skip non-recurring: due date moves one day, nothing archived", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "- [ ] call bank due::2026-11-10T08:00Z" })
  local n = notifier(root)
  n.notify()
  n.skip_task(find(n, "call bank"))
  local lines = read(f)
  H.eq(#lines, 1)
  H.ok(not lines[1]:find("old::", 1, true) and not lines[1]:find("skipped::", 1, true), lines[1])
  H.eq(require("timestamps.parser").parse_iso(lines[1]:match("due::(%S+)")), 1794297600 + 86400)
end)

---------------------------------------------------------------- :PKBComplete
t.test(":PKBComplete completes the task under the cursor", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "# t", "- [ ] a due::2026-11-10T08:00Z" })
  local n = notifier(root)
  n.notify()
  vim.cmd.source(H.root .. "/plugin/pkb.lua")
  vim.cmd.edit(f)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("PKBComplete")
  H.has(read(f)[2], "old::2026-11-10T08:00Z")
end)

t.test(":PKBComplete on a line without due:: only warns", function()
  local root = H.tmpdir()
  local f = H.write(root .. "/t.md", { "just text" })
  notifier(root)
  vim.cmd.source(H.root .. "/plugin/pkb.lua")
  vim.cmd.edit(f)
  vim.cmd("PKBComplete")
  H.eq(read(f), { "just text" })
  H.has(H.messages[#H.messages], "No due:: tag")
end)

---------------------------------------------------------------- invalid recur:: rule
for _, action in ipairs({ "complete_task", "skip_task" }) do
  t.test(action .. " leaves a task with an invalid recur:: unchanged and warns", function()
    local root = H.tmpdir()
    local f = H.write(root .. "/t.md", { "- [ ] report due::2026-11-10T08:00Z recur::3mnth" })
    local n = notifier(root)
    n.notify()
    n[action](find(n, "report"))
    H.eq(read(f), { "- [ ] report due::2026-11-10T08:00Z recur::3mnth" })
    H.has(H.messages[#H.messages], "3mnth")
  end)
end

return t
