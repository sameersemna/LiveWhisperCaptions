#!/bin/bash
# call-transcribe-live.sh
# Live chunked transcription AND translation via Whisper server with VAD.
# Uses ffmpeg segment muxer to write fixed-duration WAV chunks,
# filters out silence using ffmpeg's silencedetect, then sends the
# speech-containing chunks for transcription and translation.
#
# Requires: ffmpeg, curl
#
# Usage:
#   ./call-transcribe-live.sh [LANG_CODE]
#
#   LANG_CODE  Source language (default: de). Examples: de, en, fr, es, it, nl...
#
# Example: ./call-transcribe-live.sh es   # Spanish source, translated to English
# Press Ctrl+C to stop.

# get environment variables from .env file
if [ -f .env ]; then
  export $(cat .env | sed 's/#.*//g' | xargs)
fi

# Source language from CLI arg (default: de)
LANGUAGE="${1:-de}"

CHUNK_SECONDS=3
# Silence detection: treat as silence if below -25dB for 0.3s+ (more aggressive)
SILENCE_THRESHOLD_DB=-25
SILENCE_DURATION=0.3
# Also check mean_volume - if average < -40dB, consider it silence
RMS_THRESHOLD_DB=-40
# Minimum transcription length to avoid hallucinations
MIN_TEXT_LENGTH=20

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
  echo "Warning: $HALLUCINATIONS_FILE not found — hallucination filtering disabled." >&2
  HALLUCINATIONS=()
fi
BASENAME="call_live_$(date +%s)"
TMPDIR="/tmp/${BASENAME}_chunks"
mkdir -p "$TMPDIR"

cleanup() {
  echo -e "\nStopping..."
  kill "$CAPTURE_PID" 2>/dev/null
  rm -rf "$TMPDIR"
  echo "Cleaned up temporary files."
  exit 0
}
trap cleanup EXIT INT TERM

# Check if a chunk contains speech (not just silence)
# Returns 0 (true) if speech detected, 1 (false) if silence
has_speech() {
  local chunk_file="$1"
  local idx="$2"

  # Method 1: volumedetect for mean_volume (RMS equivalent)
  local vol_info
  vol_info=$(ffmpeg -hide_banner -loglevel error -i "$chunk_file" \
    -af "volumedetect" -f null - 2>&1)

  local mean_volume
  mean_volume=$(echo "$vol_info" | grep -oP 'mean_volume:\s*\K[-]?[\d.]+' | head -1)

  if [ -n "$mean_volume" ]; then
    # mean_volume is negative dB, more negative = quieter
    if (( $(echo "$mean_volume < $RMS_THRESHOLD_DB" | bc -l 2>/dev/null || echo 0) )); then
      return 1
    fi
  fi

  # Method 2: silencedetect as backup
  local silence_info
  silence_info=$(ffmpeg -hide_banner -loglevel error -i "$chunk_file" \
    -af "silencedetect=noise=${SILENCE_THRESHOLD_DB}dB:d=${SILENCE_DURATION}" \
    -f null - 2>&1)

  # If silencedetect found silence spanning most of the chunk, skip it
  if echo "$silence_info" | grep -q "silence_end"; then
    local silence_dur
    silence_dur=$(echo "$silence_info" | grep -oP 'silence_duration: \K[\d.]+' | head -1)
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

process_chunk() {
  local chunk_file="$1"
  local idx="$2"
  [ -s "$chunk_file" ] || return 0

  # Skip if chunk is mostly silence (prevents Whisper hallucinations)
  if ! has_speech "$chunk_file" "$idx"; then
    return 0
  fi

  # Transcription (original language)
  local transcription
  transcription=$(curl -s "http://${WHISPER_HOST}/inference" \
    -F file="@$chunk_file" \
    -F language="$LANGUAGE" \
    -F translate="false" \
    -F response_format="text")

  # Translation (to English)
  local translation
  translation=$(curl -s "http://${WHISPER_HOST}/inference" \
    -F file="@$chunk_file" \
    -F language="$LANGUAGE" \
    -F translate="true" \
    -F response_format="text")

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

  if [ "$trans_len" -ge "$MIN_TEXT_LENGTH" ] && [ -n "$transcription" ] && [ "$is_hallucination" -eq 0 ]; then
    printf "\n[%s] %s\n" "$LANGUAGE" "$transcription"
  fi
  if [ "$transl_len" -ge "$MIN_TEXT_LENGTH" ] && [ -n "$translation" ] && [ "$is_hallucination" -eq 0 ]; then
    printf "[EN] %s\n" "$translation"
  fi
}

echo "Live transcription + translation started (${CHUNK_SECONDS}s chunks, VAD enabled). Press Ctrl+C to stop."
echo "---"
echo "[$LANGUAGE] = Source transcription | [EN] = English translation"
echo ""

# Use ffmpeg segment muxer to write fixed-duration chunk files directly.
ffmpeg -loglevel error \
  -f pulse -i "$BT_SOURCE" \
  -ar 16000 -ac 1 -acodec pcm_s16le \
  -f segment -segment_time "$CHUNK_SECONDS" -segment_format wav \
  -reset_timestamps 1 \
  "${TMPDIR}/chunk_%03d.wav" &
CAPTURE_PID=$!

# Allow capture to start and first chunk to be written
sleep "$((CHUNK_SECONDS + 1))"

CHUNK_IDX=0
while true; do
  CHUNK_FILE=$(printf "${TMPDIR}/chunk_%03d.wav" "$CHUNK_IDX")

  # Check capture is still running
  if ! kill -0 "$CAPTURE_PID" 2>/dev/null; then
    echo "Audio capture ended (device disconnected?)"
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
echo "Live transcription finished."