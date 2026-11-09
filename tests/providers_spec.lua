-- What calendar-nvim and the inbox show: the inbox (with time slots and a day view), effort_calculation.
local H = require("tests.helpers")
local t = H.suite()
local notifier = require("tests.pkb").notifier

-- 2026-11-10 in Helsinki (UTC+2): 06:00Z = 08:00, 09:00Z = 11:00, 11:00Z = 13:00
local TASKS = {
  "# tasks",
  "- [ ] Water plants due::2026-11-10T06:00Z recur::2d effort::30min notify::1h task::t-2026-01-01T10:00",
  "- [ ] Write report due::2026-11-10T11:00Z effort::3h",
  "- [x] Done thing due::2026-11-10T07:00Z effort::5h",
  "- Meeting due::2026-11-10T09:00Z effort::1.5h",
  "- [ ] Next day due::2026-11-11T09:00Z effort::1day",
}

local function setup_pkb(lines, opts)
  local root = H.tmpdir()
  H.write(root .. "/tasks.md", lines or TASKS)
  local n = notifier(root, opts)
  n.notify()
  return n, root
end

--- Open the inbox on a day; return the lines of that day's section (heading first) and the cursor row.
local function day_view(n, y, m, d)
  n.open_day(y, m, d)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local section = {}
  for i = row, #lines do
    if i > row and (lines[i] == "" or lines[i]:match("^## ")) then break end
    table.insert(section, lines[i])
  end
  return section, row, lines
end

--- Item lines of a day section, without the status marker and the "· file" suffix.
local function items(section)
  local out = {}
  for i = 2, #section do
    table.insert(out, (section[i]:gsub("^%[.%] ", ""):gsub("%s+· %S+$", "")))
  end
  return out
end

---------------------------------------------------------------- day view (replaces the calendar agenda)
t.test("day view: cursor on the day's heading, open tasks sorted by time with time slots", function()
  local n = setup_pkb()
  local section, row, lines = day_view(n, 2026, 11, 10)
  H.eq(lines[row], section[1])
  H.ok(section[1]:match("^## 2026%-11%-10"), section[1])
  H.eq(items(section), {
    "08:00–08:30  Water plants ↻",
    "11:00–12:30  Meeting",
    "13:00–16:00  Write report",
  })
end)

t.test("day view: tags are hidden, recurring tasks marked ↻, file shown relative to the PKB", function()
  local n = setup_pkb()
  local section = day_view(n, 2026, 11, 10)
  for i = 2, #section do
    for _, tag in ipairs({ "due::", "notify::", "recur::", "effort::", "task::", "- [ ]" }) do
      H.ok(not section[i]:find(tag, 1, true), ("%s left in %q"):format(tag, section[i]))
    end
    H.ok(section[i]:match("· tasks%.md$"), section[i])
  end
end)

-- 2026-11-20, one task per hour from 08:00 Helsinki time (06:00Z), 1h each
local display = {
  { "- [ ] open checkbox",                  "open checkbox" },
  { "  - [ ] indented checkbox",            "indented checkbox" },
  { "- plain list item",                    "plain list item" },
  { "no list marker",                       "no list marker" },
  { "- [ ] keeps [ ] and [x] in the text",  "keeps [ ] and [x] in the text" },
  { "- [ ] [[wiki link]] first",            "[[wiki link]] first" },
  { "- [ ]   extra spaces",                 "extra spaces" },
}
t.test("day view: display text for different line shapes", function()
  local lines = {}
  for i, c in ipairs(display) do
    table.insert(lines, ("%s due::2026-11-20T%02d:00Z effort::1h"):format(c[1], 5 + i))
  end
  local section = day_view(setup_pkb(lines), 2026, 11, 20)
  local want = {}
  for i, c in ipairs(display) do
    table.insert(want, ("%02d:00–%02d:00  %s"):format(7 + i, 8 + i, c[2]))
  end
  H.eq(items(section), want)
end)

t.test("day view: a task without effort shows only its start time", function()
  local section = day_view(setup_pkb({ "- [ ] call bank due::2026-11-10T08:00Z" }), 2026, 11, 10)
  H.eq(items(section), { "10:00        call bank" })
end)

t.test("day view: a slot running past midnight shows the day offset", function()
  local section = day_view(setup_pkb({ "- [ ] night shift due::2026-11-10T20:00Z effort::5h" }), 2026, 11, 10)
  H.eq(items(section), { "22:00–03:00+1d  night shift" })
end)

t.test("day view: recurring task shows up on its later occurrences", function()
  local n = setup_pkb()
  H.eq(items(day_view(n, 2026, 11, 11)), { "11:00–11:00+1d  Next day" })
  H.eq(items(day_view(n, 2026, 11, 12)), { "08:00–08:30  Water plants ↻" })
end)

t.test("day view: a day without tasks gets an empty section in date order", function()
  local n = setup_pkb()
  local section, row, lines = day_view(n, 2026, 11, 9)
  H.eq(section, { "## 2026-11-09", "  (no tasks)" })
  H.ok(lines[row + 3] and lines[row + 3]:match("^## 2026%-11%-10"), "the 10th should follow: " .. vim.inspect(lines))
end)

t.test("day view works when the PKB has no tasks at all", function()
  local section = day_view(setup_pkb({ "nothing here" }), 2026, 11, 9)
  H.eq(section, { "## 2026-11-09", "  (no tasks)" })
end)

t.test("day view keeps its focus after completing a task with c", function()
  local n = setup_pkb()
  local _, row = day_view(n, 2026, 11, 10)
  vim.api.nvim_win_set_cursor(0, { row + 3, 0 }) -- Write report
  vim.fn.maparg("c", "n", false, true).callback()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  H.ok(lines[vim.api.nvim_win_get_cursor(0)[1]], "cursor out of range")
  local text = table.concat(lines, "\n")
  H.ok(not text:find("Write report", 1, true), "completed task still listed")
  H.ok(text:find("## 2026-11-10", 1, true), "the focus day is gone")
end)

t.test(":PKBInbox YYYY-MM-DD opens the day view", function()
  setup_pkb()
  vim.cmd.source(H.root .. "/plugin/pkb.lua")
  vim.cmd("PKBInbox 2026-11-12")
  H.ok(vim.api.nvim_get_current_line():match("^## 2026%-11%-12"), vim.api.nvim_get_current_line())
end)

---------------------------------------------------------------- horizon (known issue 5)
-- A weekly task starting tomorrow 12:00; its instances fall on multiples of 7 days from then.
local function weekly_from_tomorrow(opts)
  local d = os.date("*t", os.time() + 86400)
  local start = os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
  local n = setup_pkb({ "- [ ] weekly review due::" .. H.iso_utc(start) .. " recur::weekly effort::2h" }, opts)
  return n, function(days)
    local t2 = os.date("*t", start + days * 86400)
    return t2.year, t2.month, t2.day
  end
end
local effort = function(...) return require("pkb.effort_calculation").get_tasks_duration(...) end
local function inbox_text(n)
  n.inbox()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

t.test("inbox and effort respect setup{default_horizon} for recurring tasks", function()
  local n, day = weekly_from_tomorrow({ default_horizon = 200 })
  local text = inbox_text(n)
  H.ok(text:find(("## %04d-%02d-%02d"):format(day(196)), 1, true), "196 days ahead missing")
  H.ok(not text:find(("## %04d-%02d-%02d"):format(day(210)), 1, true), "210 days ahead listed")
  H.eq(effort(day(147)), 2)
  H.eq(effort(day(210)), 0)
end)

t.test("a short default_horizon hides later recurring instances in inbox and effort", function()
  local n, day = weekly_from_tomorrow({ default_horizon = 30 })
  local text = inbox_text(n)
  H.ok(text:find(("## %04d-%02d-%02d"):format(day(28)), 1, true))
  H.ok(not text:find(("## %04d-%02d-%02d"):format(day(35)), 1, true))
  H.eq({ effort(day(28)), effort(day(35)) }, { 2, 0 })
end)

t.test("without default_horizon, effort looks 90 days ahead", function()
  local _, day = weekly_from_tomorrow()
  H.eq({ effort(day(84)), effort(day(98)) }, { 2, 0 })
end)

t.test("the day view shows a recurring instance even beyond the horizon", function()
  local n, day = weekly_from_tomorrow({ default_horizon = 30 })
  H.eq(items(day_view(n, day(70))), { "12:00–14:00  weekly review ↻" })
end)

t.test("one-off tasks beyond the horizon are still shown", function()
  local d = os.date("*t", os.time() + 60 * 86400)
  local due = os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
  local n = setup_pkb({ "- [ ] far away due::" .. H.iso_utc(due) .. " effort::1h" }, { default_horizon = 30 })
  H.ok(inbox_text(n):find("far away", 1, true))
  H.eq(effort(d.year, d.month, d.day), 1)
end)

---------------------------------------------------------------- effort
t.test("effort: sums open tasks of the day in hours (min, h, decimal h)", function()
  setup_pkb()
  H.eq(require("pkb.effort_calculation").get_tasks_duration(2026, 11, 10), 0.5 + 3 + 1.5)
end)

t.test("effort: day unit is 24 hours", function()
  setup_pkb()
  H.eq(require("pkb.effort_calculation").get_tasks_duration(2026, 11, 11), 24)
end)

t.test("effort: recurring instances count on their own day", function()
  setup_pkb()
  H.eq(require("pkb.effort_calculation").get_tasks_duration(2026, 11, 12), 0.5)
end)

t.test("effort: tasks without effort:: or with unknown units count as 0", function()
  setup_pkb({ "- [ ] a due::2026-11-10T09:00Z", "- [ ] b due::2026-11-10T10:00Z effort::3weeks" })
  H.eq(require("pkb.effort_calculation").get_tasks_duration(2026, 11, 10), 0)
end)

---------------------------------------------------------------- inbox rendering
local function inbox_entries()
  local function e(id, hhmm, extra, fields)
    local hh, mm = hhmm:match("(%d%d):(%d%d)")
    return vim.tbl_extend("force", {
      id = id, file = "/pkb/notes/t.md", line_num = 1,
      line = "- [ ] " .. id .. " " .. extra,
      due_ts = H.local_ts(2026, 11, 10, tonumber(hh), tonumber(mm)), triggered = false, dismissed = false,
    }, fields or {})
  end
  return {
    a = e("a", "10:00", "effort::1h"),
    b = e("b", "10:30", "effort::30min", { triggered = true }),
    c = e("c", "15:00", ""),
    d = e("d", "17:00", "", { dismissed = true }),
  }
end

local function render(show_all, opts)
  H.unload("pkb")
  local render_mod = require("pkb.render")
  local buf = vim.api.nvim_create_buf(false, true)
  local focus = render_mod.render_inbox(inbox_entries(), show_all, 86400, buf, opts or { root = "/pkb" })
  return buf, vim.api.nvim_buf_get_lines(buf, 0, -1, false), render_mod, focus
end

t.test("inbox: date heading with total effort", function()
  local _, lines = render(false)
  H.eq(lines[1], "## 2026-11-10 — total effort: 1h 30min")
end)

t.test("inbox: status markers, time slots, overlap conflicts, file", function()
  local _, lines = render(false)
  H.eq(#lines, 4, vim.inspect(lines))
  H.eq(lines[2], "[ ] 10:00–11:00  a  ⚠️ CONFLICT  · notes/t.md")
  H.eq(lines[3], "[!] 10:30–11:00  b  ⚠️ CONFLICT  · notes/t.md")
  H.eq(lines[4], "[ ] 15:00        c  · notes/t.md")
end)

t.test("inbox: without a root the file is shown by name", function()
  local _, lines = render(false, {})
  H.eq(lines[4], "[ ] 15:00        c  · t.md")
end)

t.test("inbox: dismissed tasks only shown in show-all view, marked [x]", function()
  local _, lines = render(true)
  H.eq(#lines, 5)
  H.ok(lines[5]:match("^%[x%] 17:00        d"), lines[5])
end)

t.test("inbox: cursor line maps back to its notification", function()
  local buf, _, render_mod = render(false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  H.eq(render_mod.get_notification_at_cursor(buf).id, "b")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  H.eq(render_mod.get_notification_at_cursor(buf), nil, "heading line")
end)

t.test("inbox: render_inbox returns the focus day's heading row", function()
  local _, lines, _, focus = render(false, { root = "/pkb", focus_date = "2026-11-11" })
  H.eq(focus, 6)
  H.eq({ lines[6], lines[7] }, { "## 2026-11-11", "  (no tasks)" })
end)

t.test("inbox: a wrapped line continues under the task text, after the time slot", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", { "- [ ] Call the bank about the mortgage renewal papers today due::2026-11-10T08:00Z effort::30min" })
  local n = notifier(root)
  n.notify()
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  H.defer(function() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end end)
  vim.api.nvim_win_set_width(win, 40)
  n.open_day(2026, 11, 10)
  local row = vim.fn.search("Call the bank", "n")
  vim.cmd("redraw")
  local first = vim.fn.screenpos(win, row, 1)
  local function screen_line(r)
    local s = ""
    for c = first.col, first.col + 39 do s = s .. vim.fn.screenstring(r, c) end
    return (s:gsub("%s+$", ""))
  end
  H.eq(screen_line(first.row), "[ ] 10:00–10:30  Call the bank about")
  H.eq(screen_line(first.row + 1), "                 the mortgage renewal")
  H.eq(screen_line(first.row + 2), "                 papers today  · t.md")
  -- the options are local to the inbox: another buffer in the same window does not get them
  vim.cmd("enew")
  H.eq({ vim.wo[win].breakindent, vim.wo[win].linebreak }, { false, false })
end)

---------------------------------------------------------------- inbox in another offset (:PKBInbox tz=-06:00)
-- In Helsinki (+02:00): early 05:00, late 22:00, both on 2026-11-10. In -06:00, early is 21:00 the day before.
local TZ_NOTE = { "- [ ] early due::2026-11-10T03:00Z effort::1h", "- [ ] late due::2026-11-10T20:00Z effort::30min" }

local function tz_inbox(opts)
  local root = H.tmpdir()
  H.write(root .. "/t.md", TZ_NOTE)
  local n = notifier(root)
  n.inbox(opts)
  return vim.api.nvim_buf_get_lines(0, 0, -1, false), n
end

t.test("inbox tz=-06:00: times and days in that offset, with a header saying so", function()
  H.eq(tz_inbox({ tz = "-06:00" }), {
    "Times in UTC-06:00",
    "",
    "## 2026-11-09 — total effort: 1h",
    "[ ] 21:00–22:00  early  · t.md",
    "",
    "## 2026-11-10 — total effort: 30min",
    "[ ] 14:00–14:30  late  · t.md",
  })
end)

t.test("inbox without tz: local time and no header", function()
  H.eq(tz_inbox({}), {
    "## 2026-11-10 — total effort: 1h 30min",
    "[ ] 05:00–06:00  early  · t.md",
    "[ ] 22:00–22:30  late  · t.md",
  })
end)

local tz_forms = {
  { "Z",      "Times in UTC",        "[ ] 03:00–04:00  early  · t.md" },
  { "+05:30", "Times in UTC+05:30",  "[ ] 08:30–09:30  early  · t.md" },
  { "-6",     "Times in UTC-06:00",  "[ ] 21:00–22:00  early  · t.md" },
  { "+3",     "Times in UTC+03:00",  "[ ] 06:00–07:00  early  · t.md" },
  { "-06",    "Times in UTC-06:00",  "[ ] 21:00–22:00  early  · t.md" },
  { "H",      "Times in UTC+02:00",  "[ ] 05:00–06:00  early  · t.md" },
  { "S",      "Times in UTC+03:00",  "[ ] 06:00–07:00  early  · t.md" },
}
for _, c in ipairs(tz_forms) do
  t.test("inbox tz=" .. c[1], function()
    local lines = tz_inbox({ tz = c[1] })
    H.eq(lines[1], c[2])
    H.has(table.concat(lines, "\n"), c[3])
  end)
end

for _, bad in ipairs({ "6", "+25:00", "+05:61", "EST", "America/Chicago" }) do
  t.test("inbox rejects tz=" .. bad .. " with a warning", function()
    local before = vim.api.nvim_get_current_buf()
    tz_inbox({ tz = bad })
    H.eq(vim.api.nvim_get_current_buf(), before, "no inbox opened")
    H.has(H.messages[#H.messages], "tz")
  end)
end

t.test("inbox tz with a date: the day is that offset's day, cursor on it", function()
  local lines = tz_inbox({ tz = "-06:00", date = "2026-11-09" })
  H.eq(lines[vim.api.nvim_win_get_cursor(0)[1]], "## 2026-11-09 — total effort: 1h")
end)

t.test("inbox tz: an empty focus day in that offset gets its own section", function()
  local lines = tz_inbox({ tz = "-06:00", date = "2026-11-08" })
  H.eq(vim.list_slice(lines, 1, 5), { "Times in UTC-06:00", "", "## 2026-11-08", "  (no tasks)", "" })
end)

t.test("inbox tz: the offset stays when the inbox re-renders (t)", function()
  tz_inbox({ tz = "-06:00" })
  vim.fn.maparg("t", "n", false, true).callback()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  H.eq(lines[1], "Times in UTC-06:00")
  H.has(table.concat(lines, "\n"), "[ ] 21:00–22:00  early")
end)

t.test(":PKBInbox takes tz= and a date in any order", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", TZ_NOTE)
  notifier(root)
  vim.cmd.source(H.root .. "/plugin/pkb.lua")
  vim.cmd("PKBInbox tz=-06:00")
  H.eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "Times in UTC-06:00")
  vim.cmd("PKBInbox tz=-06:00 2026-11-09")
  H.eq(vim.api.nvim_get_current_line(), "## 2026-11-09 — total effort: 1h")
  vim.cmd("PKBInbox 2026-11-10")
  H.eq(vim.api.nvim_get_current_line(), "## 2026-11-10 — total effort: 1h 30min")
end)

return t
