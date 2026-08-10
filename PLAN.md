# PLAN.md — ratchet: fully autonomous loop, human at PR-merge only

> Supersedes UPGRADE_DRAFT.md (validated 2026-02: pi 0.81.1 flags OK, subagent
> tool live in headless turns, gh 2.4.0 `--base`/`--json` OK, selftest 223/223,
> models.dev join OK). Pivot: the ONLY human touchpoint is merging a PR.
> Plan review = PR #0. Code review = one PR per milestone, no stacking — the
> loop blocks on merge (trilemma: sequential work + small PRs + no stacking
> forces a merge-gate; the wait IS the human-in-the-loop).

Tracker grammar: [ ] open → [IN PROGRESS] → [x] done. Tags: (trivial|normal|hard) and (serial).

## Design constraints (read before ANY task — non-negotiable)
1. Additive only. The 223-case selftest baseline never regresses. Frozen
   loop.log line grammar: new lines may be ADDED, existing lines never change.
2. Bash 3.2, zero new dependencies. `gh` is used only when the PR flow is on.
3. Backward compatible: all new behavior is off unless `PR_CADENCE=milestone`
   is set. Default `PR_CADENCE=done` = today's behavior, byte-identical.
4. The green gate (`commit_turn`) stays the ONLY commit authority. Review and
   plan turns never write code; the review turn is read-only by prompt.
5. No hardcoded model ids anywhere in ratchet source or templates.
6. The loop never merges. `gh pr merge` must not appear in any code path.
7. One task per turn. Do the task, add its verify case, run VERIFY_CMD, mark
   [x], print STEP_COMPLETE.

VERIFY_CMD: bash test/selftest.sh

## Milestone 1 — review tier + contract keys (config plumbing)
> Everything later hangs off these keys. Pure plumbing, mirrors the plan tier.

- [x] T1.1 (normal) add the `review` tier to model routing
      touches: lib/model-fallback.sh, lib/common.sh
      do: Mirror the existing plan tier exactly. In `chain_for_tier`, add a
          `review` case returning `$REVIEW_MODELS` (fallback: flat MODELS, then
          suggest_chain). In `thinking_for_tier`, add `review` returning
          `$THINKING_REVIEW` (fallback: $THINKING). Declare REVIEW_MODELS=""
          and THINKING_REVIEW="" defaults in lib/common.sh next to the other
          tier keys.
      accept:
          Given REVIEW_MODELS=zai/glm-5.2 and THINKING_REVIEW=medium
          When chain_for_tier review / thinking_for_tier review run
          Then they echo zai/glm-5.2 and medium
          Given both are unset
          Then they fall back to MODELS / THINKING exactly like the plan tier
      verify: bash test/selftest.sh   (add cases: review tier set, unset≡flat)
      constraints: additive; do not touch plan/build/light arms.

- [x] T1.2 (trivial) allowlist the new contract keys
      touches: lib/contract.sh, templates/ratchet.conf.example
      do: Append to CONTRACT_KEYS: REVIEW_MODELS THINKING_REVIEW MODEL_RANK
          MAX_REVIEW_CYCLES PR_CADENCE MERGE_POLL_SECS MERGE_WAIT_TIMEOUT
          PR_SOFT_MAX_LINES. NOTIFY_CMD is deliberately NOT allowlisted: it is
          an executable command string, so it may live only in the trusted
          global conf (sourced) — a repo .ratchet.conf setting it already
          fails loudly as an unknown key, which is exactly the wanted
          behavior. (MODEL_RANK exists in common.sh but was
          never allowlisted — a per-repo .ratchet.conf setting it is silently a
          doctor error today; this fixes that gap.) Add numeric validation for
          MAX_REVIEW_CYCLES, MERGE_POLL_SECS, MERGE_WAIT_TIMEOUT,
          PR_SOFT_MAX_LINES in the numeric-keys case arm. Document each new key
          with a commented example in ratchet.conf.example.
      accept:
          Given a .ratchet.conf containing MODEL_RANK=x and PR_CADENCE=milestone
          When parse_repo_conf runs
          Then it returns 0 with no "unknown key" errors
      verify: bash test/selftest.sh   (add case: new keys parse, junk value in
          MERGE_POLL_SECS is stripped to digits)
      constraints: allowlist parser semantics unchanged; never source the conf.

- [x] T1.3 (normal) defaults + `--pr-cadence` flag wiring
      touches: lib/common.sh, bin/ratchet
      do: Defaults in common.sh: PR_CADENCE=done, MAX_REVIEW_CYCLES=2,
          MERGE_POLL_SECS=300, MERGE_WAIT_TIMEOUT=259200 (72h), NOTIFY_CMD="",
          PR_SOFT_MAX_LINES=400. Add `--pr-cadence milestone|done` to
          parse_args + pre_scan skip list + usage text. PR_CADENCE=milestone
          implies OPEN_PR=1 PUSH_ON_DONE=1 (set after parse_args in main).
      accept:
          Given no new conf keys and no new flags
          When ratchet runs
          Then behavior is byte-identical to today (PR_CADENCE=done)
      verify: bash test/selftest.sh   (add case: default cadence is done;
          --pr-cadence milestone sets OPEN_PR=1)
      constraints: additive; existing flags untouched.

## Milestone 2 — generalized model ranking (derived rank, no hardcoding)
> "Auto model choosing" that works for any user, any provider, any catalog.
> Rank = output price descending from models.dev, availability from pi.

- [x] T2.1 (hard) derived_rank: price-ordered ranking when MODEL_RANK is unset
      touches: lib/model-select.sh
      do: Add `derived_rank()`: read pi_model_registry (availability ground
          truth, ALLOWED_PROVIDERS filter reused from ranked_available_models),
          join each model via model_meta, DROP models with tool_call=false
          (coding loop needs tools; empty/unknown flag = keep), sort joined
          models by output price (TSV field 3) DESCENDING, then append
          no-join models (subscription ids etc.) in registry order. Echo one
          provider/id per line. Then change `ranked_available_models` /
          `suggest_chain`: when MODEL_RANK is unset, use derived_rank instead
          of returning rc1 — suggest_chain slices it exactly as it slices an
          explicit rank today (plan=top, build=middle down, light=bottom).
          Add a `review` tier arm to suggest_chain: same slice as build's
          first pick + fallbacks (middle of the ranking).
      snippet:
          # sort ranked by price desc:  printf '%s\n' "${lines[@]}" | sort -t$'\t' -k2 -rn
      accept:
          Given MODEL_RANK is unset and a registry + cost cache fixture exist
          When suggest_chain build runs
          Then it echoes a non-empty chain ordered by output price descending
          Given a model has no models.dev join
          Then it appears after all priced models, never dropped
          Given MODEL_RANK is set
          Then behavior is identical to today (explicit rank wins)
      verify: bash test/selftest.sh   (add cases with fixture caches under
          test/fixtures: price ordering, no-join appended, tool_call=false
          dropped, explicit MODEL_RANK unchanged)
      constraints: ponytail: price∝strength heuristic — ceiling is subsidized/
          subscription pricing; upgrade path = outcome-based re-rank from
          loop.log stats (T6.3, optional). Never call the network in the loop
          path; caches only.

- [x] T2.2 (normal) rank snapshot + `ratchet models rank` subcommand
      touches: lib/models.sh, lib/model-select.sh, lib/commands.sh
      do: Derived ranks must not reshuffle mid-project on catalog churn. On
          first derivation, write the derived list to $RATCHET_HOME/rank.derived
          and serve from that file on later calls. Add `ratchet models rank`
          (in cmd_models): prints the effective ranking (explicit MODEL_RANK or
          snapshot) with per-model cost marks reusing _chain_with_marks;
          `ratchet models rank refresh` re-derives (refreshes both caches via
          pi_model_registry refresh + model_cost_registry refresh) and
          rewrites the snapshot. Doctor: add one line reporting rank source
          (explicit | derived-snapshot | none) and count of unranked no-join
          models.
      accept:
          Given no MODEL_RANK and no snapshot
          When suggest_chain first runs
          Then $RATCHET_HOME/rank.derived is created and later calls reuse it
          When ratchet models rank refresh runs
          Then the snapshot is rewritten from live registry + costs
      verify: bash test/selftest.sh   (add cases: snapshot created once, reused,
          refresh rewrites)
      constraints: snapshot is plain lines, printf'd; no jq/python in loop path.

## Milestone 3 — merge-gate + human notification
> The single human checkpoint mechanism. Loop blocks until a PR merges.

- [x] T3.1 (trivial) notify_human helper
      touches: lib/observability.sh
      do: `notify_human MSG`: emit the message prefixed "HUMAN NEEDED:", print
          a terminal bell (printf '\a' >&2) when stderr is a TTY, and if
          NOTIFY_CMD is non-empty run it in the background with the message as
          $1: `sh -c "$NOTIFY_CMD \"\$1\"" _ "$MSG" &`. This is safe ONLY
          because NOTIFY_CMD can come solely from the trusted, sourced global
          conf — T1.2 keeps it OFF the repo-conf allowlist, so the existing
          parser already rejects an agent-adjacent repo conf setting it.
      accept:
          Given NOTIFY_CMD set in the global conf to a script that touches a file
          When notify_human "x" runs
          Then the file exists and the loop did not block
          Given NOTIFY_CMD=x in a repo .ratchet.conf
          Then parse_repo_conf reports it as an unknown key (existing behavior)
      verify: bash test/selftest.sh   (add cases: hook fires + does not block;
          repo-conf NOTIFY_CMD rejected by the allowlist)
      constraints: SECURITY — never execute a command string that can originate
          from the parsed repo conf. Global conf is trusted (already sourced
          today).

- [x] T3.2 (hard) wait_for_merge: poll the PR until merged / closed / timeout
      touches: bin/ratchet (new function), lib/observability.sh
      do: `wait_for_merge BRANCH`: requires gh + origin (else notify_human and
          return 2 = manual mode: loop stops cleanly telling the human to merge
          and re-run). Loop: `gh pr view BRANCH --json state -q .state` (gh
          2.4.0-compatible; if -q unsupported parse with sed) every
          MERGE_POLL_SECS. MERGED → git checkout main (detect default branch
          via `git symbolic-ref refs/remotes/origin/HEAD`), git pull --ff-only,
          return 0. CLOSED → notify_human + return 1 (loop stops: human
          rejected the work). Elapsed > MERGE_WAIT_TIMEOUT (72h default) →
          notify_human + clean exit message + return 3. Emit a frozen new
          loop.log line `merge-wait | pr=<branch> | state=<state>` on each
          state change only (not each poll).
      accept:
          Given a stub gh on PATH returning OPEN then MERGED
          When wait_for_merge runs with MERGE_POLL_SECS=1
          Then it returns 0 after the second poll and the repo is on the
          default branch, fast-forwarded
          Given the stub returns CLOSED
          Then it returns 1 and a HUMAN NEEDED line was emitted
      verify: bash test/selftest.sh   (add cases with a PATH-stubbed gh + a
          fixture git repo with an origin; timeout path with
          MERGE_WAIT_TIMEOUT=1)
      constraints: never `gh pr merge`; poll sleep is interruptible (plain
          sleep is fine — Ctrl-C is the existing stop story).

## Milestone 4 — plan as PR #0 (full autonomy, no hard stops)
> Every human decision is a merge button. Plan review included.

- [x] T4.1 (normal) plan_is_ready detector
      touches: lib/tracker.sh
      do: `plan_is_ready()`: return 0 when the tracker has ≥1 open task line
          carrying an explicit (trivial|normal|hard) tag AND contains no
          template placeholder marker `_(` anywhere in the file. NOTE: the
          PLAN.seed.md template ships with TAGGED tasks, so a tag alone does
          not mean "ready" — the placeholder markers (`_(exact paths)_`,
          `_(replace ...)_`) are the seed's real signature. An untagged bare
          checkbox plan is also "not ready". A tracker with only [x] tasks is
          ready (nothing to plan).
      accept:
          Given the PLAN.seed.md template
          When plan_is_ready runs
          Then it returns 1 (placeholder markers present despite tags)
          Given this PLAN.md
          Then it returns 0
          Given a plan with untagged checkboxes only
          Then it returns 1
      verify: bash test/selftest.sh   (add cases: seed→not ready, this plan→
          ready, untagged→not ready, all-done→ready)
      constraints: pure grep/sed/awk; no state.

- [x] T4.2 (hard) auto-plan → branch → PR #0 → merge-gate in the run path
      touches: bin/ratchet, lib/commands.sh
      do: In main(), when PR_CADENCE=milestone and ! plan_is_ready: create
          branch ratchet/plan off the default branch, run ONE plan turn
          (existing cmd_plan body — extract its turn+commit core into a helper
          `plan_turn` so cmd_plan and this path share it), push, open PR #0
          titled "ratchet plan: <repo>" with the tracker diff summary as body,
          then wait_for_merge. On merge: continue straight into the build loop
          (NO emit_plan_review_stop in this path — the PR merge WAS the
          review). Standalone `ratchet plan` keeps today's hard stop unchanged.
          When PR_CADENCE=done, behavior is unchanged (no auto-plan).
      accept:
          Given PR_CADENCE=milestone, a not-ready tracker, stubbed pi + gh
          When ratchet run starts
          Then a ratchet/plan branch with a plan commit is pushed, a PR is
          opened, and the loop proceeds only after the stub reports MERGED
          Given PR_CADENCE=done
          Then no plan turn runs and startup is unchanged
      verify: bash test/selftest.sh   (add integration case with stubbed
          pi/gh/git remote fixture)
      constraints: plan turn commits ONLY tracker + LEARNINGS.md (existing
          plan_commit); the mandatory-stop code path must remain for
          cmd_plan/cmd_new.

## Milestone 5 — milestone branches, review turn, PR per milestone
> The bounded context for a PR = one milestone (planner-sized, ≤~400 lines).

- [x] T5.1 (normal) milestone branch lifecycle
      touches: bin/ratchet
      do: When PR_CADENCE=milestone, before the first turn of each milestone
          (detect: current milestone name differs from .ratchet/milestone.cur,
          a printf'd one-line state file holding "name<TAB>base-sha"), create
          branch ratchet/m-<slug-of-name> off the current default-branch HEAD
          and record name + base sha in .ratchet/milestone.cur. The build loop
          otherwise runs unchanged on that branch.
      accept:
          Given a fresh milestone starting
          When the loop begins its first turn
          Then HEAD is a new ratchet/m-* branch and .ratchet/milestone.cur
          holds the milestone name and base sha
      verify: bash test/selftest.sh   (fixture repo: branch created once, not
          recreated on later turns of the same milestone)
      constraints: .ratchet/ is already gitignored by init; keep it that way.

- [x] T5.2 (hard) milestone-complete detection + review turn (≤2 cycles)
      touches: bin/ratchet, lib/run-turn.sh (reuse), templates/REVIEW.prompt.md (new)
      do: After each green commit, when the just-worked milestone has no
          remaining open/IN PROGRESS tasks (compare tracker_current_milestone
          against .ratchet/milestone.cur), emit frozen line
          `milestone-complete | m=<name>` and run ONE review turn: run_turn on
          the review tier (chain_for_tier review), prompt from a new template
          REVIEW.prompt.md — read-only review of `git diff <base-sha>..HEAD`,
          instructing: adopt 4 perspectives (principal engineer, security,
          product, devil's advocate); MAY spawn ≤4 read-only subagents via the
          subagent tool if the diff is large (verified available in headless
          pi); verdict = print REVIEW_PASS, or REVIEW_FAIL after appending
          must-fix tasks as tagged `- [ ]` lines at the TOP of the current
          milestone in the tracker (the agent writes the tasks; the harness
          parses nothing). CLASSIFICATION: call run_turn with the token
          globals swapped for the duration of the call — STEP_TOKEN=REVIEW_PASS
          DONE_TOKEN=REVIEW_FAIL (restore both after) — so the existing
          watchdog early-break AND classify_turn work unmodified: class step ⇒
          pass, class done ⇒ fail, any error class ⇒ reviewer error. Never
          strike/bench the review model into the build loop's model state;
          review errors use only the skip policy below.
          FAIL → commit tracker (plan_commit-style, markdown only), loop back
          to build; bound with a cycle counter in .ratchet/milestone.cur
          (third field); after MAX_REVIEW_CYCLES fails → notify_human + stop.
          PASS or review turn errors twice → proceed to T5.3 (a broken
          reviewer must not wedge the pipeline; emit a loud skip line).
      accept:
          Given a milestone whose last task just went [x] and a stub agent
          printing REVIEW_PASS
          Then loop.log gains milestone-complete and review-pass lines and the
          loop proceeds to the PR step
          Given a stub printing REVIEW_FAIL with 2 injected fix tasks
          Then the tracker gains 2 open tasks in the milestone, cycle=1, and
          the build loop resumes
          Given MAX_REVIEW_CYCLES exceeded
          Then the loop stops with a HUMAN NEEDED line
      verify: bash test/selftest.sh   (stubbed-agent cases: pass, fail+inject,
          cycle bound, reviewer-error skip)
      constraints: review turn is advisory — the green gate still gates every
          commit; review gates the PR only. New loop.log lines additive:
          milestone-complete, review-pass, review-fail, review-skip.

- [x] T5.3 (normal) PR per milestone + merge-gate + size warning
      touches: bin/ratchet
      do: Refactor maybe_push_or_pr into `open_milestone_pr NAME BASE_SHA`:
          push the milestone branch, `gh pr create` with title
          "ratchet <m-name>: <first completed task subject>", body = completed
          task list for THIS milestone + `git diff --stat <base>..HEAD` + the
          review verdict line. If changed lines > PR_SOFT_MAX_LINES, prepend a
          "⚠ large PR" warning to the body and emit it (soft — never blocks).
          Then wait_for_merge (M3). On merge: default branch is current and
          ff'd (wait_for_merge did it) → next milestone (T5.1 cuts the next
          branch off fresh main → PRs never stack). ALL_DONE path: when
          PR_CADENCE=milestone the final milestone PR replaces today's global
          PR; when done, today's maybe_push_or_pr behavior is untouched.
      accept:
          Given a review-passed milestone and stubbed gh
          When open_milestone_pr runs
          Then the PR body contains only this milestone's tasks + diffstat and
          the loop blocks until the stub reports MERGED, then resumes on main
          Given a diff larger than PR_SOFT_MAX_LINES
          Then the body and the log carry the large-PR warning
      verify: bash test/selftest.sh   (stub gh: body content, size warning,
          resume-on-main)
      constraints: no `gh pr merge`; PR_CADENCE=done path byte-identical.

## Milestone 6 — observability + docs
- [x] T6.1 (normal) status/stats surface the new state
      touches: lib/commands.sh, lib/observability.sh
      do: cmd_status: show current node (plan-wait|build|review|merge-wait,
          derived from the newest of the new loop.log lines), review cycle
          count, and "waiting on PR <branch> since <ts>" when in merge-wait.
          cmd_stats: count review-pass/review-fail/milestone-complete lines.
      accept:
          Given a loop.log fixture containing the new lines
          When ratchet status / stats run
          Then node, cycle count, and review tallies render
      verify: bash test/selftest.sh   (fixture-log cases)
      constraints: parse only the frozen line grammar; additive.

- [x] T6.2 (trivial) README + conf example docs for the PR-gated flow
      touches: README.md, templates/ratchet.conf.example
      do: Document PR_CADENCE=milestone flow with the 5-node diagram (plan PR
          #0 → build → review → PR → merge-gate), the trilemma rationale (why
          the loop waits instead of stacking), NOTIFY_CMD examples (macOS
          afplay/osascript, Linux notify-send), MERGE_WAIT_TIMEOUT=72h default,
          and `ratchet models rank`.
      accept:
          Given the README
          Then a new "PR-gated autonomy" section documents every new conf key
      verify: bash test/selftest.sh
      constraints: docs only.

- [x] T6.3 (hard) OPTIONAL — outcome-based rank demotion from loop.log stats
      SKIPPED: zero timeout/hard/exhausted failures in logs; price heuristic
      has not proven insufficient. Speculative code = YAGNI. Revisit when
      evidence exists that price-based ranking fails in practice.

## Milestone 7 — turn economics, part 2 (speed follow-ups)
> Part 1 landed by hand (salvage-on-timeout, STALL_TIMEOUT=120, no double-
> verify, task-block injection). These are the bigger follow-ups from the
> 2026-08-07 run postmortem (T1.2 trivial task burned ~2h across 13 turns).

- [x] T7.1 (normal) per-task session resume: warm retries on the same task
      touches: bin/ratchet, lib/run-turn.sh
      do: When a turn ends timeout/stall/transient and the NEXT turn works the
          SAME task id, pass --session-id ratchet-task-<taskid> instead of
          --no-session so the retry resumes with context instead of cold
          rediscovering (~39k tokens + 2-5min per retry). First attempt of a
          task stays ephemeral. Sanitize the session (existing machinery)
          before resume. Clear/rotate the per-task session once the task goes
          [x]. Task id from tracker_next_id_and_text; fall back to ephemeral
          when the id is "?".
      accept:
          Given a turn that times out on task T9.9
          When the next turn starts and T9.9 is still the current task
          Then the agent is invoked with --session-id ratchet-task-T9.9
          Given the task changed between turns
          Then the turn is ephemeral (--no-session) as today
      verify: bash test/selftest.sh   (add cases: retry-same-task resumes,
          new-task ephemeral, "?" id ephemeral)
      constraints: default path (happy turns) stays ephemeral — the token
          economy invariant holds; sessions only pay for themselves on retries.

- [x] T7.2 (normal) diagnose + classify the silent 18-95s transient deaths
      touches: lib/classify.sh, lib/run-turn.sh
      do: The 2026-08-07 run had 7 turns where pi exited in 18-95s with no
          token and no matched error (classified transient, burned backoffs).
          Capture the agent's exit code in run_turn (wait "$pid" already
          collects it in bounded_reap — preserve it into a global) and log it
          on the frozen turn-end line as an ADDITIVE field (exitcode=N).
          Inspect a real failure output, add the unmatched error shape(s) to
          classify.sh so they route to the right class (exhausted/hard)
          instead of transient.
      accept:
          Given a turn whose agent exits nonzero without a token
          Then loop.log's turn-end line carries exitcode=N
      verify: bash test/selftest.sh   (add case: exit code captured; new
          error-shape fixtures classify correctly)
      constraints: loop.log line grammar additive-only.

- [x] T7.3 (trivial) inject gate status into every turn prompt
      touches: bin/ratchet
      do: The protocol now tells the agent to trust the prompt for gate state.
          Always write last_turn.note with an explicit first line:
          "Verify gate after last turn: GREEN" or "... RED (fix this first)" —
          including after salvage commits and error turns (today the note is
          only refreshed on step/done paths, so stale notes can lie).
      accept:
          Given a salvaged (timeout+green) turn
          Then the next turn's prompt says the gate is GREEN
          Given a RED gate turn
          Then the next prompt's first note line says RED
      verify: bash test/selftest.sh   (note content cases)
      constraints: note is one small file; never authoritative over the gate.

- [x] T7.4 (normal) speed up the selftest itself (60s real vs 12s CPU)
      touches: test/selftest.sh, lib/common.sh, lib/run-turn.sh
      done: Root cause was NOT mktemp/git-init (86 inits total ~0.8s) but the
          loop's two inter-turn sleeps paid by every `ratchet once`: SHORT_SLEEP
          (2s post-turn) + the watchdog poll granularity (hardcoded `sleep 3`).
          Suites 8/17 run the loop ~15x = ~30s of dead wait against the instant
          fake-agent. Fix: made both env-overridable (POLL_INTERVAL default 3,
          SHORT_SLEEP default 2 unchanged in prod) and set SHORT_SLEEP=0 /
          POLL_INTERVAL=0.2 in the selftest. 65s -> 40s real, 297/297 green.
          Remainder is ~1.9s fixed startup x ~15 loop invocations; driving under
          20s would mean cutting real end-to-end cases, which the constraint
          forbids. ponytail: per-run startup floor, upgrade path = share one
          fixture repo across suite-17 cases if the gate ever needs <20s.
      do: The gate runs the full suite before every commit; 60s real vs 12s
          CPU means ~48s is sleeps/process-spawn overhead. Hunt sleeps and
          serial mktemp-heavy fixtures; batch or drop waits where the assert
          doesn't need them. Target: full suite under ~20s real. No case
          deleted, count never drops.
      accept:
          Given bash test/selftest.sh on a dev machine
          Then it passes with the same (or higher) case count in <20s real
      verify: time bash test/selftest.sh
      constraints: additive baseline invariant (234+ cases stay green).

## Milestone 8 — parallel worktree fanout (race-safe + self-cleaning)
> Run independent milestones concurrently, one git worktree each. Research
> (claude-code#47266, #55724; amitkoth git-worktree-shared-state, git v2.50.1
> source) established the three hazards this milestone MUST design around:
> (1) `git worktree add` writes shared `.git/config` → config.lock race at
>     CREATION, before any agent runs → creation must be SERIAL.
> (2) `refs/stash` is SHARED across worktrees (only refs/worktree|bisect|
>     rewritten are per-tree) → an agent `git stash pop` can apply a sibling's
>     edit, silently, exit 0 → forbid stash in parallel mode.
> (3) a stashed mid-task tree reports dirty=0/unpushed=0/merged=yes → naive
>     sweeps DELETE live work → cleanup gates must fail toward KEEP.
> The loop is a process supervisor: worktrees isolate the working dir + index;
> everything under `.git/` (objects, config, refs, stash) is shared. The design
> serializes the few shared WRITES and never checks out the default branch off
> a parallel loop.

- [x] T8.1 (normal) PARALLEL mode: on-branch loop, never checkout default branch
      touches: bin/ratchet, lib/common.sh, lib/contract.sh, templates/ratchet.conf.example
      do: Add PARALLEL default 0 in common.sh + allowlist PARALLEL in
          CONTRACT_KEYS (numeric). When PARALLEL=1, `wait_for_merge` must NOT
          `git checkout <default>` / `git pull --ff-only` (bin/ratchet:236-237)
          — that shared-ref write is the corruption path when N loops run. In
          PARALLEL mode the loop stays on its own ratchet/m-<slug> branch for
          its whole life: poll the PR, and on MERGED simply return 0 and EXIT
          the loop (no branch switch, no pull). Keep the serial (PARALLEL=0)
          path byte-identical. Export GIT_OPTIONAL_LOCKS=0 for the loop's git
          calls to cut read-side lock pressure on shared .git.
      accept:
          Given PARALLEL=1 and a stub gh returning OPEN then MERGED
          When wait_for_merge runs
          Then it returns 0 without any `git checkout`/`git pull` and HEAD is
          still the milestone branch
          Given PARALLEL=0 (default)
          Then wait_for_merge behavior is byte-identical to today (ff's main)
      verify: bash test/selftest.sh   (stub gh: parallel path stays on branch;
          serial path still checks out+ff's main)
      constraints: additive; PARALLEL=0 default path unchanged. No `gh pr merge`.

- [x] T8.2 (normal) forbid git stash in parallel mode (shared-stash guard)
      touches: templates/AGENTS.md (protocol), lib/common.sh (proto text)
      do: `refs/stash` is shared across worktrees, so an agent stash in one
          worktree is visible/poppable in another. Ratchet already commits only
          through the green gate — stash should never appear. When PARALLEL=1,
          the turn-prompt protocol gains one line: "NEVER run `git stash` — the
          stash stack is shared across parallel worktrees; commit through the
          gate or leave the tree dirty for the next turn." This is prompt-only;
          no harness code parses stash. (If a WIP save is ever needed the
          per-worktree plumbing is `git update-ref refs/worktree/wip $(git
          stash create)` — documented in T8.4, not automated here.)
      accept:
          Given PARALLEL=1
          When the turn prompt is built
          Then it contains the no-stash instruction
          Given PARALLEL=0
          Then the prompt is unchanged
      verify: bash test/selftest.sh   (prompt contains/omits the line by mode)
      constraints: prompt text only; protocol markers unchanged; additive.

- [IN PROGRESS] T8.3 (hard) fanout orchestrator: serial worktree creation, parallel loops
      touches: bin/ratchet, lib/commands.sh, lib/tracker.sh
      do: New `ratchet fanout [REPO]` subcommand. Requires PARALLEL=1 + gh +
          origin. Steps, in order:
          (1) Parse the tracker for milestones whose FIRST open task carries an
              `(independent)` tag (new tag, additive to the tag grammar in
              tracker.sh) — only these may run concurrently; untagged milestones
              stay serial. `fanout_independent_milestones()` echoes their
              names/slugs.
          (2) SERIALLY (config.lock race is at creation): for each, `git
              worktree add ../ratchet-wt-<slug> -b ratchet/m-<slug>
              origin/<default>`. On the lock error, retry w/ backoff (5x, 1s
              doubling) — the documented workaround. Record created paths in
              .ratchet/fanout.state (one path<TAB>branch per line).
          (3) Fan out: `(cd <wt> && PARALLEL=1 ratchet run) &` per worktree,
              bounded by a FANOUT_MAX (default 4) concurrency cap; `wait` for
              all. Each loop is fully isolated (own working dir, own
              .ratchet/, own LOG_DIR slug — project_slug already keys on path).
          (4) On completion, call fanout_clean (T8.4).
      accept:
          Given a tracker with 2 (independent)-tagged milestones, stub gh/git
          When ratchet fanout runs
          Then 2 worktrees are created serially on ratchet/m-* branches, 2
          loops run, and fanout.state lists both paths
          Given no (independent) tags
          Then fanout runs nothing and prints a clear "no independent
          milestones" message
      verify: bash test/selftest.sh   (stubbed: serial-create order, state
          file, concurrency cap; retry-on-lock path)
      constraints: creation SERIAL (never parallel worktree add); PARALLEL=0
          repos never enter this path; no `gh pr merge`.

- [ ] T8.4 (hard) fanout_clean: fail-safe worktree sweep + prune hook
      touches: bin/ratchet, lib/commands.sh, README.md
      do: `ratchet fanout-clean [REPO]` + a `git worktree prune` call at the
          START of every `ratchet run` (cheap; only drops already-gone admin
          entries — anti-bloat with no cron). The sweep, per worktree in `git
          worktree list --porcelain` (skip the primary):
            GUARD 1 (shared stash): if `git stash list` has a `(WIP )?[Oo]n
              <branch>:` entry → KEEP (the Trap-3 data-loss bug).
            GUARD 2 (unpushed): if `git -C <wt> log --branches --not --remotes`
              is non-empty → KEEP.
            Then `git worktree remove <wt>` — NEVER `--force`: git's own
              refusal of dirty trees IS the backstop (it's what actually saved
              50 worktrees in the field report, not any classifier). On success
              `git branch -D <branch>`; drop the line from .ratchet/fanout.state.
          EVERY gate that cannot answer (grep/git error) must fall through to
          KEEP — a deletion gate returns the data-preserving answer on failure.
      accept:
          Given a worktree whose branch appears in the shared stash
          Then fanout-clean KEEPS it (never removed)
          Given a clean, pushed, merged worktree
          Then fanout-clean removes it and deletes its branch
          Given a dirty worktree
          Then `git worktree remove` (no --force) refuses and it is KEPT
      verify: bash test/selftest.sh   (fixture: stash-guard keep, dirty-refuse
          keep, clean-merged sweep, prune drops stale entry)
      constraints: NEVER --force; all gates fail toward KEEP; prune is
          idempotent. `ponytail: coarse per-repo sweep, upgrade path = age-based
          retention if worktrees outlive their PRs.`

## Non-goals
- Cross-worktree work-stealing / dynamic rebalancing (M8 is static: one
  independent milestone per worktree, fixed at fanout time).
- Automatic conflict resolution when independent milestones touch the same
  files (the `(independent)` tag is a human assertion; overlapping edits
  surface as PR merge conflicts, resolved by the human at merge — the gate).
- Harness-side subagent orchestration (the agent's own subagent tool covers
  fan-out review).
- Stacked PRs (`gh pr create --base <prev>`) — explicitly rejected; the
  merge-gate is the chosen trade.
- Auto-merge of any PR. The human merges, always.
- Turning PR review comments into fix tasks (future enhancement).
