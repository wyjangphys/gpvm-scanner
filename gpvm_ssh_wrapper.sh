# put this into your ~/.bashrc or ~/.zshrc and then source the file
_dunegpvm_ssh_wrapper() {
  # global defaults (can be overridden per-prefix below)
  local default_sel_file="${HOME}/.local/etc/dunegpvm"
  local default_domain="${DUNEGPVM_DOMAIN:-.fnal.gov}"
  local default_pad_width="${DUNEGPVM_PAD:-2}"
  local fallback_action="${DUNEGPVM_FALLBACK:-error}"

  # detect shell and handle arrays appropriately
  if [ -n "${BASH_VERSION:-}" ]; then
    # --- BASH path (0-based arrays) ---
    local -a args=("$@")
    local hostpos=-1
    local i a
    for i in "${!args[@]}"; do
      a="${args[$i]}"
      if [ "${a#-}" = "$a" ] && [ "${a#*=}" = "$a" ]; then
        hostpos=$i
        break
      fi
    done

    if [ "$hostpos" -lt 0 ]; then
      command ssh "${args[@]}"
      return $?
    fi

    local orig_target="${args[$hostpos]}"
    local userpart=""
    local hostpart="$orig_target"
    if [[ "$orig_target" == *@* ]]; then
      userpart="${orig_target%@*}"
      hostpart="${orig_target#*@}"
    fi

    # determine prefix and per-prefix configuration
    local prefix=""
    if [[ "$hostpart" =~ ^(dunegpvm|icarusgpvm)([[:digit:]]*)($|\.) ]]; then
      prefix="${BASH_REMATCH[1]}"
    fi

    if [ -z "$prefix" ]; then
      # not a target we rewrite
      command ssh "${args[@]}"
      return $?
    fi

    # set per-prefix values (defaults fall back to the global defaults above)
    local sel_file domain pad_width
    if [ "$prefix" = "dunegpvm" ]; then
      sel_file="${HOME}/.local/etc/dunegpvm"
      domain="${DUNEGPVM_DOMAIN:-$default_domain}"
      pad_width="${DUNEGPVM_PAD:-$default_pad_width}"
    elif [ "$prefix" = "icarusgpvm" ]; then
      sel_file="${HOME}/.local/etc/icarusgpvm"
      domain="${ICARUSGPVM_DOMAIN:-$default_domain}"
      pad_width="${ICARUSGPVM_PAD:-$default_pad_width}"
    else
      sel_file="$default_sel_file"
      domain="$default_domain"
      pad_width="$default_pad_width"
    fi

    if [ ! -r "$sel_file" ]; then
      printf '%s wrapper: selection file not found: %s\n' "$prefix" "$sel_file" >&2
      [ "$fallback_action" = "raw" ] && command ssh "${args[@]}" || return 1
    fi

    local sel
    sel="$(tr -d '[:space:]' < "$sel_file" 2>/dev/null || true)"

    if [ -z "$sel" ] || [ "$sel" = "-1" ]; then
      printf '%s wrapper: no valid selection (value=%q)\n' "$prefix" "$sel" >&2
      [ "$fallback_action" = "raw" ] && command ssh "${args[@]}" || return 2
    fi

    if ! printf '%s\n' "$sel" | grep -Eq '^[0-9]+$'; then
      printf '%s wrapper: selection is not numeric: %s\n' "$prefix" "$sel" >&2
      return 3
    fi

    local sel_padded
    sel_padded=$(printf "%0${pad_width}d" "$sel")

    local newhost
    if [ -n "$userpart" ]; then
      newhost="${userpart}@${prefix}${sel_padded}${domain}"
    else
      newhost="${prefix}${sel_padded}${domain}"
    fi

    args[$hostpos]="$newhost"
    printf 'ssh -> %s\n' "${args[$hostpos]}" >&2
    command ssh "${args[@]}"
    return $?

  elif [ -n "${ZSH_VERSION:-}" ]; then
    # --- ZSH path (1-based arrays) ---
    typeset -a args
    args=("$@")   # zsh arrays are 1-based
    local hostpos=0
    local idx=1
    local a
    for a in "${args[@]}"; do
      # treat args starting with '-' as option; KEY=VAL skip
      if [ "${a#-}" = "$a" ] && [ "${a#*=}" = "$a" ]; then
        hostpos=$idx
        break
      fi
      idx=$((idx+1))
    done

    if [ "$hostpos" -eq 0 ]; then
      command ssh "${args[@]}"
      return $?
    fi

    # in zsh arrays are 1-based, so args[hostpos] is correct
    local orig_target="${args[$hostpos]}"
    local userpart=""
    local hostpart="$orig_target"
    if [[ "$orig_target" == *@* ]]; then
      userpart="${orig_target%@*}"
      hostpart="${orig_target#*@}"
    fi

    # determine prefix in a portable way for zsh
    local prefix=""
    if [[ "$hostpart" == dunegpvm* ]]; then
      prefix="dunegpvm"
    elif [[ "$hostpart" == icarusgpvm* ]]; then
      prefix="icarusgpvm"
    else
      prefix=""
    fi

    if [ -z "$prefix" ]; then
      command ssh "${args[@]}"
      return $?
    fi

    # set per-prefix configuration
    local sel_file domain pad_width
    if [ "$prefix" = "dunegpvm" ]; then
      sel_file="${HOME}/.local/etc/dunegpvm"
      domain="${DUNEGPVM_DOMAIN:-$default_domain}"
      pad_width="${DUNEGPVM_PAD:-$default_pad_width}"
    elif [ "$prefix" = "icarusgpvm" ]; then
      sel_file="${HOME}/.local/etc/icarusgpvm"
      domain="${ICARUSGPVM_DOMAIN:-$default_domain}"
      pad_width="${ICARUSGPVM_PAD:-$default_pad_width}"
    else
      sel_file="$default_sel_file"
      domain="$default_domain"
      pad_width="$default_pad_width"
    fi

    if [ ! -r "$sel_file" ]; then
      printf '%s wrapper: selection file not found: %s\n' "$prefix" "$sel_file" >&2
      [ "$fallback_action" = "raw" ] && command ssh "${args[@]}" || return 1
    fi

    local sel
    sel="$(tr -d '[:space:]' < "$sel_file" 2>/dev/null || true)"

    if [ -z "$sel" ] || [ "$sel" = "-1" ]; then
      printf '%s wrapper: no valid selection (value=%q)\n' "$prefix" "$sel" >&2
      [ "$fallback_action" = "raw" ] && command ssh "${args[@]}" || return 2
    fi

    if ! printf '%s\n' "$sel" | grep -Eq '^[0-9]+$'; then
      printf '%s wrapper: selection is not numeric: %s\n' "$prefix" "$sel" >&2
      return 3
    fi

    local sel_padded
    sel_padded=$(printf "%0${pad_width}d" "$sel")

    local newhost
    if [ -n "$userpart" ]; then
      newhost="${userpart}@${prefix}${sel_padded}${domain}"
    else
      newhost="${prefix}${sel_padded}${domain}"
    fi

    args[$hostpos]="$newhost"
    printf 'ssh -> %s\n' "${args[$hostpos]}" >&2
    command ssh "${args[@]}"
    return $?

  else
    # unknown shell: fall back to calling ssh with original args
    command ssh "$@"
    return $?
  fi
}

# override ssh in interactive shells only
case $- in
  *i*) ssh() { _dunegpvm_ssh_wrapper "$@"; } ;;
  *) : ;;
esac
