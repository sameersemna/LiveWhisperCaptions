#!/bin/bash
# call-transcribe-live.sh
# Live chunked transcription AND translation via Whisper server.
# Uses ffmpeg segment muxer to write fixed-duration WAV chunks,
# then sends each chunk for both transcription (original) and translation.
#
# Requires: ffmpeg, curl
#
# Usage: ./call-transcribe-live.sh
# Press Ctrl+C to stop.

# get environment variables from .env file
if [ -f .env ]; then
  export $(cat .env | sed 's/#.*//g' | xargs)
fi

CHUNK_SECONDS=3
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

process_chunk() {
  local chunk_file="$1"
  [ -s "$chunk_file" ] || return 0

  # Transcription (original language - German)
  local transcription
  transcription=$(curl -s "http://${WHISPER_HOST}/inference" \
    -F file="@$chunk_file" \
    -F language="de" \
    -F translate="false" \
    -F response_format="text")

  # Translation (to English)
  local translation
  translation=$(curl -s "http://${WHISPER_HOST}/inference" \
    -F file="@$chunk_file" \
    -F language="de" \
    -F translate="true" \
    -F response_format="text")

  if [ -n "$transcription" ]; then
    printf "\n[DE] %s\n" "$transcription"
  fi
  if [ -n "$translation" ]; then
    printf "[EN] %s\n" "$translation"
  fi
}

echo "Live transcription + translation started (${CHUNK_SECONDS}s chunks). Press Ctrl+C to stop."
echo "---"

# Use ffmpeg segment muxer to write fixed-duration chunk files directly.
# This avoids complex stream management - each chunk is a complete file.
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
    process_chunk "$CHUNK_FILE" &
    CHUNK_IDX=$((CHUNK_IDX + 1))
  else
    # File not ready yet, brief wait
    sleep 0.2
  fi
done

wait "$CAPTURE_PID" 2>/dev/null
echo "Live transcription finished."