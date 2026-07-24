# =============================================================================
#  session-sanitize.sh — cross-provider session continuity (OPTIONAL)
# =============================================================================
#  Providers sign assistant "thinking" blocks differently: Anthropic emits
#  cryptographic signatures, others emit a "reasoning_content" placeholder.
#  Replaying one provider's signed thinking to another fails (Anthropic ->
#  HTTP 400 "Invalid signature in thinking block"). Before a resumed turn we
#  rewrite the session in place: drop every assistant `thinking` block,
#  preserving text + tool calls, never leaving an empty assistant message.
#
#  SCOPE: this is Pi's JSONL session format specifically. For other agent CLIs
#  it is a documented no-op (the loop simply has no session file to sanitize).
#  Ship it optional; do not overclaim generality. Ephemeral turns (the default)
#  never need it — there is no replay.
# =============================================================================
#  Pure stdlib python3 (json), no jq dependency. Snapshots are kept so the
#  original is recoverable.
# =============================================================================

sanitize_session() {  # sanitize_session FILE
  local file="$1"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  command -v python3 >/dev/null 2>&1 || { vlog "python3 missing; skip sanitize"; return 0; }

  local snapdir="$LOG_DIR/session-snapshots"; mkdir -p "$snapdir"
  local result
  result=$(python3 - "$file" "$snapdir" <<'PY'
import json, sys, os, time, shutil

src, snapdir = sys.argv[1], sys.argv[2]

def is_thinking(block):
    return isinstance(block, dict) and block.get("type") == "thinking"

stripped = 0; rewrote_lines = 0; out_lines = []
try:
    with open(src, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line.strip():
                out_lines.append(line); continue
            try:
                obj = json.loads(line)
            except Exception:
                out_lines.append(line); continue
            msg = obj.get("message") if isinstance(obj, dict) else None
            if (isinstance(obj, dict) and obj.get("type") == "message"
                    and isinstance(msg, dict) and msg.get("role") == "assistant"
                    and isinstance(msg.get("content"), list)):
                content = msg["content"]
                kept = [b for b in content if not is_thinking(b)]
                removed = len(content) - len(kept)
                if removed:
                    if not kept:
                        kept = [{"type": "text", "text": ""}]
                    msg["content"] = kept
                    stripped += removed; rewrote_lines += 1
                    out_lines.append(json.dumps(obj, ensure_ascii=False)); continue
            out_lines.append(line)
except FileNotFoundError:
    print("0 0"); sys.exit(0)

if stripped:
    ts = time.strftime("%Y%m%dT%H%M%S")
    snap = os.path.join(snapdir, f"{ts}_{os.path.basename(src)}")
    try: shutil.copy2(src, snap)
    except Exception: pass
    tmp = src + ".sanitize.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out_lines) + "\n")
    os.replace(tmp, src)

print(f"{stripped} {rewrote_lines}")
PY
) || { vlog "sanitize failed (non-fatal)"; return 0; }

  local n_blocks n_msgs
  n_blocks=$(printf '%s' "$result" | awk '{print $1+0}')
  n_msgs=$(printf '%s' "$result" | awk '{print $2+0}')
  if [ "${n_blocks:-0}" -gt 0 ]; then
    emit "sanitized session: stripped ${n_blocks} thinking block(s) across ${n_msgs} message(s) (snapshot in ${LOG_DIR}/session-snapshots/)"
  fi
}
