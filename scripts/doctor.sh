#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 PremiereNux contributors
# Prints what is needed to understand a problem: the installation, Wine, the graphics route, sound, fonts and the last run.
# Changes nothing. Paste the output into a bug report.
#
#   doctor.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"
if [ -t 1 ]; then G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'; else G=""; Y=""; N=""; fi
ok()   { printf '  %sok%s    %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s     %s\n' "$Y" "$N" "$*"; }
sec()  { printf '\n== %s ==\n' "$*"; }

sec "PremiereNux $PRNUX_VERSION"
printf '  host:     %s, kernel %s\n' "$( . /etc/os-release 2> /dev/null; echo "${PRETTY_NAME:-Linux}")" "$(uname -r)"
printf '  install:  %s\n  settings: %s%s\n' "$PRNUX_HOME" "$PRNUX_CONFIG" "$([ -f "$PRNUX_CONFIG" ] || echo ' (missing)')"

sec "Wine"
if [ -x "$WINE_BIN_DIR/wine" ]; then ok "runner: $("$WINE_BIN_DIR/wine" --version 2> /dev/null)"; else warn "no runner in $WINE_BIN_DIR (run install.sh)"; fi
if [ -f "$WINEPREFIX/system.reg" ]; then ok "prefix: $WINEPREFIX"; else warn "no prefix in $WINEPREFIX"; fi
[ -f "$WINEPREFIX/drive_c/windows/system32/premierenux_json.dll" ] && ok "JSON shim installed" || warn "JSON shim missing: Premiere shows empty windows"

sec "Premiere Pro"
if [ -f "$PP_DIR/Adobe Premiere Pro.exe" ]; then
    ok "$PP_DIR (version $(sed -n 's/.*<Data key="ProductVersion">\([0-9][0-9.]*\).*/\1/p' "$PP_DIR/AMT/application.xml" 2> /dev/null | head -n 1))"
else
    warn "Adobe Premiere Pro.exe not found in $PP_DIR"
fi

sec "Graphics"
printf '  route:    %s\n' "$(prnux_vulkan_mode) ($(is_d3d12_host && echo 'GPU through Direct3D 12' || echo "the host's own driver"))"
printf '  display:  %s\n' "${DISPLAY:-none} ${WAYLAND_DISPLAY:+(Wayland session: $WAYLAND_DISPLAY, Wine runs on XWayland)}"
if [ "${PRNUX_DISABLE_CUDA:-0}" = 1 ]; then ok "CUDA bridge hidden: software rendering (the default; the GPU renderer leaves the Program monitor blank)"
else warn "CUDA bridge visible: Premiere may pick the GPU renderer, and the Program monitor can stay blank"; fi
if command -v vulkaninfo > /dev/null 2>&1; then
    ( prnux_env; vulkaninfo --summary 2> /dev/null | sed -n 's/^[[:space:]]*deviceName[[:space:]]*=[[:space:]]*/  vulkan:   /p' | sort -u | head -n 4 )
else
    warn "vulkaninfo not installed (vulkan-tools): the Vulkan device was not listed"
fi

sec "Sound"
prnux_audio_setup
case "$PRNUX_AUDIO" in
    ok) ok "sound server answers: $PRNUX_AUDIO_INFO" ;;
    none) warn "no sound server answers (PulseAudio, or PipeWire with pipewire-pulse): Premiere stops at 'No output device is available'" ;;
    *) warn "pactl is not installed, so the sound server cannot be checked ($(prnux_pkg_hint pactl))" ;;
esac

sec "Fonts"
NFONT=$(fc-list 2> /dev/null | wc -l)
if [ "$NFONT" -gt 100 ]; then ok "$NFONT fonts visible"; else warn "only $NFONT fonts visible: Premiere stops with 'Initialization Failure' (install Noto, DejaVu, Liberation)"; fi

sec "Last run"
LAST=$(cat "$PRNUX_LOG_DIR/LATEST" 2> /dev/null)
if [ -n "$LAST" ] && [ -d "$LAST" ]; then
    printf '  log:      %s (%s)\n' "$LAST" "$(cat "$LAST/rc" 2> /dev/null || echo 'still running or killed')"
    [ -f "$LAST/audio.log" ] && printf '  audio:    %s\n' "$(sed 's/^audio: //' "$LAST/audio.log" | head -n 1)"
    for pat in 'Initialization Failure' 'c0000005' 'invalid map' 'E_NOINTERFACE'; do
        n=$(grep -ac "$pat" "$LAST/err.log" 2> /dev/null || true)
        [ "${n:-0}" -gt 0 ] && warn "err.log mentions '$pat' $n time(s)"
    done
else
    printf '  no run yet\n'
fi
