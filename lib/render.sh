#!/usr/bin/env bash
# =============================================================================
#  render.sh — pure terminal rendering (progress bars, status blocks)
# =============================================================================
#  All functions are PURE: inputs via args/stdin, output via stdout, zero
#  globals read, zero file I/O. Testable with no agent and no live loop.
#
#  Bash 3.2 compatible (macOS default): no associative arrays, no ${var,,}.
# =============================================================================

# render_bar PCT WIDTH -> "▓▓▓░░░"
# Clamps PCT to 0-100, integer math only.
render_bar() {
  local pct=$1 w=$2 fill i out=''
  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100
  fill=$(( pct * w / 100 ))
  for i in $(seq 1 "$w"); do
    [ "$i" -le "$fill" ] && out="${out}▓" || out="${out}░"
  done
  printf '%s' "$out"
}

# ansi_ok -> returns 0 when stdout is a TTY AND NO_COLOR is unset
# Callers gate color emit on this.
ansi_ok() {
  [ -t 1 ] && [ -z "${NO_COLOR:-}" ]
}

# color CODE TEXT... -> wrap TEXT in SGR CODE + reset when ansi_ok, else passthrough.
# Self-resetting per line (pi TUI rule: styles never carry across lines).
# 8-color ANSI only, for portability. c_* are thin named aliases.
color() {
  local code=$1; shift
  if ansi_ok; then printf '\033[%sm%s\033[0m' "$code" "$*"
  else printf '%s' "$*"; fi
}
c_bold()   { color '1'  "$*"; }
c_dim()    { color '2'  "$*"; }
c_red()    { color '31' "$*"; }
c_green()  { color '32' "$*"; }
c_blue()   { color '34' "$*"; }
c_purple() { color '35' "$*"; }

# render_activity EVENTTYPE -> human verb for pi json stream event
# Maps machine event types to readable activity verbs.
render_activity() {
  case "$1" in
    turn_start) printf 'thinking';;
    tool_execution_update) printf 'working';;
    tool_call|toolCall) printf 'running a tool';;
    *) printf '%s' "${1:-working}";;
  esac
}

# render_summary NLINES -> reads agent output on stdin, keeps last meaningful block
# Drops blank lines and tool chatter, keeps the last NLINES (default 4).
render_summary() {
  local nlines=${1:-4}
  grep -v '^[[:space:]]*$' | tail -n "$nlines"
}

# render_status_block DONE TOTAL MNAME MDONE MTOTAL TURN TIER MODEL TASKID TASKTEXT
# -> multi-line PM header: Step D/T [bar PCT%] · Mname (mdone/mtotal)
#                          ▶ TASKID (tier) TASKTEXT   tier · model
render_status_block() {
  local done=$1 total=$2 mname=$3 mdone=$4 mtotal=$5
  local turn=$6 tier=$7 model=$8 taskid=$9
  shift 9; local tasktext="$*"
  
  local pct=0
  [ "$total" -gt 0 ] && pct=$(( done * 100 / total ))
  
  local bar; bar="$(render_bar "$pct" 12)"
  
  # Line 1: Step D/T [bar PCT%] · Mname (mdone/mtotal)
  printf 'Step %d/%d  [%s %d%%]' "$done" "$total" "$bar" "$pct"
  if [ -n "$mname" ]; then
    printf '   %s  (%d/%d)' "$mname" "$mdone" "$mtotal"
  fi
  printf '\n'
  
  # Line 2: ▶ TASKID (tier) TASKTEXT   tier · model
  printf '  ▶ %s  %s   %s · %s\n' "$taskid" "$tasktext" "$tier" "$model"
}

# fmt_dur SECS -> human-readable duration (42s, 57m, 1h20m)
fmt_dur() {
  local secs=$1 h m
  if [ "$secs" -lt 60 ]; then
    printf '%ds' "$secs"
  elif [ "$secs" -lt 3600 ]; then
    printf '%dm' "$((secs / 60))"
  else
    h=$((secs / 3600))
    m=$(( (secs % 3600) / 60 ))
    printf '%dh%dm' "$h" "$m"
  fi
}

# render_eta REMAINING AVGSECS -> "~19 turns / ~57m left" or "ETA unknown"
render_eta() {
  local remaining=$1 avg=$2
  if [ "$avg" -eq 0 ]; then
    printf 'ETA unknown'
  else
    local total_secs=$((remaining * avg))
    printf '~%d turns / ~%s left' "$remaining" "$(fmt_dur "$total_secs")"
  fi
}

# render_timing TURN ELAPSED AVG REMAINING -> "⏱ turn N · <dur>   avg <dur>   <eta>"
render_timing() {
  local turn=$1 elapsed=$2 avg=$3 remaining=$4
  printf '  ⏱ turn %d · %s   avg %s   %s' \
    "$turn" "$(fmt_dur "$elapsed")" "$(fmt_dur "$avg")" "$(render_eta "$remaining" "$avg")"
}
