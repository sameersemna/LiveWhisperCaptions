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

# Micro-chunk granularity: the unit ffmpeg's segment muxer writes and has_speech()
# classifies speech/silence on. Never sent to Whisper directly — see the VAD state
# machine in the main loop below, which accumulates consecutive micro-chunks into a
# variable-length segment cut on real pauses instead of a fixed timer. Replaces the
# old fixed CHUNK_SECONDS=3 "cut every 3s regardless of content" design, which sliced
# sentences in half at arbitrary points (see the CLAUDE.md gotcha for a concrete
# example from a real transcript).
MICRO_CHUNK_SECONDS=1
# Consecutive silent micro-chunks after speech before a segment is cut (pause
# detected). At MICRO_CHUNK_SECONDS=1 granularity, 1 means a pause is recognized
# after roughly one micro-chunk's worth of silence following speech.
HANGOVER_SECONDS=1
# Safety cap: force a cut even with no pause, so one long run-on sentence with no
# breath doesn't grow unbounded. Lowered from 15s to 10s per user decision
# (2026-08-28) — 15s was letting too much rambling, multi-exchange dialogue pile
# up under one timestamp before cutting (see a real transcript sample from that
# session for what this looked like in practice). 10s still covers a full
# sentence in normal speech, tighter latency/hallucination-risk ceiling than 15s.
MAX_SEGMENT_SECONDS=10

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

  # Both filters chained into ONE ffmpeg invocation via -af "volumedetect,silencedetect=..."
  # rather than two separate ffmpeg processes — a real, measured performance fix
  # (2026-08-28). Two sequential ffmpeg calls took ~1.08s of wall time per has_speech()
  # call, but the main loop invokes this once per MICRO_CHUNK_SECONDS=1 — meaning the VAD
  # check alone took *longer* than the real-time budget it had to run in, so the loop
  # structurally could not keep up with live audio and fell further behind every single
  # iteration. That accumulating lag, not the segment length itself, is what "waiting
  # almost 10 seconds for a transcript" actually was — it got worse the longer a call ran.
  # One combined invocation measures at ~0.5s, safely under the 1s-per-micro-chunk budget.
  # (This is also why the two ffmpeg calls were sequential single-purpose invocations in
  # the first place, before this fix — ffmpeg can run multiple audio filters in one pass
  # just fine, chained with a comma, this just hadn't been done yet.)
  #
  # -loglevel info, not error: volumedetect/silencedetect report their stats (mean_volume,
  # silence_start/end/duration) via ffmpeg's own INFO-level logging, not as filter output
  # on stdout. -loglevel error silently discards that entire line — confirmed live
  # (2026-08-22): with -loglevel error this function's grep patterns below never matched
  # anything, on ANY audio, so both detection methods always fell through and has_speech()
  # always returned "has speech" regardless of actual content. That's the real cause of a
  # real incident: every chunk, including pure silence, was being sent to Whisper, which
  # hallucinated freely on it.
  local combined_info
  combined_info=$(ffmpeg -hide_banner -loglevel info -i "$chunk_file" \
    -af "volumedetect,silencedetect=noise=${SILENCE_THRESHOLD_DB}dB:d=${SILENCE_DURATION}" \
    -f null - 2>&1)

  # sed -E, not grep -oP: -P (PCRE) is a GNU grep extension that BSD grep
  # (macOS default) doesn't support — it would fail silently there, leaving
  # mean_volume always empty and has_speech() always falling through to
  # "has speech", the same class of silent VAD-gate failure the -loglevel
  # info fix above addressed for a different tool gap. sed -E's POSIX ERE
  # (character classes + backreference) works identically on GNU and BSD sed.
  local mean_volume
  mean_volume=$(echo "$combined_info" | sed -nE 's/.*mean_volume:[[:space:]]*(-?[0-9.]+).*/\1/p' | head -1)

  if [ -n "$mean_volume" ]; then
    # mean_volume is negative dB, more negative = quieter
    if (( $(echo "$mean_volume < $RMS_THRESHOLD_DB" | bc -l 2>/dev/null || echo 0) )); then
      return 1
    fi
  fi

  # If silencedetect found silence spanning most of the chunk, skip it
  if echo "$combined_info" | grep -q "silence_end"; then
    local silence_dur
    silence_dur=$(echo "$combined_info" | sed -nE 's/.*silence_duration: ([0-9.]+).*/\1/p' | head -1)
    if [ -n "$silence_dur" ]; then
      local threshold
      threshold=$(echo "$MICRO_CHUNK_SECONDS * 0.8" | bc -l 2>/dev/null || echo "0.8")
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
# "000": segment boundaries are always multiples of MICRO_CHUNK_SECONDS (the
# VAD state machine below only ever cuts on a micro-chunk boundary, never
# mid-micro-chunk), so cue timing is exact multiples of a whole number of
# seconds — there's no sub-second component to report.
srt_timestamp() {
  local total="$1"
  printf '%02d:%02d:%02d,000' $(( total/3600 )) $(( (total%3600)/60 )) $(( total%60 ))
}

# Appends one SRT block. Sequence number comes straight from the segment index
# (idx+1) and cue timing from the segment's own start_sec/end_sec (computed by
# the caller from its first/last micro-chunk index — see finalize_segment()) —
# neither needs a shared counter, so concurrent background process_chunk calls
# (see the main loop below) never need to coordinate over what number/timestamp
# to use, only over not corrupting each other's actual write. The mkdir-based
# lock below handles that: segments can finish out of order (whichever
# segment's whisper call comes back first appends first), so blocks may land
# on disk out of sequence, but each block's own number/timestamps are always
# correct regardless of write order — SRT players key off timestamps, not file
# position. (Segments are now variable-length — see MAX_SEGMENT_SECONDS above —
# so start_sec/end_sec can no longer be derived from idx*a-fixed-duration the
# way the old fixed-timer design did; they're passed in explicitly instead.)
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
  local file="$1" idx="$2" start_sec="$3" end_sec="$4" text="$5"
  local seq=$(( idx + 1 ))
  local start_ts end_ts
  start_ts=$(srt_timestamp "$start_sec")
  end_ts=$(srt_timestamp "$end_sec")
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
  local start_sec="$3"
  local end_sec="$4"
  [ -s "$chunk_file" ] || return 0

  # Re-check the whole concatenated segment (belt-and-suspenders): the VAD state
  # machine in the main loop already only finalizes segments that had at least one
  # speech micro-chunk, but this stays as a second independent check, same layered-
  # heuristic pattern the hallucination filtering below already uses.
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
    write_srt_block "$SRT_SOURCE_FILE" "$idx" "$start_sec" "$end_sec" "$transcription"
  fi
  if [ "$transl_len" -ge "$MIN_TEXT_LENGTH" ] && [ -n "$translation" ] && [ "$is_hallucination" -eq 0 ]; then
    printf "${C_BOLD}${C_EN}[EN]${C_RESET} ${C_EN}%s${C_RESET}\n" "$translation"
    write_srt_block "$SRT_EN_FILE" "$idx" "$start_sec" "$end_sec" "$translation"
  fi
}

# Fail fast and clearly if BT_SOURCE is unset/empty, rather than letting ffmpeg
# hit it with a bare ":" (avfoundation) or "" (pulse) and produce a cryptic
# "No AV capture device found" / "Unknown input format" error that doesn't say
# what's actually wrong. Real incident (2026-09-02): a fresh macOS checkout had
# no BT_SOURCE set (either .env didn't exist yet on that machine, or a Linux
# .env was copied over without adding the macOS-specific value), and the
# resulting `-i ":"` failed with an error giving no hint that BT_SOURCE itself
# was the problem.
if [ -z "$BT_SOURCE" ]; then
  echo "${C_RED}BT_SOURCE is not set (check .env in this directory).${C_RESET}" >&2
  case "$OS_NAME" in
    Darwin)
      echo "${C_RED}On macOS, BT_SOURCE must be an avfoundation audio device index or exact${C_RESET}" >&2
      echo "${C_RED}device name. Run: ./call-transcribe-live.sh --list-devices${C_RESET}" >&2
      ;;
    Linux)
      echo "${C_RED}On Linux, BT_SOURCE must be a PulseAudio source name. Run:${C_RESET}" >&2
      echo "${C_RED}  ./call-transcribe-live.sh --list-devices${C_RESET}" >&2
      ;;
  esac
  exit 1
fi

echo "${C_AMBER}VERMITTLUNG${C_RESET} ${C_DIM}// live call transcript${C_RESET}"
echo "${C_GRAY}${C_DIM}Live transcription + translation started (pause-based segmentation, max ${MAX_SEGMENT_SECONDS}s/sentence). Press Ctrl+C to stop.${C_RESET}"
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
        -f segment -segment_time "$MICRO_CHUNK_SECONDS" -segment_format wav \
        -reset_timestamps 1 \
        "$out_pattern" &
      ;;
    Linux)
      ffmpeg -loglevel error \
        -f pulse -i "$BT_SOURCE" \
        -ar 16000 -ac 1 -acodec pcm_s16le \
        -f segment -segment_time "$MICRO_CHUNK_SECONDS" -segment_format wav \
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

# Concatenates the given micro-chunk WAV files (all identical pcm_s16le/16kHz/mono,
# written by the same segment muxer) into one segment WAV via ffmpeg's concat
# demuxer, then backgrounds process_chunk on it — same "one background job per
# unit sent to Whisper" shape the old fixed-timer loop used, just fed a variable-
# length concatenated segment instead of a single fixed-size chunk. seq is the
# segment's own sequence number (assigned by the caller in the main loop, before
# backgrounding — never inside this function/process_chunk itself — so concurrent
# finalize_segment calls never need to coordinate over which number to use, same
# property write_srt_block's own comment above documents).
finalize_segment() {
  local seq="$1" start_sec="$2" end_sec="$3"
  shift 3
  local files=("$@")
  [ "${#files[@]}" -gt 0 ] || return 0

  local tag
  tag=$(printf '%04d' "$seq")
  local listfile="${TMPDIR}/seglist_${tag}.txt"
  local out="${TMPDIR}/segment_${tag}.wav"
  : > "$listfile"
  local f
  for f in "${files[@]}"; do
    printf "file '%s'\n" "$f" >> "$listfile"
  done

  # Concat AND process_chunk both run inside the same backgrounded subshell now, not just
  # process_chunk (2026-08-28, real, measured performance fix). The concat step alone
  # blocked the main loop for ~0.6s of wall time — and it ran synchronously, right at the
  # exact moment a segment finishes and the next micro-chunk needs polling, on top of the
  # has_speech() lag fixed above. Backgrounding the whole pipeline lets the main loop return
  # to polling immediately instead of stalling at the one moment latency is most visible.
  (
    ffmpeg -loglevel error -f concat -safe 0 -i "$listfile" -c copy -y "$out"
    rm -f "$listfile"
    process_chunk "$out" "$seq" "$start_sec" "$end_sec"
  ) &
}

start_capture "${TMPDIR}/chunk_%03d.wav"

# Allow capture to start and first micro-chunk to be written
sleep "$((MICRO_CHUNK_SECONDS + 1))"

# VAD state machine: accumulates consecutive speech micro-chunks (has_speech(),
# reused unchanged from before) into a segment, and finalizes it — concatenates +
# sends to Whisper — either on a pause (HANGOVER_SECONDS of silence following
# speech) or once MAX_SEGMENT_SECONDS is reached, whichever comes first. This is
# the CLI equivalent of the browser console's own Tier 2 VAD endpointing (see
# CLAUDE.md) — replaces the old "cut every MICRO_CHUNK_SECONDS regardless of
# content" design, which sliced sentences at arbitrary fixed-timer boundaries.
MICRO_IDX=0
SEGMENT_SEQ=0
segment_active=0
segment_first_idx=0
silence_run=0
pending_files=()

while true; do
  MICRO_FILE=$(printf "${TMPDIR}/chunk_%03d.wav" "$MICRO_IDX")

  # Check capture is still running
  if ! kill -0 "$CAPTURE_PID" 2>/dev/null; then
    echo "${C_RED}Audio capture ended (device disconnected?)${C_RESET}"
    break
  fi

  # Wait for this micro-chunk file to exist and have content
  if [ ! -f "$MICRO_FILE" ] || [ ! -s "$MICRO_FILE" ]; then
    sleep 0.2
    continue
  fi

  if has_speech "$MICRO_FILE" "$MICRO_IDX"; then
    if [ "$segment_active" -eq 0 ]; then
      segment_active=1
      segment_first_idx="$MICRO_IDX"
      pending_files=()
    fi
    pending_files+=("$MICRO_FILE")
    silence_run=0
  else
    if [ "$segment_active" -eq 1 ]; then
      # Keep trailing silence in the segment (natural pause padding) until hangover
      # is reached — matches the browser VAD's own hangover behavior.
      pending_files+=("$MICRO_FILE")
      silence_run=$((silence_run + 1))
    else
      printf "%s.%s" "$C_GRAY" "$C_RESET"
    fi
  fi

  if [ "$segment_active" -eq 1 ]; then
    local_elapsed=$(( (MICRO_IDX - segment_first_idx + 1) * MICRO_CHUNK_SECONDS ))
    if [ "$silence_run" -ge "$HANGOVER_SECONDS" ] || [ "$local_elapsed" -ge "$MAX_SEGMENT_SECONDS" ]; then
      start_sec=$(( segment_first_idx * MICRO_CHUNK_SECONDS ))
      end_sec=$(( (MICRO_IDX + 1) * MICRO_CHUNK_SECONDS ))
      finalize_segment "$SEGMENT_SEQ" "$start_sec" "$end_sec" "${pending_files[@]}"
      SEGMENT_SEQ=$((SEGMENT_SEQ + 1))
      segment_active=0
      silence_run=0
      pending_files=()
    fi
  fi

  MICRO_IDX=$((MICRO_IDX + 1))
done

# Flush whatever was still accumulating when capture ended (device disconnected —
# Ctrl+C instead goes straight through the EXIT/INT trap to cleanup(), same as
# before this change, so this only fires on the disconnect path).
if [ "$segment_active" -eq 1 ] && [ "${#pending_files[@]}" -gt 0 ]; then
  start_sec=$(( segment_first_idx * MICRO_CHUNK_SECONDS ))
  end_sec=$(( (MICRO_IDX) * MICRO_CHUNK_SECONDS ))
  finalize_segment "$SEGMENT_SEQ" "$start_sec" "$end_sec" "${pending_files[@]}"
fi

wait "$CAPTURE_PID" 2>/dev/null
echo "${C_AMBER}Live transcription finished.${C_RESET}"