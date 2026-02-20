#!/usr/bin/env bash
set -euo pipefail

# >> Functions

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
    return 0
  fi

  journalctl -u "$service" --since "$since" -o cat --no-pager \
    | (grep -Pzo '(?ms)^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?\|(ERROR|FATAL)\|.*?(?=^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?\|[A-Z]+\||\z)' || true) \
    | tr '\0' '\036'
}

get_service_error_count_since_last_activation() {
  local service="$1"
  get_service_errors_since_last_activation "$service" | tr -cd '\036' | wc -c
}

get_service_health() {
  local service="$1"

  local ActiveState SubState ActiveEnterTimestamp
  eval "$(get_service_status "$service")"

  local Status

  if [[ "$ActiveState" == "failed" ]]; then
    Status="failed"
    printf 'Status=%q\n' "$Status"
    return 0
  fi

  if [[ "$ActiveState" != "active" ]]; then
    Status="stopped"
    printf 'Status=%q\n' "$Status"
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

get_query_param() {
  local target="$1"
  local key="$2"

  if [[ "$target" != *\?* ]]; then
    printf '%s' ""
    return 0
  fi

  local qs="${target#*\?}"
  local raw
  raw="$(printf '%s' "$qs" \
    | tr '&' '\n' \
    | sed -n "s/^${key}=//p" \
    | head -n1 || true)"

  if [[ -z "$raw" ]]; then
    printf '%s' ""
    return 0
  fi

  url_decode "$raw"
}

strip_query_param() {
  local target="$1"
  local key="$2"

  if [[ "$target" != *\?* ]]; then
    printf '%s' "$target"
    return 0
  fi

  local path="${target%%\?*}"
  local qs="${target#*\?}"

  local -a keep=()
  local part k
  while IFS= read -r part; do
    [[ -z "$part" ]] && continue
    k="${part%%=*}"
    if [[ "$k" == "$key" ]]; then
      continue
    fi
    keep+=("$part")
  done < <(printf '%s' "$qs" | tr '&' '\n')

  if [[ "${#keep[@]}" -eq 0 ]]; then
    printf '%s' "$path"
    return 0
  fi

  local out="${path}?"
  local first=1
  for part in "${keep[@]}"; do
    if (( first )); then
      first=0
    else
      out+="&"
    fi
    out+="$part"
  done

  printf '%s' "$out"
}

proxy_request() {
  local monitor="$1"
  local target="$2"

  if ! command -v curl >/dev/null 2>&1; then
    printf_headers 501
    printf '{"error":"curl is required for monitor proxy"}'
    return 0
  fi

  local base="${monitor%/}"
  local cleaned
  cleaned="$(strip_query_param "$target" "monitor")"

  local url="${base}${cleaned}"

  if curl -sS --max-time 15 --http1.1 -i "$url"; then
    return 0
  fi

  printf_headers 502
  printf '{"error":"monitor request failed"}'
  return 0
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
  local req_line method target path service monitor line
  IFS= read -r req_line || return 0
  method="${req_line%% *}"
  target="${req_line#* }"; target="${target%% *}"
  path="${target%%\?*}"

  while IFS= read -r line; do
    [[ "$line" == $'\r' || -z "$line" ]] && break
  done

  if [[ "$method" != "GET" ]]; then
    printf_headers 400
    printf '{"error":"bad request"}'
    return 0
  fi

  monitor="$(get_query_param "$target" "monitor")"

  if [[ -n "$monitor" && "$path" != "" && "$path" != "/" ]]; then
    proxy_request "$monitor" "$target"
    return 0
  fi

  service="$(get_query_param "$target" "service")"

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
    /list)
      printf_headers
      printf "$(get_list_json "services.list")"
      ;;
    /monitors)
      printf_headers
      printf "$(get_list_json "monitors.list")"
      ;;
    /host)
      local ip
      ip="$(get_external_ip)"
      printf_headers
      printf "{\"host\":\"$(json_escape "$ip")\"}"
      ;;
    /status)
      local Status ErrorCount ActiveEnterTimestamp
      eval "$(get_service_health "$service")"

      local ts_json=""
      if [[ -n "${ActiveEnterTimestamp:-}" ]]; then
        ts_json=",\"activeEnterTimestamp\":\"$(ctime_to_json_date "$ActiveEnterTimestamp")\""
      fi

      if [[ -n "${ErrorCount:-}" ]]; then
        printf_headers
        printf "{\"status\":\"$(json_escape "$Status")\",\"errorCount\":$ErrorCount$ts_json}"
      else
        printf_headers
        printf "{\"status\":\"$(json_escape "$Status")\"$ts_json}"
      fi
      ;;
    /errors)
      local format="$(get_query_param "$target" "format")"
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
