#!/bin/bash
# Experiments 1 and 2: receive the iPhone's SRT stream on this Mac, show it live,
# and save it plus SRT statistics for inspection.
# usage: experiments/capture.sh [port] [srt_latency_ms]
# Stop with q in the video window, or Ctrl-C.
set -uo pipefail
port=${1:-9000}
latency=${2:-120}
dir="$(dirname "$0")/captures"
mkdir -p "$dir"
out="$dir/$(date +%Y%m%d-%H%M%S)"

echo "Listening on srt://$(ipconfig getifaddr en0):$port (receiver latency $latency ms)"
trap : INT
srt-live-transmit -s:200 -pf:json -statsout:"$out.stats.json" \
    "srt://:$port?mode=listener&latency=$latency" file://con \
  | tee "$out.ts" \
  | { ffplay -loglevel warning -an -fflags nobuffer -flags low_delay -probesize 32768 \
        -analyzeduration 0 -framedrop -window_title AirFeed -f mpegts -i - \
      || cat > /dev/null; }  # if the viewer fails, keep saving the stream anyway

echo
echo "Saved $out.ts"
# MPEG-TS lists each stream twice (once under its program), hence the dedupe.
ffprobe -v error -show_entries \
    stream=index,codec_type,codec_name,profile,width,height,pix_fmt,color_range,avg_frame_rate,has_b_frames,sample_rate,channels \
    -of compact=p=0 "$out.ts" | awk '!seen[$0]++'
