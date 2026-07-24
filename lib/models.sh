# =============================================================================
#  models.sh — `ratchet models`: list/add/remove/validate model config
# =============================================================================
#  Model ids churn (glm 5.1->5.2, sonnet 4.5->4.6, ...). Before this, editing
#  the tier chains meant hand-typing comma strings into ~/.ratchet.conf and/or
#  .ratchet.conf with zero validation — a typo surfaced as a burned turn, not
#  at edit time. These commands make the edit path one line, validated against
#  pi's live registry (`pi --list-models`, auth-aware).
#
#  The registry call costs ~3s (node startup), so it is CACHED in
#  $RATCHET_HOME/models.registry (24h TTL): the interactive `models` commands
#  refresh it; `doctor` (runs before every loop) only reads the cache and
#  skips validation when it is missing/stale.
#
#  Write-back upserts a single KEY=value line (replacing the existing line,
#  preserving every other line + comment) — the confs stay human-owned,
#  sourced/parsed exactly as before.
# =============================================================================

# parse_pi_models — read a `pi --list-models` table on stdin, echo provider/id.
parse_pi_models() {
  awk 'NF>=2 && $1!="provider" {print $1"/"$2}'
}

# pi_model_registry [refresh] -> echo provider/id lines (empty + rc1 if pi
# unavailable). Default: serve the 24h cache; never call pi. `refresh` (or a
# missing/stale cache when forced) calls pi and rewrites the cache.
pi_model_registry() {
  local cache="$RATCHET_HOME/models.registry"
  if [ "${1:-}" != "refresh" ]; then
    [ -f "$cache" ] && cat "$cache"
    return 0
  fi
  command -v pi >/dev/null 2>&1 || return 1
  local reg; reg="$(pi --list-models 2>/dev/null | parse_pi_models)"
  [ -n "$reg" ] || return 1
  mkdir -p "$RATCHET_HOME"
  printf '%s\n' "$reg" > "$cache"
  printf '%s\n' "$reg"
}

# _registry_fresh — 0 if the cache exists and is <24h old.
_registry_fresh() {
  [ -f "$RATCHET_HOME/models.registry" ] && \
    [ -n "$(find "$RATCHET_HOME/models.registry" -mtime -1 2>/dev/null)" ]
}

# chain_add CHAIN MODEL [first|last|N] -> echo the new chain. MODEL already
# present is removed first (so `add --pos` doubles as `move`).
chain_add() {
  local chain="$1" model="$2" pos="${3:-last}" m i
  local out=() new=()
  IFS=',' read -ra arr <<< "$chain"
  for m in ${arr[@]+"${arr[@]}"}; do
    [ -n "$m" ] && [ "$m" != "$model" ] && out+=("$m")
  done
  case "$pos" in
    last|"") out+=("$model") ;;
    first)   out=("$model" ${out[@]+"${out[@]}"}) ;;
    *[!0-9]*) die "bad --pos '$pos' (want first|last|N)" ;;
    *)
      [ "$pos" -ge 1 ] || pos=1
      for ((i=0; i<${#out[@]}; i++)); do
        [ $((i+1)) -eq "$pos" ] && new+=("$model")
        new+=("${out[$i]}")
      done
      [ "$pos" -gt ${#out[@]} ] && new+=("$model")
      out=(${new[@]+"${new[@]}"}) ;;
  esac
  local IFS=','; echo "${out[*]}"
}

# chain_remove CHAIN MODEL -> echo the chain without MODEL.
chain_remove() {
  local chain="$1" model="$2" m out=()
  IFS=',' read -ra arr <<< "$chain"
  for m in ${arr[@]+"${arr[@]}"}; do
    [ -n "$m" ] && [ "$m" != "$model" ] && out+=("$m")
  done
  local IFS=','; echo "${out[*]:-}"
}

# upsert_conf_key FILE KEY VALUE — replace the active KEY= line (commented
# template lines like `#PLAN_MODELS=` are left alone) or append at the end.
# Every other line (comments included) is preserved byte-for-byte.
upsert_conf_key() {
  local file="$1" key="$2" val="$3" tmp
  [ -f "$file" ] || : > "$file"
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$val" '
    $0 ~ "^"k"=" { if (!done) { print k"="v; done=1 } next }
    { print }
    END { if (!done) print k"="v }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# _tier_key models|thinking TIER -> echo the conf key (TIER: models|plan|build|light).
_tier_key() {
  case "$1:$2" in
    models:models|models:flat) echo "MODELS" ;;
    models:plan)   echo "PLAN_MODELS" ;;
    models:build)  echo "BUILD_MODELS" ;;
    models:light)  echo "LIGHT_MODELS" ;;
    thinking:models|thinking:flat) echo "THINKING" ;;
    thinking:plan)  echo "THINKING_PLAN" ;;
    thinking:build) echo "THINKING_BUILD" ;;
    thinking:light) echo "THINKING_LIGHT" ;;
    *) return 1 ;;
  esac
}

# _chain_with_marks CHAIN REGISTRY -> echo chain with ✓/✗ per model.
_chain_with_marks() {
  local chain="$1" reg="$2" m out="" mark
  IFS=',' read -ra arr <<< "$chain"
  for m in ${arr[@]+"${arr[@]}"}; do
    [ -n "$m" ] || continue
    if [ -z "$reg" ]; then mark="?"
    elif printf '%s\n' "$reg" | grep -qxF "$m"; then mark="ok"
    else mark="UNKNOWN"; fi
    out="${out:+$out, }$m [$mark]"
  done
  echo "${out:-<empty>}"
}

# ----------------------------- ratchet models --------------------------------
# Owns its own arg parse (model ids + --tier/--pos would trip parse_args).
# Dispatched from main AFTER the conf precedence load, so the globals hold the
# effective values for `list`.
cmd_models() {
  local sub="${1:-list}"; [ $# -gt 0 ] && shift
  local tier="models" pos="last" repo=0 force=0 arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tier)  tier="${2:-}"; shift 2;;
      --pos)   pos="${2:-}"; shift 2;;
      --repo)  repo=1; shift;;
      --force) force=1; shift;;
      -d|--dir) REPO_DIR="${2:-}"; shift 2;;
      -*) die "ratchet models: unknown option '$1'";;
      *) [ -z "$arg" ] && { arg="$1"; shift; } || die "ratchet models: unexpected '$1'";;
    esac
  done

  # edit target: global conf (default) or the repo contract (--repo)
  local target
  if [ "$repo" = 1 ]; then
    REPO_DIR="${REPO_DIR:-$PWD}"
    target="$REPO_DIR/.ratchet.conf"
  else
    target="$GLOBAL_CONF"
  fi

  case "$sub" in
    list)
      local reg=""; reg="$(pi_model_registry refresh)" || \
        emit "note: pi registry unavailable — showing chains without validation marks"
      emit "effective chains (edit targets: global=$GLOBAL_CONF | --repo <dir>/.ratchet.conf):"
      emit "  MODELS : $(_chain_with_marks "$MODELS" "$reg")"
      local t chain key
      for t in plan build light; do
        key=$(_tier_key models "$t")
        eval "chain=\"\${$key}\""
        if [ -n "$chain" ]; then
          emit "  $(printf '%-6s' "$(echo "$t" | tr 'a-z' 'A-Z')") : $(_chain_with_marks "$chain" "$reg") (thinking=$(thinking_for_tier "$t"))"
        else
          emit "  $(printf '%-6s' "$(echo "$t" | tr 'a-z' 'A-Z')") : -> MODELS (flat) (thinking=$(thinking_for_tier "$t"))"
        fi
      done
      if [ -n "$reg" ]; then
        emit "registry: $(printf '%s\n' "$reg" | grep -c .) models from 'pi --list-models'"
        emit "edit: ratchet models add <provider/id> [--tier plan|build|light] [--pos first|last|N] [--repo]"
      fi
      ;;
    add)
      [ -n "$arg" ] || die "usage: ratchet models add <provider/id> [--tier T] [--pos first|last|N] [--repo] [--force]"
      local key; key=$(_tier_key models "$tier") || die "bad --tier '$tier' (want models|plan|build|light)"
      case "$arg" in */*) ;; *) die "model id must be provider/id form: '$arg'";; esac
      local reg=""; reg="$(pi_model_registry refresh)" || true
      if [ -n "$reg" ] && ! printf '%s\n' "$reg" | grep -qxF "$arg"; then
        [ "$force" = 1 ] || die "'$arg' not in 'pi --list-models' (typo or churned id? --force to add anyway)"
        emit "WARNING: '$arg' not in pi registry — added anyway (--force)."
      fi
      local cur new; eval "cur=\"\${$key}\""
      new="$(chain_add "$cur" "$arg" "$pos")"
      upsert_conf_key "$target" "$key" "$new"
      _models_after_edit "$target" "$repo"
      emit "$key=$new"
      emit "  -> $target"
      ;;
    remove)
      [ -n "$arg" ] || die "usage: ratchet models remove <provider/id> [--tier T] [--repo]"
      local key; key=$(_tier_key models "$tier") || die "bad --tier '$tier' (want models|plan|build|light)"
      local cur new; eval "cur=\"\${$key}\""
      case ",$cur," in
        *",$arg,"*) ;;
        *) die "'$arg' not in $key='$cur'";;
      esac
      new="$(chain_remove "$cur" "$arg")"
      upsert_conf_key "$target" "$key" "$new"
      _models_after_edit "$target" "$repo"
      emit "$key=$new"
      emit "  -> $target"
      ;;
    thinking)
      [ -n "$arg" ] || die "usage: ratchet models thinking <off|minimal|low|medium|high|xhigh> [--tier T] [--repo]"
      case "$arg" in off|minimal|low|medium|high|xhigh) ;;
        *) die "bad thinking level '$arg' (off|minimal|low|medium|high|xhigh)";; esac
      local key; key=$(_tier_key thinking "$tier") || die "bad --tier '$tier' (want models|plan|build|light)"
      upsert_conf_key "$target" "$key" "$arg"
      _models_after_edit "$target" "$repo"
      emit "$key=$arg"
      emit "  -> $target"
      ;;
    *) die "usage: ratchet models [list|add|remove|thinking] ... (see --help)";;
  esac
}

# _models_after_edit TARGET REPO — a --repo edit changes the contract: re-stamp
# the conf hash so doctor doesn't flag ratchet's own edit as tampering.
_models_after_edit() {
  [ "$2" = 1 ] && [ -d "$REPO_DIR/.ratchet" ] && conf_hash "$1" > "$REPO_DIR/.ratchet/conf.hash"
  return 0
}
