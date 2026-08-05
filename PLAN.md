# PLAN.md — ratchet: a project-management terminal UI (readable, PM-grade run view)

> The prior plan (tiered model routing v1.1) is COMPLETE and preserved in git
> history. This plan replaces the tracker with the UI overhaul. Run with
> `bin/ratchet run .` (default tracker = PLAN.md).

Tracker grammar: `[ ]` open → `[IN PROGRESS]` → `[x]` done.
Tags: `(trivial|normal|hard)` and `(serial)`.

## The problem (from a real run, 2026-07-24)

Watching a live run today you get a flat scroll of:
- a `... working (Ns, model=X) | tool_execution_update 1762682b` line **every
  15 seconds** — dozens per turn, ending in a meaningless byte counter;
- a **12-line raw dump** of the agent's inner monologue after every turn;
- machine lines (`turn N | tier=… | task=…`, `tasks: N done / M total`) that
  scroll away and carry **no milestone position, no %, no ETA, no "what now"**.

You cannot answer the four questions a human actually has: **what step am I on,
what is it doing now, how many steps are left, and how long until done.** This
plan makes the terminal answer all four at a glance — a project-management
board, not a log tail.

## The one architectural decision (read before ANY task)

`loop.log` is the machine record: `cmd_stats` and `cmd_status` parse its line
**formats** (`turn N | tier=X | model=Y`, `took=Ns`, `tasks: N done / M total`).
Those formats are **frozen**. All UI work happens in a **new terminal render
layer** that reads the same data and prints for humans. We never trade the
machine log for the pretty view — we add the pretty view on top.

## Design constraints (read before ANY task — non-negotiable)

1. **loop.log formats are frozen (additive only).** Never change, rename, or
   reorder any existing emitted line that `cmd_stats`/`cmd_status` parse. New
   *terminal* rendering may look however it needs to; the log line it derives
   from must still be written verbatim. `stats`/`status` on OLD logs must not
   break.
2. **Zero new deps for the loop core.** bash 3.2 (macOS default): no
   associative arrays, no `${var,,}`, no `mapfile`; no `timeout` binary. Render
   is pure bash + `awk`/`sed`. `ratchet status` may use `python3` (already a
   `stats` dependency) but prefer awk.
3. **Render functions are PURE.** Every `render_*` takes inputs as args or
   stdin and prints a string — no globals read, no files touched, no side
   effects. This is what makes them selftestable with NO agent and NO live loop.
4. **Color is optional and safe.** Emit ANSI only when stdout is a TTY and
   `NO_COLOR` is unset; otherwise plain text. A piped/redirected run (and the
   log) stays clean ASCII.
5. **ETA is honestly labelled.** It is a naive `avg_turn_secs × remaining_open`
   estimate. Always render it prefixed `~` and never present it as a promise.
6. **One task per turn.** Do the task, add its selftest case, run
   `bash test/selftest.sh`, mark `[x]`, print STEP_COMPLETE.
7. Never edit `.ratchet.conf`. Discovered gotchas → LEARNINGS.md (append-only).

## What "good" looks like (the target render)

Per-turn header on the terminal (log still gets its frozen machine lines):

```
◐ Step 33/52  [▓▓▓▓▓▓▓░░░░░ 63%]   M5 · observability & UX  (3/6)
  ▶ T5.4 (normal)  heartbeat shows activity          build · glm-5-turbo
  ⏱ turn 5 · 3m42s   avg 3m00s   ~19 turns / ~57m left
     … editing files (2m18s)
```

`ratchet status` (second terminal / `watch -n5`): the full PM board — progress
bar, milestone tree with per-milestone mini-bars, current task, ETA, and the
one-line "what it's doing now".

## Milestone 0 — safety net + the render seam (serial)

> No UI task runs before this is green. Bootstraps a pure, testable render
> module and the "no green, no commit" gate for it.

- [x] T0.1 (trivial, serial) Baseline: confirm the suite is green and record the count.
      touches: LEARNINGS.md
      do: Run `bash test/selftest.sh`. Confirm it passes. Append one line to
          LEARNINGS.md recording the pass count (e.g. "UI-overhaul baseline:
          selftest N/N green"). Change no code.
      accept:
          Given a clean checkout
          When `bash test/selftest.sh` runs
          Then it exits 0 and LEARNINGS.md records the count
      verify: bash test/selftest.sh
      constraints: no code changes this turn.

- [x] T0.2 (normal, serial) New pure render module + walking-skeleton test.
      touches: lib/render.sh, bin/ratchet, test/selftest.sh
      do: Create `lib/render.sh`. Add two pure functions: `render_bar PCT WIDTH`
          → prints a `[▓▓▓░░░]`-style bar of WIDTH cells filled to PCT percent
          (clamp 0–100, integer math, no globals); and `ansi_ok` → returns 0
          only when stdout is a TTY AND `NO_COLOR` is unset (so callers gate
          color). Source `render.sh` in `bin/ratchet`'s `_mod` loop (add
          `render` to the list). This is the seam every later task builds on.
      snippet:
          render_bar() { # PCT WIDTH -> "▓▓▓░░░"
            local pct=$1 w=$2 fill i out=''
            [ "$pct" -lt 0 ] && pct=0; [ "$pct" -gt 100 ] && pct=100
            fill=$(( pct * w / 100 ))
            for i in $(seq 1 "$w"); do
              [ "$i" -le "$fill" ] && out="$out▓" || out="$out░"; done
            printf '%s' "$out"; }
      accept:
          Given render_bar 63 10
          When it runs
          Then it prints a 10-cell bar with 6 filled cells (63*10/100=6)
          And render_bar 0 5 is all empty, render_bar 100 5 is all full
      verify: bash test/selftest.sh   (new suite "render": render_bar 0/50/100/clamp cells correct)
      constraints: pure functions only; bash 3.2; additive source line only.

## Milestone 1 — kill the noise (serial: heartbeat + excerpt share run-turn/observability)

- [x] T1.1 (normal, serial) In-place heartbeat, human words, no byte counter.
      touches: lib/render.sh, lib/run-turn.sh, test/selftest.sh
      do: Add pure `render_activity EVENTTYPE` to render.sh mapping the pi json
          stream event type to a human verb: `turn_start`→"thinking",
          `tool_execution_update`→"working", `tool_call`→"running a tool",
          else the raw type. In `run-turn.sh`'s heartbeat branch, STOP printing a
          new line every tick and STOP appending `${sz}b`. Instead rewrite ONE
          status line in place: `printf '\r\033[K  … %s (%s)' "$(render_activity
          "$evt")" "$(fmt_dur $elapsed)"` when `ansi_ok`, else keep the current
          newline behaviour (so logs/pipes stay clean). Print a trailing newline
          once the turn's while-loop exits so the next emit starts on a fresh
          line. Heartbeats are `term_only` already (never in loop.log) — keep
          that; only the on-screen form changes.
      snippet:
          render_activity() { case "$1" in
            turn_start) printf 'thinking';;
            tool_execution_update) printf 'working';;
            tool_call|toolCall) printf 'running a tool';;
            *) printf '%s' "${1:-working}";; esac; }
      accept:
          Given a running turn emitting heartbeats to a TTY
          When 10 heartbeats fire
          Then the screen shows ONE line updating in place (no byte counter)
          And render_activity tool_execution_update prints "working"
          And with stdout non-TTY the heartbeat still prints newline-style (log-safe)
      verify: bash test/selftest.sh   (case: render_activity mapping; assert no "b" byte-suffix in the new heartbeat format string)
      constraints: heartbeat stays term_only (never loop.log); bash 3.2; no new deps.

- [x] T1.2 (normal, serial) Curate the post-turn excerpt (summary, not a 12-line dump).
      touches: lib/render.sh, lib/observability.sh, lib/common.sh, test/selftest.sh
      do: The agent's useful output is its FINAL summary, not its whole inner
          monologue. Add pure `render_summary NLINES` reading the extracted
          assistant text on stdin and printing the LAST meaningful block: drop
          blank lines and lines that are pure tool chatter, keep the last NLINES
          (default 4). In `show_excerpt` (observability.sh), pipe the already
          un-escaped text through `render_summary "$SUMMARY_LINES"` instead of
          `tail -n "$TAIL_LINES"`. Add `SUMMARY_LINES=4` default in common.sh
          next to `TAIL_LINES` (leave TAIL_LINES for back-compat / non-json
          agents). Change the banner label from "agent output (last 12 lines)"
          to "summary".
      accept:
          Given a 40-line agent output ending in a 3-line summary
          When show_excerpt renders it
          Then only the trailing ~4 meaningful lines print under a "summary" header
          And blank/whitespace-only lines are dropped
      verify: bash test/selftest.sh   (case: render_summary keeps last 4 non-blank lines from a fixture)
      constraints: json extraction path unchanged (reuse the existing text_delta join); additive default key.

## Milestone 2 — project-management header (serial: milestone parse + turn render)

- [x] T2.1 (normal, serial) Milestone awareness in the tracker parser.
      touches: lib/tracker.sh, test/selftest.sh
      do: Add `tracker_milestones` — for each `## Milestone …` (also match a
          plain `## ` section that contains tasks) print `name<TAB>done<TAB>total`
          counting `[x]` vs `[ ]|[IN PROGRESS]` task lines that fall under that
          heading until the next `## `. Add `tracker_current_milestone` — echo
          `name<TAB>idx<TAB>count<TAB>mdone<TAB>mtotal` for the milestone that
          contains the first open/IN PROGRESS task (idx = its 1-based position
          within that milestone). Pure reads of `$REPO_DIR/$TRACKER_FILE`; add
          next to `tracker_next_tag` — do not touch existing functions.
      accept:
          Given a tracker with "## Milestone 5 …" holding 6 tasks, 3 done
          When tracker_current_milestone runs with the first open task in M5
          Then it echoes the M5 name, its within-milestone index, 3, and 6
          And tracker_milestones lists every milestone with correct done/total
      verify: bash test/selftest.sh   (fixture tracker: multi-milestone counts + current-milestone position)
      constraints: additive functions only; grammar-compatible with untagged trackers; bash 3.2.

- [x] T2.2 (normal, serial) The per-turn PM status block (terminal), machine line unchanged.
      touches: lib/render.sh, bin/ratchet, test/selftest.sh
      do: Add pure `render_status_block DONE TOTAL MNAME MDONE MTOTAL TURN TIER
          MODEL TASKID TASKTEXT` → the multi-line header shown in "What good
          looks like": a `Step D/T [bar PCT%] · Mname (mdone/mtotal)` line, a
          `▶ TASKID (…) TASKTEXT   TIER · MODEL` line. In `bin/ratchet`, keep
          emitting the EXISTING frozen lines to the log (`tasks: … / …`,
          `turn N | tier=…`), but ALSO render this block to the terminal via
          `term_only` (so loop.log is untouched, constraint 1). Feed it from
          `tracker_count_done`, the open count already computed, and
          `tracker_current_milestone`.
      accept:
          Given done=33 total=52, milestone "M5 observability" 3/6, turn 5,
                task T5.4 on build/glm-5-turbo
          When render_status_block runs
          Then output contains "Step 33/52", a 63% bar, "M5 observability (3/6)",
               and "T5.4" with "build · glm-5-turbo"
      verify: bash test/selftest.sh   (assert the block contains Step/percent/milestone/task substrings)
      constraints: frozen log lines still emitted verbatim; block is term_only; pure render.

## Milestone 3 — timing & ETA (serial: both touch observability + render)

- [x] T3.1 (normal, serial) Turn-duration average + ETA math.
      touches: lib/observability.sh, lib/render.sh, test/selftest.sh
      do: Add `avg_turn_secs LOGFILE` — awk the `took=(\d+)s` lines to a mean
          integer (echo 0 if none; old logs without `took=` must not error).
          Add pure `fmt_dur SECS` (→ `57m`, `1h20m`, `42s`) and pure
          `render_eta REMAINING AVGSECS` (→ `~19 turns / ~57m left`; if avg=0 →
          `ETA unknown`). Reuse `fmt_dur` for the heartbeat elapsed too.
      accept:
          Given a log with took=180,took=240,took=120
          When avg_turn_secs runs
          Then it echoes 180
          And render_eta 19 180 contains "~19 turns" and "~57m"
          And a log with no took= lines yields avg 0 → render_eta … "ETA unknown"
      verify: bash test/selftest.sh   (fixture logs: with and without took= lines)
      constraints: additive; awk not python; tolerate malformed/old logs.

- [x] T3.2 (normal, serial) Wire ETA into the status block and the turn-end terminal line.
      touches: lib/render.sh, bin/ratchet, test/selftest.sh
      do: Extend `render_status_block` (or add a `render_timing TURN ELAPSED AVG
          REMAINING` line the block appends) to show
          `⏱ turn N · <dur>   avg <dur>   <render_eta>`. In `bin/ratchet`,
          compute `remaining = open task count`, `avg = avg_turn_secs
          "$LOOP_LOG"`, and render the timing line to the terminal (term_only)
          after the frozen `turn N end | … took=…` machine line. The machine
          `took=` line stays byte-identical (constraint 1).
      accept:
          Given avg 180s and 19 open tasks after a 222s turn
          When the turn-end terminal render runs
          Then it shows "turn N · 3m42s", "avg 3m00s", and "~57m left"
          And loop.log still contains the unchanged "turn N end | class=… | took=222s" line
      verify: bash test/selftest.sh   (render_timing substrings; grep the frozen took= line still present)
      constraints: frozen log line untouched; ETA prefixed `~`; term_only render.

## Milestone 4 — the `ratchet status` PM board (serial: rewrites cmd_status render)

- [x] T4.1 (hard, serial) Rewrite `cmd_status` output into a project-management board.
      touches: lib/commands.sh, test/selftest.sh
      do: Keep every field `cmd_status` already parses (turn, task, tier/model,
          elapsed/took, done/total, loop liveness, last output) — this is a
          RENDER change, not a data change. Replace the flat key/value print
          with: a header (repo + loop-alive dot), `render_bar` progress with
          `Step D/T (PCT%)`, a milestone tree from `tracker_milestones` (each
          `name  mini-bar  mdone/mtotal`, current one marked `▶`), the current
          task + tier/model + elapsed, `render_eta` from `avg_turn_secs`, and a
          single "doing now" line from the last heartbeat-equivalent (last
          meaningful line of last_turn.out via `render_activity`/`render_summary
          1`). Use `ansi_ok` for color. This is the board a human keeps open in
          a 2nd terminal (`watch -n5 bin/ratchet status .`).
      accept:
          Given a fixture LOG_DIR + multi-milestone tracker
          When `ratchet status` runs
          Then output shows a progress bar with Step D/T, a milestone tree with
               per-milestone counts, the current task marked ▶, an ETA line, and
               a loop-alive indicator
          And with no pid file it still reports "not running"
      verify: bash test/selftest.sh   (extend the existing status suite: assert bar, milestone tree, ETA, current-marker present)
      constraints: reuse render_* + tracker_milestones; no new deps beyond existing (python3 optional); keep all parsed fields.

- [x] T4.2 (trivial) Document the live board.
      touches: README.md
      do: In the observability section, add `watch -n5 bin/ratchet status .` as
          the live PM board (native `watch`, zero new deps) and show a sample of
          the new board + turn header. One short subsection.
      accept:
          Given the README observability section
          When a reader looks for "how do I watch a run like a project"
          Then they find the `watch -n5 … status` one-liner and a sample board
      verify: bash test/selftest.sh   (agnosticism grep-check still green; doc-only)
      constraints: doc-only; no project-specific knowledge that would trip the agnosticism grep.

## Milestone 5 — docs + polish (parallel-safe)

- [x] T5.1 (trivial) README observability rewrite: the new terminal UX end-to-end.
      touches: README.md
      do: Rewrite the "Feedback / observability" prose to describe the new
          run-time terminal (PM header, in-place heartbeat, curated summary) and
          the ETA caveat (naive avg × remaining, labelled `~`). Remove the
          description of the old 12-line dump / byte-counter heartbeat.
      accept:
          Given the README
          When a new user reads the observability section
          Then it describes the PM header, in-place heartbeat, curated summary,
               and honestly caveats the ETA
      verify: bash test/selftest.sh
      constraints: doc-only.

## Milestone 6 — loop-analysis round 2: kill the two live dead-classes (serial)

Source: cross-repo `loop.log` analysis (ta_justo / harbor / cookbook / ratchet /
gustavoneiva-dev, 2026-07-24 → 2026-08-04). **P0/P1/P2 of
`RATCHET_COOKBOOK_POSTMORTEM.md` are verified-shipped in `144d1ec` — do NOT
redo them.** This milestone closes only what is still live or stale. The
strongest evidence is the ta_justo A/B: same repo, fixing `VERIFY_CMD` from a
broken `bundle exec rspec` (system Ruby has no bundler 2.6.3 → 12 gate-REDs,
16 turns, 0 commits) to `bin/rubocop && bin/rails test` → 11/11 tasks
committed in 7 turns. That win is locked in by the P0 doctor dry-run; M6 is the
next round.

- [ ] T6.1 (normal, serial) Tamper guard: stop dead-looping on a benign re-stamp.
      touches: lib/commit-gate.sh (`conf_tampered`), lib/commands.sh
      (`stamp_protocol` + new shared `expected_protocol_block`)
      problem: `conf_tampered()` compares the staged AGENTS.md protocol block
      to HEAD's block and fails the turn on ANY diff. But `ratchet init`
      re-stamps the block whenever TRACKER_FILE / VERIFY_CMD / tokens /
      protocol-version change, leaving a legitimate diff vs HEAD. The agent is
      forbidden to edit AGENTS.md, so the tree can never be cleaned → every
      turn RED (gustavoneiva-dev: ~19 turns stuck on T3.1, 2026-07-24/25).
      `.ratchet.conf` avoids this by being silently unstaged
      (`commit-gate.sh:83-88`); AGENTS.md is tracked and the re-stamp SHOULD
      land, so unstaging would lose it forever.
      do:
        1. Extract the block builder out of `stamp_protocol` into a shared
           `expected_protocol_block()` (commands.sh) that renders
           `templates/AGENTS.protocol.md` with the LIVE conf values
           ({{TRACKER_FILE}}/{{VERIFY_CMD}}/{{STEP_TOKEN}}/{{DONE_TOKEN}}).
           Have `stamp_protocol` call it, so init and the gate agree by
           construction (DRY — one builder, two callers).
        2. In `conf_tampered()`: after confirming AGENTS.md is staged and the
           block differs from HEAD, compare the staged block to
           `expected_protocol_block`. If equal → return 1 (NOT tampered) so
           the re-stamp commits normally with the turn's work. Only if
           staged != HEAD AND staged != expected → return 0 (real tamper,
           revert+fail as today).
        3. Make `stamp_protocol` idempotent: skip the rewrite (early return)
           when the existing block already equals the new one, so a no-op init
           stops dirtying the tree at all.
      accept:
        Given a repo whose committed AGENTS.md block has VERIFY_CMD='bin/a'
        When the human changes VERIFY_CMD to 'bin/b' and re-runs `ratchet init`,
          then a turn stages AGENTS.md (e.g. via git add -A) alongside real work
        Then `conf_tampered` returns not-tampered, the turn commits the
          re-stamp + work together, and the gate is GREEN.
        Given the same setup but the agent rewrites the block to arbitrary text
          (not the expected stamp)
        Then `conf_tampered` returns tampered, the change is reverted, RED.
        Given a re-init with NO config change → `stamp_protocol` writes
          nothing, `git diff` empty.
      verify: bash test/selftest.sh (new suite: fixture repo +
        `expected_protocol_block` equality + `conf_tampered` for the 3 cases).
      constraints: bash 3.2-safe; do not change AGENTS.md prose-outside-markers
        being human-owned. The shared builder is the whole point — init and the
        gate must not drift.

- [ ] T6.2 (normal, serial) Bound watchdog reaping so a turn can't run far past TURN_TIMEOUT.
      touches: lib/run-turn.sh (`run_turn` kill/reap tail, after the watchdog loop)
      problem: three turns hit `class=timeout` at took=1816/1970/2365s against a
      1800s cap (cookbook turn 38; harbor). `took=` is measured at
      `bin/ratchet:366` BEFORE `commit_turn`, so the overshoot is inside
      `run_turn`. The watchdog polls every 3s and the kill path is
      `kill; pkill -P; sleep 2; kill -9; pkill -9 -P; wait "$pid"` — the only
      UNBOUNDED call is `wait "$pid"`, which blocks until the kernel reaps the
      (possibly D-state / wedged) agent and its children. A wedged pi child on
      network I/O can sit unreaped for minutes, burning quota past the cap.
      do: Replace the unconditional `wait "$pid"` with a BOUNDED reap. After
        `kill -9 "$pid"; pkill -9 -P "$pid"`, poll `kill -0 "$pid"` in a short
        loop (up to ~10s, `sleep 1`), then if still alive DETACH (return
        without blocking — the OS reaps the orphan later; never let the loop
        stall on it). Keep the existing 2s SIGTERM grace before SIGKILL and the
        `pkill -P` child reaping. Net guarantee: deadline-fire → `run_turn`
        return ≤ ~15s regardless of child state.
      accept:
        Given a turn that hits TURN_TIMEOUT with a wedged (slow-to-reap) child
        When `run_turn` returns
        Then took ≤ TURN_TIMEOUT+15, class=timeout, and the loop proceeds — no
          565s hang.
        Given a turn that hits the deadline and the agent dies cleanly →
          unchanged (took ≈ TURN_TIMEOUT+2).
      verify: bash test/selftest.sh (unit for the bounded-reap helper using a
        deliberately long-lived `sleep 600 &` subprocess, asserting the reap
        returns within the bound). The 3 historical cases can't be replayed, so
        a live-run spot-check is acceptable extra evidence.
      constraints: bash 3.2-safe; NO `timeout` binary (existing constraint). Do
        NOT change TURN_TIMEOUT semantics or the stall-kill path — only the
        post-deadline reap.

- [ ] T6.3 (trivial, serial) Reconcile POSTMORTEM_FIX_PLAN.md with shipped reality.
      touches: POSTMORTEM_FIX_PLAN.md
      problem: the file shows 4 `[x]` / 12 `[ ]`, but P0 (doctor VERIFY_CMD
      dry-run `commands.sh:499-506`; tracker↔AGENTS.md mismatch `:467`), P1
      (task-in-prompt `bin/ratchet:343-348`; parser hardening), and P2 (LEARNINGS
      auto-capture `commit-gate.sh:118`; last_turn.note `bin/ratchet:357,444`)
      all shipped in `144d1ec`. The stale `[ ]` will mislead the next loop /
      reader into redoing finished work.
      do: For each `[ ]`, verify against current source (grep the cited
        file:line). Tick `[x]` with the verifying source pointer, OR — if an
        item is genuinely unshipped — promote it into M6 as a real task instead
        of ticking. Delete the now-redundant "Already done — verify only"
        block (fold its pointers into the ticked lines). End state: no `[ ]`
        describes shipped work.
      accept:
        Given POSTMORTEM_FIX_PLAN.md
        When a reader scans it
        Then every `[ ]` maps to work NOT in current source, and every shipped
          item is `[x]` with a file:line pointer.
      verify: bash test/selftest.sh (doc-only; no code change).
      constraints: doc-only. Never tick a genuinely-unshipped item — promote it.

- [ ] T6.4 (trivial, serial) Lock in "builtin secret scan never blocks with an empty reason".
      touches: test/selftest.sh (suite 10/11 area — builtin secret scan)
      problem: 11 historical log lines read `BLOCKED: secret scan —  — NOT
      committing` (empty reason), incl. one on 2026-08-04 (ta_justo final
      commit). Current `builtin_secret_scan()` cannot produce this — every
      branch sets `SECRET_BLOCK_REASON` and the final `[ -n "$reason" ]` guard
      returns false on empty — so it is most likely a stale-checkout artifact
      from before the `144d1ec` rewrite. Non-reproducible today. Treat as
      non-repro and add a regression guard.
      do: Add selftest cases: (a) a staged diff that matches NO pattern (e.g.
        `x = 1`) → assert `builtin_secret_scan` returns NOT-blocked; (b) a
        matching diff → assert the reason is non-empty. Defensive belt:
        assert the emit line can never be the empty-reason shape.
      accept:
        Given the new selftest
        When `builtin_secret_scan` runs on a no-match diff → not blocked; on a
          match → reason non-empty
        Then the suite is green and the empty-reason class is provably
          impossible in current code.
      verify: bash test/selftest.sh
      constraints: test-only. If (b) FAILS — i.e. the bug IS reproducible — do
        NOT tick; promote to a real fix task in M6 and investigate the live
        code path.

## Milestone 7 — automatic model selection (derive tiers, minimize manual config)

> Goal: the human sets ONE ordering (`MODEL_RANK`) at most, and ratchet derives
> every tier chain from what is authenticated NOW + a cached vendor-neutral
> cost/capability table (models.dev). Per-task tier tags stop being hand-written
> — the PLAN-tier model assigns them as it drafts. Manual `MODELS`/`*_MODELS`
> chains still win when set (override, never removed).
>
> **Assumptions verified against the 16 authenticated models on 2026-08-05 —
> DO NOT re-litigate, they are why this design looks the way it does:**
> 1. `pi --list-models` is ground truth for AVAILABILITY (auth-aware). Already
>    cached at `$RATCHET_HOME/models.registry`.
> 2. models.dev (`https://models.dev/api.json`, no key, provider-keyed JSON with
>    `cost.{input,output}`, `reasoning`, `tool_call`, `limit.context`) is the
>    vendor-neutral cost/capability source. It joins on `provider/id` for
>    **11 of 16** of this account's models; `kimi-coding/*` (5 models) and
>    `claude-mythos-5` MISS (kimi-coding maps to models.dev `moonshotai` but the
>    specific ids are absent). So models.dev is BEST-EFFORT enrichment, never a
>    hard filter — a missing join must not drop a model.
> 3. Capability FLAGS do not discriminate: 11/11 joined models are
>    `tool_call:true` AND `reasoning:true`. So flags cannot rank or tier models.
> 4. Price is NOT a skill proxy: `claude-fable-5` is the priciest ($50/Mtok out)
>    but is a creative-writing model; `claude-sonnet-5` ($10) is cheaper than
>    `claude-sonnet-4-5` ($15) yet newer. Sorting tiers by price is WRONG.
> 5. Therefore the ONLY reliable skill signal is a human-set ordering. The whole
>    milestone reduces manual config to at most ONE line (`MODEL_RANK`), from
>    which all tiers are sliced. The green gate remains the correctness backstop:
>    a too-weak auto-pick fails the gate → strike → the existing cascade, so a
>    wrong guess costs one turn, never a bad commit.

- [ ] T7.1 (normal, serial) Vendor-neutral cost/capability cache (models.dev join).
      touches: lib/model-cost.sh, bin/ratchet (_mod source list), test/selftest.sh
      do: Create `lib/model-cost.sh`. Add `model_cost_registry [refresh]`
          mirroring `pi_model_registry` in models.sh: serve a 24h cache at
          `$RATCHET_HOME/models.cost` by default; on `refresh` (or missing/stale
          cache) `curl -fsS --max-time 20 https://models.dev/api.json` and
          flatten to `provider/id<TAB>input<TAB>output<TAB>reasoning<TAB>tool_call<TAB>context`
          lines via python3 (already the `stats` dep; awk can't parse the 3.4MB
          nested JSON). On curl/parse failure echo nothing + rc1 (callers must
          degrade, never die). Add `model_meta PROVIDER/ID` → echo the one
          cached line (or empty). Add a provider alias map so pi's `kimi-coding`
          joins models.dev `moonshotai` (best-effort; unmatched ids simply have
          no meta). Source `model-cost` in bin/ratchet's `_mod` loop.
      snippet:
          # provider alias: pi name -> models.dev name
          _mdev_provider() { case "$1" in kimi-coding) echo moonshotai;; *) echo "$1";; esac; }
      accept:
          Given a populated models.cost cache
          When `model_meta anthropic/claude-sonnet-4-5` runs
          Then it echoes a line containing input=3 output=15 tool_call=true
          And `model_meta kimi-coding/k3` (no join) echoes empty without error
          And with no network AND no cache, model_cost_registry echoes nothing
               and returns 1 (caller degrades, loop never dies)
      verify: bash test/selftest.sh  (fixture models.cost with 2 rows: one hit,
          one miss; assert model_meta hit/miss + graceful empty on absent cache)
      constraints: bash 3.2; python3 ONLY for the JSON flatten (guarded — skip
          enrichment if absent); network failure is non-fatal; cache pattern
          identical to models.registry; additive source line only.

- [ ] T7.2 (normal, serial) MODEL_RANK: the one manual ordering + tier auto-slice.
      touches: lib/model-select.sh, lib/common.sh (MODEL_RANK default + doc),
          bin/ratchet (_mod source list), test/selftest.sh
      do: Create `lib/model-select.sh`. `MODEL_RANK` (new conf key, optional) is
          a comma list of `provider/id` OR bare `provider` tokens, strongest
          first (e.g. `anthropic/claude-opus-4-8,anthropic/claude-sonnet-4-5,zai/glm-5.2,zai/glm-4.5-air`).
          Add `ranked_available_models` → intersect the live pi registry
          (`pi_model_registry`, availability = ground truth) with MODEL_RANK
          order; models present in the registry but absent from MODEL_RANK are
          appended after, ordered by models.dev output-price ascending (cheap
          last, since unranked ≠ trusted-strong) then id. Add `suggest_chain TIER`
          (TIER: plan|build|light) slicing the ranked list: `plan` → top model +
          next as fallback; `light` → bottom (cheapest-ranked) model + one up as
          fallback; `build` → the model just below plan (or plan's pick if only
          2), + fallbacks down. Apply `ALLOWED_PROVIDERS` filter FIRST (reuse the
          same provider-prefix match as init_models). If MODEL_RANK is unset AND
          fewer than 2 models rank, `suggest_chain` echoes empty (caller keeps
          today's behavior — see T7.3).
      snippet:
          # tiers slice one ranked list: plan=strongest, light=cheapest-ranked,
          # build=middle. 2 models -> plan=build=[0], light=[1]. 1 -> all=[0].
      accept:
          Given MODEL_RANK='anthropic/claude-opus-4-8,anthropic/claude-sonnet-4-5,zai/glm-5.2,zai/glm-4.5-air'
                and all four available in the pi registry
          When suggest_chain plan / build / light run
          Then plan starts with claude-opus-4-8, light starts with zai/glm-4.5-air,
               build starts with a middle model, each with a fallback appended
          And a model in the registry but not in MODEL_RANK is included, ordered
               after the ranked ones
          And with ALLOWED_PROVIDERS=zai, plan/build/light contain only zai models
          And with MODEL_RANK unset, suggest_chain echoes empty (rc non-zero)
      verify: bash test/selftest.sh  (fixture pi registry + MODEL_RANK; assert
          per-tier first model, unranked-append, ALLOWED_PROVIDERS filter, empty-on-unset)
      constraints: bash 3.2 (parallel arrays, no assoc); reuse ALLOWED_PROVIDERS
          match from model-fallback.sh; availability from pi registry is
          authoritative; models.dev only orders the unranked tail (best-effort,
          skip if no meta); additive.

- [ ] T7.3 (hard, serial) Wire suggest_chain into chain_for_tier (override-preserving).
      touches: lib/model-fallback.sh (chain_for_tier), test/selftest.sh
      do: In `chain_for_tier`, keep the EXACT current precedence as the override
          path: if the tier's explicit key (`PLAN_MODELS`/`BUILD_MODELS`/
          `LIGHT_MODELS`) is set, use it unchanged; else if flat `MODELS` is set,
          today it returns `$MODELS` — keep that too. ONLY when BOTH the tier key
          AND `MODELS` are empty (i.e. the human configured no chain at all), call
          `suggest_chain TIER`; if that also echoes empty, fall through to today's
          `die "no models configured"` path in the caller (no silent hang). This
          makes derivation the behavior for a ZERO-config repo while every
          existing repo with a `MODELS=` line behaves byte-identically.
      accept:
          Given BUILD_MODELS set
          When chain_for_tier build runs
          Then it returns BUILD_MODELS unchanged (override wins, byte-identical to today)
          Given ALL of PLAN_MODELS/BUILD_MODELS/LIGHT_MODELS/MODELS empty but
               MODEL_RANK set with 4 available models
          When chain_for_tier plan|build|light run
          Then each returns the suggest_chain slice for that tier
          Given everything empty (no MODEL_RANK, no MODELS)
          Then chain_for_tier echoes empty and the loop's existing
               "no models configured" die path fires (no hang)
      verify: bash test/selftest.sh  (three cases: override-wins byte-identical;
          derive-when-empty; empty-when-nothing preserves die path)
      constraints: bash 3.2; the override path MUST be byte-identical to current
          behavior (guard the existing 300+ line-format + stats tests); only the
          both-empty branch is new; no new die/hang introduced.

- [ ] T7.4 (normal, serial) `ratchet models` shows cost + derived chains.
      touches: lib/models.sh (cmd_models list), test/selftest.sh
      do: In `cmd_models list`, next to each chain member's `[ok|UNKNOWN]`
          registry mark, append its models.dev cost when joined:
          `zai/glm-5.2 [ok] $1.4/$4.4`. When a tier key is UNSET, instead of
          only printing `-> MODELS (flat)`, ALSO show the derived chain in
          parens when MODEL_RANK yields one: `-> derived: <suggest_chain output>`.
          Add a `MODEL_RANK: <value or (unset)>` summary line. Pure display —
          reads model_meta (best-effort) and suggest_chain; no routing change.
      accept:
          Given a joined cost cache and MODEL_RANK set with tiers unset
          When `ratchet models list` runs
          Then each known model shows its $in/$out, and each unset tier shows the
               derived chain it WOULD use
          And a model with no models.dev join shows no price (no error, no "$?/?")
      verify: bash test/selftest.sh  (extend models suite: assert a price string
          appears for a joined model, absent for a miss, derived-chain line shown)
      constraints: display-only; best-effort cost (missing join = no price shown);
          reuse suggest_chain from T7.2; no change to add/remove/thinking subcommands.

- [ ] T7.5 (normal, serial) PLAN-tier model auto-tags each task's tier as it drafts.
      touches: skills/ratchet-plan/SKILL.md, templates/PLAN.seed.md (if it carries
          the tag guidance), lib/commands.sh (build_plan_prompt only if it inlines
          tag instructions)
      do: The strong PLAN-tier model already reads each task to write it — have it
          ASSIGN the tier tag `(trivial|normal|hard)` as part of drafting, with a
          one-line justification, instead of leaving it to the human. Update the
          ratchet-plan skill's "Tags are the model-selection contract" section and
          "Tier pass" step to state the planner tags every task at authoring time
          (human still reviews at the mandatory checkpoint — this is
          automatic-WITH-review, not silent). If `build_plan_prompt` inlines
          tagging guidance, mirror the same instruction there so `ratchet plan`
          turns emit tags. No change to the tag GRAMMAR or the parser.
      accept:
          Given `ratchet plan` drafts a PLAN.md
          When the PLAN-tier model writes each task
          Then every task carries a (trivial|normal|hard) tag with a one-line
               justification, and the human review checkpoint still fires before
               any run
          And the tag grammar + tracker parser are unchanged (old plans still parse)
      verify: bash test/selftest.sh  (doc/prompt change; assert the agnosticism
          grep stays green and skill/README describe planner-assigned tags)
      constraints: no parser/grammar change; the human review checkpoint is
          preserved (never auto-run); prose/prompt change only.

- [ ] T7.6 (trivial) Document automatic model selection.
      touches: README.md
      do: In the model-routing section, add a subsection: "Automatic selection
          (minimal config)". Explain: availability comes from `pi --list-models`;
          cost/capability from models.dev (cached 24h, vendor-neutral, best-effort);
          the human sets at most ONE line, `MODEL_RANK` (strongest→weakest), and
          ratchet slices plan/build/light from it; explicit `*_MODELS`/`MODELS`
          chains still override. State the honest caveat: no free API ranks coding
          skill, so `MODEL_RANK` is the one calibration knob, and the green gate
          catches a wrong auto-pick. Show a zero-tier-chain example using only
          `MODEL_RANK`.
      accept:
          Given the README model-routing section
          When a reader wants "set it up once, let ratchet pick"
          Then they find the MODEL_RANK one-liner, the availability+cost sources,
               the override note, and the skill-ranking caveat
      verify: bash test/selftest.sh  (doc-only; agnosticism grep green)
      constraints: doc-only; vendor-neutral wording (no "use provider X"); no
          project-specific knowledge that trips the agnosticism grep.

## Definition of done

`bash test/selftest.sh` green with ALL new cases (render suite, milestone-parse,
ETA, status board). A live run shows a PM header answering step/now/left/ETA;
heartbeats update ONE line in place with human words and no byte counter; the
post-turn excerpt is a short curated summary; `bin/ratchet status .` renders a
full milestone board with progress bar and ETA; `watch -n5 bin/ratchet status .`
is a usable live board. Every existing `loop.log` line format is unchanged and
`ratchet stats`/`status` still parse old logs.

## Non-goals

- No full-screen/ncurses TUI or alternate-screen redraw — native `watch(1)` +
  in-place heartbeat is the lazy live view.
- No change to any `loop.log` line format, `cmd_stats` parsing, or the tracker
  grammar.
- No new runtime dependency for the loop core (python3 stays optional, only for
  `stats`; the board prefers awk).
- No per-task time tracking beyond the naive turn-average ETA (revisit only if
  the estimate proves misleading in practice).
- No automatic coding-SKILL ranking of models — no free API provides it and
  price is not a proxy (verified: fable-5 priciest yet creative-only). `MODEL_RANK`
  is the human's one ordering knob; ratchet only automates availability, cost
  display, and tier-slicing from that order.
- No live per-turn model re-selection or embedding/classifier router. Tier is
  fixed per task (planner-assigned tag); the green gate + existing strike/cascade
  is the correctness backstop, not a router model.
- models.dev is best-effort enrichment (network-cached, ~11/16 join on this
  account). A missing join never drops a model or fails a turn.
