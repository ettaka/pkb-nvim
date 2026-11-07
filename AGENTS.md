# pkb-nvim — agent guide

The core of the PKB stack. It scans `$PKB_ROOT` Markdown for tagged tasks and provides notifications (a digest popup, and Termux notifications on the phone), an inbox, task complete and skip with recurrence, and the agenda and effort providers for calendar-nvim.

This plugin is one part of the PKB stack (`timestamps-nvim` ← `pkb-nvim` ← `calendar-nvim`, wired together by
`toolsrc/nvim-lua`). The cross-repo guide covers the note-tag format, the module map, the test harness, the git
workflow and the rules that keep earlier bugs fixed. It lives in toolsrc at `pkb-dev/AGENTS.md`, which is `~/pkb-dev/AGENTS.md` in the dev
workspace. **Read it before changing anything here.**

Quick reference:
- Test: `make test` (headless, `tests/*_spec.lua`, runner in `tests/run.lua`; `FILTER=...`, `PKB_TEST_VERBOSE=1`).
  Add or change a test for every behaviour you change. A known bug is marked `t.xfail(...)`: write the failing
  test first, fix the code, then turn the `xfail` into `test` (the runner reports XPASS until you do).
- Cross-repo smoke test: `~/pkb-dev/toolsrc/pkb-dev/test/run.sh`.
- Try it in the real editor: `PKB_DEV_DIR=~/pkb-dev nvim`.
- Git: `origin` is `/srv/git/pkb-nvim.git`. Push topic branches there; the owner pushes to GitHub.
- `notifier.lua` holds all state and rewrites note files on complete and skip. Those code paths change user data, so test them in the harness first.
