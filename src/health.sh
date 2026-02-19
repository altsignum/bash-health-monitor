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
  systemctl show "$service" -p ActiveState -p SubState
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

  local ActiveState SubState
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
    return 0
  fi

  if [[ "$SubState" != "running" ]]; then
    Status="transition"
    printf 'Status=%q\n' "$Status"
    return 0
  fi

  local err_count
  err_count="$(get_service_error_count_since_last_activation "$service")"

  if [[ "$err_count" -eq 0 ]]; then
    Status="stable"
    printf 'Status=%q\n' "$Status"
    return 0
  fi

  Status="unstable"
  printf 'Status=%q\n' "$Status"
  printf 'ErrorCount=%q\n' "$err_count"
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

http_json() {
  local status="$1"
  local body="$2"

  printf 'HTTP/1.1 %s\r\n' "$status"
  printf 'Content-Type: application/json\r\n'
  printf 'Connection: close\r\n'
  printf '\r\n'
  printf '%s' "$body"
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

proxy_request() {
  local monitor="$1"
  local path="$2"
  local service="$3"

  if ! command -v curl >/dev/null 2>&1; then
    http_json "501 Not Implemented" '{"error":"curl is required for monitor proxy"}'
    return 0
  fi

  local base="${monitor%/}"
  local url="${base}${path}"

  if [[ "$path" == "/status" || "$path" == "/errors" ]]; then
    url="${url}?service=${service}"
  fi

  local body http_code
  body="$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)"
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"

  case "$http_code" in
    200) http_json "200 OK" "$body" ;;
    400) http_json "400 Bad Request" "$body" ;;
    404) http_json "404 Not Found" "$body" ;;
    000|"") http_json "502 Bad Gateway" '{"error":"monitor request failed"}' ;;
    *) http_json "502 Bad Gateway" '{"error":"monitor returned non-OK status"}' ;;
  esac

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
    http_json "400 Bad Request" '{"error":"bad request"}'
    return 0
  fi

  monitor="$(get_query_param "$target" "monitor")"
  service="$(get_query_param "$target" "service")"

  if [[ -n "$monitor" && "$path" != "" && "$path" != "/" ]]; then
    proxy_request "$monitor" "$path" "$service"
    return 0
  fi

  local needs_service=0
  case "$path" in
    /status|/errors) needs_service=1 ;;
  esac

  if [[ "$needs_service" -eq 1 ]]; then
    if [[ -z "$service" ]]; then
      http_json "400 Bad Request" '{"error":"bad request"}'
      return 0
    fi

    if [[ "$(systemctl show "$service" -p LoadState --value 2>/dev/null)" == "not-found" ]]; then
      http_json "404 Not Found" '{"error":"service not found"}'
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
        http_json "404 Not Found" '{"error":"index.html not exists"}'
      fi
      ;;
    /list)
      http_json "200 OK" "$(get_list_json "services.list")"
      ;;
    /monitors)
      http_json "200 OK" "$(get_list_json "monitors.list")"
      ;;
    /host)
      local ip
      ip="$(get_external_ip)"
      http_json "200 OK" "{\"host\":\"$(json_escape "$ip")\"}"
      ;;
    /status)
      local Status ErrorCount
      eval "$(get_service_health "$service")"

      if [[ -n "${ErrorCount:-}" ]]; then
        http_json "200 OK" "{\"status\":\"$(json_escape "$Status")\",\"errorCount\":$ErrorCount}"
      else
        http_json "200 OK" "{\"status\":\"$(json_escape "$Status")\"}"
      fi
      ;;
    /errors)
      local -a blocks=()
      local block out first=1

      while IFS= read -r -d $'\036' block || [[ -n "$block" ]]; do
        [[ -z "$block" ]] && continue
        blocks+=("$(json_escape "$block")")
      done < <(get_service_errors_since_last_activation "$service" || true)

      out='['
      for block in "${blocks[@]}"; do
        (( first )) || out+=','
        first=0
        out+="\"$block\""
      done
      out+=']'

      http_json "200 OK" "$out"
      ;;
    *)
      http_json "404 Not Found" '{"error":"not found"}'
      ;;
  esac
}

handle_conn
