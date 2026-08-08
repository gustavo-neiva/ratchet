# =============================================================================
#  observability.sh — excerpts, live watch, and baseline metrics
# =============================================================================
#  Every turn is narrated to the terminal AND loop.log. While a turn runs you
#  get a heartbeat; after it finishes you get an excerpt of what the agent said.
#  `ratchet watch` (2nd terminal) pretty-prints the live session JSONL the agent
#  writes. `ratchet stats` parses loop.log into the baseline metrics.
# =============================================================================

# notify_human MSG -> surface a message a human must act on (PR merge, review cap,
# manual merge mode, etc.). Emits the message prefixed "HUMAN NEEDED:", rings the
# terminal bell when stderr is a TTY, and runs NOTIFY_CMD in the background with
# the message as $1. SECURITY: NOTIFY_CMD is an executable command string that
# may live ONLY in the trusted, sourced global conf — T1.2 keeps it OFF the
# repo-conf allowlist, so an agent-adjacent repo .ratchet.conf setting it is
# already rejected by the parser. Never accept it from a parsed source.
notify_human() {
  local msg="$1"
  emit "HUMAN NEEDED: $msg"
  [ -t 2 ] && printf '\a' >&2
  if [ -n "${NOTIFY_CMD:-}" ]; then
    sh -c "$NOTIFY_CMD \"\$1\"" _ "$msg" &
  fi
}

# print_new_bytes OFFVAR -> tail new bytes written to TURN_OUT since last offset.
# Uses byte offsets so it works on bash 3.2 with no external deps.
print_new_bytes() {
  local offvar="$1" sz
  sz=$(wc -c <"$TURN_OUT" 2>/dev/null | tr -d ' '); sz=${sz:-0}
  off=${!offvar:-0}
  if [ "$sz" -gt "$off" ]; then
    tail -c "+$((off+1))" "$TURN_OUT" 2>/dev/null | flow
  fi
  printf -v "$offvar" '%s' "$sz"
}

# show_excerpt -> echo the last SUMMARY_LINES of the agent's output.
# pi --mode json streams give one giant JSON line per event; extract the
# assistant's text (text_delta fragments, unescaped) instead of raw JSON.
show_excerpt() {
  [ "${SUMMARY_LINES:-0}" -gt 0 ] || return 0
  [ -s "$TURN_OUT" ] || return 0
  emit "--- summary ---"
  if head -c 32 "$TURN_OUT" 2>/dev/null | grep -q '^{"type":"session"'; then
    local joined
    # Prefer assistant text; fall back to thinking for reasoning-only models
    # (e.g. kimi-for-coding streams its whole reply as reasoning_content).
    joined=$(grep -E '"type":"(text|thinking)_delta"' "$TURN_OUT" 2>/dev/null \
      | sed -e 's/.*"delta":"//' -e 's/","partial.*//' \
      | awk '{printf "%s", $0}' \
      | sed -e 's/\\"/"/g')
    printf '%b\n' "$joined" | render_summary "$SUMMARY_LINES" | flow
  else
    render_summary "$SUMMARY_LINES" <"$TURN_OUT" 2>/dev/null | flow
  fi
  emit "---"
}

# session_dir_for DIR -> the directory the agent CLI stores its sessions under.
# For pi this is ~/.pi/agent/sessions/<encoded-path>. Used by --watch + sanitize.
session_dir_for() {
  local dir="$1" enc
  enc="-$(printf '%s' "$dir" | sed 's:/:-:g')--"
  printf '%s/.pi/agent/sessions/%s' "$HOME" "$enc"
}

# watch_session -> pretty-print the live session JSONL (run via `ratchet watch`).
# Falls back to raw tail if jq is missing. Exits on Ctrl-C; the loop keeps running.
watch_session() {
  # Source is ratchet's OWN --mode json stream (last_turn.out), which the loop
  # writes+truncates every turn. pi's -p print mode persists NO session .jsonl,
  # so the old glob for *_<SESSION_ID>.jsonl under the pi sessions dir matched
  # nothing — watch failed in both ephemeral (default) and resume modes.
  local f="$TURN_OUT"
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    emit "watch: no live agent output yet at ${f:-<unset>}"
    emit "watch: start the loop first ('ratchet run $REPO_DIR'), then re-run watch."
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    emit "watch: jq not found — falling back to raw tail."
    emit "watching: $f"
    exec tail -n 40 -f "$f"
  fi
  emit "watching live: $f"
  emit "(Ctrl-C to stop watching; the loop keeps running)"
  emit "------------------------------------------------------------"
  # pi --mode json schema v3: message_start carries the user prompt; assistant
  # deltas arrive as message_update.assistantMessageEvent (text_delta streams
  # the reply live; toolcall_delta marks a tool call, deduped per contentIndex).
  tail -n 80 -f "$f" | jq -nrj --unbuffered '
    foreach inputs as $e (
      {seen:{}};
      if $e.type=="message_start" then
        # Each message reuses contentIndex from 1, so reset the per-message
        # toolcall dedup map or later tool names never print (orphan results).
        .seen = {} |
        if $e.message.role=="user" then
          .emit = "\n\u001b[36m> you:\u001b[0m " + (([$e.message.content[]?|select(.type=="text")|.text]|join(" "))[0:160] | gsub("\n";" ")) + "\n"
        else .emit = "" end
      elif $e.type=="message_update" then
        ($e.assistantMessageEvent // {}) as $a |
        if $a.type=="text_delta" and (($a.delta//"")|length)>0 then .emit = $a.delta
        elif $a.type=="thinking_delta" and (($a.delta//"")|length)>0 then .emit = "\u001b[90m" + $a.delta + "\u001b[0m"
        elif $a.type=="toolcall_delta" then
          ($a.contentIndex|tostring) as $k |
          ($a.partial.content[$a.contentIndex] // {}) as $tc |
          (if (.seen[$k]|not) and ($tc.name//null) then .seen[$k]=true | .emit = "\n\u001b[33m>> \($tc.name)\u001b[0m\n" else .emit = "" end)
        else .emit = "" end
      elif $e.type=="tool_execution_end" then .emit = "\n\u001b[32m<- result\u001b[0m\n"
      else .emit = "" end;
      .emit)'
}

# avg_turn_secs LOGFILE -> mean turn duration in seconds from took= lines
# Returns 0 if no took= lines found (old logs without timing).
avg_turn_secs() {
  local logfile="$1"
  [ -f "$logfile" ] || { echo 0; return; }
  awk '/took=[0-9]+s/ {
    match($0, /took=[0-9]+s/)
    s = substr($0, RSTART, RLENGTH)
    sub(/took=/, "", s)
    sub(/s/, "", s)
    sum += s
    count++
  }
  END { print (count>0 ? int(sum/count) : 0) }' "$logfile"
}

# cmd_stats -> parse loop.log into the baseline metrics (step-success rate,
# wasted wall-hours per 100 turns, % turns on the cheap/first model, plus per-tier
# and per-model counts from the `turn N | tier=X | model=Y` log lines, and avg/max
# turn duration from `took=` lines.
cmd_stats() {
  [ -f "$LOOP_LOG" ] || die "no loop.log found at $LOOP_LOG (nothing run here yet?)"
  command -v python3 >/dev/null 2>&1 || die "stats requires python3"
  local cheap_model="${models_arr[0]:-<first-model>}"
  python3 - "$LOOP_LOG" "$cheap_model" <<'PY'
import re, sys, datetime
path, cheap_model = sys.argv[1], sys.argv[2]
ts_re = re.compile(r'^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] (.*)$')
turn_re = re.compile(r'^--- turn (\d+) \| model=(\S+) ---$')
tier_re = re.compile(r'^turn (\d+) \| tier=(\S+) \| model=(\S+) \| thinking=(\S+)$')
took_re = re.compile(r'turn \d+ end \| class=\S+ \| took=(\d+)s')
def parse_ts(s): return datetime.datetime.strptime(s, '%Y-%m-%d %H:%M:%S')
turns=cheap=steps=dones=dl_kills=exhausted=hard=transient=timeout=0
wasted=0.0; cur_ts=None; benched_ts=None
tier_counts={}; model_counts={}; durations=[]
with open(path, encoding='utf-8', errors='replace') as fh:
    for raw in fh:
        m=ts_re.match(raw.rstrip('\n'))
        if not m: continue
        ts=parse_ts(m.group(1)); rest=m.group(2)
        tm=turn_re.match(rest)
        if tm:
            turns+=1
            if tm.group(2)==cheap_model: cheap+=1
            if benched_ts is not None:
                wasted+=(ts-benched_ts).total_seconds(); benched_ts=None
            cur_ts=ts; continue
        tr=tier_re.match(rest)
        if tr:
            tier=tr.group(2); model=tr.group(3)
            tier_counts[tier]=tier_counts.get(tier,0)+1
            model_counts[model]=model_counts.get(model,0)+1
            continue
        tk=took_re.search(rest)
        if tk:
            durations.append(int(tk.group(1)))
            continue
        if 'terminating' in rest and 'deadline' in rest:
            dl_kills+=1
            if cur_ts is not None: wasted+=(ts-cur_ts).total_seconds()
            continue
        if 'step complete' in rest: steps+=1
        elif rest.startswith('agent signaled'): dones+=1
        elif 'EXHAUSTED' in rest: exhausted+=1
        elif 'HARD ERROR' in rest: hard+=1
        elif 'TIMEOUT (deadline' in rest: timeout+=1
        elif 'transient failure' in rest: transient+=1
        elif rest.startswith('ALL models benched'): benched_ts=ts
succ=steps+dones; att=succ+hard+transient+timeout
sr=(succ/att*100.0) if att else 0.0
wh=wasted/3600.0; wp=(wh/turns*100.0) if turns else 0.0; cp=(cheap/turns*100.0) if turns else 0.0
print(f"turns started         : {turns}")
print(f"  on cheap ({cheap_model}): {cheap} ({cp:.0f}%)")
print(f"successes (step+done) : {succ}  (steps={steps} done={dones})")
print(f"failures              : hard={hard} transient={transient} timeout={timeout} exhausted={exhausted}")
print(f"step-success rate     : {sr:.0f}%")
print(f"deadline kills        : {dl_kills}")
print(f"wasted wall-hours     : {wh:.2f}h  ({wp:.2f}h per 100 turns)")
if tier_counts:
    print(f"turns by tier         : {', '.join(f'{k}={v}' for k,v in sorted(tier_counts.items()))}")
if model_counts:
    print(f"turns by model        : {', '.join(f'{k}={v}' for k,v in sorted(model_counts.items()))}")
if durations:
    avg=sum(durations)/len(durations); mx=max(durations)
    print(f"turn duration         : avg={avg:.0f}s max={mx}s")
PY
}
