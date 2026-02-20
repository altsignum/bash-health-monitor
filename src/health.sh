#!/usr/bin/env bash
set -euo pipefail

# >> Functions

ERRORS_DIR="./errors"

service_to_key() {
  local service="$1"
  local key="$service"
  key="${key//\//_}"
  printf '%s' "$key"
}

ctime_to_epoch() {
  local input="$1"
  local out=""
  out="$(date -u -d "$input" +%s 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    return 1
  fi
  printf '%s' "$out"
}

acquire_lock() {
  local lock_file="$1"
  local wait_seconds="${2:-30}"
  local stale_seconds="${3:-60}"

  local start now ts age
  start="$(date -u +%s)"

  mkdir -p "$ERRORS_DIR"

  while true; do
    now="$(date -u +%s)"

    if ( set -o noclobber; printf '%s\n' "$now" > "$lock_file" ) 2>/dev/null; then
      return 0
    fi

    ts=""
    if [[ -f "$lock_file" ]]; then
      ts="$(head -n1 "$lock_file" 2>/dev/null || true)"
    fi

    if [[ "$ts" =~ ^[0-9]+$ ]]; then
      age=$(( now - ts ))
      if (( age > stale_seconds )); then
        rm -f "$lock_file" 2>/dev/null || true
        continue
      fi
    fi

    if (( now - start >= wait_seconds )); then
      return 1
    fi

    sleep 1
  done
}

release_lock() {
  local lock_file="$1"
  rm -f "$lock_file" 2>/dev/null || true
}

dedupe_errors_file() {
  local errors_file="$1"
  local tmp="${errors_file}.tmp"

  [[ -f "$errors_file" ]] || return 0

  awk 'BEGIN{RS="\036"; ORS="\036"} NF && !seen[$0]++ {print}' \
    "$errors_file" > "$tmp"

  mv -f "$tmp" "$errors_file"
}

get_file_lines() {
  local file="$1"
  local -a lines=()

  if [[ -f "$file" ]]; then
    mapfile -t lines < "$file"
  fi

  printf '%s\n' "${lines[@]}"
}

get_service_status() {
  local service="$1"
  local line key val

  systemctl show "$service" \
    -p ActiveState \
    -p SubState \
    -p ActiveEnterTimestamp \
    -p StateChangeTimestamp \
    2>/dev/null \
    | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        printf '%s=%q\n' "$key" "$val"
      done
}

get_service_errors_since_last_activation() {
  local service="$1"

  local since
  since="$(systemctl show -p ActiveEnterTimestamp --value "$service")"

  if [[ -z "$since" || "$since" == "n/a" ]]; then
    since="$(systemctl show -p StateChangeTimestamp --value "$service")"
  fi

  if [[ -z "$since" || "$since" == "n/a" ]]; then
    return 0
  fi

  mkdir -p "$ERRORS_DIR"

  local key
  key="$(service_to_key "$service")"

  local lock_file sync_file errors_file
  lock_file="${ERRORS_DIR}/${key}.lock"
  sync_file="${ERRORS_DIR}/${key}.sync"
  errors_file="${ERRORS_DIR}/${key}.errors"

  if ! acquire_lock "$lock_file" 30 60; then
    return 1
  fi

  local since_epoch
  if ! since_epoch="$(ctime_to_epoch "$since")"; then
    release_lock "$lock_file"
    return 0
  fi

  local sync_epoch_raw sync_epoch
  sync_epoch_raw=""
  sync_epoch=""
  if [[ -f "$sync_file" ]]; then
    sync_epoch_raw="$(head -n1 "$sync_file" 2>/dev/null || true)"
  fi
  if [[ "$sync_epoch_raw" =~ ^[0-9]+$ ]]; then
    sync_epoch="$sync_epoch_raw"
  fi

  if [[ -n "$sync_epoch" && "$sync_epoch" -lt "$since_epoch" ]]; then
    : > "$errors_file"
    : > "$sync_file"
    sync_epoch=""
  fi

  local from_epoch
  if [[ -n "$sync_epoch" ]]; then
    from_epoch="$sync_epoch"
  else
    from_epoch="$since_epoch"
  fi

  local to_epoch
  to_epoch="$(date -u +%s)"

  journalctl -u "$service" --since "@$from_epoch" -o cat --no-pager \
    | (grep -Pzo '(?ms)^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?\|(ERROR|FATAL)\|.*?(?=^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?\|[A-Z]+\||\z)' || true) \
    | tr '\0' '\036' \
    >> "$errors_file"

  dedupe_errors_file "$errors_file"

  printf '%s\n' "$to_epoch" > "$sync_file"

  cat "$errors_file" 2>/dev/null || true

  release_lock "$lock_file"
}

get_service_error_count_since_last_activation() {
  local service="$1"
  (get_service_errors_since_last_activation "$service" || true) \
    | tr -cd '\036' \
    | wc -c
}

get_service_health() {
  local service="$1"

  local ActiveState SubState ActiveEnterTimestamp StateChangeTimestamp
  eval "$(get_service_status "$service")"

  local Status

  if [[ "$ActiveState" == "failed" ]]; then
    Status="failed"
    printf 'Status=%q\n' "$Status"
    return 0
  fi

  if [[ "$ActiveState" != "active" ]]; then
    if [[ "$ActiveState" == "inactive" ]]; then
      Status="stopped"
      printf 'Status=%q\n' "$Status"
      return 0
    fi

    Status="transition"
    printf 'Status=%q\n' "$Status"

    if [[ -n "${ActiveEnterTimestamp:-}" && "$ActiveEnterTimestamp" != "n/a" ]]
    then
      printf 'ActiveEnterTimestamp=%q\n' "$ActiveEnterTimestamp"
    elif [[ -n "${StateChangeTimestamp:-}" && "$StateChangeTimestamp" != "n/a" ]]
    then
      printf 'ActiveEnterTimestamp=%q\n' "$StateChangeTimestamp"
    fi

    local err_count
    err_count="$(get_service_error_count_since_last_activation "$service")"
    if [[ "$err_count" -gt 0 ]]; then
      printf 'ErrorCount=%q\n' "$err_count"
    fi

    return 0
  fi

  if [[ "$SubState" == "exited" ]]; then
    Status="completed"
    printf 'Status=%q\n' "$Status"
    printf 'ActiveEnterTimestamp=%q\n' "${ActiveEnterTimestamp:-}"
    return 0
  fi

  if [[ "$SubState" != "running" ]]; then
    Status="transition"
    printf 'Status=%q\n' "$Status"
    printf 'ActiveEnterTimestamp=%q\n' "${ActiveEnterTimestamp:-}"
    return 0
  fi

  local err_count
  err_count="$(get_service_error_count_since_last_activation "$service")"

  if [[ "$err_count" -eq 0 ]]; then
    Status="stable"
    printf 'Status=%q\n' "$Status"
    printf 'ActiveEnterTimestamp=%q\n' "${ActiveEnterTimestamp:-}"
    return 0
  fi

  Status="unstable"
  printf 'Status=%q\n' "$Status"
  printf 'ErrorCount=%q\n' "$err_count"
  printf 'ActiveEnterTimestamp=%q\n' "${ActiveEnterTimestamp:-}"
  return 0
}

# >> Server

get_external_ip() {
  local ip=""

  ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | sed -n 's/.* src \([0-9.]\+\).*/\1/p' \
    | head -n1 || true)"

  if [[ -z "$ip" ]]; then
    ip="$(ip -4 -o addr show scope global 2>/dev/null \
      | awk '{print $4}' \
      | cut -d/ -f1 \
      | head -n1 || true)"
  fi

  printf '%s' "$ip"
}

get_unique_identifier() {
  cat /etc/machine-id
}

expand_http_status() {
  local code="${1:-200}"

  case "$code" in
    200) printf "200 OK" ;;
    400) printf "400 Bad Request" ;;
    404) printf "404 Not Found" ;;
    501) printf "501 Not Implemented" ;;
    502) printf "502 Bad Gateway" ;;
    *)
      echo "Unknown status code $code" >&2
      return 1
    ;;
  esac
}

printf_headers() {
  local status="$(expand_http_status "${1:-}")" || return 1
  local content="${2:-application/json}"

  printf 'HTTP/1.1 %s\r\n' "$status"
  printf 'Content-Type: %s\r\n' "$content"
  printf 'Connection: close\r\n'
  printf '\r\n'
}

printf_file_list() {
  local file="$1"
  local item first=1

  printf '['
  while IFS= read -r item || [[ -n "$item" ]]; do
    [[ -z "$item" ]] && continue
    (( first )) || printf ','
    first=0
    printf '"%s"' "$(json_escape "$item")"
  done < <(get_file_lines "$file")
  printf ']'
}

printf_service_status() {
  local service=$1

  local host="$(get_external_ip)"
  local Status ErrorCount ActiveEnterTimestamp
  eval "$(get_service_health "$service")"

  printf '{'
  printf '"name":"%s",' "$(json_escape "$service")"
  printf '"status":"%s",' "$(json_escape "$Status")"
  if [[ -n "${ActiveEnterTimestamp:-}" ]]; then
    printf '"activeSince":"%s",' "$(ctime_to_json_date "$ActiveEnterTimestamp")"
  fi
  if [[ -n "${ErrorCount:-}" ]]; then
    printf '"errorCount":%s,' $ErrorCount
  fi
  printf '"host":"%s"' "$(json_escape "$host")"
  printf '}'
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

url_decode() {
  local s="${1//+/ }"
  printf '%b' "${s//%/\\x}"
}

ctime_to_json_date() {
  local input="$1"
  date -u -d "$input" +"%Y-%m-%dT%H:%M:%SZ"
}

parse_query_params() {
  local target="$1"
  local qs pair k v

  declare -gA query=()

  [[ "$target" == *\?* ]] || return 0
  qs="${target#*\?}"

  while IFS='&' read -r -a pairs; do
    for pair in "${pairs[@]}"; do
      [[ -n "$pair" ]] || continue
      k="${pair%%=*}"
      v=""
      [[ "$pair" == *"="* ]] && v="${pair#*=}"
      query["$k"]="$(url_decode "$v")"
    done
  done <<< "$qs"
}

get_list_json() {
  local file="$1"
  local -a items=()
  local item out first=1

  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    items+=("$(json_escape "$item")")
  done < <(get_file_lines "$file")

  out='['
  for item in "${items[@]}"; do
    (( first )) || out+=','
    first=0
    out+="\"$item\""
  done
  out+=']'

  printf '%s' "$out"
}

handle_conn() {
  local req_line method target path line
  IFS= read -r req_line || return 0
  method="${req_line%% *}"
  target="${req_line#* }"; target="${target%% *}"
  path="${target%%\?*}"
  parse_query_params "$target"

  while IFS= read -r line; do
    [[ "$line" == $'\r' || -z "$line" ]] && break
  done

  if [[ "$method" != "GET" ]]; then
    printf_headers 400
    printf '{"error":"bad request"}'
    return 0
  fi

  local monitor="${query[monitor]:-}"
  if [[ -n "$monitor" && "$path" != "" && "$path" != "/" ]]; then
    local url="${monitor}${path}"
    local querySeparator='?'
    local param

    for param in "${!query[@]}"; do
      [[ "$param" == "monitor" ]] && continue
      url+="${querySeparator}${param}=${query[$param]}"
      querySeparator='&'
    done

    exec curl -sS -D - "$url"
  fi

  local service="${query[service]:-}"
  local needs_service=0
  case "$path" in
    /status|/errors) needs_service=1 ;;
  esac

  if [[ "$needs_service" -eq 1 ]]; then
    if [[ -z "$service" ]]; then
      printf_headers 400
      printf '{"error":"service must be specified"}'
      return 0
    fi

    if [[ "$(systemctl show "$service" -p LoadState --value 2>/dev/null)" == "not-found" ]]; then
      printf_headers 404
      printf '{"error":"service not found"}'
      return 0
    fi
  fi

  case "$path" in
    ""|"/")
      local file="index.html"

      if [[ -f "$file" ]]; then
        local len
        len="$(wc -c < "$file")"
        printf 'HTTP/1.1 200 OK\r\n'
        printf 'Content-Type: text/html; charset=utf-8\r\n'
        printf 'Content-Length: %s\r\n' "$len"
        printf 'Connection: close\r\n'
        printf '\r\n'
        cat "$file"
      else
        printf_headers 404
        printf '{"error":"index.html not exists"}'
      fi
      ;;
    /services)
      printf_headers
      printf_file_list "services.list"
      ;;
    /monitors)
      printf_headers
      printf_file_list "monitors.list"
      ;;
    /host)
      local host="$(get_external_ip)"
      printf_headers
      printf '{"host":"%s"}' "$(json_escape "$host")"
      ;;
    /status)
      printf_headers
      printf_service_status $service
      ;;
    /all)
      local ids="${query[ids]:-}"
      local id="$(get_unique_identifier)"
      if [[ ",$ids," == *",$id,"* ]]; then
        printf_headers 204 'application/json; charset=utf-8'
        return 0
      fi
      if [[ -z "$ids" ]]; then
        ids="$id"
      else
        ids="$ids,$id"
      fi

      printf_headers 200 'application/json; charset=utf-8'
      printf '{'

      local ref="${query[ref]:-}"
      if [[ -z "$ref" ]]; then
        printf '"name":null,'
      else
        printf '"name":"%s",' "$(json_escape "$ref")"
      fi

      printf '"services":['
      local first=1 service
      while IFS= read -r service || [[ -n "$service" ]]; do
        [[ -z "$service" ]] && continue
        (( first )) || printf ','
        first=0
        printf_service_status "$service"
      done < <(get_file_lines "services.list")
      printf '],'

      printf '"monitors":['
      local first=1 monitor
      while IFS= read -r monitor || [[ -n "$monitor" ]]; do
        [[ -z "$monitor" ]] && continue
        (( first )) || printf ','
        first=0

        local base="${monitor%/}"
        local url="${base}/all?ref=$monitor&ids=$ids"

        curl -sS --fail --connect-timeout 2 --max-time 60 "$url"
      done < <(get_file_lines "monitors.list")
      printf ']'

      printf '}'
      ;;
    /errors)
      local format="${query[format]:-}"
      if [[ "$format" == "text" ]]; then
        printf_headers 200 'text/plain; charset=utf-8'
        get_service_errors_since_last_activation "$service" \
          | awk 'BEGIN{RS="\036"; ORS="\n\n"} NF{print}'
        return 0
      fi

      local block first=1
      printf_headers 200 'application/json'
      printf '['
      while IFS= read -r -d $'\036' block || [[ -n "$block" ]]; do
        (( first )) || printf ','
        first=0
        printf '"%s"' "$(json_escape "$block")"
      done < <(get_service_errors_since_last_activation "$service" || true)
      printf ']'
      ;;
    *)
      printf_headers 404
      printf '{"error":"not found"}'
      ;;
  esac
}

handle_conn
