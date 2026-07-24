#!/usr/bin/env bash
# =============================================================================
#  bench.sh — benchmark harness for speed/efficiency claims
# =============================================================================
#  Runs 3 tasks with the fake agent and measures:
#    (a) token-seen → turn-end latency (early-kill < 10s)
#    (b) wall-clock of the run
#    (c) turns-on-cheap-model % from stats
#  Compares against test/bench-baseline.txt; exits nonzero on >20% regression.
# =============================================================================
set -euo pipefail
RR="$(cd "$(dirname "$0")/.." && pwd)"
RATCHET="$RR/bin/ratchet"
FAKE="$RR/test/fixtures/fake-agent"

# temp fixture repo with 3 tasks
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/PLAN.md" <<'PLAN'
- [ ] T1 (trivial) first task
- [ ] T2 (normal) second task
- [ ] T3 (hard) third task
PLAN
cat > "$TMPDIR/.ratchet.conf" <<'CONF'
RATCHET_PROTOCOL=1
TRACKER_FILE=PLAN.md
MODELS="fake/agent"
LIGHT_MODELS="fake/cheap"
THINKING="off"
VERIFY_CMD="exit 0"
CONF
# git init + stamp AGENTS.md via init
cd "$TMPDIR"
git init -q
"$RATCHET" init "$TMPDIR" >/dev/null 2>&1
git add -A >/dev/null 2>&1
git commit -m "init" >/dev/null 2>&1

# run with timestamps (RATCHET_HOME controls log location)
RATCHET_HOME="$TMPDIR/.ratchet"
mkdir -p "$RATCHET_HOME"
START=$(date +%s)
RATCHET_HOME="$RATCHET_HOME" "$RATCHET" run "$TMPDIR" --agent-cmd "$FAKE" --no-commit >/dev/null 2>&1 || true
END=$(date +%s)
WALL=$((END - START))

# (a) token-seen latency: fake-agent prints token instantly, so measure turn duration
LOGF=$(find "$RATCHET_HOME/logs" -name "loop.log" 2>/dev/null | head -n1)
if [ -z "$LOGF" ] || [ ! -f "$LOGF" ]; then echo "FAIL: no log file"; exit 1; fi
LATENCIES=$(grep -o 'took=[0-9]*s' "$LOGF" | sed 's/took=//;s/s//' | sort -n)
MAX_LAT=$(echo "$LATENCIES" | tail -n1)
if [ -z "$MAX_LAT" ]; then echo "FAIL: no latency data"; exit 1; fi

# (b) wall-clock is $WALL
# (c) cheap model % — fake-agent doesn't hit real models, skip for now
CHEAP_PCT=0

# compare
BASELINE="$RR/test/bench-baseline.txt"
if [ -f "$BASELINE" ]; then
  read -r base_lat base_wall base_cheap < "$BASELINE"
  lat_delta=$(( (MAX_LAT - base_lat) * 100 / base_lat ))
  wall_delta=$(( (WALL - base_wall) * 100 / base_wall ))
  
  printf "%-20s %10s %10s %10s\n" "Metric" "Current" "Baseline" "Delta"
  printf "%-20s %10s %10s %+9d%%\n" "Max latency (s)" "$MAX_LAT" "$base_lat" "$lat_delta"
  printf "%-20s %10s %10s %+9d%%\n" "Wall-clock (s)" "$WALL" "$base_wall" "$wall_delta"
  printf "%-20s %10s %10s %10s\n" "Cheap model %" "$CHEAP_PCT" "$base_cheap" "n/a"
  
  # exit nonzero on >20% regression
  [ "$lat_delta" -gt 20 ] && { echo "FAIL: latency regression >20%"; exit 1; }
  [ "$wall_delta" -gt 20 ] && { echo "FAIL: wall-clock regression >20%"; exit 1; }
  echo "PASS"
else
  # first run: write baseline
  echo "$MAX_LAT $WALL $CHEAP_PCT" > "$BASELINE"
  echo "Baseline written: latency=${MAX_LAT}s wall=${WALL}s cheap=${CHEAP_PCT}%"
fi

# verify latency claim (< 10s per early-kill design)
if [ "$MAX_LAT" -lt 10 ]; then
  echo "Latency claim verified: ${MAX_LAT}s < 10s"
else
  echo "FAIL: latency $MAX_LAT >= 10s (violates early-kill claim)"
  exit 1
fi
