---------------------------------------------------------------
-- LINKS
-- Follows the link under the cursor in the cases Telekasten's follow_link does not handle: a markdown link
-- [text](path) to a file (Telekasten hands the path to xdg-open, which reads it from Neovim's working
-- directory), and [[./path]] / [[../path]] wiki links. Paths are read relative to the note, from the PKB root
-- when they start with "/" and no such absolute file exists, or as absolute (~ works). Markdown files open in
-- Neovim, other files (PDFs, images) with the system opener (vim.ui.open).
-- follow() returns false when there is nothing for it to do (no link, a URL, a plain [[page]] link), so a
-- mapping can fall back to Telekasten.
---------------------------------------------------------------
local M = {}

local function url_decode(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

--- The path of the link at 1-based byte column `col` of `line`, or nil. Only file links this module handles.
function M.path_at(line, col)
  for s, inside, e in line:gmatch("()%[[^%]]*%]%(([^%)]+)%)()") do
    if col >= s and col < e then
      local path = inside:match("^<([^>]*)>") or inside:match("^(%S+)")
      if path and not path:match("^%a[%w+.-]*:") then -- not a URL
        return (url_decode(path):gsub("#.*$", ""))
      end
      return nil
    end
  end
  for s, inner, e in line:gmatch("()%[%[([^%]]+)%]%]()") do
    if col >= s and col < e then
      local path = inner:match("^([^|#]*)")
      if path:match("^%.%.?/") then return path end
      return nil
    end
  end
end

--- Absolute path for `path` written in the note `note` (absolute path of the note).
function M.resolve(path, note)
  if path:match("^~") then return vim.fs.normalize(vim.fn.expand(path)) end
  if path:match("^/") then
    if vim.uv.fs_stat(path) then return vim.fs.normalize(path) end
    local root = require("pkb.notifier").PKB_ROOT or vim.env.PKB_ROOT
    if root then return vim.fs.normalize(vim.fn.expand(root) .. path) end
    return path
  end
  return vim.fs.normalize(vim.fs.dirname(note) .. "/" .. path)
end

--- Follow the link under the cursor. true if it was a link this module handles (opened, or a warning).
function M.follow()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local path = M.path_at(vim.api.nvim_get_current_line(), col)
  if not path then return false end
  local file = M.resolve(path, vim.api.nvim_buf_get_name(0))
  if not vim.uv.fs_stat(file) then
    vim.notify("[PKB] No such file: " .. file, vim.log.levels.WARN)
    return true
  end
  if file:match("%.md$") or vim.fn.isdirectory(file) == 1 then
    vim.cmd.edit(vim.fn.fnameescape(file))
  else
    vim.ui.open(file)
  end
  return true
end

return M
