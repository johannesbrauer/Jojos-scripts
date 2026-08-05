# Jojo's Scripts

A personal collection of shell scripts and small tools. Click a script name below to jump straight to its explanation.

## 📜 Scripts

| Script | Description |
|---|---|
| [`m3u8-merge`](#m3u8-merge) | Downloads a video and audio track from `.m3u8` (HLS) playlists and merges them into a single `.mp4` file. |

---

## m3u8-merge

A small interactive Bash script that downloads a **video** and an **audio** track from separate `.m3u8` (HLS) playlists and merges them into a single `.mp4` file — without re-encoding, so there is no quality loss.

[⬆ Back to top](#jojos-scripts)

### What it does

1. Asks you for the filenames of your local `video.m3u8` and (optionally) `audio.m3u8` playlists.
2. Asks for the **base URL** the segments are hosted on, since `.m3u8` files often only contain relative segment paths (e.g. `seg_001.ts`) rather than full URLs.
3. Rewrites the playlists into temporary files with absolute URLs (`sed`), so `yt-dlp` can resolve every segment correctly.
4. Downloads the video track (and audio track, if provided) with `yt-dlp`, using its native downloader — this is important because some HLS streams disguise `.ts` segments with extensions like `.jpg` or `.js`, which `yt-dlp`'s native downloader handles correctly.
5. Muxes (merges) video and audio into one file using `ffmpeg -c copy`, i.e. it just repackages the streams instead of re-encoding them — fast and lossless.
6. Cleans up all temporary files automatically.

### Requirements

You need these tools installed and available in your `PATH`:

| Tool | Purpose | Install (Debian/Ubuntu) | Install (macOS) |
|---|---|---|---|
| [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) | Downloads the media segments referenced in the `.m3u8` playlists | `sudo apt install yt-dlp` or `pip install -U yt-dlp` | `brew install yt-dlp` |
| [`ffmpeg`](https://ffmpeg.org/) | Merges (muxes) the downloaded video/audio into the final file | `sudo apt install ffmpeg` | `brew install ffmpeg` |
| `bash`, `sed` | Running the script itself | Preinstalled on virtually every Linux/macOS system | Preinstalled |

Tested on Linux; should work on macOS and WSL as-is since it only relies on standard Bash/`sed`.

### Installation

Save the script as `m3u8-merge.sh`, then either run it directly or install it globally so you can call it from anywhere by just typing `m3u8-merge`.

```bash
# Run directly
chmod +x m3u8-merge.sh
./m3u8-merge.sh
```

**Install globally (optional):**

```bash
cp m3u8-merge.sh m3u8-merge   # drop the .sh extension
chmod +x m3u8-merge
sudo mv m3u8-merge /usr/local/bin/m3u8-merge
```

After that you can just run `m3u8-merge` from any folder.

### Usage

1. Place your `video.m3u8` (and optionally `audio.m3u8`) files in the folder you're running the script from.
2. Run the script and answer the prompts:

   ```
   === Bash M3U8 Audio/Video Merger ===

   What is your VIDEO m3u8 file called? [video.m3u8]:
   What is your AUDIO m3u8 file called? (enter 0 to skip audio) [audio.m3u8]:
   Please enter the base URL for the VIDEO:
   Please enter the base URL for the AUDIO:
   What should the final output file be called? [final_video.mp4]:
   ```

3. The script downloads both tracks and merges them. Progress is shown as `[1/4]` to `[4/4]`.
4. You end up with a single `final_video.mp4` (or whatever name you chose) in the current folder.

#### Video-only mode

If you don't have (or don't want) a separate audio track, just enter `0` when asked for the audio `.m3u8` filename — the script will skip the audio download and merge step and just repackage the video track.

### What you need to figure out yourself

- **Where to get the `.m3u8` files and base URL from:** This script assumes you've already obtained the video/audio playlist files (e.g. via a browser's dev tools / network tab) and know the base URL the segments are served from. It does not scrape or discover these for you.
- **Relative vs. absolute segment paths:** The base-URL step only makes sense if your `.m3u8` file uses relative segment paths. If it already contains full URLs, just use yt-dlp.

[⬆ Back to top](#jojos-scripts)
