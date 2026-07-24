# =============================================================================
#  run-turn.sh — run ONE agent turn under a watchdog, then classify it
# =============================================================================
#  run_turn MODEL -> sets global TURN_STATUS (done|step|exhausted|hard|timeout|
#  transient). Spawns the agent in the background so a pure-bash watchdog can
#  early-break the moment the completion token appears, and hard-kill on the
#  wall-clock deadline. Print mode can hang *after* success (the token is on
#  stdout but the process never exits), so we never block on the agent exiting.
#
#  The watchdog is bash 3.2-safe: `kill -0` to poll liveness, `$SECONDS` for
#  timing, no external `timeout` binary required.
# =============================================================================

TURN_STATUS=""

run_turn() {
  local model="$1"
  : > "$TURN_OUT"                       # truncate per-turn agent output
  local session_args=()
  if [ "$RESUME_SESSION" -eq 1 ]; then
    session_args=(--session-id "$SESSION_ID")
    if [ "$SANITIZE_THINKING" -eq 1 ]; then
      local sf; sf=$(ls -t "$(session_dir_for "$REPO_DIR")"/*"_${SESSION_ID}.jsonl" 2>/dev/null | head -n1)
      sanitize_session "$sf"
    fi
  else
    # Ephemeral turns: no session replay, no extension discovery (the tracker +
    # md files are the memory) -> leaner, faster, ~90% cheaper per turn.
    session_args=(--no-session --no-extensions)
  fi

  local thinking_args=()
  [ -n "$THINKING" ] && thinking_args=(--thinking "$THINKING")

  vlog "invoking: $AGENT_CMD --model $model ${thinking_args[*]} ${session_args[*]} -p <prompt>"
  # Background the agent so the watchdog can early-kill on token OR hard-kill on
  # deadline. Agents other than pi tolerate the extra pi-style flags (they ignore
  # what they don't understand); for full control pass --agent-cmd.
  "$AGENT_CMD" --model "$model" "${thinking_args[@]}" "${session_args[@]}" -p "$PROMPT" >"$TURN_OUT" 2>&1 &
  local pid=$!
  local start=$SECONDS reason="" last_hb=0 stream_off=0

  while kill -0 "$pid" 2>/dev/null; do
    if _has_token "$DONE_TOKEN" "$TURN_OUT" || _has_token "$STEP_TOKEN" "$TURN_OUT"; then
      reason="token-seen"; break
    fi
    if (( SECONDS - start >= TURN_TIMEOUT )); then
      reason="deadline-${TURN_TIMEOUT}s"; break
    fi
    # live feedback while the agent works
    if [ "$STREAM_AGENT" = 1 ]; then print_new_bytes stream_off; fi
    if [ "$QUIET" = 0 ] && [ "$HEARTBEAT" -gt 0 ] && (( SECONDS - start >= last_hb + HEARTBEAT )); then
      last_hb=$(( SECONDS - start ))
      # show what the agent is actually doing: last non-empty output line (ANSI/CR-stripped)
      local esc act; esc=$(printf '\033')
      act=$(tail -c 2000 "$TURN_OUT" 2>/dev/null | tr -d '\r' | sed "s/${esc}\[[0-9;]*[A-Za-z]//g" | grep -v '^[[:space:]]*$' | tail -n1 | cut -c1-80)
      term_only "  ... working (${last_hb}s, model=$model)${act:+ | $act}"
    fi
    sleep 3
  done

  # If still alive (token seen but agent hanging, OR deadline): terminate, then SIGKILL.
  if kill -0 "$pid" 2>/dev/null; then
    [ -n "$reason" ] && emit "terminating agent ($reason) — print mode can hang after completion"
    kill "$pid" 2>/dev/null
    pkill -P "$pid" 2>/dev/null        # reap child workers
    sleep 2
    kill -9 "$pid" 2>/dev/null
    pkill -9 -P "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null              # reap; ignore exit code (we classify by content)

  if [ "$STREAM_AGENT" = 1 ]; then print_new_bytes stream_off; fi

  # Classify by content (exit code is unreliable in print mode). A deadline kill
  # with no token/error is `timeout` (still working past the cap), distinct from
  # `transient` (a network blip / empty reply) — keeps stats honest.
  local deadline=0
  [ "$reason" = "deadline-${TURN_TIMEOUT}s" ] && deadline=1
  TURN_STATUS="$(classify_turn "$TURN_OUT" "$STEP_TOKEN" "$DONE_TOKEN" "$deadline")"
  vlog "turn classified: $TURN_STATUS"
}
