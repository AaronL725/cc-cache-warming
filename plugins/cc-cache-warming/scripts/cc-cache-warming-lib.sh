#!/usr/bin/env bash
# ============================================================
# cc-cache-warming-lib.sh  --  shared helpers (sourced, never run)
# ============================================================
# Config, per-session state, the clock, hook-JSON field access and the
# transcript usage reader used by the hook, the monitor and the ctl script.
#
# Pure bash 3.2 (macOS /bin/bash) plus POSIX tools (tail, awk, stat, date).
# No jq, no Python, no network, and never any credential file.
#
# Hot paths (hooks, monitor ticks) avoid process creation: readers return
# their value in REPLY instead of printing it (no $(...) subshell), the clock
# is read once per process, unchanged values are not rewritten, and nothing
# spawns tr/mkdir/cut/rm when a builtin can do it.
#
# State lives in $CCW_STATE_DIR (default ~/.claude/cc-cache-warming):
#   config                      optional KEY=VALUE file (env wins over it)
#   disabled                    global kill switch (ctl off-all)
#   ping_active/<sid>           the prompt_id of that session's running ping
#                               turn -- the one record of "a ping is running"
#                               (PreToolUse fast path: empty dir -> exit at once)
#   bench                       automatic pings benched for one Claude Code
#                               version after a verified miss
#   procs/<claude_pid>          session id the Claude process is on now
#   procs/<claude_pid>.mon      pid of the monitor that owns that process
#   sessions/<sid>/<key>        one small file per state key (atomic writes):
#     real        "<epoch> <prompt_id>" of the last real turn's end (the 6 h
#                 window runs from it; pings never write it)
#     touch_at    last verified cache touch (real turn end or ping delivery)
#     turn        "<epoch> <prompt_id>" while a real turn is open, else absent
#     state       armed | done | stopped (+ reason)
#   sessions/<sid>/log          event log, capped at CCW_LOG_MAX_BYTES
# ============================================================

CCW_STATE_DIR="${CCW_STATE_DIR:-$HOME/.claude/cc-cache-warming}"
CCW_NAME="cc-cache-warming"
# Every ping line starts with this tag plus a nonce, so the hook can tell our
# ping apart from any other prompt or notification.
CCW_TAG="[ccw:"
# Per-window counters, reset together whenever a real turn re-arms.
CCW_COUNTERS="pings delivered hits main_verified blocked partials errors"
# Claude Code version ("2.1.308 (Claude Code)" -> 2.1.308), for the bench.
CCW__VER="${CLAUDE_CODE_VERSION:-unknown}"; CCW__VER="${CCW__VER%% *}"
# BSD (macOS) or GNU date/stat, decided once without spawning anything.
case "${OSTYPE:-}" in darwin*|*bsd*) CCW__BSD=1 ;; *) CCW__BSD=0 ;; esac

# ---- clock --------------------------------------------------------------
# CCW_NOW pins the clock for tests (mock clock); real runs use wall-clock
# time, which keeps counting while the machine sleeps -- deadlines are
# absolute epochs, never "number of ticks". One `date` per refresh gives
# both the epoch and the log timestamp.
CCW__T=""; CCW__STAMP=""
ccw_clock() {
  local d
  if [ -n "${CCW_NOW:-}" ]; then
    CCW__T="$CCW_NOW"; CCW__STAMP=""
  else
    d="$(date '+%s|%Y-%m-%d %H:%M:%S')"
    CCW__T="${d%%|*}"; CCW__STAMP="${d#*|}"
  fi
}

ccw_fmt() { # epoch strftime-format -> prints local time
  if [ "$CCW__BSD" = 1 ]; then date -r "$1" "+$2" 2>/dev/null; else date -d "@$1" "+$2" 2>/dev/null; fi
}
ccw_hhmm() { ccw_fmt "$1" '%H:%M'; }

ccw_dur() { # seconds -> 1h05m / 7m / 40s
  local s="${1:-0}" neg=""
  [ "$s" -lt 0 ] 2>/dev/null && { neg="-"; s=$(( -s )); }
  if [ "$s" -ge 3600 ]; then printf '%s%dh%02dm' "$neg" $((s / 3600)) $(((s % 3600) / 60))
  elif [ "$s" -ge 60 ]; then printf '%s%dm' "$neg" $((s / 60))
  else printf '%s%ds' "$neg" "$s"; fi
}

# ---- config -------------------------------------------------------------
# Environment first, then $CCW_STATE_DIR/config, then defaults. The config
# file is parsed, never sourced, so it cannot run code. Keys that came from
# the environment are remembered once, which lets a long-running monitor
# pick up later edits of the config file without the file overriding env.
ccw_load_config() {
  local f="$CCW_STATE_DIR/config" line key val v
  if [ -z "${CCW__ENVKEYS+x}" ]; then
    CCW__ENVKEYS=" "
    for v in ${!CCW_@}; do
      case "$v" in CCW_[A-Z0-9]*) CCW__ENVKEYS="$CCW__ENVKEYS$v " ;; esac
    done
  fi
  if [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      line="${line#export }"
      key="${line%%=*}"; val="${line#*=}"
      [ "$key" = "$line" ] && continue
      case "$key" in CCW_*) ;; *) continue ;; esac
      case "$key" in *[!A-Z0-9_]*) continue ;; esac
      case "$val" in
        \"*\") val="${val#\"}"; val="${val%\"}" ;;
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
      esac
      case "$CCW__ENVKEYS" in *" $key "*) continue ;; esac
      printf -v "$key" '%s' "$val"
    done < "$f"
  fi
  ccw_params
}

ccw_int() { # VAR default : keep VAR if it is a non-negative integer
  local v
  eval "v=\${$1:-}"
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  printf -v "$1" '%s' "$v"
}

ccw_params() {
  ccw_int CCW_INTERVAL_SECONDS 2880         # ping 48 min after the last cache touch
  ccw_int CCW_TTL_SECONDS 3600              # main-session prompt-cache TTL (promptCacheTtl 1h)
  ccw_int CCW_SAFETY_SECONDS 300            # never ping later than TTL - this
  ccw_int CCW_GATE_MARGIN_SECONDS 120       # hook refuses a ping delivered later than TTL - this
  ccw_int CCW_WINDOW_SECONDS 21600          # hard 6 h window from the last real turn
  ccw_int CCW_MAX_PINGS 8                   # hard cap per window
  ccw_int CCW_TICK_SECONDS 60               # monitor poll period around a ping
  ccw_int CCW_IDLE_TICK_SECONDS 300         # monitor poll period when nothing is due
  ccw_int CCW_MIN_CONTEXT_TOKENS 40000      # do not warm a smaller prompt
  ccw_int CCW_HIT_PERCENT 80                # read/prompt at or above -> hit
  ccw_int CCW_PARTIAL_PERCENT 50            # below -> miss; in between -> partial (once)
  ccw_int CCW_VERIFY_GRACE_SECONDS 180      # wait this long for transcript usage
  ccw_int CCW_TURN_TIMEOUT_SECONDS 900      # delivered ping with no Stop/StopFailure
  ccw_int CCW_RETRY_SECONDS 120             # retry delay after a transient API error
  ccw_int CCW_MAX_ERRORS 2                  # consecutive transient errors before stopping
  ccw_int CCW_TAIL_BYTES 1048576            # max transcript bytes read per verification
  ccw_int CCW_LOG_MAX_BYTES 262144          # a session log is cut in half above this
  ccw_int CCW_CAFFEINATE 1                  # macOS while armed: 1 = no system sleep on AC (display still sleeps), 2 = also on battery, 0 = off
  [ "$CCW_TICK_SECONDS" -ge 1 ] || CCW_TICK_SECONDS=60
  [ "$CCW_IDLE_TICK_SECONDS" -ge "$CCW_TICK_SECONDS" ] || CCW_IDLE_TICK_SECONDS="$CCW_TICK_SECONDS"
  [ "$CCW_MAX_PINGS" -ge 1 ] || CCW_MAX_PINGS=8
  [ "$CCW_TAIL_BYTES" -ge 65536 ] || CCW_TAIL_BYTES=65536
  [ "$CCW_LOG_MAX_BYTES" -ge 4096 ] || CCW_LOG_MAX_BYTES=4096
  # a ping must be able to land inside [interval, ttl - safety)
  if [ "$CCW_SAFETY_SECONDS" -ge "$CCW_TTL_SECONDS" ]; then CCW_SAFETY_SECONDS=$((CCW_TTL_SECONDS / 10)); fi
  if [ "$CCW_INTERVAL_SECONDS" -ge $((CCW_TTL_SECONDS - CCW_SAFETY_SECONDS)) ]; then
    CCW_INTERVAL_SECONDS=$((CCW_TTL_SECONDS - CCW_SAFETY_SECONDS - CCW_TICK_SECONDS))
    [ "$CCW_INTERVAL_SECONDS" -ge 1 ] || CCW_INTERVAL_SECONDS=1
  fi
  CCW_PING_TEXT="${CCW_PING_TEXT:-Automated prompt-cache keep-warm ping (cc-cache-warming). Not a task: do not use tools or resume earlier work. Reply with only: ok}"
}

ccw_enabled() { # 0 when the master switch is on
  case "${CCW_ENABLED:-1}" in
    0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) return 1 ;;
  esac
  return 0
}

# ---- files and state ----------------------------------------------------
# One-line files. Reads use the `read` builtin into REPLY (no subprocess).
# Writes are atomic (dot-temp file + rename) so a hook and the monitor never
# see half a value; an unchanged value is not rewritten (returns 1 then).
ccw_rdf() { # path [default] -> REPLY
  REPLY=""
  [ -f "$1" ] && { IFS= read -r REPLY < "$1"; } 2>/dev/null
  [ -n "$REPLY" ] || REPLY="${2:-}"
}
ccw_setf() { # path value -> 0 written, 1 unchanged
  local cur="" tmp="${1%/*}/.${1##*/}.$$"
  if [ -f "$1" ]; then
    { IFS= read -r cur < "$1"; } 2>/dev/null
    [ "$cur" = "$2" ] && return 1
  fi
  printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null
  return 0
}

ccw_safe() { # id -> REPLY with anything but [A-Za-z0-9._-] replaced
  REPLY="${1//[^A-Za-z0-9._-]/_}"
}

ccw_session() { # sid -> sets SID / SD and creates the session dir
  ccw_safe "${1:-default}"
  SID="${REPLY:-default}"
  SD="$CCW_STATE_DIR/sessions/$SID"
  [ -d "$SD" ] || mkdir -p "$SD" 2>/dev/null || true
}

ccw_rd()  { ccw_rdf "$SD/$1" "${2:-}"; }                 # key [default] -> REPLY
ccw_rdi() { ccw_rd "$1" 0; case "$REPLY" in ''|*[!0-9]*) REPLY=0 ;; esac; }
ccw_get() { ccw_rd "$@"; printf '%s' "$REPLY"; }          # for the ctl script
ccw_geti() { ccw_rdi "$1"; printf '%s' "$REPLY"; }
ccw_set() { ccw_setf "$SD/$1" "$2"; }
ccw_del() { # keys... : one rm for all that exist, none if nothing exists
  local k f=""
  for k in "$@"; do [ -e "$SD/$k" ] && f="$f $SD/$k"; done
  [ -n "$f" ] && rm -f $f 2>/dev/null
  return 0
}
ccw_inc() { ccw_rdi "$1"; ccw_set "$1" $((REPLY + 1)); }

# The two-field records: real -> REAL_AT REAL_PID, turn -> TURN_AT TURN_PID.
ccw_rd_real() { ccw_rd real; REAL_AT="${REPLY%% *}"; REAL_PID="${REPLY#* }"
  case "$REAL_AT" in ''|*[!0-9]*) REAL_AT=0; REAL_PID="" ;; esac; [ "$REAL_PID" = "$REAL_AT" ] && REAL_PID=""; }
ccw_rd_turn() { ccw_rd turn; TURN_AT="${REPLY%% *}"; TURN_PID="${REPLY#* }"; [ "$TURN_PID" = "$TURN_AT" ] && TURN_PID=""; }

# ---- logging --------------------------------------------------------------
ccw_log_to() { # file LEVEL message...
  local f="$1" lvl="$2"; shift 2
  [ -n "$CCW__T" ] || ccw_clock
  [ -n "$CCW__STAMP" ] || CCW__STAMP="$(ccw_fmt "$CCW__T" '%Y-%m-%d %H:%M:%S')"
  printf '[%s] %-28s %s\n' "$CCW__STAMP" "$lvl" "$*" >> "$f" 2>/dev/null || true
}
ccw_log() { ccw_log_to "$SD/log" "$@"; }

# Set a key and log only when its value actually changes (no repeated lines
# for a condition that persists across ticks).
ccw_note() { ccw_set "$1" "$2" && ccw_log "$3" "$4"; }

# Keep a log under its cap by dropping its older half: one stat (skipped when
# the caller already knows the size) and, only when over the cap, tail + mv.
ccw_cap_log() { # file [max_bytes] [known_size]
  local f="$1" max="${2:-$CCW_LOG_MAX_BYTES}" size="${3:-}" tmp
  [ -f "$f" ] || return 0
  [ -n "$size" ] || size="$(ccw_fsize "$f")"
  [ "$size" -gt "$max" ] || return 0
  tmp="${f%/*}/.${f##*/}.$$"
  tail -c $((max / 2)) "$f" 2>/dev/null | sed '1d' > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# ---- window lifecycle ------------------------------------------------------
# A real turn ended at <epoch>: the only place a 6 h window starts. Pings
# never come here. Used by the hook (Stop / StopFailure) and by the monitor
# (an interrupted turn, which fires no Stop).
ccw_rearm() { # epoch prompt_id
  local at="$1" pid="${2:-}" prev_state prev_touch prev_hits prev_pings start k
  ccw_rd state; prev_state="$REPLY"
  ccw_rd_real
  ccw_rdi touch_at; prev_touch="$REPLY"
  ccw_rdi hits; prev_hits="$REPLY"
  ccw_rdi pings; prev_pings="$REPLY"
  ccw_rd_turn; start="${TURN_AT:-$at}"
  case "$start" in ''|*[!0-9]*) start="$at" ;; esac
  # The first request of this turn proves (or disproves) that the pings kept
  # the main session warm: it came after a pinged break longer than the TTL,
  # while the last verified touch was still inside the TTL.
  if [ "$prev_hits" -gt 0 ] && [ -n "$pid" ] \
     && [ $((start - REAL_AT)) -gt "$CCW_TTL_SECONDS" ] \
     && [ "$start" -lt $((prev_touch + CCW_TTL_SECONDS)) ]; then
    ccw_rdi last_prompt; ccw_set ret_expect "$REPLY"
    ccw_set ret_pid "$pid"
    ccw_set ret_idle $((start - REAL_AT))
    ccw_set ret_at "$at"
  fi
  ccw_set real "$at $pid"
  ccw_set touch_at "$at"
  ccw_set state armed
  ccw_ping_end
  ccw_del turn reason pending pending_at retry_at verify_pid baseline last_prompt
  for k in $CCW_COUNTERS; do ccw_set "$k" 0; done
  # log only transitions: an actively used session (armed, no pings yet)
  # would otherwise add a line per turn
  if [ "$prev_state" != "armed" ] || [ "$prev_pings" -gt 0 ]; then
    ccw_log ARMED "real turn done; keeping warm until $(ccw_hhmm $((at + CCW_WINDOW_SECONDS))) (max $CCW_MAX_PINGS pings)"
  fi
}

# End the window until the next real turn re-arms it: state done (it ran its
# course) or stopped (something was wrong). Records and logs why.
ccw_end_window() { # done|stopped reason [log-tag] [log-message]
  ccw_set state "$1"
  ccw_set reason "$2"
  ccw_del pending pending_at retry_at
  ccw_log "${3:-STOP}" "${4:-$2}"
}
ccw_stop() { ccw_end_window stopped "$1" STOP; }

# ---- the running ping turn -------------------------------------------------
# ping_active/<sid> holds the ping's prompt_id while its turn runs. It is the
# single record PreToolUse, Stop and the monitor consult; every way a ping
# turn ends goes through ccw_ping_end.
ccw_ping_begin() { # prompt_id
  [ -d "$CCW_STATE_DIR/ping_active" ] || mkdir -p "$CCW_STATE_DIR/ping_active" 2>/dev/null
  ccw_setf "$CCW_STATE_DIR/ping_active/$SID" "$1"
}
ccw_ping_pid() { ccw_rdf "$CCW_STATE_DIR/ping_active/$SID"; }   # -> REPLY ("" = none)
ccw_ping_end() {
  [ -e "$CCW_STATE_DIR/ping_active/$SID" ] && rm -f "$CCW_STATE_DIR/ping_active/$SID" 2>/dev/null
  return 0
}

# ---- processes ---------------------------------------------------------------
# Which Claude process is this? (CLAUDE_PID is exported to hooks and
# monitors; the ps fallback walks up from the shell Claude Code spawned.)
ccw_claude_pid() { # -> REPLY
  REPLY="${CLAUDE_PID:-}"
  [ -n "$REPLY" ] && return 0
  REPLY="$(ps -o ppid= -p "$PPID" 2>/dev/null)"; REPLY="${REPLY// /}"
}
ccw_proc_sid() { ccw_rdf "$CCW_STATE_DIR/procs/$1"; }   # claude_pid -> REPLY (session id)

ccw_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
ccw_pid_is() { # pid pattern : the pid is alive AND its command line matches
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "$(ps -p "$1" -o command= 2>/dev/null)" in *"$2"*) return 0 ;; esac
  return 1
}
ccw_kill_if() { ccw_pid_is "$1" "$2" && kill "$1" 2>/dev/null; return 0; }  # never a reused pid

ccw_caff_stop() { # the session's keep-awake helper, if any
  ccw_rd caff_pid
  [ -n "$REPLY" ] || return 0
  ccw_kill_if "$REPLY" caffeinate
  ccw_del caff_pid caff_until
}

# ---- switches -------------------------------------------------------------
# Opt-out markers: global kill switch, this session, this project.
ccw_off() { # project_dir -> 0 and REPLY=reason when disabled
  REPLY=""
  if ! ccw_enabled; then REPLY="CCW_ENABLED=off"
  elif [ -f "$CCW_STATE_DIR/disabled" ]; then REPLY="global off (ctl off-all)"
  elif [ -f "$CCW_STATE_DIR/disabled.$SID" ]; then REPLY="session off (ctl off)"
  elif [ -n "${1:-}" ] && [ -f "$1/.claude/$CCW_NAME-off" ]; then REPLY="project off ($1/.claude/$CCW_NAME-off)"
  fi
  [ -n "$REPLY" ]
}

# Version bench: a verified miss on a ping that should have hit pauses
# automatic pings for that Claude Code version, in every session.
ccw_benched() { # 0 when benched for this version
  ccw_rdf "$CCW_STATE_DIR/bench"
  [ -n "$REPLY" ] && [ "${REPLY%%|*}" = "$CCW__VER" ]
}
ccw_bench() { # reason
  printf '%s|%s|%s\n' "$CCW__VER" "$CCW__T" "$1" > "$CCW_STATE_DIR/bench" 2>/dev/null || true
  ccw_log BENCHED "automatic pings paused for Claude Code $CCW__VER in every session ($1; ctl on-all clears it)"
}

# ---- hook JSON ----------------------------------------------------------
# Top-level field of a hook payload -> REPLY. Strings inside the payload are
# JSON-escaped (\"), so a key quoted inside a prompt can never match.
ccw_js() { # key json
  local re="\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
  REPLY=""
  if [[ $2 =~ $re ]]; then REPLY="${BASH_REMATCH[1]}"; fi
}
ccw_jbool() { # key json -> REPLY true/false/""
  local re="\"$1\"[[:space:]]*:[[:space:]]*(true|false)"
  REPLY=""
  if [[ $2 =~ $re ]]; then REPLY="${BASH_REMATCH[1]}"; fi
}

# ---- transcript ---------------------------------------------------------
ccw_fsize() { if [ "$CCW__BSD" = 1 ]; then stat -f %z "$1"; else stat -c %s "$1"; fi 2>/dev/null || echo 0; }
ccw_mtime() { if [ "$CCW__BSD" = 1 ]; then stat -f %m "$1"; else stat -c %Y "$1"; fi 2>/dev/null || echo 0; }
ccw_stat_lines() { # paths... -> "mtime size path" per line, one process for all
  if [ "$CCW__BSD" = 1 ]; then stat -f '%m %z %N' "$@"; else stat -c '%Y %s %n' "$@"; fi 2>/dev/null
}

# Usage of the main-thread requests of ONE turn, read from the transcript
# tail only: the last 256 KB first (a ping turn is always at the very end),
# up to CCW_TAIL_BYTES only if the turn starts earlier. The turn starts at the
# record carrying "promptId":"<pid>" and ends at a record with another
# promptId. With an empty pid, every main-thread assistant record in the
# tail counts (used to find the last request).
#
# prints: found  first: read write input output model  last: read write input output model  h1 m5
#   h1/m5 = 1-hour / 5-minute cache writes summed over the turn's records
ccw_turn_usage() { # transcript prompt_id
  local t="$1" pid="$2" size bytes out
  [ -f "$t" ] || { echo "0 0 0 0 0 - 0 0 0 0 - 0 0"; return; }
  size="$(ccw_fsize "$t")"
  for bytes in 262144 "$CCW_TAIL_BYTES"; do
    [ "$bytes" -gt "$CCW_TAIL_BYTES" ] && bytes="$CCW_TAIL_BYTES"
    out="$(ccw__turn_usage_tail "$t" "$pid" "$bytes" "$size")"
    case "$out" in 1\ *) break ;; esac
    # an empty pid always finds what the tail has; and a tail that already
    # holds the whole file cannot find more
    [ -z "$pid" ] && break
    [ "$size" -le "$bytes" ] && break
  done
  printf '%s\n' "$out"
}
ccw__turn_usage_tail() { # transcript pid bytes size
  local skip=0
  [ "$4" -gt "$3" ] && skip=1
  tail -c "$3" "$1" 2>/dev/null | awk -v pid="$2" -v skip="$skip" '
    function lastidx(s, t,   i, p, off) {
      p = 0; off = 0
      while ((i = index(substr(s, off + 1), t)) > 0) { p = off + i; off = p }
      return p
    }
    function num(s, k,   r) {
      if (match(s, "\"" k "\":[0-9]+")) { r = substr(s, RSTART, RLENGTH); sub(/.*:/, "", r); return r + 0 }
      return 0
    }
    function str(s, k,   r) {
      if (match(s, "\"" k "\":\"[^\"]*\"")) { r = substr(s, RSTART, RLENGTH); sub(/^[^:]*:"/, "", r); sub(/"$/, "", r); return r }
      return ""
    }
    BEGIN { st = (pid == "") ? 1 : 0; done = 0; found = 0; h1 = 0; m5 = 0 }
    NR == 1 && skip == 1 { next }               # first line of a tail is partial
    done { next }
    {
      if (pid != "" && index($0, "\"promptId\":\"")) {
        p = str($0, "promptId")
        if (p == pid) st = 1
        else if (st) { done = 1; next }
      }
      if (!st) next
      if (index($0, "\"type\":\"assistant\"") == 0) next
      if (index($0, "\"isSidechain\":true")) next
      u = lastidx($0, "\"usage\":{")
      if (u == 0) next
      us = substr($0, u)
      m = ""; mi = index($0, "\"message\":{")
      if (mi > 0) m = str(substr($0, mi), "model")
      if (m == "" || m == "<synthetic>") next
      cr = num(us, "cache_read_input_tokens"); cw = num(us, "cache_creation_input_tokens")
      it = num(us, "input_tokens"); ot = num(us, "output_tokens")
      rid = str($0, "requestId")
      if (rid == "" || rid != lastrid) {        # one request may span several records
        h1 += num(us, "ephemeral_1h_input_tokens"); m5 += num(us, "ephemeral_5m_input_tokens")
      }
      lastrid = rid
      if (!found) { fcr = cr; fcw = cw; fit = it; fot = ot; fm = m }
      found = 1; lcr = cr; lcw = cw; lit = it; lot = ot; lm = m
    }
    END {
      if (!found) { print "0 0 0 0 0 - 0 0 0 0 - 0 0"; exit }
      printf "1 %d %d %d %d %s %d %d %d %d %s %d %d\n", fcr, fcw, fit, fot, fm, lcr, lcw, lit, lot, lm, h1, m5
    }'
}

# Did the user interrupt the open turn? (Stop does not fire on Esc.) Only an
# interruption recorded after that turn's own prompt counts.
ccw_turn_interrupted() { # transcript prompt_id
  [ -f "$1" ] && [ -n "${2:-}" ] || return 1
  tail -c "$CCW_TAIL_BYTES" "$1" 2>/dev/null | awk -v pid="$2" '
    index($0, "\"promptId\":\"" pid "\"") { st = 1 }
    st && index($0, "Request interrupted by user") { f = 1; exit }
    END { exit f ? 0 : 1 }'
}
