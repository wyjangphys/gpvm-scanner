#!/bin/sh
#set -e
#set -euo pipefail

# Function definitions

check_cfg() {
  if [ ! -f "$CFG" ] ; then
    printf '%s ERROR: config not found: %s\n' "$(timestamp)" "$CFG" >&2
    return 1
  fi
}

check_essential_fields() {
  # validate essential fields
  if [ -z "$name" ] || [ -z "$domain" ] || [ -z "$user" ] || [ -z "$idx_min" ] || [ -z "$idx_max" ]; then
    printf '%s ERROR: invalid config line: %s\n' "$(timestamp)" "$rawline"
    return 1
  fi
}

count_index() {
  # count_index idx_min idx_max except
  idx_min="$1"
  idx_max="$2"
  except="$3"

  # index-padding correction
  start=$(printf '%s\n' "$idx_min" | awk '{print int($0)}')
  end=$(printf '%s\n' "$idx_max" | awk '{print int($0)}')
  if [ "$start" -gt "$end" ]; then
    tmp="$start"; start="$end"; end="$tmp"
  fi

  width=$(printf '%s' "$idx_min" | awk '{print length($0)}')
  count=0
  i="$start"

  while [ "$i" -le "$end" ]; do
    idx_formatted=$(printf "%0*d" "$width" "$i")
    excluded=$(is_excluded "$idx_formatted" "$except")
    if [ "$excluded" != "yes" ]; then
      count=$((count + 1))
    fi
    i=$((i + 1))
  done

  echo "$count"
}

detect_os() {
  case "$(uname -s)" in
    Darwin)
      printf "macos"
      ;;
    Linux)
      printf "linux"
      ;;
    *)
      printf "unknown"
      ;;
  esac
}

get_min_index() {
    family="$1"
  csv="$2"

  awk -F',' -v fam="$family" '
    NF == 0 { next }
    {
      gsub(/^[ \t]+|[ \t]+$/, "", $1)
      gsub(/^[ \t]+|[ \t]+$/, "", $3)

      host = $1
      load15 = $3 + 0

      if (host ~ ("^" fam)) {
        if (match(host, /[0-9]+/)) {
          idx = substr(host, RSTART, RLENGTH) + 0
          if (min_load == "" || load15 < min_load) {
            min_load = load15
            min_idx = idx
          }
        }
      }
    }
    END {
      if (min_idx != "")
        print min_idx
    }
  ' "$csv"
}

timestamp() {
  # ISO8601 UTC
  date -u +"%Y-%m-%dT%H:%M:%S"
}

log() {
  # prefixed log suitable for journald format
  printf '%s [gpvm-scanner] %s\n' "$(timestamp)" "$*"
}

is_excluded() {
  idx="$1"
  ex="$2"
  if [ -z "$ex" ]; then
    printf 'no'
    return 0
  fi

  # convert idx to integer safely (awk handles leading zeros)
  idxint=$(printf '%s\n' "$idx" | awk '{print int($0)}')

  # iterate comma-separated parts
  # we can't rely on shell arrays, use awk to parse quickly
  printf '%s' "$ex" | awk -v idx="$idxint" '
    BEGIN{ FS="," }
    {
      for(i=1;i<=NF;i++){
        gsub(/^ +| +$/,"",$i)
        p=$i
        if(p=="") next
        if(index(p,"-")>0) {
          split(p, r, "-")
          a = int(r[1]); b = int(r[2])
          if(idx >= a && idx <= b){ print "yes"; exit }
        } else {
          if(idx == int(p)){ print "yes"; exit }
        }
      }
      print "no"
    }'
}

has_kerberos_ticket() {
  # check whether klist exist
  if ! command -v klist >/dev/null 2>&1; then
    return 1
  fi

  # check FNAL.GOV ticket
  if klist 2>/dev/null | grep -Fq "$REALM"; then
    return 0
  else
    return 1
  fi
}

fetch_one() {
  out=""
  loads=""
  # Try /proc/loadavg
  out=$(ssh ${SSH_OPTS} "${user}@${name}${idx_formatted}.${domain}" 'cat /proc/loadavg' 2>/dev/null ) || true
  printf '%s' "$out"
  # extract first three floats
  #loads=$(echo "$out" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n3 | tr '\n' ' ' | sed 's\ $\\') # it works only in Linux
  printf '%s' "$loads"
  loads=$(echo "$out" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n3 | xargs)
  [ -n "$loads" ] && echo "${name}${idx_formatted},$(echo $loads | awk '{print $1","$2","$3}'),/proc/loadavg" >> "$TMP_CSV"
}

main() {
  CFG="$HOME/.local/etc/gpvm-scanner-config"
  USERNAME=${USERNAME:-${USER:-$(whoami)}}
  REALM="${REALM:-FNAL.GOV}"
  PRINCIPAL="${PRINCIPAL:-${USERNAME}@${REALM}}"
  SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-6}"
  SSH_OPTS="-o ConnectTimeout=${SSH_CONNECT_TIMEOUT} -o BatchMode=yes -o StrictHostkeyChecking=no"
  OUT_DIR="${HOME}/.local/etc"
  OS_TYPE=$(detect_os)
  MAX_JOBS=20
  job_count=0
  check_cfg

  # Temporary files
  if [ "$OS_TYPE" = "macos" ]; then
    TMP_CSV="$(mktemp -t gpvm_scan)"
  else
    TMP_CSV="$(mktemp /tmp/gpvm_scan.XXXXXX.csv)"
  fi
  trap 'cat $TMP_CSV; rm -fv "$TMP_CSV"' EXIT

  if ! has_kerberos_ticket; then
    log "No valid Kerberos ticket for realm ${REALM}. Skipping scan."
    exit 0
  fi

  log "Kerberos ticket present for ${PRINCIPAL}. Starting load scan..."

  # CFG 파일을 읽으면서 설정된 항목들에 대해 루프
  pids=""
  while IFS= read -r rawline || [ -n "$rawline" ]; do
    # remove comments after '#'
    line=$(printf '%s' "$rawline" \
      | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$line" ] && continue

    echo $rawline

    # split by '|'
    # POSIX: use awk to split safely into 6 fields
    name=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$1); print $1}')
    domain=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
    user=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}')
    idx_min=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')
    idx_max=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5}')
    except=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6}')

    check_essential_fields
    nworks=$(count_index "$idx_min" "$idx_max" "$except")

    width=$(printf '%s' "$idx_min" | awk '{print length($0)}')
    # convert to integers (awk int handles leading zeros)
    start=$(printf '%s\n' "$idx_min" | awk '{print int($0)}')
    end=$(printf '%s\n' "$idx_max" | awk '{print int($0)}')
    # ensure start <= end
    if [ "$start" -gt "$end" ]; then
      tmp="$start"; start="$end"; end="$tmp"
    fi

    i="$start"
    while : ; do
      idx_formatted=$(printf "%0*d" "$width" "$i")
      excluded=$(is_excluded "$idx_formatted" "$except")
      if [ "$excluded" = "yes" ] ; then
        i=$((i+1))
        continue
      fi

      printf "ssh $SSH_OPTS ${name}${idx_formatted}.${domain} -- $?\n"
      fetch_one &
      pids="$pids $!"
      job_count=$((job_count + 1))
      if [ "$job_count" -ge "$MAX_JOBS" ] ; then
        # wait for all jobs
        for pid in $pids; do
          wait "$pid" && pids=$(printf '%s' "$pids" | sed "s/\b$pid\b//g") || true
          job_count=$((job_count - 1))
        done
        # reset
        pids=""
        job_count=0
      fi

      if [ "$i" -ge "$end" ] ; then
        break
      fi
      i=$((i+1))
    done
  done < "$CFG"

  # wait for remaining jobs
  for pid in $pids; do
    wait "$pid" || true
  done

  log "Fetched average load information from all servers."

  # Now parse CSV and pick host with minimal 15-min load (3rd numeric column)
  # Keep entries with numeric 15-min value
  # Format: host, load1, load5, load15, source
  while IFS= read -r rawline || [ -n "$rawline" ]; do
    # remove comments after '#'
    line=$(printf '%s' "$rawline" \
      | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$line" ] && continue

    name=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$1); print $1}')
    domain=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
    user=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}')
    idx_min=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')
    idx_max=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5}')
    except=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6}')

    mkdir -p "${HOME}/.local/etc"
    outfile="${HOME}/.local/etc/${name}"
    min_index="$(get_min_index ${name} ${TMP_CSV})"
    log "Selected index ${min_index} written to ${outfile}"
  done < "$CFG"

  log "Scan complete."
}

main "$@"
