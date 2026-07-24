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
  local file="$REPO_DIR/$TRACKER_FILE" n
  [ -f "$file" ] || { echo 0; return; }
  # NOTE: grep -c prints "0" itself on no match (exit 1) — `|| echo 0` would
  # double-print "0\n0" and break arithmetic callers.
  n=$(grep -cE '^[[:space:]]*-?[[:space:]]*\[x\]' "$file" 2>/dev/null)
  echo "${n:-0}"
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

# tracker_next_id_and_text -> echoes "id (tag) text" for the next task (first 60 chars of text).
# For tagged task with id: "T2.1 (hard) implement the parser..."
# For tagged task without id: "? (normal) do the thing..."
# For untagged task: "? (normal) do the thing..."
# Used for turn header observability.
tracker_next_id_and_text() {
  local file="$REPO_DIR/$TRACKER_FILE" line id tag text_with_tag text_clean
  [ -f "$file" ] || { echo "? (normal) "; return; }
  
  # Find the first [IN PROGRESS] task, else the first [ ] task
  line=$(tracker_next inprogress)
  [ -z "$line" ] && line=$(tracker_next open)
  [ -z "$line" ] && { echo "? (normal) "; return; }
  
  # Strip line number prefix from tracker_next output (format: "123:- [ ] ...")
  line=$(echo "$line" | sed -E 's/^[0-9]+://')
  
  # Strip the status marker: - [ ] or - [IN PROGRESS]
  line=$(echo "$line" | sed -E 's/^[[:space:]]*-?[[:space:]]*\[[^]]*\][[:space:]]*//')
  
  # Extract tag (trivial|normal|hard) - use non-greedy match to get FIRST occurrence
  tag=$(echo "$line" | sed -nE 's/^[^(]*\((trivial|normal|hard)[,)].*$/\1/p')
  [ -z "$tag" ] && tag="normal"
  
  # Try to extract id: must be a T-prefixed token OR be followed by parentheses
  # Examples: "T1.2 (hard) text" -> id=T1.2
  #           "do the thing" -> id=?
  #           "T5.1 text" -> id=T5.1 (even without parens, T-prefix signals an id)
  if echo "$line" | grep -qE '^T[0-9]+\.[0-9]+[[:space:]]'; then
    # T-prefixed id exists
    id=$(echo "$line" | sed -E 's/^(T[0-9]+\.[0-9]+).*/\1/')
  else
    id="?"
  fi
  
  # Extract text: remove id (if T-prefixed), remove tag parens, trim
  text_with_tag="$line"
  if [ "$id" != "?" ]; then
    text_with_tag=$(echo "$line" | sed -E "s/^$id[[:space:]]+//")
  fi
  text_clean=$(echo "$text_with_tag" | sed -E 's/[[:space:]]*\([^)]*\)[[:space:]]*/ /' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  
  # Truncate text to 60 chars
  text_clean=$(printf '%.60s' "$text_clean")
  
  echo "$id ($tag) $text_clean"
}
