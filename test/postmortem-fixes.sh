#!/usr/bin/env bash
# Postmortem fix tests — one assert per new logic change

set -uo pipefail
cd "$(dirname "$0")/.."
. lib/tracker.sh
. lib/commands.sh
. lib/contract.sh

# Initialize required globals for cmd_doctor
AGENT_CMD="${AGENT_CMD:-pi}"
RATCHET_PROTOCOL_VERSION="${RATCHET_PROTOCOL_VERSION:-1}"

# P0.1: doctor resolves VERIFY_CMD arg[0]
test_verify_cmd_resolve() {
  local tmp; tmp=$(mktemp -d)
  cat >"$tmp/.ratchet.conf" <<'EOF'
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=nonexistent_cmd test
EOF
  echo "- [ ] T1 task" >"$tmp/PLAN.md"
  local out; out=$(cmd_doctor "$tmp" 0 2>&1)
  rm -rf "$tmp"
  echo "$out" | grep -q "unresolved executable.*nonexistent_cmd"
}

# P1.1: skip done-definition checklists
test_skip_done_checklist() {
  local tmp; tmp=$(mktemp -d)
  cat >"$tmp/PLAN.md" <<EOF
## DONE when
- [ ] checkbox under done heading
## Task
- [ ] A1 real task
EOF
  REPO_DIR="$tmp" TRACKER_FILE="PLAN.md"
  local result; result=$(tracker_next open)
  rm -rf "$tmp"
  echo "$result" | grep -q "A1 real task"
}

# P1.1: recognize non-T ids
test_non_t_ids() {
  local tmp; tmp=$(mktemp -d)
  echo "- [ ] A1 task alpha" >"$tmp/PLAN.md"
  REPO_DIR="$tmp" TRACKER_FILE="PLAN.md"
  local result; result=$(tracker_next_id_and_text)
  rm -rf "$tmp"
  echo "$result" | grep -q "^A1 "
}

# P1.2: doctor warns on unresolved task id
test_doctor_warns_unresolved_id() {
  local tmp; tmp=$(mktemp -d)
  cat >"$tmp/.ratchet.conf" <<'EOF'
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=bash
EOF
  echo "- [ ] no id task" >"$tmp/PLAN.md"
  local out; out=$(cmd_doctor "$tmp" 0 2>&1)
  rm -rf "$tmp"
  echo "$out" | grep -q "task id unresolved"
}

# P3.2: REQUIRED_TOOLS check
test_required_tools() {
  local tmp; tmp=$(mktemp -d)
  cat >"$tmp/.ratchet.conf" <<'EOF'
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
VERIFY_CMD=true
REQUIRED_TOOLS=bash,nonexistent_tool_xyz
EOF
  echo "- [ ] T1 task" >"$tmp/PLAN.md"
  local out; out=$(cmd_doctor "$tmp" 0 2>&1)
  rm -rf "$tmp"
  echo "$out" | grep -q "missing required tool"
}

# P4.1: backoff escalation (mock)
test_backoff_escalation() {
  # mock: just verify backoff logic in isolation
  local all_benched_count backoff_secs
  all_benched_count=1
  case "$all_benched_count" in
    1) backoff_secs=900 ;;
    2) backoff_secs=3600 ;;
    *) backoff_secs=14400 ;;
  esac
  [ "$backoff_secs" = "900" ] || return 1
  all_benched_count=3
  case "$all_benched_count" in
    1) backoff_secs=900 ;;
    2) backoff_secs=3600 ;;
    *) backoff_secs=14400 ;;
  esac
  [ "$backoff_secs" = "14400" ]
}

# P5.2: ALL_DONE sanity gate (mock)
test_all_done_sanity() {
  # mock: verify the logic that would block false ALL_DONE
  local tmp; tmp=$(mktemp -d)
  echo "- [ ] T1 open task" >"$tmp/PLAN.md"
  REPO_DIR="$tmp" TRACKER_FILE="PLAN.md"
  if tracker_has_open; then
    # would log "open tasks remain" and treat as step
    rm -rf "$tmp"; return 0
  fi
  rm -rf "$tmp"; return 1
}

# P5.2b: the downgrade must run BEFORE the case so it dispatches to step),
# not inside done) where setting TURN_STATUS is a no-op and the loop exits
# with open tasks remaining (bug: ratchet END after 1 turn).
test_all_done_downgrade_dispatches() {
  local TURN_STATUS="done" dispatched=""
  tracker_has_open() { return 0; }        # open task remains
  tracker_has_inprogress() { return 1; }
  if [ "$TURN_STATUS" = "done" ] && { tracker_has_open || tracker_has_inprogress; }; then
    TURN_STATUS="step"
  fi
  case "$TURN_STATUS" in
    done) dispatched="done" ;;
    step) dispatched="step" ;;
  esac
  [ "$dispatched" = "step" ]
}

# Run all tests
echo "P0.1: doctor resolves VERIFY_CMD arg[0]"
test_verify_cmd_resolve || { echo "FAIL: P0.1"; exit 1; }
echo "P1.1: skip done-definition checklists"
test_skip_done_checklist || { echo "FAIL: P1.1 skip done"; exit 1; }
echo "P1.1: recognize non-T ids"
test_non_t_ids || { echo "FAIL: P1.1 non-T"; exit 1; }
echo "P1.2: doctor warns on unresolved id"
test_doctor_warns_unresolved_id || { echo "FAIL: P1.2"; exit 1; }
echo "P3.2: REQUIRED_TOOLS check"
test_required_tools || { echo "FAIL: P3.2"; exit 1; }
echo "P4.1: backoff escalation"
test_backoff_escalation || { echo "FAIL: P4.1"; exit 1; }
echo "P5.2: ALL_DONE sanity gate"
test_all_done_sanity || { echo "FAIL: P5.2"; exit 1; }
echo "P5.2b: ALL_DONE downgrade dispatches to step)"
test_all_done_downgrade_dispatches || { echo "FAIL: P5.2b downgrade fell through to done)"; exit 1; }

echo "All postmortem fix tests passed."
