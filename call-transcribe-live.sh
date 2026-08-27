#!/bin/bash
# call-transcribe-live.sh
# Live chunked transcription AND translation via Whisper server with VAD.
# Uses ffmpeg segment muxer to write fixed-duration WAV chunks,
# filters out silence using ffmpeg's silencedetect, then sends the
# speech-containing chunks for transcription and translation.
#
# Requires: ffmpeg, curl
# Works on Linux (PulseAudio) and macOS (CoreAudio via ffmpeg's avfoundation
# input) — see start_capture() and the CLAUDE.md gotcha for details.
#
# Usage:
#   ./call-transcribe-live.sh [LANG_CODE]
#   ./call-transcribe-live.sh --list-devices   # list audio input devices, then exit
#
#   LANG_CODE  Source language (default: de). Examples: de, en, fr, es, it, nl...
#
# Example: ./call-transcribe-live.sh es   # Spanish source, translated to English
# Press Ctrl+C to stop.

# get environment variables from .env file
if [ -f .env ]; then
  export $(cat .env | sed 's/#.*//g' | xargs)
fi

# Linux uses PulseAudio (-f pulse); macOS has no PulseAudio by default and
# reaches CoreAudio via ffmpeg's avfoundation input instead — see
# start_capture() below and the CLAUDE.md gotcha for the full story.
OS_NAME="$(uname -s)"

# --list-devices / -l: print the platform-appropriate audio device list and
# exit, so you can find what to put in BT_SOURCE (a PulseAudio source name on
# Linux, an avfoundation device index/name on macOS) without reading ffmpeg
# docs. Checked before LANGUAGE so it works as a standalone command.
if [ "$1" = "--list-devices" ] || [ "$1" = "-l" ]; then
  case "$OS_NAME" in
    Darwin)
      ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | sed -n '/AVFoundation audio devices/,$p'
      ;;
    Linux)
      if command -v pactl >/dev/null 2>&1; then
        pactl list sources short
      else
        echo "pactl not found — install pulseaudio-utils to list sources." >&2
        exit 1
      fi
      ;;
    *)
      echo "Unsupported OS: ${OS_NAME}. This script supports Linux and macOS." >&2
      exit 1
      ;;
  esac
  exit 0
fi

# Source language from CLI arg (default: de)
LANGUAGE="${1:-de}"

# ---------- Terminal colors ----------
# Only enabled for an actual interactive terminal with real color support —
# never for piped/redirected output (`./call-transcribe-live.sh > log.txt`),
# so logs stay plain, greppable text. tput over raw ANSI escapes: it respects
# whatever the terminal actually supports instead of assuming.
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RESET=$(tput sgr0); C_BOLD=$(tput bold); C_DIM=$(tput dim)
  C_DE=$(tput setaf 6)                                  # cyan — echoes the browser console's --de
  C_EN=$(tput setaf 3)                                  # amber/yellow — echoes --en / the brand amber
  C_AMBER="${C_BOLD}$(tput setaf 3)"
  C_GREEN=$(tput setaf 2); C_RED=$(tput setaf 1)
  C_GRAY=$(tput setaf 8 2>/dev/null || echo "$C_DIM")
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_DE=""; C_EN=""; C_AMBER=""; C_GREEN=""; C_RED=""; C_GRAY=""
fi

CHUNK_SECONDS=3

# ---------- SRT transcript export ----------
# Persists this call's transcript to disk as two SRT files (source language +
# English), one line reused as both filename timestamp and session ID. This is
# a deliberate, script-specific exception to the browser console's "nothing is
# ever written to disk" principle (see CLAUDE.md) — that principle is about
# call-console.html/server.js specifically; this standalone CLI tool is meant
# to leave a saved transcript behind, that's the point of running it this way
# instead of through the browser.
SESSION_STAMP=$(date +%Y%m%d_%H%M%S)
TRANSCRIPTS_DIR="transcripts"
mkdir -p "$TRANSCRIPTS_DIR"
SRT_SOURCE_FILE="${TRANSCRIPTS_DIR}/${SESSION_STAMP}.${LANGUAGE}.srt"
SRT_EN_FILE="${TRANSCRIPTS_DIR}/${SESSION_STAMP}.en.srt"

# Silence detection: treat as silence if below -25dB for 0.3s+ (more aggressive)
SILENCE_THRESHOLD_DB=-25
SILENCE_DURATION=0.3
# Also check mean_volume - if average < -40dB, consider it silence
RMS_THRESHOLD_DB=-40
# Minimum transcription length to avoid hallucinations
MIN_TEXT_LENGTH=20
# whisper.cpp's own no-speech gate (confirmed real form field, server default 0.6 — see
# CLAUDE.md). Raised here as a starting point after a real incident (2026-08-22) where
# has_speech() let noisy/near-silent audio through and Whisper confidently hallucinated
# fluent, varied English sentences on it rather than recognizing "no real speech" — a
# failure mode temperature_inc's retry mechanism doesn't catch, since a fluent hallucinated
# sentence can pass whisper's own compression-ratio/avg-logprob quality checks just fine.
# This is the same "tune against real audio, don't guess" territory as SILENCE_THRESHOLD_DB
# above — 0.7 is a first move, not a validated final value; raise further if hallucinated
# full sentences keep appearing, lower if real quiet speech starts getting dropped.
NO_SPEECH_THOLD=0.7

# Common Whisper hallucinations to filter out (case-insensitive substrings),
# read directly from hallucinations.txt — same convention this script
# already uses for .env: relative to cwd, no network call. Keeps this
# script fully standalone with no dependency on `node server.js` being up.
# Note: the browser console (call-console.html) has its own separate,
# regex-based hallucination list — not this file. See CLAUDE.md.
HALLUCINATIONS_FILE="hallucinations.txt"
if [ -f "$HALLUCINATIONS_FILE" ]; then
  mapfile -t HALLUCINATIONS < <(grep -vE '^\s*(#|$)' "$HALLUCINATIONS_FILE")
else
  echo "${C_RED}Warning: $HALLUCINATIONS_FILE not found — hallucination filtering disabled.${C_RESET}" >&2
  HALLUCINATIONS=()
fi
BASENAME="call_live_$(date +%s)"
TMPDIR="/tmp/${BASENAME}_chunks"
mkdir -p "$TMPDIR"

cleanup() {
  echo -e "\n${C_AMBER}Stopping...${C_RESET}"
  kill "$CAPTURE_PID" 2>/dev/null
  rm -rf "$TMPDIR"
  rmdir "${SRT_SOURCE_FILE}.lockdir" "${SRT_EN_FILE}.lockdir" 2>/dev/null
  echo "${C_GREEN}Cleaned up temporary files.${C_RESET}"
  sort_srt_file "$SRT_SOURCE_FILE"
  sort_srt_file "$SRT_EN_FILE"
  [ -f "$SRT_SOURCE_FILE" ] && echo "${C_GREEN}Saved:${C_RESET} $SRT_SOURCE_FILE"
  [ -f "$SRT_EN_FILE" ] && echo "${C_GREEN}Saved:${C_RESET} $SRT_EN_FILE"
  exit 0
}
trap cleanup EXIT INT TERM

# Check if a chunk contains speech (not just silence)
# Returns 0 (true) if speech detected, 1 (false) if silence
has_speech() {
  local chunk_file="$1"
  local idx="$2"

  # Method 1: volumedetect for mean_volume (RMS equivalent)
  # -loglevel info, not error: volumedetect/silencedetect (both filters used in this
  # function) report their stats (mean_volume, silence_start/end/duration) via ffmpeg's
  # own INFO-level logging, not as filter output on stdout. -loglevel error silently
  # discards that entire line — confirmed live (2026-08-22): with -loglevel error this
  # function's grep patterns below never matched anything, on ANY audio, so both
  # detection methods always fell through and has_speech() always returned "has speech"
  # regardless of actual content. That's the real cause of a real incident: every chunk,
  # including pure silence, was being sent to Whisper, which hallucinated freely on it.
  local vol_info
  vol_info=$(ffmpeg -hide_banner -loglevel info -i "$chunk_file" \
    -af "volumedetect" -f null - 2>&1)

  # sed -E, not grep -oP: -P (PCRE) is a GNU grep extension that BSD grep
  # (macOS default) doesn't support — it would fail silently there, leaving
  # mean_volume always empty and has_speech() always falling through to
  # "has speech", the same class of silent VAD-gate failure the -loglevel
  # info fix above addressed for a different tool gap. sed -E's POSIX ERE
  # (character classes + backreference) works identically on GNU and BSD sed.
  local mean_volume
  mean_volume=$(echo "$vol_info" | sed -nE 's/.*mean_volume:[[:space:]]*(-?[0-9.]+).*/\1/p' | head -1)

  if [ -n "$mean_volume" ]; then
    # mean_volume is negative dB, more negative = quieter
    if (( $(echo "$mean_volume < $RMS_THRESHOLD_DB" | bc -l 2>/dev/null || echo 0) )); then
      return 1
    fi
  fi

  # Method 2: silencedetect as backup (see the -loglevel note on Method 1 above — applies
  # here too, silencedetect's silence_start/end/duration lines are also INFO-level)
  local silence_info
  silence_info=$(ffmpeg -hide_banner -loglevel info -i "$chunk_file" \
    -af "silencedetect=noise=${SILENCE_THRESHOLD_DB}dB:d=${SILENCE_DURATION}" \
    -f null - 2>&1)

  # If silencedetect found silence spanning most of the chunk, skip it
  if echo "$silence_info" | grep -q "silence_end"; then
    local silence_dur
    silence_dur=$(echo "$silence_info" | sed -nE 's/.*silence_duration: ([0-9.]+).*/\1/p' | head -1)
    if [ -n "$silence_dur" ]; then
      local threshold
      threshold=$(echo "$CHUNK_SECONDS * 0.8" | bc -l 2>/dev/null || echo "2.4")
      if (( $(echo "$silence_dur >= $threshold" | bc -l 2>/dev/null || echo 0) )); then
        return 1
      fi
    fi
  fi
  return 0
}

# Repeats a (possibly multi-byte) character N times. Not `tr`: `tr`'s SET2 on
# this system operates byte-wise even under a UTF-8 locale, so `tr ' ' '─'`
# silently corrupts the 3-byte '─' into repeated first-bytes — verified, not
# assumed. A plain loop sidesteps that entirely.
repeat_char() {
  local ch="$1" n="$2" out="" i
  for (( i=0; i<n; i++ )); do out+="$ch"; done
  printf '%s' "$out"
}

# Prints "──── [HH:MM:SS] ────", dashes filling the rest of the terminal's actual
# width, as a visual break between chunks. Re-measures via `tput cols` on every
# call rather than caching a width once — cheap (one small subprocess per chunk,
# and chunks are seconds apart), and correct even if the terminal gets resized
# mid-call. Falls back to a fixed 60 columns when stdout isn't a real terminal
# (piped/redirected output — there's no "actual width" to measure there).
print_timestamp_rule() {
  local label=" [$1] "
  local width=60
  if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    width=$(tput cols 2>/dev/null || echo 60)
  fi
  local dash_total=$(( width - ${#label} ))
  if [ "$dash_total" -lt 4 ]; then
    printf "${C_BOLD}${C_GRAY}%s${C_RESET}\n" "$label"
    return
  fi
  local left=$(( dash_total / 2 ))
  local right=$(( dash_total - left ))
  printf "${C_GRAY}%s${C_BOLD}%s${C_RESET}${C_GRAY}%s${C_RESET}\n" \
    "$(repeat_char '─' "$left")" "$label" "$(repeat_char '─' "$right")"
}

# Converts whole seconds to SRT's "HH:MM:SS,mmm". Milliseconds are always
# "000": chunk boundaries come from ffmpeg's fixed CHUNK_SECONDS segment muxer,
# not a VAD endpointer, so cue timing is exact multiples of a whole number of
# seconds — there's no sub-second component to report.
srt_timestamp() {
  local total="$1"
  printf '%02d:%02d:%02d,000' $(( total/3600 )) $(( (total%3600)/60 )) $(( total%60 ))
}

# Appends one SRT block. Sequence number and cue timing both come straight
# from the chunk index (idx+1, and idx*CHUNK_SECONDS..(idx+1)*CHUNK_SECONDS) —
# not a shared counter — so concurrent background process_chunk calls (see the
# main loop below) never need to coordinate over what number/timestamp to use,
# only over not corrupting each other's actual write. flock on a per-file lock
# handles that: chunks can finish out of order (whichever chunk's whisper call
# comes back first appends first), so blocks may land on disk out of sequence,
# but each block's own number/timestamps are always correct regardless of
# write order — SRT players key off timestamps, not file position.
# Portable mutual-exclusion lock: mkdir is atomic on every POSIX filesystem,
# so this needs no extra tool. Deliberately not flock — flock is util-linux,
# Linux-only, not shipped on macOS; using it there would fail silently there
# too (the write still happens after the failed flock command, just without
# the corruption protection flock is meant to provide) rather than erroring
# loudly, which is exactly the kind of gap this project has been bitten by
# before (see the -loglevel error gotcha in CLAUDE.md).
acquire_lock() {
  while ! mkdir "$1" 2>/dev/null; do sleep 0.05; done
}
release_lock() {
  rmdir "$1" 2>/dev/null
}

write_srt_block() {
  local file="$1" idx="$2" text="$3"
  local seq=$(( idx + 1 ))
  local start_ts end_ts
  start_ts=$(srt_timestamp $(( idx * CHUNK_SECONDS )))
  end_ts=$(srt_timestamp $(( (idx + 1) * CHUNK_SECONDS )))
  local lockdir="${file}.lockdir"
  acquire_lock "$lockdir"
  printf '%d\n%s --> %s\n%s\n\n' "$seq" "$start_ts" "$end_ts" "$text" >> "$file"
  release_lock "$lockdir"
}

# write_srt_block() only guarantees blocks don't corrupt each other on
# concurrent writes — it does NOT guarantee they land in the file in
# chronological order (whichever chunk's whisper call returns first gets
# appended first, and calls don't necessarily finish in chunk order). Fine for
# a live-updating file, not fine for the transcript someone opens afterward
# and reads top to bottom, so re-sort once by sequence number on the way out.
# Pure bash + `sort -n`, deliberately not awk: this system's default `awk` may
# be mawk, which lacks the array-sorting gawk extensions this would otherwise
# want, and pure bash has no such portability question.
sort_srt_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  local tmp="${file}.sorted"
  local -A records
  local block="" num=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
      if [ -n "$block" ]; then
        num=$(head -n1 <<< "$block")
        records["$num"]="$block"
        block=""
      fi
    else
      block+="${block:+$'\n'}$line"
    fi
  done < "$file"
  if [ -n "$block" ]; then
    num=$(head -n1 <<< "$block")
    records["$num"]="$block"
  fi
  : > "$tmp"
  local key
  for key in $(printf '%s\n' "${!records[@]}" | sort -n); do
    printf '%s\n\n' "${records[$key]}" >> "$tmp"
  done
  mv "$tmp" "$file"
}

# whisper.cpp's response_format=text output conventionally leads each segment
# with a space (and can trail one too). A chunk spanning multiple segments
# joins them with a raw newline, and each segment carries its own leading
# space — so a whole-string trim only catches the outer edges, not the space
# after an embedded newline. sed strips leading/trailing whitespace line by
# line (it naturally processes a multi-line string that way), catching every
# segment boundary in one pass.
trim() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$1"
}

process_chunk() {
  local chunk_file="$1"
  local idx="$2"
  [ -s "$chunk_file" ] || return 0

  # Skip if chunk is mostly silence (prevents Whisper hallucinations). Print a dim
  # dot rather than nothing at all — a silent terminal for a stretch of pauses is
  # indistinguishable from a hung script; this is a low-noise heartbeat instead.
  if ! has_speech "$chunk_file" "$idx"; then
    printf "%s.%s" "$C_GRAY" "$C_RESET"
    return 0
  fi

  # temperature/temperature_inc: same values the browser console settled on after its own
  # repetition-loop hallucination incident (see CLAUDE.md) — 0 for a greedy first pass,
  # 0.2 to keep whisper's own escalating-temperature retry alive rather than disabling it.
  # no_speech_thold: see NO_SPEECH_THOLD above.

  # Transcription (original language)
  local transcription
  transcription=$(curl -s "http://${WHISPER_HOST}/inference" \
    -F file="@$chunk_file" \
    -F language="$LANGUAGE" \
    -F translate="false" \
    -F response_format="text" \
    -F temperature="0" \
    -F temperature_inc="0.2" \
    -F no_speech_thold="$NO_SPEECH_THOLD")
  transcription=$(trim "$transcription")

  # Translation (to English)
  local translation
  translation=$(curl -s "http://${WHISPER_HOST}/inference" \
    -F file="@$chunk_file" \
    -F language="$LANGUAGE" \
    -F translate="true" \
    -F response_format="text" \
    -F temperature="0" \
    -F temperature_inc="0.2" \
    -F no_speech_thold="$NO_SPEECH_THOLD")
  translation=$(trim "$translation")

  # Filter out very short results (likely hallucinations)
  local trans_len=${#transcription}
  local transl_len=${#translation}
  
  # Check for known hallucination patterns
  local is_hallucination=0
  local lower_trans=$(echo "$transcription" | tr '[:upper:]' '[:lower:]')
  local lower_transl=$(echo "$translation" | tr '[:upper:]' '[:lower:]')
  for pattern in "${HALLUCINATIONS[@]}"; do
    if [[ "$lower_trans" == *"$pattern"* ]] || [[ "$lower_transl" == *"$pattern"* ]]; then
      is_hallucination=1
      break
    fi
  done

  # Color/prefix escapes are interpolated straight into the format string (they
  # never contain a literal %), but the transcribed/translated text always goes
  # through as a %s argument — if Whisper ever emits a stray % in its output,
  # printf must not try to interpret it as a format specifier.
  if [ "$trans_len" -ge "$MIN_TEXT_LENGTH" ] && [ -n "$transcription" ] && [ "$is_hallucination" -eq 0 ]; then
    echo ""
    print_timestamp_rule "$(date '+%H:%M:%S')"
    printf "${C_BOLD}${C_DE}[%s]${C_RESET} ${C_DE}%s${C_RESET}\n" "$LANGUAGE" "$transcription"
    write_srt_block "$SRT_SOURCE_FILE" "$idx" "$transcription"
  fi
  if [ "$transl_len" -ge "$MIN_TEXT_LENGTH" ] && [ -n "$translation" ] && [ "$is_hallucination" -eq 0 ]; then
    printf "${C_BOLD}${C_EN}[EN]${C_RESET} ${C_EN}%s${C_RESET}\n" "$translation"
    write_srt_block "$SRT_EN_FILE" "$idx" "$translation"
  fi
}

echo "${C_AMBER}VERMITTLUNG${C_RESET} ${C_DIM}// live call transcript${C_RESET}"
echo "${C_GRAY}${C_DIM}Live transcription + translation started (${CHUNK_SECONDS}s chunks, VAD enabled). Press Ctrl+C to stop.${C_RESET}"
echo "${C_GRAY}────────────────────────────────────────────────────────────${C_RESET}"
echo "${C_BOLD}${C_DE}[${LANGUAGE}]${C_RESET} = source transcription    ${C_BOLD}${C_EN}[EN]${C_RESET} = English translation    ${C_GRAY}.${C_RESET} = listening (silence)"
echo "${C_GRAY}Saving SRT to ${SRT_SOURCE_FILE} and ${SRT_EN_FILE}${C_RESET}"
echo ""

# Use ffmpeg segment muxer to write fixed-duration chunk files directly.
# Capture input is the one genuinely OS-specific piece: Linux reaches the
# phone's HFP mic via PulseAudio (-f pulse), macOS has no PulseAudio by
# default and reaches the same CoreAudio device via -f avfoundation instead.
# BT_SOURCE is reused as-is on both platforms — a PulseAudio source name on
# Linux, an avfoundation device index or exact device name on macOS (see
# --list-devices above) — rather than adding a second, platform-specific env
# var for what is conceptually the same "which mic" setting.
start_capture() {
  local out_pattern="$1"
  case "$OS_NAME" in
    Darwin)
      ffmpeg -loglevel error \
        -f avfoundation -i ":${BT_SOURCE}" \
        -ar 16000 -ac 1 -acodec pcm_s16le \
        -f segment -segment_time "$CHUNK_SECONDS" -segment_format wav \
        -reset_timestamps 1 \
        "$out_pattern" &
      ;;
    Linux)
      ffmpeg -loglevel error \
        -f pulse -i "$BT_SOURCE" \
        -ar 16000 -ac 1 -acodec pcm_s16le \
        -f segment -segment_time "$CHUNK_SECONDS" -segment_format wav \
        -reset_timestamps 1 \
        "$out_pattern" &
      ;;
    *)
      echo "${C_RED}Unsupported OS: ${OS_NAME}. This script supports Linux and macOS.${C_RESET}" >&2
      exit 1
      ;;
  esac
  CAPTURE_PID=$!
}

start_capture "${TMPDIR}/chunk_%03d.wav"

# Allow capture to start and first chunk to be written
sleep "$((CHUNK_SECONDS + 1))"

CHUNK_IDX=0
while true; do
  CHUNK_FILE=$(printf "${TMPDIR}/chunk_%03d.wav" "$CHUNK_IDX")

  # Check capture is still running
  if ! kill -0 "$CAPTURE_PID" 2>/dev/null; then
    echo "${C_RED}Audio capture ended (device disconnected?)${C_RESET}"
    break
  fi

  # Wait for this chunk file to exist and have content
  if [ -f "$CHUNK_FILE" ] && [ -s "$CHUNK_FILE" ]; then
    process_chunk "$CHUNK_FILE" "$CHUNK_IDX" &
    CHUNK_IDX=$((CHUNK_IDX + 1))
  else
    # File not ready yet, brief wait
    sleep 0.2
  fi
done

wait "$CAPTURE_PID" 2>/dev/null
echo "${C_AMBER}Live transcription finished.${C_RESET}"