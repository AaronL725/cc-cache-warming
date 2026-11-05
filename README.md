# cc-cache-warming

**English** · [简体中文](README.zh-CN.md)

<p>
<a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
<a href="test.sh"><img alt="tests: 144 passing" src="https://img.shields.io/badge/tests-144%20passing-brightgreen"></a>
<img alt="Claude Code plugin" src="https://img.shields.io/badge/Claude%20Code-plugin-6E56CF">
<img alt="pure shell" src="https://img.shields.io/badge/pure-bash%203.2%2B-555">
</p>

**Keep the main Claude Code session's prompt cache warm for up to 6 hours after
your last real task, so you come back to a cache read instead of a full rewrite.**

When Claude finishes a task and you walk away, a background **Monitor** sends a
tiny ping *into the same session* about 48 minutes after each cache touch. The
ping is a real turn of the main conversation, so its request reads, and
re-extends, exactly the cache entry your next message will use. Every ping is
**verified from the transcript's token counts**, and warming stops by itself
after 6 hours, after 8 pings, or as soon as anything looks wrong.

Built for Claude Code with `promptCacheTtl: "1h"` (the default for Claude Pro/Max
inside plan usage). Pure Bash 3.2+ and POSIX tools: no jq, no Python, no
network, no credentials.

---

## How it works

```
you: "do X"        ── UserPromptSubmit ─► turn = REAL
Claude works …     ── Stop ─────────────► ARMED: real_at = touch = now
                                           deadline = now + 6h   (only real turns set this)
you walk away
   the Monitor sleeps until the next ping slot (no tokens, a few tiny files):
   touch + 48m ≤ now < touch + 55m ?  cache still worth saving and safe to hit
   └─► prints "[ccw:<nonce>] Automated prompt-cache keep-warm ping …"   = Ping Sent
         Claude Code delivers it as a notification ─► UserPromptSubmit hook = GATE
           too late / not needed / disabled / stale ─► blocked: no model request
           otherwise ─► ping turn (tools denied by PreToolUse) ─► reply "ok"
         Stop (ping) ─► never touches the deadline; queues verification
   next tick: read only the transcript tail for that ping's request usage
     ≥ 80 % of the prompt read from cache and ≥ the main prefix   = Cache Hit Verified
     … and more than one TTL after the last real turn            = Main Session Warm Verified
     miss / big rewrite / 5m tier / other model / no usage      ─► STOP until your next real turn
   repeat until the cache is covered to the deadline, 8 pings, or 6 h
you come back: the first request of your turn is checked too ─► Main Session Warm Verified (return)
```

With the defaults a full break costs **7 pings** (at about 48, 97, 146, 195,
244, 293 and 342 minutes). The last ping keeps the cache alive past the 6 hour
mark, so no 8th ping is needed. The cap of 8 is a hard ceiling.

### Telling real turns from pings

Every ping line carries a random nonce. The `UserPromptSubmit` hook recognises
it and records the ping's `prompt_id`, and the `Stop` with that same
`prompt_id` is treated as a ping. Only other `Stop` events re-arm the window.
A real task, a background-agent result, a `/loop` wakeup or one of the plugin's
own skills starts a new 6 hour window. Pings never do.

### Three levels of evidence

| Level | Meaning | Where it comes from |
| --- | --- | --- |
| **Ping Sent** | the Monitor emitted a ping (and the hook saw it arrive, or blocked it) | monitor + `UserPromptSubmit` hook |
| **Cache Hit Verified** | that ping's API request read ≥ 80 % of its prompt from cache, and at least as many tokens as the main session's prefix | `cache_read_input_tokens` / `cache_creation_input_tokens` of the ping's request in the transcript |
| **Main Session Warm Verified** | a hit that happened **more than one TTL after your last real turn**: that cache entry would have expired without the earlier pings. It is also checked on the first request of your next real turn after the break. | same, plus timing |

A notification or an `ok` reply is never taken as proof. A ping whose usage
cannot be found in the transcript stops warming ("unverifiable").

Because the ping is a turn of the *main* session, there is no fork and no
second cache entry. Its request is byte-for-byte the conversation prefix plus
one short message. The verification also checks this: the read must cover the
main prefix (≥ 90 % of the last real request's prompt) and the model must be
the session's model.

### When it stops (and costs nothing more)

| Condition | Effect |
| --- | --- |
| 6 h since the last real turn, 8 pings, or the cache already covers the deadline | window done |
| ping slot missed (machine slept, Claude busy, notification held back) | **no catch-up**: stop until your next real turn |
| ping delivered too late (≥ TTL − 2 min after the last touch) | blocked by the hook, so no request is made |
| cache miss or large rewrite (< 50 % read; a 50–80 % partial is tolerated once) | stop; if the cache should have been warm, **bench** automatic pings for this Claude Code version in every session |
| your return turn was cold although the pings hit | bench this Claude Code version |
| 5 m cache tier seen (in usage, or `cache_ttl: "5m"` from Claude Code) | stop |
| `/model` switch, compaction, `/clear`, resume with an expired cache | wait for the next real turn |
| context < 40 k tokens | not worth warming |
| `rate_limit` / `billing_error` / auth errors (`StopFailure`) | stop |
| `server_error` / `overloaded` / network | one retry 2 min later, then stop |
| ping turn tries a tool | denied (`PreToolUse`), also under `bypassPermissions` |

### Sleep and wall-clock time

All deadlines are absolute wall-clock times, so the 6 hour clock keeps running
while the screen is off or the Mac sleeps. A ping is only sent inside its safe
slot (48–55 min after the last touch). After a wake-up nothing is sent in
bulk: one ping at most per slot, and a missed slot ends the window.

**The screen is never kept on.** While a window is armed on macOS, the monitor
runs `caffeinate -s -t <until the deadline>`. That holds off *system* sleep
only while on AC power, so the network and the monitor keep running. The
display still turns off on its normal schedule (`pmset` shows
`PreventUserIdleDisplaySleep 0`). It does nothing on battery, ends by itself at
the deadline, and stops as soon as the window ends. Closing the lid still
sleeps the Mac. `CCW_CAFFEINATE=2` uses `-i` (also on battery) and
`CCW_CAFFEINATE=0` turns it off.

### Sessions

* One Monitor per Claude Code process. All state is per session under
  `~/.claude/cc-cache-warming/sessions/<session-id>/`.
* Hooks keep `procs/<claude-pid>` pointing at the session that process is on,
  so after `/clear` or an in-process `/resume` the monitor follows the new
  conversation. The old one is stopped.
* A reloaded plugin starts a new monitor, which takes ownership. The old one goes
  quiet but does not exit, because Claude Code turns a monitor exit into a model
  turn. If our own "monitor ended" notice ever arrives, the hook blocks it.
* `SessionEnd` on exit stops the process's monitor and `caffeinate`, and only
  if the pid really is our monitor.

---

## Install

From GitHub:

```
/plugin marketplace add AaronL725/cc-cache-warming
/plugin install cc-cache-warming@cc-cache-warming
```

From a local clone (edits take effect after `/reload-plugins`):

```bash
git clone https://github.com/AaronL725/cc-cache-warming.git
claude plugin marketplace add ./cc-cache-warming
claude plugin install cc-cache-warming@cc-cache-warming
claude plugin list
```

Then restart Claude Code or run `/reload-plugins`. The monitor starts with every
interactive session. Warming begins after the first real turn finishes.

Requirements: interactive Claude Code CLI (verified on **2.1.308**). Plugin
monitors don't run in `-p`/SDK sessions, on Bedrock/Vertex/Foundry, or when
`DISABLE_TELEMETRY` / `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is set. Your
settings are never modified: keep `promptCacheTtl: "1h"` yourself.

> Run only one cache-warming plugin at a time; multiple warmers can send
> duplicate pings and increase usage.

## Use it

| Want | Do |
| --- | --- |
| See status | `/cc-cache-warming:status` |
| Stop warming **this session** | `/cc-cache-warming:off` (takes effect at once; a queued ping is refused) |
| Turn it back on | `/cc-cache-warming:on` (re-arms after your next real turn) |
| Stop **everywhere** (kill switch) | `bash <plugin>/scripts/cc-cache-warming-ctl.sh off-all` or `touch ~/.claude/cc-cache-warming/disabled` |
| Everything back on (also clears a version bench) | `… cc-cache-warming-ctl.sh on-all` |
| Never in this project | `touch <project>/.claude/cc-cache-warming-off` |
| Never anywhere | `CCW_ENABLED=0` in `~/.claude/cc-cache-warming/config` |
| Read the log | `… cc-cache-warming-ctl.sh log 50` or `tail -f ~/.claude/cc-cache-warming/sessions/<id>/log` |
| All sessions | `… cc-cache-warming-ctl.sh status --all` |

The three skills set `disable-model-invocation: true`, so Claude never runs them
by itself. They run the ctl script through `!` injection, which costs one small
turn (and, being a real turn, re-arms the window). `<plugin>` is the clone's
`plugins/cc-cache-warming`, or the installed copy under `~/.claude/plugins/cache/`.

Example status:

```
cc-cache-warming  (state dir ~/.claude/cc-cache-warming)
config       : interval=48m ttl=1h00m window=6h00m max_pings=8 tick=60s min_context=40000
session      : 0de3b390-…
monitor      : running (pid 52649, claude pid 52439)
switch       : on
state        : ARMED - keeping warm until 07:12 (4h31m left)
next ping    : ~03:27 (in 41m)
last real    : 01:12 (1h29m ago)
cache touch  : 02:39 -> presumed warm until 03:39
main prefix  : 184022 tokens, model claude-opus-5-5, cache tier 1h
pings        : 2/8 sent, 2 delivered, 0 blocked by the gate
verified     : Ping Sent 2 | Cache Hit Verified 2 | Main Session Warm Verified 1 (+0 on return)
last ping    : #2 read=184310 write=296 input=4 output=3 ratio=99% model=claude-opus-5-5
```

## Configuration

Environment variables (in the environment Claude Code starts with) win over
`~/.claude/cc-cache-warming/config` (`KEY=VALUE` lines, parsed, never executed),
which wins over the defaults. The monitor re-reads the file every tick.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CCW_ENABLED` | `1` | `0`/`false`/`no`/`off` disables everything |
| `CCW_INTERVAL_SECONDS` | `2880` | ping 48 min after the last cache touch |
| `CCW_TTL_SECONDS` | `3600` | your main-session cache TTL (`promptCacheTtl: "1h"`) |
| `CCW_SAFETY_SECONDS` | `300` | never *send* a ping later than TTL − this (55 min) |
| `CCW_GATE_MARGIN_SECONDS` | `120` | the hook refuses a ping *delivered* later than TTL − this |
| `CCW_WINDOW_SECONDS` | `21600` | hard window after the last real turn (6 h) |
| `CCW_MAX_PINGS` | `8` | hard cap per window |
| `CCW_TICK_SECONDS` | `60` | monitor poll period around a ping |
| `CCW_IDLE_TICK_SECONDS` | `300` | monitor poll period when nothing is due (it sleeps straight to the ping slot) |
| `CCW_MIN_CONTEXT_TOKENS` | `40000` | don't warm a smaller prompt (Claude Code's own ~27 k system prefix is shared across sessions anyway) |
| `CCW_HIT_PERCENT` / `CCW_PARTIAL_PERCENT` | `80` / `50` | read share for a hit / below which it is a miss |
| `CCW_VERIFY_GRACE_SECONDS` | `180` | wait this long for the transcript to show a ping's usage |
| `CCW_RETRY_SECONDS` / `CCW_MAX_ERRORS` | `120` / `2` | transient API error retry |
| `CCW_TAIL_BYTES` | `1048576` | transcript bytes read per verification (never the whole file) |
| `CCW_CAFFEINATE` | `1` | macOS while armed: `1` = no system sleep on AC power only, `2` = also on battery, `0` = off. The display is never kept on |
| `CCW_LOG_MAX_BYTES` | `262144` | a session log over this is cut to its newest half |
| `CCW_PING_TEXT` | see below | text after the `[ccw:<nonce>]` tag |
| `CCW_STATE_DIR` | `~/.claude/cc-cache-warming` | state, logs, markers |
| `CCW_RETENTION_DAYS` / `CCW_MAX_SESSIONS` | `7` / `200` | archive session dirs idle for 7 days, and the oldest beyond 200, to `archive/cc-cache-warming-<date>.tar.gz` |
| `CCW_ARCHIVE_KEEP_DAYS` / `CCW_HOUSEKEEP_INTERVAL` | `30` / `21600` | delete archives after 30 days (`0` = keep); housekeeping runs at most every 6 h |

Default ping text, about 50 input tokens, normally answered with 3–5 output tokens:

```
[ccw:1a2b3c4d] Automated prompt-cache keep-warm ping (cc-cache-warming). Not a task: do not use tools or resume earlier work. Reply with only: ok
```

Timing rule: `INTERVAL + TICK < TTL − SAFETY`. The script clamps a bad
combination itself. For a 5 minute TTL, warming does not pay off: it stops on
its own when it sees 5 m cache writes.

## Account safety and cost

* **No credentials, no API calls of its own.** The plugin never reads, exports
  or replays OAuth tokens or keys, never calls the API, and never impersonates
  a client. Every ping is an ordinary turn of your own interactive Claude Code
  session, delivered through Claude Code's documented plugin Monitor feature.
* **Bounded and transparent.** At most 8 short turns per break, at most 6 hours
  after real work, never in a loop. The ping text says plainly what it is. It is
  *not* randomised to look human: disguising automation would not lower any
  risk and would be the wrong signal. The only varying part is the nonce the
  hook uses to recognise the ping.
* **Terms.** Usage rules for subscriptions can change. Unattended automation
  that consumes plan usage is a grey area, so read Anthropic's current
  Consumer Terms / Usage Policy and decide for yourself. If in doubt, run
  `ctl.sh off-all`. Pings count against your plan's limits like any turn. A
  cache read is the cheapest kind of request (about 0.1× input), and a cache miss
  stops warming immediately.
* **Break-even.** A cache read is about 0.1× and a 1 h cache write about 2×
  base input, so about 20 pings cost one cold rewrite. A full break here costs
  ≤ 8. See [docs/COST.md](docs/COST.md).

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `monitor : not running` | Monitor unavailable (headless, Bedrock/Vertex/Foundry, telemetry disabled) or plugin not loaded: `claude plugin list`, `/reload-plugins` |
| `state : waiting for the first real turn` | normal right after start / resume |
| `stopped - context … < 40000` | small session; lower `CCW_MIN_CONTEXT_TOKENS` if you really want it |
| `PING_UNDELIVERED` in the log | Claude Code holds notifications while a draft sits in the prompt box; clear the input before leaving |
| `missed the ping slot … likely sleep` | the Mac really slept (lid closed / no power); the cache was gone anyway |
| `BENCHED` | a ping or your return turn missed although the cache should have been warm: a prefix change in this Claude Code version. Run `on-all` to clear it after updating Claude Code |
| `stopped - … 5m cache tier` | check `promptCacheTtl: "1h"` in your settings |
| `CACHE_PARTIAL` on the first ping of a brand-new session | expected: Claude Code's very first cache marker sits on the session-start context; later pings hit fully |
| A ping reply shows in the transcript | by design: the ping is a real turn (`ok`) so it hits the main cache |

Every decision is logged with a reason in `sessions/<id>/log`
(`ARMED`, `PING_SENT`, `PING_DELIVERED`, `PING_BLOCKED`, `TOOL_DENIED`,
`CACHE_HIT_VERIFIED`, `CACHE_PARTIAL`, `MAIN_SESSION_WARM_VERIFIED`,
`RETURN_COLD`, `STOP`, `DONE`, `BENCHED`, …).

## Resource use and caps

Measured on an Apple-silicon Mac with /bin/bash 3.2 (average of 20 runs, from `./test.sh`):

| Path | Runs | Cost |
| --- | --- | --- |
| `PreToolUse` hook | every tool call | **~3 ms**: one bash start and one directory glob, then `exec cat` drains stdin (Claude Code reports a hook that closes stdin early as an EPIPE error); the full hook runs only while a ping turn is running |
| `UserPromptSubmit` / `Stop` hook | once per turn | ~12 ms, no subshells, unchanged state is not rewritten |
| monitor tick | every 5 min idle, straight to the ping slot when armed, every 1 min only around a ping | ~6 ms; `date` + `sleep` are its only processes |
| transcript read | once per ping / return check | last 256 KB (up to 1 MB if needed), never the whole file |

Hooks run in exec form (no `sh -c` wrapper), and `SessionStart` runs async.

Everything on disk has a ceiling:
- **Logs:** each session log is cut to its newest half above 256 KB (checked hourly by the monitor and by housekeeping), and `housekeep.log` is capped at 64 KB. An actively used session logs `ARMED` only on a state change, not once per turn.
- **Session dirs:** they are archived after 7 days idle, or beyond the 200 newest. A session whose Claude process is still alive is never archived.
- **Archives:** deleted after 30 days.
- **Leftovers:** `off` markers of vanished sessions, stale ping markers and temp files are removed.
- **Process entries:** removed when their Claude process exits.

## Tests

```bash
./test.sh                       # 144 checks, ~1.5 min, no Claude needed
CCW_TEST_SHELL=/opt/homebrew/bin/bash ./test.sh
```

A mock clock (`CCW_NOW`) and synthetic transcripts in Claude Code's real record
format drive the hook and `monitor --once` through:

- a full 6 h lifecycle: 7 pings and their times, an unchanged deadline, 7 hits,
  6 main-session verifications, the stop, and the return check;
- the 8-ping cap, re-timing on a new real task, and sleep with no catch-up burst;
- late delivery and stale pings blocked, tool denial, and silent hooks;
- miss with version bench, partial once, 5 m tier, model switch, compaction,
  small context, and a reply from another model;
- quota errors, transient retry, unverifiable or undelivered pings, and
  interrupted turns;
- multi-session isolation, `/clear`, switches, the monitor-ended notice,
  config parsing, live background monitors (silent stdout, takeover, exit with
  Claude, SessionEnd that never kills a foreign pid), housekeeping, and packaging.

The hook/notification facts the design relies on were measured in real
interactive sessions on Claude Code 2.1.308:
- A Monitor line reaches `UserPromptSubmit` as `<task-notification>…<event>LINE</event>`.
- A `block` there prevents the model request.
- `Stop` and `UserPromptSubmit` share `prompt_id`.
- `PreToolUse` deny works under `bypassPermissions`.
- An exiting monitor costs a turn.
- `${CLAUDE_SESSION_ID}` is empty in monitor commands, but
  `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID` are exported.

An end-to-end run of this plugin (Haiku, compressed timings) showed:
- a denied Bash call;
- pings reading 99 % from cache;
- Main Session Warm Verified on a ping after the TTL and on the return turn.

## Limitations

* Each ping adds two short entries (the notification and `ok`) to the
  conversation. A thinking model may spend a few dozen thinking tokens on it.
* Claude Code may generate its own away "recap" after several notifications.
  That call is Claude Code's, not the plugin's.
* A draft left in the prompt box holds notifications back. Pings are then
  refused or skipped, never sent late.
* A truly sleeping Mac (lid closed, no power) cannot ping. The window simply
  ends.
* The transcript format is not a public API. If it changes, verification fails
  safe: "unverifiable", and warming stops.
* Interrupted turns (Esc) fire no `Stop`. They are detected from the
  transcript after 5 minutes.

## Repo layout

```
.
├── .claude-plugin/marketplace.json          # marketplace "cc-cache-warming"
├── plugins/cc-cache-warming/
│   ├── .claude-plugin/plugin.json
│   ├── hooks/hooks.json                     # all events -> cc-cache-warming-hook.sh
│   ├── monitors/monitors.json               # one monitor per session
│   ├── skills/{status,off,on}/SKILL.md      # /cc-cache-warming:*
│   └── scripts/
│       ├── cc-cache-warming-lib.sh          # config, state, clock, transcript reader
│       ├── cc-cache-warming-hook.sh         # classify turns, gate pings, deny tools, re-arm
│       ├── cc-cache-warming-monitor.sh      # schedule, emit, verify, stop
│       ├── cc-cache-warming-ctl.sh          # status | on | off | on-all | off-all | log
│       └── cc-cache-warming-housekeep.sh    # archive stale sessions
├── docs/COST.md                             # warm vs cold cost tables
└── test.sh
```

## License

MIT, see [LICENSE](LICENSE).
