#!/bin/sh
# Download the test recording, verify its SHA256 and convert it to the WAV
# the fake birdmic loops. Runs inside the MediaMTX ffmpeg image (busybox wget,
# sha256sum, ffmpeg), both as a compose one-shot service and as a k8s
# initContainer. Safe to rerun: skips work when the WAV is already in place.
#
# Usage: fetch-audio.sh <output-dir>
# Source details and licence: dev/ATTRIBUTION.md
set -eu

# Two mirrors of the same file (identical bytes). Wikimedia sometimes answers
# 429 to bursts of requests, so each mirror gets a few attempts.
SOURCE_URLS="https://upload.wikimedia.org/wikipedia/commons/5/59/Turdus_merula_-_Common_Blackbird_XC26605.mp3
https://xeno-canto.org/26605/download"
SOURCE_SHA256="bd3a55851b12dd0b52b377e5541e5087d50986175e6e21487c7a3092cc32a80b"

out_dir="${1:-/audio}"
src="$out_dir/source.mp3"
wav="$out_dir/bird.wav"

mkdir -p "$out_dir"

verify() {
    echo "$SOURCE_SHA256  $src" | sha256sum -c -s
}

if [ -s "$wav" ] && [ -f "$src" ] && verify; then
    echo "fetch-audio: $wav already present, nothing to do"
    exit 0
fi

download() {
    for url in $SOURCE_URLS; do
        for attempt in 1 2 3; do
            echo "fetch-audio: downloading $url (attempt $attempt)"
            rm -f "$src.part"
            if wget -q -T 30 -U "birdstation-dev/1.0" -O "$src.part" "$url"; then
                mv "$src.part" "$src"
                if verify; then
                    return 0
                fi
                echo "fetch-audio: SHA256 mismatch for $url, discarding" >&2
                rm -f "$src"
                break
            fi
            sleep $((attempt * 5))
        done
    done
    return 1
}

if [ ! -f "$src" ] || ! verify; then
    if ! download; then
        echo "fetch-audio: no verified copy of the recording could be downloaded" >&2
        exit 1
    fi
fi
echo "fetch-audio: checksum OK"

# 48 kHz mono 16-bit, so the runOnInit ffmpeg only has to swap byte order.
ffmpeg -nostdin -hide_banner -loglevel error -y -i "$src" \
    -ar 48000 -ac 1 -c:a pcm_s16le -map_metadata -1 -bitexact \
    -f wav "$wav.part"
mv "$wav.part" "$wav"
echo "fetch-audio: wrote $wav"
