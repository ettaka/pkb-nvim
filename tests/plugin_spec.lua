-- plugin/pkb.lua is the one place that defines the PKB commands (known issue 10).
local H = require("tests.helpers")
local t = H.suite()
local notifier = require("tests.pkb").notifier

local COMMANDS = { "PKBComplete", "PKBInbox", "PKBNotify" }

local function pkb_commands()
  local names = vim.tbl_filter(function(name) return name:match("^PKB") end, vim.tbl_keys(vim.api.nvim_get_commands({})))
  table.sort(names)
  return names
end

local function delete_pkb_commands()
  for _, name in ipairs(pkb_commands()) do vim.api.nvim_del_user_command(name) end
end

t.test("loading the Lua modules defines no commands", function()
  delete_pkb_commands()
  H.unload("pkb")
  for _, m in ipairs({ "pkb", "pkb.notifier", "pkb.parser", "pkb.ui", "pkb.render", "pkb.effort_calculation" }) do
    require(m)
  end
  H.eq(pkb_commands(), {})
end)

t.test("plugin/pkb.lua defines the PKB commands", function()
  delete_pkb_commands()
  vim.cmd.source(H.root .. "/plugin/pkb.lua")
  H.eq(pkb_commands(), COMMANDS)
end)

t.test(":runtime plugin/pkb.lua finds pkb-nvim's file even with timestamps-nvim earlier on the runtimepath", function()
  delete_pkb_commands()
  vim.cmd.runtime("plugin/pkb.lua") -- sources only the first match
  H.eq(pkb_commands(), COMMANDS)
end)

t.test(":PKBNotify rescans the PKB", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z" })
  local n = notifier(root)
  vim.cmd.source(H.root .. "/plugin/pkb.lua")
  vim.cmd("PKBNotify")
  H.eq(vim.tbl_count(n.notifications), 1)
end)

t.test(":PKBInbox opens the inbox", function()
  local root = H.tmpdir()
  H.write(root .. "/t.md", { "- [ ] a due::2026-11-10T08:00Z" })
  notifier(root)
  vim.cmd.source(H.root .. "/plugin/pkb.lua")
  vim.cmd("PKBInbox")
  H.has(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"), "[ ] 10:00        a  · t.md")
end)

return t
