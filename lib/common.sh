# =============================================================================
#  common.sh — output layer, defaults, and shared helpers for ratchet
# =============================================================================
#  Sourced by bin/ratchet. Holds the neutral built-in defaults, the
#  terminal+log output functions, the project slug derivation, and usage().
#
#  Nothing in this file knows about your project. All project specifics live
#  in the target repo's .ratchet.conf / AGENTS.md / PLAN.md (see lib/contract.sh,
#  lib/tracker.sh). The agnosticism self-test grep-checks the whole tool for
#  stray project knowledge (see test/selftest.sh).
# =============================================================================

PROG="${PROG:-ratchet}"
RATCHET_HOME="${RATCHET_HOME:-$HOME/.ratchet}"
GLOBAL_CONF="${GLOBAL_CONF:-$RATCHET_HOME/conf}"   # sourced; trusted; NOT agent-writable
RATCHET_PROTOCOL_VERSION="1"

# ----------------------------- neutral defaults ------------------------------
# Precedence (highest wins):  CLI flags  >  repo .ratchet.conf (parsed)  >
#                              global conf (sourced)  >  these built-ins.
# All built-ins are deliberately project-neutral. VERIFY_CMD defaults EMPTY so a
# missing gate is a LOUD red warning every run, never a silent skip.

MODELS=""                       # comma-separated provider/id chain, e.g. "zai/glm,anthropic/claude"
TURN_TIMEOUT=1800               # max wall-clock seconds for ONE agent turn (hang defense)
STALL_TIMEOUT=300               # kill a turn whose output stops growing this long (streaming agents only)
SHORT_SLEEP=10                  # seconds between normal turns
MAX_TRANSIENT=3                 # consecutive transient/hard failures before a model is benched
MAX_DONE_GATE_FAILS=3           # consecutive ALL_DONE turns blocked at the commit gate before the loop stops for human review (a done agent can't self-repair a structural gate failure)
COOLDOWN=14400                  # seconds a benched model is skipped (≈ common daily-quota refresh)
BOTH_WAIT=14400                 # seconds to wait when ALL models are benched, then reset

STEP_TOKEN="STEP_COMPLETE"      # agent prints this when ONE step is done
DONE_TOKEN="ALL_DONE"           # agent prints this when ALL work is done

AGENT_CMD="pi"                  # headless agent command (pluggable: pi | claude | any -p-style CLI)

# --- commit-per-turn (the loop owns the commit, gated on green) ---
COMMIT_EACH_TURN=1              # 1 = the loop stages + commits each green turn
COMMIT_VERIFY_GATE=1            # 1 = re-run VERIFY_CMD before committing; RED never commits
VERIFY_CMD=""                   # project green gate; run from repo root. Empty = LOUD warning (never silent)
PUSH_ON_DONE=0                  # 1 = push once, only after ALL_DONE (shared-state; human by default)
OPEN_PR=0                       # 1 = after ALL_DONE push + open a PR/MR via gh/glab (human merges)
APPROVE_UI=0                    # 1 = open local diff-review UI before push/PR (opt-in, v1)
COMMIT_EXCLUDE_GLOBS=""         # paths to un-stage before each commit (runtime junk)
ALLOWED_PROVIDERS=""            # comma list; unset = global chain. Data-governance per repo

THINKING=""                     # reasoning level passed each turn (off|minimal|low|medium|high|xhigh)

# --- tiered model routing (v1.1) ---
PLAN_MODELS=""                  # comma-separated chain for plan-drafting turns (unset → MODELS)
BUILD_MODELS=""                 # comma-separated chain for normal/hard tasks (unset → MODELS)
LIGHT_MODELS=""                 # comma-separated chain for trivial tasks (unset → MODELS)
THINKING_PLAN=""                # thinking level for PLAN tier (unset → THINKING)
THINKING_BUILD=""               # thinking level for BUILD tier (unset → THINKING)
THINKING_LIGHT=""               # thinking level for LIGHT tier (unset → THINKING)

# --- fanout strategy (v1.1, default off) ---
FANOUT=""                       # off|scout|scout+review (empty = off). Enables subagent tool on (hard) tasks.

# --- token economy (quota saving) ---
RESUME_SESSION=0                # 0 = EPHEMERAL turns (tracker = memory, cheap). 1 = resume one session.
CACHE_RETENTION="long"          # prompt-cache TTL for the stable prefix (long|short|none)
SANITIZE_THINKING=1             # 1 = strip prior thinking blocks so any provider can continue

# --- feedback / observability ---
QUIET=0                         # 1 = terminal silent; logs only
CHEAP_MODE=0                    # 1 = force ALL tiers to the LIGHT chain (--cheap)
TAIL_LINES=12                   # lines of agent output to echo after a turn
SUMMARY_LINES=4                 # meaningful lines to show in curated summary
HEARTBEAT=15                    # seconds between "still working" pings (0 = off)
STREAM_AGENT=0                  # 1 = live-stream the agent's raw output (noisy)

# runtime (filled by arg parser / main)
REPO_DIR=""
PROMPT_OVERRIDE=""
SESSION_NAME=""
ONCE=0
SELFTEST=0
STATS=0
VERBOSE=0
WATCH=0
COMMAND="run"                   # subcommand: run | init | new | doctor | once | selftest | stats | watch

# output targets (set in main before any emit()/die())
LOOP_LOG=""
TURN_OUT=""

# ----------------------------- output layer ----------------------------------
# emit  MSG...  — narrate to terminal + log (log only if --quiet)
emit() {
  local ts line
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  line="[$ts] $*"
  if [ -z "$LOOP_LOG" ]; then printf '%s\n' "$line"          # before logs are wired up
  elif [ "$QUIET" = 1 ]; then printf '%s\n' "$line" >>"$LOOP_LOG"
  else printf '%s\n' "$line" | tee -a "$LOOP_LOG"; fi
}
# flow  — copy stdin to terminal + log (log only if --quiet). For raw/multi-line.
flow() {
  if [ -z "$LOOP_LOG" ]; then cat
  elif [ "$QUIET" = 1 ]; then cat >>"$LOOP_LOG"
  else tee -a "$LOOP_LOG"; fi
}

# term_only  MSG...  — terminal only, never the log (heartbeats; keeps loop.log signal-only).
term_only() {
  [ "$QUIET" = 1 ] && return 0
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] %s\n' "$ts" "$*"
}

log()  { emit "$*"; }
vlog() { [ "$VERBOSE" = 1 ] && emit "(verbose) $*" || true; }
die()  { emit "FATAL: $*"; exit 1; }

# Build the default per-turn prompt from the finalized tokens (called late).
build_default_prompt() {
  printf 'Do ONE discrete step of work on this repository'"'"'s current task, following the project'"'"'s AGENTS.md instructions. Write all changes to files; do not dump file contents in your reply. When the step is complete, print the token %s on its own line. If there is absolutely no remaining work, print the token %s on its own line instead.' "$STEP_TOKEN" "$DONE_TOKEN"
}

# Build the plan-drafting prompt for ONE `ratchet plan` turn (called late, after
# TRACKER_FILE/STEP_TOKEN are finalized). The agent reads the repo + tracker,
# drafts/refreshes open tasks (Milestone-0 walking skeleton, a tag on every
# task), touches ONLY the tracker + LEARNINGS.md, then prints the step token and
# stops. It must NOT write code or run the loop — plan is a markdown-only turn.
build_plan_prompt() {
  printf 'You are doing a PLAN-drafting turn (ratchet plan), not implementation. Read this repository, read %s, and draft or refresh the open tasks so the plan is concrete and actionable. Rules: keep a Milestone 0 walking skeleton whose verify gate is green; tag EVERY task trivial|normal|hard; make each task ONE discrete step; do NOT write or change code in this turn — only %s and LEARNINGS.md. When you have finished drafting/refreshing the plan, print the token %s on its own line and STOP. Do not run the build loop.' "$TRACKER_FILE" "$TRACKER_FILE" "$STEP_TOKEN"
}

# ----------------------------- project slug ----------------------------------
# basename + 6-char path hash so two repos named "app" never collide in logs.
# Uses cksum (POSIX, always present) for a stable, collision-resistant suffix.
project_slug() {  # project_slug DIR
  local dir="$1" base h
  base="$(basename "$dir")"
  base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"
  h="$(printf '%s' "$dir" | cksum | awk '{print $1}')"
  printf '%s-%s' "$base" "${h:0:6}"
}

usage() {
  cat <<USAGE
Usage: $PROG <command> [REPO_DIR] [OPTIONS]

ratchet — an unattended-but-safe agent loop. Runs a headless coding agent
(pi, or any -p-style CLI) ONE turn at a time against a repo, surviving provider
rate limits, gating every commit on a green test suite, and routing shared-state
actions (push, PR/MR) through a human. A RED tree is never committed.

Commands:
  run    [REPO]   Run the loop unattended until the agent prints ${DONE_TOKEN}. (default)
  once   [REPO]   Run exactly one turn, then exit (testing/debugging).
  init   [REPO]   Stamp AGENTS.md protocol + .ratchet.conf + seed PLAN.md (existing repo).
  new    "<idea>" Scaffold a repo, draft PLAN.md, then STOP for human plan review.
  plan   [REPO]   ONE plan-drafting turn on the PLAN tier, then STOP for human review (never auto-runs).
  doctor [REPO]   Preflight: conf parses, tracker has open tasks, keys live, protocol current.
  selftest         Verify detection + loop logic against fixtures (NO agent calls). Exits 0/1.
  stats   [REPO]  Parse this repo's loop.log and print the baseline metrics, then exit.
  watch   [REPO]  Pretty-print the live session JSONL the agent writes (run in a 2nd terminal).
  models          Model config UX: list | add <provider/id> | remove <provider/id> |
                  thinking <level>. Flags: --tier models|plan|build|light (default:
                  models), --pos first|last|N, --repo (edit .ratchet.conf instead of
                  the global conf), --force (skip pi-registry validation). Ids are
                  validated against 'pi --list-models' (24h cache; doctor warns too).

Options:
  -d, --dir DIR          Repo directory (default: \$PWD). A bare positional works too.
  -p, --prompt TEXT      Prompt sent each turn (default: built-in generic do-one-step prompt).
  -m, --models LIST      Comma-separated fallback chain, provider/id form.
      --agent-cmd CMD    Headless agent command (default: $AGENT_CMD; e.g. claude, /path/to/agent).
  -s, --session NAME     Session id suffix (default: ratchet-<project-slug>).
      --thinking LEVEL   Reasoning level each turn: off|minimal|low|medium|high|xhigh.
      --turn-timeout N   Max seconds for one turn (default: $TURN_TIMEOUT).
      --cooldown N       Seconds to skip a benched model (default: $COOLDOWN).
      --step-token T     Per-step completion token (default: $STEP_TOKEN).
      --done-token T     All-done token (default: $DONE_TOKEN).

  Commit-per-turn (the loop owns the commit, gated on green):
      --commit / --no-commit   Commit after each green turn (default: on).
      --verify-cmd CMD         Green gate re-run before each commit. A RED tree never commits.
                               Empty (default) = LOUD warning, gate skipped, never silent.
      --no-verify-gate         Skip the pre-commit re-verify (commit on the agent's word).
      --push                   Push ONCE after ${DONE_TOKEN} only (default: off; human owns push).
      --pr                     After ${DONE_TOKEN}: push branch + open PR/MR (gh/glab); human merges.
      --approve                Open a local diff-review UI before push/PR (opt-in, v1/unproven).

  Token economy (quota):
      --resume / --no-resume   Ephemeral turns are the DEFAULT (tracker = memory, ~90% cheaper).
      --cache-retention R      Prompt-cache TTL: long|short|none (default: $CACHE_RETENTION).
      --no-sanitize            Don't strip prior thinking blocks (disable only to debug replay).

  Feedback / observability:
      --tail N / --heartbeat N / --stream / --quiet

  Model selection:
      --cheap                  Force ALL tiers to the LIGHT chain (LIGHT_MODELS, else MODELS).
                               The one-word overnight-on-the-cheap-model switch. Use -m for
                               an explicit chain override.

  -v, --verbose          Verbose logging.   -h, --help  Show this help.

Where to look while it runs:
  loop log   \$RATCHET_HOME/logs/<slug>/loop.log        (tail -f to watch)
  agent out  \$RATCHET_HOME/logs/<slug>/last_turn.out    (what the agent said/did)

Config:  repo .ratchet.conf (PARSED, never sourced)  >  $GLOBAL_CONF (sourced)  >  defaults.
USAGE
}
