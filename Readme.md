# Jojo's Scripts

A personal collection of shell scripts and small tools. Click a script name below to jump straight to its explanation.

## 📜 Scripts

| Script | Description |
|---|---|
| [`m3u8-merge`](#m3u8-merge) | Downloads a video and audio track from `.m3u8` (HLS) playlists and merges them into a single `.mp4` file. |
| [`Stalwart-installer-alpine`](#Stalwart-installer-alpine) | A simple isntaller script for Stalwart on alpine |
| [`Stalwart-updater-alpine`](#Stalwart-updater-alpine) | Companion auto-updater for Stalwart on Alpine Linux |

---

## m3u8-merge

A small interactive Bash script that downloads a **video** and an **audio** track from separate `.m3u8` (HLS) playlists and merges them into a single `.mp4` file — without re-encoding, so there is no quality loss.

[⬆ Back to top](#jojos-scripts)

### Use Cases:
Sites that restrict the directly access to the `m3u8` files and save audio and video tracks in different playlists. So you can't access them without browser emulation. With this script you can directly use the answer of the requested `m3u8` file from your browsers Network tab. Then it automatically merges video and audio so you get a single video file.

### What it does

1. Asks you for the filenames of your local `video.m3u8` and (optionally) `audio.m3u8` playlists.
2. Asks for the **base URL** the segments are hosted on, since `.m3u8` files often only contain relative segment paths (e.g. `seg_001.ts`) rather than full URLs.
3. Rewrites the playlists into temporary files with absolute URLs (`sed`), so `yt-dlp` can resolve every segment correctly.
4. Downloads the video track (and audio track, if provided) with `yt-dlp`, using its native downloader — this is important because some HLS streams disguise `.ts` segments with extensions like `.jpg` or `.js`, which `yt-dlp`'s native downloader handles correctly.
5. Muxes (merges) video and audio into one file using `ffmpeg -c copy`, i.e. it just repackages the streams instead of re-encoding them — fast and lossless.
6. Cleans up all temporary files automatically.

### Requirements

You need these tools installed and available in your `PATH`:

| Tool | Purpose | Install (Debian/Fedora) | Install (macOS) |
|---|---|---|---|
| [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) | Downloads the media segments referenced in the `.m3u8` playlists | `sudo apt install yt-dlp` or `sudo dnf install yt-dlp` | `brew install yt-dlp` |
| [`ffmpeg`](https://ffmpeg.org/) | Merges (muxes) the downloaded video/audio into the final file | `sudo apt install ffmpeg`, should be pre-installes on Fedora | `brew install ffmpeg` |
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

### Ai-notice
Yeah all these em-dashes come from a llm, guess I was just too lazy to write a documentation for my own scripts, and too lazy to remove them :) .

---

## Stalwart-installer-alpine

A Simple installer script for the Stalwart mail server on alpine Linux, it installs the newest Stalwart version, creates additional directories, creates a stalwart group and user, creates the OpenRC service and starts Stalwart in bootstrap mode and that's it.

---

## Stalwart-updater-alpine

A companion script to the Stalwart installer. It checks GitHub for a newer Stalwart release and safely swaps the binary with automatic rollback if the update fails. Features include e-mail notifications for errors, successes, and new major/minor versions, a `--check-only` mode, and an `--install-cron` option to set up daily update checks.

[⬆ Back to top](#jojos-scripts)

### What it does

1. Queries the GitHub API for the latest Stalwart release and compares it to the currently installed version.
2. If no newer version exists, exits quietly.
3. If the update is a **major or minor** version bump (e.g. `0.7.x` -> `0.8.x`), it does **not** auto-update — instead it sends an e-mail asking you to review the changelog and upgrade manually, since these releases can contain breaking changes.
4. If the update is a **patch-level** bump only (e.g. `0.8.1` -> `0.8.3`), it proceeds automatically:
   - Sends a notification that an update is being attempted.
   - Downloads the new binary from GitHub.
   - Verifies the downloaded archive contains a valid `stalwart` binary.
   - Backs up the current binary to `/usr/local/bin/stalwart.prev`.
   - Stops the OpenRC service, installs the new binary, starts the service again.
   - Runs a health check for up to 60 seconds, waiting for the service to respond on `http://127.0.0.1:8080/`.
   - If the health check passes, sends a success e-mail.
   - If the health check fails, **automatically rolls back** to the previous binary, restarts the service, and sends a failure e-mail with the full log attached.
5. Every fatal error at any stage (GitHub API unreachable, download failed, binary missing, unsupported architecture, etc.) triggers a failure e-mail with the log attached — so the server never silently stops updating unnoticed.

### E-mail transport

The script sends all e-mails directly via `curl` using SMTP, so **no local MTA (postfix, sendmail, etc.) is required**. You configure an external SMTP relay (e.g. your provider's SMTP server or a self-hosted one) at the top of the script. It supports three TLS modes:

| Mode | What it does |
|---|---|
| `starttls` (default) | Connects on port 587, upgrades to TLS via the STARTTLS command |
| `ssl` | Connects on the given port with TLS from the start (typically port 465) |
| `none` | No encryption — only use this on trusted networks |

All recipients listed in `MAIL_RECIPIENTS` receive the same e-mail. Fatal errors and failed update attempts attach the full log file (`/var/log/stalwart/updater.log`) so you have context for debugging.

### Requirements

| Tool | Purpose |
|---|---|
| [`curl`](https://curl.se/) | Sends e-mails via SMTP and is used as a fallback for downloading |
| [`wget`](https://www.gnu.org/software/wget/) | Primary tool for downloading release archives from GitHub |
| [`jq`](https://stedolan.github.io/jq/) | Parses the JSON response from the GitHub API |
| `coreutils` | Provides the `base64` command used for e-mail attachments |
| `openrc` | Manages the Stalwart service (`rc-service`, `rc-update`) |
| root access | The script must run as root to manage the service and write to system paths |

These packages are installed automatically on Alpine if missing.

### Installation

1. Edit the SMTP configuration variables at the top of the script (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM`, `MAIL_RECIPIENTS`).
2. Place the script on your Alpine server (e.g. `/usr/local/bin/stalwart-updater-alpine.sh`).
3. Make it secure and executable:

```bash
chmod 700 /usr/local/bin/stalwart-updater-alpine.sh
```

4. (Optional) Verify your SMTP settings work by sending a test e-mail:

```bash
stalwart-updater-alpine.sh --test-mail
```

### Usage

| Command | What it does |
|---|---|
| `stalwart-updater-alpine.sh` | Run an update check/apply now (the default) |
| `stalwart-updater-alpine.sh --check-only` | Only report whether an update is available (no e-mail sent, no changes made) |
| `stalwart-updater-alpine.sh --install-cron` | Register a daily cron job at 00:00 that runs the updater automatically |
| `stalwart-updater-alpine.sh --test-mail` | Send a test e-mail to verify your SMTP configuration |

#### Setting up daily automatic updates

```bash
stalwart-updater-alpine.sh --install-cron
```

This adds a cron entry to `/etc/crontabs/root` and ensures `crond` is enabled and running. After that the updater runs every day at midnight automatically — patch updates are applied, major/minor updates trigger an e-mail instead.