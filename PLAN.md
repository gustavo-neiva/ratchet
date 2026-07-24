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

- [IN PROGRESS] T4.2 (trivial) Document the live board.
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

- [ ] T5.1 (trivial) README observability rewrite: the new terminal UX end-to-end.
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
