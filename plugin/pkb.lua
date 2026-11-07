vim.api.nvim_create_user_command("PKBNotify", function()
  require("pkb.notifier").notify()
end, {})

vim.api.nvim_create_user_command("PKBInbox", function(args)
  require("pkb.notifier").inbox({ date = args.args ~= "" and args.args or nil })
end, { nargs = "?", desc = "PKB inbox; optional YYYY-MM-DD opens it on that day" })

vim.api.nvim_create_user_command("PKBComplete", function()
  local file = vim.api.nvim_buf_get_name(0)
  local line_num = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()

  local parser = require("pkb.parser")
  local due_str = line:match("due::([^%s]+)")
  if not due_str then
    vim.notify("No due:: tag found on current line", vim.log.levels.WARN)
    return
  end

  local due_ts = require('timestamps.parser').parse_iso(due_str)
  local entry = {
    file = file,
    line_num = line_num,
    line = line,
    due_ts = due_ts,
  }

  require("pkb.notifier").complete_task(entry)
end, {})
