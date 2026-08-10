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

# _is_noncoder_model PROVIDER/ID -> 0 if the id is a known non-coder family
# (creative-writing / vision / image). These land in the CODING rank only by
# accident of price or alphabet (e.g. claude-fable-5 sorts before real coders),
# so the derived path drops them by construction. An explicit MODEL_RANK entry
# is honored regardless — this gate only guards AUTO-derivation, never a human
# choice. Anchored to known families + generic vision/image tokens; every drop
# is logged to stderr so a wrong exclusion is auditable, never silent.
_is_noncoder_model() {
  local id="${1#*/}"
  case "$id" in
    *fable*|*mythos*|*vision*|*image*|*-5v-*|*-5v|5v-*) return 0 ;;
    *) return 1 ;;
  esac
}

# _derive_rank_live -> echo provider/id lines ordered by output price DESC, then
# no-join models in registry order. Applies ALLOWED_PROVIDERS, filters out
# tool_call=false (coding loop needs tools) and known non-coder families.
# Price heuristic: higher cost = stronger. Ceiling: subsidized/subscription
# pricing + price-is-not-skill (set MODEL_RANK for the real signal; T6.3 adds
# outcome stats). When NOTHING joins the cost cache, the order is arbitrary
# registry order — that case warns loudly instead of pretending to rank.
_derive_rank_live() {
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
    # capability gate: creative/vision families are not coders — drop from the
    # auto-derived rank (logged; explicit MODEL_RANK is unaffected by this path).
    if _is_noncoder_model "$m"; then
      printf 'rank: dropped %s (non-coder family: creative/vision)\n' "$m" >&2
      continue
    fi

    meta="$(model_meta "$m")"
    if [ -z "$meta" ]; then
      nojoin+=("$m")
      continue
    fi
    
    # field 5 = tool_call
    tool_call="$(echo "$meta" | cut -f5)"
    [ "$tool_call" = "false" ] && { printf 'rank: dropped %s (tool_call=false)\n' "$m" >&2; continue; }
    
    # field 3 = output cost
    outp="$(echo "$meta" | cut -f3)"
    [ -z "$outp" ] && outp="0"
    priced+=("$outp:$m")
  done
  
  # No cost signal joined ANY model: the order below is arbitrary registry order,
  # not a ranking. Warn loudly (stderr, so the echoed list stays clean) — the fix
  # is one MODEL_RANK line, not a silent alphabetical mis-route into PLAN.
  if [ "${#priced[@]}" -eq 0 ] && [ "${#nojoin[@]}" -gt 0 ]; then
    printf 'rank: WARNING no cost/rank signal (models.dev cache empty and MODEL_RANK unset) — models are in arbitrary registry order, NOT ranked by skill. Set MODEL_RANK in ~/.ratchet/conf or run `ratchet models rank refresh`.\n' >&2
  fi

  # sort by output cost DESC (-r = reverse), strip price prefix
  [ "${#priced[@]}" -gt 0 ] && printf '%s\n' "${priced[@]}" | sort -t: -k1 -rn | sed 's/^[^:]*://'
  
  # append no-join models
  [ "${#nojoin[@]}" -gt 0 ] && printf '%s\n' "${nojoin[@]}"
  return 0
}

# derived_rank -> echo provider/id lines from snapshot (stable mid-project) or
# derive live and write snapshot. Snapshot: $RATCHET_HOME/rank.derived
derived_rank() {
  local snap="$RATCHET_HOME/rank.derived"
  if [ -f "$snap" ]; then
    cat "$snap"
    return 0
  fi
  # no snapshot: derive live and write it
  local ranked
  ranked="$(_derive_rank_live)" || return 1
  mkdir -p "$RATCHET_HOME"
  printf '%s\n' "$ranked" > "$snap"
  printf '%s\n' "$ranked"
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
