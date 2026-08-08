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

# derived_rank -> echo provider/id lines ordered by output price DESC, then
# no-join models in registry order. Applies ALLOWED_PROVIDERS, filters out
# tool_call=false (coding loop needs tools). Price heuristic: higher cost =
# stronger. Ceiling: subsidized/subscription pricing (T6.3 adds outcome stats).
derived_rank() {
  local reg avail=() m prov meta tool_call outp priced=() nojoin=()
  
  reg="$(pi_model_registry)"
  [ -z "$reg" ] && return 1
  
  # apply ALLOWED_PROVIDERS filter
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
  
  # partition: priced with cost vs no-join
  for m in "${avail[@]}"; do
    meta="$(model_meta "$m")"
    if [ -z "$meta" ]; then
      nojoin+=("$m")
      continue
    fi
    
    # field 5 = tool_call
    tool_call="$(echo "$meta" | cut -f5)"
    [ "$tool_call" = "false" ] && continue  # drop tool_call=false
    
    # field 3 = output cost
    outp="$(echo "$meta" | cut -f3)"
    [ -z "$outp" ] && outp="0"
    priced+=("$outp:$m")
  done
  
  # sort by output cost DESC (-r = reverse), strip price prefix
  [ "${#priced[@]}" -gt 0 ] && printf '%s\n' "${priced[@]}" | sort -t: -k1 -rn | sed 's/^[^:]*://'
  
  # append no-join models
  [ "${#nojoin[@]}" -gt 0 ] && printf '%s\n' "${nojoin[@]}"
}

# ranked_available_models -> echo provider/id lines ordered by MODEL_RANK,
# then unranked models sorted by cost. Applies ALLOWED_PROVIDERS filter FIRST.
# Returns empty if no models pass the filter.
ranked_available_models() {
  local reg rank_arr avail=() ranked=() unranked=() m prov found i
  
  # if MODEL_RANK is unset, use derived rank
  if [ -z "${MODEL_RANK:-}" ]; then
    derived_rank
    return $?
  fi
  
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

# suggest_chain TIER -> echo comma-separated model chain for plan|build|light|review.
# plan: top + next fallback; light: bottom + one-up fallback; 
# build/review: middle + fallbacks down.
suggest_chain() {
  local tier="$1" ranked out=() total mid i
  
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
    build|review)
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
