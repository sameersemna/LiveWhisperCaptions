#!/usr/bin/env bash
# test_google_tor.sh — diagnostic only, does not touch server.js or the running app.
#
# Checks whether routing Google Translate's unofficial endpoint through a local Tor SOCKS
# proxy actually avoids the IP-based rate limit we're hitting directly (HTTP 429), and how
# much latency it costs. Answers this empirically before any code gets written for a
# server.js Tor fallback — see CLAUDE.md's Translate modes section for the full context.
#
# Usage: ./test_google_tor.sh [attempts-per-mode]
#   TOR_HOST=latitude TOR_PORT=9050 ./test_google_tor.sh 5

set -u

TOR_HOST="${TOR_HOST:-latitude}"
TOR_PORT="${TOR_PORT:-9050}"
ATTEMPTS="${1:-3}"
TEXT="Das ist ein Testsatz für die Übersetzung."

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done

# ---------- colors (same convention as call-transcribe-live.sh) ----------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RESET=$(tput sgr0); C_BOLD=$(tput bold); C_DIM=$(tput dim)
  C_GREEN=$(tput setaf 2); C_RED=$(tput setaf 1); C_AMBER="${C_BOLD}$(tput setaf 3)"
  C_GRAY=$(tput setaf 8 2>/dev/null || echo "$C_DIM")
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_RED=""; C_AMBER=""; C_GRAY=""
fi

ENCODED_TEXT=$(printf '%s' "$TEXT" | jq -sRr @uri)
URL="https://translate.googleapis.com/translate_a/single?client=gtx&sl=de&tl=en&dt=t&q=${ENCODED_TEXT}"

echo "${C_BOLD}Direct vs Tor-proxied Google Translate${C_RESET}"
echo "${C_GRAY}Test text: \"${TEXT}\"${C_RESET}"
echo "${C_GRAY}Tor SOCKS proxy: ${TOR_HOST}:${TOR_PORT} · attempts per mode: ${ATTEMPTS}${C_RESET}"
echo

DIRECT_OK=0; DIRECT_FAIL=0
TOR_OK=0; TOR_FAIL=0

# Runs one attempt, printing a result line. Extra args (if any) are passed straight to
# curl — used to inject --proxy for the Tor-routed attempts.
run_attempt() {
  local label="$1"; shift
  local start end elapsed response http_code body translation

  start=$(date +%s.%N)
  response=$(curl -s -w '___HTTP_CODE___%{http_code}' --max-time 25 "$@" "$URL" 2>&1)
  end=$(date +%s.%N)
  elapsed=$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.2f", b-a}')

  http_code=$(printf '%s' "$response" | grep -o '___HTTP_CODE___[0-9]*$' | grep -o '[0-9]*$')
  body=${response%___HTTP_CODE___*}

  if [ "$http_code" = "200" ]; then
    translation=$(printf '%s' "$body" | jq -r '[.[0][]?[0]] | join("")' 2>/dev/null)
    if [ -n "$translation" ]; then
      printf "${C_GREEN}%-16s${C_RESET} HTTP %-3s  %6ss  -> %s\n" "$label" "$http_code" "$elapsed" "$translation"
      return 0
    fi
    printf "${C_AMBER}%-16s${C_RESET} HTTP %-3s  %6ss  200 but unparseable body\n" "$label" "$http_code" "$elapsed"
    return 1
  else
    local snippet
    snippet=$(printf '%s' "$body" | tr -s '[:space:]' ' ' | cut -c1-70)
    printf "${C_RED}%-16s${C_RESET} HTTP %-3s  %6ss  %s\n" "$label" "${http_code:-timeout}" "$elapsed" "$snippet"
    return 1
  fi
}

echo "${C_AMBER}-- Direct (current baseline) --${C_RESET}"
for i in $(seq 1 "$ATTEMPTS"); do
  if run_attempt "direct #$i"; then DIRECT_OK=$((DIRECT_OK+1)); else DIRECT_FAIL=$((DIRECT_FAIL+1)); fi
done

echo
echo "${C_AMBER}-- Via Tor (isolated circuit per attempt) --${C_RESET}"
for i in $(seq 1 "$ATTEMPTS"); do
  # A distinct SOCKS username forces Tor onto a new circuit per attempt (Tor's default
  # IsolateSOCKSAuth behavior since 0.2.3 — no torrc changes needed on the proxy side), so
  # each attempt exits through a different node. Without this, repeated attempts would
  # likely share one circuit/exit IP for its ~10-minute lifetime, telling us nothing about
  # how *typical* Tor exit nodes fare with Google rather than just this one lucky/unlucky
  # circuit. socks5h (not socks5) so hostname resolution happens proxy-side, not locally.
  if run_attempt "tor #$i" --proxy "socks5h://circuit${i}:x@${TOR_HOST}:${TOR_PORT}"; then
    TOR_OK=$((TOR_OK+1))
  else
    TOR_FAIL=$((TOR_FAIL+1))
  fi
done

echo
echo "${C_BOLD}Summary${C_RESET}"
echo "  direct: ${C_GREEN}${DIRECT_OK} ok${C_RESET} / ${C_RED}${DIRECT_FAIL} failed${C_RESET} out of ${ATTEMPTS}"
echo "  tor:    ${C_GREEN}${TOR_OK} ok${C_RESET} / ${C_RED}${TOR_FAIL} failed${C_RESET} out of ${ATTEMPTS}"
echo "${C_GRAY}(200 = success, 429 = rate-limited, timeout = proxy unreachable/circuit stalled)${C_RESET}"
