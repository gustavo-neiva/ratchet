# =============================================================================
#  tracker.sh — PLAN.md grammar: parse, find next task, derive commit subject
# =============================================================================
#  Grammar for a task line:
#     - [ ] T1.2 (normal, serial) design the schema ...
#        │   │       │     │
#        │   │       │     └─ optional tags: trivial|normal|hard  and/or  serial
#        │   │       └─ optional task id (T<milestone>.<n> or any token)
#        │   └─ status marker: [ ] open · [IN PROGRESS] · [x] done
#        └─ leading "- " (with optional indentation)
#  Plain untagged checkboxes (`- [ ] do the thing`) remain 100% valid, so old
#  trackers keep working. Tags feed model routing and future parallel-safety;
#  ids feed per-task failure strikes and commit subjects.
# =============================================================================

# tracker_next OPEN_MARKER -> echoes the first task line matching the status, or "".
# Reads $TRACKER_FILE under $REPO_DIR. OPEN_MARKER: "open" => [ ] , "inprogress" => [IN PROGRESS]
tracker_next() {
  local marker="$1" file="$REPO_DIR/$TRACKER_FILE"
  [ -f "$file" ] || return 0
  case "$marker" in
    inprogress) grep -nE '^[[:space:]]*-?[[:space:]]*\[IN PROGRESS\]' "$file" | head -n1 ;;
    open)       grep -nE '^[[:space:]]*-?[[:space:]]*\[ \]'          "$file" | head -n1 ;;
  esac
}

# tracker_has_open -> 0 if at least one [ ] task exists, else 1 (nothing to do).
tracker_has_open() {
  local file="$REPO_DIR/$TRACKER_FILE"
  [ -f "$file" ] || return 1
  grep -qE '^[[:space:]]*-?[[:space:]]*\[ \]' "$file"
}

# tracker_has_inprogress -> 0 if a task is currently [IN PROGRESS].
tracker_has_inprogress() {
  local file="$REPO_DIR/$TRACKER_FILE"
  [ -f "$file" ] || return 1
  grep -qE '^[[:space:]]*-?[[:space:]]*\[IN PROGRESS\]' "$file"
}

# tracker_count_done -> echoes the number of [x] tasks (for the PR body + stats).
tracker_count_done() {
  local file="$REPO_DIR/$TRACKER_FILE"
  [ -f "$file" ] || { echo 0; return; }
  grep -cE '^[[:space:]]*-?[[:space:]]*\[x\]' "$file" || echo 0
}

# tracker_completed_subject -> one-line subject from the task line that flipped
# to [x] in the CURRENTLY-STAGED diff (best-effort; falls back to the most
# recent [x] line, then a generic per-turn label). Used by the commit gate.
tracker_completed_subject() {
  local line file="$REPO_DIR/$TRACKER_FILE"
  # 1) prefer the line newly marked [x] in this turn's staged diff
  line=$(git diff --cached -U0 -- "$TRACKER_FILE" 2>/dev/null \
        | grep -E '^\+.*\[x\]' | head -n1 \
        | sed -E 's/^\+[[:space:]]*-?[[:space:]]*\[x\][[:space:]]*//; s/\*\*//g')
  # 2) else the newest [x] in the file
  if [ -z "$line" ] && [ -f "$file" ]; then
    line=$(grep -E '^[[:space:]]*-?[[:space:]]*\[x\]' "$file" | tail -n1 \
          | sed -E 's/^[[:space:]]*-?[[:space:]]*\[x\][[:space:]]*//; s/\*\*//g')
  fi
  [ -n "$line" ] && printf '%.100s' "$line" || printf 'step'
}

# tracker_completed_list -> the [x] task lines (ids + text), newline-separated,
# used to compose the PR/MR body after ALL_DONE.
tracker_completed_list() {
  local file="$REPO_DIR/$TRACKER_FILE"
  [ -f "$file" ] || return 0
  grep -E '^[[:space:]]*-?[[:space:]]*\[x\]' "$file" \
    | sed -E 's/^[[:space:]]*-?[[:space:]]*//; s/\*\*//g'
}

# tracker_next_tag -> echoes the tag (trivial|normal|hard) of the first
# [IN PROGRESS] task, or if none, the first [ ] task. Echoes "normal" when
# untagged or no task exists. Used for tiered model routing.
tracker_next_tag() {
  local file="$REPO_DIR/$TRACKER_FILE" line tag
  [ -f "$file" ] || { echo "normal"; return; }
  
  # Find the first [IN PROGRESS] task, else the first [ ] task
  line=$(tracker_next inprogress)
  [ -z "$line" ] && line=$(tracker_next open)
  [ -z "$line" ] && { echo "normal"; return; }
  
  # Extract the tag from parentheses: (trivial|normal|hard)
  # The line format is: - [ ] T1.2 (normal, serial) design...
  # We want to extract the first tag in parens that matches trivial|normal|hard
  tag=$(echo "$line" | sed -nE 's/.*\((trivial|normal|hard)[,)].*$/\1/p')
  
  # Default to "normal" if no tag found
  [ -z "$tag" ] && tag="normal"
  echo "$tag"
}
