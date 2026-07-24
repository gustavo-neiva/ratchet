#!/usr/bin/env bash
# test/models-smoke.sh — one-line ping per model in the loop chain.
# Confirms reachability + auth for the vendor/model setup. Manual run;
# NOT part of the green gate (separate from selftest.sh).
set -u
cd "$(dirname "$0")/.." || exit 1

MODELS=(zai/glm-5-turbo zai/glm-5.2 zai/glm-4.7 \
        anthropic/claude-sonnet-4-5 anthropic/claude-opus-4-8)
blocked=0

for m in "${MODELS[@]}"; do
  printf '%-34s ' "$m"
  out=$(pi -p --model "$m" "Reply with exactly: OK" 2>&1)
  if printf '%s' "$out" | grep -qi 'OK'; then
    echo "PASS"
  elif printf '%s' "$out" | grep -qiE '429|rate.?limit|quota'; then
    echo "RATE-LIMITED (alive — loop self-heals via cooldown)"
  elif printf '%s' "$out" | grep -qiE '400|401|403|extra.?usage|third.?part|not.*found|invalid'; then
    echo "BLOCKED (auth/billing — expected for anthropic if extra-usage off)"
    blocked=$((blocked + 1))
  else
    echo "NO REPLY: $(printf '%s' "$out" | tail -1 | cut -c1-70)"
    blocked=$((blocked + 1))
  fi
done

echo "---"
echo "models-smoke: done ($blocked blocked). z.ai models must PASS for the loop to run."
