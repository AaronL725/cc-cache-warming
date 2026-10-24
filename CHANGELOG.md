# Changelog

All notable changes to this project are documented here.

## [4.1.0] — bounded disk use, lower overhead, screen never kept on

### Changed
- `caffeinate` now uses `-s` by default: system sleep is held off only on AC
  power while a window is armed, never the display (the screen still turns
  off). `CCW_CAFFEINATE=2` keeps the old `-i` (also on battery).
- Hooks run in exec form (`bash` + `args`, no `sh -c` wrapper); `SessionStart`
  is async.
- The monitor sleeps straight to the next ping slot when armed and every
  `CCW_IDLE_TICK_SECONDS` (5 min) when idle; the 1 min tick is used only around
  a ping.

### Performance
- `PreToolUse` skips all parsing unless a ping turn is running
  (`ping_active/<session>`): one directory glob, then `exec cat` drains stdin
  (closing it early is reported by Claude Code as an EPIPE hook error):
  11 ms -> ~3 ms per tool call.
- No `$(...)` subshells on hot paths (readers return in `REPLY`), one `date`
  per process, no `tr`/`mkdir`/`cut`/`rm` where a builtin does it, unchanged
  state not rewritten: `Stop` 62 -> ~12 ms, monitor tick 25 -> ~6 ms.
- Transcript reads try the last 256 KB before the 1 MB maximum.

### Added (caps)
- Session logs cut to their newest half above `CCW_LOG_MAX_BYTES` (256 KB),
  checked hourly by the monitor and by housekeeping; `housekeep.log` capped at
  64 KB; `ARMED` is logged only on a state change.
- At most `CCW_MAX_SESSIONS` (200) session dirs; archives deleted after
  `CCW_ARCHIVE_KEEP_DAYS` (now 30, was forever); stale `disabled.<sid>`,
  ping markers and temp files removed; housekeeping also runs hourly.

### Tests
- 144 checks (caps, fast path, adaptive sleep, exec-form hooks, caffeinate -s, timing).

## [4.0.0] — cc-cache-warming: verified, bounded main-session warming

### Changed (breaking)
- Plugin and marketplace `cc-cache-warming`, scripts `cc-cache-warming-*.sh`,
  variables `CCW_*`, state `~/.claude/cc-cache-warming/`, and skills
  `/cc-cache-warming:{status,off,on}`.
- Lifecycle: a hard 6 h window starts at the end of the last *real* turn and
  pings never extend it. Pings are told apart from real turns by `prompt_id`
  and fire ~48 min after the last verified cache touch, at most 8 per window,
  and stop once the cache is covered to the deadline (7 pings for a full 6 h break).
- One hook script (`cc-cache-warming-hook.sh`) handles SessionStart,
  UserPromptSubmit, PreToolUse, Stop, StopFailure, PostCompact,
  PostModelSwitch and SessionEnd; the separate stamp/cleanup scripts are gone.

### Added
- Verification from the transcript tail: Ping Sent / Cache Hit Verified (≥ 80 %
  of the ping's prompt read from cache and ≥ the main prefix) / Main Session
  Warm Verified (a hit more than one TTL after the last real turn), plus a
  check of the first request of the returning turn.
- Delivery gate in UserPromptSubmit: a ping that arrives too late, is no longer
  needed, is stale, or arrives while disabled is blocked, so no model request
  is made. The monitor's own "stream ended" notice is blocked too.
- Every tool call of a ping turn is denied (PreToolUse), also under
  bypassPermissions.
- Stops on cache miss / large rewrite (a partial hit is tolerated once), 5 m
  cache tier, model switch, compaction, `/clear`, expired resume, small
  context, quota/auth errors; one retry for transient API errors. A miss on a
  cache that should have been warm benches automatic pings for that Claude
  Code version in every session (`on-all` clears it).
- Sleep safety: wall-clock deadlines, a ping only inside its 48–55 min slot,
  never a catch-up burst; macOS `caffeinate -i -t <deadline>` while armed (`-s` since 4.1.0)
  (`CCW_CAFFEINATE=0` to disable).
- Sessions: monitors follow `/clear` and in-process `/resume` via
  `procs/<claude-pid>`, a reloaded monitor takes over, the old one goes quiet
  instead of exiting (an exit costs a model turn), monitors exit with Claude.
- `off`/`on` take effect immediately without restarting anything; new
  `/cc-cache-warming:on` skill; `ctl status --all` and `ctl log`.
- Config file is parsed, never sourced; env wins; re-read every tick.

### Tests
- Rewritten `test.sh` (pure shell, mock clock, synthetic transcripts in Claude
  Code's real format, live background monitors): 119 checks.
