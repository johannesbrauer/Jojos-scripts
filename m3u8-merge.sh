#!/bin/bash


#To run it everywhere with just tapping m3u8-merge:
#1. remove the .sh ending
#2. chmod +x m3u8-merge
#3. sudo mv m3u8-merge /usr/local/bin/m3u8-merge

# Stop immediately on errors
set -e
drain_stdin() { while read -r -t 0.1 -n 10000 _leftover; do :; done 2>/dev/null; }

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
read -r -p "Please enter the base URL for the VIDEO: " VIDEO_BASE
VIDEO_BASE="${VIDEO_BASE//$'\r'/}"
drain_stdin()

if [ "$HAS_AUDIO" == true ]; then
    read -r -p "Please enter the base URL for the AUDIO: " AUDIO_BASE
    AUDIO_BASE="${AUDIO_BASE//$'\r'/}"
    drain_stdin()
fi

echo ""
read -p "What should the final output file be called? [final_video.mp4]: " OUTPUT_FILE
OUTPUT_FILE="${OUTPUT_FILE:-final_video.mp4}"

echo ""
echo "[1/4] Processing manifests..."
# 3. Create temporary .m3u8 files with absolute paths
sed '/^#/!s|^|'"$VIDEO_BASE"'|' "$VIDEO_INPUT" > tmp_video_ready.m3u8

if [ "$HAS_AUDIO" == true ]; then
    sed '/^#/!s|^|'"$AUDIO_BASE"'|' "$AUDIO_INPUT" > tmp_audio_ready.m3u8
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
