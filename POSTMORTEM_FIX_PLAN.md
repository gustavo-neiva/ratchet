# Postmortem Fix Plan — ratchet harness

Executable plan to close every finding in `RATCHET_COOKBOOK_POSTMORTEM.md`.
Each task is self-contained: **file · change · acceptance**. Tasks are ordered
by ROI (P0 first). Tags: `(trivial|normal|hard)`.

Grounding note: several postmortem fixes already shipped in current source and
are listed under "Already done — verify only" so they are not re-implemented.

---

## Already done — verify only (no code change expected)

- [x] **P1.3 inject resolved task into prompt** — `bin/ratchet:343-348` appends
  `The current tracker task is: …` to the prompt. Acceptance: grep confirms the
  block exists; a run header shows the task line.
- [x] **VERIFY_CMD points at a real gate** — `.ratchet.conf:VERIFY_CMD=bash test/selftest.sh`.
- [x] **Cooldown shortened** — `.ratchet.conf:COOLDOWN=900`.
- [x] **Per-tier backoff on transient/timeout** — `bin/ratchet:~400` (`backoff=SHORT_SLEEP*n`).

If any of the above is NOT true when you start, fold it back into the plan.

---

## P0 — Stop discarding good work

- [ ] **T0.1 (normal) doctor dry-run resolves VERIFY_CMD arg[0] at preflight.**
  File: `lib/commands.sh` `cmd_doctor()` (static block, ~line 488, runs at
  `full=0`). Today the executable dry-run only runs under `--full`
  (`lib/commands.sh:559`), but preflight calls `cmd_doctor "$REPO_DIR" 0`
  (`bin/ratchet:202`), so a gate that cannot execute (`npm test`, no
  `package.json`) passes preflight. Add a static check next to the existing
  "VERIFY_CMD is set" branch: extract the first shell token of `$VERIFY_CMD`; if
  it is not a shell builtin/keyword, require `command -v` OR a readable file at
  that path under `$dir`. Fail (`pr_fail`) with the unresolved token.
  Acceptance: `VERIFY_CMD=npm test` in a repo with no `package.json`/npm →
  `ratchet doctor` returns non-zero and names `npm`; `VERIFY_CMD=bash test/x.sh`
  with the file present → ok.
  `ponytail:` first-token resolve only, not full arg parsing — upgrade to a real
  dry-run behind `--full` (already exists) if false-greens appear.

- [ ] **T0.2 (normal) doctor fails on tracker ↔ AGENTS.md mismatch.**
  File: `lib/commands.sh` `cmd_doctor()`, in the AGENTS.md protocol-marker block
  (~line 459). The stamped protocol block embeds the tracker filename; assert it
  matches `$TRACKER_FILE`. Add: `grep -q "$TRACKER_FILE" "$agents"` within the
  managed marker range → ok; else `pr_fail "AGENTS.md references a different
  tracker than TRACKER_FILE=$TRACKER_FILE (re-stamp: ratchet init)"`.
  Acceptance: set `TRACKER_FILE=PLAN.md` but leave `COOKBOOK_PLAN.md` in the
  AGENTS.md protocol block → doctor fails; matching names → ok.

---

## P1 — Fix orientation

- [ ] **T1.1 (hard) harden the task-ID parser.**
  File: `lib/tracker.sh`. Three changes to `tracker_next` / the id extractor in
  `tracker_next_id_and_text`:
  1. **Skip done-definition checklists.** A `[ ]` line under a heading matching
     `/DONE|Done when|Definition of Done|checklist/i` is not a task. In
     `tracker_next`, track the nearest preceding heading (awk, not grep) and
     skip open boxes whose section heading matches that pattern.
  2. **Recognize non-`T` ids.** Extend id extraction to `^[A-Za-z]+[0-9]+(\.[0-9]+)?`
     and `^[A-Za-z]+-[a-z0-9-]+` (matches `A1`, `I3`, `N-postmortem`), not just
     `T[0-9]+\.[0-9]+`.
  3. Keep untagged plain checkboxes valid (regression: `- [ ] do the thing`).
  Acceptance: extend `test/` with a fixture tracker containing a DONE-checklist
  box before the first real `A1` task; `tracker_next open` returns the `A1`
  line, and `tracker_next_id_and_text` echoes `A1 (…)` not `? (normal)`.

- [ ] **T1.2 (trivial) doctor warns when the next task resolves to `?`.**
  File: `lib/commands.sh` `cmd_doctor()`, tracker block (~line 474). After
  confirming an open task exists, call `tracker_next_id_and_text`; if the id is
  `?`, `pr_fail` (loud) — "task id unresolved on the first open task; parser
  degraded to `?` (see tracker grammar)". `task=?` on 142/142 turns must be a
  hard preflight failure, not silent.
  Acceptance: a tracker whose first open box has no id → doctor fails; a `T1.2`/
  `A1` first task → ok.

---

## P2 — Make memory compound

- [ ] **T2.1 (normal) auto-append gate failures to LEARNINGS.md.**
  File: `lib/commit-gate.sh` `commit_turn()`, at the `commit gate RED` branch
  (~line where it `return 1`). When the gate fails, append one bounded line to
  `$REPO_DIR/LEARNINGS.md`: the last non-empty line of the verify output plus a
  timestamp, deduped (skip if an identical cause line already exists). Cap the
  file (e.g. keep last 50 auto lines under a `## auto-captured` heading) so it
  can't grow unbounded. This LEARNINGS.md edit rides the next green commit; it is
  not the agent's contract, so it is allowed.
  Acceptance: force a RED gate twice with the same error → LEARNINGS.md gains
  exactly ONE `## auto-captured` line; a different error adds a second.
  `ponytail:` naive tail-of-output capture, no NLP — upgrade to plan-tier
  curation (P2 note in postmortem) only if the lines get noisy.

- [ ] **T2.2 (normal) carry a one-line last-turn note into the next prompt.**
  Files: `bin/ratchet` (main loop) + prompt builder. After each turn, write a
  ≤2-line note to `$LOG_DIR/last_turn.note` (what the turn touched:
  `git diff --name-only` of the committed change, or "gate RED, left staged"). In
  the prompt-injection block (`bin/ratchet:343`), append the note if the file
  exists. Kills the "re-derive repo state" tax without session replay.
  Acceptance: run two `--once` turns; the second turn's prompt contains the first
  turn's file list.

---

## P3 — Gate & environment realism

- [ ] **T3.1 (trivial) document changed-entry gating as the multi-toolchain default.**
  File: `README.md` (VERIFY_CMD section) + `.ratchet.conf` comment. Note that for
  repos spanning N language toolchains, `VERIFY_CMD` should verify only what the
  turn changed (e.g. a `changed-entries.sh` pattern) so pre-existing
  environmental reds don't block good turns. Doc-only.
  Acceptance: README names the pattern and when to use it.

- [ ] **T3.2 (normal) optional REQUIRED_TOOLS conf key, checked in doctor.**
  Files: `lib/common.sh` (allowlist the key + default empty), `lib/commands.sh`
  (`parse_repo_conf` accepts it; `cmd_doctor` checks each tool with `command -v`
  and `pr_fail`s the missing ones). Unset = no check (backward compatible).
  Acceptance: `REQUIRED_TOOLS=pytest,dotnet` with pytest absent → doctor lists
  `pytest` as missing; unset key → no new output.

---

## P4 — Spend & fallback hygiene

- [ ] **T4.1 (normal) cooldown backoff instead of a flat both-wait.**
  Files: `lib/model-fallback.sh` + `bin/ratchet` all-benched branch (~line 300).
  Replace the single `sleep "$BOTH_WAIT"` with an escalating sequence
  (e.g. `900 → 3600 → 14400`, capped), reset to the first step after any
  successful step turn. A transient daily-limit blip should cost minutes, not a
  guaranteed 4 h nap.
  Acceptance: simulate all-benched twice with no success between → second sleep
  is longer than the first; a success resets the ladder.
  `ponytail:` fixed 3-rung ladder, no jitter — add jitter only if providers
  sync-thrash.

- [ ] **T4.2 (trivial) bench a model that returns a quota error in <15s.**
  File: `bin/ratchet` `exhausted` case (~line 397). It already benches on
  `exhausted`; add: if `turn_elapsed < 15` AND status is `exhausted`, log
  "instant-quota — model was already dry" so the chain doesn't look healthy.
  (Benching already prevents re-pick until cooldown; this is the observability
  the postmortem asked for.)
  Acceptance: a <15s exhausted turn logs the instant-quota note and the model is
  benched for `$COOLDOWN`.

---

## P5 — Guardrail UX

- [ ] **T5.1 (trivial) name off-limits regions in the default prompt.**
  File: `lib/common.sh` `build_default_prompt()`. Add one line: "Do NOT edit
  `.ratchet.conf` or the `AGENTS.md` protocol markers — the loop reverts and
  wastes the turn." Prevents the 6 forced reds proactively, not just post-hoc.
  Acceptance: prompt contains the off-limits line; AGENTS.md guard unchanged.

- [ ] **T5.2 (normal) sanity-gate ALL_DONE against open task count.**
  File: `bin/ratchet` `done)` case (~line 365). Before treating `ALL_DONE` as
  final, re-check `tracker_has_open`; if open tasks remain, log a warning and
  fall through to the `step` path (commit the turn, keep looping) instead of
  breaking. Complements the existing `MAX_DONE_GATE_FAILS` (which only guards the
  gate, not a false done on a green tree).
  Acceptance: agent prints `ALL_DONE` with an open `[ ]` task present → loop
  logs the warning and continues; genuinely all-`[x]` → loop finalizes.

---

## Verification (run after each task)

```
bash test/selftest.sh                 # existing gate stays green
ratchet doctor .                      # new checks fire correctly
```

New logic (T0.1, T0.2, T1.1, T1.2, T2.1, T4.1, T5.2) each leaves ONE runnable
assert-based check in `test/` — no framework, smallest thing that fails if the
logic breaks.
