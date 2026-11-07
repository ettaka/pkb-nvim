-- What calendar-nvim and the inbox show: agenda_provider, effort_calculation, render.render_inbox.
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
  return n
end

---------------------------------------------------------------- agenda
t.test("agenda: open tasks of the day, sorted by time, done tasks excluded", function()
  setup_pkb()
  local agenda = require("pkb.agenda_provider").get_pkb_day_agenda(2026, 11, 10)
  H.eq(#agenda, 3, vim.inspect(agenda))
  H.eq(vim.tbl_map(function(a) return a:sub(1, 5) end, agenda), { "08:00", "11:00", "13:00" })
end)

t.test("agenda: tags are stripped from the text", function()
  setup_pkb()
  for _, a in ipairs(require("pkb.agenda_provider").get_pkb_day_agenda(2026, 11, 10)) do
    for _, tag in ipairs({ "due::", "notify::", "recur::", "effort::", "task::" }) do
      H.ok(not a:find(tag, 1, true), ("%s left in %q"):format(tag, a))
    end
  end
end)

t.test("agenda: plain list item keeps its text", function()
  setup_pkb()
  H.eq(require("pkb.agenda_provider").get_pkb_day_agenda(2026, 11, 10)[2], "11:00 - Meeting")
end)

t.test("agenda: checkbox is stripped from the text", function()
  setup_pkb()
  H.eq(require("pkb.agenda_provider").get_pkb_day_agenda(2026, 11, 10)[1], "08:00 - Water plants")
end)

-- 2026-11-20, one task per hour from 08:00 Helsinki time (06:00Z)
local display = {
  { "- [ ] open checkbox",                  "open checkbox" },
  { "  - [ ] indented checkbox",            "indented checkbox" },
  { "- plain list item",                    "plain list item" },
  { "no list marker",                       "no list marker" },
  { "- [ ] keeps [ ] and [x] in the text",  "keeps [ ] and [x] in the text" },
  { "- [ ] [[wiki link]] first",            "[[wiki link]] first" },
  { "- [ ]   extra spaces",                 "extra spaces" },
}
t.test("agenda: display text for different line shapes", function()
  local lines = {}
  for i, c in ipairs(display) do
    table.insert(lines, ("%s due::2026-11-20T%02d:00Z effort::1h"):format(c[1], 5 + i))
  end
  setup_pkb(lines)
  local agenda = require("pkb.agenda_provider").get_pkb_day_agenda(2026, 11, 20)
  H.eq(#agenda, #display, vim.inspect(agenda))
  for i, c in ipairs(display) do
    H.eq(agenda[i], ("%02d:00 - %s"):format(7 + i, c[2]))
  end
end)

t.test("agenda: recurring task shows up on its later occurrences only", function()
  setup_pkb()
  local agenda = require("pkb.agenda_provider").get_pkb_day_agenda
  H.eq(#agenda(2026, 11, 11), 1, "11th: only 'Next day'")
  local on_12th = agenda(2026, 11, 12)
  H.eq(#on_12th, 1)
  H.has(on_12th[1], "Water plants")
end)

t.test("agenda: empty day", function()
  setup_pkb()
  H.eq(require("pkb.agenda_provider").get_pkb_day_agenda(2026, 11, 9), {})
end)

---------------------------------------------------------------- horizon (known issue 5)
-- A weekly task starting tomorrow 12:00; its instances fall on multiples of 7 days from then.
local function weekly_from_tomorrow(opts, extra_lines)
  local d = os.date("*t", os.time() + 86400)
  local start = os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
  local lines = { "- [ ] weekly review due::" .. H.iso_utc(start) .. " recur::weekly effort::2h" }
  vim.list_extend(lines, extra_lines or {})
  setup_pkb(lines, opts)
  return function(days)
    local t = os.date("*t", start + days * 86400)
    return t.year, t.month, t.day
  end
end
local agenda = function(...) return require("pkb.agenda_provider").get_pkb_day_agenda(...) end
local effort = function(...) return require("pkb.effort_calculation").get_tasks_duration(...) end

t.test("agenda respects setup{default_horizon} for recurring tasks", function()
  local day = weekly_from_tomorrow({ default_horizon = 200 })
  H.eq(#agenda(day(147)), 1, "147 days ahead, inside a 200-day horizon")
  H.eq(#agenda(day(196)), 1, "196 days ahead")
  H.eq(#agenda(day(210)), 0, "210 days ahead is past the horizon")
end)

t.test("a short default_horizon hides later recurring instances in agenda and effort", function()
  local day = weekly_from_tomorrow({ default_horizon = 30 })
  H.eq(#agenda(day(28)), 1)
  H.eq(effort(day(28)), 2)
  H.eq(#agenda(day(35)), 0)
  H.eq(effort(day(35)), 0)
end)

t.test("effort respects setup{default_horizon}", function()
  local day = weekly_from_tomorrow({ default_horizon = 200 })
  H.eq(effort(day(147)), 2)
end)

t.test("without default_horizon, agenda and effort look 90 days ahead", function()
  local day = weekly_from_tomorrow()
  H.eq(#agenda(day(84)), 1)
  H.eq(effort(day(84)), 2)
  H.eq(#agenda(day(98)), 0)
  H.eq(effort(day(98)), 0)
end)

t.test("one-off tasks beyond the horizon are still shown", function()
  local d = os.date("*t", os.time() + 60 * 86400)
  local due = os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
  setup_pkb({ "- [ ] far away due::" .. H.iso_utc(due) .. " effort::1h" }, { default_horizon = 30 })
  H.eq(#agenda(d.year, d.month, d.day), 1)
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
    local y, mo, d, hh, mm = 2026, 11, 10, hhmm:match("(%d%d):(%d%d)")
    hh, mm = tonumber(hh), tonumber(mm)
    return vim.tbl_extend("force", {
      id = id, file = "/pkb/t.md", line_num = 1,
      line = "- [ ] " .. id .. " " .. extra,
      due_ts = H.local_ts(y, mo, d, hh, mm), triggered = false, dismissed = false,
    }, fields or {})
  end
  return {
    a = e("a", "10:00", "effort::1h"),
    b = e("b", "10:30", "effort::30min", { triggered = true }),
    c = e("c", "15:00", ""),
    d = e("d", "17:00", "", { dismissed = true }),
  }
end

local function render(show_all)
  H.unload("pkb")
  local render_mod = require("pkb.render")
  local buf = vim.api.nvim_create_buf(false, true)
  render_mod.render_inbox(inbox_entries(), show_all, 86400, buf)
  return buf, vim.api.nvim_buf_get_lines(buf, 0, -1, false), render_mod
end

t.test("inbox: date heading with total effort", function()
  local _, lines = render(false)
  H.eq(lines[1], "## 2026-11-10 — total effort: 1h 30min")
end)

t.test("inbox: status markers, overlap conflicts, file and time", function()
  local _, lines = render(false)
  H.eq(#lines, 4, vim.inspect(lines))
  H.eq(lines[2], "[ ] - [ ] a effort::1h ⚠️ [CONFLICT] | /pkb/t.md | due 10:00")
  H.eq(lines[3], "[!] - [ ] b effort::30min ⚠️ [CONFLICT] | /pkb/t.md | due 10:30")
  H.eq(lines[4], "[ ] - [ ] c  | /pkb/t.md | due 15:00")
end)

t.test("inbox: dismissed tasks only shown in show-all view, marked [x]", function()
  local _, lines = render(true)
  H.eq(#lines, 5)
  H.has(lines[5], "[x] - [ ] d")
end)

t.test("inbox: cursor line maps back to its notification", function()
  local buf, _, render_mod = render(false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  H.eq(render_mod.get_notification_at_cursor(buf).id, "b")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  H.eq(render_mod.get_notification_at_cursor(buf), nil, "heading line")
end)

return t
