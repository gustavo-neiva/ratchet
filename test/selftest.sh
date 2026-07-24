#!/usr/bin/env bash
# =============================================================================
#  selftest.sh — verify ratchet's detection + loop logic (NO model calls)
# =============================================================================
#  Six suites:
#    1. turn-outcome classification (token / exhausted / hard / transient)
#    2. tracker tag extraction (trivial|normal|hard routing tags)
#    3. contract parsing (allowlisted keys, unknown key rejection)
#    4. cross-provider session sanitizer (strips thinking blocks)
#    5. agnosticism grep-check (zero project knowledge in the tool)
#    6. end-to-end: `ratchet once` against a fixture repo driven by fake-agent
#       -> proves spawn -> watchdog -> classify -> green gate -> commit works
#          with ZERO api keys (this is what makes the loop testable in CI).
#
#  Exit 0 if all pass, 1 otherwise.
# =============================================================================
set -uo pipefail
RR="$(cd "$(dirname "$0")/.." && pwd)"     # ratchet repo root
RATCHET="$RR/bin/ratchet"
FAKE="$RR/test/fixtures/fake-agent"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

# stubs so session-sanitize.sh can be sourced standalone
emit() { :; }
vlog() { :; }
LOG_DIR="$(mktemp -d)"

# --- units under test ---------------------------------------------------------
STEP_TOKEN="STEP_COMPLETE"; DONE_TOKEN="ALL_DONE"
. "$RR/lib/classify.sh"
. "$RR/lib/session-sanitize.sh"
. "$RR/lib/tracker.sh"
. "$RR/lib/contract.sh"

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

echo "== suite 3: contract parsing =="
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

echo "== suite 4: session sanitizer =="
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

echo "== suite 5: agnosticism (zero project knowledge) =="
if grep -riE 'cookbook|cap_table|carta|erl_crash|issuance|reporting|jira|secm-' \
     "$RR/lib" "$RR/bin" "$RR/templates" 2>/dev/null; then
  fail "project knowledge leaked into lib/bin/templates"
else
  ok "no project knowledge in lib/bin/templates"
fi

echo "== suite 6: end-to-end (fake-agent, no api keys) =="
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

echo ""
echo "selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
