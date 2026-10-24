#!/usr/bin/env bash
# ============================================================
# test.sh  --  self-test for cc-cache-warming (pure shell, no Claude needed)
# ============================================================
# Drives the hook and the monitor with a MOCK CLOCK (CCW_NOW) and synthetic
# transcripts in Claude Code's real record format, so whole 6-hour lifecycles,
# sleep/resume, misses and API errors run in seconds. A few tests also run
# the monitor as a real background process with a tiny tick.
#
# Runs every script under /bin/bash (bash 3.2 on macOS) unless
# CCW_TEST_SHELL names another shell.
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/plugins/cc-cache-warming/scripts"
HOOK="$S/cc-cache-warming-hook.sh"
MON="$S/cc-cache-warming-monitor.sh"
CTL="$S/cc-cache-warming-ctl.sh"
HK="$S/cc-cache-warming-housekeep.sh"
SH="${CCW_TEST_SHELL:-/bin/bash}"; [ -x "$SH" ] || SH="$(command -v bash)"

TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# a clean, deterministic environment for the scripts
for v in $(compgen -v | grep '^CCW_'); do unset "$v"; done
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_PROJECT_DIR CCW_NOW
export CCW_CAFFEINATE=0
export CLAUDE_CODE_VERSION="2.1.308 (Claude Code)"
export CLAUDE_PID=11111

pass=0; fail=0
check() { # got want label
  if [ "$1" = "$2" ]; then pass=$((pass + 1)); printf '  ok   %s\n' "$3"
  else fail=$((fail + 1)); printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$3" "$1" "$2"; fi
}
yes_no() { if "$@" 2>/dev/null; then echo yes; else echo no; fi; }
section() { printf -- '-- %s --\n' "$*"; }

# ---- fixtures ------------------------------------------------------------
T0=1800000000          # mock epoch of the scenario's first real turn
REQ=0
fresh() { # scenario name: new state dir + transcript
  export CCW_STATE_DIR="$TMP/$1"
  mkdir -p "$CCW_STATE_DIR"
  TR="$CCW_STATE_DIR/t.jsonl"; : > "$TR"
}
sd() { printf '%s' "$CCW_STATE_DIR/sessions/$1"; }
st() { local v=""; [ -f "$(sd "$1")/$2" ] && IFS= read -r v < "$(sd "$1")/$2"; printf '%s' "$v"; }
logc() { grep -c "$2" "$(sd "$1")/log" 2>/dev/null || true; }

hook() { printf '%s' "$2" | CCW_NOW="$1" "$SH" "$HOOK"; }
j() { # event sid pid [extra-json-fields]
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"/w","permission_mode":"bypassPermissions","hook_event_name":"%s","prompt_id":"%s"%s}' "$2" "$TR" "$1" "$3" "${4:-}"
}
ups()  { hook "$1" "$(j UserPromptSubmit "$2" "$3" ",\"prompt\":\"$4\"")"; }
stop() { hook "$1" "$(j Stop "$2" "$3" ',"stop_hook_active":false,"last_assistant_message":"ok"')"; }
tick() { CCW_NOW="$1" "$SH" "$MON" --once 2>/dev/null; }
nexts() { CCW_NOW="$1" "$SH" "$MON" --once 2>&1 >/dev/null; }   # the sleep the monitor chose
real_at() { local v; v="$(st "$1" real)"; printf "%s" "${v%% *}"; }

tr_user() { # pid text
  printf '{"parentUuid":null,"isSidechain":false,"promptId":"%s","type":"user","message":{"role":"user","content":"%s"},"uuid":"u-%s","timestamp":"2027-01-15T08:00:00.000Z"}\n' "$1" "$2" "$1" >> "$TR"
}
tr_asst() { # read write [model] [h1|m5] [sidechain]
  local m="${3:-claude-opus-5-5}" tier="${4:-h1}" sc="${5:-false}" h=0 f=0
  if [ "$tier" = h1 ]; then h="$2"; else f="$2"; fi
  REQ=$((REQ + 1))
  printf '{"parentUuid":"x","isSidechain":%s,"message":{"model":"%s","id":"msg_%d","type":"message","role":"assistant","content":[{"type":"text","text":"ok \\"usage\\":{\\"cache_read_input_tokens\\":1}"},{"type":"tool_use","id":"t","name":"Agent","input":{"model":"haiku","usage":{"x":1}}}],"stop_reason":"end_turn","usage":{"input_tokens":4,"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d,"output_tokens":3,"cache_creation":{"ephemeral_1h_input_tokens":%d,"ephemeral_5m_input_tokens":%d},"iterations":[{"input_tokens":4,"cache_read_input_tokens":999999}]}},"requestId":"req_%d","type":"assistant","uuid":"a%d"}\n' \
    "$sc" "$m" "$REQ" "$2" "$1" "$h" "$f" "$REQ" "$REQ" >> "$TR"
}

# A real turn: prompt at t-60, two requests, Stop at t. The last request's
# prompt (read+write+input) becomes the main-prefix baseline: CTX + 4.
CTX=100000
real_turn() { # t sid pid [first_read]
  ups $(($1 - 60)) "$2" "$3" "please do the task" >/dev/null
  tr_user "$3" "please do the task"
  tr_asst "${4:-$((CTX - 3000))}" 3000
  CTX=$((CTX + 2000))
  tr_asst $((CTX - 1500)) 1500
  stop "$1" "$2" "$3" >/dev/null
  LP=$((CTX + 4))                      # next request should read this much
}

notif() { # line -> a Monitor notification as Claude Code passes it to UserPromptSubmit (JSON-escaped)
  printf '<task-notification>\\n<task-id>bmon1</task-id>\\n<summary>Monitor event: \\"cc-cache-warming: keeps this session\x27s prompt cache warm while you are away\\"</summary>\\n<event>%s</event>\\n</task-notification>' "$1"
}
# Deliver an emitted ping at t: hook gate, then (if allowed) the ping turn's
# request in the transcript and its Stop at t+5. read/write default to a hit.
deliver() { # t sid line pid [read] [write] [model] [tier]
  local out
  out="$(ups "$1" "$2" "$4" "$(notif "$3")")"
  if [ -n "$out" ]; then LAST_BLOCK="$out"; return 1; fi
  LAST_BLOCK=""
  tr_user "$4" "<task-notification> $3"
  tr_asst "${5:-$LP}" "${6:-300}" "${7:-claude-opus-5-5}" "${8:-h1}"
  stop $(($1 + 5)) "$2" "$4" >/dev/null
  LP=$(( ${5:-$LP} + ${6:-300} + 4 ))
  return 0
}

# Run the monitor once a minute from $2 to $3; every emitted ping is
# delivered 10 s later as a cache hit. Records ping times (minutes after T0).
life() { # sid from to -- steps by the sleep the monitor chose, on the 60 s grid
  local t="$2" line n=0 nx
  PING_MIN=""; EXTRA_OUT=""
  while [ "$t" -le "$3" ]; do
    line="$(CCW_NOW="$t" "$SH" "$MON" --once 2>"$TMP/next")"
    nx="$(cat "$TMP/next")"
    if [ -n "$line" ]; then
      case "$line" in "[ccw:"*) ;; *) EXTRA_OUT="$EXTRA_OUT|$line" ;; esac
      n=$((n + 1))
      PING_MIN="$PING_MIN $(((t - T0) / 60))"
      deliver $((t + 10)) "$1" "$line" "p$n-$t" || :
      nx=60
    fi
    t=$((t + (nx + 59) / 60 * 60))
  done
}

echo "cc-cache-warming self-test (shell: $SH)"

# =========================================================================
section "transcript usage reader (tail only, escaped text, sidechains)"
fresh parse
. "$S/cc-cache-warming-lib.sh"; ccw_load_config
tr_user P1 "hello"
tr_asst 5000 700
tr_asst 9000 100 claude-opus-5-5 h1 true      # subagent record: ignored
tr_asst 6000 50
tr_user P2 "next"
tr_asst 7000 20 claude-sonnet-5-5 m5
check "$(ccw_turn_usage "$TR" P1)" "1 5000 700 4 3 claude-opus-5-5 6000 50 4 3 claude-opus-5-5 750 0" "first/last request of turn P1, sidechain skipped, escaped/nested usage ignored"
check "$(ccw_turn_usage "$TR" P2)" "1 7000 20 4 3 claude-sonnet-5-5 7000 20 4 3 claude-sonnet-5-5 0 20" "turn P2: model and 5m tier"
check "$(ccw_turn_usage "$TR" NOPE | cut -d' ' -f1)" "0" "unknown prompt id -> not found"
check "$(ccw_turn_usage "$TR" "" | cut -d' ' -f7)" "7000" "empty prompt id -> last main request in the tail"
for _ in $(seq 1 400); do printf '{"type":"progress","pad":"%0200d"}\n' 0 >> "$TR"; done
tr_user P3 "late"; tr_asst 4242 1
check "$(CCW_TAIL_BYTES=65536 ccw_turn_usage "$TR" P3 | cut -d' ' -f2)" "4242" "reads only the tail and skips the partial first line"
ccw_js prompt_id '{"prompt":"x \"prompt_id\":\"evil\"","prompt_id":"good"}'; check "$REPLY" "good" "hook JSON: a key quoted inside a prompt is never matched"

# =========================================================================
section "full 6h lifecycle on a mock clock (interval 48m, TTL 1h)"
fresh life
real_turn "$T0" A r1
check "$(st A state)" "armed" "real turn arms the window"
check "$(st A real)" "$T0 r1" "the window is anchored at the real turn (deadline = it + 6h)"
check "$(tick $((T0 + 2820)))" "" "no ping at 47m (before the 48m interval)"
life A "$T0" $((T0 + 7 * 3600))
check "$PING_MIN" " 48 97 146 195 244 293 342" "7 pings, each ~48m after the previous cache touch, last one before 6h"
check "$EXTRA_OUT" "" "the monitor printed nothing but ping lines"
check "$(( $(real_at A) + 21600 ))" "$((T0 + 21600))" "pings never moved the 6h deadline"
check "$(real_at A)" "$T0" "pings never counted as real activity"
check "$(st A pings)" "7" "ping counter = 7 (cap 8)"
check "$(st A delivered)/$(st A hits)" "7/7" "7 delivered, 7 Cache Hit Verified"
check "$(st A main_verified)" "6" "Main Session Warm Verified for pings 2..7 (each > 1 TTL after the real turn)"
check "$(st A state)|$(st A reason)" "done|cache covered to the 6h deadline" "stops by itself: last touch covers the deadline"
check "$(logc A PING_SENT)" "7" "log: Ping Sent x7"
check "$(logc A CACHE_HIT_VERIFIED)" "7" "log: Cache Hit Verified x7"

section "returning after the pinged break: definitive main-session check"
REQ_BEFORE=$REQ
real_turn $((T0 + 350 * 60)) A r2 "$LP"
check "$(st A ret_pid)" "r2" "first turn after a >TTL pinged break is queued for verification"
tick $((T0 + 351 * 60)) >/dev/null
check "$(st A ret_verified)" "1" "your next request read the main prefix: Main Session Warm Verified (return)"
check "$(logc A 'on return')" "1" "log: MAIN_SESSION_WARM_VERIFIED on return"
check "$(( $(real_at A) + 21600 ))" "$((T0 + 350 * 60 + 21600))" "the real turn restarted the 6h window"
check "$(st A pings)/$(st A hits)" "0/0" "the real turn reset the per-window counters"

section "max ping cap"
fresh cap
export CCW_WINDOW_SECONDS=43200
real_turn "$T0" C r1
life C "$T0" $((T0 + 12 * 3600))
check "$(echo $PING_MIN | wc -w | tr -d ' ')" "8" "a 12h window still stops at 8 pings"
check "$(st C state)|$(st C reason)" "done|max 8 pings reached" "state says why it stopped"
unset CCW_WINDOW_SECONDS

section "a new real task restarts the clock; pings do not"
fresh retime
real_turn "$T0" R r1
life R "$T0" $((T0 + 150 * 60))
check "$PING_MIN" " 48 97 146" "3 pings in the first 2.5h"
real_turn $((T0 + 150 * 60 + 30)) R r2
check "$(( $(real_at R) + 21600 ))" "$((T0 + 150 * 60 + 30 + 21600))" "new real turn: deadline = its end + 6h"
check "$(st R pings)" "0" "ping budget reset"
life R $((T0 + 151 * 60)) $((T0 + 151 * 60 + 7 * 3600))
check "$(echo $PING_MIN | wc -w | tr -d ' ')" "7" "a full new window follows"
check "$(real_at R)" "$((T0 + 150 * 60 + 30))" "real_at is the last REAL turn"

section "sleep / suspend: no burst of catch-up pings"
fresh sleep
real_turn "$T0" Z r1
tick $((T0 + 1800)) >/dev/null
check "$(tick $((T0 + 7200)))" "" "waking 2h later: no ping (cache already expired)"
check "$(st Z state)" "stopped" "missed slot -> stopped until the next real turn"
out=""; for m in 121 122 130 200 300; do out="$out$(tick $((T0 + m * 60)))"; done
check "$out" "" "no catch-up pings on later ticks"
case "$(st Z reason)" in *"missed the ping slot"*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "reason names the missed slot"
real_turn $((T0 + 301 * 60)) Z r2
check "$(st Z state)" "armed" "the next real turn re-arms after a sleep"

section "late delivery is refused by the prompt hook (no model request)"
fresh late
real_turn "$T0" L r1
line="$(tick $((T0 + 2880)))"
check "$(yes_no test -n "$line")" "yes" "ping emitted at 48m"
deliver $((T0 + 3540)) L "$line" pL || :
case "$LAST_BLOCK" in *'"decision":"block"'*"too late"*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "delivered at 59m -> blocked (cache likely cold, would only rewrite)"
check "$(st L turn)$(yes_no test -e "$CCW_STATE_DIR/ping_active/L")" "no" "a blocked ping never becomes a turn"
check "$(st L blocked)" "1" "blocked counter"

section "a queued ping that arrives right after real work is refused as not needed / stale"
fresh stale
real_turn "$T0" Q r1
line="$(tick $((T0 + 2880)))"
real_turn $((T0 + 2900)) Q r2
deliver $((T0 + 2950)) Q "$line" pQ || :
case "$LAST_BLOCK" in *"stale ping"*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "ping emitted before a real turn is refused after it"

section "tools are denied inside a ping turn only (bypassPermissions too)"
fresh tools
real_turn "$T0" T r1
line="$(tick $((T0 + 2880)))"
ups $((T0 + 2890)) T pT "$(notif "$line")" >/dev/null
out="$(hook $((T0 + 2891)) "$(j PreToolUse T pT ',"tool_name":"Bash","tool_input":{"command":"rm -rf x"}')")"
case "$out" in *'"permissionDecision":"deny"'*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "PreToolUse in the ping turn -> deny"
check "$(logc T TOOL_DENIED)" "1" "the attempt is logged"
stop $((T0 + 2895)) T pT >/dev/null
ups $((T0 + 3000)) T r9 "real work" >/dev/null
check "$(hook $((T0 + 3001)) "$(j PreToolUse T r9 ',"tool_name":"Bash"')")" "" "PreToolUse in a real turn -> untouched"
check "$(ups $((T0 + 3002)) T r10 "hello")" "" "a real prompt passes silently (no stdout injected into context)"
check "$(stop $((T0 + 3003)) T r10)" "" "Stop prints nothing"
. "$S/cc-cache-warming-lib.sh"; ccw_params
case "$CCW_PING_TEXT" in *"do not use tools"*"Reply with only: ok"*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "default ping text forbids tools and asks for a one-word reply"
check "$(yes_no test "${#CCW_PING_TEXT}" -le 160)" "yes" "default ping text stays short (${#CCW_PING_TEXT} chars)"

section "cache miss / large rewrite stops warming and benches the version"
fresh miss
real_turn "$T0" M r1
line="$(tick $((T0 + 2880)))"
deliver $((T0 + 2890)) M "$line" pM 27000 $((LP - 27000)) || :
tick $((T0 + 2940)) >/dev/null
check "$(st M state)" "stopped" "a ping that rewrote the prefix stops warming"
check "$(st M hits)" "0" "a miss is never counted as a Cache Hit"
check "$(yes_no test -f "$CCW_STATE_DIR/bench")" "yes" "the Claude Code version is benched (prefix mismatch)"
real_turn $((T0 + 4000)) N n1
check "$(tick $((T0 + 4000 + 2880)))" "" "benched: another session sends no ping either"
case "$(st N reason)" in *benched*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "the other session says it is benched"
"$SH" "$CTL" on-all >/dev/null
check "$(yes_no test -f "$CCW_STATE_DIR/bench")" "no" "ctl on-all clears the bench"

section "a partial hit is tolerated once, a second one stops"
fresh partial
real_turn "$T0" P r1
line="$(tick $((T0 + 2880)))"; deliver $((T0 + 2890)) P "$line" p1 $((LP * 7 / 10)) $((LP * 3 / 10)) || :
tick $((T0 + 2940)) >/dev/null
check "$(st P state)/$(st P partials)" "armed/1" "first partial (70%) tolerated"
line="$(tick $((T0 + 2890 + 2880)))"; deliver $((T0 + 5780)) P "$line" p2 $((LP * 6 / 10)) $((LP * 4 / 10)) || :
tick $((T0 + 5830)) >/dev/null
check "$(st P state)" "stopped" "second partial stops"

section "5m cache tier, model switch, compaction, small context"
fresh tier
real_turn "$T0" F r1
line="$(tick $((T0 + 2880)))"; deliver $((T0 + 2890)) F "$line" pF "$LP" 300 claude-opus-5-5 m5 || :
tick $((T0 + 2940)) >/dev/null
case "$(st F reason)" in *"5m cache tier"*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "a ping writing 5m entries stops (main session not on 1h TTL)"
real_turn $((T0 + 9000)) F r2
hook $((T0 + 9100)) "$(j PostModelSwitch F "" ',"from_model":"claude-opus-5-5","to_model":"claude-sonnet-5-5","cache_ttl":"1h"')" >/dev/null
check "$(st F state)" "stopped" "model switch -> wait for the next real turn"
check "$(tick $((T0 + 9000 + 2880)))" "" "no ping after a model switch"
real_turn $((T0 + 12000)) F r3
hook $((T0 + 12100)) "$(j PostModelSwitch F "" ',"from_model":"claude-opus-5-5","to_model":"claude-opus-5-5","cache_ttl":"5m"')" >/dev/null
case "$(st F reason)" in *"TTL is 5m"*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "cache_ttl 5m reported by Claude Code -> stop"
real_turn $((T0 + 15000)) F r4
hook $((T0 + 15100)) "$(j PostCompact F "" ',"trigger":"manual"')" >/dev/null
check "$(st F state)" "stopped" "compaction -> wait for the next real turn"
fresh small
CTX=20000; real_turn "$T0" G r1; CTX=100000
check "$(tick $((T0 + 2880)))" "" "context below 40k tokens -> no ping"
case "$(st G reason)" in *"rebuilding it is cheaper"*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "small-context reason recorded"
fresh model
real_turn "$T0" H r1
line="$(tick $((T0 + 2880)))"; deliver $((T0 + 2890)) H "$line" pH "$LP" 300 claude-haiku-5-5 || :
tick $((T0 + 2940)) >/dev/null
case "$(st H reason)" in *"not the session's"*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "a ping answered by another model is not a main-session hit"

section "API errors: quota stops, transient errors retry once"
fresh api
real_turn "$T0" E r1
line="$(tick $((T0 + 2880)))"
ups $((T0 + 2890)) E pE1 "$(notif "$line")" >/dev/null
hook $((T0 + 2895)) "$(j StopFailure E pE1 ',"error":"server_error","error_details":"500"')" >/dev/null
check "$(st E state)" "armed" "first transient error: still armed"
check "$(tick $((T0 + 2940)))" "" "no immediate retry"
line="$(tick $((T0 + 2895 + 120)))"
check "$(yes_no test -n "$line")" "yes" "retry after 2 minutes"
ups $((T0 + 3020)) E pE2 "$(notif "$line")" >/dev/null
hook $((T0 + 3025)) "$(j StopFailure E pE2 ',"error":"overloaded"')" >/dev/null
check "$(st E state)" "stopped" "second transient error in a row stops"
real_turn $((T0 + 5000)) E r2
line="$(tick $((T0 + 5000 + 2880)))"
ups $((T0 + 7890)) E pE3 "$(notif "$line")" >/dev/null
hook $((T0 + 7895)) "$(j StopFailure E pE3 ',"error":"rate_limit","last_assistant_message":"API Error: Rate limit reached"')" >/dev/null
case "$(st E reason)" in *rate_limit*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "rate_limit (quota) on a ping stops without retry"
real_turn $((T0 + 9000)) E r3
hook $((T0 + 9001)) "$(j StopFailure E r4 ',"error":"billing_error"')" >/dev/null
check "$(st E state)" "stopped" "a real turn failing on quota also stops warming"

section "unverifiable or undelivered pings"
fresh unver
real_turn "$T0" U r1
line="$(tick $((T0 + 2880)))"
ups $((T0 + 2890)) U pU "$(notif "$line")" >/dev/null
stop $((T0 + 2895)) U pU >/dev/null            # no usage written to the transcript
tick $((T0 + 2940)) >/dev/null
check "$(st U state)" "armed" "missing usage: wait for the transcript to catch up"
tick $((T0 + 2895 + 200)) >/dev/null
case "$(st U reason)" in *unverifiable*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "still no usage after the grace period -> stop (never assume success)"
fresh undel
real_turn "$T0" V r1
line="$(tick $((T0 + 2880)))"
for m in 49 50 51 53 55 58; do tick $((T0 + m * 60)) >/dev/null; done
check "$(logc V PING_UNDELIVERED)" "1" "an undelivered ping is reported once"
check "$(tick $((T0 + 3600)))" "" "no second ping while one is pending"
check "$(st V state)" "stopped" "pending past the TTL -> stop"

section "interrupted turn (Esc: no Stop hook) still arms the window"
fresh intr
ups "$T0" I i1 "long job" >/dev/null
tr_user i1 "long job"; tr_asst 97000 3000; tr_asst 99000 1000
tr_user i1 "[Request interrupted by user]"
touch -t "$(date -r $((T0 + 60)) '+%Y%m%d%H%M.%S' 2>/dev/null || date -d @$((T0 + 60)) '+%Y%m%d%H%M.%S')" "$TR"
hook "$T0" "$(j SessionStart I "" ',"source":"startup"')" >/dev/null
printf "armed\n" > "$(sd I)/state"; printf "%s x\n" $((T0 - 100)) > "$(sd I)/real"
tick $((T0 + 600)) >/dev/null
check "$(real_at I)" "$((T0 + 60))" "interrupted turn treated as finished at the transcript's last write"
check "$(st I turn)" "" "no longer considered busy"

section "multi-session isolation"
fresh multi
real_turn "$T0" S1 a1
CLAUDE_PID=22222 real_turn "$T0" S2 b1
CLAUDE_PID=22222 ups $((T0 + 2000)) S2 b2 "busy again" >/dev/null
l1="$(tick $((T0 + 2880)))"
l2="$(CLAUDE_PID=22222 tick $((T0 + 2880)))"
check "$(yes_no test -n "$l1")" "yes" "session 1 (idle) pings"
check "$l2" "" "session 2 (turn running) does not"
check "$(st S2 pings)" "0" "session 2's counters untouched"
check "$(cat "$CCW_STATE_DIR/procs/11111")/$(cat "$CCW_STATE_DIR/procs/22222")" "S1/S2" "each Claude process maps to its own session"
"$SH" -c "CLAUDE_PID=22222 '$SH' '$CTL' off" >/dev/null
check "$(yes_no test -f "$CCW_STATE_DIR/disabled.S2")" "yes" "ctl off targets the calling process's session"
check "$(yes_no test -f "$CCW_STATE_DIR/disabled.S1")" "no" "...and only that one"

section "/clear moves the monitor to the new session"
fresh clear
real_turn "$T0" OLD o1
hook $((T0 + 10)) "$(j SessionEnd OLD "" ',"reason":"clear"')" >/dev/null
hook $((T0 + 11)) "$(j SessionStart NEW "" ',"source":"clear"')" >/dev/null
check "$(cat "$CCW_STATE_DIR/procs/11111")" "NEW" "process map follows /clear"
check "$(st OLD state)" "stopped" "old conversation stops warming"
check "$(tick $((T0 + 2880)))" "" "no ping for the cleared conversation"
real_turn $((T0 + 100)) NEW n1
check "$(yes_no test -n "$(tick $((T0 + 100 + 2880)))")" "yes" "the new conversation is warmed after its first real turn"

section "switches: off / on / off-all / project / CCW_ENABLED"
fresh sw
real_turn "$T0" W r1
line="$(tick $((T0 + 2880)))"
CLAUDE_PID=11111 "$SH" "$CTL" off >/dev/null
deliver $((T0 + 2890)) W "$line" pW || :
case "$LAST_BLOCK" in *"session off"*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "a ping already queued when you turn it off is refused"
real_turn $((T0 + 3000)) W r2
check "$(tick $((T0 + 3000 + 2880)))" "" "off: no pings"
CLAUDE_PID=11111 "$SH" "$CTL" on >/dev/null
check "$(yes_no test -n "$(tick $((T0 + 3000 + 2940)))")" "yes" "on: pings again, no restart needed"
"$SH" "$CTL" off-all >/dev/null
real_turn $((T0 + 9000)) W r3
check "$(tick $((T0 + 9000 + 2880)))" "" "off-all (global kill switch): no pings"
"$SH" "$CTL" on-all >/dev/null
mkdir -p "$TMP/proj/.claude"; : > "$TMP/proj/.claude/cc-cache-warming-off"
check "$(CLAUDE_PROJECT_DIR="$TMP/proj" tick $((T0 + 9000 + 2880)))" "" "project opt-out file: no pings"
check "$(CCW_ENABLED=0 tick $((T0 + 9000 + 2900)))" "" "CCW_ENABLED=0: no pings"
case "$(CLAUDE_PID=11111 "$SH" "$CTL" status)" in *"ARMED"*"Ping Sent"*"Cache Hit Verified"*"Main Session Warm Verified"*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "status shows the window and all three verification levels"

section "monitor-ended notification is suppressed (it would cost a turn)"
fresh ended
out="$(ups "$T0" X x1 '<task-notification>\n<task-id>b1</task-id>\n<summary>Monitor \"cc-cache-warming: keeps this session prompt cache warm while you are away\" stream ended</summary>\n</task-notification>')"
case "$out" in *'"decision":"block"'*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "our monitor's stream-ended notice is blocked"
out="$(ups "$T0" X x2 '<task-notification>\n<summary>Monitor \"build watcher\" stream ended</summary>\n</task-notification>')"
check "$out" "" "other monitors' notices pass through"

section "config file: parsed, never executed; env wins"
fresh cfg
printf 'CCW_MAX_PINGS=3\nCCW_TICK_SECONDS=$(touch %s/pwned)\nCCW_WINDOW_SECONDS="7200"\n' "$CCW_STATE_DIR" > "$CCW_STATE_DIR/config"
. "$S/cc-cache-warming-lib.sh"
( unset CCW__ENVKEYS CCW_MAX_PINGS CCW_TICK_SECONDS CCW_WINDOW_SECONDS; CCW_WINDOW_SECONDS=999; ccw_load_config; echo "$CCW_MAX_PINGS $CCW_WINDOW_SECONDS $CCW_TICK_SECONDS" ) > "$TMP/cfg.out"
check "$(cat "$TMP/cfg.out")" "3 999 60" "config values apply, env overrides them, garbage falls back to defaults"
check "$(yes_no test -e "$CCW_STATE_DIR/pwned")" "no" "config text is never executed"

section "real background monitor: silent stdout, owner hand-over, exits with Claude"
fresh live
sleep 300 & FAKE=$!; PIDS+=("$FAKE")
export CLAUDE_PID="$FAKE"
real_turn "" L1 l1
live_env="CCW_TICK_SECONDS=1 CCW_IDLE_TICK_SECONDS=1 CCW_INTERVAL_SECONDS=2 CCW_TTL_SECONDS=40 CCW_SAFETY_SECONDS=5 CCW_WINDOW_SECONDS=120"
env $live_env CLAUDE_CODE_SESSION_ID=L1 "$SH" "$MON" --session '${CLAUDE_SESSION_ID}' > "$TMP/live.out" 2>"$TMP/live.err" &
M1=$!; PIDS+=("$M1")
for _ in $(seq 1 40); do [ -s "$TMP/live.out" ] && break; sleep 0.2; done
check "$(head -c 5 "$TMP/live.out")" "[ccw:" "a live monitor emits a tagged ping line"
check "$(grep -vc '^\[ccw:' "$TMP/live.out")" "0" "nothing but ping lines on stdout"
check "$(cat "$CCW_STATE_DIR/procs/$FAKE.mon")" "$M1" "monitor registered as owner of its Claude process"
env $live_env CLAUDE_CODE_SESSION_ID=L1 "$SH" "$MON" > "$TMP/live2.out" 2>/dev/null &
M2=$!; PIDS+=("$M2")
for _ in $(seq 1 30); do [ "$(cat "$CCW_STATE_DIR/procs/$FAKE.mon")" = "$M2" ] && break; sleep 0.1; done
check "$(cat "$CCW_STATE_DIR/procs/$FAKE.mon")" "$M2" "a reloaded monitor takes over"
check "$(yes_no kill -0 "$M1")" "yes" "the old one stays (quietly) instead of exiting"
hook "" "$(j SessionEnd L1 "" ',"reason":"prompt_input_exit"')" >/dev/null
for _ in $(seq 1 30); do kill -0 "$M2" 2>/dev/null || break; sleep 0.1; done
check "$(yes_no kill -0 "$M2")" "no" "SessionEnd on exit stops the owning monitor"
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null
for _ in $(seq 1 30); do kill -0 "$M1" 2>/dev/null || break; sleep 0.2; done
check "$(yes_no kill -0 "$M1")" "no" "a monitor exits once its Claude process is gone"
sleep 30 & DECOY=$!; PIDS+=("$DECOY")
printf '%s\n' "$DECOY" > "$CCW_STATE_DIR/procs/$FAKE.mon"; printf 'L1\n' > "$CCW_STATE_DIR/procs/$FAKE"
hook "" "$(j SessionEnd L1 "" ',"reason":"other"')" >/dev/null
check "$(yes_no kill -0 "$DECOY")" "yes" "SessionEnd never kills a pid that is not our monitor"
export CLAUDE_PID=11111

section "housekeeping archives stale sessions"
fresh hk
mkdir -p "$CCW_STATE_DIR/sessions/OLD" "$CCW_STATE_DIR/sessions/NEWS" "$CCW_STATE_DIR/sessions/CUR" "$CCW_STATE_DIR/procs"
printf x > "$CCW_STATE_DIR/sessions/OLD/log"; printf x > "$CCW_STATE_DIR/sessions/NEWS/log"; printf x > "$CCW_STATE_DIR/sessions/CUR/log"
touch -t 202001010000 "$CCW_STATE_DIR/sessions/OLD/log" "$CCW_STATE_DIR/sessions/CUR/log" "$CCW_STATE_DIR/sessions/OLD" "$CCW_STATE_DIR/sessions/CUR"
printf x > "$CCW_STATE_DIR/config"; printf 'S\n' > "$CCW_STATE_DIR/procs/999999"
CLAUDE_CODE_SESSION_ID=CUR CCW_HOUSEKEEP_INTERVAL=0 "$SH" "$HK"
check "$(yes_no test -d "$CCW_STATE_DIR/sessions/OLD")" "no" "old session archived away"
check "$(yes_no test -d "$CCW_STATE_DIR/sessions/NEWS")" "yes" "recent session kept"
check "$(yes_no test -d "$CCW_STATE_DIR/sessions/CUR")" "yes" "current session kept"
check "$(yes_no test -f "$CCW_STATE_DIR/config")" "yes" "config kept"
check "$(yes_no test -f "$CCW_STATE_DIR/procs/999999")" "no" "entry for a dead Claude process removed"
check "$(tar -tzf "$CCW_STATE_DIR/archive/cc-cache-warming-2020-01-01.tar.gz" 2>/dev/null | grep -c 'OLD/log')" "1" "dated archive contains it"

section "caps: logs, archives, session count, markers"
fresh caps
. "$S/cc-cache-warming-lib.sh"; ccw_load_config
for i in $(seq 1 6); do real_turn $((T0 + i * 100)) K "k$i"; done
check "$(logc K ARMED)" "1" "an actively used session logs ARMED once, not once per turn"
mkdir -p "$CCW_STATE_DIR/sessions/BIG"
awk 'BEGIN { for (i = 0; i < 6000; i++) printf "[2027-01-01 00:00:00] %-28s line %d padding padding padding\n", "X", i }' > "$CCW_STATE_DIR/sessions/BIG/log"
before="$(ccw_fsize "$CCW_STATE_DIR/sessions/BIG/log")"
ccw_cap_log "$CCW_STATE_DIR/sessions/BIG/log" 262144
after="$(ccw_fsize "$CCW_STATE_DIR/sessions/BIG/log")"
check "$(yes_no test "$before" -gt 262144 -a "$after" -le 131072)" "yes" "a log over 256 KB is cut to its newest half ($before -> $after bytes)"
check "$(tail -n1 "$CCW_STATE_DIR/sessions/BIG/log" | grep -c 'line 5999')" "1" "the newest lines are kept"
check "$(head -c1 "$CCW_STATE_DIR/sessions/BIG/log")" "[" "the cut starts on a whole line"
fresh caps2
mkdir -p "$CCW_STATE_DIR/procs" "$CCW_STATE_DIR/ping_active" "$CCW_STATE_DIR/archive"
awk 'BEGIN { for (i = 0; i < 9000; i++) print "padding padding padding padding padding" }' > "$TMP/big.log"
nowr=$(date +%s)
for i in $(seq 1 12); do
  mkdir -p "$CCW_STATE_DIR/sessions/s$i"; printf x > "$CCW_STATE_DIR/sessions/s$i/log"
  [ "$i" = 12 ] && cp "$TMP/big.log" "$CCW_STATE_DIR/sessions/s12/log"
  touch -t "$(date -r $((nowr - (20 - i) * 60)) '+%Y%m%d%H%M.%S')" "$CCW_STATE_DIR/sessions/s$i/log" "$CCW_STATE_DIR/sessions/s$i"
done
printf 's1\n' > "$CCW_STATE_DIR/procs/$$"                  # s1 belongs to a live process
: > "$CCW_STATE_DIR/disabled.gone"; touch -t 202001010000 "$CCW_STATE_DIR/disabled.gone"
: > "$CCW_STATE_DIR/disabled.s12"; touch -t 202001010000 "$CCW_STATE_DIR/disabled.s12"
: > "$CCW_STATE_DIR/ping_active/stuck"; touch -t 202001010000 "$CCW_STATE_DIR/ping_active/stuck"
: > "$CCW_STATE_DIR/sessions/s12/.state.4242"; touch -t 202001010000 "$CCW_STATE_DIR/sessions/s12/.state.4242"
: > "$CCW_STATE_DIR/archive/cc-cache-warming-2020-01-01.tar.gz"; touch -t 202001010000 "$CCW_STATE_DIR/archive/cc-cache-warming-2020-01-01.tar.gz"
CCW_MAX_SESSIONS=5 CCW_HOUSEKEEP_INTERVAL=0 "$SH" "$HK"
check "$(ls "$CCW_STATE_DIR/sessions" | wc -l | tr -d ' ')" "6" "session count capped (5 newest + one with a live Claude process)"
check "$(yes_no test -d "$CCW_STATE_DIR/sessions/s1")" "yes" "a session whose Claude process is alive is never archived"
check "$(yes_no test -d "$CCW_STATE_DIR/sessions/s2")" "no" "the oldest sessions beyond the cap are archived"
check "$(yes_no test "$(ccw_fsize "$CCW_STATE_DIR/sessions/s12/log")" -le 262144)" "yes" "housekeeping caps every session log"
check "$(yes_no test -f "$CCW_STATE_DIR/disabled.gone")" "no" "an old off-marker of a vanished session is removed"
check "$(yes_no test -f "$CCW_STATE_DIR/disabled.s12")" "yes" "an off-marker of an existing session stays"
check "$(yes_no test -f "$CCW_STATE_DIR/ping_active/stuck")" "no" "a stale ping marker (> 1 h) is removed"
check "$(yes_no test -f "$CCW_STATE_DIR/sessions/s12/.state.4242")" "no" "leftover temp files are removed"
check "$(yes_no test -f "$CCW_STATE_DIR/archive/cc-cache-warming-2020-01-01.tar.gz")" "no" "archives older than 30 days are pruned by default"

section "performance: PreToolUse fast path, adaptive sleep, exec-form hooks"
fresh perf
real_turn "$T0" A r1
head -c 300000 /dev/zero | "$SH" "$HOOK" PreToolUse > "$TMP/pre.out"; ps0="${PIPESTATUS[0]}"
check "$(cat "$TMP/pre.out")|$ps0" "|0" "no ping running: PreToolUse prints nothing and drains even a 300 KB payload (no EPIPE for Claude Code)"
line="$(tick $((T0 + 2880)))"
ups $((T0 + 2890)) A pA "$(notif "$line")" >/dev/null
check "$(yes_no test -f "$CCW_STATE_DIR/ping_active/A")" "yes" "a delivered ping raises its session's marker"
out="$(printf '%s' "$(j PreToolUse A pA ',"tool_name":"Bash"')" | "$SH" "$HOOK" PreToolUse)"
case "$out" in *'"permissionDecision":"deny"'*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "with a ping running the same fast-path entry still denies its tools"
: > "$CCW_STATE_DIR/ping_active/OTHER"
stop $((T0 + 2895)) A pA >/dev/null
check "$(yes_no test -f "$CCW_STATE_DIR/ping_active/A")/$(yes_no test -f "$CCW_STATE_DIR/ping_active/OTHER")" "no/yes" "a ping's Stop clears only its own session's marker"
rm -f "$CCW_STATE_DIR/ping_active/OTHER"
fresh sleepy
real_turn "$T0" B r1
check "$(nexts $((T0 + 60)))" "300" "armed, ping far away: sleep the idle tick (5 min)"
check "$(nexts $((T0 + 2780)))" "100" "armed, ping in 100 s: sleep exactly until the slot"
check "$(nexts $((T0 + 2880)))" "60" "ping just sent: short tick until it is verified"
fresh idle
check "$(nexts "$T0")" "300" "nothing armed: idle tick"
bad=""
for ev in SessionStart UserPromptSubmit PreToolUse Stop StopFailure PostCompact PostModelSwitch SessionEnd; do
  grep -q "\"$ev\": *\[ *{[^]]*\"command\": \"bash\", \"args\": \[\"\${CLAUDE_PLUGIN_ROOT}/scripts/cc-cache-warming-hook.sh\", \"$ev\"\]" "$HERE/plugins/cc-cache-warming/hooks/hooks.json" || bad="$bad $ev"
done
check "$bad" "" "every hook runs in exec form (no sh -c wrapper) and passes its event name"
fresh bench
real_turn "$T0" P r1
ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
t1=$(ms); for _ in $(seq 1 20); do printf '{}' | "$SH" "$HOOK" PreToolUse; done; t2=$(ms)
for _ in $(seq 1 20); do stop "" P "x$_" >/dev/null; done; t3=$(ms)
for _ in $(seq 1 20); do tick "" >/dev/null; done; t4=$(ms)
printf '       timing: PreToolUse %d ms, Stop %d ms, monitor tick %d ms (avg of 20)\n' $(((t2 - t1) / 20)) $(((t3 - t2) / 20)) $(((t4 - t3) / 20))
check "$(yes_no test $(((t2 - t1) / 20)) -lt 15)" "yes" "PreToolUse fast path averages under 15 ms"

if command -v caffeinate >/dev/null 2>&1; then
  fresh caff
  real_turn "$T0" CF r1
  CCW_CAFFEINATE=1 tick $((T0 + 60)) >/dev/null
  cp_pid="$(st CF caff_pid)"
  check "$(ps -p "${cp_pid:-0}" -o command= 2>/dev/null | sed 's/^.*caffeinate/caffeinate/')" "caffeinate -s -t 21540" "armed window: caffeinate -s (AC-only system sleep, never the display) until the deadline"
  case "$(pmset -g assertions 2>/dev/null | grep "pid ${cp_pid:-0}(caffeinate)")" in *PreventUserIdleDisplaySleep*) r=yes ;; *) r=no ;; esac
  check "$r" "no" "it never asserts PreventUserIdleDisplaySleep (the screen still turns off)"
  hook $((T0 + 70)) "$(j SessionEnd CF "" ',"reason":"prompt_input_exit"')" >/dev/null
  for _ in 1 2 3 4 5; do kill -0 "$cp_pid" 2>/dev/null || break; sleep 0.2; done
  check "$(yes_no kill -0 "$cp_pid")" "no" "SessionEnd stops it"
fi

section "packaging"
P="$HERE/plugins/cc-cache-warming"
missing=""
for f in "$P"/skills/*/SKILL.md; do grep -q '^disable-model-invocation: true' "$f" || missing="$missing $f"; done
check "$missing" "" "every skill sets disable-model-invocation: true"
check "$(ls -1 "$P/skills" | tr '\n' ' ')" "off on status " "skills: off, on, status"
check "$(grep -o '"name": *"[^"]*"' "$P/.claude-plugin/plugin.json" | head -1)" '"name": "cc-cache-warming"' "plugin is named cc-cache-warming"
case "$(cat "$P/monitors/monitors.json")" in *'"description": "cc-cache-warming'*) r=yes ;; *) r=no ;; esac
check "$r" "yes" "monitor description starts with the plugin name (stream-ended filter relies on it)"
leak="$(grep -rIl -e "\.credentials" -e "find-generic-password" -i -e "keychain" -e "OAUTH_TOKEN" -e "ANTHROPIC_API_KEY" "$P/scripts" 2>/dev/null | tr '\n' ' ')"
check "$leak" "" "scripts never touch credentials or the keychain"
bad=""; for f in "$P"/scripts/*.sh "$HERE/test.sh"; do "$SH" -n "$f" 2>/dev/null || bad="$bad $f"; done
check "$bad" "" "every script parses under $SH"

printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
