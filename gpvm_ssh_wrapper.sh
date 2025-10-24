# POSIX-compliant GPVM SSH wrapper
_gpvm_ssh_wrapper() {
  config_file="${HOME}/.local/etc/gpvm-scanner-config"
  default_pad="${GPVM_PAD:-2}"
  fallback_action="${GPVM_FALLBACK:-error}"

  # find first "host" argument: first arg not starting with '-' and not containing '='
  hostpos=0
  idx=1
  for a in "$@"; do
    case "$a" in
      -*) ;;                 # option, skip
      *=*) ;;                # KEY=VAL, skip
      *)
        hostpos=$idx
        break
        ;;
    esac
    idx=$((idx + 1))
  done

  # nothing to rewrite -> pass through
  if [ "$hostpos" -eq 0 ]; then
    command ssh "$@"
    return $?
  fi

  # get original target (positional parameter extraction via eval so POSIX-compatible)
  eval "orig_target=\${$hostpos}"

  # split user@host if present
  case "$orig_target" in
    *@*)
      userpart="${orig_target%@*}"
      hostpart="${orig_target#*@}"
      ;;
    *)
      userpart=""
      hostpart="$orig_target"
      ;;
  esac

  # find matching config line (first column equals hostpart)
  found_config=0
  if [ -r "$config_file" ]; then
    # read file line by line; IFS '|' separates columns
    while IFS='|' read -r cfg_name cfg_domain cfg_user cfg_min cfg_max cfg_except; do
      case "$cfg_name" in
        ''|\#*) continue ;;  # skip blank or comment
      esac
      if [ "$hostpart" = "$cfg_name" ]; then
        name="$cfg_name"
        domain="$cfg_domain"
        cfg_user="$cfg_user"
        idx_min="$cfg_min"
        idx_max="$cfg_max"
        except="$cfg_except"
        found_config=1
        break
      fi
    done < "$config_file"
  fi

  if [ "$found_config" -ne 1 ]; then
    # not a known gpvm group
    command ssh "$@"
    return $?
  fi

  # defaults
  [ -z "$domain" ] && domain=".fnal.gov"
  pad="${GPVM_PAD:-$default_pad}"

  sel_file="${HOME}/.local/etc/${name}"
  sel=""

  # prefer explicit selection file
  if [ -r "$sel_file" ]; then
    sel="$(tr -d '[:space:]' < "$sel_file" 2>/dev/null || true)"
  else
    # choose first available index within idx_min..idx_max excluding 'except'
    # convert idx_min/idx_max by removing leading zeros (to avoid octal issues)
    if [ -n "$idx_min" ] && [ -n "$idx_max" ]; then
      imin="$(printf '%s' "$idx_min" | sed 's/^0*//')"
      imax="$(printf '%s' "$idx_max" | sed 's/^0*//')"
      [ -z "$imin" ] && imin=0
      [ -z "$imax" ] && imax="$imin"

      i="$imin"
      while [ "$i" -le "$imax" ]; do
        # check exclusion list
        excluded=0
        if [ -n "$except" ]; then
          # split by comma (use word splitting)
          oldIFS="$IFS"
          IFS=','
          set -- $except
          for token in "$@"; do
            case "$token" in
              *-*)
                low="${token%-*}"
                high="${token#*-}"
                low="$(printf '%s' "$low" | sed 's/^0*//')"
                high="$(printf '%s' "$high" | sed 's/^0*//')"
                [ -z "$low" ] && low=0
                [ -z "$high" ] && high="$imax"
                # numeric compare
                if [ "$i" -ge "$low" ] && [ "$i" -le "$high" ]; then
                  excluded=1
                  break
                fi
                ;;
              *)
                tnum="$(printf '%s' "$token" | sed 's/^0*//')"
                [ -z "$tnum" ] && tnum=0
                if [ "$i" -eq "$tnum" ]; then
                  excluded=1
                  break
                fi
                ;;
            esac
          done
          IFS="$oldIFS"
        fi

        if [ "$excluded" -eq 0 ]; then
          # pad the index
          sel="$(printf "%0${pad}d" "$i")"
          break
        fi
        i=$((i + 1))
      done
    fi
  fi

  if [ -n "$sel" ]; then
    # normalize numeric value by stripping leading zeros to avoid octal issues,
    # then re-pad to requested width
    case "$sel" in
      ''|*[!0-9]*)
        # leave non-numeric as-is; validation below will catch it
        ;;
      *)
        sel_num="$(printf '%s' "$sel" | sed 's/^0*//')"
        [ -z "$sel_num" ] && sel_num=0
        sel="$(printf "%0${pad}d" "$sel_num")"
        ;;
    esac
  fi

  # fallback checks (same behavior as prior)
  if [ -z "$sel" ] || [ "$sel" = "-1" ]; then
    printf '%s wrapper: no valid selection (value=%q)\n' "$name" "$sel" >&2
    if [ "$fallback_action" = "raw" ]; then
      command ssh "$@"
      return $?
    else
      return 2
    fi
  fi

  # validate numeric (only digits)
  case "$sel" in
    ''|*[!0-9]*)
      printf '%s wrapper: selection is not numeric: %s\n' "$name" "$sel" >&2
      return 3
      ;;
  esac

  # if config provided a default user and userpart empty, use it
  if [ -z "$userpart" ] && [ -n "$cfg_user" ]; then
    userpart="$cfg_user"
  fi

  # construct new host name
  if [ -n "$userpart" ]; then
    newhost="${userpart}@${name}${sel}.${domain}"
  else
    newhost="${name}${sel}.${domain}"
  fi

  # reconstruct positional parameters with newhost replacing the original at hostpos
  # build a safe set command using single-quoted args (escape single quotes in args)
  set_cmd="set --"
  j=1
  for a in "$@"; do
    if [ "$j" -eq "$hostpos" ]; then
      arg="$newhost"
    else
      # extract the j-th original param safely
      eval "arg=\${$j}"
    fi
    # escape single quotes inside arg for safe single-quoting
    esc_arg="$(printf "%s" "$arg" | sed "s/'/'\\\\''/g")"
    set_cmd="$set_cmd '$esc_arg'"
    j=$((j + 1))
  done

  # evaluate and call ssh
  eval "$set_cmd"
  printf 'ssh -> %s\n' "$newhost" >&2
  command ssh "$@"
  return $?
}

# override ssh only in interactive shells
case $- in
  *i*) ssh() { _gpvm_ssh_wrapper "$@"; } ;;
  *) : ;;
esac
