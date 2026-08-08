# =============================================================================
#  commands.sh — ratchet init | new | doctor
# =============================================================================
#  The repo-contract tooling (v2 design). These turn ANY repo into a
#  loop-runnable one and preflight it so a mis-onboarded repo fails in <1s
#  instead of burning quota at turn 3. The engine stays task-agnostic: these
#  only WRITE/VALIDATE the contract files; they never author business logic.
#
#  RATCHET_ROOT (the repo root of ratchet itself) must be exported by bin/ratchet
#  before these run, so template files can be located.
# =============================================================================

# detect_verify_cmd DIR -> proposes a green gate from the stack. None => a stub.
detect_verify_cmd() {
  local d="$1"
  if [ -f "$d/package.json" ]; then
    if grep -q '"test"' "$d/package.json" 2>/dev/null; then printf 'npm test'
    else printf 'node -e "console.log(1)"'; fi
  elif [ -f "$d/mix.exs" ]; then printf 'mix test'
  elif [ -f "$d/Cargo.toml" ]; then printf 'cargo test'
  elif [ -f "$d/pyproject.toml" ] || [ -f "$d/pytest.ini" ]; then printf 'pytest -q'
  elif [ -f "$d/Gemfile" ]; then printf 'bundle exec rspec'
  elif [ -f "$d/go.mod" ]; then printf 'go test ./...'
  else printf ''; fi
}

# expected_protocol_block TRACKER VERIFY STEP DONE -> render the protocol block
# with live conf values. Used by build_default_prompt for per-turn injection.
expected_protocol_block() {
  local tr="$1" vc="$2" st="$3" dt="$4" tpl
  tpl="$RATCHET_ROOT/templates/AGENTS.protocol.md"
  [ -f "$tpl" ] || die "template missing: $tpl"
  sed -e "s|{{TRACKER_FILE}}|$tr|g" -e "s|{{VERIFY_CMD}}|$vc|g" \
      -e "s|{{STEP_TOKEN}}|$st|g" -e "s|{{DONE_TOKEN}}|$dt|g" "$tpl"
}



# ----------------------------- ratchet init ----------------------------------
cmd_init() {
  local dir="$1"
  [ -d "$dir" ] || die "not a directory: $dir"
  local conf="$dir/.ratchet.conf" trackers seed_vc
  emit "ratchet init: $dir"

  # 1) .ratchet.conf — copy the example then localize the detected verify cmd.
  if [ ! -f "$conf" ]; then
    cp "$RATCHET_ROOT/templates/ratchet.conf.example" "$conf"
    seed_vc="$(detect_verify_cmd "$dir")"
    if [ -n "$seed_vc" ]; then
      emit "  detected stack -> VERIFY_CMD='$seed_vc'"
      sed -i.tmp -e "s|^VERIFY_CMD=.*|VERIFY_CMD=$seed_vc|" "$conf" && rm -f "$conf.tmp"
    else
      emit "  no stack detected -> VERIFY_CMD left empty (set it; no-gate is loud by design)"
    fi
  else
    emit "  .ratchet.conf exists — leaving it (re-stamp only)"
  fi

  # 2) parse it so we know the real tracker/tokens/verify.
  parse_repo_conf "$conf" || { emit "  WARNING: .ratchet.conf has errors:"; printf '%b\n' "$RATCHET_CONF_ERRORS"; }
  local tr="${TRACKER_FILE:-$(detect_tracker_file "$dir")}"
  [ -n "$tr" ] || tr="PLAN.md"
  local vc="${VERIFY_CMD:-$(detect_verify_cmd "$dir")}"

  # 3) tracker — adopt an existing one, else seed from the template.
  if [ ! -f "$dir/$tr" ]; then
    cp "$RATCHET_ROOT/templates/PLAN.seed.md" "$dir/$tr"
    emit "  seeded $tr (edit it, or run 'ratchet new' to draft from an idea)"
  fi

  # 4) LEARNINGS.md (advisory memory) if absent.
  [ -f "$dir/LEARNINGS.md" ] || cp "$RATCHET_ROOT/templates/LEARNINGS.md" "$dir/LEARNINGS.md"

  # 5) AGENTS.md migration: strip legacy loop-protocol block, seed human template if needed.
  local agents="$dir/AGENTS.md" migrated=0
  if [ -f "$agents" ] && grep -q 'ratchet-protocol:.*:begin' "$agents"; then
    local tmp; tmp=$(mktemp)
    awk '
      /ratchet-protocol:.*:begin/ {skip=1; next}
      /ratchet-protocol:.*:end/   {skip=0; next}
      !skip {print}
    ' "$agents" > "$tmp" && mv "$tmp" "$agents"
    emit "  migrated legacy loop block out of AGENTS.md"
    migrated=1
  fi
  # Seed if absent or empty after migration
  if [ ! -f "$agents" ] || [ ! -s "$agents" ] || ! grep -q '[^[:space:]]' "$agents" 2>/dev/null; then
    cp "$RATCHET_ROOT/templates/AGENTS.human.md" "$agents"
    if [ "$migrated" -eq 1 ]; then
      emit "  seeded human AGENTS.md (no content after marker strip)"
    else
      emit "  seeded human AGENTS.md"
    fi
  fi

  # 6) .gitignore audit — keep loop junk AND the human-owned conf out of commits.
  # .ratchet.conf MUST be ignored: the commit gate's `git add -A` would otherwise
  # stage this untracked conf, and the contract-tamper guard then blocks EVERY
  # turn (it treats any staged .ratchet.conf as the agent editing its own rules).
  [ -f "$dir/.gitignore" ] || : > "$dir/.gitignore"
  local line
  for line in '.ratchet/' '.ratchet.conf'; do
    grep -qxF "$line" "$dir/.gitignore" || printf '%s\n' "$line" >> "$dir/.gitignore"
  done

  # 7) record the conf hash so a later change is surfaced for human ack.
  mkdir -p "$dir/.ratchet"; conf_hash "$conf" > "$dir/.ratchet/conf.hash"

  emit "done. Next: review $tr, then 'ratchet doctor $dir' and 'ratchet run $dir'."
}

# ----------------------------- ratchet new -----------------------------------
# Scaffold a fresh repo from an idea, draft PLAN.md, then STOP for the mandatory
# human plan review (the one checkpoint the loop never skips).
#
# emit_plan_review_stop DIR TRACKER LINE... -> the mandatory human checkpoint
# emitted after a plan turn (shared by `ratchet new` and `ratchet plan`). The
# loop NEVER auto-runs after a plan turn — review comes first.
emit_plan_review_stop() {
  local dir="$1" tracker="$2"; shift 2
  emit ""
  emit "STOP FOR PLAN REVIEW (mandatory human checkpoint):"
  local _line
  for _line in "$@"; do emit "$_line"; done
  emit "  (ratchet never auto-runs the loop after a plan — you review first.)"
}

cmd_new() {
  local idea="$1" dir="$2"
  [ -n "$idea" ] || die "usage: ratchet new \"<idea>\" [DIR]"
  local name; name="$(printf '%s' "$idea" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9-' | sed 's/^-*//; s/-*$//; s/-\{2,\}/-/g')"
  [ -n "$name" ] || name="new-repo"
  [ -n "$dir" ] || dir="$PWD/$name"
  emit "ratchet new: '$idea' -> $dir"
  mkdir -p "$dir" && cd "$dir" || die "cannot create $dir"
  git init -q

  # BRIEF.md (the goal/start/done/non-goals the human can refine).
  cat > BRIEF.md <<BRIEF
# Brief: $idea

## What
$idea

## Definition of done
- _(replace: what must be true for this to ship?)_

## Non-goals
- _(explicitly out of scope)_

## Constraints / stack
- _(language, runtime, target, anything load-bearing)_
BRIEF

  emit "  wrote BRIEF.md"
  # Reuse init to stamp the contract files, then draft a PLAN.md.
  cmd_init "$dir"

  # Draft PLAN.md from the brief (this is the one "expensive" strong-model plan
  # turn the public repo ships a minimal prompt for; it does NOT depend on any
  # internal interview skill). Then STOP for human review.
  cat > "$dir/PLAN.md" <<PLAN
# Plan — $idea

> Drafted from BRIEF.md. **Review this before running the loop** — this is the
> one mandatory human checkpoint. Edit freely.

## Milestone 0 — Walking skeleton + green gate
- [ ] T0.1 (trivial) scaffold project from the constraints in BRIEF.md
- [ ] T0.2 (normal) verify command is green (one passing walking-skeleton test)
- [ ] T0.3 (normal) thinnest end-to-end slice

## Milestone 1 — _(flesh out from the brief)_
- [ ] T1.1 (normal) _(first real task toward the definition of done)_

## Non-goals
- _(copy from BRIEF.md)_
PLAN
  emit "  drafted PLAN.md"

  git add -A && git commit -q -m "scaffold: $idea (ratchet new)" && emit "  initial commit"
  emit_plan_review_stop "$dir" "$tr" \
    "  1. Open $dir/PLAN.md and $dir/BRIEF.md." \
    "  2. Edit the plan until Milestone 0 + the feature milestones are right." \
    "  3. Commit your edits, then:  ratchet doctor $dir && ratchet run $dir"
}

# ----------------------------- ratchet plan ----------------------------------
# ONE plan-drafting turn on the PLAN tier, then STOP for human review. Reads the
# repo + tracker, drafts/refreshes open tasks (Milestone-0 walking skeleton, a
# tag on every task), commits ONLY the tracker + LEARNINGS.md (never code), and
# never auto-runs the loop. Reuses run_turn + the shared plan-review stop message
# used by `ratchet new` (the smallest shared refactor — one extracted helper).
cmd_plan() {
  local dir="$1"
  emit "ratchet plan: $dir (PLAN tier — ONE turn, then STOP for review)"

  plan_turn "$dir"

  emit_plan_review_stop "$dir" "$TRACKER_FILE" \
    "  HUMAN: review $dir/$TRACKER_FILE before running the loop." \
    "  Edit the plan (Milestone 0 + tags), then: ratchet doctor $dir && ratchet run $dir"
}

# plan_turn DIR -> run ONE plan turn (core shared by cmd_plan and auto-plan in main).
# Sets up plan tier, runs the turn, commits tracker + LEARNINGS.md only.
plan_turn() {
  local dir="$1"
  # finalize tracker (auto-detect if conf left it empty)
  TRACKER_FILE="${TRACKER_FILE:-$(detect_tracker_file "$dir")}"
  [ -n "$TRACKER_FILE" ] || TRACKER_FILE="PLAN.md"
  [ -f "$dir/$TRACKER_FILE" ] || die "no tracker '$TRACKER_FILE' in $dir (run 'ratchet init $dir' first)."

  # PLAN tier chain + thinking (fallback to MODELS/THINKING when unset).
  init_models "$(chain_for_tier plan)"
  local model; model="${models_arr[0]:-}"
  [ -n "$model" ] || die "no model for PLAN tier (set PLAN_MODELS / MODELS / -m)."
  local tier_think; tier_think=$(thinking_for_tier plan)
  THINKING="$tier_think"

  PROMPT="$(build_plan_prompt)"

  cd "$dir" || die "cannot cd into $dir"

  emit "plan turn 1 | tier=plan | model=$model | thinking=$tier_think"
  local turn_start=$SECONDS
  run_turn "$model" "normal"
  emit "plan turn 1 end | class=$TURN_STATUS | took=$((SECONDS-turn_start))s"
  show_excerpt

  plan_commit "$dir"
}

# plan_commit DIR -> commit ONLY the tracker + LEARNINGS.md from a plan turn.
# A plan turn never lands code changes: no `git add -A`, no verify gate (the tree
# may legitimately be RED while you plan), no contract-tamper guard (plan never
# stages .ratchet.conf/AGENTS.md). One markdown-only commit, or nothing.
plan_commit() {
  local dir="$1"
  [ "$COMMIT_EACH_TURN" = 1 ] || return 0
  [ -d "$dir/.git" ] || { vlog "plan: not a git repo; skip commit"; return 0; }
  git add -- "$TRACKER_FILE" LEARNINGS.md 2>/dev/null || true
  if git diff --cached --quiet 2>/dev/null; then
    emit "  nothing plan-staged to commit (idempotent plan turn)."
    return 0
  fi
  if git commit -q -m "plan(ratchet): refresh $TRACKER_FILE" 2>>"$LOOP_LOG"; then
    emit "  plan-committed: $TRACKER_FILE (+ LEARNINGS.md if changed)"
  else
    emit "  plan git commit failed (see $LOOP_LOG) — continuing."
  fi
}

# ----------------------------- ratchet status --------------------------------
# One-shot snapshot of a running or finished loop (complement to --watch).
# Reads loop.log + tracker + last_turn.out, checks loop.pid for liveness.
cmd_status() {
  local log="$LOOP_LOG" tracker="$REPO_DIR/$TRACKER_FILE" turn_out="$TURN_OUT" pid_file="$LOG_DIR/loop.pid"
  
  if [ ! -f "$log" ]; then
    echo "status: no loop.log found at $log (nothing run here yet?)"
    return 1
  fi
  
  # Parse loop.log for turn info (last turn line)
  local turn_line turn_num tier model thinking task
  turn_line=$(grep -E '^\[[^]]+\] turn [0-9]+ \| tier=' "$log" 2>/dev/null | tail -n1)
  if [ -n "$turn_line" ]; then
    turn_num=$(echo "$turn_line" | sed -nE 's/.*turn ([0-9]+) .*/\1/p')
    tier=$(echo "$turn_line" | sed -nE 's/.*tier=([^|[:space:]]+).*/\1/p')
    model=$(echo "$turn_line" | sed -nE 's/.*model=([^|[:space:]]+).*/\1/p')
    thinking=$(echo "$turn_line" | sed -nE 's/.*thinking=([^|[:space:]]+).*/\1/p')
    task=$(echo "$turn_line" | sed -nE 's/.*task=([^$]+)$/\1/p' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  else
    # Fallback: old format without tier
    turn_line=$(grep -E '^\[[^]]+\] --- turn [0-9]+ \| model=' "$log" 2>/dev/null | tail -n1)
    if [ -n "$turn_line" ]; then
      turn_num=$(echo "$turn_line" | sed -nE 's/.*turn ([0-9]+) .*/\1/p')
      model=$(echo "$turn_line" | sed -nE 's/.*model=([^-[:space:]]+).*/\1/p')
      tier="—"; thinking="—"; task="—"
    else
      turn_num="—"; tier="—"; model="—"; thinking="—"; task="—"
    fi
  fi
  
  # Parse for elapsed/took time
  local elapsed_took took_s
  local end_line
  end_line=$(grep -E '^\[[^]]+\] turn [0-9]+ end \| class=' "$log" 2>/dev/null | tail -n1)
  if [ -n "$end_line" ]; then
    # Check if this is the same turn (finished)
    local end_turn; end_turn=$(echo "$end_line" | sed -nE 's/.*turn ([0-9]+) end.*/\1/p')
    if [ "$end_turn" = "$turn_num" ]; then
      took_s=$(echo "$end_line" | sed -nE 's/.*took=([0-9]+)s.*/\1/p')
      [ -n "$took_s" ] && elapsed_took="took ${took_s}s" || elapsed_took="finished"
    else
      # Turn started but not finished → running
      elapsed_took="running"
    fi
  else
    elapsed_took="running"
  fi
  
  # Tasks done/total from tracker
  local done_n open_n total_n
  if [ -f "$tracker" ]; then
    done_n=$(grep -cE '^[[:space:]]*-?[[:space:]]*\[x\]' "$tracker" 2>/dev/null || echo 0)
    open_n=$(grep -cE '^[[:space:]]*-?[[:space:]]*\[( |IN PROGRESS)\]' "$tracker" 2>/dev/null || echo 0)
    total_n=$((done_n + open_n))
  else
    done_n="?"; open_n="?"; total_n="?"
  fi
  
  # Loop liveness from PID file
  local loop_alive_dot loop_status
  if [ -f "$pid_file" ]; then
    local pid; pid=$(cat "$pid_file" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      loop_status="running (pid $pid)"
      ansi_ok && loop_alive_dot="●" || loop_alive_dot="*"
    else
      loop_status="not running (stale pid $pid)"
      loop_alive_dot="○"
    fi
  else
    loop_status="not running"
    loop_alive_dot="○"
  fi
  
  # Compute progress percentage
  local pct=0
  [ "$total_n" != "?" ] && [ "$total_n" -gt 0 ] && pct=$(( done_n * 100 / total_n ))
  
  # Get milestone info
  local cur_milestone mname="" midx="" mcount="" mdone="" mtotal=""
  if [ -f "$tracker" ]; then
    cur_milestone=$(tracker_current_milestone)
    if [ -n "$cur_milestone" ]; then
      mname=$(echo "$cur_milestone" | cut -f1)
      midx=$(echo "$cur_milestone" | cut -f2)
      mcount=$(echo "$cur_milestone" | cut -f3)
      mdone=$(echo "$cur_milestone" | cut -f4)
      mtotal=$(echo "$cur_milestone" | cut -f5)
    fi
  fi
  
  # Get avg turn time and compute ETA
  local avg_s remaining_n eta_str
  avg_s=$(avg_turn_secs "$log")
  remaining_n="$open_n"
  [ "$remaining_n" = "?" ] && remaining_n=0
  eta_str=$(render_eta "$remaining_n" "$avg_s")
  
  # Header: repo + loop-alive dot
  local repo_name; repo_name=$(basename "$REPO_DIR")
  ansi_ok && printf '\033[1m%s\033[0m %s\n' "$repo_name" "$loop_alive_dot" || printf '%s %s\n' "$repo_name" "$loop_alive_dot"
  
  # Progress bar with Step D/T (PCT%)
  local bar; bar=$(render_bar "$pct" 12)
  printf 'Step %s/%s  [%s %d%%]\n' "$done_n" "$total_n" "$bar" "$pct"
  
  # Milestone tree with mini-bars
  if [ -f "$tracker" ]; then
    local ms_line ms_name ms_done ms_total ms_pct ms_bar marker
    while IFS=$'\t' read -r ms_name ms_done ms_total; do
      ms_pct=0
      [ "$ms_total" -gt 0 ] && ms_pct=$(( ms_done * 100 / ms_total ))
      ms_bar=$(render_bar "$ms_pct" 6)
      # Mark current milestone with ▶
      if [ "$ms_name" = "$mname" ]; then
        marker="▶"
      else
        marker=" "
      fi
      printf '%s %s  [%s]  %d/%d\n' "$marker" "$ms_name" "$ms_bar" "$ms_done" "$ms_total"
    done < <(tracker_milestones)
  fi
  
  # Current task + tier/model
  if [ "$task" != "—" ]; then
    printf '\nCurrent: %s\n' "$task"
  fi
  printf 'Tier/Model: %s / %s (thinking=%s)\n' "$tier" "$model" "$thinking"
  
  # Turn status and ETA
  if [ "$turn_num" != "—" ]; then
    printf 'Turn %s: %s\n' "$turn_num" "$elapsed_took"
  fi
  printf 'ETA: %s\n' "$eta_str"
  
  # "doing now" line from last_turn.out
  if [ -f "$turn_out" ] && [ -s "$turn_out" ]; then
    local doing_now
    # Handle JSON streaming format or plain text
    if head -c 32 "$turn_out" 2>/dev/null | grep -q '^{"type":"session"'; then
      # JSON streaming: extract text_delta fragments
      local joined
      joined=$(grep '"type":"text_delta"' "$turn_out" 2>/dev/null \
        | sed -e 's/.*"delta":"//' -e 's/","partial.*//' \
        | awk '{printf "%s", $0}' \
        | sed -e 's/\\"/"/g')
      doing_now=$(printf '%b\n' "$joined" | render_summary 1)
    else
      # Plain text
      doing_now=$(render_summary 1 <"$turn_out" 2>/dev/null)
    fi
    if [ -n "$doing_now" ]; then
      printf '\nDoing: %s\n' "$doing_now"
    fi
  fi
  
  printf '\nLoop: %s\n' "$loop_status"
  printf 'Log: %s\n' "$log"
}

# ----------------------------- ratchet doctor --------------------------------
# Fast static checks (<1s, auto before every run) + optional deep checks.
cmd_doctor() {
  local dir="$1" full="${2:-0}" problems=0 conf
  conf="$dir/.ratchet.conf"
  pr_ok() { printf '  ok   %s\n' "$1"; }
  pr_fail() { printf '  FAIL %s\n' "$1"; problems=$((problems+1)); }

  printf 'doctor: %s\n' "$dir"

  # Check for mid-operation state
  if [ -d "$dir/.git/rebase-merge" ]; then
    pr_fail "repo is mid-rebase (interactive) — use 'git rebase --quit' to keep commits or 'git rebase --abort' to discard"
  elif [ -d "$dir/.git/rebase-apply" ]; then
    pr_fail "repo is mid-rebase (apply) — use 'git rebase --quit' or 'git am --abort'"
  elif [ -f "$dir/.git/MERGE_HEAD" ]; then
    pr_fail "repo is mid-merge — resolve conflicts and commit, or 'git merge --abort'"
  elif [ -f "$dir/.git/CHERRY_PICK_HEAD" ]; then
    pr_fail "repo is mid-cherry-pick — resolve and commit, or 'git cherry-pick --abort'"
  fi

  # git repo
  [ -d "$dir/.git" ] && pr_ok "git repo" || pr_fail "not a git repo"

  # agent command on PATH (or an absolute path / pi)
  if command -v "$AGENT_CMD" >/dev/null 2>&1 || [ -x "$AGENT_CMD" ]; then
    pr_ok "agent command '$AGENT_CMD' on PATH"
  else
    pr_fail "agent command '$AGENT_CMD' not found (set AGENT_CMD / install it)"
  fi

  # conf parses + protocol supported
  if [ -f "$conf" ]; then
    if parse_repo_conf "$conf"; then
      pr_ok ".ratchet.conf parses (allowlisted keys)"
    else
      pr_fail ".ratchet.conf has errors:"; printf '%b\n' "$RATCHET_CONF_ERRORS" | sed 's/^/         /'
    fi
    case "${RATCHET_PROTOCOL:-1}" in
      1) pr_ok "RATCHET_PROTOCOL=$RATCHET_PROTOCOL_VERSION supported" ;;
      *) pr_fail "RATCHET_PROTOCOL=$RATCHET_PROTOCOL unsupported (want $RATCHET_PROTOCOL_VERSION)" ;;
    esac
    # conf hash (surface a changed contract for human acknowledgment)
    if [ -f "$dir/.ratchet/conf.hash" ]; then
      cur="$(conf_hash "$conf")"; prev="$(cat "$dir/.ratchet/conf.hash")"
      if [ "$cur" = "$prev" ]; then pr_ok ".ratchet.conf unchanged since onboarding"
      else pr_fail ".ratchet.conf CHANGED since onboarding — review & re-acknowledge (run: ratchet init $dir)"; fi
    fi
  else
    pr_fail "no .ratchet.conf (run: ratchet init $dir)"
  fi

  # protocol delivery mode
  local agents="$dir/AGENTS.md"
  if [ -f "$agents" ] && grep -q 'ratchet-protocol:.*:begin' "$agents"; then
    pr_fail "AGENTS.md carries a legacy loop-in-file protocol block; run \`ratchet init $dir\` to migrate (loop protocol now travels in the harness prompt)"
  else
    pr_ok "protocol delivery: harness-prompt (loop briefs its own turns)"
  fi

  # tracker exists, parses, has an open task
  local tr="${TRACKER_FILE:-$(detect_tracker_file "$dir")}"
  if [ -n "$tr" ] && [ -f "$dir/$tr" ]; then
    TRACKER_FILE="$tr"; REPO_DIR="$dir"
    if tracker_has_open; then
      pr_ok "tracker '$tr' has an open task"
      # verify task id resolves
      local _tid; _tid=$(tracker_next_id_and_text | awk '{print $1}')
      [ "$_tid" = "?" ] && pr_fail "task id unresolved on first open task; parser degraded to '?' (see tracker grammar)"
    elif [ "$(tracker_count_done)" -gt 0 ]; then
      pr_ok "tracker '$tr' fully done (all [x]) — loop final-commits + stops"
    else
      pr_fail "tracker '$tr' has NO tasks (empty/unparsed) — add work"
    fi
  else
    pr_fail "no tracker found (PLAN.md/TODO.md/TASKS.md) — run: ratchet init $dir"
  fi

  # VERIFY_CMD set (no-gate is loud, never silent)
  if [ -n "$VERIFY_CMD" ]; then
    pr_ok "VERIFY_CMD is set: '$VERIFY_CMD'"
    # dry-run: resolve first token
    local _cmd; _cmd=$(printf '%s' "$VERIFY_CMD" | awk '{print $1}')
    case "$_cmd" in
      if|then|else|elif|fi|for|while|do|done|case|esac|function|return|continue|break|:) ;; # shell builtins
      *) if ! command -v "$_cmd" >/dev/null 2>&1 && [ ! -r "$dir/$_cmd" ]; then
           pr_fail "VERIFY_CMD references unresolved executable: '$_cmd' (not found via command -v or as file)"
         fi ;;
    esac
  else pr_fail "VERIFY_CMD is EMPTY — set it in .ratchet.conf (no-gate is loud by design)"; fi

  # tokens (transitional: skip check until T3.1 - protocol now in prompt)
  pr_ok "tokens: defined in conf (prompt delivery)"

  # secret-scan tool availability
  if command -v gitleaks >/dev/null 2>&1; then pr_ok "gitleaks available (rich secret scan)"
  else pr_ok "gitleaks missing — builtin pattern scan will run (install gitleaks for more)"; fi

  # required tools check
  if [ -n "$REQUIRED_TOOLS" ]; then
    local _missing="" _t
    for _t in $(printf '%s' "$REQUIRED_TOOLS" | tr ',' ' '); do
      [ -n "$_t" ] || continue
      command -v "$_t" >/dev/null 2>&1 || _missing="$_missing $_t"
    done
    if [ -z "$_missing" ]; then pr_ok "all required tools available: $REQUIRED_TOOLS"
    else pr_fail "missing required tool(s):$_missing (install them or remove from REQUIRED_TOOLS in .ratchet.conf)"; fi
  fi

  # configured models exist in pi's registry (typo/churn guard). Uses the
  # 24h cache ONLY — doctor runs before every loop and `pi --list-models`
  # costs ~3s; refresh via `ratchet models list`.
  local _reg=""
  _registry_fresh && _reg="$(pi_model_registry)"
  if [ -n "$_reg" ]; then
    local _bad="" _m
    for _m in $(printf '%s' "$MODELS $PLAN_MODELS $BUILD_MODELS $LIGHT_MODELS" | tr ', ' '\n\n' | sort -u); do
      [ -n "$_m" ] || continue
      printf '%s\n' "$_reg" | grep -qxF "$_m" || _bad="$_bad $_m"
    done
    if [ -z "$_bad" ]; then pr_ok "all configured models exist in pi registry"
    else pr_fail "unknown model(s):$_bad (not in 'pi --list-models' — typo or churned id; fix: ratchet models remove/add)"; fi
  else
    pr_ok "pi registry cache missing/stale — model validation skipped (refresh: ratchet models list)"
  fi
  
  # rank source + unranked count
  local rank_src _nojoin_count=0
  if [ -n "${MODEL_RANK:-}" ]; then
    rank_src="explicit"
  elif [ -f "$RATCHET_HOME/rank.derived" ]; then
    rank_src="derived-snapshot"
  else
    rank_src="none"
  fi
  if [ -n "$_reg" ] && [ "$rank_src" != "explicit" ]; then
    local _m _meta
    while IFS= read -r _m; do
      [ -n "$_m" ] || continue
      _meta="$(model_meta "$_m" 2>/dev/null || true)"
      [ -z "$_meta" ] && _nojoin_count=$((_nojoin_count + 1))
    done <<< "$_reg"
  fi
  pr_ok "rank source: $rank_src (unranked no-join: $_nojoin_count)"

  # tier routing configuration display
  echo "---"
  echo "tier routing:"
  local plan_chain build_chain light_chain plan_think build_think light_think
  plan_chain=$(chain_for_tier "plan")
  build_chain=$(chain_for_tier "build")
  light_chain=$(chain_for_tier "light")
  plan_think=$(thinking_for_tier "plan")
  build_think=$(thinking_for_tier "build")
  light_think=$(thinking_for_tier "light")
  
  # Display plan tier
  if [ -n "$PLAN_MODELS" ]; then
    printf '  PLAN  : %s (thinking=%s)\n' "$plan_chain" "$plan_think"
  else
    printf '  PLAN  : → MODELS (flat) (thinking=%s)\n' "$plan_think"
  fi
  
  # Display build tier
  if [ -n "$BUILD_MODELS" ]; then
    printf '  BUILD : %s (thinking=%s)\n' "$build_chain" "$build_think"
  else
    printf '  BUILD : → MODELS (flat) (thinking=%s)\n' "$build_think"
  fi
  
  # Display light tier
  if [ -n "$LIGHT_MODELS" ]; then
    printf '  LIGHT : %s (thinking=%s)\n' "$light_chain" "$light_think"
  else
    printf '  LIGHT : → MODELS (flat) (thinking=%s)\n' "$light_think"
  fi
  
  # Warning: LIGHT_MODELS set but THINKING_LIGHT not "off"
  if [ -n "$LIGHT_MODELS" ] && [ "$light_think" != "off" ]; then
    printf '  WARN : LIGHT_MODELS set but THINKING_LIGHT is not "off" (cheap tier should not reason)\n'
  fi

  if [ "$full" = 1 ]; then
    echo "--- deep checks (--full) ---"
    if [ -n "$VERIFY_CMD" ]; then
      printf '  VERIFY_CMD ... '; local t0 t1 rc
      t0=$SECONDS; ( cd "$dir" && eval "$VERIFY_CMD" ) >/dev/null 2>&1; rc=$?; t1=$SECONDS
      if [ "$rc" = 0 ]; then printf 'GREEN in %ss\n' "$((t1-t0))"
      else printf 'RED in %ss (the loop will make it green first)\n' "$((t1-t0))"; fi
    fi
  fi

  echo "---"
  if [ "$problems" = 0 ]; then printf 'doctor: OK — repo is loop-ready.\n'
  else printf 'doctor: %d problem(s). Fix before running the loop.\n' "$problems"; fi
  return "$problems"
}
