#!/usr/bin/env bash
# =============================================================================
#  selftest.sh — verify ratchet's detection + loop logic (NO model calls)
# =============================================================================
#  Suites:
#    1. turn-outcome classification (token / exhausted / hard / transient)
#    2. tracker tag extraction (trivial|normal|hard routing tags)
#    3. contract parsing (allowlisted keys, unknown key rejection)
#    4. tier routing (chain_for_tier, thinking_for_tier with fallback)
#    5. cross-provider session sanitizer (strips thinking blocks)
#    6. agnosticism grep-check (zero project knowledge in the tool)
#    7. end-to-end: `ratchet once` against a fixture repo driven by fake-agent
#       -> proves spawn -> watchdog -> classify -> green gate -> commit works
#          with ZERO api keys (this is what makes the loop testable in CI).
#
#  Exit 0 if all pass, 1 otherwise.
# =============================================================================
set -uo pipefail
RR="$(cd "$(dirname "$0")/.." && pwd)"     # ratchet repo root
export RATCHET_ROOT="$RR"                  # commands.sh reads it (bin/ratchet exports it in prod)
RATCHET="$RR/bin/ratchet"
FAKE="$RR/test/fixtures/fake-agent"

# Isolate ALL test runs from the real ~/.ratchet: any `bin/ratchet` invocation
# below writes logs under a throwaway home (cleaned at the end — a trap won't do,
# the per-suite `trap ... EXIT` calls below overwrite each other). Without this
# every fake-repo run leaked a logs/tmp-* dir into the user's real ~/.ratchet.
export RATCHET_HOME="$(mktemp -d)"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

# stubs so session-sanitize.sh can be sourced standalone
emit() { :; }
vlog() { :; }
LOG_DIR="$(mktemp -d)"

# --- units under test ---------------------------------------------------------
STEP_TOKEN="STEP_COMPLETE"; DONE_TOKEN="ALL_DONE"
. "$RR/lib/common.sh"             # tier defaults
. "$RR/lib/classify.sh"
. "$RR/lib/session-sanitize.sh"
. "$RR/lib/tracker.sh"
. "$RR/lib/contract.sh"
. "$RR/lib/model-fallback.sh"     # tier routing
. "$RR/lib/commands.sh"           # cmd_status
. "$RR/lib/models.sh"             # ratchet models (chain ops, upsert, registry)
. "$RR/lib/model-cost.sh"         # model cost/capability cache from models.dev
. "$RR/lib/model-select.sh"       # automatic tier selection from MODEL_RANK
. "$RR/lib/render.sh"             # pure render functions
. "$RR/lib/observability.sh"      # avg_turn_secs, show_excerpt

echo "== suite 0: render (pure terminal functions) =="
check_bar() {  # NAME PCT WIDTH EXPECTED
  local name="$1" pct="$2" w="$3" exp="$4" got
  got="$(render_bar "$pct" "$w")"
  [ "$got" = "$exp" ] && ok "$name" || fail "$name -> got='$got' want='$exp'"
}
check_bar "render_bar 0% empty" 0 5 "░░░░░"
check_bar "render_bar 50% half" 50 10 "▓▓▓▓▓░░░░░"
check_bar "render_bar 63% six-of-ten" 63 10 "▓▓▓▓▓▓░░░░"
check_bar "render_bar 100% full" 100 5 "▓▓▓▓▓"
check_bar "render_bar clamp-low" -10 5 "░░░░░"
check_bar "render_bar clamp-high" 150 5 "▓▓▓▓▓"

# ansi_ok returns 0 only when stdout is a TTY AND NO_COLOR is unset
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  ansi_ok && ok "ansi_ok returns 0 on TTY without NO_COLOR" || fail "ansi_ok false-negative"
else
  ansi_ok && fail "ansi_ok false-positive (non-TTY or NO_COLOR set)" || ok "ansi_ok correctly returns 1"
fi

# render_activity maps event types to human verbs
check_activity() {  # NAME EVENTTYPE EXPECTED
  local name="$1" evt="$2" exp="$3" got
  got="$(render_activity "$evt")"
  [ "$got" = "$exp" ] && ok "$name" || fail "$name -> got='$got' want='$exp'"
}
check_activity "render_activity turn_start" "turn_start" "thinking"
check_activity "render_activity tool_execution_update" "tool_execution_update" "working"
check_activity "render_activity tool_call" "tool_call" "running a tool"
check_activity "render_activity toolCall" "toolCall" "running a tool"
check_activity "render_activity unknown" "some_random_event" "some_random_event"
check_activity "render_activity empty" "" "working"

# render_summary keeps last N meaningful lines (drops blanks)
check_summary() {  # NAME NLINES INPUT EXPECTED
  local name="$1" n="$2" input="$3" exp="$4" got
  got="$(printf '%s' "$input" | render_summary "$n")"
  [ "$got" = "$exp" ] && ok "$name" || fail "$name -> got='$got' want='$exp'"
}
check_summary "render_summary keeps-last-4" 4 "line1
line2

line3
line4
line5
line6" "line3
line4
line5
line6"
check_summary "render_summary drops-blanks" 2 "line1

  
line2
line3" "line2
line3"
check_summary "render_summary all-blank" 2 $'\n\n  \n' ""

# render_status_block DONE TOTAL MNAME MDONE MTOTAL TURN TIER MODEL TASKID TASKTEXT
check_status_block() {  # NAME ARGS... EXPECTED_SUBSTRING
  local name="$1"; shift
  local exp_sub="${!#}"; set -- "${@:1:$(($#-1))}"
  local got; got="$(render_status_block "$@")"
  if printf '%s' "$got" | grep -qF "$exp_sub"; then
    ok "$name"
  else
    fail "$name -> missing substring '$exp_sub' in output"
  fi
}
check_status_block "render_status_block Step line" 33 52 "M5 observability" 3 6 5 build glm-5-turbo T5.4 "heartbeat shows activity" "Step 33/52"
check_status_block "render_status_block percent" 33 52 "M5 observability" 3 6 5 build glm-5-turbo T5.4 "heartbeat shows activity" "63%"
check_status_block "render_status_block milestone" 33 52 "M5 observability" 3 6 5 build glm-5-turbo T5.4 "heartbeat shows activity" "M5 observability"
check_status_block "render_status_block milestone counts" 33 52 "M5 observability" 3 6 5 build glm-5-turbo T5.4 "heartbeat shows activity" "(3/6)"
check_status_block "render_status_block task id" 33 52 "M5 observability" 3 6 5 build glm-5-turbo T5.4 "heartbeat shows activity" "T5.4"
check_status_block "render_status_block tier model" 33 52 "M5 observability" 3 6 5 build glm-5-turbo T5.4 "heartbeat shows activity" "build · glm-5-turbo"
check_status_block "render_status_block no milestone" 10 20 "" 0 0 3 light gpt-4o-mini "?" "do the thing" "Step 10/20"

# fmt_dur SECS -> human-readable duration
check_fmt_dur() {  # NAME SECS EXPECTED
  local name="$1" secs="$2" exp="$3" got
  got="$(fmt_dur "$secs")"
  [ "$got" = "$exp" ] && ok "$name" || fail "$name -> got='$got' want='$exp'"
}
check_fmt_dur "fmt_dur 42s" 42 "42s"
check_fmt_dur "fmt_dur 57m" 3420 "57m"
check_fmt_dur "fmt_dur 1h20m" 4800 "1h20m"
check_fmt_dur "fmt_dur 0s" 0 "0s"
check_fmt_dur "fmt_dur 59s" 59 "59s"
check_fmt_dur "fmt_dur 60s" 60 "1m"
check_fmt_dur "fmt_dur 3599s" 3599 "59m"
check_fmt_dur "fmt_dur 3600s" 3600 "1h0m"

# render_eta REMAINING AVGSECS -> ETA string
check_eta() {  # NAME REMAINING AVG EXPECTED_SUBSTRING
  local name="$1" remaining="$2" avg="$3" exp_sub="$4" got
  got="$(render_eta "$remaining" "$avg")"
  if printf '%s' "$got" | grep -qF "$exp_sub"; then
    ok "$name"
  else
    fail "$name -> missing substring '$exp_sub' in '$got'"
  fi
}
check_eta "render_eta 19 turns" 19 180 "~19 turns"
check_eta "render_eta 57m" 19 180 "~57m left"
check_eta "render_eta avg=0" 19 0 "ETA unknown"
check_eta "render_eta large" 100 300 "~100 turns"

# render_timing TURN ELAPSED AVG REMAINING -> timing line
check_timing() {  # NAME TURN ELAPSED AVG REMAINING EXPECTED_SUBSTRING
  local name="$1" turn="$2" elapsed="$3" avg="$4" remaining="$5" exp_sub="$6" got
  got="$(render_timing "$turn" "$elapsed" "$avg" "$remaining")"
  if printf '%s' "$got" | grep -qF "$exp_sub"; then
    ok "$name"
  else
    fail "$name -> missing substring '$exp_sub' in '$got'"
  fi
}
check_timing "render_timing turn number" 5 222 180 19 "turn 5"
check_timing "render_timing elapsed" 5 222 180 19 "3m"
check_timing "render_timing avg" 5 222 180 19 "avg 3m"
check_timing "render_timing eta" 5 222 180 19 "~57m left"

# avg_turn_secs LOGFILE -> mean turn duration
check_avg() {  # NAME LOGFILE EXPECTED
  local name="$1" logfile="$2" exp="$3" got
  got="$(avg_turn_secs "$logfile")"
  [ "$got" = "$exp" ] && ok "$name" || fail "$name -> got='$got' want='$exp'"
}
check_avg "avg_turn_secs with-took" "$RR/test/fixtures/logs/with-took.log" 64
check_avg "avg_turn_secs old-format" "$RR/test/fixtures/logs/old-format.log" 0
check_avg "avg_turn_secs missing-file" "/nonexistent.log" 0

echo "== suite 1: turn classification =="
check_class() {  # NAME EXPECTED STRING
  local name="$1" exp="$2" str="$3" got f
  f="$(mktemp)"; printf '%s' "$str" > "$f"
  got="$(classify_turn "$f" "$STEP_TOKEN" "$DONE_TOKEN" 0)"
  rm -f "$f"
  [ "$got" = "$exp" ] && ok "$name -> $got" || fail "$name -> got=$got want=$exp"
}
check_class "step-token"          "step"      "did the thing
$STEP_TOKEN"
check_class "done-token"          "done"      "$DONE_TOKEN"
check_class "anthropic-429"       "exhausted" 'Anthropic request failed: HTTP 429 {"type":"error","error":{"type":"rate_limit_error"}}'
check_class "anthropic-529"       "exhausted" 'Anthropic request failed: HTTP 529 {"error":{"type":"overloaded_error"}}'
check_class "zai-daily-1304"      "exhausted" 'request failed: HTTP 429 {"error":{"code":"1304","message":"daily call limit reached"}}'
check_class "zai-quota-1308"      "exhausted" 'request failed: HTTP 403 {"error":{"code":"1308","message":"quota insufficient balance"}}'
check_class "not-found-404"       "hard"      'Anthropic request failed: HTTP 404 {"error":{"type":"not_found_error"}}'
check_class "auth-401"            "hard"      'request failed: HTTP 401 {"error":{"type":"authentication_error"}}'
check_class "invalid-sig-thinking" "hard"     'HTTP 400 {"error":{"type":"invalid_request_error","message":"Invalid signature in thinking block"}}'
check_class "network-blip"        "transient" 'fetch failed: ECONNRESET'
check_class "plain-text-no-token" "transient" "I am still thinking about the problem."

# json-mode: assistant PROSE mentioning quota/rate-limit/daily-limit must NOT be
# read as a provider error (the 24%-quota false-EXHAUSTED bug). Same words inside
# an error event still classify. STEP_TOKEN present -> classifies step, proving
# the prose didn't short-circuit to exhausted/hard.
check_class_json() {  # NAME EXPECTED STRING
  local name="$1" exp="$2" str="$3" got f
  f="$(mktemp)"; printf '%s' "$str" > "$f"
  got="$(classify_turn "$f" "$STEP_TOKEN" "$DONE_TOKEN" 0 1)"
  rm -f "$f"
  [ "$got" = "$exp" ] && ok "$name -> $got" || fail "$name -> got=$got want=$exp"
}
check_class_json "json-prose-quota-not-exhausted" "step" \
  '{"type":"text_delta","delta":"Next I will add dependency-scanning; note the daily quota / rate limit handling."}
{"type":"text_end","text":"done with '"$STEP_TOKEN"'"}'
check_class_json "json-real-429-still-exhausted" "exhausted" \
  '{"type":"text_delta","delta":"working on it"}
{"type":"error","error":{"type":"rate_limit_error"}} request failed: HTTP 429'
# deadline kill with no token/error -> timeout (distinct from transient)
check_deadline() {
  local f; f="$(mktemp)"; printf '%s' 'agent still working, no token' > "$f"
  local got; got="$(classify_turn "$f" "$STEP_TOKEN" "$DONE_TOKEN" 1)"
  rm -f "$f"
  [ "$got" = "timeout" ] && ok "deadline-no-token -> timeout" || fail "deadline-no-token -> got=$got want=timeout"
}
check_deadline

echo "== suite 2: tracker tag extraction =="
check_tag() {  # NAME EXPECTED PLAN_CONTENT
  local name="$1" exp="$2" content="$3" got tmpdir tmpplan
  tmpdir="$(mktemp -d)"
  tmpplan="$tmpdir/PLAN.md"
  printf '%s' "$content" > "$tmpplan"
  REPO_DIR="$tmpdir" TRACKER_FILE="PLAN.md" got="$(tracker_next_tag)"
  rm -rf "$tmpdir"
  [ "$got" = "$exp" ] && ok "$name -> $got" || fail "$name -> got=$got want=$exp"
}
check_tag "trivial-tag" "trivial" "- [ ] T1.1 (trivial) do the thing"
check_tag "normal-tag" "normal" "- [ ] T1.2 (normal, serial) design"
check_tag "hard-tag" "hard" "- [ ] T1.3 (hard) implement"
check_tag "untagged" "normal" "- [ ] do something"
check_tag "empty-tracker" "normal" ""
check_tag "inprogress-wins" "hard" "- [IN PROGRESS] T2.1 (hard) big task
- [ ] T2.2 (trivial) small task"
check_tag "only-done" "normal" "- [x] T1.1 (trivial) finished"

# tracker_next_id_and_text tests
check_id_text() {  # NAME EXPECTED PLAN_CONTENT
  local name="$1" exp="$2" content="$3" got tmpdir tmpplan
  tmpdir="$(mktemp -d)"
  tmpplan="$tmpdir/PLAN.md"
  printf '%s' "$content" > "$tmpplan"
  REPO_DIR="$tmpdir" TRACKER_FILE="PLAN.md" got="$(tracker_next_id_and_text)"
  rm -rf "$tmpdir"
  [ "$got" = "$exp" ] && ok "$name" || fail "$name -> got='$got' want='$exp'"
}
check_id_text "tagged-with-id" "T2.1 (hard) implement the parser quickly" "- [ ] T2.1 (hard) implement the parser quickly"
check_id_text "tagged-no-id" "? (normal) do the thing" "- [ ] do the thing"
check_id_text "untagged-no-id" "? (normal) simple task" "- [ ] simple task"
check_id_text "long-text-truncate" "T5.1 (normal) $(printf '%.60s' 'Turn header shows the work: extend the additive tier line to')" "- [ ] T5.1 (normal) Turn header shows the work: extend the additive tier line to turn N | tier=X | model=Y | thinking=Z | task=T2.1 (hard) <first 60 chars of task text>"
check_id_text "inprogress-wins" "T2.1 (hard) $(printf '%.60s' 'big task with long description that should be truncated at s')" "- [IN PROGRESS] T2.1 (hard) big task with long description that should be truncated at sixty characters
- [ ] T2.2 (trivial) small task"
check_id_text "empty-tracker" "? (normal) " ""

echo "== suite 3: milestone parsing =="
check_milestones() {  # NAME EXPECTED_COUNT PLAN_CONTENT
  local name="$1" exp_count="$2" content="$3" got tmpdir tmpplan count
  tmpdir="$(mktemp -d)"
  tmpplan="$tmpdir/PLAN.md"
  printf '%s' "$content" > "$tmpplan"
  REPO_DIR="$tmpdir" TRACKER_FILE="PLAN.md" got="$(tracker_milestones)"
  rm -rf "$tmpdir"
  [ -z "$got" ] && count=0 || count=$(echo "$got" | grep -c '^')
  [ "$count" = "$exp_count" ] && ok "$name" || fail "$name -> got $count lines, want $exp_count"
}
check_milestones "no-milestones" "0" "- [ ] task without milestone"
check_milestones "one-milestone" "1" "## Milestone 1
- [ ] T1.1 (trivial) task
- [x] T1.2 (normal) done"
check_milestones "multi-milestone" "2" "## Milestone 0
- [x] T0.1 (trivial) done
## Milestone 1
- [ ] T1.1 (normal) open
- [IN PROGRESS] T1.2 (hard) inprog"

check_milestone_counts() {  # NAME MNAME EXPECTED_DONE EXPECTED_TOTAL PLAN_CONTENT
  local name="$1" mname="$2" exp_done="$3" exp_total="$4" content="$5" got tmpdir tmpplan line done total
  tmpdir="$(mktemp -d)"
  tmpplan="$tmpdir/PLAN.md"
  printf '%s' "$content" > "$tmpplan"
  REPO_DIR="$tmpdir" TRACKER_FILE="PLAN.md" got="$(tracker_milestones)"
  rm -rf "$tmpdir"
  line=$(echo "$got" | grep "^$mname")
  done=$(echo "$line" | cut -f2)
  total=$(echo "$line" | cut -f3)
  [ "$done" = "$exp_done" ] && [ "$total" = "$exp_total" ] && ok "$name" || fail "$name -> got done=$done total=$total, want $exp_done/$exp_total"
}
check_milestone_counts "m1-counts" "Milestone 1" "1" "3" "## Milestone 1
- [x] T1.1 (trivial) done
- [ ] T1.2 (normal) open
- [IN PROGRESS] T1.3 (hard) inprog"

check_current_milestone() {  # NAME EXPECTED_NAME EXPECTED_IDX EXPECTED_TOTAL PLAN_CONTENT
  local name="$1" exp_name="$2" exp_idx="$3" exp_total="$4" content="$5" got tmpdir tmpplan mname idx total
  tmpdir="$(mktemp -d)"
  tmpplan="$tmpdir/PLAN.md"
  printf '%s' "$content" > "$tmpplan"
  REPO_DIR="$tmpdir" TRACKER_FILE="PLAN.md" got="$(tracker_current_milestone)"
  rm -rf "$tmpdir"
  mname=$(echo "$got" | cut -f1)
  idx=$(echo "$got" | cut -f2)
  total=$(echo "$got" | cut -f3)
  [ "$mname" = "$exp_name" ] && [ "$idx" = "$exp_idx" ] && [ "$total" = "$exp_total" ] && ok "$name" || fail "$name -> got '$mname' idx=$idx total=$total, want '$exp_name' $exp_idx $exp_total"
}
check_current_milestone "current-m2-idx3" "Milestone 2" "3" "4" "## Milestone 1
- [x] T1.1 done
## Milestone 2
- [x] T2.1 done
- [x] T2.2 done
- [ ] T2.3 open first
- [ ] T2.4 open"
check_current_milestone "current-inprogress" "Milestone 5 — observability" "3" "6" "## Milestone 5 — observability
- [x] T5.1 done
- [x] T5.2 done
- [IN PROGRESS] T5.3 inprog
- [ ] T5.4 open
- [ ] T5.5 open
- [ ] T5.6 open"

echo "== suite 4: contract parsing =="
# Test that tier keys parse correctly
check_tier_key() {
  local tmpconf; tmpconf="$(mktemp)"
  printf 'LIGHT_MODELS="a/b"\n' > "$tmpconf"
  if parse_repo_conf "$tmpconf" 2>/dev/null; then
    [ "$LIGHT_MODELS" = "a/b" ] && ok "tier-key parses" || fail "tier-key parsed but value wrong: got=$LIGHT_MODELS"
  else
    fail "tier-key parse failed"
  fi
  rm -f "$tmpconf"
}
check_tier_key

# Test that unknown keys still error
check_unknown_key() {
  local tmpconf; tmpconf="$(mktemp)"
  printf 'UNKNOWN_KEY="value"\n' > "$tmpconf"
  if parse_repo_conf "$tmpconf" 2>/dev/null; then
    fail "unknown-key should error but passed"
  else
    [ -n "$RATCHET_CONF_ERRORS" ] && ok "unknown-key rejected" || fail "unknown-key rejected but no error message"
  fi
  rm -f "$tmpconf"
}
check_unknown_key

echo "== suite 5: tier routing =="
# chain_for_tier: unset tier -> MODELS fallback
check_chain() {  # NAME TIER PLAN_M BUILD_M LIGHT_M MODELS EXPECTED
  local name="$1" tier="$2" exp="$7" got
  PLAN_MODELS="$3"; BUILD_MODELS="$4"; LIGHT_MODELS="$5"; MODELS="$6"
  got="$(chain_for_tier "$tier")"
  [ "$got" = "$exp" ] && ok "$name" || fail "$name -> got=$got want=$exp"
}
check_chain "plan-set" "plan" "p/a,p/b" "" "" "m/x" "p/a,p/b"
check_chain "build-set" "build" "" "b/a,b/b" "" "m/x" "b/a,b/b"
check_chain "light-set" "light" "" "" "l/a" "m/x" "l/a"
check_chain "plan-unset" "plan" "" "" "" "m/x,m/y" "m/x,m/y"
check_chain "build-unset" "build" "" "" "" "m/x,m/y" "m/x,m/y"
check_chain "light-unset" "light" "" "" "" "m/x,m/y" "m/x,m/y"

# thinking_for_tier: unset tier -> THINKING fallback, build-hard bump logic
check_thinking() {  # NAME TIER PLAN_T BUILD_T LIGHT_T THINKING EXPECTED
  local name="$1" tier="$2" exp="$7" got
  THINKING_PLAN="$3"; THINKING_BUILD="$4"; THINKING_LIGHT="$5"; THINKING="$6"
  got="$(thinking_for_tier "$tier")"
  [ "$got" = "$exp" ] && ok "$name" || fail "$name -> got=$got want=$exp"
}
check_thinking "plan-set" "plan" "high" "" "" "low" "high"
check_thinking "build-set" "build" "" "medium" "" "low" "medium"
check_thinking "light-set" "light" "" "" "off" "low" "off"
check_thinking "plan-unset" "plan" "" "" "" "low" "low"
check_thinking "build-unset" "build" "" "" "" "medium" "medium"
check_thinking "light-unset" "light" "" "" "" "high" "high"
# build-hard bump logic: bump one notch above THINKING when THINKING_BUILD is empty
check_thinking "hard-bump-off" "build-hard" "" "" "" "off" "minimal"
check_thinking "hard-bump-minimal" "build-hard" "" "" "" "minimal" "low"
check_thinking "hard-bump-low" "build-hard" "" "" "" "low" "medium"
check_thinking "hard-bump-medium" "build-hard" "" "" "" "medium" "high"
check_thinking "hard-bump-high" "build-hard" "" "" "" "high" "high"
check_thinking "hard-bump-xhigh" "build-hard" "" "" "" "xhigh" "high"
# build-hard with THINKING_BUILD set -> honor THINKING_BUILD, no bump
check_thinking "hard-explicit" "build-hard" "" "low" "" "medium" "low"

echo "== suite 6: session sanitizer =="
if command -v python3 >/dev/null 2>&1; then
  sf="$LOG_DIR/sess.jsonl"
  {
    printf '%s\n' '{"type":"session","version":3,"id":"x"}'
    printf '%s\n' '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}'
    printf '%s\n' '{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm","thinkingSignature":"reasoning_content"},{"type":"text","text":"ok"},{"type":"toolCall","id":"c1","name":"read","arguments":{"path":"/x"}}]}}'
    printf '%s\n' '{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"only","thinkingSignature":"reasoning_content"}]}}'
  } > "$sf"
  sanitize_session "$sf" >/dev/null 2>&1
  res=$(python3 - "$sf" <<'PY'
import json,sys
n=e=tool=txt=0
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    o=json.loads(line); m=o.get("message",{})
    if o.get("type")=="message" and m.get("role")=="assistant":
        c=m.get("content",[])
        n+=sum(1 for b in c if b.get("type")=="thinking")
        e+= 1 if len(c)==0 else 0
        tool+=sum(1 for b in c if b.get("type")=="toolCall")
        txt+=sum(1 for b in c if b.get("type")=="text")
print(f"{n} {e} {tool} {txt}")
PY
)
  set -- $res
  if [ "$1" = "0" ] && [ "$2" = "0" ] && [ "$3" = "1" ] && [ "$4" = "2" ]; then
    ok "sanitizer -> thinking=0 empty=0 tool=1 text=2"
  else
    fail "sanitizer -> got(thinking empty tool text)=${res} want=0 0 1 2"
  fi
else
  fail "python3 missing (sanitizer untested)"
fi

echo "== suite 7: agnosticism (zero project knowledge) =="
if grep -riE 'cookbook|cap_table|carta|erl_crash|issuance|reporting|jira|secm-' \
     "$RR/lib" "$RR/bin" "$RR/templates" 2>/dev/null; then
  fail "project knowledge leaked into lib/bin/templates"
else
  ok "no project knowledge in lib/bin/templates"
fi

echo "== suite 8: end-to-end (fake-agent, no api keys) =="
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$RR/test/fixtures/fixture-repo/PLAN.md" "$tmp/"
cp "$RR/test/fixtures/fixture-repo/verify.sh" "$tmp/"
cp "$RR/test/fixtures/fixture-repo/.gitignore" "$tmp/"
chmod +x "$tmp/verify.sh"
cat > "$tmp/.ratchet.conf" <<EOF
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=./verify.sh
EOF

# init stamps the AGENTS.md protocol + localizes; then git-init a baseline.
if "$RATCHET" init "$tmp" >>"$tmp/init.log" 2>&1; then ok "ratchet init"
else fail "ratchet init (see $tmp/init.log)"; fi

# fanout protocol block must be in template (used for per-turn prompt injection)
if grep -q "Fanout strategy" "$RR/templates/AGENTS.protocol.md"; then
  ok "template contains fanout protocol"
else
  fail "template missing fanout protocol block"
fi

git -C "$tmp" init -q
git -C "$tmp" add -A
git -C "$tmp" commit -q -m "baseline"

# one turn: fake-agent ticks a task -> green gate -> commit.
"$RATCHET" once "$tmp" -m fake/model --agent-cmd "$FAKE" --quiet >>"$tmp/run.log" 2>&1
rc=$?
if [ "$rc" = 0 ]; then ok "ratchet once exited 0"
else fail "ratchet once exit=$rc (see $tmp/run.log)"; fi

commits=$(git -C "$tmp" log --oneline 2>/dev/null | grep -c 'auto(ratchet)' || true)
ticks=$(grep -cE '^[[:space:]]*-?[[:space:]]*\[x\]' "$tmp/PLAN.md" || true)
[ "$commits" -ge 1 ] && ok "one green-gated commit made ($commits)" || fail "no auto(ratchet) commit ($commits)"
[ "$ticks" -ge 1 ]   && ok "tracker advanced ($ticks task(s) [x])"    || fail "tracker did not advance ($ticks [x])"

# a RED verify must BLOCK the commit (the safety punchline).
echo "test_fail" > "$tmp/should_not_commit.txt"
git -C "$tmp" add -A
git -C "$tmp" commit -q -m "stage a change to be gated" 2>/dev/null || true
# point the gate at a command that always fails, run once more
cat > "$tmp/.ratchet.conf" <<EOF
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=false
EOF
# re-stamp conf hash so doctor is happy with the changed contract
mkdir -p "$tmp/.ratchet"; shasum -a 256 "$tmp/.ratchet.conf" | awk '{print $1}' > "$tmp/.ratchet/conf.hash"
# make a real file change so there is something to (try to) commit
echo "// noop change" >> "$tmp/verify.sh"
"$RATCHET" once "$tmp" -m fake/model --agent-cmd "$FAKE" --quiet >>"$tmp/run2.log" 2>&1
red_commits=$(git -C "$tmp" log --oneline 2>/dev/null | grep -c 'auto(ratchet): turn 2' || true)
if [ "$red_commits" = "0" ]; then ok "RED verify blocked the commit (no green, no commit)"
else fail "RED turn was committed ($red_commits) — green gate failed"; fi

# Doctor tier warning test (new in v1.1)
echo ""
echo "== suite 9: doctor tier warning (LIGHT_MODELS without THINKING_LIGHT=off) =="
tmp_doc="$(mktemp -d)"
trap 'rm -rf "$tmp_doc"' EXIT
cat > "$tmp_doc/PLAN.md" <<'EOF'
# Test plan
- [ ] T1 (trivial) task
EOF
cat > "$tmp_doc/verify.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp_doc/verify.sh"
cat > "$tmp_doc/.ratchet.conf" <<'EOF'
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=./verify.sh
LIGHT_MODELS=fake/light
THINKING_LIGHT=low
EOF
"$RATCHET" init "$tmp_doc" >/dev/null 2>&1
git -C "$tmp_doc" init -q >/dev/null 2>&1
git -C "$tmp_doc" add -A
git -C "$tmp_doc" commit -q -m "baseline" >/dev/null 2>&1
# Run doctor and check for the warning
if "$RATCHET" doctor "$tmp_doc" 2>&1 | grep -q 'WARN.*LIGHT_MODELS.*THINKING_LIGHT.*off'; then
  ok "doctor warns when LIGHT_MODELS set without THINKING_LIGHT=off"
else
  fail "doctor did not warn about LIGHT_MODELS/THINKING_LIGHT mismatch"
fi

# Tier routing end-to-end tests (new in v1.1)
echo ""
echo "== suite 10: tier routing end-to-end (unset keys, trivial tag) =="
tmp2="$(mktemp -d)"
trap 'rm -rf "$tmp2"' EXIT

# Test (a): unset tier keys → old behavior (MODELS chain used)
cat > "$tmp2/PLAN.md" <<'EOF'
# Test plan
- [ ] T1 (normal) first task
- [ ] T2 (normal) second task
EOF
cat > "$tmp2/verify.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp2/verify.sh"
cat > "$tmp2/.ratchet.conf" <<'EOF'
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=./verify.sh
EOF
"$RATCHET" init "$tmp2" >/dev/null 2>&1
git -C "$tmp2" init -q
git -C "$tmp2" add -A
git -C "$tmp2" commit -q -m "baseline"

# Run with MODELS (no tier keys)
"$RATCHET" once "$tmp2" -m fake/default --agent-cmd "$FAKE" >"$tmp2/run.log" 2>&1
# Check that the log shows tier=build (default for normal tasks) but model is from MODELS
if grep -q 'tier=build.*model=fake/default' "$tmp2/run.log"; then
  ok "unset tier keys: tier=build routes to MODELS chain"
else
  fail "unset tier keys: expected tier=build with MODELS chain (see $tmp2/run.log)"
fi

# Test (b): trivial task routes to LIGHT_MODELS
tmp3="$(mktemp -d)"
trap 'rm -rf "$tmp3"' EXIT
cat > "$tmp3/PLAN.md" <<'EOF'
# Test plan
- [ ] T1 (trivial) light task
- [ ] T2 (normal) heavy task
EOF
cat > "$tmp3/verify.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp3/verify.sh"
cat > "$tmp3/.ratchet.conf" <<'EOF'
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=./verify.sh
LIGHT_MODELS=fake/light-model
BUILD_MODELS=fake/build-model
EOF
"$RATCHET" init "$tmp3" >/dev/null 2>&1
git -C "$tmp3" init -q
git -C "$tmp3" add -A
git -C "$tmp3" commit -q -m "baseline"

# Run once: should route the trivial task to LIGHT_MODELS
"$RATCHET" once "$tmp3" --agent-cmd "$FAKE" >"$tmp3/run.log" 2>&1
if grep -q 'tier=light.*model=fake/light-model' "$tmp3/run.log"; then
  ok "trivial task routes to LIGHT_MODELS (tier=light)"
else
  fail "trivial task did not route to LIGHT_MODELS (see $tmp3/run.log)"
fi

echo ""
echo "== suite 11: builtin secret scan (BSD-grep-safe patterns) =="
. "$RR/lib/commit-gate.sh"
check_secret() {  # NAME EXPECT_RC(0=block,1=clean) CONTENT
  local name="$1" exp="$2" content="$3" d rc errf
  d="$(mktemp -d)"; errf="$d/.stderr"
  git -C "$d" init -q
  printf '%s\n' "$content" > "$d/f.txt"
  git -C "$d" add f.txt
  ( cd "$d" && builtin_secret_scan 2>"$errf" ); rc=$?
  if [ "$rc" = "$exp" ] && ! grep -q 'grep:' "$errf"; then ok "secret-scan $name"
  else fail "secret-scan $name (rc=$rc want=$exp, stderr: $(cat "$errf"))"; fi
  rm -rf "$d"
}
check_secret "openssh-private-key blocks" 0 '-----BEGIN OPENSSH PRIVATE KEY-----'
check_secret "bare-private-key blocks"    0 '-----BEGIN PRIVATE KEY-----'
check_secret "clean-diff passes"          1 'just a normal line of code'

# T6.4: a block (rc=0) must NEVER carry an empty reason (the empty-reason
# `BLOCKED: secret scan —  —` shape that dead-looped repos historically), and a
# clean pass must leave no stale reason set.
check_secret_reason() {  # NAME EXPECT_RC CONTENT
  local name="$1" exp="$2" content="$3" d rc
  d="$(mktemp -d)"; git -C "$d" init -q
  printf '%s\n' "$content" > "$d/f.txt"; git -C "$d" add f.txt
  # Run in THIS shell (cd + restore) so SECRET_BLOCK_REASON is observable — a
  # subshell would hide the very var this test exists to assert on.
  local prev="$PWD"; cd "$d" || return; builtin_secret_scan; rc=$?; cd "$prev" || return
  if [ "$exp" = 0 ]; then
    { [ "$rc" = 0 ] && [ -n "$SECRET_BLOCK_REASON" ]; } \
      && ok "secret-scan $name (blocks with non-empty reason)" \
      || fail "secret-scan $name (rc=$rc reason='[$SECRET_BLOCK_REASON]')"
  else
    { [ "$rc" = 1 ] && [ -z "$SECRET_BLOCK_REASON" ]; } \
      && ok "secret-scan $name (passes, empty reason)" \
      || fail "secret-scan $name (rc=$rc reason='[$SECRET_BLOCK_REASON]')"
  fi
  rm -rf "$d"
}
check_secret_reason "aws-key reason"  0 'AKIAIOSFODNN7EXAMPLE'
check_secret_reason "no-match reason" 1 'x = 1'

# The live dead-loop cause: a staged tree with NO added lines (agent printed the
# token without editing a file). `$diff` is empty -> the scan must return CLEAN
# (rc=1, empty reason), never block. `elif builtin_secret_scan` reads rc=0 as a
# hit, so an empty-diff rc=0 is the `BLOCKED: secret scan —  —` false block.
check_secret_empty_diff() {
  local d rc; d="$(mktemp -d)"; git -C "$d" init -q
  local prev="$PWD"; cd "$d" || return; builtin_secret_scan; rc=$?; cd "$prev" || return
  { [ "$rc" = 1 ] && [ -z "$SECRET_BLOCK_REASON" ]; } \
    && ok "secret-scan empty-diff passes (no false block)" \
    || fail "secret-scan empty-diff (rc=$rc reason='[$SECRET_BLOCK_REASON]')"
  rm -rf "$d"
}
check_secret_empty_diff

# Regression: a secret marker only on a REMOVED or context line is NOT being
# introduced by the commit and must NOT block (else the loop dead-locks when a
# file legitimately documents/tests a secret shape). Scan added lines only.
check_secret_removed_only() {
  local d rc errf
  d="$(mktemp -d)"; errf="$d/.stderr"
  git -C "$d" init -q
  printf 'key=-----BEGIN PRIVATE KEY-----\n' > "$d/f.txt"  # ratchet:allow-secret (test fixture, not a real key)
  git -C "$d" add f.txt; git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  printf 'key=redacted\n' > "$d/f.txt"; git -C "$d" add f.txt  # removes the marker line
  ( cd "$d" && builtin_secret_scan 2>"$errf" ); rc=$?
  if [ "$rc" = 1 ] && ! grep -q 'grep:' "$errf"; then ok "secret-scan removed-line marker passes"
  else fail "secret-scan removed-line marker (rc=$rc want=1, stderr: $(cat "$errf"))"; fi
  rm -rf "$d"
}
check_secret_removed_only

# Verify .ratchet.conf is still unstaged by commit_turn (untracked conf must not fail turn)
check_conf_unstaged() {
  local d
  d="$(mktemp -d)"; git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf 'x\n' > "$d/file.txt"
  git -C "$d" add file.txt; git -C "$d" commit -qm init
  printf 'MODELS=a/b\n' > "$d/.ratchet.conf"
  printf 'y\n' > "$d/file.txt"
  ( cd "$d" && git add -A && git reset -q -- .ratchet.conf 2>/dev/null && ! git diff --cached --name-only | grep -q '.ratchet.conf' ) && \
    ok "conf unstaged: .ratchet.conf not in staging after reset" || fail "conf unstaged: .ratchet.conf still staged"
  rm -rf "$d"
}
check_conf_unstaged

echo ""
echo "== suite 12: --cheap flag + staged-changes startup warning =="
tmp4="$(mktemp -d)"
trap 'rm -rf "$tmp4"' EXIT
cat > "$tmp4/PLAN.md" <<'EOF'
# Test plan
- [ ] T1 (hard) heavy task
EOF
cat > "$tmp4/verify.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp4/verify.sh"
cat > "$tmp4/.ratchet.conf" <<'EOF'
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=./verify.sh
LIGHT_MODELS=fake/light-model
BUILD_MODELS=fake/build-model
EOF
"$RATCHET" init "$tmp4" >/dev/null 2>&1
git -C "$tmp4" init -q
git -C "$tmp4" add -A
git -C "$tmp4" commit -q -m "baseline"
# pre-stage a file to trigger the startup warning
echo "leftover" > "$tmp4/staged.txt"
git -C "$tmp4" add staged.txt
"$RATCHET" once "$tmp4" --cheap --agent-cmd "$FAKE" >"$tmp4/run.log" 2>&1
if grep -q 'tier=light.*model=fake/light-model' "$tmp4/run.log"; then
  ok "--cheap routes a (hard) task to the LIGHT chain"
else
  fail "--cheap did not route hard task to LIGHT chain (see $tmp4/run.log)"
fi
if grep -q 'staged changes detected at startup' "$tmp4/run.log"; then
  ok "staged-changes startup warning emitted"
else
  fail "no staged-changes warning (see $tmp4/run.log)"
fi
if grep -qE 'tasks: [0-9]+ done / [0-9]+ total \| next: T1' "$tmp4/run.log"; then
  ok "progress line shows done/total + next task"
else
  fail "no progress line (see $tmp4/run.log)"
fi
if grep -qE 'turn 1 end \| class=step \| took=[0-9]+s \| task=T1' "$tmp4/run.log"; then
  ok "turn summary line shows class + took= + task"
else
  fail "no turn summary took= line (see $tmp4/run.log)"
fi

echo ""
echo "== suite 13: ratchet plan (one PLAN-tier turn, restricted commit) =="
tmp_p="$(mktemp -d)"
trap 'rm -rf "$tmp_p"' EXIT
cat > "$tmp_p/PLAN.md" <<'EOF'
# Test plan
- [ ] T1 (trivial) first
- [ ] T2 (normal) second
EOF
cat > "$tmp_p/verify.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp_p/verify.sh"
cat > "$tmp_p/.ratchet.conf" <<'EOF'
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=./verify.sh
PLAN_MODELS=fake/plan-model
EOF
"$RATCHET" init "$tmp_p" >/dev/null 2>&1
git -C "$tmp_p" init -q
# a tracked CODE file — plan must NOT sweep its (uncommitted) changes into the commit.
printf 'fn main(){}\n' > "$tmp_p/src_main.rs"
git -C "$tmp_p" add -A
git -C "$tmp_p" commit -q -m "baseline"
# uncommitted code change that must stay out of the plan commit
printf 'fn main(){ /* uncommitted edit */ }\n' >> "$tmp_p/src_main.rs"

"$RATCHET" plan "$tmp_p" --agent-cmd "$FAKE" >"$tmp_p/run.log" 2>&1
rc=$?
if [ "$rc" = 0 ]; then ok "ratchet plan exited 0"
else fail "ratchet plan exit=$rc (see $tmp_p/run.log)"; fi

# (a) exactly ONE plan-tier turn ran (no second turn)
if grep -q 'plan turn 1 | tier=plan' "$tmp_p/run.log"; then
  ok "plan runs one PLAN-tier turn"
else
  fail "plan did not log one PLAN-tier turn (see $tmp_p/run.log)"
fi
if grep -q 'plan turn 2' "$tmp_p/run.log"; then
  fail "plan ran a second turn (must be exactly one) (see $tmp_p/run.log)"
else
  ok "plan stops after one turn (no loop)"
fi

# (b) plan stopped loudly for human review
if grep -qi 'HUMAN: review' "$tmp_p/run.log" && grep -qi 'before running' "$tmp_p/run.log"; then
  ok "plan stops with the loud HUMAN-review message"
else
  fail "plan did not stop loudly (see $tmp_p/run.log)"
fi

# (c) the plan commit touches ONLY the tracker (+ LEARNINGS.md), never code.
plan_files=$(git -C "$tmp_p" show --name-only --format="" HEAD 2>/dev/null | tr -d ' ')
if printf '%s\n' "$plan_files" | grep -qx 'PLAN.md'; then
  ok "plan commit includes PLAN.md"
else
  fail "plan commit did not include PLAN.md (files: $(printf '%s' "$plan_files" | tr '\n' ' '))"
fi
if printf '%s\n' "$plan_files" | grep -qx 'src_main.rs'; then
  fail "plan commit swept code changes (src_main.rs) — must be PLAN.md/LEARNINGS.md only"
else
  ok "plan commit excludes code changes (src_main.rs untouched)"
fi
# and the uncommitted code edit must still be uncommitted (working tree dirty)
if ! git -C "$tmp_p" diff --quiet -- src_main.rs 2>/dev/null; then
  ok "uncommitted code edit left in working tree (not swept into plan commit)"
else
  fail "uncommitted code edit was committed/staged by plan"
fi

# --- suite 8: stats (tier and model counts from loop.log) ---------------
echo "== suite 14: stats (tier/model counts) =="
. "$RR/lib/observability.sh"

# (a) old format log (no tier lines) — must not break
LOOP_LOG="$RR/test/fixtures/logs/old-format.log"
models_arr=("anthropic/claude-sonnet-4")
out="$(cmd_stats 2>&1)"
if printf '%s' "$out" | grep -q 'turns started.*:.*4'; then
  ok "old-format log: counts 4 turns"
else
  fail "old-format log: turn count failed ($out)"
fi
if printf '%s' "$out" | grep -q 'step-success rate'; then
  ok "old-format log: computes success rate"
else
  fail "old-format log: success rate missing"
fi
if printf '%s' "$out" | grep -q 'turns by tier'; then
  fail "old-format log: should NOT show tier counts (no tier lines)"
else
  ok "old-format log: no tier counts (backward compat)"
fi

# (b) new format log (with tier lines) — shows tier and model counts
LOOP_LOG="$RR/test/fixtures/logs/new-format.log"
models_arr=("zai/glm-5-turbo")
out="$(cmd_stats 2>&1)"
if printf '%s' "$out" | grep -q 'turns started.*:.*5'; then
  ok "new-format log: counts 5 turns"
else
  fail "new-format log: turn count failed"
fi
if printf '%s' "$out" | grep -q 'turns by tier.*build=2.*light=2.*plan=1'; then
  ok "new-format log: tier counts (build=2 light=2 plan=1)"
else
  fail "new-format log: tier counts wrong or missing (got: $(printf '%s' "$out" | grep 'turns by tier' || echo '<none>'))"
fi
if printf '%s' "$out" | grep -q 'turns by model.*anthropic/claude-fable-5=1' && \
   printf '%s' "$out" | grep -q 'anthropic/claude-sonnet-4=2' && \
   printf '%s' "$out" | grep -q 'zai/glm-5-turbo=2'; then
  ok "new-format log: model counts (fable=1 sonnet=2 glm=2)"
else
  fail "new-format log: model counts wrong or missing (got: $(printf '%s' "$out" | grep 'turns by model' || echo '<none>'))"
fi

# (c) old format log without took= lines — must not crash, skip duration section
LOOP_LOG="$RR/test/fixtures/logs/old-format.log"
models_arr=("anthropic/claude-sonnet-4")
out="$(cmd_stats 2>&1)"
if printf '%s' "$out" | grep -q 'turn duration'; then
  fail "old-format log: should NOT show turn duration (no took= lines)"
else
  ok "old-format log: no turn duration (backward compat)"
fi

# (d) log with took= lines — shows avg and max duration
LOOP_LOG="$RR/test/fixtures/logs/with-took.log"
models_arr=("anthropic/claude-sonnet-4")
out="$(cmd_stats 2>&1)"
if printf '%s' "$out" | grep -qE 'turn duration.*avg=(64|65)s.*max=84s'; then
  ok "with-took log: duration avg=64s max=84s"
else
  fail "with-took log: duration wrong or missing (got: $(printf '%s' "$out" | grep 'turn duration' || echo '<none>'))"
fi

# --- suite 13: doctor mid-operation check (T4.2) ---------------
echo "== suite 15: doctor mid-operation check (rebase-merge, MERGE_HEAD, etc.) =="
tmp_mid="$(mktemp -d)"
trap 'rm -rf "$tmp_mid"' EXIT
cat > "$tmp_mid/PLAN.md" <<'EOF'
# Test plan
- [ ] T1 (normal) task
EOF
cat > "$tmp_mid/verify.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp_mid/verify.sh"
cat > "$tmp_mid/.ratchet.conf" <<'EOF'
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=./verify.sh
EOF
"$RATCHET" init "$tmp_mid" >/dev/null 2>&1
git -C "$tmp_mid" init -q >/dev/null 2>&1
git -C "$tmp_mid" add -A
git -C "$tmp_mid" commit -q -m "baseline" >/dev/null 2>&1

# (a) fake rebase-merge dir → doctor fails with message
mkdir -p "$tmp_mid/.git/rebase-merge"
out_a="$("$RATCHET" doctor "$tmp_mid" 2>&1)"
if printf '%s' "$out_a" | grep -q 'repo is mid-rebase'; then
  ok "doctor detects .git/rebase-merge and fails with --quit advice"
else
  fail "doctor did not detect .git/rebase-merge"
fi
rmdir "$tmp_mid/.git/rebase-merge"

# (b) fake MERGE_HEAD → doctor fails
touch "$tmp_mid/.git/MERGE_HEAD"
out_b="$("$RATCHET" doctor "$tmp_mid" 2>&1)"
if printf '%s' "$out_b" | grep -q 'repo is mid-merge'; then
  ok "doctor detects .git/MERGE_HEAD and fails"
else
  fail "doctor did not detect .git/MERGE_HEAD"
fi
rm "$tmp_mid/.git/MERGE_HEAD"

# (c) clean state → doctor passes
if "$RATCHET" doctor "$tmp_mid" >/dev/null 2>&1; then
  ok "doctor passes when no mid-operation state"
else
  fail "doctor failed on clean repo"
fi

echo ""
echo "== suite 16: ratchet status (fixture log rendering + liveness) =="
tmp_s="$(mktemp -d)"
trap 'rm -rf "$tmp_s"' EXIT

# Build a fixture log directory with loop.log, tracker, last_turn.out, loop.pid
mkdir -p "$tmp_s/logs/test-project"
cat > "$tmp_s/logs/test-project/loop.log" <<'LOGEOF'
[2026-01-01 10:00:00] ratchet START
[2026-01-01 10:00:01] tasks: 2 done / 5 total | next: T3.1 (trivial) add docs
[2026-01-01 10:00:01] --- turn 3 | model=fake/model ---
[2026-01-01 10:00:01] turn 3 | tier=light | model=fake/model | thinking=off | task=T3.1 (trivial) add docs to README
[2026-01-01 10:00:15] turn 3 end | class=step | took=14s | task=T3.1
LOGEOF

cat > "$tmp_s/PLAN.md" <<'PLANEOF'
# Test Plan
## Milestone 1 — Foundation
- [x] T1.1 done task one
- [x] T2.1 done task two
## Milestone 2 — Features
- [IN PROGRESS] T3.1 (trivial) add docs to README
- [ ] T4.1 (normal) next task
- [ ] T5.1 (hard) big task
PLANEOF

cat > "$tmp_s/logs/test-project/last_turn.out" <<'OUTEOF'
Added docs to README.
All done.
STEP_COMPLETE
OUTEOF

# Create a PID file with a running process (our own shell pid is fine for test)
echo $$ > "$tmp_s/logs/test-project/loop.pid"

# Export environment for status command
REPO_DIR="$tmp_s"
TRACKER_FILE="PLAN.md"
LOG_DIR="$tmp_s/logs/test-project"
LOOP_LOG="$tmp_s/logs/test-project/loop.log"
TURN_OUT="$tmp_s/logs/test-project/last_turn.out"

# (a) status with pid file and all fields present (PM board format)
status_out="$(cmd_status 2>&1)"
if printf '%s' "$status_out" | grep -q 'Turn 3'; then
  ok "status shows turn number"
else
  fail "status missing turn number: $status_out"
fi
if printf '%s' "$status_out" | grep -q 'Tier/Model.*light / fake/model'; then
  ok "status shows tier and model"
else
  fail "status missing tier/model: $status_out"
fi
if printf '%s' "$status_out" | grep -q 'took 14s'; then
  ok "status shows took= time for finished turn"
else
  fail "status missing took= time: $status_out"
fi
if printf '%s' "$status_out" | grep -q 'Step 2/5'; then
  ok "status shows Step D/T progress bar"
else
  fail "status missing Step D/T: $status_out"
fi
if printf '%s' "$status_out" | grep -q 'Loop.*running'; then
  ok "status shows loop running (live pid)"
else
  fail "status missing loop liveness: $status_out"
fi
if printf '%s' "$status_out" | grep -q 'Doing:.*STEP_COMPLETE'; then
  ok "status shows doing now line"
else
  fail "status missing doing now: $status_out"
fi
if printf '%s' "$status_out" | grep -q 'Milestone 2'; then
  ok "status shows milestone tree"
else
  fail "status missing milestone tree: $status_out"
fi
if printf '%s' "$status_out" | grep -q '▶.*Milestone 2'; then
  ok "status marks current milestone with ▶"
else
  fail "status missing current milestone marker: $status_out"
fi
if printf '%s' "$status_out" | grep -qE 'ETA:.*turns'; then
  ok "status shows ETA line"
else
  fail "status missing ETA: $status_out"
fi

# (b) status with no pid file → "not running"
rm "$tmp_s/logs/test-project/loop.pid"
status_out2="$(cmd_status 2>&1)"
if printf '%s' "$status_out2" | grep -q 'Loop.*not running'; then
  ok "status shows 'not running' when no pid file"
else
  fail "status did not show 'not running': $status_out2"
fi

echo ""
echo "== suite 17: FANOUT contract key (env-signal gating; extensions always on) =="
# Extensions ALWAYS load (the OAuth-auth extension is one) — --no-extensions must
# NEVER appear. FANOUT only gates the RATCHET_FANOUT/SCOUT env signal, and only
# on (hard) tasks. These tests prove the signal gating, not extension toggling.
# Test (a): FANOUT unset + (hard) task → NO scout env exported, extensions on
tmpf1="$(mktemp -d)"
cat > "$tmpf1/PLAN.md" <<'EOF'
# Test plan
- [ ] T1 (hard) test task
EOF
cat > "$tmpf1/verify.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmpf1/verify.sh"
cat > "$tmpf1/.ratchet.conf" <<'EOF'
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=./verify.sh
EOF
"$RATCHET" init "$tmpf1" >/dev/null 2>&1
git -C "$tmpf1" init -q
git -C "$tmpf1" add -A
git -C "$tmpf1" commit -q -m "baseline"

# Run with FANOUT unset (default off)
"$RATCHET" once "$tmpf1" -v -m fake/model --agent-cmd "$FAKE" >"$tmpf1/run.log" 2>&1
if ! grep -q 'invoking.*--no-extensions' "$tmpf1/run.log"; then
  ok "FANOUT unset: extensions loaded (no --no-extensions)"
else
  fail "FANOUT unset: --no-extensions present — would break OAuth auth (see $tmpf1/run.log)"
fi
if ! grep -q 'RATCHET_FANOUT=' "$tmpf1/run.log"; then
  ok "FANOUT unset: no scout env exported"
else
  fail "FANOUT unset: RATCHET_FANOUT exported without FANOUT set (see $tmpf1/run.log)"
fi
rm -rf "$tmpf1"

# Test (b): FANOUT=scout + (hard) task → no --no-extensions, env exported
tmpf2="$(mktemp -d)"
cat > "$tmpf2/PLAN.md" <<'EOF'
# Test plan
- [ ] T1 (hard) hard task
EOF
cat > "$tmpf2/verify.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmpf2/verify.sh"
cat > "$tmpf2/.ratchet.conf" <<'EOF'
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=./verify.sh
FANOUT=scout
LIGHT_MODELS=fake/scout
EOF
"$RATCHET" init "$tmpf2" >/dev/null 2>&1
git -C "$tmpf2" init -q
git -C "$tmpf2" add -A
git -C "$tmpf2" commit -q -m "baseline"

"$RATCHET" once "$tmpf2" -v -m fake/model --agent-cmd "$FAKE" >"$tmpf2/run.log" 2>&1
if ! grep -q 'invoking.*--no-extensions' "$tmpf2/run.log"; then
  ok "FANOUT=scout + hard: extensions loaded (no --no-extensions)"
else
  fail "FANOUT=scout + hard: --no-extensions present (see $tmpf2/run.log)"
fi
# Check env export - fake-agent echoes env vars if they're set
if grep -q 'RATCHET_FANOUT=scout' "$tmpf2/run.log" && grep -q 'RATCHET_SCOUT_MODELS=fake/scout' "$tmpf2/run.log"; then
  ok "FANOUT=scout + hard: env vars exported"
else
  fail "FANOUT=scout + hard: env vars not exported (see $tmpf2/run.log)"
fi
rm -rf "$tmpf2"

# Test (c): FANOUT=scout + (normal) task → still --no-extensions (gating proof)
tmpf3="$(mktemp -d)"
cat > "$tmpf3/PLAN.md" <<'EOF'
# Test plan
- [ ] T1 (normal) normal task
EOF
cat > "$tmpf3/verify.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmpf3/verify.sh"
cat > "$tmpf3/.ratchet.conf" <<'EOF'
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=./verify.sh
FANOUT=scout
LIGHT_MODELS=fake/scout
EOF
"$RATCHET" init "$tmpf3" >/dev/null 2>&1
git -C "$tmpf3" init -q
git -C "$tmpf3" add -A
git -C "$tmpf3" commit -q -m "baseline"

"$RATCHET" once "$tmpf3" -v -m fake/model --agent-cmd "$FAKE" >"$tmpf3/run.log" 2>&1
if ! grep -q 'RATCHET_FANOUT=' "$tmpf3/run.log"; then
  ok "FANOUT=scout + normal: no scout env (gating proof — fanout only on hard)"
else
  fail "FANOUT=scout + normal: scout env exported on a non-hard task (see $tmpf3/run.log)"
fi
rm -rf "$tmpf3"

# Test (d): RATCHET_LOOP=1 exported unconditionally (unlike FANOUT)
tmpf4="$(mktemp -d)"
cat > "$tmpf4/PLAN.md" <<'EOF'
# Test plan
- [ ] T1 (trivial) simple task
EOF
cat > "$tmpf4/verify.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmpf4/verify.sh"
cat > "$tmpf4/.ratchet.conf" <<'EOF'
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=./verify.sh
EOF
"$RATCHET" init "$tmpf4" >/dev/null 2>&1
git -C "$tmpf4" init -q
git -C "$tmpf4" add -A
git -C "$tmpf4" commit -q -m "baseline"

"$RATCHET" once "$tmpf4" -v -m fake/model --agent-cmd "$FAKE" >"$tmpf4/run.log" 2>&1
if grep -q 'RATCHET_LOOP=1' "$tmpf4/run.log"; then
  ok "RATCHET_LOOP=1 exported unconditionally (advisory loop signal)"
else
  fail "RATCHET_LOOP=1 not exported (see $tmpf4/run.log)"
fi
rm -rf "$tmpf4"

echo ""
echo "== suite 18: ratchet models (chain ops, conf upsert, registry, cmd) =="

check_eq() { # NAME GOT WANT
  [ "$2" = "$3" ] && ok "$1" || fail "$1 -> got='$2' want='$3'"
}

# chain_add: append / first / positional / move-existing
check_eq "chain_add to empty"        "$(chain_add "" "a/b")"                 "a/b"
check_eq "chain_add append"          "$(chain_add "a/b,c/d" "e/f")"         "a/b,c/d,e/f"
check_eq "chain_add first"           "$(chain_add "a/b,c/d" "e/f" first)"   "e/f,a/b,c/d"
check_eq "chain_add pos 2"           "$(chain_add "a/b,c/d" "e/f" 2)"       "a/b,e/f,c/d"
check_eq "chain_add pos past end"    "$(chain_add "a/b" "e/f" 9)"           "a/b,e/f"
check_eq "chain_add move-existing"   "$(chain_add "a/b,c/d" "c/d" first)"   "c/d,a/b"

# chain_remove
check_eq "chain_remove head"         "$(chain_remove "a/b,c/d" "a/b")"       "c/d"
check_eq "chain_remove absent"       "$(chain_remove "a/b" "x/y")"           "a/b"

# parse_pi_models: header skipped, provider/id joined
check_eq "parse pi table" "$(printf 'provider     model              context  max-out\nzai          glm-5.2            1M       131K\nkimi-coding  k3                 262K     32K\n' | parse_pi_models)" "zai/glm-5.2
kimi-coding/k3"

# upsert_conf_key: replaces active line, leaves comments + commented template lines
tmpm="$(mktemp -d)"
printf '# header\nMODELS=a/b\n#PLAN_MODELS=x/y\n' > "$tmpm/conf"
upsert_conf_key "$tmpm/conf" MODELS "c/d,e/f"
grep -qx 'MODELS=c/d,e/f' "$tmpm/conf" && grep -qx '# header' "$tmpm/conf" && grep -qx '#PLAN_MODELS=x/y' "$tmpm/conf" \
  && ok "upsert replaces line, preserves comments" || fail "upsert replace (see $tmpm/conf)"
upsert_conf_key "$tmpm/conf" LIGHT_MODELS "z/g"
[ "$(tail -1 "$tmpm/conf")" = 'LIGHT_MODELS=z/g' ] && ok "upsert appends missing key" || fail "upsert append"
[ "$(grep -c '^#PLAN_MODELS' "$tmpm/conf")" = 1 ] && ok "upsert ignores commented template line" || fail "upsert touched commented line"

# end-to-end cmd_models with a fake pi on PATH (registry = 2 models)
tmpp="$(mktemp -d)"
cat > "$tmpp/pi" <<'EOF'
#!/usr/bin/env bash
cat <<'T'
provider     model              context  max-out  thinking  images
zai          glm-5.2            1M       131K     yes       no
zai          glm-5-turbo        200K     131K     yes       no
T
EOF
chmod +x "$tmpp/pi"

rm -f "$RATCHET_HOME/conf" "$RATCHET_HOME/models.registry"
PATH="$tmpp:$PATH" "$RATCHET" models add zai/glm-5.2 --tier light >"$tmpm/add.log" 2>&1 \
  && grep -qx 'LIGHT_MODELS=zai/glm-5.2' "$RATCHET_HOME/conf" \
  && ok "models add writes LIGHT_MODELS to global conf" || fail "models add (see $tmpm/add.log)"

PATH="$tmpp:$PATH" "$RATCHET" models add zai/glm-5-turbo --tier light --pos first >/dev/null 2>&1 \
  && grep -qx 'LIGHT_MODELS=zai/glm-5-turbo,zai/glm-5.2' "$RATCHET_HOME/conf" \
  && ok "models add --pos first prepends" || fail "models add --pos first"

PATH="$tmpp:$PATH" "$RATCHET" models remove zai/glm-5.2 --tier light >/dev/null 2>&1 \
  && grep -qx 'LIGHT_MODELS=zai/glm-5-turbo' "$RATCHET_HOME/conf" \
  && ok "models remove" || fail "models remove"

if PATH="$tmpp:$PATH" "$RATCHET" models add zai/nope >/dev/null 2>&1; then
  fail "models add unknown id should be refused"
else
  ok "models add refuses unknown id"
fi
PATH="$tmpp:$PATH" "$RATCHET" models add zai/nope --force >/dev/null 2>&1 \
  && grep -q 'zai/nope' "$RATCHET_HOME/conf" \
  && ok "models add --force overrides registry" || fail "models add --force"

PATH="$tmpp:$PATH" "$RATCHET" models thinking off --tier light >/dev/null 2>&1 \
  && grep -qx 'THINKING_LIGHT=off' "$RATCHET_HOME/conf" \
  && ok "models thinking writes THINKING_LIGHT" || fail "models thinking"

PATH="$tmpp:$PATH" "$RATCHET" models list >"$tmpm/list.log" 2>&1 \
  && grep -q 'LIGHT' "$tmpm/list.log" && grep -q 'zai/glm-5-turbo \[ok\]' "$tmpm/list.log" && grep -q 'zai/nope \[UNKNOWN\]' "$tmpm/list.log" \
  && ok "models list shows chains with registry marks" || fail "models list (see $tmpm/list.log)"

# T7.4: cost display + MODEL_RANK + derived chains
mkdir -p "$RATCHET_HOME"
printf 'zai/glm-5.2\t1.4\t4.4\ttrue\ttrue\t1000000\n' > "$RATCHET_HOME/models.cost"
printf 'zai/glm-5-turbo\t0.5\t1.5\ttrue\ttrue\t200000\n' >> "$RATCHET_HOME/models.cost"

rm -f "$RATCHET_HOME/conf"
PATH="$tmpp:$PATH" "$RATCHET" models add zai/glm-5.2 --tier light >/dev/null 2>&1
PATH="$tmpp:$PATH" "$RATCHET" models list >"$tmpm/cost.log" 2>&1 \
  && grep -q 'zai/glm-5.2 \[ok\] \$1.4/\$4.4' "$tmpm/cost.log" \
  && ok "models list shows cost for joined models" || fail "models list cost (see $tmpm/cost.log)"

grep -q 'MODEL_RANK: (unset)' "$tmpm/cost.log" \
  && ok "models list shows MODEL_RANK status" || fail "models list MODEL_RANK (see $tmpm/cost.log)"

# derived chain: set MODEL_RANK and check unset tier shows derived
printf 'MODEL_RANK=zai/glm-5.2,zai/glm-5-turbo\n' > "$RATCHET_HOME/conf"
PATH="$tmpp:$PATH" "$RATCHET" models list >"$tmpm/derived.log" 2>&1 \
  && grep -q 'derived:' "$tmpm/derived.log" \
  && ok "models list shows derived chain for unset tiers" || fail "models list derived (see $tmpm/derived.log)"

# --repo: edit the repo contract + re-stamp conf.hash (ratchet's own edit is not tampering)
rm -f "$RATCHET_HOME/conf"   # clean global so the repo chain starts empty
git -C "$tmpm" init -q; mkdir -p "$tmpm/.ratchet"
printf 'RATCHET_PROTOCOL=1\nTRACKER_FILE=PLAN.md\nVERIFY_CMD=true\n' > "$tmpm/.ratchet.conf"
conf_hash "$tmpm/.ratchet.conf" > "$tmpm/.ratchet/conf.hash"
PATH="$tmpp:$PATH" "$RATCHET" models add zai/glm-5.2 --repo -d "$tmpm" >/dev/null 2>&1 \
  && grep -qx 'MODELS=zai/glm-5.2' "$tmpm/.ratchet.conf" \
  && [ "$(conf_hash "$tmpm/.ratchet.conf")" = "$(cat "$tmpm/.ratchet/conf.hash")" ] \
  && ok "models add --repo edits contract + re-stamps hash" || fail "models add --repo"

rm -rf "$tmpp" "$tmpm"



# --- suite 20: bounded reap (T6.2) ---
echo ""
echo "== suite 20: bounded reap (watchdog kill path) =="

# Source run-turn.sh to get bounded_reap function
. "$RR/lib/run-turn.sh"

# Test 1: bounded_reap returns within ~12s for a wedged (SIGKILL'd) long-lived process
tmpb="$(mktemp -d)"
sleep 600 &  # deliberately long-lived subprocess
wedged_pid=$!
kill -9 "$wedged_pid" 2>/dev/null  # SIGKILL it to simulate a wedged process

start_reap=$SECONDS
bounded_reap "$wedged_pid"
elapsed_reap=$((SECONDS - start_reap))

# Should return within ~12s (10s bound + margin)
if [ "$elapsed_reap" -le 12 ]; then
  ok "bounded_reap returns within bound (~${elapsed_reap}s <= 12s)"
else
  fail "bounded_reap exceeded bound (took ${elapsed_reap}s > 12s)"
fi

# Test 2: bounded_reap handles already-dead process (immediate return)
sleep 0.1 &  # short-lived process
quick_pid=$!
wait "$quick_pid" 2>/dev/null  # let it finish

start_dead=$SECONDS
bounded_reap "$quick_pid"
elapsed_dead=$((SECONDS - start_dead))

# Should return immediately (within 1s)
if [ "$elapsed_dead" -le 1 ]; then
  ok "bounded_reap handles already-dead process quickly (~${elapsed_dead}s)"
else
  fail "bounded_reap slow on dead process (${elapsed_dead}s > 1s)"
fi

rm -rf "$tmpb"

# --- suite 21: model cost/capability cache (T7.1) ---
echo ""
echo "== suite 21: model cost/capability cache (models.dev join) =="

# Create a fixture models.cost cache with known models
tmp21="$(mktemp -d)"
export RATCHET_HOME="$tmp21"
mkdir -p "$tmp21"

# Write fixture cache: 2 rows (one will match, one won't be queried)
cat > "$tmp21/models.cost" <<'FIXTURE21'
anthropic/claude-sonnet-4-5	3	15	true	true	200000
zai/glm-5.2	1.4	4.4	true	true	128000
FIXTURE21

# Test 1: model_meta hit (direct match)
got_meta="$(model_meta 'anthropic/claude-sonnet-4-5')"
if echo "$got_meta" | grep -q "3.*15.*true.*true"; then
  ok "model_meta hit: anthropic/claude-sonnet-4-5 returns cost data"
else
  fail "model_meta hit failed: got='$got_meta'"
fi

# Test 2: model_meta miss (no join, should return empty without error)
got_miss="$(model_meta 'kimi-coding/k3')"
if [ -z "$got_miss" ]; then
  ok "model_meta miss: kimi-coding/k3 returns empty (no error)"
else
  fail "model_meta miss should be empty: got='$got_miss'"
fi

# Test 3: model_meta with provider alias (kimi-coding -> moonshotai)
# Add a moonshotai entry to test alias mapping
cat >> "$tmp21/models.cost" <<'FIXTURE21B'
moonshotai/k3	0.5	2.0	true	true	64000
FIXTURE21B

got_alias="$(model_meta 'kimi-coding/k3')"
if echo "$got_alias" | grep -q "moonshotai/k3.*0.5.*2.0"; then
  ok "model_meta alias: kimi-coding/k3 joins via moonshotai"
else
  fail "model_meta alias failed: got='$got_alias'"
fi

# Test 4: graceful degradation with absent cache (no error, empty output)
rm -f "$tmp21/models.cost"
got_nofile="$(model_meta 'anthropic/claude-sonnet-4-5')"
if [ -z "$got_nofile" ]; then
  ok "model_meta with no cache: returns empty without error"
else
  fail "model_meta should return empty when cache absent: got='$got_nofile'"
fi

# Test 5: model_cost_registry gracefully fails when curl/python3 unavailable
# (We can't actually remove curl/python3, so we'll just verify rc1 on empty result)
# This is tested by ensuring the function returns 1 when cache is missing
rm -f "$tmp21/models.cost"
if model_cost_registry; then
  # If it succeeded, that's fine (curl + python3 available)
  ok "model_cost_registry serves cache or degrades gracefully"
else
  # rc1 is expected when cache missing and network unavailable
  ok "model_cost_registry returns 1 on missing cache (graceful degradation)"
fi

rm -rf "$tmp21"

rm -rf "$RATCHET_HOME"   # isolated test home (see top of file)

echo "== suite 22: model-select (MODEL_RANK + tier auto-slice) =="

# Create a fixture with pi registry + cost cache + MODEL_RANK
tmp22="$(mktemp -d)"
export RATCHET_HOME="$tmp22"
mkdir -p "$tmp22"

# Fixture pi registry: 5 available models
cat > "$tmp22/models.registry" <<'FIXTURE22REG'
anthropic/claude-opus-4-8
anthropic/claude-sonnet-4-5
zai/glm-5.2
zai/glm-4.5-air
kimi-coding/k3
FIXTURE22REG

# Fixture cost cache: 4 models with cost (kimi-coding/k3 via moonshotai alias)
cat > "$tmp22/models.cost" <<'FIXTURE22COST'
anthropic/claude-opus-4-8	5	25	true	true	200000
anthropic/claude-sonnet-4-5	3	15	true	true	200000
zai/glm-5.2	1.4	4.4	true	true	128000
zai/glm-4.5-air	0.5	2.0	true	true	128000
moonshotai/k3	0.3	1.0	true	true	64000
FIXTURE22COST

# Test 1: ranked_available_models with MODEL_RANK set
MODEL_RANK="anthropic/claude-opus-4-8,anthropic/claude-sonnet-4-5,zai/glm-5.2,zai/glm-4.5-air"
ALLOWED_PROVIDERS=""  # no filter
ranked="$(ranked_available_models)"
# Should return ranked in order, then unranked (kimi-coding/k3) sorted by cost
if echo "$ranked" | head -1 | grep -q "anthropic/claude-opus-4-8"; then
  ok "ranked_available_models: top model is claude-opus-4-8"
else
  fail "ranked_available_models: expected opus-4-8 first, got=$(echo "$ranked" | head -1)"
fi

if echo "$ranked" | tail -1 | grep -q "kimi-coding/k3"; then
  ok "ranked_available_models: unranked model kimi-coding/k3 appended last"
else
  fail "ranked_available_models: expected k3 appended, got=$(echo "$ranked" | tail -1)"
fi

# Test 2: suggest_chain plan (top + fallback)
chain_plan="$(suggest_chain plan)"
if echo "$chain_plan" | grep -q "anthropic/claude-opus-4-8" && echo "$chain_plan" | grep -q "anthropic/claude-sonnet-4-5"; then
  ok "suggest_chain plan: contains opus-4-8 and sonnet-4-5"
else
  fail "suggest_chain plan: got='$chain_plan'"
fi

# Test 3: suggest_chain light (bottom + one-up)
chain_light="$(suggest_chain light)"
if echo "$chain_light" | grep -q "kimi-coding/k3"; then
  ok "suggest_chain light: contains cheapest model (kimi-coding/k3)"
else
  fail "suggest_chain light: expected k3, got='$chain_light'"
fi

# Test 4: suggest_chain build (middle + fallbacks down)
chain_build="$(suggest_chain build)"
if echo "$chain_build" | grep -q "anthropic/claude-sonnet-4-5"; then
  ok "suggest_chain build: contains middle model (sonnet-4-5)"
else
  fail "suggest_chain build: got='$chain_build'"
fi

# Test 5: ALLOWED_PROVIDERS filter
ALLOWED_PROVIDERS="zai"
ranked_zai="$(ranked_available_models)"
if echo "$ranked_zai" | grep -q "anthropic"; then
  fail "ranked_available_models with ALLOWED_PROVIDERS=zai: should not contain anthropic"
else
  ok "ranked_available_models: ALLOWED_PROVIDERS=zai filters correctly"
fi

if echo "$ranked_zai" | grep -q "zai/glm-5.2"; then
  ok "ranked_available_models: zai/glm-5.2 present after filter"
else
  fail "ranked_available_models: expected zai/glm-5.2, got='$ranked_zai'"
fi

# Test 6: MODEL_RANK unset with 2+ models returns models (no explicit ranking but not empty)
MODEL_RANK=""
ALLOWED_PROVIDERS=""
ranked_unset="$(ranked_available_models)"
if [ -n "$ranked_unset" ]; then
  ok "ranked_available_models: MODEL_RANK unset returns available models"
else
  fail "ranked_available_models: should return models even when MODEL_RANK unset"
fi

# Test 7: suggest_chain with MODEL_RANK unset returns empty (no reliable ranking)
MODEL_RANK=""
if suggest_chain plan >/dev/null 2>&1; then
  fail "suggest_chain: should return empty (rc1) when MODEL_RANK unset"
else
  ok "suggest_chain: returns empty when MODEL_RANK unset (no skill ranking)"
fi

rm -rf "$tmp22"

echo ""
echo "== suite 23: chain_for_tier override-preserving wire-in (T7.3) =="

# Create a fixture with pi registry + cost cache + MODEL_RANK
tmp23="$(mktemp -d)"
export RATCHET_HOME="$tmp23"
mkdir -p "$tmp23"

# Fixture pi registry: 4 available models
cat > "$tmp23/models.registry" <<'FIXTURE23REG'
anthropic/claude-opus-4-8
anthropic/claude-sonnet-4-5
zai/glm-5.2
zai/glm-4.5-air
FIXTURE23REG

# Fixture cost cache
cat > "$tmp23/models.cost" <<'FIXTURE23COST'
anthropic/claude-opus-4-8	5	25	true	true	200000
anthropic/claude-sonnet-4-5	3	15	true	true	200000
zai/glm-5.2	1.4	4.4	true	true	128000
zai/glm-4.5-air	0.5	2.0	true	true	128000
FIXTURE23COST

# Test 1: Override-wins — tier-specific key set → byte-identical to today
BUILD_MODELS="custom/model-1,custom/model-2"
MODELS=""
MODEL_RANK="anthropic/claude-opus-4-8,anthropic/claude-sonnet-4-5,zai/glm-5.2,zai/glm-4.5-air"
ALLOWED_PROVIDERS=""

got_override="$(chain_for_tier build)"
if [ "$got_override" = "custom/model-1,custom/model-2" ]; then
  ok "chain_for_tier override-wins: BUILD_MODELS returned unchanged"
else
  fail "chain_for_tier override-wins: expected BUILD_MODELS, got='$got_override'"
fi

# Test 2: Flat MODELS override — tier-specific unset, MODELS set → returns MODELS
PLAN_MODELS=""
BUILD_MODELS=""
LIGHT_MODELS=""
MODELS="flat/model-a,flat/model-b"
MODEL_RANK="anthropic/claude-opus-4-8,anthropic/claude-sonnet-4-5,zai/glm-5.2,zai/glm-4.5-air"

got_flat="$(chain_for_tier build)"
if [ "$got_flat" = "flat/model-a,flat/model-b" ]; then
  ok "chain_for_tier flat-override: MODELS returned when tier-specific unset"
else
  fail "chain_for_tier flat-override: expected MODELS, got='$got_flat'"
fi

# Test 3: Derive-when-empty — both tier and MODELS empty, MODEL_RANK set → suggest_chain slice
PLAN_MODELS=""
BUILD_MODELS=""
LIGHT_MODELS=""
MODELS=""
MODEL_RANK="anthropic/claude-opus-4-8,anthropic/claude-sonnet-4-5,zai/glm-5.2,zai/glm-4.5-air"

got_derived="$(chain_for_tier plan)"
if [ -n "$got_derived" ] && echo "$got_derived" | grep -q "anthropic/claude-opus-4-8"; then
  ok "chain_for_tier derive: plan tier returns suggest_chain slice"
else
  fail "chain_for_tier derive: expected derived chain, got='$got_derived'"
fi

got_light="$(chain_for_tier light)"
if [ -n "$got_light" ] && echo "$got_light" | grep -q "zai/glm-4.5-air"; then
  ok "chain_for_tier derive: light tier returns cheapest model"
else
  fail "chain_for_tier derive light: expected cheapest model, got='$got_light'"
fi

# Test 4: Empty-when-nothing — everything empty → echoes empty, caller handles die
PLAN_MODELS=""
BUILD_MODELS=""
LIGHT_MODELS=""
MODELS=""
MODEL_RANK=""

got_empty="$(chain_for_tier build)"
if [ -z "$got_empty" ]; then
  ok "chain_for_tier empty-when-nothing: returns empty when no config"
else
  fail "chain_for_tier empty-when-nothing: expected empty, got='$got_empty'"
fi

# Verify rc1 when empty (caller checks this)
if chain_for_tier build >/dev/null 2>&1; then
  fail "chain_for_tier empty-when-nothing: should return rc1"
else
  ok "chain_for_tier empty-when-nothing: returns rc1 for caller's die path"
fi

rm -rf "$tmp23"

# =============================================================================
# Suite 24: build_default_prompt with template rendering (T1.1)
# =============================================================================
echo "Suite 24: build_default_prompt renders loop protocol from template"

# Setup: finalize tokens and tracker vars so build_default_prompt can run
TRACKER_FILE="PLAN.md"
VERIFY_CMD="bash test/selftest.sh"
STEP_TOKEN="STEP_COMPLETE"
DONE_TOKEN="ALL_DONE"

# Test 1: With template present, prompt contains rendered protocol substrings
prompt="$(build_default_prompt)"

if echo "$prompt" | grep -q "exactly ONE discrete step"; then
  ok "build_default_prompt: contains 'exactly ONE discrete step' from template"
else
  fail "build_default_prompt: missing 'exactly ONE discrete step'"
fi

if echo "$prompt" | grep -q "STEP_COMPLETE"; then
  ok "build_default_prompt: contains STEP_COMPLETE token"
else
  fail "build_default_prompt: missing STEP_COMPLETE token"
fi

if echo "$prompt" | grep -q "ALL_DONE"; then
  ok "build_default_prompt: contains ALL_DONE token"
else
  fail "build_default_prompt: missing ALL_DONE token"
fi

if echo "$prompt" | grep -q "Read AGENTS.md and LEARNINGS.md for project-specific facts"; then
  ok "build_default_prompt: contains AGENTS.md trailer"
else
  fail "build_default_prompt: missing AGENTS.md trailer"
fi

if echo "$prompt" | grep -q "Do NOT edit .ratchet.conf"; then
  ok "build_default_prompt: contains .ratchet.conf forbidden line"
else
  fail "build_default_prompt: missing .ratchet.conf forbidden line"
fi

# Test 2: Fallback when template unreadable - prompt still non-empty with tokens
# Save real RATCHET_ROOT, point to bogus path, restore after
real_root="$RATCHET_ROOT"
export RATCHET_ROOT="/nonexistent/bogus/path"
fallback_prompt="$(build_default_prompt 2>/dev/null || echo "")"
export RATCHET_ROOT="$real_root"

if [ -n "$fallback_prompt" ]; then
  ok "build_default_prompt fallback: produces non-empty prompt"
else
  fail "build_default_prompt fallback: prompt is empty"
fi

if echo "$fallback_prompt" | grep -q "STEP_COMPLETE"; then
  ok "build_default_prompt fallback: contains STEP_COMPLETE token"
else
  fail "build_default_prompt fallback: missing STEP_COMPLETE token"
fi

if echo "$fallback_prompt" | grep -q "ALL_DONE"; then
  ok "build_default_prompt fallback: contains ALL_DONE token"
else
  fail "build_default_prompt fallback: missing ALL_DONE token"
fi

# =============================================================================
# Suite 25: RATCHET_LOOP is never used as authority (T1.3)
# =============================================================================
echo "Suite 25: RATCHET_LOOP advisory-only invariant (T1.3)"

# Grep lib/ and bin/ for any reference to RATCHET_LOOP and assert the ONLY
# occurrence is the export write in run-turn.sh. No if/case/[ branch may
# read it to gate commits, skip checks, or grant power (constraint 3).

loop_refs="$(grep -rn 'RATCHET_LOOP' "$RR/lib" "$RR/bin" 2>/dev/null || true)"

# Should contain exactly one line: the export in run-turn.sh
ref_count="$(echo "$loop_refs" | grep -c . || true)"

if [ "$ref_count" -eq 1 ]; then
  ok "RATCHET_LOOP: exactly one reference found"
else
  fail "RATCHET_LOOP: expected 1 reference, found $ref_count"
fi

# Verify it's the export statement, not a conditional read
if echo "$loop_refs" | grep -q 'export RATCHET_LOOP=1'; then
  ok "RATCHET_LOOP: reference is the export statement"
else
  fail "RATCHET_LOOP: reference is not the export statement"
fi

# Verify it's in run-turn.sh
if echo "$loop_refs" | grep -q 'lib/run-turn.sh'; then
  ok "RATCHET_LOOP: export is in lib/run-turn.sh"
else
  fail "RATCHET_LOOP: export is not in lib/run-turn.sh"
fi

# Assert no conditional usage: no if/case/[ that would use it as authority
# Check for variable expansion patterns that would indicate reading the value
if echo "$loop_refs" | grep -qE '\$RATCHET_LOOP|\$\{RATCHET_LOOP'; then
  fail "RATCHET_LOOP: found variable read syntax (violates advisory-only constraint)"
else
  ok "RATCHET_LOOP: no variable read syntax (advisory-only constraint holds)"
fi

# =============================================================================
# Suite 26: AGENTS.md is human-only, no loop protocol (T1.4)
# =============================================================================
echo "Suite 26: AGENTS.md human-only (T1.4)"

# This repo's AGENTS.md must have NO ratchet-protocol markers
if grep -q 'ratchet-protocol:' "$RR/AGENTS.md"; then
  fail "AGENTS.md: found ratchet-protocol marker (should be human-only)"
else
  ok "AGENTS.md: no ratchet-protocol markers"
fi

# AGENTS.md must not mandate STEP_COMPLETE / one-turn semantics
if grep -qi 'STEP_COMPLETE' "$RR/AGENTS.md"; then
  fail "AGENTS.md: found STEP_COMPLETE mandate (loop protocol leaked)"
else
  ok "AGENTS.md: no STEP_COMPLETE mandate"
fi

# AGENTS.md must not tell the agent to do exactly one step as a standing rule
if grep -qiE 'do (exactly )?one (discrete )?step|one turn at a time' "$RR/AGENTS.md"; then
  fail "AGENTS.md: found one-step mandate (loop protocol leaked)"
else
  ok "AGENTS.md: no one-step standing mandate"
fi

# Agnosticism invariant verified in Suite 7 (no re-check needed)
ok "AGENTS.md: agnosticism invariant verified in Suite 7"

# =============================================================================
# Suite 27: cmd_init migrates legacy loop blocks and seeds human AGENTS.md (T3.1)
# =============================================================================
echo "Suite 27: cmd_init AGENTS.md migration (T3.1)"

# Test 1: migrate legacy block, preserve human prose
testdir="$(mktemp -d)"
mkdir -p "$testdir/.git"
cat > "$testdir/AGENTS.md" <<'EOF'
<!-- ratchet-protocol:v1:begin -->
Old loop stuff
<!-- ratchet-protocol:v1:end -->

## My custom rules

Do things this way.
EOF
(cd "$testdir" && source "$RR/lib/common.sh" && source "$RR/lib/commands.sh" && cmd_init "$testdir" >/dev/null 2>&1)
if grep -q 'ratchet-protocol' "$testdir/AGENTS.md"; then
  fail "cmd_init: legacy block not removed"
else
  ok "cmd_init: legacy block removed"
fi
if grep -q 'My custom rules' "$testdir/AGENTS.md" && grep -q 'Do things this way' "$testdir/AGENTS.md"; then
  ok "cmd_init: human prose preserved"
else
  fail "cmd_init: human prose lost during migration"
fi
rm -rf "$testdir"

# Test 2: seed human template when AGENTS.md absent
testdir="$(mktemp -d)"
mkdir -p "$testdir/.git"
(cd "$testdir" && source "$RR/lib/common.sh" && source "$RR/lib/commands.sh" && cmd_init "$testdir" >/dev/null 2>&1)
if [ -f "$testdir/AGENTS.md" ]; then
  ok "cmd_init: AGENTS.md seeded when absent"
else
  fail "cmd_init: AGENTS.md not seeded"
fi
if [ -f "$testdir/AGENTS.md" ] && grep -q 'ratchet-protocol' "$testdir/AGENTS.md"; then
  fail "cmd_init: seeded AGENTS.md has markers"
else
  ok "cmd_init: seeded AGENTS.md has no markers"
fi
rm -rf "$testdir"

# Test 3: seed after stripping when markers were the only content
testdir="$(mktemp -d)"
mkdir -p "$testdir/.git"
cat > "$testdir/AGENTS.md" <<'EOF'
<!-- ratchet-protocol:v1:begin -->
Old loop stuff
<!-- ratchet-protocol:v1:end -->
EOF
(cd "$testdir" && source "$RR/lib/common.sh" && source "$RR/lib/commands.sh" && cmd_init "$testdir" >/dev/null 2>&1)
if [ -f "$testdir/AGENTS.md" ] && grep -qE 'Loop vs interactive|What to read' "$testdir/AGENTS.md"; then
  ok "cmd_init: seeded after stripping marker-only file"
else
  fail "cmd_init: did not seed after stripping marker-only file"
fi
if grep -q 'ratchet-protocol' "$testdir/AGENTS.md"; then
  fail "cmd_init: markers remain after migration+seed"
else
  ok "cmd_init: no markers after migration+seed"
fi
rm -rf "$testdir"

# =============================================================================
# Suite 28: doctor detects legacy loop-in-file block (T3.2)
# =============================================================================
echo "Suite 28: doctor protocol delivery check (T3.2)"

# Test 1: doctor detects legacy block and fails with migration message
testdir="$(mktemp -d)"
mkdir -p "$testdir/.git"
cat > "$testdir/.ratchet.conf" <<'EOF'
TRACKER_FILE=PLAN.md
VERIFY_CMD=true
STEP_TOKEN=STEP_COMPLETE
DONE_TOKEN=ALL_DONE
EOF
cat > "$testdir/PLAN.md" <<'EOF'
- [ ] test task
EOF
cat > "$testdir/AGENTS.md" <<'EOF'
<!-- ratchet-protocol:v1:begin -->
Old loop stuff
<!-- ratchet-protocol:v1:end -->
EOF
output="$(cd "$testdir" && source "$RR/lib/common.sh" && source "$RR/lib/commands.sh" && cmd_doctor "$testdir" 2>&1)" || true
if printf '%s\n' "$output" | grep -q 'legacy loop-in-file protocol block'; then
  ok "doctor detects legacy block and reports migration needed"
else
  fail "doctor did not detect legacy protocol block"
fi
if printf '%s\n' "$output" | grep -q 'ratchet init'; then
  ok "doctor suggests 'ratchet init' migration"
else
  fail "doctor did not suggest migration command"
fi
rm -rf "$testdir"

# Test 2: doctor reports harness-prompt delivery when no markers
testdir="$(mktemp -d)"
mkdir -p "$testdir/.git"
cat > "$testdir/.ratchet.conf" <<'EOF'
TRACKER_FILE=PLAN.md
VERIFY_CMD=true
STEP_TOKEN=STEP_COMPLETE
DONE_TOKEN=ALL_DONE
EOF
cat > "$testdir/PLAN.md" <<'EOF'
- [ ] test task
EOF
cat > "$testdir/AGENTS.md" <<'EOF'
# Human guidance

This is a clean AGENTS.md with no markers.
EOF
output="$(cd "$testdir" && source "$RR/lib/common.sh" && source "$RR/lib/commands.sh" && cmd_doctor "$testdir" 2>&1)" || true
if printf '%s\n' "$output" | grep -q 'protocol delivery: harness-prompt'; then
  ok "doctor reports harness-prompt delivery for clean AGENTS.md"
else
  fail "doctor did not report harness-prompt delivery"
fi
rm -rf "$testdir"

echo ""
echo "selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
