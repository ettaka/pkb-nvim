-- Minimal, dependency-free test runner.
--
--   nvim --clean -l tests/run.lua [filter]      (or: make test [FILTER=...])
--
-- Runs every tests/*_spec.lua. A spec returns a suite built with helpers.suite():
--   t.test(name, fn)            normal test
--   t.xfail(name, reason, fn)   known bug: must FAIL; reported as XPASS (and fails the run) once it is fixed,
--                               so the marker gets removed together with the fix
-- PKB_TEST_VERBOSE=1 also prints why each xfail failed.
-- Tests run with TZ=Europe/Helsinki (override with PKB_TEST_TZ). TZ cannot be changed inside a running nvim,
-- so the runner re-executes itself with the right environment.
local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":p:h:h")
local TZ = vim.env.PKB_TEST_TZ or "Europe/Helsinki"

if vim.env.TZ ~= TZ or vim.env.PKB_TEST_CHILD ~= "1" then
  local cmd = { vim.v.progpath, "--clean", "-l", script }
  vim.list_extend(cmd, _G.arg)
  local res = vim.system(cmd, { env = { TZ = TZ, PKB_TEST_CHILD = "1" }, text = true }):wait()
  io.stdout:write(res.stdout or "")
  io.stderr:write(res.stderr or "")
  os.exit(res.code)
end

-- Plugin under test + dependencies listed in tests/deps.lua (resolved by helpers.find_dep).
package.path = root .. "/?.lua;" .. package.path
vim.opt.runtimepath:prepend(root)
local H = require("tests.helpers")
H.root = root
local ok_deps, deps = pcall(dofile, root .. "/tests/deps.lua")
for _, name in ipairs(ok_deps and deps or {}) do
  vim.opt.runtimepath:prepend(H.find_dep(name))
end

local filter = _G.arg[1]
local files = vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
table.sort(files)

local counts = { pass = 0, fail = 0, xfail = 0, xpass = 0 }
local failures = {}

for _, file in ipairs(files) do
  local fname = vim.fn.fnamemodify(file, ":t:r")
  local loaded, suite = xpcall(dofile, debug.traceback, file)
  if not loaded then
    counts.fail = counts.fail + 1
    table.insert(failures, ("FAIL  %s: could not load spec\n  %s"):format(fname, tostring(suite):gsub("\n", "\n  ")))
    suite = { cases = {} }
  end
  for _, case in ipairs(suite.cases) do
    local full = fname .. ": " .. case.name
    if not filter or full:find(filter, 1, true) then
      H.before_each()
      local ok, err = xpcall(case.fn, debug.traceback)
      H.after_each()
      if case.xfail then
        if ok then
          counts.xpass = counts.xpass + 1
          table.insert(failures, ("XPASS %s\n  marked as known bug (%s) but passed: remove the xfail marker"):format(full, case.xfail))
        else
          counts.xfail = counts.xfail + 1
          io.stdout:write(("xfail %s  (%s)\n"):format(full, case.xfail))
          if vim.env.PKB_TEST_VERBOSE == "1" then
            io.stdout:write("      " .. tostring(err):gsub("\nstack traceback:.*", ""):gsub("\n", "\n      ") .. "\n")
          end
        end
      elseif ok then
        counts.pass = counts.pass + 1
      else
        counts.fail = counts.fail + 1
        table.insert(failures, ("FAIL  %s\n  %s"):format(full, tostring(err):gsub("\n", "\n  ")))
      end
    end
  end
end

for _, f in ipairs(failures) do io.stdout:write(f .. "\n") end
io.stdout:write(("\n%d passed, %d failed, %d known bugs (xfail), %d xpass   [TZ=%s]\n")
  :format(counts.pass, counts.fail, counts.xfail, counts.xpass, TZ))
os.exit((counts.fail + counts.xpass == 0 and counts.pass + counts.xfail > 0) and 0 or 1)
