# =============================================================================
#  model-fallback.sh — first-available model + rate-limit survival
# =============================================================================
#  Each turn the loop picks the FIRST model whose cooldown has expired. When a
#  provider returns exhaustion (quota/rate-limit) it is benched for $COOLDOWN
#  and the next model runs. Transient/hard/timeout failures strike a model;
#  after $MAX_TRANSIENT strikes it is benched. When ALL are benched, the loop
#  sleeps $BOTH_WAIT then resets (a daily quota window is ~hours, so this waits
#  it out instead of hot-spinning). This is the core of unattended survival.
# =============================================================================
#  State is held in three PARALLEL indexed arrays (bash 3.2 has no assoc arrays):
#    models_arr[], cooldown_until_arr[], transient_arr[]
# =============================================================================

# init_models [MODELS]  — split the chain into models_arr[] (+ zero the state).
init_models() {
  local chain="${1:-$MODELS}"
  IFS=',' read -ra models_arr <<< "$chain"
  [ "${#models_arr[@]}" -ge 1 ] || die "no models configured (MODELS='$chain')"
  local i
  cooldown_until_arr=(); transient_arr=()
  for ((i=0; i<${#models_arr[@]}; i++)); do
    cooldown_until_arr[i]=0; transient_arr[i]=0
  done
  # ALLOWED_PROVIDERS (per-repo data governance): drop models whose provider is
  # not on the allowlist. Unset/empty allowlist = keep the full chain.
  if [ -n "$ALLOWED_PROVIDERS" ]; then
    local filtered=() m prov ok
    for m in "${models_arr[@]}"; do
      prov="${m%%/*}"; prov="${prov%%:*}"
      ok=0
      case ",$ALLOWED_PROVIDERS," in
        *",$prov,"*) ok=1;;
      esac
      [ "$ok" = 1 ] && filtered+=("$m")
    done
    if [ "${#filtered[@]}" -gt 0 ]; then
      models_arr=("${filtered[@]}")
      cooldown_until_arr=(); transient_arr=()
      for ((i=0; i<${#models_arr[@]}; i++)); do
        cooldown_until_arr[i]=0; transient_arr[i]=0
      done
    else
      emit "WARNING: ALLOWED_PROVIDERS='$ALLOWED_PROVIDERS' matched no model in chain; using full chain."
    fi
  fi
}

# Echo index of the first AVAILABLE model (cooldown passed), or -1 if none.
pick_model_index() {
  local now cd_until i
  now=$(date +%s)
  for ((i=0; i<${#models_arr[@]}; i++)); do
    cd_until=${cooldown_until_arr[i]:-0}
    if [ "$cd_until" -le "$now" ]; then echo "$i"; return 0; fi
  done
  echo "-1"; return 1
}
bench_model()    { cooldown_until_arr[$1]=$(( $(date +%s) + COOLDOWN )); transient_arr[$1]=0; }  # $1=index
bump_transient() { transient_arr[$1]=$(( ${transient_arr[$1]:-0} + 1 )); }
reset_all()      { local i; for ((i=0; i<${#models_arr[@]}; i++)); do cooldown_until_arr[i]=0; transient_arr[i]=0; done; }

# All models benched right now? (used for stats + BOTH_WAIT messaging.)
all_benched() {
  local now cd_until i
  now=$(date +%s)
  for ((i=0; i<${#models_arr[@]}; i++)); do
    cd_until=${cooldown_until_arr[i]:-0}
    [ "$cd_until" -le "$now" ] && return 1
  done
  return 0
}

# chain_for_tier TIER  — echo the effective model chain for plan|build|light.
# Fallback: unset tier → $MODELS (the flat global chain).
chain_for_tier() {
  local tier="$1" chain=""
  case "$tier" in
    plan)  chain="$PLAN_MODELS" ;;
    build) chain="$BUILD_MODELS" ;;
    light) chain="$LIGHT_MODELS" ;;
    *)     chain="" ;;
  esac
  [ -n "$chain" ] && echo "$chain" || echo "$MODELS"
}

# thinking_for_tier TIER  — echo the effective thinking level for a tier.
# Fallback: unset tier thinking → $THINKING.
# Special: tier=build-hard bumps one notch above THINKING_BUILD (capped at high),
# but ONLY when THINKING_BUILD is empty; if THINKING_BUILD is explicitly set,
# use it unchanged (the user has already configured the tier thinking).
thinking_for_tier() {
  local tier="$1" level=""
  case "$tier" in
    plan)  level="$THINKING_PLAN" ;;
    build) level="$THINKING_BUILD" ;;
    light) level="$THINKING_LIGHT" ;;
    build-hard)
      # Hard tasks: bump one notch above BUILD tier, but only if THINKING_BUILD is unset.
      if [ -z "$THINKING_BUILD" ]; then
        # THINKING_BUILD is unset → use global THINKING and bump it
        level="$THINKING"
        case "$level" in
          off)     level="minimal" ;;
          minimal) level="low" ;;
          low)     level="medium" ;;
          medium)  level="high" ;;
          high)    level="high" ;;  # capped
          xhigh)   level="high" ;;  # capped
          *)       level="" ;;       # empty or unknown → fallback
        esac
      else
        # THINKING_BUILD is explicitly set → honor it for hard tasks too
        level="$THINKING_BUILD"
      fi
      ;;
    *) level="" ;;
  esac
  [ -n "$level" ] && echo "$level" || echo "$THINKING"
}
