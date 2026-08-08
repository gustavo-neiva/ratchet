# =============================================================================
#  commit-gate.sh — green gate + secret scan + conf-tamper check + one commit
# =============================================================================
#  The loop OWNS the commit, so a turn can never land red even if the agent
#  forgets to commit. After a successful step/done turn it:
#    1) re-runs VERIFY_CMD as a hard gate (RED tree is NEVER committed; the turn
#       is left for the next turn to repair). An EMPTY VERIFY_CMD is a LOUD red
#       warning every run (never a silent skip) — no-gate is not safe-by-default.
#    2) secret-scans the staged diff (gitleaks if installed, else a builtin
#       pattern check). A hit blocks the commit exactly like a red verify.
#    3) rejects the turn if .ratchet.conf or the AGENTS.md protocol markers are
#       in the staged diff (the agent may not edit its own contract).
#    4) stages everything, un-stages runtime junk (COMMIT_EXCLUDE_GLOBS).
#    5) commits ONE change with a subject mined from the tracker.
#  Invariant: no green, no commit — and no secrets, and no contract tampering.
# =============================================================================

COMMITTED_THIS_TURN=0
SECRET_BLOCK_REASON=""

# builtin_secret_scan -> greps the staged diff for common secret shapes.
# Used only when gitleaks is not installed. Sets SECRET_BLOCK_REASON on a hit.
builtin_secret_scan() {
  SECRET_BLOCK_REASON=""
  local diff pat
  # Only scan ADDED lines (leading '+', excluding the '+++' file header). Context
  # and removed lines are NOT being introduced by this commit, and scanning them
  # false-positives on any file that legitimately documents/tests a secret shape
  # (e.g. this scanner's own regression fixtures) — which dead-locks the loop.
  # An added line carrying the inline marker `ratchet:allow-secret` is exempt
  # (gitleaks-style allowlist) so test fixtures / docs can hold a secret SHAPE.
  diff="$(git diff --cached 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+ ' | grep -v 'ratchet:allow-secret')"
  # No added lines to scan -> NOT a hit. This function's 0/1 is a boolean
  # (0=block), so "nothing to scan" must return 1 (clean), never 0 (which the
  # `elif builtin_secret_scan` caller reads as a hit -> empty-reason false block).
  [ -n "$diff" ] || return 1
  # patterns: private key headers, AWS keys, OpenAI/Anthropic-style sk-/sk-ant,
  # generic api_key/secret assignments, JWTs, .env file additions.
  if printf '%s' "$diff" | grep -qiE -e '-----BEGIN ((RSA|EC|OPENSSH|DSA) )?PRIVATE KEY-----'; then
    SECRET_BLOCK_REASON="private key material in staged diff"
  elif printf '%s' "$diff" | grep -qiE '(^|[^A-Za-z0-9])(AKIA[0-9A-Z]{16})([^A-Za-z0-9]|$)'; then
    SECRET_BLOCK_REASON="AWS access key id in staged diff"
  elif printf '%s' "$diff" | grep -qiE '(sk-ant-[A-Za-z0-9_-]{20,})|(sk-[A-Za-z0-9]{20,})'; then
    SECRET_BLOCK_REASON="API key (sk-/sk-ant-) in staged diff"
  elif printf '%s' "$diff" | grep -qiE '(api[_-]?key|secret|passwd|password|token)["'"'"' ]*[:=][ ]*["'"'"' ]?[A-Za-z0-9/_+-]{16,}'; then
    SECRET_BLOCK_REASON="likely secret assignment in staged diff"
  elif printf '%s' "$diff" | grep -qiE 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'; then
    SECRET_BLOCK_REASON="JWT in staged diff"
  elif git diff --cached --name-only 2>/dev/null | grep -qiE '(^|/)\.env(\.|$)'; then
    SECRET_BLOCK_REASON=".env file staged"
  fi
  [ -n "$SECRET_BLOCK_REASON" ]
}



# commit_turn TURN MODEL -> 0 if committed (or cleanly nothing-to-commit),
# 1 if the verify gate was RED / a secret / contract tamper was found (the
# caller treats the turn as needing repair, NOT as a clean success).
commit_turn() {
  local turn="$1" model="$2"
  COMMITTED_THIS_TURN=0
  [ "$COMMIT_EACH_TURN" = 1 ] || return 0
  [ -d "$REPO_DIR/.git" ] || { vlog "not a git repo; skip commit"; return 0; }

  # Stage first so the gate scans the actual proposed commit. (Runtime junk is
  # un-staged below, AFTER the gate, so a red verify never commits even partially.)
  git add -A 2>/dev/null
  local g
  for g in $COMMIT_EXCLUDE_GLOBS; do git reset -q -- "$g" 2>/dev/null || true; done
  # .ratchet.conf is human-owned and NEVER part of a loop commit. Silently drop
  # it from staging (git add -A sweeps it in when a repo forgot to gitignore it).
  # Do NOT fail the turn over it: an untracked conf can't be `git checkout`-restored,
  # so the old block looped forever. The real anti-tamper guard (AGENTS.md markers)
  # stays below.
  git reset -q -- .ratchet.conf 2>/dev/null || true

  # 1) secret scan (gitleaks if present, else builtin).
  if command -v gitleaks >/dev/null 2>&1; then
    if ! gitleaks protect --staged --redact >/dev/null 2>>"$LOOP_LOG"; then
      emit "  BLOCKED: gitleaks found a secret in the staged diff — NOT committing."
      return 1
    fi
  elif builtin_secret_scan; then
    emit "  BLOCKED: secret scan — ${SECRET_BLOCK_REASON} — NOT committing."
    emit "  (install gitleaks for richer coverage; this is the builtin pattern check.)"
    return 1
  fi

  # 2) hard green gate: re-verify before committing anything.
  if [ "$COMMIT_VERIFY_GATE" = 1 ]; then
    if [ -n "$VERIFY_CMD" ]; then
      emit "  commit gate: running '$VERIFY_CMD' …"
      if ! ( cd "$REPO_DIR" && eval "$VERIFY_CMD" ) >>"$LOOP_LOG" 2>&1; then
        # capture the verify's actual last failure line BEFORE emitting the RED
        # banner (emitting first made the capture grab its own banner — 17 junk
        # "commit gate RED" lines polluted LEARNINGS.md and every turn's context).
        local _lrn="$REPO_DIR/LEARNINGS.md" _err _ts
        _err=$(tail -n 20 "$LOOP_LOG" | grep -v '^[[:space:]]*$' | grep -v 'commit gate' | tail -n1)
        emit "  commit gate RED — NOT committing; leaving work for next turn to repair."
        [ -n "$_err" ] && _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" && {
          grep -qxF "$_err" "$_lrn" 2>/dev/null || {
            echo "## auto-captured" >>"$_lrn" 2>/dev/null || true
            echo "$_err  # $_ts" >>"$_lrn" || true
            tail -n 50 "$_lrn" >"$_lrn.tmp" 2>/dev/null && mv "$_lrn.tmp" "$_lrn" 2>/dev/null || true
          }
        }
        return 1
      fi
    else
      emit "  \033[31mWARNING: VERIFY_CMD is empty — committing with NO green gate (no-gate is loud by design; set VERIFY_CMD in .ratchet.conf).\033[0m"
    fi
  fi

  # 3) nothing staged? idempotent turn — fine.
  if git diff --cached --quiet 2>/dev/null; then
    emit "  nothing staged to commit (idempotent turn)."
    return 0
  fi

  # 4) ONE commit with a traceable subject.
  local subject
  subject="$(tracker_completed_subject)"
  if git commit -q -m "auto(ratchet): turn ${turn} ${model} — ${subject}" \
                -m "Autonomous loop turn ${turn}. verify: green." 2>>"$LOOP_LOG"; then
    COMMITTED_THIS_TURN=1
    emit "  committed: ${subject}"
  else
    emit "  git commit failed (see $LOOP_LOG) — continuing."
  fi
  return 0
}
