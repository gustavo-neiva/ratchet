# =============================================================================
#  classify.sh — turn-outcome detection from the agent's output
# =============================================================================
#  The agent is spawned in print mode; its stdout+stderr land in TURN_OUT. The
#  loop classifies the turn by CONTENT, not by exit code: print-mode can hang
#  *after* success (so exit code is unreliable), and a success token on its own
#  line is the authoritative "step done" signal. Failure modes are matched by
#  the provider's own error text. A deadline kill with no token/error is a
#  distinct `timeout` (still working past the cap) vs a `transient` blip.
# =============================================================================
#  All functions take a file path ($2) and return 0 (match) / 1 (no match).
# =============================================================================

# Literal token match: success is the exact token appearing anywhere in output.
_has_token() { grep -qF -- "$1" "$2" 2>/dev/null; }

# JSON-stream token match (pi --mode json): the user prompt (which names the
# tokens) is echoed into the event stream, so only ASSISTANT text completions
# (`text_end` events) count. Never grep the whole file in json mode.
_has_token_json() { grep '"type":"text_end"' "$2" 2>/dev/null | grep -qF -- "$1"; }

# Error scans must look ONLY at transport/error output, never assistant-authored
# text. In json mode (pi --mode json) the agent's own prose streams as text/
# thinking_delta+_end events; scanning the WHOLE file makes any task that merely
# *discusses* "rate limit"/"quota"/"daily limit" (or one named "dependency-scanning")
# false-fire exhausted/hard even at 24% quota. So in json mode strip assistant text
# events before scanning; text mode scans as-is.
_err_scan_src() {  # FILE JSON -> lines the error-matchers may look at
  if [ "${2:-0}" = 1 ]; then
    grep -vE '"type":"(text|thinking)_(delta|end)"' "$1" 2>/dev/null
  else
    cat "$1" 2>/dev/null
  fi
}

# Rate-limit / quota exhaustion. Covers Anthropic 429/529, Z.AI 130x codes,
# and the generic "rate limit / quota / too many requests" family. -> bench model.
_is_exhausted() {  # FILE JSON
  # \\? before quotes: json-mode streams JSON-escape provider errors (\"code\":\"1308\").
  _err_scan_src "$1" "${2:-0}" | grep -qiE '(request failed: HTTP (429|503|529))|(auto_retry.{0,40}429)|(\\?"code\\?"[[:space:]]*:[[:space:]]*\\?"?130[2-8])|(rate_limit_error|overloaded_error)|(rate[ _-]?limit)|(quota)|(usage limit reached)|(insufficient.{0,30}(balance|quota|credit))|(daily.{0,15}(limit|quota))|(too many requests)|(exceed(ed|s)?.{0,15}(quota|limit|balance|rate))' 2>/dev/null
}

# Hard errors: auth, permission, not-found, bad request. -> strike (then bench).
# Includes the cross-provider "Invalid signature in thinking block" 400 (fixed by
# session-sanitize, but still classified hard so a stuck session doesn't loop).
_is_hard_error() {  # FILE JSON
  _err_scan_src "$1" "${2:-0}" | grep -qiE '(request failed: HTTP (400|401|403|404|413|422))|(authentication_error|permission_error|not_found_error|invalid_request_error)|(invalid.{0,10}(api[ _-]?key|token))|(unauthorized)' 2>/dev/null
}

# classify_turn FILE STEP_TOKEN DONE_TOKEN WAS_DEADLINE [JSON]  -> echoes the class
# Order matters: done before step (done is a stricter all-finished signal);
# exhausted before hard (429 is HTTP-4xx-ish but means "retry later", not "broken").
# JSON=1 (pi --mode json): token match restricted to assistant text events.
classify_turn() {
  local file="$1" st="$2" dt="$3" deadline="$4" tok=_has_token
  [ "${5:-0}" = 1 ] && tok=_has_token_json
  if   $tok "$dt" "$file";             then echo "done"
  elif $tok "$st" "$file";             then echo "step"
  elif _is_exhausted  "$file" "${5:-0}"; then echo "exhausted"
  elif _is_hard_error "$file" "${5:-0}"; then echo "hard"
  elif [ "$deadline" = "1" ];          then echo "timeout"
  else                                      echo "transient"
  fi
}
