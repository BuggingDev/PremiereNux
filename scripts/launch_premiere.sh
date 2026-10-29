#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 PremiereNux contributors
# Starts Adobe Premiere Pro under Wine. Logs go to $PRNUX_LOG_DIR/premiere_<time>/ (the folder name is also in
# $PRNUX_LOG_DIR/LATEST). PRNUX_WINEDEBUG=... turns Wine's debug channels on; PRNUX_RESTART=1 stops a running copy first.
#
#   launch_premiere.sh [SECONDS]    stop Premiere after SECONDS (default 0: no limit)
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"
SECS=${1:-0}

if [ -n "$(prnux_prefix_pids 'Adobe Premiere Pro[.]exe' | head -n 1)" ]; then
    if [ "${PRNUX_RESTART:-0}" = 1 ]; then
        "$WINE_BIN_DIR/wineserver" -k > /dev/null 2>&1
        sleep 2
    else
        echo "Premiere Pro already runs in this prefix. Close it, or run again with PRNUX_RESTART=1." >&2
        exit 1
    fi
fi
"$WINE_BIN_DIR/wineserver" -k > /dev/null 2>&1 || true
sleep 1
prnux_env
if [ "$(prnux_vulkan_mode)" = dzn ] && [ ! -f "$VK_ICD_FILENAMES" ]; then
    echo "dzn ICD not found: $VK_ICD_FILENAMES (run install.sh again)" >&2
    exit 1
fi
[ -f "$PP_DIR/Adobe Premiere Pro.exe" ] || { echo "Adobe Premiere Pro.exe not found in $PP_DIR" >&2; exit 1; }

LOGD="$PRNUX_LOG_DIR/premiere_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOGD"
echo "$LOGD" > "$PRNUX_LOG_DIR/LATEST"

# Sound: pick a server that answers before Wine opens its audio. Without one Premiere stops at a modal box.
if [ "${PRNUX_AUDIO_CHECK:-1}" = 1 ]; then
    prnux_audio_setup
    case "$PRNUX_AUDIO" in
        ok) echo "audio: $PRNUX_AUDIO_INFO" | tee "$LOGD/audio.log" ;;
        none)
            MSG="no sound server answers (PulseAudio, or PipeWire with pipewire-pulse): Premiere will ask about the audio hardware"
            echo "audio: $MSG" | tee "$LOGD/audio.log" >&2
            command -v notify-send > /dev/null 2>&1 && notify-send "Premiere Pro" "$MSG" 2> /dev/null
            ;;
    esac
fi

cd "$PP_DIR" || exit 1
if [ "$SECS" -gt 0 ]; then
    timeout -s TERM "$SECS" wine "Adobe Premiere Pro.exe" > "$LOGD/out.log" 2> "$LOGD/err.log" < /dev/null
else
    wine "Adobe Premiere Pro.exe" > "$LOGD/out.log" 2> "$LOGD/err.log" < /dev/null
fi
rc=$?
echo "rc=$rc" > "$LOGD/rc"
"$WINE_BIN_DIR/wineserver" -k > /dev/null 2>&1 || true
echo "log directory: $LOGD (rc=$rc)"
