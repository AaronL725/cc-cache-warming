#!/usr/bin/env bash
# ============================================================
# cc-cache-warming-housekeep.sh  --  keep the state directory bounded
# ============================================================
# Everything the plugin writes has a ceiling. This pass enforces them:
#
#   * procs/<pid>, procs/<pid>.mon of Claude processes that are gone: removed
#   * session dirs untouched for CCW_RETENTION_DAYS (7), and the oldest ones
#     beyond CCW_MAX_SESSIONS (200): bundled into
#     archive/cc-cache-warming-<date>.tar.gz (by last-modified date), removed
#   * archives older than CCW_ARCHIVE_KEEP_DAYS (30; 0 = keep forever): pruned
#   * every session log and housekeep.log: capped at CCW_LOG_MAX_BYTES (256 KB)
#   * disabled.<sid> markers of sessions that no longer exist, stale
#     ping_active/<sid> markers (> 1 h) and leftover temp files: removed
#
# A session's age is the newer of its directory's mtime (every state write is
# a rename into it) and its log's mtime (appends), so one `stat` call covers
# every session. It never touches the current session, config or the global
# markers. The monitor runs it at start-up and hourly; it throttles itself to
# once per CCW_HOUSEKEEP_INTERVAL (6 h).
# ============================================================
set -uo pipefail

HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE=.
# shellcheck source=cc-cache-warming-lib.sh
. "$HERE/cc-cache-warming-lib.sh"
[ -d "$CCW_STATE_DIR" ] || exit 0
ccw_load_config
ccw_int CCW_RETENTION_DAYS 7
ccw_int CCW_ARCHIVE_KEEP_DAYS 30
ccw_int CCW_MAX_SESSIONS 200
ccw_int CCW_HOUSEKEEP_INTERVAL 21600
ARCHIVE_DIR="${CCW_ARCHIVE_DIR:-$CCW_STATE_DIR/archive}"
LOG="$CCW_STATE_DIR/housekeep.log"
STAMP="$CCW_STATE_DIR/housekeep.last"
ccw_clock; now="$CCW__T"

if [ "$CCW_HOUSEKEEP_INTERVAL" -gt 0 ]; then
  ccw_rdf "$STAMP" 0
  case "$REPLY" in ''|*[!0-9]*) REPLY=0 ;; esac
  [ $((now - REPLY)) -lt "$CCW_HOUSEKEEP_INTERVAL" ] && exit 0
fi
printf '%s\n' "$now" > "$STAMP" 2>/dev/null || true

ccw_safe "${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"; cur="$REPLY"
ret_secs=$((CCW_RETENTION_DAYS * 86400))

# ---- 1) process entries; the sessions still owned by a live Claude ----------
live=" "
for f in "$CCW_STATE_DIR"/procs/*; do
  [ -f "$f" ] || continue
  b="${f##*/}"; p="${b%.mon}"
  case "$p" in ''|*[!0-9]*) rm -f "$f"; continue ;; esac
  if ! ccw_alive "$p"; then rm -f "$f"; continue; fi
  [ "$b" = "$p" ] && { ccw_rdf "$f"; live="$live$REPLY "; }
done

# ---- 2) temp files left by an interrupted write (one find) ------------------
find "$CCW_STATE_DIR/sessions" -type f -name '.*.[0-9]*' -mtime +1 -delete 2>/dev/null || true

# ---- 3) sessions: age + log size in one stat, then caps ----------------------
stage_root="$(mktemp -d)"
trap 'rm -rf "$stage_root"' EXIT
# lines "age_epoch log_size session", newest first
sessions="$(
  ccw_stat_lines "$CCW_STATE_DIR"/sessions/*/ "$CCW_STATE_DIR"/sessions/*/log |
  awk '{
      m = $1; z = $2; p = $0; sub(/^[^ ]+ [^ ]+ /, "", p); sub(/\/+$/, "", p)
      islog = (p ~ /\/log$/); if (islog) sub(/\/log$/, "", p)
      n = split(p, a, "/"); s = a[n]
      if (m > age[s]) age[s] = m
      if (islog) size[s] = z
    }
    END { for (s in age) printf "%d %d %s\n", age[s], size[s] + 0, s }' |
  sort -rn
)"
found=0; rank=0; total=0
while read -r m z s; do
  [ -n "$s" ] || continue
  total=$((total + 1)); rank=$((rank + 1))
  if [ "$z" -gt "$CCW_LOG_MAX_BYTES" ]; then ccw_cap_log "$CCW_STATE_DIR/sessions/$s/log" "$CCW_LOG_MAX_BYTES" "$z"; fi
  [ -n "$cur" ] && [ "$s" = "$cur" ] && continue
  case "$live" in *" $s "*) continue ;; esac            # its Claude process is alive
  [ $((now - m)) -lt "$ret_secs" ] && [ "$rank" -le "$CCW_MAX_SESSIONS" ] && continue
  day="$(ccw_fmt "$m" '%Y-%m-%d')"
  mkdir -p "$stage_root/$day" 2>/dev/null || continue
  if cp -Rp "$CCW_STATE_DIR/sessions/$s" "$stage_root/$day/" 2>/dev/null; then
    rm -rf "${CCW_STATE_DIR:?}/sessions/$s"
    found=$((found + 1))
  fi
done <<EOF
$sessions
EOF
if [ "$found" -gt 0 ]; then
  mkdir -p "$ARCHIVE_DIR" 2>/dev/null || true
  for dd in "$stage_root"/*/; do
    [ -d "$dd" ] || continue
    day="${dd%/}"; day="${day##*/}"
    arch="$ARCHIVE_DIR/cc-cache-warming-$day.tar.gz"
    [ -f "$arch" ] && tar -xzf "$arch" -C "$dd" 2>/dev/null
    if tar -czf "$arch" -C "$dd" . 2>/dev/null; then ccw_log_to "$LOG" HOUSEKEEP "archived $day -> $arch"
    else ccw_log_to "$LOG" HOUSEKEEP "ERROR: failed to write $arch"; fi
  done
  ccw_log_to "$LOG" HOUSEKEEP "archived $found of $total session(s) (retention ${CCW_RETENTION_DAYS}d, max $CCW_MAX_SESSIONS)"
fi

# ---- 4) markers that outlived their session ---------------------------------
for f in "$CCW_STATE_DIR"/disabled.*; do
  [ -f "$f" ] || continue
  [ -d "$CCW_STATE_DIR/sessions/${f##*/disabled.}" ] && continue
  [ $((now - $(ccw_mtime "$f"))) -gt "$ret_secs" ] && rm -f "$f"
done
find "$CCW_STATE_DIR/ping_active" -type f -mmin +60 -delete 2>/dev/null || true

# ---- 5) old archives, own log ------------------------------------------------
if [ "$CCW_ARCHIVE_KEEP_DAYS" -gt 0 ] && [ -d "$ARCHIVE_DIR" ]; then
  find "$ARCHIVE_DIR" -maxdepth 1 -type f -name 'cc-cache-warming-*.tar.gz' \
    -mtime +"$CCW_ARCHIVE_KEEP_DAYS" -delete 2>/dev/null || true
fi
ccw_cap_log "$LOG" 65536
exit 0
