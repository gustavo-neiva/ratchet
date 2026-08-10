# =============================================================================
#  tracker.sh — PLAN.md grammar: parse, find next task, derive commit subject
# =============================================================================
#  Grammar for a task line:
#     - [ ] T1.2 (normal, serial) design the schema ...
#        │   │       │     │
#        │   │       │     └─ optional tags: trivial|normal|hard  and/or  serial
#        │   │       └─ optional task id (see supported formats below)
#        │   └─ status marker: [ ] open · [IN PROGRESS] · [x] done
#        └─ leading "- " (with optional indentation)
#
#  Supported task ID formats:
#    T1.2, T5     — classic milestone.task or T+number (most common)
#    A1, I3       — letter(s) + number (e.g., Action items, Issues)
#    N-postmortem — letter + dash + slug (e.g., Named tasks)
#    ? (no ID)    — plain checkboxes valid but get '?' ID (avoid for main work)
#
#  Plain untagged checkboxes (`- [ ] do the thing`) remain 100% valid, so old
#  trackers keep working. Tags feed model routing and future parallel-safety;
#  ids feed per-task failure strikes and commit subjects.
# =============================================================================

# tracker_next OPEN_MARKER -> echoes the first task line matching the status, or "".
# Reads $TRACKER_FILE under $REPO_DIR. OPEN_MARKER: "open" => [ ] , "inprogress" => [IN PROGRESS]
# Skips [ ] lines under DONE/Done when/Definition of Done/checklist headings.
tracker_next() {
  local marker="$1" file="$REPO_DIR/$TRACKER_FILE"
  [ -f "$file" ] || return 0
  case "$marker" in
    inprogress)
      awk '/^#+ / { heading = tolower($0) }
           /^[[:space:]]*-?[[:space:]]*\[IN PROGRESS\]/ {
             if (heading !~ /done|checklist/) { print NR ":" $0; exit }
           }' "$file" ;;
    open)
      awk '/^#+ / { heading = tolower($0) }
           /^[[:space:]]*-?[[:space:]]*\[ \]/ {
             if (heading !~ /done|checklist/) { print NR ":" $0; exit }
           }' "$file" ;;
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

# tracker_milestone_completed_list NAME -> [x] tasks under the named ## milestone
tracker_milestone_completed_list() {
  local mname="$1" file="$REPO_DIR/$TRACKER_FILE"
  [ -f "$file" ] || return 0
  awk -v target="$mname" '
    /^## / {
      name = $0; sub(/^## /, "", name)
      in_target = (name == target) ? 1 : 0
      next
    }
    in_target && /^[[:space:]]*-[[:space:]]*\[x\]/ {
      line = $0
      sub(/^[[:space:]]*-?[[:space:]]*/, "", line)
      gsub(/\*\*/, "", line)
      print line
    }
  ' "$file"
}

# tracker_task_block -> echoes the CURRENT task's full block: the task line
# plus its indented continuation lines (do:/accept:/touches:...), up to the next
# task line or heading. Injected into the turn prompt so ephemeral turns skip
# re-reading the whole tracker to find their spec. Empty when no open task.
tracker_task_block() {
  local line n file="$REPO_DIR/$TRACKER_FILE"
  line=$(tracker_next inprogress)
  [ -z "$line" ] && line=$(tracker_next open)
  [ -z "$line" ] && return 0
  n=${line%%:*}
  awk -v start="$n" 'NR == start { print; next }
       NR > start {
         if ($0 ~ /^[[:space:]]*-?[[:space:]]*\[/ || $0 ~ /^#+ /) exit
         print
       }' "$file"
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
  
  # Extract id: [A-Za-z]+[0-9]+(.N)? or [A-Za-z]+-slug
  # Examples: T1.2, A1, I3, N-postmortem
  if echo "$line" | grep -qE '^[A-Za-z]+[0-9]+(\.[0-9]+)?[[:space:]]'; then
    id=$(echo "$line" | sed -E 's/^([A-Za-z]+[0-9]+(\.[0-9]+)?).*/\1/')
  elif echo "$line" | grep -qE '^[A-Za-z]+-[a-z0-9-]+[[:space:]]'; then
    id=$(echo "$line" | sed -E 's/^([A-Za-z]+-[a-z0-9-]+).*/\1/')
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

# tracker_milestones -> prints "name<TAB>done<TAB>total" for each milestone section.
# A milestone is any `## Milestone ...` or `## ` heading containing tasks.
# Counts [x] vs [ ]|[IN PROGRESS] tasks under that heading until the next ## .
tracker_milestones() {
  local file="$REPO_DIR/$TRACKER_FILE"
  [ -f "$file" ] || return 0
  awk '
    /^## / {
      if (name != "" && total > 0) print name "\t" done "\t" total
      name = $0; sub(/^## /, "", name)
      done = 0; total = 0
      next
    }
    /^[[:space:]]*-[[:space:]]*\[x\]/ { done++; total++; next }
    /^[[:space:]]*-[[:space:]]*\[ \]/ { total++; next }
    /^[[:space:]]*-[[:space:]]*\[IN PROGRESS\]/ { total++; next }
    END { if (name != "" && total > 0) print name "\t" done "\t" total }
  ' "$file"
}

# plan_is_ready -> return 0 when tracker is ready (≥1 tagged open task, no placeholders),
# else 1. A tracker with only [x] tasks is ready (nothing to plan). Untagged-only = not ready.
plan_is_ready() {
  local file="$REPO_DIR/$TRACKER_FILE"
  [ -f "$file" ] || return 1
  # Check for placeholder markers: _(..._) pattern, skip backtick-quoted examples
  grep -v '`' "$file" | grep -qE '_\([^)]+\)_' && return 1
  # All done (no open/inprogress tasks) = ready
  if ! grep -qE '^[[:space:]]*-?[[:space:]]*\[([ ]|IN PROGRESS)\]' "$file"; then
    return 0
  fi
  # Check for at least one open/inprogress task with a tag
  grep -E '^[[:space:]]*-?[[:space:]]*\[([ ]|IN PROGRESS)\]' "$file" \
    | grep -qE '\((trivial|normal|hard)[,)]'
}

# tracker_current_milestone -> echoes "name<TAB>idx<TAB>count<TAB>mdone<TAB>mtotal"
# for the milestone containing the first open/IN PROGRESS task.
# idx = 1-based position of the task within that milestone, count = total tasks in milestone.
tracker_current_milestone() {
  local file="$REPO_DIR/$TRACKER_FILE" first_open_line
  [ -f "$file" ] || return 0
  
  # Find line number of first [IN PROGRESS] or [ ] task
  first_open_line=$(tracker_next inprogress | sed -E 's/:.*$//')
  [ -z "$first_open_line" ] && first_open_line=$(tracker_next open | sed -E 's/:.*$//')
  [ -z "$first_open_line" ] && return 0
  
  awk -v target="$first_open_line" '
    BEGIN { name=""; idx=0; mdone=0; mtotal=0; found=0 }
    /^## / {
      if (found) exit
      name = $0; sub(/^## /, "", name)
      idx = 0; mdone = 0; mtotal = 0
      next
    }
    /^[[:space:]]*-[[:space:]]*\[x\]/ {
      mdone++; mtotal++
      if (!found) idx++
      next
    }
    /^[[:space:]]*-[[:space:]]*\[ \]/ {
      mtotal++
      if (NR == target) { idx++; found = 1 }
      else if (!found) idx++
      next
    }
    /^[[:space:]]*-[[:space:]]*\[IN PROGRESS\]/ {
      mtotal++
      if (NR == target) { idx++; found = 1 }
      else if (!found) idx++
      next
    }
    END { if (found) print name "\t" idx "\t" mtotal "\t" mdone "\t" mtotal }
  ' "$file"
}

# fanout_independent_milestones -> echoes "name<TAB>slug" for each milestone whose
# FIRST open task is tagged (independent). Empty when no independent milestones exist.
fanout_independent_milestones() {
  local file="$REPO_DIR/$TRACKER_FILE"
  [ -f "$file" ] || return 0
  awk '
    BEGIN { name=""; first_task_line="" }
    /^## / {
      # Process previous milestone if it had an independent first task
      if (name != "" && first_task_line != "" && first_task_line ~ /\(independent[,)]/) {
        slug = name
        gsub(/[^A-Za-z0-9_-]/, "-", slug)
        gsub(/-+/, "-", slug)
        gsub(/^-+|-+$/, "", slug)
        print name "\t" slug
      }
      # Start new milestone
      name = $0; sub(/^## /, "", name)
      first_task_line = ""
      next
    }
    /^[[:space:]]*-[[:space:]]*\[ \]/ {
      # Found an open task — if this is the first, record it
      if (first_task_line == "") first_task_line = $0
      next
    }
    END {
      # Process final milestone
      if (name != "" && first_task_line != "" && first_task_line ~ /\(independent[,)]/) {
        slug = name
        gsub(/[^A-Za-z0-9_-]/, "-", slug)
        gsub(/-+/, "-", slug)
        gsub(/^-+|-+$/, "", slug)
        print name "\t" slug
      }
    }
  ' "$file"
}
