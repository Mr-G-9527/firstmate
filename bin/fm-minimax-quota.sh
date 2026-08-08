#!/usr/bin/env bash
# bin/fm-minimax-quota.sh - minimax provider quota pre-flight.
#
# Returns a JSON object on stdout describing current headroom and the data that
# produced it. The dispatcher reads this result before admitting a wave of
# workers and either proceeds, reduces wave size to measured headroom, or
# pauses until headroom recovers.
#
# This helper exists because quota-axi does not model the minimax provider and
# the minimax anthropic-compatible endpoint does not expose rate-limit headers
# on `/v1/models` or `/v1/messages` responses (verified 2026-08-08 against
# https://api.minimaxi.com/anthropic with MiniMax-M3), so the two verified
# approaches below are the supported ways to learn the provider's available
# capacity. The helper is deliberately a fact collector, not a router: it
# returns the data and lets the dispatching first mate own the sizing call.
#
# Usage:
#   bin/fm-minimax-quota.sh [--method=<history|api>] [--window=<seconds>]
#                           [--state-dir=<path>] [--endpoint=<url>]
#
# Methods:
#   history  (default) - read the home's state/<id>.status files plus the
#                         durable wake queue tail, count 429 events within the
#                         trailing window, compute error rate, translate to a
#                         headroom estimate. Requires fresh local data; exit 2
#                         if the most recent event is older than 2*window.
#   api                - issue an authenticated GET against the configured
#                         endpoint, capture rate-limit headers if present, and
#                         report them. Exit 2 on unreachable, 3 on non-success.
#
# Output JSON shape (always the same keys; values may be null when a method
# does not produce them):
#   {
#     "provider":            "minimax",
#     "method":              "history" | "api",
#     "headroom_pct":        <int 0..100 | null>,
#     "staleness_ms":        <int ms since last supporting event | null>,
#     "data_window_seconds": <int>,
#     "recent_429_count":    <int>,
#     "recent_total_count":  <int>,
#     "error_rate_pct":      <float>,
#     "remaining_quota":     <int | null>,        # api method only
#     "reset_at":            "<ISO8601>" | null,   # api method only
#     "endpoint_status":     <int | null>,        # api method only
#     "ts":                  "<ISO8601>"
#   }
#
# Exit codes:
#   0  success, headroom_pct is set
#   2  data is stale (history) or endpoint unreachable (api)
#   3  api endpoint returned non-success
#   4  bad arguments
#
# Environment overrides:
#   FM_MINIMAX_API_KEY    auth token for the api method; falls back to
#                          ANTHROPIC_AUTH_TOKEN (the configured provider auth),
#                          then to MINIMAX_API_KEY
#   FM_MINIMAX_BASE_URL   provider base URL; default https://api.minimaxi.com
#   FM_MINIMAX_TIMEOUT    per-request bound in seconds; default 10
#   FM_MINIMAX_QUOTA_DIR  override state directory (defaults to FM_STATE then
#                          to the firstmate home's state/)

set -eu

PROVIDER=minimax
DEFAULT_BASE_URL="https://api.minimaxi.com"
DEFAULT_TIMEOUT=10
DEFAULT_WINDOW=900   # 15 minutes
MIN_WINDOW=60
MAX_WINDOW=86400

METHOD=history
WINDOW=$DEFAULT_WINDOW
STATE_DIR=
ENDPOINT=
QUIET=0

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --method=*) METHOD=${1#--method=} ;;
    --window=*) WINDOW=${1#--window=} ;;
    --state-dir=*) STATE_DIR=${1#--state-dir=} ;;
    --endpoint=*) ENDPOINT=${1#--endpoint=} ;;
    --quiet) QUIET=1 ;;
    *) echo "error: unknown argument: $1" >&2; exit 4 ;;
  esac
  shift
done

case "$METHOD" in
  history|api) ;;
  *) echo "error: --method must be one of history, api (got '$METHOD')" >&2; exit 4 ;;
esac
case "$WINDOW" in
  ''|*[!0-9]*|0) echo "error: --window must be a positive integer" >&2; exit 4 ;;
  *) ;;
esac
if [ "$WINDOW" -lt "$MIN_WINDOW" ] || [ "$WINDOW" -gt "$MAX_WINDOW" ]; then
  echo "error: --window must be between $MIN_WINDOW and $MAX_WINDOW seconds" >&2; exit 4
fi

if [ -z "$STATE_DIR" ]; then
  if [ -n "${FM_STATE:-}" ]; then
    STATE_DIR=$FM_STATE
  elif [ -n "${FM_HOME:-}" ]; then
    STATE_DIR="$FM_HOME/state"
  else
    STATE_DIR="./state"
  fi
fi
if [ ! -d "$STATE_DIR" ]; then
  echo "error: state directory not found: $STATE_DIR" >&2
  exit 4
fi
STATE_DIR=$(cd "$STATE_DIR" && pwd -P)

BASE_URL=${FM_MINIMAX_BASE_URL:-$DEFAULT_BASE_URL}
BASE_URL=${BASE_URL%/}
TIMEOUT=${FM_MINIMAX_TIMEOUT:-$DEFAULT_TIMEOUT}
case "$TIMEOUT" in
  ''|*[!0-9]*|0) echo "error: FM_MINIMAX_TIMEOUT must be a positive integer" >&2; exit 4 ;;
esac

NOW_EPOCH=$(date -u +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WINDOW_START=$((NOW_EPOCH - WINDOW))
STALE_AFTER=$((NOW_EPOCH - (WINDOW * 2)))

iso_to_epoch() {
  # Accept a 10-digit epoch first; otherwise try GNU date parsing.
  case "$1" in
    *[!0-9]*) ;;
    *) [ "${#1}" -ge 10 ] && printf '%s\n' "${1:0:10}"; return 0 ;;
  esac
  date -u -d "$1" +%s 2>/dev/null || return 1
}

# history_method: scan state/<id>.status + state/.wake-queue for 429 events.
# We attribute each line's age to the file's mtime when the file holds no
# per-line timestamp (state/<id>.status). The wake queue carries its own
# <epoch>TAB<seq>TAB<kind>TAB<key>TAB<payload> format and is read with the
# epoch from column 1. Files are filtered to ones touched in the window so
# we never read more than we need.
history_method() {
  local recent_429=0 recent_total=0 newest_event_epoch=0 f line mtime_epoch kind payload epoch key
  # status files: include only those with mtime >= window_start
  for f in "$STATE_DIR"/*.status; do
    [ -f "$f" ] || continue
    mtime_epoch=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    if [ "$mtime_epoch" -ge "$WINDOW_START" ]; then
      newest_event_epoch=$mtime_epoch
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        recent_total=$((recent_total + 1))
        case "$line" in
          *429*) recent_429=$((recent_429 + 1)) ;;
        esac
      done < "$f"
    fi
  done
  # wake queue if present (its own per-record epoch governs line age)
  for f in "$STATE_DIR/.wake-queue" "$STATE_DIR/.wake-queue.lock"; do
    [ -f "$f" ] || continue
    while IFS=$'\t' read -r epoch _ kind key payload; do
      [ -n "${epoch:-}" ] || continue
      case "$epoch" in
        *[!0-9]*) continue ;;
      esac
      if [ "$epoch" -lt "$WINDOW_START" ]; then continue; fi
      recent_total=$((recent_total + 1))
      case "${payload:-}${kind:-}${key:-}" in
        *429*) recent_429=$((recent_429 + 1)) ;;
      esac
      if [ "$epoch" -gt "$newest_event_epoch" ]; then
        newest_event_epoch=$epoch
      fi
    done < "$f"
  done

  local staleness_ms="" headroom_pct error_rate status
  if [ "$newest_event_epoch" -eq 0 ] || [ "$newest_event_epoch" -lt "$STALE_AFTER" ]; then
    status=stale
    headroom_pct="null"
    staleness_ms="null"
    error_rate=0
  else
    status=ok
    headroom_pct=100
    staleness_ms=$(((NOW_EPOCH - newest_event_epoch) * 1000))
    if [ "$recent_total" -gt 0 ]; then
      # 100 * 429 / total = integer percent, but we keep the float for jq consumers
      error_rate=$(awk -v n="$recent_429" -v t="$recent_total" 'BEGIN { printf "%.4f", (n * 100.0) / t }')
      headroom_pct=$(awk -v n="$recent_429" -v t="$recent_total" 'BEGIN { h = 100 - (n * 100.0) / t; if (h < 0) h = 0; printf "%d", h }')
    fi
  fi

  jq -n \
    --arg provider "$PROVIDER" \
    --arg method history \
    --argjson headroom "$headroom_pct" \
    --argjson staleness "$staleness_ms" \
    --argjson window "$WINDOW" \
    --argjson recent429 "$recent_429" \
    --argjson recentTotal "$recent_total" \
    --arg errorRate "$error_rate" \
    --arg ts "$NOW_ISO" \
    '{provider: $provider, method: $method, headroom_pct: $headroom, staleness_ms: $staleness, data_window_seconds: $window, recent_429_count: $recent429, recent_total_count: $recentTotal, error_rate_pct: ($errorRate|tonumber), remaining_quota: null, reset_at: null, endpoint_status: null, ts: $ts}'

  if [ "$status" = stale ]; then
    return 2
  fi
  return 0
}

# api_method: probe the configured endpoint, capture rate-limit headers.
# The minimax provider does not currently emit x-ratelimit-* headers, so this
# method may report all rate-limit fields as null and rely on the endpoint
# status only. A future minimax release that adds headers will be picked up
# without a code change because the header names follow the OpenAI/Anthropic
# convention.
api_method() {
  local url=${ENDPOINT:-"$BASE_URL/anthropic/v1/models"}
  local auth=""
  if [ -n "${FM_MINIMAX_API_KEY:-}" ]; then auth=${FM_MINIMAX_API_KEY}
  elif [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then auth=${ANTHROPIC_AUTH_TOKEN}
  elif [ -n "${MINIMAX_API_KEY:-}" ]; then auth=${MINIMAX_API_KEY}
  fi

  local headers_file status body_file status_code
  headers_file=$(mktemp)
  body_file=$(mktemp)
  trap 'rm -f "$headers_file" "$body_file"' RETURN

  local curl_args=(
    -s -D "$headers_file" -o "$body_file"
    --max-time "$TIMEOUT"
    -w '%{http_code}'
    -H 'anthropic-version: 2023-06-01'
  )
  if [ -n "$auth" ]; then
    curl_args+=(-H "x-api-key: $auth")
  fi
  curl_args+=("$url")

  if ! status_code=$(curl "${curl_args[@]}" 2>/dev/null); then
    [ "$QUIET" -eq 1 ] || echo "error: minimax endpoint unreachable: $url" >&2
    jq -n \
      --arg provider "$PROVIDER" \
      --arg method api \
      --arg ts "$NOW_ISO" \
      --argjson window "$WINDOW" \
      '{provider: $provider, method: $method, headroom_pct: null, staleness_ms: null, data_window_seconds: $window, recent_429_count: 0, recent_total_count: 0, error_rate_pct: 0, remaining_quota: null, reset_at: null, endpoint_status: null, ts: $ts}'
    return 2
  fi

  if [ "${status_code:-0}" -lt 200 ] || [ "${status_code:-0}" -ge 300 ]; then
    [ "$QUIET" -eq 1 ] || echo "error: minimax endpoint returned HTTP $status_code: $url" >&2
    jq -n \
      --arg provider "$PROVIDER" \
      --arg method api \
      --arg ts "$NOW_ISO" \
      --argjson window "$WINDOW" \
      --argjson status "$status_code" \
      '{provider: $provider, method: $method, headroom_pct: null, staleness_ms: null, data_window_seconds: $window, recent_429_count: 0, recent_total_count: 0, error_rate_pct: 0, remaining_quota: null, reset_at: null, endpoint_status: $status, ts: $ts}'
    return 3
  fi

  # Capture rate-limit headers. Provider headers may use - or _ and may be
  # case-variant; case-insensitive grep against a known set is the safe path.
  local remaining_requests="" remaining_tokens="" reset_requests="" reset_tokens=""
  while IFS= read -r line; do
    line_lc=$(printf '%s\n' "$line" | tr '[:upper:]' '[:lower:]')
    case "$line_lc" in
      x-ratelimit-remaining-requests:*|x_ratelimit_remaining_requests:*)
        remaining_requests=$(printf '%s\n' "$line" | sed -E 's/^[^:]+:[[:space:]]*//')
        ;;
      x-ratelimit-remaining-tokens:*|x_ratelimit_remaining_tokens:*)
        remaining_tokens=$(printf '%s\n' "$line" | sed -E 's/^[^:]+:[[:space:]]*//')
        ;;
      x-ratelimit-reset-requests:*|x_ratelimit_reset_requests:*)
        reset_requests=$(printf '%s\n' "$line" | sed -E 's/^[^:]+:[[:space:]]*//')
        ;;
      x-ratelimit-reset-tokens:*|x_ratelimit_reset_tokens:*)
        reset_tokens=$(printf '%s\n' "$line" | sed -E 's/^[^:]+:[[:space:]]*//')
        ;;
    esac
  done < "$headers_file"

  local headroom_pct="null" remaining_quota="null" reset_at_iso=""
  if [ -n "$remaining_tokens" ] && [ "$remaining_tokens" -gt 0 ] 2>/dev/null; then
    remaining_quota=$remaining_tokens
  elif [ -n "$remaining_requests" ] && [ "$remaining_requests" -gt 0 ] 2>/dev/null; then
    remaining_quota=$remaining_requests
  fi
  if [ -n "$reset_tokens" ]; then
    if reset_at_epoch=$(iso_to_epoch "$reset_tokens"); then
      reset_at_iso=$(date -u -d "@$reset_at_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$reset_tokens")
    else
      reset_at_iso=$reset_tokens
    fi
  elif [ -n "$reset_requests" ]; then
    if reset_at_epoch=$(iso_to_epoch "$reset_requests"); then
      reset_at_iso=$(date -u -d "@$reset_at_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$reset_requests")
    else
      reset_at_iso=$reset_requests
    fi
  fi

  if [ "$remaining_quota" != "null" ]; then
    headroom_pct=$remaining_quota
    if [ "$headroom_pct" -gt 100 ] 2>/dev/null; then headroom_pct=100; fi
    if [ "$headroom_pct" -lt 0 ] 2>/dev/null; then headroom_pct=0; fi
  fi

  # reset_at is either a JSON null or an ISO8601 string. --argjson cannot carry
  # a string, so build the jq expression by hand when a timestamp is present.
  if [ -n "$reset_at_iso" ]; then
    jq -n \
      --arg provider "$PROVIDER" \
      --arg method api \
      --argjson headroom "$headroom_pct" \
      --argjson window "$WINDOW" \
      --argjson remaining "$remaining_quota" \
      --arg resetAt "$reset_at_iso" \
      --argjson status "$status_code" \
      --arg ts "$NOW_ISO" \
      '{provider: $provider, method: $method, headroom_pct: $headroom, staleness_ms: 0, data_window_seconds: $window, recent_429_count: 0, recent_total_count: 0, error_rate_pct: 0, remaining_quota: $remaining, reset_at: $resetAt, endpoint_status: $status, ts: $ts}'
  else
    jq -n \
      --arg provider "$PROVIDER" \
      --arg method api \
      --argjson headroom "$headroom_pct" \
      --argjson window "$WINDOW" \
      --argjson remaining "$remaining_quota" \
      --argjson status "$status_code" \
      --arg ts "$NOW_ISO" \
      '{provider: $provider, method: $method, headroom_pct: $headroom, staleness_ms: 0, data_window_seconds: $window, recent_429_count: 0, recent_total_count: 0, error_rate_pct: 0, remaining_quota: $remaining, reset_at: null, endpoint_status: $status, ts: $ts}'
  fi
}

case "$METHOD" in
  history) history_method ;;
  api) api_method ;;
esac
