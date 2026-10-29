#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 PremiereNux contributors
# The Wine environment and the package tables are derived from scripts/common.sh of NuxFX (Copyright (C) 2026 NuxFX
# contributors, GPL-3.0-or-later), which found these settings for hosts whose GPU is reached through Direct3D 12
# (dzn, DXVK, vkd3d-proton).
#
# Shared settings of the PremiereNux scripts. A value comes from the environment, else from the config file
# (~/.config/premierenux/premierenux.conf, KEY=value lines), else from the defaults below.

PRNUX_CONFIG="${PRNUX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/premierenux/premierenux.conf}"
PRNUX_CONFIG_KEYS="PRNUX_HOME WINE_BIN_DIR WINEPREFIX PP_DIR DZN_PREFIX PRNUX_GL_PREFIX PRNUX_LOG_DIR PRNUX_DISABLE_CUDA PRNUX_WINEDEBUG PRNUX_EXTRA_OVERRIDES PRNUX_VULKAN"
if [ -f "$PRNUX_CONFIG" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line=${_line%$'\r'}
        case "$_line" in *=*) ;; *) continue ;; esac
        _key=${_line%%=*}
        _value=${_line#*=}
        case " $PRNUX_CONFIG_KEYS " in *" $_key "*) ;; *) continue ;; esac
        if [ -z "${!_key+x}" ]; then export "$_key=$_value"; fi
    done < "$PRNUX_CONFIG"
    unset _line _key _value
fi

PRNUX_VERSION=0.1.0
PRNUX_SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRNUX_HOME="${PRNUX_HOME:-$HOME/.local/share/premierenux}"
WINE_BIN_DIR="${WINE_BIN_DIR:-$PRNUX_HOME/runner/bin}"
WINEPREFIX="${WINEPREFIX:-$PRNUX_HOME/wineprefix}"
PP_DIR="${PP_DIR:-$WINEPREFIX/drive_c/Program Files/Adobe/Adobe Premiere Pro 2024}"
DZN_PREFIX="${DZN_PREFIX:-$PRNUX_HOME/dzn}"
PRNUX_GL_PREFIX="${PRNUX_GL_PREFIX:-$PRNUX_HOME/mesa-gl}"
PRNUX_LOG_DIR="${PRNUX_LOG_DIR:-$PRNUX_HOME/logs}"
# Vulkan driver: auto (dzn when the GPU is reached through Direct3D 12, else the host's own driver), dzn or system
PRNUX_VULKAN="${PRNUX_VULKAN:-auto}"
export PRNUX_CONFIG PRNUX_HOME WINE_BIN_DIR WINEPREFIX PP_DIR DZN_PREFIX PRNUX_GL_PREFIX PRNUX_LOG_DIR PRNUX_VULKAN

# True when the GPU is reachable through Direct3D 12 (/dev/dxg): Vulkan then comes from Mesa's dzn and OpenGL from Mesa's
# d3d12 driver. False on a host with a native GPU driver (NVIDIA, AMD, Intel): its own Vulkan and OpenGL are used.
is_d3d12_host() { [ -e /dev/dxg ]; }

# Prints "dzn" or "system".
prnux_vulkan_mode() {
    case "$PRNUX_VULKAN" in
        dzn|system) echo "$PRNUX_VULKAN" ;;
        *) if is_d3d12_host; then echo dzn; else echo system; fi ;;
    esac
}

prnux_dzn_icd() { echo "$DZN_PREFIX/share/vulkan/icd.d/dzn_icd.x86_64.json"; }

prnux_write_dzn_icd() {
    mkdir -p "$DZN_PREFIX/share/vulkan/icd.d"
    cat > "$(prnux_dzn_icd)" <<EOF
{
    "ICD": {
        "api_version": "1.3.318",
        "library_arch": "64",
        "library_path": "$DZN_PREFIX/lib/libvulkan_dzn.so"
    },
    "file_format_version": "1.0.1"
}
EOF
}

# The environment every Wine program of this installation runs in.
prnux_env() {
    export PATH="$WINE_BIN_DIR:$PATH"
    export WINEPREFIX
    # no Mono / Gecko prompts; PRNUX_DISABLE_CUDA=1 hides the CUDA bridge from Premiere
    local overrides="mscoree,mshtml="
    # Wine's X11 driver (XWayland on a Wayland desktop) is the verified display path. Wine 11.17 takes its Wayland driver when
    # a Wayland socket exists, also with WAYLAND_DISPLAY unset, so that driver is turned off.
    [ -z "${DISPLAY:-}" ] && [ -S /tmp/.X11-unix/X0 ] && export DISPLAY=:0
    if [ -n "${DISPLAY:-}" ]; then unset WAYLAND_DISPLAY; overrides="$overrides;winewayland.drv=d"; fi
    if [ "${PRNUX_DISABLE_CUDA:-0}" = 1 ]; then
        overrides="$overrides;nvcuda,nvcuvid=d"
        case ",${DZN_DEBUG:-}," in *,nocudauuid,*) ;; *) export DZN_DEBUG="${DZN_DEBUG:+$DZN_DEBUG,}nocudauuid" ;; esac
    fi
    [ -n "${PRNUX_EXTRA_OVERRIDES:-}" ] && overrides="$overrides;$PRNUX_EXTRA_OVERRIDES"
    [ -n "${WINEDLLOVERRIDES:-}" ] && overrides="$overrides;$WINEDLLOVERRIDES"
    export WINEDLLOVERRIDES="$overrides"
    export WINEDEBUG="${WINEDEBUG:-${PRNUX_WINEDEBUG:--all}}"
    if [ "$(prnux_vulkan_mode)" = dzn ]; then
        export VK_ICD_FILENAMES="$(prnux_dzn_icd)"
        # DXVK refuses a device without storageBuffer8BitAccess; dzn reports it with this driconf option
        local drirc_dir="$DZN_PREFIX/share/drirc.d"
        if [ -d "$DZN_PREFIX" ]; then
            mkdir -p "$drirc_dir" 2> /dev/null
            if [ ! -f "$drirc_dir/50-premierenux-dzn.conf" ]; then
                cat > "$drirc_dir/50-premierenux-dzn.conf" 2> /dev/null <<'EOF'
<driconf>
    <device driver="dzn">
        <application name="Default">
            <option name="dzn_enable_8bit_loads_stores" value="true" />
        </application>
    </device>
</driconf>
EOF
            fi
            export DRIRC_CONFIGDIR="$drirc_dir"
        fi
    fi
    if is_d3d12_host; then
        # OpenGL goes through Mesa's D3D12 Gallium driver (without it llvmpipe draws on the CPU); Mesa 25.2.8's EGL is
        # first in the library path so that the distribution's Mesa does not matter
        [ -z "${GALLIUM_DRIVER:-}" ] && export GALLIUM_DRIVER=d3d12
        if [ -f "$PRNUX_GL_PREFIX/lib/libEGL.so.1" ]; then
            case ":${LD_LIBRARY_PATH:-}:" in
                *":$PRNUX_GL_PREFIX/lib:"*) ;;
                *) export LD_LIBRARY_PATH="$PRNUX_GL_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
            esac
        fi
        # Wine turns every EGL device into a GPU; naming the driver keeps the software "vgem" node out of the list
        [ -z "${MESA_LOADER_DRIVER_OVERRIDE:-}" ] && export MESA_LOADER_DRIVER_OVERRIDE=d3d12
        # glibc's memcpy uses "rep movsb" from 4 KB up, which runs at about 45 MB/s on the shared-memory mappings of this route
        case ":${GLIBC_TUNABLES:-}:" in
            *:glibc.cpu.x86_rep_movsb_threshold=*) ;;
            *) export GLIBC_TUNABLES="${GLIBC_TUNABLES:+$GLIBC_TUNABLES:}glibc.cpu.x86_rep_movsb_threshold=0x40000000" ;;
        esac
    fi
    # a PULSE_SERVER that names a socket which is not there keeps libpulse from looking at the default place
    case "${PULSE_SERVER:-}" in
        unix:*) [ -S "${PULSE_SERVER#unix:}" ] || unset PULSE_SERVER ;;
    esac
    export LANG="${LANG:-en_US.UTF-8}"
}

# PIDs of this user's processes that match the pgrep pattern $1 and run in this prefix
prnux_prefix_pids() {
    local pid
    for pid in $(pgrep -u "$(id -u)" -f "$1" 2> /dev/null); do
        if tr '\0' '\n' 2> /dev/null < "/proc/$pid/environ" | grep -qxF "WINEPREFIX=$WINEPREFIX"; then echo "$pid"; fi
    done
}

# ---------- audio ----------

# Premiere stops at a modal box "No output device is available" (its main window is dead until the box is answered) when Wine
# finds no sound output. Wine talks to a PulseAudio-protocol server (PulseAudio, or PipeWire's pipewire-pulse) or to ALSA.
# A server whose socket exists but does not answer is as bad as none, hence the time limit.

# prnux_pulse_probe SERVER: success when that server answers within 4 s and has an output. SERVER "" is libpulse's own search
# (PULSE_SERVER, the X11 property, client.conf, the default socket). The environment keeps SERVER on success.
prnux_pulse_probe() {
    if [ -n "$1" ]; then export PULSE_SERVER="$1"; else unset PULSE_SERVER; fi
    timeout 4 pactl info > /dev/null 2>&1 || return 1
    [ -n "$(timeout 4 pactl list short sinks 2> /dev/null)" ]
}

# prnux_audio_setup: looks for a sound server that answers and leaves PULSE_SERVER pointing at it (unset for libpulse's
# default one). Sets PRNUX_AUDIO to ok (a server with an output), none (nothing answers; the environment stays as it was) or
# unchecked (no pactl), and PRNUX_AUDIO_INFO to a one-line description.
prnux_audio_setup() {
    PRNUX_AUDIO=unchecked; PRNUX_AUDIO_INFO=""
    command -v pactl > /dev/null 2>&1 || return 0
    local rt=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} was="${PULSE_SERVER-}" was_set=0 cand key seen=" "
    [ -n "${PULSE_SERVER+x}" ] && was_set=1
    # as the environment has it, libpulse's own search, then the usual sockets of PulseAudio and pipewire-pulse
    for cand in "$was" "" "unix:$rt/pulse/native" "unix:/run/pulse/native"; do
        key=${cand:-default}
        case "$seen" in *" $key "*) continue ;; esac
        seen="$seen$key "
        case "$cand" in unix:*) [ -S "${cand#unix:}" ] || continue ;; esac
        if prnux_pulse_probe "$cand"; then
            PRNUX_AUDIO=ok
            PRNUX_AUDIO_INFO="$(pactl info 2> /dev/null | sed -n 's/^Server Name: //p' | head -n 1), $(pactl list short sinks 2> /dev/null | wc -l) output(s), server ${cand:-by default}"
            return 0
        fi
    done
    if [ "$was_set" = 1 ]; then export PULSE_SERVER="$was"; else unset PULSE_SERVER; fi
    PRNUX_AUDIO=none
    return 1
}

# ---------- packages ----------

# Package manager family of this distribution: apt, dnf, pacman, zypper or other.
prnux_family() {
    local family=""
    [ -r /etc/os-release ] && family=$(. /etc/os-release; echo " ${ID:-} ${ID_LIKE:-} ")
    case "$family" in
        *" debian "*|*" ubuntu "*) echo apt ;;
        *" fedora "*|*" rhel "*|*" centos "*) echo dnf ;;
        *" arch "*) echo pacman ;;
        *" suse "*|*" opensuse "*) echo zypper ;;
        *) echo other ;;
    esac
}

# Shared libraries the Wine runner opens with dlopen at run time. Wine does not stop when one is missing, it switches the
# feature off (without libXcomposite.so.1 OpenGL child windows stay black).
PRNUX_WINE_SONAMES="libX11.so.6 libXext.so.6 libXi.so.6 libXrandr.so.2 libXrender.so.1 libXfixes.so.3 libXcursor.so.1 libXcomposite.so.1 libXinerama.so.1 libXxf86vm.so.1 libxkbcommon.so.0 libxkbregistry.so.0 libfreetype.so.6 libfontconfig.so.1 libgnutls.so.30 libEGL.so.1 libGL.so.1 libpulse.so.0 libasound.so.2"
# Shared libraries the prebuilt Mesa packages link.
PRNUX_MESA_SONAMES="libdrm.so.2 libexpat.so.1 libzstd.so.1 libz.so.1 libxcb.so.1 libX11-xcb.so.1 libxcb-dri3.so.0 libxcb-present.so.0 libxcb-xfixes.so.0 libxcb-sync.so.1 libxcb-randr.so.0 libxcb-shm.so.0 libxcb-keysyms.so.1 libxshmfence.so.1 libwayland-client.so.0"

# True when the dynamic linker knows the 64-bit shared library $1 (soname).
prnux_have_lib() {
    local ld
    ld=$(command -v ldconfig 2> /dev/null || echo /sbin/ldconfig)
    "$ld" -p 2> /dev/null | grep -q "^[[:space:]]*$1 ([^)]*x86-64"
}

# prnux_libs_missing "SONAMES": prints the sonames that the dynamic linker does not know
prnux_libs_missing() {
    local s
    for s in $1; do prnux_have_lib "$s" || echo "$s"; done
}

# Prints the package that provides shared library $1 on this distribution (dnf and zypper install by the library).
prnux_soname_pkg() {
    case "$(prnux_family):$1" in
        apt:libX11.so.6) echo libx11-6 ;;
        apt:libXext.so.6) echo libxext6 ;;
        apt:libXi.so.6) echo libxi6 ;;
        apt:libXrandr.so.2) echo libxrandr2 ;;
        apt:libXrender.so.1) echo libxrender1 ;;
        apt:libXfixes.so.3) echo libxfixes3 ;;
        apt:libXcursor.so.1) echo libxcursor1 ;;
        apt:libXcomposite.so.1) echo libxcomposite1 ;;
        apt:libXinerama.so.1) echo libxinerama1 ;;
        apt:libXxf86vm.so.1) echo libxxf86vm1 ;;
        apt:libxkbcommon.so.0) echo libxkbcommon0 ;;
        apt:libxkbregistry.so.0) echo libxkbregistry0 ;;
        apt:libfreetype.so.6) echo libfreetype6 ;;
        apt:libfontconfig.so.1) echo libfontconfig1 ;;
        apt:libgnutls.so.30) echo libgnutls30 ;;
        apt:libEGL.so.1) echo libegl1 ;;
        apt:libGL.so.1) echo libgl1 ;;
        apt:libpulse.so.0) echo libpulse0 ;;
        apt:libasound.so.2) echo libasound2 ;;
        apt:libdrm.so.2) echo libdrm2 ;;
        apt:libexpat.so.1) echo libexpat1 ;;
        apt:libzstd.so.1) echo libzstd1 ;;
        apt:libz.so.1) echo zlib1g ;;
        apt:libxcb.so.1) echo libxcb1 ;;
        apt:libX11-xcb.so.1) echo libx11-xcb1 ;;
        apt:libxcb-dri3.so.0) echo libxcb-dri3-0 ;;
        apt:libxcb-present.so.0) echo libxcb-present0 ;;
        apt:libxcb-xfixes.so.0) echo libxcb-xfixes0 ;;
        apt:libxcb-sync.so.1) echo libxcb-sync1 ;;
        apt:libxcb-randr.so.0) echo libxcb-randr0 ;;
        apt:libxcb-shm.so.0) echo libxcb-shm0 ;;
        apt:libxcb-keysyms.so.1) echo libxcb-keysyms1 ;;
        apt:libxshmfence.so.1) echo libxshmfence1 ;;
        apt:libwayland-client.so.0) echo libwayland-client0 ;;
        pacman:libdrm.so.2) echo libdrm ;;
        pacman:libexpat.so.1) echo expat ;;
        pacman:libzstd.so.1) echo zstd ;;
        pacman:libz.so.1) echo zlib ;;
        pacman:libxcb.so.1|pacman:libxcb-dri3.so.0|pacman:libxcb-present.so.0|pacman:libxcb-xfixes.so.0|pacman:libxcb-sync.so.1|pacman:libxcb-randr.so.0|pacman:libxcb-shm.so.0) echo libxcb ;;
        pacman:libX11-xcb.so.1) echo libx11 ;;
        pacman:libxcb-keysyms.so.1) echo xcb-util-keysyms ;;
        pacman:libxshmfence.so.1) echo libxshmfence ;;
        pacman:libwayland-client.so.0) echo wayland ;;
        pacman:libX11.so.6) echo libx11 ;;
        pacman:libXext.so.6) echo libxext ;;
        pacman:libXi.so.6) echo libxi ;;
        pacman:libXrandr.so.2) echo libxrandr ;;
        pacman:libXrender.so.1) echo libxrender ;;
        pacman:libXfixes.so.3) echo libxfixes ;;
        pacman:libXcursor.so.1) echo libxcursor ;;
        pacman:libXcomposite.so.1) echo libxcomposite ;;
        pacman:libXinerama.so.1) echo libxinerama ;;
        pacman:libXxf86vm.so.1) echo libxxf86vm ;;
        pacman:libxkbcommon.so.0|pacman:libxkbregistry.so.0) echo libxkbcommon ;;
        pacman:libfreetype.so.6) echo freetype2 ;;
        pacman:libfontconfig.so.1) echo fontconfig ;;
        pacman:libgnutls.so.30) echo gnutls ;;
        pacman:libEGL.so.1|pacman:libGL.so.1) echo libglvnd ;;
        pacman:libpulse.so.0) echo libpulse ;;
        pacman:libasound.so.2) echo alsa-lib ;;
        dnf:*|zypper:*) echo "'$1()(64bit)'" ;;
        *) echo "$1" ;;
    esac
}

# Prints an install command for generic package names on this distribution. A name that looks like a shared library
# (libXcomposite.so.1) is turned into the package that provides it.
prnux_pkg_hint() {
    local family out p
    family=$(prnux_family)
    case "$family" in
        apt) out="sudo apt install" ;;
        dnf) out="sudo dnf install" ;;
        pacman) out="sudo pacman -S --needed" ;;
        zypper) out="sudo zypper install" ;;
        *) out="install (names may differ):" ;;
    esac
    for p in "$@"; do
        case "$p" in lib*.so.*) p=$(prnux_soname_pkg "$p") ;; esac
        case "$family:$p" in
            apt:xz) p=xz-utils ;;
            apt:awk|dnf:awk|pacman:awk|zypper:awk) p=gawk ;;
            apt:which) p=debianutils ;;
            dnf:procps|pacman:procps) p=procps-ng ;;
            apt:vulkan-loader|zypper:vulkan-loader) p=libvulkan1 ;;
            pacman:vulkan-loader) p=vulkan-icd-loader ;;
            dnf:pkg-config|pacman:pkg-config|zypper:pkg-config) p=pkgconf ;;
            pacman:pactl) p=libpulse ;;
            apt:pactl|dnf:pactl|zypper:pactl) p=pulseaudio-utils ;;
        esac
        # Debian 13 and Ubuntu 24.04 renamed libraries for the 64-bit time_t (libasound2 is a virtual package there,
        # the library is in libasound2t64): take the name that exists
        if [ "$family" = apt ] && command -v apt-cache > /dev/null 2>&1 && ! apt-cache show "$p" > /dev/null 2>&1 && apt-cache show "${p}t64" > /dev/null 2>&1; then
            p=${p}t64
        fi
        case " $out " in *" $p "*) ;; *) out="$out $p" ;; esac
    done
    echo "$out"
}

# Prints the packages of the fonts Premiere needs on this distribution, one line.
#   Adobe's text engine stops Premiere with "Initialization Failure: invalid map<K, T> key" when Wine sees no system fonts.
prnux_font_pkgs() {
    case "$(prnux_family)" in
        pacman) echo "noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation" ;;
        apt) echo "fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji fonts-dejavu-core fonts-liberation" ;;
        dnf) echo "google-noto-sans-fonts google-noto-serif-fonts google-noto-sans-cjk-fonts google-noto-color-emoji-fonts dejavu-sans-fonts liberation-fonts" ;;
        zypper) echo "noto-sans-fonts noto-sans-cjk-fonts google-noto-coloremoji-fonts dejavu-fonts liberation-fonts" ;;
        *) echo "" ;;
    esac
}
