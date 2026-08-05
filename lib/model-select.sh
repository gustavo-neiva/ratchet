# =============================================================================
#  model-select.sh — automatic model tier selection from MODEL_RANK
# =============================================================================
#  Reduces manual tier-chain config to at most ONE line: MODEL_RANK (comma list
#  of provider/id or bare provider, strongest first). Slices that ranking into
#  plan/build/light chains by intersecting with the live pi registry (auth-aware
#  availability), applying ALLOWED_PROVIDERS filter, then appending unranked
#  models ordered by models.dev output-price (cheapest last, since unranked ≠
#  trusted-strong).
#
#  Explicit *_MODELS config still overrides (see lib/model-fallback.sh
#  chain_for_tier). This is the automatic path when the human configures no
#  chain — zero-config that degrades gracefully: if MODEL_RANK is unset AND
#  fewer than 2 models are available, suggest_chain echoes empty and the caller
#  keeps today's "no models configured" die path.
# =============================================================================

# ranked_available_models -> echo provider/id lines ordered by MODEL_RANK,
# then unranked models sorted by cost. Applies ALLOWED_PROVIDERS filter FIRST.
# Returns empty if no models pass the filter.
ranked_available_models() {
  local reg rank_arr avail=() ranked=() unranked=() m prov found i
  
  # get live registry (availability = ground truth)
  reg="$(pi_model_registry)"
  [ -z "$reg" ] && return 1
  
  # apply ALLOWED_PROVIDERS filter (same pattern as init_models)
  if [ -n "$ALLOWED_PROVIDERS" ]; then
    while IFS= read -r m; do
      prov="${m%%/*}"; prov="${prov%%:*}"
      case ",$ALLOWED_PROVIDERS," in
        *",$prov,"*) avail+=("$m") ;;
      esac
    done <<< "$reg"
  else
    while IFS= read -r m; do avail+=("$m"); done <<< "$reg"
  fi
  
  [ "${#avail[@]}" -eq 0 ] && return 1
  
  # if MODEL_RANK is unset or empty, return available models as-is (no ranking)
  [ -z "${MODEL_RANK:-}" ] && printf '%s\n' "${avail[@]}" && return 0
  
  # split MODEL_RANK into array
  IFS=',' read -ra rank_arr <<< "$MODEL_RANK"
  
  # partition available models: ranked vs unranked
  for m in "${avail[@]}"; do
    found=0
    for ((i=0; i<${#rank_arr[@]}; i++)); do
      # match exact provider/id OR bare provider prefix
      if [ "$m" = "${rank_arr[$i]}" ] || [ "${m%%/*}" = "${rank_arr[$i]}" ]; then
        ranked+=("$m:$i")  # tag with rank position
        found=1
        break
      fi
    done
    [ "$found" = 0 ] && unranked+=("$m")
  done
  
  # sort ranked by their position tag, then strip the tag
  if [ "${#ranked[@]}" -gt 0 ]; then
    printf '%s\n' "${ranked[@]}" | sort -t: -k2 -n | sed 's/:.*//'
  fi
  
  # append unranked sorted by models.dev output-price (best-effort), then id
  if [ "${#unranked[@]}" -gt 0 ]; then
    local meta cost_out
    for m in "${unranked[@]}"; do
      meta="$(model_meta "$m")"
      if [ -n "$meta" ]; then
        cost_out="$(echo "$meta" | cut -f3)"
        [ -z "$cost_out" ] && cost_out="999999"
      else
        cost_out="999999"
      fi
      printf '%s:%s\n' "$cost_out" "$m"
    done | sort -t: -k1 -n | sed 's/^[^:]*://'
  fi
}

# suggest_chain TIER -> echo comma-separated model chain for plan|build|light.
# plan: top + next fallback; light: bottom + one-up fallback; build: middle + fallbacks down.
# If MODEL_RANK is unset, echo empty (rc1) — no reliable skill ranking without it.
suggest_chain() {
  local tier="$1" ranked out=() total mid i
  
  # MODEL_RANK is required for automatic selection (the one ordering knob)
  [ -z "${MODEL_RANK:-}" ] && return 1
  
  ranked="$(ranked_available_models)"
  [ -z "$ranked" ] && return 1
  
  # read into array
  local arr=()
  while IFS= read -r m; do arr+=("$m"); done <<< "$ranked"
  total="${#arr[@]}"
  
  # need at least 1 model to slice
  [ "$total" -lt 1 ] && return 1
  
  case "$tier" in
    plan)
      # top model + next as fallback
      out+=("${arr[0]}")
      [ "$total" -ge 2 ] && out+=("${arr[1]}")
      ;;
    light)
      # bottom (cheapest-ranked) + one up as fallback
      out+=("${arr[$((total-1))]}")
      [ "$total" -ge 2 ] && out+=("${arr[$((total-2))]}")
      ;;
    build)
      # middle: model just below plan (or plan's pick if only 2), + fallbacks down
      if [ "$total" -le 2 ]; then
        # only 2 models total: build uses plan's pick (strongest)
        out+=("${arr[0]}")
        [ "$total" -eq 2 ] && out+=("${arr[1]}")
      else
        # 3+ models: start at index 1 (just below plan), add fallbacks down
        for ((i=1; i<total; i++)); do
          out+=("${arr[$i]}")
        done
      fi
      ;;
    *)
      return 1
      ;;
  esac
  
  local IFS=','; echo "${out[*]}"
}
