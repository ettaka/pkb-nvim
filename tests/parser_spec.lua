-- pkb.parser: notify offsets, recurrence rules, daily-note insertion point.
local H = require("tests.helpers")
local t = H.suite()
local P = require("pkb.parser")

---------------------------------------------------------------- parse_notify / parse_recurrence
t.test("parse_notify units", function()
  H.eq(P.parse_notify("15min"), 900)
  H.eq(P.parse_notify("2h"), 7200)
  H.eq(P.parse_notify("1day"), 86400)
  H.eq(P.parse_notify("3day"), 3 * 86400)
end)

t.test("parse_notify returns 0 for unknown input", function()
  H.eq(P.parse_notify("soon"), 0)
  H.eq(P.parse_notify("5x"), 0)
end)

t.test("parse_recurrence reads recur:: tag", function()
  H.eq(P.parse_recurrence("- [ ] x due::2026-01-01T10:00Z recur::1st_tue"), "1st_tue")
  H.eq(P.parse_recurrence("- [ ] x recur::daily effort::1h"), "daily")
  H.eq(P.parse_recurrence("- [ ] no recurrence"), nil)
  H.eq(P.parse_recurrence(nil), nil)
end)

---------------------------------------------------------------- calculate_next_due (plain units)
-- Saturday 2026-11-07 09:00 local
local base = H.local_ts(2026, 11, 7, 9, 0)
local plain = {
  { "daily",       "2026-11-08 09:00" },
  { "3d",          "2026-11-10 09:00" },
  { "weekly",      "2026-11-14 09:00" },
  { "1w",          "2026-11-14 09:00" },
  { "2w",          "2026-11-21 09:00" },
  { "biweekly",    "2026-11-21 09:00" },
  { "fortnightly", "2026-11-21 09:00" },
  { "monthly",     "2026-12-07 09:00" },
  { "2m",          "2027-01-07 09:00" },
  { "bimonthly",   "2027-01-07 09:00" },
  { "yearly",      "2027-11-07 09:00" },
  { "annually",    "2027-11-07 09:00" },
  -- unit names written out, singular or plural (recur::3month used to hang the editor)
  { "day",         "2026-11-08 09:00" },
  { "2days",       "2026-11-09 09:00" },
  { "week",        "2026-11-14 09:00" },
  { "2weeks",      "2026-11-21 09:00" },
  { "month",       "2026-12-07 09:00" },
  { "3month",      "2027-02-07 09:00" },
  { "3months",     "2027-02-07 09:00" },
  { "3monthly",    "2027-02-07 09:00" },
  { "3m",          "2027-02-07 09:00" },
  { "year",        "2027-11-07 09:00" },
  { "2years",      "2028-11-07 09:00" },
}
for _, c in ipairs(plain) do
  t.test("next due " .. c[1], function()
    H.eq(H.fmt(P.calculate_next_due(base, c[1])), c[2])
  end)
end

-- Finland changes clocks on 2026-03-29 and 2026-10-25: a recurring task keeps its wall-clock time (known issue 14).
local across_dst = {
  -- from (local)              rule        expected
  { { 2026, 10, 24, 9, 0 }, "daily",    "2026-10-25 09:00" },
  { { 2026, 3, 28, 9, 0 },  "daily",    "2026-03-29 09:00" },
  { { 2026, 10, 20, 9, 0 }, "weekly",   "2026-10-27 09:00" },
  { { 2026, 3, 25, 9, 0 },  "weekly",   "2026-04-01 09:00" },
  { { 2026, 10, 10, 9, 0 }, "monthly",  "2026-11-10 09:00" },
  { { 2026, 3, 10, 9, 0 },  "monthly",  "2026-04-10 09:00" },
  { { 2026, 7, 1, 9, 0 },   "yearly",   "2027-07-01 09:00" },
  { { 2026, 10, 6, 9, 0 },  "1st_tue",  "2026-11-03 09:00" },
  { { 2026, 3, 3, 9, 0 },   "1st_tue",  "2026-04-07 09:00" },
  { { 2026, 10, 1, 0, 30 }, "daily",    "2026-10-02 00:30" },
}
for _, c in ipairs(across_dst) do
  t.test(("next due %s keeps wall-clock time across DST (from %04d-%02d-%02d)"):format(c[2], c[1][1], c[1][2], c[1][3]), function()
    local from = H.local_ts(unpack(c[1]))
    H.eq(H.fmt(P.calculate_next_due_advanced(from, c[2])), c[3])
  end)
end

t.test("daily chain keeps 09:00 through both clock changes of a year", function()
  local ts = H.local_ts(2026, 3, 1, 9, 0)
  for _ = 1, 300 do
    ts = P.calculate_next_due(ts, "daily")
    H.eq(os.date("%H:%M", ts), "09:00", H.fmt(ts))
  end
end)

t.test("expanded recurring instances keep their time across DST", function()
  local due = H.local_ts(2026, 10, 23, 9, 0)
  local out = P.expand_recurring_tasks({ a = { id = "a", line = "- [ ] a recur::daily", due_ts = due } }, due + 4 * 86400)
  for _, e in ipairs(out) do H.eq(os.date("%H:%M", e.due_ts), "09:00", H.fmt(e.due_ts)) end
end)

-- Month/year steps clamp to the last day of the target month instead of overflowing (known issue 15).
local month_end = {
  -- from (local, 09:00)  rule        expected
  { { 2026, 1, 31 },  "monthly",  "2026-02-28 09:00", "Jan 31 -> end of Feb" },
  { { 2028, 1, 31 },  "monthly",  "2028-02-29 09:00", "Jan 31 -> Feb 29 in a leap year" },
  { { 2026, 1, 30 },  "monthly",  "2026-02-28 09:00", "Jan 30 -> end of Feb" },
  { { 2026, 3, 31 },  "monthly",  "2026-04-30 09:00", "Mar 31 -> Apr 30 (also crosses DST)" },
  { { 2026, 12, 31 }, "monthly",  "2027-01-31 09:00", "Dec 31 -> Jan 31 next year" },
  { { 2026, 12, 31 }, "2m",       "2027-02-28 09:00", "Dec 31 + 2 months" },
  { { 2026, 8, 31 },  "6m",       "2027-02-28 09:00", "Aug 31 + 6 months" },
  { { 2026, 10, 31 }, "bimonthly","2026-12-31 09:00", "31st that exists in the target month" },
  { { 2028, 2, 29 },  "yearly",   "2029-02-28 09:00", "Feb 29 -> Feb 28 in a common year" },
  { { 2028, 2, 29 },  "4y",       "2032-02-29 09:00", "Feb 29 -> Feb 29 four years later" },
  { { 2026, 1, 15 },  "monthly",  "2026-02-15 09:00", "mid-month days are unchanged" },
}
for _, c in ipairs(month_end) do
  t.test("next due " .. c[2] .. ": " .. c[4], function()
    H.eq(H.fmt(P.calculate_next_due(H.local_ts(c[1][1], c[1][2], c[1][3], 9, 0), c[2])), c[3])
  end)
end

-- Pinned limitation: the next instance is computed from the previous due date only, so after a
-- clamp the chain stays on the clamped day. Fixing it would need the original day stored in the note.
t.test("monthly chain from the 31st stays on the 28th after February (pinned limitation)", function()
  local ts = H.local_ts(2026, 1, 31, 9, 0)
  ts = P.calculate_next_due(ts, "monthly")
  H.eq(H.fmt(ts), "2026-02-28 09:00")
  H.eq(H.fmt(P.calculate_next_due(ts, "monthly")), "2026-03-28 09:00")
end)

---------------------------------------------------------------- calculate_next_due_advanced (nth weekday)
local nth = {
  -- from (local)                  rule              expected
  { { 2026, 11, 7, 9, 0 },  "1st_tue",      "2026-12-01 09:00", "1st Tuesday already passed this month" },
  { { 2026, 11, 2, 9, 0 },  "1st_tue",      "2026-11-03 09:00", "1st Tuesday still ahead this month" },
  { { 2026, 12, 1, 9, 0 },  "1st_tue",      "2027-01-05 09:00", "from the occurrence itself, into next year" },
  { { 2026, 11, 7, 9, 0 },  "2nd_wed",      "2026-11-11 09:00", "2nd Wednesday" },
  { { 2026, 11, 7, 9, 0 },  "3rd_mon",      "2026-11-16 09:00", "3rd Monday" },
  { { 2026, 11, 7, 9, 0 },  "4th_thu",      "2026-11-26 09:00", "4th Thursday" },
  { { 2026, 11, 7, 9, 0 },  "last_fri",     "2026-11-27 09:00", "last Friday" },
  { { 2026, 12, 26, 9, 0 }, "last_fri",     "2027-01-29 09:00", "last Friday across year end" },
  { { 2026, 11, 7, 9, 0 },  "1st_tuesday",  "2026-12-01 09:00", "full weekday name" },
  { { 2026, 11, 7, 9, 0 },  "1st_TUE",      "2026-12-01 09:00", "weekday is case-insensitive" },
}
for _, c in ipairs(nth) do
  t.test("next due " .. c[2] .. ": " .. c[4], function()
    H.eq(H.fmt(P.calculate_next_due_advanced(H.local_ts(unpack(c[1])), c[2])), c[3])
  end)
end

t.test("advanced rule falls back to plain units", function()
  H.eq(H.fmt(P.calculate_next_due_advanced(base, "daily")), "2026-11-08 09:00")
  H.eq(H.fmt(P.calculate_next_due_advanced(base, "2w")), "2026-11-21 09:00")
end)

-- An unknown rule has no next date (nil + reason). It used to return the same time, which hung the
-- recurring-task expansion, or to advance one day, which silently made the task daily.
local bad_rules = {
  { "xyz",     "unknown unit" },
  { "3mnth",   "unknown unit" },
  { "0d",      "must be at least 1" },
  { "1st_xyz", "weekday" },
  { "5th_mon", "ordinal" },
}
for _, c in ipairs(bad_rules) do
  t.test("invalid recurrence " .. c[1] .. " has no next date and says why", function()
    local next_ts, err = P.calculate_next_due_advanced(base, c[1])
    H.eq(next_ts, nil)
    H.has(err, c[1])
    H.has(err, c[2])
    H.eq(H.messages, {}, "the caller decides how to report it")
  end)
end

---------------------------------------------------------------- expand_recurring_tasks
t.test("expand_recurring_tasks adds virtual instances up to the horizon", function()
  local due = base
  local entries = {
    a = { id = "a", line = "- [ ] a recur::daily", due_ts = due },
    b = { id = "b", line = "- [ ] b", due_ts = due },
  }
  local out = P.expand_recurring_tasks(entries, due + 3.5 * 86400)
  local got = {}
  for _, e in ipairs(out) do table.insert(got, e.id .. (e.is_virtual and "*" or "") .. "@" .. H.fmt(e.due_ts)) end
  table.sort(got)
  H.eq(got, {
    "a@2026-11-07 09:00",
    "a_" .. (due + 86400) .. "*@2026-11-08 09:00",
    "a_" .. (due + 2 * 86400) .. "*@2026-11-09 09:00",
    "a_" .. (due + 3 * 86400) .. "*@2026-11-10 09:00",
    "b@2026-11-07 09:00",
  })
end)

t.test("expand_recurring_tasks: an invalid recur:: does not hang, warns once with the file, keeps the task", function()
  local entries = { a = { id = "t.md:1", file = "t.md", line_num = 1, line = "- [ ] a recur::3mnth", due_ts = base } }
  for _ = 1, 3 do
    local out = P.expand_recurring_tasks(entries, base + 365 * 86400)
    H.eq(#out, 1)
  end
  local warned = vim.tbl_filter(function(m) return m:find("3mnth", 1, true) end, H.messages)
  H.eq(#warned, 1, vim.inspect(H.messages))
  H.has(warned[1], "t.md:1")
end)

---------------------------------------------------------------- find_log_insertion_index
local note = { "# 2026-11-10", "", "# morning", "- a", "", "# afternoon", "" }

t.test("log insertion goes before the next heading, above blank lines", function()
  H.eq({ P.find_log_insertion_index(note, "morning") }, { 3, 5 })
end)

t.test("log insertion in the last section goes above trailing blanks", function()
  H.eq({ P.find_log_insertion_index(note, "afternoon") }, { 6, 7 })
end)

t.test("log insertion returns nil when the section is missing", function()
  H.eq({ P.find_log_insertion_index(note, "evening") }, {})
end)

return t
