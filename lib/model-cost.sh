# =============================================================================
#  model-cost.sh — vendor-neutral cost/capability cache from models.dev
# =============================================================================
#  Enriches pi's availability registry (models.sh) with cost + capability
#  metadata. models.dev provides vendor-neutral cost (input/output $/Mtok),
#  reasoning flag, tool_call flag, and context limit. This is BEST-EFFORT
#  enrichment (network-cached, ~11/16 join on 2026-08-05 account) — a missing
#  join never drops a model or fails a turn. Network failure is non-fatal.
#
#  Cache pattern identical to models.sh's pi_model_registry: 24h TTL at
#  $RATCHET_HOME/models.cost. Flat TSV: provider/id<TAB>input<TAB>output<TAB>
#  reasoning<TAB>tool_call<TAB>context. Requires curl + python3 (already the
#  `stats` dep) to parse the 3.4MB nested JSON; awk can't handle it.
# =============================================================================

# _mdev_provider — map pi provider name to models.dev provider name (alias).
# pi `kimi-coding` -> models.dev `moonshotai`; all others pass through.
_mdev_provider() {
  case "$1" in
    kimi-coding) echo "moonshotai" ;;
    *) echo "$1" ;;
  esac
}

# model_cost_registry [refresh] -> echo provider/id<TAB>... lines (empty + rc1
# if curl/parse fails). Default: serve the 24h cache; never call network.
# `refresh` (or missing/stale cache when forced) curls models.dev and flattens
# to TSV via python3.
model_cost_registry() {
  local cache="$RATCHET_HOME/models.cost"
  if [ "${1:-}" != "refresh" ]; then
    [ -f "$cache" ] && cat "$cache"
    return 0
  fi

  # require curl + python3; skip enrichment if absent (best-effort)
  command -v curl >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || return 1

  local json tmp
  tmp="$(mktemp)"
  if ! json="$(curl -fsS --max-time 20 https://models.dev/api.json 2>/dev/null)"; then
    rm -f "$tmp"
    return 1
  fi

  # flatten nested JSON to TSV: provider/id<TAB>input<TAB>output<TAB>reasoning<TAB>tool_call<TAB>context
  if ! python3 - "$tmp" <<'PYEOF' <<< "$json"; then
import json, sys
data = json.loads(sys.stdin.read())
out = open(sys.argv[1], 'w')
for prov, models in data.items():
    if not isinstance(models, dict): continue
    for mid, meta in models.items():
        if not isinstance(meta, dict): continue
        cost = meta.get('cost', {})
        inp = cost.get('input', '')
        outp = cost.get('output', '')
        reas = str(meta.get('reasoning', '')).lower()
        tool = str(meta.get('tool_call', '')).lower()
        ctx = meta.get('limit', {}).get('context', '')
        out.write(f"{prov}/{mid}\t{inp}\t{outp}\t{reas}\t{tool}\t{ctx}\n")
out.close()
PYEOF
    rm -f "$tmp"
    return 1
  fi

  mkdir -p "$RATCHET_HOME"
  mv "$tmp" "$cache"
  cat "$cache"
}

# model_meta PROVIDER/ID -> echo the cached cost line (or empty if no join).
# Returns the full TSV line: provider/id<TAB>input<TAB>output<TAB>reasoning<TAB>tool_call<TAB>context
model_meta() {
  local model="$1" cache="$RATCHET_HOME/models.cost"
  [ -f "$cache" ] || return 0
  
  # try direct match first
  local line
  line="$(grep -m1 "^${model}	" "$cache" 2>/dev/null || true)"
  if [ -n "$line" ]; then
    echo "$line"
    return 0
  fi

  # try provider alias (e.g., kimi-coding -> moonshotai)
  local prov id alias_prov
  prov="${model%%/*}"
  id="${model#*/}"
  alias_prov="$(_mdev_provider "$prov")"
  if [ "$alias_prov" != "$prov" ]; then
    grep -m1 "^${alias_prov}/${id}	" "$cache" 2>/dev/null || true
  fi
}
