#!/usr/bin/env bash
# ============================================================
# cc-cache-warming-hook.sh  --  every hook event of the plugin
# ============================================================
# Fast, silent, never blocks a real prompt. It tells real turns from our own
# pings and keeps the per-session state the monitor acts on:
#
#   UserPromptSubmit  a prompt carrying our [ccw:<nonce>] tag inside a Monitor
#                     notification is a PING: it is let through only if it is
#                     still useful and safe (gate), else blocked so no model
#                     request is made. Anything else opens a REAL turn.
#   PreToolUse        denies every tool call of a ping turn (matched by
#                     prompt_id), so a ping can never run tools -- this holds
#                     even under bypassPermissions. Every other tool call
#                     exits after one directory glob (no ping turn running).
#   Stop              a ping turn's Stop only queues verification; it never
#                     touches the 6 h window. A real turn's Stop re-arms it.
#   StopFailure       API errors: quota/auth stop warming, transient ones retry.
#   PostCompact /     the cached prefix is gone or belongs to another model:
#   PostModelSwitch   wait for the next real turn.
#   SessionStart /    session bookkeeping; SessionEnd on exit stops this
#   SessionEnd        process's monitor.
#
# Hook stdout is fed back to Claude for some events, so nothing is printed
# except the documented block/deny JSON.
# ============================================================

# ---- PreToolUse fast path: runs on EVERY tool call ----------------------
# Without a ping turn in flight (ping_active/ is empty) there is nothing to
# deny: skip the library and the parsing. stdin is still drained, by
# exec-ing cat in place of this shell (no extra fork): Claude Code reports a
# hook that closes stdin before its input is written as an EPIPE hook error.
if [ "${1:-}" = "PreToolUse" ]; then
  for f in "${CCW_STATE_DIR:-$HOME/.claude/cc-cache-warming}"/ping_active/*; do
    [ -e "$f" ] || exec cat >/dev/null 2>&1
    break
  done
fi

set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE=.
# shellcheck source=cc-cache-warming-lib.sh
. "$HERE/cc-cache-warming-lib.sh"

input="$(cat 2>/dev/null || true)"
ccw_js hook_event_name "$input"; ev="$REPLY"
ccw_js session_id "$input";      sid="${REPLY:-${CLAUDE_CODE_SESSION_ID:-default}}"
ccw_js prompt_id "$input";       pid="$REPLY"
ccw_session "$sid"

# Is this prompt_id the session's running ping turn?
is_ping_turn() { [ -n "$pid" ] && ccw_ping_pid && [ "$REPLY" = "$pid" ]; }

if [ "$ev" = "PreToolUse" ]; then
  if is_ping_turn; then
    ccw_js tool_name "$input"
    ccw_log TOOL_DENIED "ping turn tried to call $REPLY"
    printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"cc-cache-warming: this turn is an automated cache keep-warm ping; tools are disabled. Reply with only: ok"}}'
  fi
  exit 0
fi

ccw_load_config
ccw_clock; now="$CCW__T"

ccw_js transcript_path "$input"; [ -n "$REPLY" ] && ccw_set transcript "$REPLY"
ccw_claude_pid; cpid="$REPLY"
if [ -n "$cpid" ]; then
  [ -d "$CCW_STATE_DIR/procs" ] || mkdir -p "$CCW_STATE_DIR/procs" 2>/dev/null
  ccw_setf "$CCW_STATE_DIR/procs/$cpid" "$SID"
  ccw_set claude_pid "$cpid"
fi
ccw_setf "$CCW_STATE_DIR/last_session" "$SID"

block() { # reason: refuse this prompt -> no model request
  printf '{"decision":"block","reason":"%s"}' "cc-cache-warming: $1"
}

case "$ev" in
  UserPromptSubmit)
    case "$input" in
      *'<task-notification>'*"$CCW_TAG"*)
        # ---- one of our pings arrived: final gate before any model request
        re='\[ccw:([A-Za-z0-9]+)\]'
        nonce=""; [[ $input =~ $re ]] && nonce="${BASH_REMATCH[1]}"
        ccw_rd pending; pending="$REPLY"
        ccw_rdi touch_at; touch_at="$REPLY"
        ccw_rd state; state="$REPLY"
        ccw_rd_real
        why=""
        if [ -z "$nonce" ] || [ "$nonce" != "$pending" ]; then why="stale ping (not the one pending)"
        elif ccw_off "${CLAUDE_PROJECT_DIR:-}"; then why="$REPLY"
        elif ccw_benched; then why="benched for Claude Code $CCW__VER"
        elif [ "$state" != "armed" ]; then ccw_rd reason idle; why="not armed ($REPLY)"
        elif [ "$now" -ge $((REAL_AT + CCW_WINDOW_SECONDS)) ]; then why="6h window over"
        elif [ "$now" -ge $((touch_at + CCW_TTL_SECONDS - CCW_GATE_MARGIN_SECONDS)) ]; then
          why="delivered too late ($(ccw_dur $((now - touch_at))) after the last cache touch); the cache is likely cold, a ping would only rewrite it"
        elif [ $((now - touch_at)) -lt $((CCW_INTERVAL_SECONDS / 2)) ]; then
          why="not needed: the cache was refreshed $(ccw_dur $((now - touch_at))) ago"
        fi
        if [ -n "$why" ]; then
          [ -n "$nonce" ] && [ "$nonce" = "$pending" ] && ccw_del pending pending_at
          ccw_inc blocked
          ccw_log PING_BLOCKED "$why"
          block "ping skipped: $why"
          exit 0
        fi
        ccw_del pending pending_at
        ccw_ping_begin "$pid"
        ccw_set ping_delivered_at "$now"
        ccw_inc delivered
        ccw_rdi pings
        ccw_log PING_DELIVERED "#$REPLY reached the main session (prompt $pid)"
        exit 0 ;;
      *'<task-notification>'*'Monitor \"'"$CCW_NAME"*'stream ended'*)
        # our monitor's own exit notice would cost a full model turn
        ccw_log MONITOR_ENDED "suppressed the monitor-ended notification"
        block "monitor stopped (notification suppressed)"
        exit 0 ;;
    esac
    # ---- a real turn opens (typed prompt, background task result, ...)
    ccw_set turn "$now $pid"
    ;;

  Stop)
    if is_ping_turn; then
      # ping turn ended: verify from the transcript; the window is untouched
      ccw_ping_end
      ccw_set ping_done_at "$now"
      ccw_set verify_pid "$pid"
      ccw_set errors 0
      ccw_js last_assistant_message "$input"
      ccw_log PING_TURN_DONE "reply: ${REPLY:0:40}"
    else
      ccw_rearm "$now" "$pid"
    fi
    ;;

  StopFailure)
    ccw_js error "$input"; err="$REPLY"
    if is_ping_turn; then
      ccw_ping_end
      case "$err" in
        overloaded|server_error|unknown|'')
          ccw_inc errors; ccw_rdi errors
          if [ "$REPLY" -lt "$CCW_MAX_ERRORS" ]; then
            ccw_set retry_at $((now + CCW_RETRY_SECONDS))
            ccw_log PING_FAILED "transient API error ($err); one retry in $(ccw_dur "$CCW_RETRY_SECONDS")"
          else
            ccw_stop "ping failed: $REPLY API errors in a row ($err)"
          fi ;;
        *)
          ccw_stop "ping failed: $err (quota, account or request error; no retry)" ;;
      esac
    else
      # a real turn failed: it was still real activity, but a quota/auth
      # error means pings would fail too
      ccw_rearm "$now" "$pid"
      case "$err" in
        rate_limit|billing_error|account_on_hold|authentication_failed|oauth_org_not_allowed)
          ccw_stop "last turn failed with $err; not pinging" ;;
      esac
    fi
    ;;

  PostCompact)
    ccw_del turn
    ccw_ping_end
    ccw_rd state; [ "$REPLY" = "armed" ] && ccw_stop "context compacted; waiting for the next real turn to cache the new prefix"
    ;;

  PostModelSwitch)
    ccw_js from_model "$input"; from="$REPLY"
    ccw_js to_model "$input"; to="$REPLY"
    ccw_js cache_ttl "$input"; ttl="$REPLY"
    [ -n "$ttl" ] && ccw_set cache_ttl "$ttl"
    ccw_rd state
    if [ "$ttl" = "5m" ]; then
      ccw_stop "main cache TTL is 5m; warming every few minutes costs more than it saves"
    elif [ -n "$to" ] && [ "$from" != "$to" ] && [ "$REPLY" = "armed" ]; then
      ccw_stop "model switched $from -> $to; the new model has no cached prefix yet"
    fi
    ;;

  SessionStart)
    ccw_js source "$input"; src="$REPLY"
    ccw_js model "$input"; model="$REPLY"
    ccw_rd state; state="$REPLY"
    case "$src" in
      clear|compact)
        [ "$state" = "armed" ] && ccw_stop "session $src; waiting for the next real turn" ;;
      resume)
        ccw_jbool prompt_cache_likely_expired "$input"
        [ "$state" = "armed" ] && [ "$REPLY" = "true" ] && ccw_stop "resumed with an expired cache; waiting for the next real turn" ;;
    esac
    ccw_log SESSION_START "source=${src:-?} model=${model:-?}"
    ;;

  SessionEnd)
    ccw_js reason "$input"; reason="$REPLY"
    ccw_rd state; [ "$REPLY" = "armed" ] && ccw_stop "session ended ($reason)"
    ccw_del turn
    ccw_ping_end
    case "$reason" in
      clear|resume) : ;;  # the process lives on; its monitor follows procs/<pid>
      *)
        # the process is exiting: stop its monitor and keep-awake helper
        if [ -n "$cpid" ]; then
          ccw_rdf "$CCW_STATE_DIR/procs/$cpid.mon"
          ccw_kill_if "$REPLY" cc-cache-warming-monitor
          rm -f "$CCW_STATE_DIR/procs/$cpid" "$CCW_STATE_DIR/procs/$cpid.mon" 2>/dev/null
        fi
        ccw_caff_stop ;;
    esac
    ccw_log SESSION_END "reason=${reason:-?}"
    ;;
esac
exit 0
