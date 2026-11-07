-- pkb.task_id: the one definition of the task id format (known issue 12).
-- An id looks like t-2026-11-07T09:15; in a task it is written as task::t-2026-11-07T09:15.
local H = require("tests.helpers")
local t = H.suite()
local T = require("pkb.task_id")

t.test("new() is t- plus the local time to the minute", function()
  H.eq(T.new(H.local_ts(2026, 11, 7, 9, 15)), "t-2026-11-07T09:15")
  local now = T.new()
  H.ok(now:match("^" .. T.PATTERN .. "$"), now)
  H.eq(now, "t-" .. os.date("%Y-%m-%dT%H:%M"))
end)

t.test("tag() writes the task:: form", function()
  H.eq(T.tag("t-2026-11-07T09:15"), "task::t-2026-11-07T09:15")
end)

t.test("from_line() reads the id of a task:: tag", function()
  H.eq(T.from_line("- [ ] x due::2026-11-10T08:00Z task::t-2026-01-01T10:00 effort::1h"), "t-2026-01-01T10:00")
  H.eq(T.from_line("- [ ] no id"), nil)
  H.eq(T.from_line("see t-2026-01-01T10:00"), nil, "a bare reference is not a task:: tag")
  H.eq(T.from_line("task::t-2026-1-01T10:00"), nil, "malformed")
end)

t.test("untag() turns task::<id> into a bare reference", function()
  H.eq(T.untag("- [ ] x old::2026 task::t-2026-01-01T10:00 done::2026"), "- [ ] x old::2026 t-2026-01-01T10:00 done::2026")
  H.eq(T.untag("no tag"), "no tag")
end)

local line = "see t-2026-01-01T10:00 and task::t-2026-02-02T11:30 here"
--            0         1         2         3         4         5
--            0123456789012345678901234567890123456789012345678901234
t.test("at() returns the id under a 0-based column", function()
  H.eq(T.at(line, 4), "t-2026-01-01T10:00", "first char of first id")
  H.eq(T.at(line, 21), "t-2026-01-01T10:00", "last char of first id")
  H.eq(T.at(line, 40), "t-2026-02-02T11:30", "inside second id")
end)

t.test("at() falls back to the first id on the line, nil when there is none", function()
  H.eq(T.at(line, 0), "t-2026-01-01T10:00")
  H.eq(T.at(line, 54), "t-2026-01-01T10:00")
  H.eq(T.at(line, 50), "t-2026-02-02T11:30", "last char of second id")
  H.eq(T.at("nothing here", 3), nil)
end)

t.test("under_cursor() uses the current line and cursor", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x", line })
  vim.api.nvim_win_set_cursor(0, { 2, 40 })
  H.eq(T.under_cursor(), "t-2026-02-02T11:30")
end)

---------------------------------------------------------------- unique ids
t.test("collect() finds tagged ids and bare references", function()
  local ids = T.collect({ "- [ ] a task::t-2026-01-01T10:00", "log t-2026-02-02T11:30 and t-2026-03-03T12:45", "none" })
  H.eq(ids, { ["t-2026-01-01T10:00"] = true, ["t-2026-02-02T11:30"] = true, ["t-2026-03-03T12:45"] = true })
end)

t.test("new_unique() skips taken ids by moving to the next free minute", function()
  H.unload("pkb.task_id")
  local U = require("pkb.task_id")
  local ts = H.local_ts(2026, 11, 7, 9, 15)
  local taken = { ["t-2026-11-07T09:15"] = true, ["t-2026-11-07T09:16"] = true }
  H.eq(U.new_unique(taken, ts), "t-2026-11-07T09:17")
end)

t.test("new_unique() never repeats an id within a session", function()
  H.unload("pkb.task_id")
  local U = require("pkb.task_id")
  local ts = H.local_ts(2026, 11, 7, 9, 15)
  H.eq({ U.new_unique({}, ts), U.new_unique({}, ts), U.new_unique(nil, ts) },
    { "t-2026-11-07T09:15", "t-2026-11-07T09:16", "t-2026-11-07T09:17" })
end)

return t
