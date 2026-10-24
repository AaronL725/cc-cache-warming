#!/usr/bin/env bash
# ============================================================
# cc-cache-warming-monitor.sh  --  plugin monitor (one per Claude process)
# ============================================================
# Long-running loop. Every stdout line becomes a notification that starts a
# turn in THIS (main) session, so the only thing ever written to stdout is a
# ping line, and only when all of these hold:
#
#   * a real turn has finished and armed the 6 h window (hook: Stop);
#   * no turn is running, no ping is in flight, no retry is pending;
#   * now >= last cache touch + interval (48 min) and
#     now <  last cache touch + TTL - safety (55 min): a ping that could only
#     land after the cache expired is never sent (sleep/resume, delays);
#   * the cache would expire before the 6 h deadline anyway (no wasted last ping);
#   * fewer than max_pings (8) pings this window, context big enough,
#     1 h cache tier, not benched/disabled.
#
# After each ping turn it reads ONLY the transcript tail to verify:
#   Ping Sent                   the line was emitted (and the hook saw it arrive)
#   Cache Hit Verified          the ping's request read >= 80 % of its prompt
#                               from cache and at least the main prefix size
#   Main Session Warm Verified  a hit that happened more than one TTL after the
#                               last real turn -- the main session's cache
#                               survived only because of the pings (also checked
#                               on the first request of your next real turn)
# A miss, a large rewrite, a 5 m cache tier, a model change, an API/quota error
# or an unverifiable ping stops warming until the next real turn.
#
# Cost while running: tick() only decides; next_wake() then picks how long to
# sleep -- straight to the ping slot while armed, CCW_IDLE_TICK_SECONDS (5 min)
# while idle, CCW_TICK_SECONDS (1 min) only around a ping -- and keeps the
# keep-awake helper in step with the window. A tick spawns just `date` (plus
# `sleep`). Once an hour it caps its log and runs housekeeping.
#
# It never exits on its own while Claude is alive (an exiting monitor makes
# Claude Code start a turn to announce it); when stopped it just idles.
#
# Usage: cc-cache-warming-monitor.sh [--session <id>] [--once]
#   --once  run a single tick, print the chosen sleep to stderr, exit
#           (tests drive the clock with CCW_NOW)
# ============================================================
set -uo pipefail

HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE=.
# shellcheck source=cc-cache-warming-lib.sh
. "$HERE/cc-cache-warming-lib.sh"

SESSION_ARG=""; ONCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --session)   shift; SESSION_ARG="${1:-}" ;;
    --session=*) SESSION_ARG="${1#--session=}" ;;
    --once)      ONCE=1 ;;
  esac
  shift || true
done
# Claude Code may pass an unexpanded or empty ${CLAUDE_SESSION_ID}; the
# exported CLAUDE_CODE_SESSION_ID is the reliable source.
case "$SESSION_ARG" in *'${'*|'') SESSION_ARG="" ;; esac
START_SID="${SESSION_ARG:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-default}}}"

# stdout is the notification channel: keep it for pings only
exec 3>&1 1>/dev/null

[ -d "$CCW_STATE_DIR/procs" ] || mkdir -p "$CCW_STATE_DIR/procs" 2>/dev/null
[ -d "$CCW_STATE_DIR/sessions" ] || mkdir -p "$CCW_STATE_DIR/sessions" 2>/dev/null
ccw_claude_pid; CPID="$REPLY"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# This monitor owns its Claude process; a newer monitor (plugin reload)
# takes over and the older one goes quiet.
OWNER_FILE=""
if [ -n "$CPID" ]; then
  OWNER_FILE="$CCW_STATE_DIR/procs/$CPID.mon"
  [ "$ONCE" = 1 ] || printf '%s\n' "$$" > "$OWNER_FILE" 2>/dev/null || true
  if [ ! -f "$CCW_STATE_DIR/procs/$CPID" ]; then
    ccw_safe "$START_SID"; printf '%s\n' "$REPLY" > "$CCW_STATE_DIR/procs/$CPID"
  fi
fi

current_sid() { # -> REPLY
  REPLY=""
  [ -n "$CPID" ] && ccw_proc_sid "$CPID"
  [ -n "$REPLY" ] || REPLY="$START_SID"
}

i_own() {
  [ -z "$OWNER_FILE" ] && return 0
  ccw_rdf "$OWNER_FILE"
  [ -z "$REPLY" ] || [ "$REPLY" = "$$" ]
}

# ---- keep the Mac awake while a window is armed ---------------------------
# Never touches the display: the screen still turns off on schedule, only
# system sleep is held off so the network and this loop keep running.
#   CCW_CAFFEINATE=1  -s  only while on AC power (default; battery unaffected)
#   CCW_CAFFEINATE=2  -i  idle system sleep, also on battery
#   CCW_CAFFEINATE=0      off
caff_ensure() { # deadline
  local p flag
  case "$CCW_CAFFEINATE" in 1) flag=-s ;; 2) flag=-i ;; *) return 0 ;; esac
  ccw_rd caff_pid; p="$REPLY"
  ccw_rdi caff_until
  # still running for this deadline? (kill -0 is a builtin; no ps on the hot path)
  if [ "$REPLY" -ge "$1" ] && ccw_alive "$p"; then return 0; fi
  command -v caffeinate >/dev/null 2>&1 || return 0
  ccw_caff_stop
  # -t: ends by itself at the deadline even if this monitor is gone
  caffeinate "$flag" -t $(($1 - CCW__T)) >/dev/null 2>&1 &
  ccw_set caff_pid "$!"
  ccw_set caff_until "$1"
}

# ---- verification -------------------------------------------------------
# Baseline = prompt size of the last real turn's last request, its model and
# its cache tier. Read lazily, once per real turn (ccw_rearm drops it), when
# the first ping is due.
ensure_baseline() {
  local tp u
  ccw_rd baseline; [ -n "$REPLY" ] && return 0
  ccw_rd_real
  ccw_rd transcript; tp="$REPLY"
  u="$(ccw_turn_usage "$tp" "$REAL_PID")"
  set -- $u
  if [ "$1" != 1 ] && [ -n "$REAL_PID" ]; then u="$(ccw_turn_usage "$tp" "")"; set -- $u; fi
  [ "$1" = 1 ] || return 1
  # $7..$11 = last request of the turn; $12/$13 = 1h/5m writes
  ccw_set last_prompt $(( $7 + $8 + $9 ))
  ccw_set real_model "${11}"
  if [ "${12}" -gt 0 ]; then ccw_set tier 1h
  elif [ "${13}" -gt 0 ]; then ccw_set tier 5m
  else ccw_set tier unknown; fi
  ccw_set baseline $(( $7 + $8 + $9 ))
  return 0
}

verify_ping() { # now
  local now="$1" vp done_at dlv tp u cr cw it ot model prompt prev ratio n rm touch
  ccw_rd verify_pid; vp="$REPLY"; [ -n "$vp" ] || return 0
  ccw_rdi ping_done_at; done_at="$REPLY"
  ccw_rdi ping_delivered_at; dlv="$REPLY"
  ccw_rdi pings; n="$REPLY"
  ccw_rd transcript; tp="$REPLY"
  u="$(ccw_turn_usage "$tp" "$vp")"
  set -- $u
  if [ "$1" != 1 ]; then
    if [ $((now - done_at)) -lt "$CCW_VERIFY_GRACE_SECONDS" ]; then return 0; fi
    ccw_del verify_pid
    ccw_stop "ping #$n unverifiable: no usage for it in the transcript tail"
    return 0
  fi
  ccw_del verify_pid
  cr="$2"; cw="$3"; it="$4"; ot="$5"; model="$6"
  prompt=$((cr + cw + it))
  ccw_rdi last_prompt; prev="$REPLY"
  ratio=0; [ "$prompt" -gt 0 ] && ratio=$((cr * 100 / prompt))
  ccw_set last_result "#$n read=$cr write=$cw input=$it output=$ot ratio=${ratio}% model=$model"
  ccw_rd real_model; rm="$REPLY"
  if [ -n "$rm" ] && [ "$rm" != "-" ] && [ "$model" != "$rm" ]; then
    ccw_stop "ping #$n ran on $model, not the session's $rm; its cache is not the main one"
    return 0
  fi
  if [ "${12}" -eq 0 ] && [ "${13}" -gt 0 ]; then
    ccw_stop "ping #$n wrote to the 5m cache tier; the main session is not on a 1h TTL"
    return 0
  fi
  if [ "$ratio" -ge "$CCW_HIT_PERCENT" ] && [ $((cr * 10)) -ge $((prev * 9)) ]; then
    ccw_set touch_at "$dlv"
    ccw_set last_prompt "$prompt"
    ccw_inc hits
    ccw_log CACHE_HIT_VERIFIED "#$n read $cr of $prompt prompt tokens from cache (${ratio}%), wrote $cw, output $ot"
    ccw_rd_real
    if [ $((dlv - REAL_AT)) -gt "$CCW_TTL_SECONDS" ]; then
      ccw_inc main_verified
      ccw_log MAIN_SESSION_WARM_VERIFIED "#$n hit the main session's prefix $(ccw_dur $((dlv - REAL_AT))) after the last real turn (TTL $(ccw_dur "$CCW_TTL_SECONDS")): earlier pings kept it alive"
    fi
    return 0
  fi
  ccw_rdi partials
  if [ "$ratio" -ge "$CCW_PARTIAL_PERCENT" ] && [ "$REPLY" -eq 0 ]; then
    ccw_set touch_at "$dlv"
    ccw_set last_prompt "$prompt"
    ccw_inc partials
    ccw_log CACHE_PARTIAL "#$n read $cr of $prompt (${ratio}%) and rewrote $cw; tolerated once per window"
    return 0
  fi
  ccw_rdi touch_at; touch="$REPLY"
  ccw_stop "ping #$n missed: read $cr, wrote $cw of $prompt prompt tokens (${ratio}%); expected >= $prev from cache"
  [ "$dlv" -lt $((touch + CCW_TTL_SECONDS)) ] && ccw_bench "ping missed although the cache should have been warm"
  return 0
}

# First request of the next real turn after a pinged break (> TTL since the
# previous real turn): the definitive check that the main session stayed warm.
verify_return() { # now
  local now="$1" rp exp tp u cr cw idle prompt
  ccw_rd ret_pid; rp="$REPLY"; [ -n "$rp" ] || return 0
  ccw_rdi ret_expect; exp="$REPLY"
  ccw_rdi ret_idle; idle="$REPLY"
  ccw_rd transcript; tp="$REPLY"
  u="$(ccw_turn_usage "$tp" "$rp")"
  set -- $u
  if [ "$1" != 1 ]; then
    ccw_rdi ret_at
    [ $((now - REPLY)) -lt "$CCW_VERIFY_GRACE_SECONDS" ] && return 0
    ccw_log RETURN_UNVERIFIED "first request of the returning turn not found in the transcript tail"
    ccw_del ret_pid ret_expect ret_idle ret_at
    return 0
  fi
  cr="$2"; cw="$3"; prompt=$(( $2 + $3 + $4 ))
  ccw_del ret_pid ret_expect ret_idle ret_at
  if [ "$exp" -gt 0 ] && [ $((cr * 10)) -ge $((exp * 9)) ]; then
    ccw_inc ret_verified
    ccw_set last_return "warm: after $(ccw_dur "$idle") away, read $cr of $prompt from cache"
    ccw_log MAIN_SESSION_WARM_VERIFIED "on return after $(ccw_dur "$idle") idle: your next request read $cr of $prompt tokens from cache (expected >= $exp)"
  else
    ccw_set last_return "cold: after $(ccw_dur "$idle") away, read $cr, rewrote $cw"
    ccw_log RETURN_COLD "after $(ccw_dur "$idle") idle your request read $cr and rewrote $cw tokens (expected >= $exp from cache): the pings did not keep the main cache"
    ccw_bench "returning turn was cold after verified pings"
  fi
}

# ---- one decision step ---------------------------------------------------
emit_ping() { # now n touch deadline
  local nonce
  nonce="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null)"; nonce="${nonce//[^0-9a-f]/}"
  [ -n "$nonce" ] || nonce="$RANDOM$RANDOM"
  ccw_set pending "$nonce"
  ccw_set pending_at "$1"
  ccw_set pings "$2"
  ccw_del retry_at
  ccw_log PING_SENT "#$2/$CCW_MAX_PINGS $(ccw_dur $(($1 - $3))) after the last cache touch; window ends $(ccw_hhmm "$4")"
  printf '%s%s] %s\n' "$CCW_TAG" "$nonce" "$CCW_PING_TEXT" >&3
}

# Decides what to do now. Leaves LIVE=1 (window armed and running: keep the
# Mac awake until DEADLINE) and WAIT=1 (nothing in flight: waiting for the
# ping slot) for next_wake(), which turns them into the sleep.
LIVE=0; WAIT=0; DEADLINE=0; LAST_INTR_MT=""
tick() {
  local now pings touch mt
  ccw_load_config
  ccw_clock; now="$CCW__T"
  LIVE=0; WAIT=0
  current_sid; ccw_session "$REPLY"

  if ccw_off "$PROJECT_DIR"; then ccw_note off "$REPLY" OFF "$REPLY; idle"; return 0; fi
  ccw_del off

  verify_return "$now"
  verify_ping "$now"

  ccw_rd state; [ "$REPLY" = "armed" ] || return 0
  ccw_rd_real; DEADLINE=$((REAL_AT + CCW_WINDOW_SECONDS))
  ccw_rdi touch_at; touch="$REPLY"
  ccw_rdi pings; pings="$REPLY"
  if [ "$now" -ge "$DEADLINE" ]; then
    ccw_end_window done "6h window complete" DONE "6h window since the last real turn is over ($pings pings)"; return 0
  fi
  LIVE=1

  # a real turn is open: real work keeps the cache warm by itself. Stop does
  # not fire on Esc, so an interrupted turn would look open forever: check the
  # transcript once it has been quiet for 5 min (and again only if it changed).
  ccw_rd_turn
  if [ -n "$TURN_AT" ]; then
    ccw_rd transcript; mt="$(ccw_mtime "$REPLY")"
    if [ $((now - mt)) -ge 300 ] && [ "$mt" != "$LAST_INTR_MT" ]; then
      LAST_INTR_MT="$mt"
      if ccw_turn_interrupted "$REPLY" "$TURN_PID"; then
        ccw_rearm "$mt" "$TURN_PID"
        ccw_log INTERRUPTED "turn $TURN_PID was interrupted (no Stop); window counted from $(ccw_hhmm "$mt")"
      fi
    fi
    return 0
  fi
  ccw_ping_pid
  if [ -n "$REPLY" ]; then
    ccw_rdi ping_delivered_at
    if [ $((now - REPLY)) -ge "$CCW_TURN_TIMEOUT_SECONDS" ]; then
      ccw_ping_end
      ccw_stop "ping #$pings started but never finished"
    fi
    return 0
  fi
  ccw_rd verify_pid; [ -n "$REPLY" ] && return 0

  ccw_rd pending
  if [ -n "$REPLY" ]; then
    # Claude Code queues a notification while a draft sits in the prompt box;
    # the hook refuses it on arrival if it is too late by then.
    if [ "$now" -ge $((touch + CCW_TTL_SECONDS)) ]; then
      ccw_stop "ping #$pings was never delivered (prompt box busy?) and the cache TTL has passed"
    else
      local pend="$REPLY"; ccw_rdi pending_at
      [ $((now - REPLY)) -ge 300 ] && ccw_note undelivered "$pend" PING_UNDELIVERED \
        "#$pings not delivered after $(ccw_dur $((now - REPLY))); a draft in the prompt box holds notifications back"
    fi
    return 0
  fi
  WAIT=1

  if [ "$pings" -ge "$CCW_MAX_PINGS" ]; then
    ccw_end_window done "max $CCW_MAX_PINGS pings reached" DONE "reached $CCW_MAX_PINGS pings this window"; return 0
  fi
  if [ $((touch + CCW_TTL_SECONDS)) -ge "$DEADLINE" ]; then
    ccw_end_window done "cache covered to the 6h deadline" DONE \
      "last touch keeps the cache until $(ccw_hhmm $((touch + CCW_TTL_SECONDS))), past the deadline; no more pings needed"
    return 0
  fi
  [ "$now" -lt $((touch + CCW_INTERVAL_SECONDS)) ] && return 0
  if [ "$now" -ge $((touch + CCW_TTL_SECONDS - CCW_SAFETY_SECONDS)) ]; then
    # asleep, suspended or held back past the safe slot: never catch up
    ccw_stop "missed the ping slot (now $(ccw_dur $((now - touch))) after the last touch, likely sleep); the cache is presumed cold"
    return 0
  fi
  ccw_rdi retry_at; [ "$REPLY" -gt "$now" ] && return 0
  if ccw_benched; then
    ccw_stop "benched for Claude Code $CCW__VER after a verified miss (ctl on-all clears it)"; return 0
  fi
  if ! ensure_baseline; then
    ccw_stop "no main-session usage found in the transcript; cannot verify pings, so not sending any"; return 0
  fi
  ccw_rd tier
  if [ "$REPLY" = "5m" ] || { ccw_rd cache_ttl; [ "$REPLY" = "5m" ]; }; then
    ccw_stop "the main session writes 5m cache entries; set promptCacheTtl to 1h"; return 0
  fi
  ccw_rdi baseline
  if [ "$REPLY" -lt "$CCW_MIN_CONTEXT_TOKENS" ]; then
    ccw_stop "context $REPLY tokens < $CCW_MIN_CONTEXT_TOKENS; rebuilding it is cheaper than holding it"; return 0
  fi
  emit_ping "$now" $((pings + 1)) "$touch" "$DEADLINE"
}

# After a tick: how long to sleep before anything can change, and whether the
# keep-awake helper should run. A real turn re-arming in the meantime only
# moves the ping slot later, so sleeping until the old slot is always safe.
next_wake() {
  local now="$CCW__T" t best k st
  ccw_rd state; st="$REPLY"
  if [ "$LIVE" = 1 ] && [ "$st" = "armed" ]; then caff_ensure "$DEADLINE"; else ccw_caff_stop; fi
  NEXT="$CCW_IDLE_TICK_SECONDS"
  # something in flight: verify / deliver / finish it promptly
  for k in pending verify_pid ret_pid; do ccw_rd "$k"; [ -n "$REPLY" ] && { NEXT="$CCW_TICK_SECONDS"; return 0; }; done
  ccw_ping_pid; [ -n "$REPLY" ] && { NEXT="$CCW_TICK_SECONDS"; return 0; }
  [ "$WAIT" = 1 ] && [ "$st" = "armed" ] || return 0
  # armed and waiting: wake at the earliest of ping slot, retry, deadline
  ccw_rdi touch_at; best=$((REPLY + CCW_INTERVAL_SECONDS))
  ccw_rdi retry_at; [ "$REPLY" -gt "$now" ] && [ "$REPLY" -lt "$best" ] && best="$REPLY"
  [ "$DEADLINE" -lt "$best" ] && best="$DEADLINE"
  t=$((best - now))
  if [ "$t" -le 0 ]; then NEXT="$CCW_TICK_SECONDS"
  elif [ "$t" -lt "$NEXT" ]; then NEXT="$t"; fi
}

# hourly: cap this session's log, let housekeeping (self-throttled) run
maintenance() {
  ccw_cap_log "$SD/log"
  ( bash "$HERE/cc-cache-warming-housekeep.sh" >/dev/null 2>&1 & ) 2>/dev/null || true
}

if [ "$ONCE" = 1 ]; then
  tick; next_wake
  printf '%s\n' "$NEXT" >&2
  exit 0
fi

# ---- long-running loop ---------------------------------------------------
_quit() { current_sid; ccw_session "$REPLY"; ccw_caff_stop; exit 0; }
trap _quit INT TERM

ccw_load_config
ccw_clock
current_sid; ccw_session "$REPLY"
ccw_log MONITOR_START "pid $$ claude_pid ${CPID:-?} interval=$(ccw_dur "$CCW_INTERVAL_SECONDS") ttl=$(ccw_dur "$CCW_TTL_SECONDS") window=$(ccw_dur "$CCW_WINDOW_SECONDS") max_pings=$CCW_MAX_PINGS tick=${CCW_TICK_SECONDS}s/${CCW_IDLE_TICK_SECONDS}s"
maintenance
NEXT_MAINT=$((CCW__T + 3600))
NEXT="$CCW_TICK_SECONDS"

while :; do
  # background sleep + wait: a TERM interrupts it at once
  sleep "$NEXT" &
  wait $! 2>/dev/null || true
  if [ -n "$CPID" ] && ! ccw_alive "$CPID"; then _quit; fi
  if ! i_own; then NEXT="$CCW_IDLE_TICK_SECONDS"; continue; fi
  tick; next_wake
  if [ "$CCW__T" -ge "$NEXT_MAINT" ]; then maintenance; NEXT_MAINT=$((CCW__T + 3600)); fi
done
