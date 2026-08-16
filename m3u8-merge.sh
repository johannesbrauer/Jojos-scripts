#!/bin/bash


#To run it everywhere with just tapping m3u8-merge:
#1. remove the .sh ending
#2. chmod +x m3u8-merge
#3. sudo mv m3u8-merge /usr/local/bin/m3u8-merge

# Stop immediately on errors
set -e
drain_stdin() { while read -r -t 0.1 -n 10000 _leftover; do :; done 2>/dev/null; }
bind "set enable-bracketed-paste on" 2>/dev/null || true

# Reads a base URL robustly: pastes often contain stray newlines or wrap the
# URL over several lines, so every pasted line is joined and the result is
# trimmed. Retries until a non-empty URL has been entered.
read_base_url() {
    local prompt="$1" url="" line
    while :; do
        url=""
        read -e -r -p "$prompt" line
        line="${line//$'\r'/}"
        url+="$line"
        while read -r -t 0.3 line && [ -n "$line" ]; do
            line="${line//$'\r'/}"
            url+="$line"
        done
        url="${url//$'\n'/}"
        url="${url%\"}"; url="${url#\"}"
        url="${url#"${url%%[![:space:]]*}"}"
        url="${url%"${url##*[![:space:]]}"}"
        if [ -n "$url" ]; then
            printf '%s' "$url"
            return 0
        fi
        echo "The URL is empty (a stray newline in the paste?) - please try again."
    done
}

echo "=== Bash M3U8 Audio/Video Merger ==="
echo ""

# 1. Ask for the existing M3U8 file names (with defaults)
read -p "What is your VIDEO m3u8 file called? [video.m3u8]: " VIDEO_INPUT
VIDEO_INPUT="${VIDEO_INPUT:-video.m3u8}"

read -p "What is your AUDIO m3u8 file called? (enter 0 to skip audio) [audio.m3u8]: " AUDIO_INPUT
AUDIO_INPUT="${AUDIO_INPUT:-audio.m3u8}"

if [ "$AUDIO_INPUT" == "0" ]; then
    HAS_AUDIO=false
else
    HAS_AUDIO=true
fi

# Validate that the files exist
if [ ! -f "$VIDEO_INPUT" ]; then
    echo "Error: the video file was not found in the current folder!"
    exit 1
fi

if [ "$HAS_AUDIO" == true ] && [ ! -f "$AUDIO_INPUT" ]; then
    echo "Error: the audio file was not found in the current folder!"
    exit 1
fi

echo ""
# 2. Ask for the base URLs
drain_stdin
VIDEO_BASE="$(read_base_url "Please enter the base URL for the VIDEO: ")"
echo "  -> using VIDEO base URL: $VIDEO_BASE"
if [[ "$VIDEO_BASE" != *://* ]]; then
    echo "Warning: this base URL has no scheme (https://...) - yt-dlp will likely fail."
fi
drain_stdin

if [ "$HAS_AUDIO" == true ]; then
    drain_stdin
    AUDIO_BASE="$(read_base_url "Please enter the base URL for the AUDIO: ")"
    echo "  -> using AUDIO base URL: $AUDIO_BASE"
    if [[ "$AUDIO_BASE" != *://* ]]; then
        echo "Warning: this base URL has no scheme (https://...) - yt-dlp will likely fail."
    fi
    drain_stdin
fi

echo ""
read -p "What should the final output file be called? [final_video.mp4]: " OUTPUT_FILE
OUTPUT_FILE="${OUTPUT_FILE:-final_video.mp4}"

echo ""
echo "[1/4] Processing manifests..."
# 3. Create temporary .m3u8 files with absolute paths
#    (awk instead of sed: robust against '|' in the URL and skips blank lines,
#     which otherwise would turn into the bare base URL and confuse yt-dlp)
awk -v base="$VIDEO_BASE" '/^#/ { print; next } NF == 0 { next } { print base $0 }' "$VIDEO_INPUT" > tmp_video_ready.m3u8

if [ "$HAS_AUDIO" == true ]; then
    awk -v base="$AUDIO_BASE" '/^#/ { print; next } NF == 0 { next } { print base $0 }' "$AUDIO_INPUT" > tmp_audio_ready.m3u8
fi

echo "[2/4] Downloading video track (disguised segments)..."
# 4. Download the tracks via yt-dlp (force native downloader because of .jpg/.js extensions)
yt-dlp --enable-file-urls "file://$(pwd)/tmp_video_ready.m3u8" -o "tmp_raw_video.mp4"

if [ "$HAS_AUDIO" == true ]; then
    echo "[3/4] Downloading audio track..."
    yt-dlp --enable-file-urls "file://$(pwd)/tmp_audio_ready.m3u8" -o "tmp_raw_audio.mp4"
else
    echo "[3/4] Skipping audio download (no audio selected)..."
fi

echo "[4/4] Merging (muxing) via ffmpeg..."
# 5. Merge without quality loss
if [ "$HAS_AUDIO" == true ]; then
    ffmpeg -y -i tmp_raw_video.mp4 -i tmp_raw_audio.mp4 -c copy "$OUTPUT_FILE"
else
    ffmpeg -y -i tmp_raw_video.mp4 -c copy "$OUTPUT_FILE"
fi

# 6. Clean up temporary files
rm -f tmp_video_ready.m3u8 tmp_audio_ready.m3u8 tmp_raw_video.mp4 tmp_raw_audio.mp4

echo ""
echo "=== DONE! Your file '$OUTPUT_FILE' is ready. ==="
