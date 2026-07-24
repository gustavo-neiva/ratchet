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
