-- pkb-specific test fixtures.
local H = require("tests.helpers")
local M = {}

--- Fresh pkb modules (state reset) with the notifier pointed at root. Its poll timer is stopped after the test.
function M.notifier(root, opts)
  H.unload("pkb")
  local n = require("pkb.notifier")
  H.defer(function()
    if n.timer then n.timer:stop(); n.timer:close(); n.timer = nil end
  end)
  n.setup(vim.tbl_extend("force", { pkb_root = root, device_is_phone = false, poll_interval = 1e9 }, opts or {}))
  return n
end

--- The notification whose line contains needle.
function M.find(n, needle)
  for _, e in pairs(n.notifications) do
    if e.line:find(needle, 1, true) then return e end
  end
  error("no notification containing " .. needle, 2)
end

return M
