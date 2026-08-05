# PLAN.md — ratchet: separate loop-driven from human-driven agent context

> The prior plan (UI overhaul, loop-analysis, automatic model selection) is
> COMPLETE and preserved in git history. This plan fixes a dogfood design bug:
> the ratchet loop protocol currently lives inside `AGENTS.md`, which EVERY
> interactive agent (Claude, Pi, Cursor) auto-loads — so a human-led session
> reads one-turn/`STEP_COMPLETE`/"don't commit" instructions meant only for the
> headless loop, and mis-behaves. Run with `bin/ratchet run .`.

Tracker grammar: `[ ]` open → `[IN PROGRESS]` → `[x]` done.
Tags: `(trivial|normal|hard)` and `(serial)`.

## The decision (B2-minus — read before ANY task)

Loop mechanics move OUT of the shared `AGENTS.md` entrypoint and INTO the
harness-injected per-turn prompt. This makes the separation **structural, not
advisory**: an interactive agent literally never receives loop instructions,
because the harness is the only thing that injects them.

- **`AGENTS.md` becomes fully human-owned** — what the repo is, how to work
  here, gotchas. NO managed loop-protocol block, NO markers.
- **The loop protocol travels in the prompt**, rendered fresh each turn from
  `templates/AGENTS.protocol.md` (repurposed as the prompt source) via
  `expected_protocol_block`, with live conf values.
- **`RATCHET_LOOP=1`** is exported by `run-turn.sh` as an ADVISORY signal (for
  tools/subagents/telemetry). It is spoofable, so it is NEVER a security or
  commit gate — the prompt channel is the only real guarantee.
- Because the AGENTS.md protocol block disappears, the `conf_tampered` guard,
  its doctor marker-checks, and suite-19 tamper tests are DELETED — a net
  simplification. (`.ratchet.conf` tamper protection is separate and STAYS.)

## Design constraints (read before ANY task — non-negotiable)

1. **Prompt source is read-only relative to the repo.** The per-turn prompt is
   ALWAYS built from `$RATCHET_ROOT/templates`, NEVER from any file under
   `$REPO_DIR`. A loop turn must not be able to plant a prompt-override the
   harness would trust.
2. **Never `die` in the per-turn prompt build.** If the protocol template is
   missing or fails to render, `build_default_prompt` falls back to today's
   inline string. The hot path must not hard-fail mid-run.
3. **`RATCHET_LOOP` is advisory only.** No security branch, no commit gate, no
   tamper check may read it to grant power. Routing/telemetry only.
4. **loop.log line formats are frozen (additive only).** `stats`/`status` parse
   them; never rename/reorder an emitted line.
5. **Bash 3.2; zero new deps for the loop core.** No assoc arrays, no `mapfile`,
   no `timeout`. `python3` optional (stats), `jq` optional (watch).
6. **Agnosticism invariant holds.** No project tool names (`npm`/`pytest`/
   `cargo`/`rspec`/`go test`) in `lib/`, `bin/`, `templates/`. Selftest greps.
7. **One task per turn.** Do the task, add its selftest case, run
   `bash test/selftest.sh`, mark `[x]`, print STEP_COMPLETE.
8. Never edit `.ratchet.conf`. Discovered gotchas → LEARNINGS.md (append-only).

## Milestone 0 — safety net (serial)

- [x] T0.1 (trivial, serial) Baseline: confirm the suite is green and record the count.
      touches: LEARNINGS.md
      do: Run `bash test/selftest.sh`. Confirm it exits 0. Append one line to
          LEARNINGS.md recording the pass count (e.g. "loop/human split baseline:
          selftest N/N green"). Change no other file. This anchors the "additive,
          zero-regression" invariant for the deletions in M2.
      accept:
          Given a clean checkout
          When `bash test/selftest.sh` runs
          Then it exits 0 and LEARNINGS.md records the count
      verify: bash test/selftest.sh
      constraints: no code changes this turn.

## Milestone 1 — Slice 1: the split works in THIS repo (serial: shared prompt/template/AGENTS path)

> Priority slice. After M1 an interactive agent in this repo sees only human
> guidance, and a loop turn carries its protocol in the prompt. Porting to other
> repos is M3 — deliberately deferred so we feel the edges first (Product + DA).

- [x] T1.1 (hard, serial) Inject the rendered loop protocol into the per-turn prompt.
      touches: lib/common.sh, test/selftest.sh
      do: Today `build_default_prompt` (lib/common.sh:119-121) emits a generic
          "Do ONE discrete step … following the project's AGENTS.md instructions"
          string — it DELEGATES the protocol to AGENTS.md. Change it so the loop
          carries its OWN protocol: render `templates/AGENTS.protocol.md` via
          `expected_protocol_block "$TRACKER_FILE" "$VERIFY_CMD" "$STEP_TOKEN"
          "$DONE_TOKEN"` and embed it in the prompt, THEN keep a short trailer
          telling the agent to read AGENTS.md + LEARNINGS.md for PROJECT facts
          (not protocol). Two hard rules: (a) the render is best-effort — wrap it
          so a missing/failed template FALLS BACK to today's exact inline string
          (constraint 2, never `die`); (b) the template path is under
          `$RATCHET_ROOT` only (constraint 1). Note `expected_protocol_block`
          lives in commands.sh, which is sourced by bin/ratchet — call it if
          available, else fall back. Drop the "following the project's AGENTS.md
          instructions" clause (the protocol is now inline) but KEEP the
          "Do NOT edit .ratchet.conf" line.
      snippet:
          build_default_prompt() {
            local proto=''
            if command -v expected_protocol_block >/dev/null 2>&1; then
              proto="$(expected_protocol_block "$TRACKER_FILE" "$VERIFY_CMD" \
                       "$STEP_TOKEN" "$DONE_TOKEN" 2>/dev/null)" || proto=''
            fi
            if [ -n "$proto" ]; then
              printf '%s\n\nRead AGENTS.md and LEARNINGS.md for project-specific facts (not loop protocol). Do NOT edit .ratchet.conf. When the step is complete print %s on its own line; if no work remains print %s.\n' \
                "$proto" "$STEP_TOKEN" "$DONE_TOKEN"
            else
              printf 'Do ONE discrete step … (today'\''s inline fallback) … %s … %s' "$STEP_TOKEN" "$DONE_TOKEN"
            fi
          }
      accept:
          Given TRACKER_FILE/VERIFY_CMD/STEP_TOKEN/DONE_TOKEN are set and the
                template exists
          When build_default_prompt runs
          Then its output contains the rendered loop protocol (the "ONE discrete
               step" / STEP_COMPLETE mechanics) AND a trailer pointing at
               AGENTS.md for project facts
          And when the template is unreadable, build_default_prompt still prints
               a non-empty prompt containing the step + done tokens (fallback,
               no die)
      verify: bash test/selftest.sh   (new case: prompt contains protocol
          substrings with template present; prompt non-empty + tokens present
          with a bogus RATCHET_ROOT template path)
      constraints: bash 3.2; best-effort render, never die; template read from
          $RATCHET_ROOT only; keep the .ratchet.conf-forbidden line.

- [x] T1.2 (normal, serial) Export RATCHET_LOOP=1 as the advisory loop signal.
      touches: lib/run-turn.sh, test/selftest.sh
      do: In run-turn.sh, right before the block that conditionally exports
          RATCHET_FANOUT (currently lib/run-turn.sh:62-65, inside run_turn, just
          above the `vlog "invoking: …"` line), add `export RATCHET_LOOP=1`. It
          must be exported UNCONDITIONALLY for every spawned turn (unlike FANOUT,
          which is hard-task-only), so any child process (agent, subagent, verify
          hook) can read "am I inside a ratchet loop turn?". Add a one-line
          comment: advisory only — routing/telemetry, never a gate (constraint 3).
      accept:
          Given a spawned loop turn
          When the agent process inspects its environment
          Then RATCHET_LOOP=1 is present
          And it is exported for EVERY turn, not just hard/fanout turns
      verify: bash test/selftest.sh   (case: source run-turn.sh context or grep
          the export is unconditional and above the agent spawn; assert
          RATCHET_LOOP set in a stubbed turn env)
      constraints: bash 3.2; unconditional export; advisory-only (add nothing
          that READS it as authority).

- [x] T1.3 (normal, serial) Assert RATCHET_LOOP is never used as authority.
      touches: test/selftest.sh
      do: Add a guard test proving constraint 3 holds: grep lib/ and bin/ for any
          read of RATCHET_LOOP (`$RATCHET_LOOP`, `${RATCHET_LOOP`) and assert the
          ONLY occurrence is the `export RATCHET_LOOP=1` write in run-turn.sh — no
          `if`/`case`/`[ … RATCHET_LOOP … ]` branch reads it to gate a commit,
          skip a check, or grant power. This locks the advisory-only invariant so
          a future turn can't quietly turn the spoofable signal into a gate.
      accept:
          Given the current source tree
          When the guard grep runs
          Then RATCHET_LOOP appears only as the exported write, never in a
               conditional that changes security/commit behavior
      verify: bash test/selftest.sh   (the new grep-guard case is green)
      constraints: test-only; if a real reader is ever needed later, this test
          is the intentional gate that must be consciously updated.

- [IN PROGRESS] T1.4 (hard, serial) Rewrite this repo's AGENTS.md: human guidance only, no loop block.
      touches: AGENTS.md, test/selftest.sh
      do: Replace the entire `ratchet-protocol:v1` managed block (and its Fanout
          section) with human-facing guidance. Keep NO markers, NO one-turn
          mechanics. Sections to write (concise): (1) "Loop vs interactive" — one
          short paragraph: the headless loop briefs its own turns via the harness
          prompt; if you are a human-led session (`RATCHET_LOOP` unset) work
          normally, make as many edits as needed, run the tests, the human owns
          commits. (2) "What this repo is" — task-agnostic bash harness; engine in
          lib/bin holds ZERO project knowledge; the 4 contract files carry it;
          this repo dogfoods itself (PLAN.md tracker, `bash test/selftest.sh`
          gate). (3) "How to work here" — run `ratchet selftest` before done; add
          a selftest case with non-trivial logic; bash 3.2 only; agnosticism
          invariant; frozen loop.log formats; read LEARNINGS.md first. (4)
          "Gotchas" — never edit .ratchet.conf; never bold-wrap a task ID; boolean
          shell funcs return 0=hit (early-out must return 1); no new deps; author
          plans via skills/ratchet-plan. This is the human entrypoint — write it
          for a person, not a loop.
      accept:
          Given the new AGENTS.md
          When an interactive agent loads it
          Then it contains NO `ratchet-protocol` markers and NO instruction to
               do exactly one step / print STEP_COMPLETE / avoid committing as a
               standing rule
          And it explains loop-vs-interactive, the agnosticism invariant, and the
               core gotchas in human language
      verify: bash test/selftest.sh   (new case: this repo's AGENTS.md has no
          `ratchet-protocol:` marker and no `STEP_COMPLETE` mandate line; the
          agnosticism grep over lib/bin/templates stays green)
      constraints: doc-only for AGENTS.md; task-agnostic; no project tool names
          that trip the agnosticism grep.

## Milestone 2 — Slice 1 cleanup: delete the now-dead tamper machinery (serial)

> The AGENTS.md protocol block no longer exists on disk, so the guard that
> stopped an agent editing it is moot. Net deletion.

- [ ] T2.1 (hard, serial) Remove conf_tampered and its commit-gate call.
      touches: lib/commit-gate.sh, test/selftest.sh
      do: Delete the `conf_tampered()` function (lib/commit-gate.sh:55-77) and
          its invocation in `commit_turn` (the `if conf_tampered; then … BLOCKED:
          … AGENTS.md protocol markers … return 1; fi` block at
          lib/commit-gate.sh:100-107). Its whole job — stop the agent rewriting
          the AGENTS.md loop block — is gone because there is no block. Leave the
          `.ratchet.conf` unstage line (lib/commit-gate.sh:~95, `git reset -q --
          .ratchet.conf`) UNTOUCHED — conf protection is separate and stays. Then
          delete the AGENTS.md-tamper cases in the selftest: suite 19 (protocol
          block tamper guard, test/selftest.sh:1256-1322) and the tamper cases in
          the commit-gate suite (test/selftest.sh:680-700 area) that call
          `conf_tampered`. Keep every OTHER commit-gate test (secret scan, verify
          gate, nothing-staged).
      accept:
          Given lib/ after this task
          When you grep for conf_tampered
          Then it is defined nowhere and called nowhere
          And commit_turn still unstages .ratchet.conf, still runs the secret
               scan and the green gate
          And the selftest is green with the AGENTS.md-tamper cases removed
      verify: bash test/selftest.sh   (suite passes without the deleted cases;
          add/confirm a case asserting .ratchet.conf is still unstaged by
          commit_turn)
      constraints: delete only AGENTS.md-tamper logic; .ratchet.conf unstaging
          and all non-tamper gate behavior byte-identical; bash 3.2.

- [ ] T2.2 (normal, serial) Drop expected_protocol_block's stamping role; keep it as the prompt renderer.
      touches: lib/commands.sh, test/selftest.sh
      do: `expected_protocol_block` (lib/commands.sh:29-35) is now used by ONE
          caller: the prompt injection in build_default_prompt (T1.1). Its old
          caller `stamp_protocol` (commands.sh:39-69) wrote the block into
          AGENTS.md — that role is gone. Remove `stamp_protocol` and its call in
          `cmd_init` (commands.sh:107-109, the "stamp the AGENTS.md protocol
          block" step + its emit). Keep `expected_protocol_block` itself (it
          renders the template for the prompt) but it no longer needs to emit
          marker lines if that simplifies it — MINIMAL change: leave its output
          shape as-is so T1.1's injection is unaffected; only remove the
          stamp/write path and its selftest cases (suite 19 Tests 2-9 that call
          stamp_protocol, already partly removed in T2.1 — finish the job).
      accept:
          Given commands.sh after this task
          When you grep for stamp_protocol
          Then it is defined nowhere and called nowhere
          And expected_protocol_block still renders the template with the four
               substitutions (the prompt path in T1.1 still works)
          And `ratchet init` no longer writes a protocol block into AGENTS.md
      verify: bash test/selftest.sh   (keep the expected_protocol_block
          substitution case; remove the stamp_protocol create/idempotent cases)
      constraints: keep expected_protocol_block working for the prompt; remove
          only the AGENTS.md-write path; bash 3.2.

## Milestone 3 — Slice 2: port the split to every ratchet-managed repo (serial)

> Deferred on purpose until Slice 1 proved out. Target repos are stamped by the
> SAME templates + cmd_init + doctor path, so the fix ports automatically — but
> already-onboarded repos still carry a v1 loop-in-file block that must be
> detected and removed, preserving human prose.

- [ ] T3.1 (normal, serial) init seeds a human AGENTS.md body and strips any legacy loop block.
      touches: lib/commands.sh, templates/AGENTS.human.md, test/selftest.sh
      do: Create `templates/AGENTS.human.md` — a task-agnostic seed for a target
          repo's human AGENTS.md (mirrors this repo's new AGENTS.md structure from
          T1.4 but generic: loop-vs-interactive note, "read your PLAN.md +
          LEARNINGS.md", "the loop briefs its own turns", placeholder for project
          rules). In `cmd_init` (where step 5 used to call stamp_protocol, now
          removed in T2.2), instead: if the repo's AGENTS.md still contains a
          `ratchet-protocol:.*:begin` block, STRIP that marker block (reuse the
          awk marker-delete shape from the old stamp_protocol re-stamp, but delete
          instead of replace), preserving all prose outside the markers; then, if
          AGENTS.md is absent or has no human body, append/seed
          `templates/AGENTS.human.md`. Emit what happened ("migrated legacy loop
          block out of AGENTS.md" / "seeded human AGENTS.md"). NEVER touch content
          the user wrote outside the markers (constraint: migration only ever
          edits inside-marker content).
      accept:
          Given a target repo whose AGENTS.md has a v1 loop-protocol marker block
                plus human prose below it
          When `ratchet init` runs
          Then the marker block is removed, the human prose is preserved verbatim,
               and a human body seed is present
          Given a repo with no AGENTS.md
          When `ratchet init` runs
          Then AGENTS.md is seeded from templates/AGENTS.human.md with no markers
      verify: bash test/selftest.sh   (fixture AGENTS.md with markers+prose →
          assert markers gone, prose kept; empty repo → assert seeded, no markers)
      constraints: bash 3.2; migration edits ONLY inside-marker content; seed is
          task-agnostic (agnosticism grep green); no stamp/tamper machinery.

- [ ] T3.2 (normal, serial) doctor detects a legacy loop-in-file block and reports delivery mode.
      touches: lib/commands.sh, test/selftest.sh
      do: Rewrite the doctor "protocol markers present + current in AGENTS.md"
          block (lib/commands.sh:476-489). New behavior: (a) if AGENTS.md contains
          any `ratchet-protocol:.*:begin` block → `pr_fail` "AGENTS.md carries a
          legacy loop-in-file protocol block; run `ratchet init $dir` to migrate
          (loop protocol now travels in the harness prompt)". (b) otherwise
          `pr_ok "protocol delivery: harness-prompt (loop briefs its own turns)"`.
          Remove the old stale/tracker-mismatch marker sub-checks (they assumed
          the block lives in AGENTS.md). Also update the token-consistency check
          (commands.sh:527-528, which greps AGENTS.md for the tokens) — the tokens
          now live in the prompt, not AGENTS.md, so drop that AGENTS.md token grep
          (or repoint it at the conf). Update the RATCHET_PROTOCOL_VERSION handling
          note only if needed; the version stays a doctor signal, not a stamp.
      accept:
          Given a repo whose AGENTS.md still has a loop marker block
          When `ratchet doctor` runs
          Then it FAILS with a migrate-to-harness-prompt message naming
               `ratchet init`
          Given a migrated repo (no markers)
          When `ratchet doctor` runs
          Then it reports "protocol delivery: harness-prompt" and does not fail on
               missing markers
      verify: bash test/selftest.sh   (doctor over a legacy-block fixture → fail
          with migrate msg; over a clean fixture → ok delivery line)
      constraints: bash 3.2; no re-introduction of stamp/tamper; keep every other
          doctor check (conf parse, tracker open, VERIFY_CMD dry-run) intact.

- [ ] T3.3 (trivial) Document the loop-vs-interactive split and how it ports.
      touches: README.md, skills/ratchet-plan/SKILL.md
      do: README: add a short subsection (near "The repo contract (4 files)" or
          "How it works") explaining that loop protocol travels in the harness
          prompt, AGENTS.md is the human entrypoint, `RATCHET_LOOP=1` is the
          advisory in-loop signal, and existing repos migrate via `ratchet init`
          (doctor flags the legacy block). ratchet-plan skill: fix the line that
          calls AGENTS.md the agent's protocol memory (SKILL.md:12) to say
          AGENTS.md is human/project memory and the loop protocol is
          harness-injected. Keep it honest and task-agnostic.
      accept:
          Given the README and the ratchet-plan skill
          When a reader asks "why doesn't my interactive agent follow the loop
               protocol / how do I migrate an old repo"
          Then the README explains the harness-prompt delivery, the RATCHET_LOOP
               advisory signal, and the `ratchet init` migration
      verify: bash test/selftest.sh   (doc-only; agnosticism grep green)
      constraints: doc-only; vendor/task-agnostic wording.

## Definition of done

`bash test/selftest.sh` green. An interactive agent in this repo loads an
AGENTS.md with NO loop-protocol markers and no one-turn mandate. A loop turn's
prompt carries the rendered protocol (template-sourced from `$RATCHET_ROOT`,
with a safe inline fallback) and exports `RATCHET_LOOP=1`. `conf_tampered` and
`stamp_protocol` are deleted; `.ratchet.conf` unstaging and all other gate
behavior are unchanged. `ratchet init` migrates a legacy loop-in-file block out
of a target repo's AGENTS.md (preserving human prose) and seeds a human body;
`ratchet doctor` fails on a leftover legacy block and otherwise reports
"protocol delivery: harness-prompt". No security/commit branch reads
`RATCHET_LOOP`.

## Non-goals

- No full-screen/ncurses UI, no change to loop.log formats, tracker grammar, or
  the four-checkpoint human model.
- No new runtime dependency; python3 stays optional (stats only).
- No retention of the AGENTS.md managed marker block or its stamp/tamper/version
  cycle — the panel review rejected the "tiny header" as dual-source complexity.
  Fully-unmanaged AGENTS.md is the chosen shape.
- `RATCHET_LOOP` never becomes an authority signal. If a future need arises, the
  T1.3 guard test is the deliberate gate that must be consciously changed.
- No automated rewrite of humans' prose in target repos — migration only ever
  removes content INSIDE the old markers.
