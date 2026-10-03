#!/bin/bash
# Check of the safety gate. Sends a known clip through real SRT with simulated WiFi loss
# and compares every frame the receiver would show, by MD5, with the clean original.
# Fails if a single damaged frame gets through, if a clean run drops frames, or if the
# gate does not open again after a loss. Takes about two minutes.
set -euo pipefail
cd "$(dirname "$0")"
PY=${PYTHON:-python3}
tmp=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$tmp"' EXIT

make -s airfeed
enc="-f lavfi -i testsrc2=s=1280x720:r=50 -t 20 -pix_fmt yuv420p -b:v 6M -maxrate 6M -bufsize 1M -g 50"
ffmpeg -v error $enc -c:v libx264 -preset veryfast -tune zerolatency -f mpegts "$tmp/h264.ts"
ffmpeg -v error $enc -c:v libx265 -preset ultrafast -tune zerolatency -x265-params log-level=error -f mpegts "$tmp/hevc.ts"

# run <name> <clip> <random loss 0..1> <blackout seconds> <every seconds>
run() {
    ffmpeg -v error -y -i "$tmp/$2.ts" -f framemd5 "$tmp/ref.md5"
    ./airfeed -md5 -port 9000 > "$tmp/out.md5" 2> "$tmp/out.log" & rx=$!
    $PY lossy.py 9050 9000 "$3" "$4" "$5" & proxy=$!
    sleep 0.5
    if ffmpeg -v quiet -protocols | grep -qw srt; then
        ffmpeg -v error -re -i "$tmp/$2.ts" -c copy -f mpegts "srt://127.0.0.1:9050?pkt_size=1316"
    else # this ffmpeg has no SRT: send UDP and let srt-live-transmit carry it
        srt-live-transmit -q udp://:9100 srt://127.0.0.1:9050 & tx=$!
        sleep 1
        ffmpeg -v error -re -i "$tmp/$2.ts" -c copy -f mpegts "udp://127.0.0.1:9100?pkt_size=1316"
        sleep 1
        kill $tx
    fi
    wait $rx
    kill $proxy 2>/dev/null || true
    $PY - "$1" "$tmp" "$4" <<'EOF'
import sys
name, tmp, outages = sys.argv[1], sys.argv[2], sys.argv[3] != "0"
ref = [l.split(",") for l in open(tmp + "/ref.md5") if l.strip() and not l.startswith("#")]
good = {f[-1].strip() for f in ref}
assert len(good) == len(ref), "reference frames are not unique"
out = [l.split() for l in open(tmp + "/out.md5")]
bad = sum(h not in good for _, h in out)
gap = max((int(b[0]) - int(a[0]) for a, b in zip(out, out[1:])), default=0) / 90
print(f"{name:14} {len(out):4} of {len(ref)} frames shown, {bad} damaged, longest gap {gap:.0f} ms |",
      [l for l in open(tmp + "/out.log") if "disconnected" in l][-1].strip())
assert bad == 0, "DAMAGED FRAMES WERE SHOWN"
assert len(out) > len(ref) // 2, "the gate stayed shut"
# A sender that closes at once (ffmpeg's own SRT) takes the last SRT buffer of frames
# with it, so allow a few missing at the very end.
if outages:
    assert len(out) < len(ref) - 10, "no loss was simulated, so this run proves nothing"
if name.endswith("clean"):
    assert len(out) >= len(ref) - 10 and gap < 25, "frames went missing on a clean link"
EOF
}

# Random loss is mostly repaired by SRT. The 1.5 s outages are too long to repair.
run "h264 clean"    h264 0    0   0
run "h264 5% loss"  h264 0.05 0   0
run "h264 outages"  h264 0.02 1.5 5
run "hevc clean"    hevc 0    0   0
run "hevc outages"  hevc 0.02 1.5 5
echo "PASS: no damaged frame was shown"
