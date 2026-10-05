#!/usr/bin/env bash
# toggle-monitors-kde.sh - monitor toggling for KDE Plasma (Wayland) via kscreen-doctor
#
# Usage:
#   toggle-monitors-kde.sh movie          toggle movie mode (only main monitor on / all back on)
#   toggle-monitors-kde.sh movie on|off   force movie mode on/off ("off" = all monitors back on)
#   toggle-monitors-kde.sh 1              toggle monitor 1 (2, 3, ... likewise)
#
# Monitor numbers are the IDs shown by `kscreen-doctor -o` ("Output: 1 DP-1 ...").
# The main monitor for movie mode is the one with priority 1 in Plasma.
# Override with: MAIN=DP-1 toggle-monitors-kde.sh movie

set -euo pipefail

command -v kscreen-doctor >/dev/null || { echo "kscreen-doctor not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found (install it with your package manager)"; exit 1; }

# Lines of: <id> <name> <enabled 0/1> <priority>
mapfile -t OUTPUTS < <(kscreen-doctor -j | jq -r '
    .outputs[]
    | select(.connected != false)
    | "\(.id) \(.name) \(if .enabled then 1 else 0 end) \(.priority // 0)"
')

usage() {
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

# ---------- movie mode ----------
movie_mode() {
    local want="${1:-toggle}" main="${MAIN:-}" id name enabled prio
    local others=() any_off=0

    if [[ -z "$main" ]]; then
        for line in "${OUTPUTS[@]}"; do
            read -r id name enabled prio <<<"$line"
            if [[ "$enabled" == 1 && "$prio" == 1 ]]; then main="$name"; break; fi
        done
    fi
    [[ -n "$main" ]] || { echo "Could not detect main monitor. Run with MAIN=<name>."; exit 1; }

    for line in "${OUTPUTS[@]}"; do
        read -r id name enabled prio <<<"$line"
        [[ "$name" == "$main" ]] && continue
        others+=("$name")
        [[ "$enabled" == 0 ]] && any_off=1
    done
    [[ ${#others[@]} -gt 0 ]] || { echo "No secondary monitors found."; exit 0; }

    if [[ "$want" == "toggle" ]]; then
        if [[ "$any_off" == 1 ]]; then want=off; else want=on; fi
    fi

    local args=() o
    case "$want" in
        on)  for o in "${others[@]}"; do args+=("output.$o.disable"); done
             echo "Movie mode ON: only $main stays active" ;;
        off) for o in "${others[@]}"; do args+=("output.$o.enable"); done
             echo "Movie mode OFF: enabling ${others[*]}" ;;
        *)   usage ;;
    esac
    kscreen-doctor "${args[@]}"
}

# ---------- single monitor ----------
toggle_single() {
    local target="$1" id name enabled prio
    local target_name="" target_enabled="" enabled_count=0

    for line in "${OUTPUTS[@]}"; do
        read -r id name enabled prio <<<"$line"
        [[ "$enabled" == 1 ]] && enabled_count=$((enabled_count + 1))
        if [[ "$id" == "$target" ]]; then target_name="$name"; target_enabled="$enabled"; fi
    done

    [[ -n "$target_name" ]] || { echo "No connected monitor with ID $target (check 'kscreen-doctor -o')."; exit 1; }

    if [[ "$target_enabled" == 1 ]]; then
        # Never switch off the last active screen
        if [[ "$enabled_count" -le 1 ]]; then
            echo "Refusing to disable $target_name: it's the only active monitor."
            exit 1
        fi
        echo "Disabling monitor $target ($target_name)"
        kscreen-doctor "output.$target_name.disable"
    else
        echo "Enabling monitor $target ($target_name)"
        kscreen-doctor "output.$target_name.enable"
    fi
}

# ---------- dispatch ----------
case "${1:-}" in
    movie)      movie_mode "${2:-toggle}" ;;
    ''|-h|--help) usage ;;
    *[!0-9]*)   usage ;;
    *)          toggle_single "$1" ;;
esac