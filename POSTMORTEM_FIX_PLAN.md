# Postmortem Fix Plan — ratchet harness

> **Status (reconciled 2026-08-05): every item below SHIPPED.** This file was the
> executable plan to close `RATCHET_COOKBOOK_POSTMORTEM.md`. All findings shipped
> across `144d1ec` and subsequent commits; live-remaining work migrated to
> **Milestone 6 of PLAN.md** (the loop's active tracker). Ticking pointers cite
> current source `file:line` so the next reader can verify in place instead of
> redoing finished work.

---

## P0 — Stop discarding good work

- [x] **T0.1 (normal) doctor dry-run resolves VERIFY_CMD arg[0] at preflight.**
  Shipped: `lib/commands.sh:516-522` — `cmd_doctor()` resolves the first token of
  `$VERIFY_CMD` via a shell-builtin case list + `command -v` / readable-file
  check, and `pr_fail`s the unresolved token. `ponytail:` first-token resolve
  only; full dry-run still lives behind `--full`.

- [x] **T0.2 (normal) doctor fails on tracker ↔ AGENTS.md mismatch.**
  Shipped: `lib/commands.sh:484-487` — within the protocol-marker block,
  `grep -q "$_tr" "$agents"` (where `_tr=$TRACKER_FILE`) fails with
  `"AGENTS.md references a different tracker than TRACKER_FILE=… (re-stamp: ratchet init)"`.

## P1 — Fix orientation

- [x] **T1.1 (hard) harden the task-ID parser.**
  Shipped: `lib/tracker.sh:25,33,38` — `tracker_next` skips `[ ]` lines under
  headings matching `/done|checklist/` (nearest preceding heading tracked in
  awk). `lib/tracker.sh:142-149` — `tracker_next_id_and_text` id extraction
  recognizes `^[A-Za-z]+[0-9]+(\.[0-9]+)?` (T1.2, A1, I3) AND
  `^[A-Za-z]+-[a-z0-9-]+` (N-postmortem); plain untagged checkboxes stay valid.

- [x] **T1.2 (trivial) doctor warns when the next task resolves to `?`.**
  Shipped: `lib/commands.sh:503-505` — after confirming an open task,
  `cmd_doctor` runs `tracker_next_id_and_text`, and `pr_fail`s with
  `"task id unresolved on first open task; parser degraded to '?' (see tracker grammar)"`
  when the id is `?`.

- [x] **T1.3 inject resolved task into prompt** (was "verify only"). Shipped:
  `bin/ratchet:343-348` — appends `The current tracker task is: …` to the prompt.

- [x] **VERIFY_CMD points at a real gate.** `.ratchet.conf:17` → `VERIFY_CMD=bash test/selftest.sh`.

- [x] **Cooldown shortened.** `.ratchet.conf:44` → `COOLDOWN=900`.

- [x] **Per-tier backoff on transient/timeout.** Shipped: `bin/ratchet:432-443`
  — both `timeout)` and `transient)` cases compute
  `backoff=$(( SHORT_SLEEP * n ))` from the per-tier strike count, escalating
  per strike and benching after `$MAX_TRANSIENT`.

## P2 — Make memory compound

- [x] **T2.1 (normal) auto-append gate failures to LEARNINGS.md.**
  Shipped: `lib/commit-gate.sh:127-138` — the commit-gate-RED branch appends a
  bounded line under a `## auto-captured` heading (last error line + timestamp).
  `ponytail:` naive tail-of-output capture, no NLP.

- [x] **T2.2 (normal) carry a one-line last-turn note into the next prompt.**
  Shipped: `bin/ratchet:448-451` writes `$LOG_DIR/last_turn.note` after each turn
  (committed file list, or "gate RED, left staged"); `bin/ratchet:357-358`
  appends the note to the next prompt when present.

## P3 — Gate & environment realism

- [x] **T3.1 (trivial) document changed-entry gating as the multi-toolchain default.**
  Shipped: `README.md:343-346` — the `--verify-cmd` help block names the
  multi-toolchain tip: "verify only changed entries
  (e.g. 'bash changed-entries.sh') so pre-existing environmental reds don't
  block good turns".

- [x] **T3.2 (normal) optional REQUIRED_TOOLS conf key, checked in doctor.**
  Shipped: allowlisted `lib/contract.sh:24`; checked `lib/commands.sh:538-545` —
  `cmd_doctor` iterates the comma list with `command -v` and `pr_fail`s the
  missing ones. Unset = no output (backward compatible).

## P4 — Spend & fallback hygiene

- [x] **T4.1 (normal) cooldown backoff instead of a flat both-wait.**
  Shipped: `bin/ratchet:304-312` — all-benched branch replaces the single
  `BOTH_WAIT` with a 3-rung ladder (`900 → 3600 → 14400`), reset to step 1 after
  any successful step turn (`all_benched_count=0` at `bin/ratchet:406`).
  `ponytail:` fixed 3-rung ladder, no jitter.

- [x] **T4.2 (trivial) bench a model that returns a quota error in <15s.**
  Shipped: `bin/ratchet:415-417` — `exhausted)` case checks
  `turn_elapsed < 15` and logs
  `"… — instant-quota, model was already dry. Benching ${COOLDOWN}s; switching."`.

## P5 — Guardrail UX

- [x] **T5.1 (trivial) name off-limits regions in the default prompt.**
  Shipped: `lib/common.sh:119` — `build_default_prompt()` includes
  "Do NOT edit .ratchet.conf or the AGENTS.md protocol markers — the loop reverts
  and wastes the turn."

- [x] **T5.2 (normal) sanity-gate ALL_DONE against open task count.**
  Shipped: `bin/ratchet:375-379` — before treating `ALL_DONE` as final, re-checks
  `tracker_has_open || tracker_has_inprogress`; if tasks remain it logs a warning
  and falls through to the `step` path (commit + keep looping) instead of
  breaking.

---

## Verification

```
bash test/selftest.sh   # green gate (the one VERIFY_CMD points at)
ratchet doctor .        # the P0/P1/P3.2 checks all fire here
```

Every shipped item above leaves a runnable check in `test/` (no framework) or a
`doctor` assertion — grep the cited `file:line` to re-verify any item in place.
