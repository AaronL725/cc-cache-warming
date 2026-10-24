#!/usr/bin/env bash
# ============================================================
# cc-cache-warming-ctl.sh  --  status | on | off | on-all | off-all | log
# ============================================================
# Manual control. Every switch is a marker file the monitor AND the prompt
# hook read on each tick / each ping, so it takes effect at once, without
# restarting anything (killing the monitor would make Claude Code start a turn
# to announce it):
#
#   status [--all]  this session's state, window, ping counters and the three
#                   verification levels; --all lists every known session
#   off             stop warming THIS session (marker disabled.<session>)
#   on              clear this session's marker
#   off-all         global kill switch (marker `disabled`) for every session
#   on-all          clear the global marker, every session marker and the
#                   Claude Code version bench
#   log [n]         last n lines (default 30) of this session's log
#
# "This session" = the session the calling Claude process is on now
# (CLAUDE_PID -> procs/<pid>), else CLAUDE_CODE_SESSION_ID, else the last
# session any hook saw.
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cc-cache-warming-lib.sh
. "$HERE/cc-cache-warming-lib.sh"
ccw_load_config
ccw_clock
mkdir -p "$CCW_STATE_DIR" 2>/dev/null || true

REPLY=""
[ -n "${CLAUDE_PID:-}" ] && ccw_proc_sid "$CLAUDE_PID"
[ -n "$REPLY" ] || REPLY="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
[ -n "$REPLY" ] || ccw_rdf "$CCW_STATE_DIR/last_session"
ccw_session "${REPLY:-default}"

monitor_line() {
  local cp
  ccw_rd claude_pid; cp="$REPLY"
  if [ -z "$cp" ]; then echo "unknown (no hook has run in this session yet)"; return; fi
  ccw_rdf "$CCW_STATE_DIR/procs/$cp.mon"
  if ccw_pid_is "$REPLY" cc-cache-warming-monitor; then
    echo "running (pid $REPLY, claude pid $cp)"
  else
    echo "not running (claude pid $cp)"
  fi
}

status_one() {
  local now="$CCW__T" state reason deadline touch pings next v
  ccw_rd state idle; state="$REPLY"
  ccw_rd reason; reason="$REPLY"
  ccw_rd_real; deadline=$((REAL_AT + CCW_WINDOW_SECONDS))
  ccw_rdi touch_at; touch="$REPLY"
  ccw_rdi pings; pings="$REPLY"
  echo "session      : $SID"
  echo "monitor      : $(monitor_line)"
  if ccw_off "${CLAUDE_PROJECT_DIR:-}"; then
    echo "switch       : OFF ($REPLY)"
  elif ccw_benched; then
    echo "switch       : BENCHED for Claude Code $CCW__VER (${REPLY#*|*|})"
  else
    echo "switch       : on"
  fi
  case "$state" in
    armed)
      echo "state        : ARMED - keeping warm until $(ccw_hhmm "$deadline") ($(ccw_dur $((deadline - now))) left)"
      next=$((touch + CCW_INTERVAL_SECONDS))
      ccw_rd pending; v="$REPLY"
      if [ -n "$v" ]; then
        ccw_rdi pending_at
        echo "next ping    : #$pings sent $(ccw_dur $((now - REPLY))) ago, waiting for delivery"
      elif ccw_ping_pid && [ -n "$REPLY" ]; then
        echo "next ping    : #$pings running now"
      elif [ $((touch + CCW_TTL_SECONDS)) -ge "$deadline" ]; then
        echo "next ping    : none needed (cache covered to the deadline)"
      else
        echo "next ping    : ~$(ccw_hhmm "$next") (in $(ccw_dur $((next - now))))"
      fi ;;
    idle)    echo "state        : waiting for the first real turn" ;;
    *)       echo "state        : ${state} - ${reason:-?} (re-arms after your next real turn)" ;;
  esac
  [ "$REAL_AT" -gt 0 ] && echo "last real    : $(ccw_hhmm "$REAL_AT") ($(ccw_dur $((now - REAL_AT))) ago)"
  [ "$touch" -gt 0 ] && echo "cache touch  : $(ccw_hhmm "$touch") -> presumed warm until $(ccw_hhmm $((touch + CCW_TTL_SECONDS)))"
  ccw_rd baseline; v="$REPLY"
  if [ -n "$v" ]; then
    local model tier
    ccw_rd real_model '?'; model="$REPLY"; ccw_rd tier '?'; tier="$REPLY"
    echo "main prefix  : $v tokens, model $model, cache tier $tier"
  fi
  local dl blk hits mv rv
  ccw_rdi delivered; dl="$REPLY"; ccw_rdi blocked; blk="$REPLY"; ccw_rdi hits; hits="$REPLY"
  ccw_rdi main_verified; mv="$REPLY"; ccw_rdi ret_verified; rv="$REPLY"
  echo "pings        : $pings/$CCW_MAX_PINGS sent, $dl delivered, $blk blocked by the gate"
  echo "verified     : Ping Sent $pings | Cache Hit Verified $hits | Main Session Warm Verified $mv (+$rv on return)"
  ccw_rd last_result; [ -n "$REPLY" ] && echo "last ping    : $REPLY"
  ccw_rd last_return; [ -n "$REPLY" ] && echo "last return  : $REPLY"
  echo "log          : $SD/log"
}

case "${1:-status}" in
  status)
    echo "cc-cache-warming  (state dir $CCW_STATE_DIR)"
    echo "config       : interval=$(ccw_dur "$CCW_INTERVAL_SECONDS") ttl=$(ccw_dur "$CCW_TTL_SECONDS") window=$(ccw_dur "$CCW_WINDOW_SECONDS") max_pings=$CCW_MAX_PINGS tick=${CCW_TICK_SECONDS}s/${CCW_IDLE_TICK_SECONDS}s min_context=$CCW_MIN_CONTEXT_TOKENS"
    if [ "${2:-}" = "--all" ]; then
      for d in "$CCW_STATE_DIR"/sessions/*/; do
        [ -d "$d" ] || continue
        SD="${d%/}"; SID="${SD##*/}"
        echo; status_one
      done
    else
      status_one
    fi
    ;;
  on)
    rm -f "$CCW_STATE_DIR/disabled.$SID"
    echo "cc-cache-warming: ON for this session ($SID)"
    [ -f "$CCW_STATE_DIR/disabled" ] && echo "note: the GLOBAL kill switch is still set; run with 'on-all' to clear it"
    echo "warming (re)starts after your next real turn"
    ;;
  off)
    : > "$CCW_STATE_DIR/disabled.$SID"
    echo "cc-cache-warming: OFF for this session ($SID)"
    echo "no further pings; a ping already queued is refused by the prompt hook."
    echo "other sessions are untouched. Re-enable with 'on'."
    ;;
  on-all)
    rm -f "$CCW_STATE_DIR/disabled" "$CCW_STATE_DIR"/disabled.* "$CCW_STATE_DIR/bench" 2>/dev/null
    echo "cc-cache-warming: ON for all sessions (global/session markers and version bench cleared)"
    echo "warming (re)starts after each session's next real turn"
    ;;
  off-all)
    : > "$CCW_STATE_DIR/disabled"
    echo "cc-cache-warming: OFF for all sessions (global kill switch $CCW_STATE_DIR/disabled)"
    echo "it stays off across restarts until you run this script with 'on-all'"
    ;;
  log)
    n="${2:-30}"; case "$n" in ''|*[!0-9]*) n=30 ;; esac
    if [ -f "$SD/log" ]; then tail -n "$n" "$SD/log"; else echo "(no log yet for session $SID)"; fi
    ;;
  *)
    echo "usage: $0 [status [--all]|on|off|on-all|off-all|log [n]]" >&2
    exit 2
    ;;
esac
