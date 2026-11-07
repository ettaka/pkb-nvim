-- pkb-nvim must not create global variables (known issue 11).
local H = require("tests.helpers")
local t = H.suite()
local notifier = require("tests.pkb").notifier

local function global_names()
  local names = {}
  for k in pairs(_G) do names[k] = true end
  return names
end

t.test("loading and using pkb-nvim creates no globals", function()
  local before = global_names()

  local root = H.tmpdir()
  -- one task already due (fires on the first timer tick), one recurring, one to skip
  local f = H.write(root .. "/t.md", {
    "- [ ] overdue due::" .. H.iso_utc(os.time() - 3600),
    "- [ ] stretch due::2026-11-10T08:00Z recur::daily effort::30min",
    "- [ ] call bank due::2026-11-10T09:00Z",
  })
  local n = notifier(root, { poll_interval = 1e9 })
  vim.cmd.source(H.root .. "/plugin/pkb.lua")
  vim.cmd("PKBNotify")
  -- let the poll timer's first tick run check_notifications (-> phone digest + popup)
  local fired = vim.wait(1000, function() return require("tests.pkb").find(n, "overdue").triggered end)
  H.ok(fired, "timer tick did not trigger the overdue task")
  n.open_day(2026, 11, 10)
  require("pkb.effort_calculation").get_tasks_duration(2026, 11, 10)
  n.complete_task(require("tests.pkb").find(n, "stretch"))
  n.skip_task(require("tests.pkb").find(n, "call bank"))
  vim.cmd("PKBInbox")
  require("pkb").setup({ pkb_root = root, device_is_phone = false })

  local leaked = {}
  for k in pairs(global_names()) do
    if not before[k] then table.insert(leaked, k) end
  end
  table.sort(leaked)
  H.eq(leaked, {})
  H.ok(vim.fn.filereadable(f) == 1)
end)

return t
