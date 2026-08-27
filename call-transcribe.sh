#!/bin/bash
# call-transcribe.sh

# get environment variables from .env file
if [ -f .env ]
then
  export $(cat .env | sed 's/#.*//g' | xargs)
fi

TMPFILE="/tmp/call_$(date +%s).wav"

# shred -u is GNU coreutils and isn't shipped on macOS; fall back to a plain
# rm there rather than failing outright.
secure_delete() {
  if command -v shred >/dev/null 2>&1; then
    shred -u "$1"
  else
    rm -f "$1"
  fi
}

echo "Recording... press Ctrl+C when the call ends."
# Linux reaches the phone's HFP mic via PulseAudio (parecord); macOS has no
# PulseAudio by default, so it goes through ffmpeg's avfoundation CoreAudio
# input instead (ffmpeg finalizes the WAV correctly on Ctrl+C, same as
# parecord). BT_SOURCE is a PulseAudio source name on Linux, an avfoundation
# device index/name on macOS — see call-transcribe-live.sh --list-devices.
case "$(uname -s)" in
  Darwin)
    ffmpeg -loglevel error -f avfoundation -i ":${BT_SOURCE}" -ar 16000 -ac 1 "$TMPFILE"
    ;;
  Linux)
    parecord --channels=1 --rate=16000 -d "$BT_SOURCE" "$TMPFILE"
    ;;
  *)
    echo "Unsupported OS: $(uname -s). This script supports Linux and macOS." >&2
    exit 1
    ;;
esac

echo "Sending to whisper server for translation..."
curl -s http://$WHISPER_HOST/inference \
  -F file=@"$TMPFILE" \
  -F language="de" \
  -F translate="true" \
  -F response_format="text"

secure_delete "$TMPFILE"
echo -e "\nLocal recording deleted."