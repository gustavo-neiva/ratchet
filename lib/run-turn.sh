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
TURN_EXIT_CODE=0

# bounded_reap PID -> returns within ~10s regardless of child state, stores exit code in TURN_EXIT_CODE
# Polls kill -0 for up to 10s, then detaches if still alive (OS reaps orphan later)
bounded_reap() {
  local pid="$1" reap_attempts=0
  while kill -0 "$pid" 2>/dev/null && [ "$reap_attempts" -lt 10 ]; do
    sleep 1
    reap_attempts=$((reap_attempts + 1))
  done
  # If reaped during polling, collect status; otherwise detach
  TURN_EXIT_CODE=0
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || TURN_EXIT_CODE=$?
  fi
}

run_turn() {
  local model="$1" tag="$2"
  : > "$TURN_OUT"                       # truncate per-turn agent output
  # pi supports --mode json: events STREAM to stdout as they happen (text mode
  # buffers everything until exit -> zero liveness signal). Streaming enables
  # the heartbeat to show real activity and the stall-kill below to work.
  local pi_json=0 mode_args=()
  case "$(basename "$AGENT_CMD")" in pi) pi_json=1; mode_args=(--mode json);; esac
  local session_args=()
  if [ "$RESUME_SESSION" -eq 1 ]; then
    session_args=(--session-id "$SESSION_ID")
    if [ "$SANITIZE_THINKING" -eq 1 ]; then
      local sf; sf=$(ls -t "$(session_dir_for "$REPO_DIR")"/*"_${SESSION_ID}.jsonl" 2>/dev/null | head -n1)
      sanitize_session "$sf"
    fi
  else
    # Ephemeral turns: no session replay (the tracker + md files are the
    # memory) -> leaner, faster, ~90% cheaper per turn. Extensions stay ON:
    # the anthropic OAuth-auth extension must load or plan requests get billed
    # as third-party "extra usage" and hard-error (HTTP 400).
    session_args=(--no-session)
  fi

  local thinking_args=()
  [ -n "$THINKING" ] && thinking_args=(--thinking "$THINKING")

  # advisory only — routing/telemetry, never a gate
  export RATCHET_LOOP=1

  # Extensions ALWAYS load: the Anthropic OAuth-auth extension is itself an
  # extension, so --no-extensions makes plan-auth requests bill as third-party
  # "extra usage" and hard-error (HTTP 400). FANOUT does NOT toggle extensions
  # — it only exports the env signal the AGENTS.md protocol reads to decide
  # whether the agent may spawn subagents (gated there on hard tasks).
  local ext_args=()
  if [ "$tag" = "hard" ] && [ -n "$FANOUT" ] && [ "$FANOUT" != "off" ]; then
    export RATCHET_FANOUT="$FANOUT"
    export RATCHET_SCOUT_MODELS="$LIGHT_MODELS"
  fi

  vlog "invoking: $AGENT_CMD --model $model ${thinking_args[*]} ${session_args[*]} ${ext_args[*]} -p <prompt>"
  # Background the agent so the watchdog can early-kill on token OR hard-kill on
  # deadline. Agents other than pi tolerate the extra pi-style flags (they ignore
  # what they don't understand); for full control pass --agent-cmd.
  "$AGENT_CMD" --model "$model" "${mode_args[@]}" "${thinking_args[@]}" "${session_args[@]}" "${ext_args[@]}" -p "$PROMPT" >"$TURN_OUT" 2>&1 &
  local pid=$!
  local start=$SECONDS reason="" last_hb=0 stream_off=0
  local tok=_has_token; [ "$pi_json" = 1 ] && tok=_has_token_json
  local sz=0 last_sz=0 last_growth=$SECONDS

  while kill -0 "$pid" 2>/dev/null; do
    if $tok "$DONE_TOKEN" "$TURN_OUT" || $tok "$STEP_TOKEN" "$TURN_OUT"; then
      reason="token-seen"; break
    fi
    if (( SECONDS - start >= TURN_TIMEOUT )); then
      reason="deadline-${TURN_TIMEOUT}s"; break
    fi
    # stall-kill: with a streaming agent, output that stops growing for
    # STALL_TIMEOUT means a hung request — kill NOW instead of burning the
    # remaining wall-clock cap. Only engages after the first byte, so fully
    # buffered (non-pi) agents are never falsely killed.
    sz=$(wc -c <"$TURN_OUT" 2>/dev/null); sz=${sz:-0}
    if [ "$sz" -gt "$last_sz" ]; then last_sz=$sz; last_growth=$SECONDS
    elif [ "$sz" -gt 0 ] && (( SECONDS - last_growth >= STALL_TIMEOUT )); then
      reason="stall-${STALL_TIMEOUT}s"; break
    fi
    # live feedback while the agent works
    if [ "$STREAM_AGENT" = 1 ]; then print_new_bytes stream_off; fi
    if [ "$QUIET" = 0 ] && [ "$HEARTBEAT" -gt 0 ] && (( SECONDS - start >= last_hb + HEARTBEAT )); then
      last_hb=$(( SECONDS - start ))
      local elapsed="${last_hb}s"
      local evt=""
      if [ "$pi_json" = 1 ]; then
        evt="$(tail -n1 "$TURN_OUT" 2>/dev/null | sed -n 's/.*"type":"\([a-z_]*\)".*/\1/p')"
      fi
      local activity; activity="$(render_activity "$evt")"
      if ansi_ok; then
        # TTY: in-place update, no newline
        printf '\r\033[K  … %s (%s)' "$activity" "$elapsed" >&2
      else
        # non-TTY (log/pipe): keep newline behavior
        term_only "  ... working ($elapsed, model=$model) | $activity"
      fi
    fi
    sleep "$POLL_INTERVAL"
  done

  # Print trailing newline after in-place updates so next emit starts fresh
  if [ "$QUIET" = 0 ] && [ "$HEARTBEAT" -gt 0 ] && ansi_ok; then
    printf '\n' >&2
  fi

  # If still alive (token seen but agent hanging, OR deadline): terminate, then SIGKILL.
  if kill -0 "$pid" 2>/dev/null; then
    [ -n "$reason" ] && emit "terminating agent ($reason) — print mode can hang after completion"
    kill "$pid" 2>/dev/null
    pkill -P "$pid" 2>/dev/null        # reap child workers
    sleep 2
    kill -9 "$pid" 2>/dev/null
    pkill -9 -P "$pid" 2>/dev/null
  fi
  bounded_reap "$pid"  # bounded: returns within ~10s regardless of child state

  if [ "$STREAM_AGENT" = 1 ]; then print_new_bytes stream_off; fi

  # Classify by content (exit code is unreliable in print mode). A deadline kill
  # with no token/error is `timeout` (still working past the cap), distinct from
  # `transient` (a network blip / empty reply) — keeps stats honest.
  local deadline=0
  case "$reason" in deadline-*|stall-*) deadline=1;; esac
  TURN_STATUS="$(classify_turn "$TURN_OUT" "$STEP_TOKEN" "$DONE_TOKEN" "$deadline" "$pi_json")"
  vlog "turn classified: $TURN_STATUS"
}

# run_review_turn BASE_SHA MILESTONE_NAME CYCLE_COUNT -> echoes "pass"|"fail"|"error"
# Runs ONE read-only review turn with swapped tokens (STEP_TOKEN=REVIEW_PASS, DONE_TOKEN=REVIEW_FAIL)
# so the existing classify_turn logic works unmodified: class step => pass, class done => fail.
# Never strikes/benches the review model; errors return "error" to trigger skip policy.
run_review_turn() {
  local base_sha="$1" mname="$2" cycle="$3"
  # Build review prompt: template + diff
  local review_tpl="$RATCHET_ROOT/templates/REVIEW.prompt.md"
  local diff_content
  diff_content=$(git diff "${base_sha}..HEAD" 2>/dev/null || echo "<diff unavailable>")
  local review_prompt
  review_prompt=$(cat "$review_tpl")
  review_prompt="$review_prompt

\`\`\`diff
$diff_content
\`\`\`

**Milestone**: $mname (review cycle $((cycle + 1)))
**Tracker**: $TRACKER_FILE
"
  
  # Swap tokens for this turn only
  local saved_step="$STEP_TOKEN" saved_done="$DONE_TOKEN" saved_prompt="$PROMPT"
  STEP_TOKEN="REVIEW_PASS"
  DONE_TOKEN="REVIEW_FAIL"
  PROMPT="$review_prompt"
  
  # Get review tier model (never strike/bench it)
  local review_chain; review_chain=$(chain_for_tier review)
  local review_model; review_model=$(echo "$review_chain" | awk -F, '{print $1}')
  [ -n "$review_model" ] || review_model="${models_arr[0]:-}"
  [ -n "$review_model" ] || { echo "error"; return; }
  
  # Run turn (reuses run_turn, which sets TURN_STATUS)
  run_turn "$review_model" "normal"
  
  # Restore tokens and prompt
  STEP_TOKEN="$saved_step"
  DONE_TOKEN="$saved_done"
  PROMPT="$saved_prompt"
  
  # Map TURN_STATUS to review verdict
  case "$TURN_STATUS" in
    step) echo "pass" ;;  # REVIEW_PASS token seen
    done) echo "fail" ;;  # REVIEW_FAIL token seen
    *) echo "error" ;;    # timeout, exhausted, hard, transient -> all "error"
  esac
}
