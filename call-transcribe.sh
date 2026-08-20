#!/bin/bash
# call-transcribe.sh

# get environment variables from .env file
if [ -f .env ]
then
  export $(cat .env | sed 's/#.*//g' | xargs)
fi

TMPFILE="/tmp/call_$(date +%s).wav"

echo "Recording... press Ctrl+C when the call ends."
parecord --channels=1 --rate=16000 -d "$BT_SOURCE" "$TMPFILE"

echo "Sending to whisper server for translation..."
curl -s http://$WHISPER_HOST/inference \
  -F file=@"$TMPFILE" \
  -F language="de" \
  -F translate="true" \
  -F response_format="text"

shred -u "$TMPFILE"
echo -e "\nLocal recording deleted."