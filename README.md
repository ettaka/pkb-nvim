# pkb.nvim

A simple Neovim plugin template for PKB.

## Inbox

`:PKBInbox` lists open tasks by day, each with its time slot (`due` to `due` + `effort`):

```
## 2026-11-10 — total effort: 5h
[ ] 08:00–08:30  Water plants ↻  · tasks.md
[!] 11:00–12:30  Meeting  ⚠️ CONFLICT  · work/meetings.md
[ ] 13:00        Call the bank  · tasks.md
```

`[!]` notified, `[x]` dismissed (shown with `t`), `↻` recurring, `⚠️ CONFLICT` overlapping slots.
Keys: `<CR>` open the task, `c` complete, `s` skip, `d` dismiss, `t` show/hide dismissed, `q` close.

`:PKBInbox 2026-11-12` (or `require("pkb.notifier").open_day(2026, 11, 12)`, which calendar-nvim calls) opens it
with the cursor on that day; a day without tasks gets an empty section.

`:PKBInbox tz=-06:00` shows the times and days at another UTC offset (`+05:30`, `-6`, `Z`, and the home letters
`H`/`S` also work), under a `Times in UTC-06:00` header; the notes are not changed. It combines with a date:
`:PKBInbox 2026-11-12 tz=-06:00` (the date is then that offset's day). From Lua: `notifier.inbox({ tz = "-06:00" })`.

## Recurrence

`recur::<rule>` repeats a task; completing or skipping it writes the next instance below it.

- Every N days/weeks/months/years: `3d`, `2w`, `3m`, `1y`, or written out: `day`, `2weeks`, `3months`, `1year`
  (singular or plural). Presets: `daily`, `weekly`, `biweekly`/`fortnightly`, `monthly`, `bimonthly`, `yearly`/
  `annually`; a number multiplies them (`3monthly` = every 3 months).
- N-th weekday of the month: `1st_tue`, `2nd_wed`, `3rd_mon`, `4th_thu`, `last_fri` (full names work too).

Monthly steps from the 29th–31st land on the last day of a shorter month. An unknown rule is reported once and
the task does not repeat; complete and skip leave such a task unchanged until the tag is fixed.

## Reminders

A task with `due::` pops up in a digest window (and as a phone notification on Termux) `notify::` before it
is due: 30 min by default, or e.g. `notify::1h` / `notify::2day` per task.
`[q]` snoozes the digest until the task's next reminder: 15, 10, 5 and 0 min before due, and after that every
30 min until the task is done, skipped or dismissed. A snooze never lasts longer than 30 min, so a task with
`notify::2h` comes back every 30 min before the follow-ups start.

```lua
require("pkb.notifier").setup({
  default_notify = "30min",                       -- first reminder when a task has no notify:: tag
  remind_before = { "15min", "10min", "5min", "0min" }, -- follow-ups ({} for none)
  snooze_interval = 30 * 60,                      -- longest snooze, seconds
})
```

## Tests

```sh
make test                        # or: nvim --clean -l tests/run.lua
make test FILTER=notifier        # only tests whose "file: name" contains the filter
PKB_TEST_VERBOSE=1 make test     # also show why each known bug (xfail) fails
make test NVIM_BIN=/path/to/nvim  # use a specific nvim binary
```

Requires [timestamps-nvim](https://github.com/ettaka/timestamps-nvim): found next to this repo, via
`$TIMESTAMPS_NVIM_DIR`, or cloned into `.deps/` by `make test`.

Tests live in `tests/*_spec.lua` and use the small runner in `tests/run.lua` (no dependencies). They run
headless in a temporary PKB folder (never `~/pkb`) with `TZ=Europe/Helsinki` (override with `PKB_TEST_TZ`).
`t.xfail(...)` marks a known bug: the case must fail, and the run fails with XPASS once the bug is fixed, so the
marker is removed together with the fix.
