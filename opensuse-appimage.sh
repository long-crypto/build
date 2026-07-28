#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Steam-AppImage (openSUSE Tumbleweed)
# Based on the approach by ivan-hc (Steam-appimage / ArchImage)
# =============================================================================

VERSION="0.1.0"
SCRIPT="$(basename "$0")"
BASE="${HOME}/.local/share/steam-appimage-opensuse"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
C='\033[0;36m'; B='\033[0;34m'; N='\033[0m'

info()  { echo -e "${G}[INFO]${N}  $*"; }
warn()  { echo -e "${Y}[WARN]${N}  $*" >&2; }
err()   { echo -e "${R}[ERR]${N}  $*" >&2; exit 1; }
step()  { echo -e "${C}[..]${N}  $*"; }

# =============================================================================
# Dependencies
# =============================================================================

check_host_deps() {
    local miss=()
    for d in bwrap curl tar zstd xz; do
        command -v "$d" &>/dev/null || miss+=("$d")
    done
    command -v mksquashfs &>/dev/null && export HAS_SQUASHFS=true || { export HAS_SQUASHFS=false; miss+=("mksquashfs"); }
    [ ${#miss[@]} -eq 0 ] && return 0
    err "Missing: ${miss[*]}
  Install with your package manager (e.g. apt/dnf/pacman/zypper)"
}

# =============================================================================
# Rootfs
# =============================================================================

download_rootfs() {
    local dst="$1"
    mkdir -p "$(dirname "$dst")"

    [ -f "$dst/etc/os-release" ] && { info "Rootfs already exists at $dst"; return 0; }

    step "Downloading openSUSE Tumbleweed container..."

    local url="https://download.opensuse.org/tumbleweed/appliances/opensuse-tumbleweed-container.x86_64.tar.xz"
    local tmp="$BASE/rootfs.tar"

    curl -fSL --retry 5 --connect-timeout 30 --progress-bar -o "$tmp.xz" "$url" || {
        warn "Primary URL failed, trying Docker Hub..."
        local m
        m=$(curl -fsSL \
            "https://registry.hub.docker.com/v2/library/opensuse/tumbleweed/manifests/latest" \
            -H "Accept: application/vnd.docker.distribution.manifest.v2+json" 2>/dev/null || true)
        [ -z "$m" ] && err "Cannot download openSUSE image."
        local d=$(echo "$m" | python3 -c "import sys,json; print(json.load(sys.stdin)['layers'][0]['digest'])" 2>/dev/null || \
                   echo "$m" | jq -r '.layers[0].digest')
        curl -fsSL --retry 5 -o "$tmp.gz" \
            "https://registry.hub.docker.com/v2/library/opensuse/tumbleweed/blobs/$d" || err "Download failed"
        zstd -d "$tmp.gz" -o "$tmp" 2>/dev/null || gunzip "$tmp.gz" -c > "$tmp" 2>/dev/null || err "Decompress failed"
    }

    if [ -f "$tmp.xz" ]; then
        xz -d "$tmp.xz" -c > "$tmp"
    fi

    step "Extracting rootfs..."
    rm -rf "$dst"
    mkdir -p "$dst"
    tar xf "$tmp" -C "$dst"
    rm -f "$tmp" "$tmp.xz" "$tmp.gz" "$tmp.zst"

    [ -f "$dst/etc/os-release" ] || err "Rootfs extraction failed."
    info "Rootfs: $(grep PRETTY_NAME "$dst/etc/os-release" | cut -d= -f2 | tr -d '"')"
}

# =============================================================================
# Bubblewrap sandbox
# =============================================================================

bwrap_run() {
    local rootfs="$1"
    shift
    [ ! -d "$rootfs" ] && err "Rootfs not found: $rootfs"

    cp -f /etc/resolv.conf "$rootfs/etc/resolv.conf" 2>/dev/null || true
    mkdir -p "$rootfs/proc" "$rootfs/sys" "$rootfs/dev" "$rootfs/run" "$rootfs/tmp"

    local sh="/bin/bash"
    [ -x "$rootfs/bin/bash" ] || [ -x "$rootfs/usr/bin/bash" ] || sh="/bin/sh"

    bwrap \
        --unshare-all --share-net --die-with-parent \
        --ro-bind /sys /sys \
        --proc /proc \
        --dev /dev \
        --tmpfs /tmp \
        --tmpfs /run \
        --bind "$rootfs" / \
        --setenv PATH "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        --setenv HOME /root \
        --hostname opensuse-tw \
        --cap-add ALL \
        --seccomp unconfined \
        "$sh" -c "
            cd /root
            $*
        "
}

bwrap_shell() {
    local rootfs="$1"
    local cmd="${2:-/bin/bash}"

    cp -f /etc/resolv.conf "$rootfs/etc/resolv.conf" 2>/dev/null || true
    mkdir -p "$rootfs/proc" "$rootfs/sys" "$rootfs/dev" "$rootfs/run" "$rootfs/tmp"

    local sh="/bin/bash"
    [ -x "$rootfs/bin/bash" ] || [ -x "$rootfs/usr/bin/bash" ] || sh="/bin/sh"

    exec bwrap \
        --unshare-all --share-net --die-with-parent \
        --ro-bind /sys /sys \
        --proc /proc \
        --dev /dev \
        --tmpfs /tmp \
        --tmpfs /run \
        --bind "$rootfs" / \
        --setenv PATH "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        --setenv HOME /root \
        --hostname opensuse-tw \
        --cap-add ALL \
        --seccomp unconfined \
        "$sh" -c "
            cd /root
            exec $cmd
        "
}

# =============================================================================
# Zypper helpers
# =============================================================================

zypper_install() {
    local rootfs="$1"; shift
    step "Installing: $*"
    bwrap_run "$rootfs" "
        zypper --non-interactive --no-gpg-checks refresh 2>/dev/null || true
        zypper --non-interactive --no-gpg-checks install -y $* 2>&1 | tail -5
    " || warn "Some packages may have failed to install"
}

zypper_update() {
    local rootfs="$1"
    step "Updating packages..."
    bwrap_run "$rootfs" "
        zypper --non-interactive --no-gpg-checks refresh 2>/dev/null || true
        zypper --non-interactive --no-gpg-checks update -y 2>&1 | tail -5
    " || warn "Update may be incomplete"
}

# =============================================================================
# Steam-specific package list
# =============================================================================

STEAM_CORE="steam"

STEAM_DEPS_64="
Mesa-libGL1 Mesa-libGLESv2_2 Mesa-libEGL1 Mesa-dri
Mesa-vulkan-device-select vulkan-tools libvulkan1
libpulse0 pulseaudio-utils
libudev1 libusb-1_0-0
libopenal1 libsndfile1
libcurl4 NetworkManager
libXi6 libXrandr2 libXfixes3 libXcursor1 libXinerama1
libXext6 libX11-6 libxcb1 libXrender1 libXdamage1
libXcomposite1 libXScrnSaver libXxf86vm1
libpng16-16 libjpeg8 libtiff6
freetype2 fontconfig
libvdpau1 libva2 libva-drm2 libva-glx2 libva-x11-2
pipewire-libjack libjack0 libasound2
gtk3 libpango-1_0-0 cairo
libdbus-1-3 dbus-1
libnss3 nspr
glib2 libgobject-2_0-0 libgio-2_0-0 libglib-2_0-0
ca-certificates-mozilla
"

STEAM_DEPS_32="
steam-32bit
Mesa-libGL1-32bit Mesa-libGLESv2_2-32bit Mesa-libEGL1-32bit Mesa-dri-32bit
Mesa-vulkan-device-select-32bit libvulkan1-32bit vulkan-tools-32bit
libpulse0-32bit
libudev1-32bit libusb-1_0-0-32bit
libopenal1-32bit libsndfile1-32bit
libcurl4-32bit
libXi6-32bit libXrandr2-32bit libXfixes3-32bit libXcursor1-32bit libXinerama1-32bit
libXext6-32bit libX11-6-32bit libxcb1-32bit libXrender1-32bit libXdamage1-32bit
libXcomposite1-32bit libXScrnSaver-32bit libXxf86vm1-32bit
libpng16-16-32bit libjpeg8-32bit libtiff6-32bit
freetype2-32bit fontconfig-32bit
libvdpau1-32bit libva2-32bit libva-drm2-32bit libva-glx2-32bit libva-x11-2-32bit
libasound2-32bit
gtk3-32bit libpango-1_0-0-32bit cairo-32bit
libdbus-1-3-32bit
libnss3-32bit nspr-32bit
libstdc++6-32bit libgcc_s1-32bit
glibc-32bit glib2-32bit
"

STEAM_OPTIONAL="
steamtricks mangohud gamemode
gamescope
Mesa-libGLESv3_2 Mesa-libGLESv1_CM1
libFAudio0 libFAudio0-32bit
libvkd3d1 libvkd3d1-32bit
wine
"

# =============================================================================
# Steam AppImage launcher (embedded in output)
# =============================================================================

write_steam_launcher() {
    cat << 'LAUNCHER'
#!/bin/bash
# Steam AppImage launcher (openSUSE Tumbleweed)

HERE="$(dirname "$(readlink -f "${0}")")"

export PATH="$HERE/usr/local/sbin:$HERE/usr/local/bin:$HERE/usr/sbin:$HERE/usr/bin:$HERE/sbin:$HERE/bin:$PATH"
export LD_LIBRARY_PATH="$HERE/usr/lib64:$HERE/usr/lib:$HERE/lib64:$HERE/lib:$LD_LIBRARY_PATH"
export XDG_DATA_DIRS="$HERE/usr/share:$XDG_DATA_DIRS"
export STEAM_RUNTIME="$HERE/usr/lib/steam/steam-runtime"
export STEAM_RUNTIME_HEAVY=1
export SDL_VIDEO_DRIVER=x11
export LIBGL_DRIVERS_PATH="$HERE/usr/lib64/dri:$HERE/usr/lib/dri"

# Point Steam to libraries inside the AppImage
export LD_PRELOAD="$HERE/usr/lib64/libstdc++.so.6:$HERE/usr/lib64/libgcc_s.so.1:$LD_PRELOAD"

# Ensure Vulkan layer path
export VK_LAYER_PATH="$HERE/usr/share/vulkan/explicit_layer.d:$HERE/usr/share/vulkan/implicit_layer.d:$VK_LAYER_PATH"
export VK_ICD_FILENAMES="$HERE/usr/share/vulkan/icd.d:$VK_ICD_FILENAMES"

# MangoHud
[ -x "$HERE/usr/bin/mangohud" ] && export MANGOHUD=1

# Gamemode
[ -x "$HERE/usr/bin/gamemoderun" ] && alias gamemoderun="$HERE/usr/bin/gamemoderun"

if command -v bubblewrap &>/dev/null; then
    exec bwrap \
        --unshare-ipc \
        --share-net \
        --die-with-parent \
        --ro-bind /sys /sys \
        --proc /proc \
        --dev /dev \
        --tmpfs /tmp \
        --tmpfs /run \
        --bind "$HERE" / \
        --bind /home /home \
        --bind-try /mnt /mnt \
        --bind-try /media /media \
        --bind-try /run/media /run/media \
        --bind-try /tmp/.X11-unix /tmp/.X11-unix \
        --bind-try /tmp/.X11-unix /tmp/.X11-unix \
        --bind-try /run/user /run/user \
        --bind-try /run/dbus /run/dbus \
        --dev-bind-try /dev/dri /dev/dri \
        --dev-bind-try /dev/nvidia0 /dev/nvidia0 \
        --dev-bind-try /dev/nvidiactl /dev/nvidiactl \
        --dev-bind-try /dev/nvidia-modeset /dev/nvidia-modeset \
        --dev-bind-try /dev/nvidia-uvm /dev/nvidia-uvm \
        --dev-bind-try /dev/nvidia-uvm-tools /dev/nvidia-uvm-tools \
        --ro-bind /etc/resolv.conf /etc/resolv.conf \
        --ro-bind-try /etc/localtime /etc/localtime \
        --ro-bind-try /etc/machine-id /etc/machine-id \
        --setenv PATH "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        --setenv HOME "$HOME" \
        --hostname steam-opensuse \
        --chdir "$HOME" \
        --unsetenv container \
        /usr/bin/steam "$@"
else
    echo "WARNING: bubblewrap not found, running without sandbox."
    export APPDIR="$HERE"
    export APPIMAGE="$0"
    cd "$HOME"
    exec "$HERE/usr/bin/steam" "$@"
fi
LAUNCHER
}

write_squashfs_runtime() {
    cat << 'RUNTIME'
#!/usr/bin/env bash
# SquashFS AppImage runtime
HERE="$(dirname "$(readlink -f "${0}")")"
MNT="${TMPDIR:-/tmp}/.steam-appimage-$$"
cleanup() { fusermount -u "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null; }
trap cleanup EXIT
mkdir -p "$MNT"

OFFSET=$(awk '/^__END_RUNTIME__$/ {print NR+1; exit}' "$0")

if command -v squashfuse &>/dev/null; then
    tail -n +"$OFFSET" "$0" | squashfuse "$MNT" -o ro,allow_other
elif command -v unsquashfs &>/dev/null; then
    tail -n +"$OFFSET" "$0" > "$MNT.squashfs"
    unsquashfs -d "$MNT" -f "$MNT.squashfs"
    rm -f "$MNT.squashfs"
else
    echo "ERROR: squashfuse or unsquashfs required to run this AppImage." >&2
    exit 1
fi

exec "$MNT/AppRun" "$@"
__END_RUNTIME__
RUNTIME
}

# =============================================================================
# Build
# =============================================================================

build_steam() {
    local rootfs="$1"
    local output="${2:-./Steam-opensuse-TW-x86_64.AppImage}"

    [ ! -d "$rootfs" ] && err "Rootfs not found. Run 'setup' first."

    step "Building Steam AppImage..."

    local bdir="$BASE/build"
    rm -rf "$bdir"
    mkdir -p "$bdir/AppDir"

    info "Copying rootfs (this may take a while)..."
    cp -a "$rootfs"/. "$bdir/AppDir/"

    # Write AppRun (Steam launcher)
    write_steam_launcher > "$bdir/AppDir/AppRun"
    chmod +x "$bdir/AppDir/AppRun"

    # .desktop file
    cat > "$bdir/AppDir/steam.desktop" << 'EOF'
[Desktop Entry]
Name=Steam (openSUSE Tumbleweed)
Comment=Application for managing and playing games on Steam
Exec=AppRun
Icon=steam
Terminal=false
Type=Application
Categories=Game;
EOF

    # Symlink for AppImage spec
    ln -sf AppRun "$bdir/AppDir/steam" 2>/dev/null || true

    # Try to copy Steam icons
    for sz in 16 24 32 48 64 128 256; do
        if [ -f "$bdir/AppDir/usr/share/icons/hicolor/${sz}x${sz}/apps/steam.png" ]; then
            cp "$bdir/AppDir/usr/share/icons/hicolor/${sz}x${sz}/apps/steam.png" \
               "$bdir/AppDir/steam.png" 2>/dev/null && break
        fi
    done
    [ -f "$bdir/AppDir/steam.png" ] || touch "$bdir/AppDir/steam.png"

    # Build
    step "Packaging..."

    if [ "${HAS_SQUASHFS:-false}" = true ]; then
        if command -v appimagetool &>/dev/null; then
            ARCH=x86_64 appimagetool "$bdir/AppDir" "$output" 2>/dev/null || {
                info "appimagetool failed, using mksquashfs..."
                mksquashfs "$bdir/AppDir" "$bdir/fs.squashfs" -comp zstd -Xcompression-level 19 -noappend
                write_squashfs_runtime > "$output"
                chmod +x "$output"
                cat "$bdir/fs.squashfs" >> "$output"
                rm -f "$bdir/fs.squashfs"
            }
        else
            mksquashfs "$bdir/AppDir" "$bdir/fs.squashfs" -comp zstd -Xcompression-level 19 -noappend
            write_squashfs_runtime > "$output"
            chmod +x "$output"
            cat "$bdir/fs.squashfs" >> "$output"
            rm -f "$bdir/fs.squashfs"
        fi
    else
        warn "No mksquashfs, creating self-extracting tar..."
        {
            echo '#!/bin/bash'
            echo 'D="$(mktemp -d)"'
            echo 'trap "rm -rf $D" EXIT'
            echo 'mkdir -p "$D"'
            echo 'ARCHIVE_START=$(awk "/^__ARCHIVE__$/ {print NR+1; exit}" "$0")'
            echo 'tail -n +$ARCHIVE_START "$0" | tar xJ -C "$D"'
            echo 'exec "$D/AppRun" "$@"'
            echo '__ARCHIVE__'
            tar cJ -C "$bdir/AppDir" .
        } > "$output"
        chmod +x "$output"
    fi

    rm -rf "$bdir"
    echo ""
    info "Done: $output"
    ls -lh "$output"
    echo ""
    echo -e "  Run: ${G}./$output${N}"
}

# =============================================================================
# Setup: download rootfs + install Steam + all deps
# =============================================================================

setup_steam() {
    check_host_deps
    local rootfs="$BASE/rootfs"

    download_rootfs "$rootfs"

    step "Bootstrapping base system..."
    bwrap_run "$rootfs" "
        zypper --non-interactive --no-gpg-checks refresh 2>/dev/null || true
        zypper --non-interactive --no-gpg-checks install -y \
            bash coreutils filesystem glibc glibc-locale-base \
            shadow util-linux systemd-sysvinit 2>/dev/null || true
    " || true

    step "Installing Steam core package..."
    zypper_install "$rootfs" "$STEAM_CORE"

    step "Installing 64-bit dependencies..."
    zypper_install "$rootfs" "$STEAM_DEPS_64"

    step "Installing 32-bit dependencies..."
    zypper_install "$rootfs" "$STEAM_DEPS_32"

    step "Installing optional packages (MangoHud, GameMode, etc.)..."
    zypper_install "$rootfs" "$STEAM_OPTIONAL" || true

    echo ""
    info "Steam setup complete!"
    info "Run: $SCRIPT build [output-path]"
}

# =============================================================================
# CLI
# =============================================================================

usage() {
    cat << EOF
${SCRIPT} v${VERSION} - Steam AppImage from openSUSE Tumbleweed

USAGE:
  ${SCRIPT} setup              Download rootfs + install Steam + all deps
  ${SCRIPT} build [output]     Build Steam AppImage (default: ./Steam-opensuse-TW-x86_64.AppImage)
  ${SCRIPT} enter              Enter openSUSE sandbox (interactive shell)
  ${SCRIPT} shell <cmd>        Run a command inside the sandbox
  ${SCRIPT} update             zypper update all packages
  ${SCRIPT} clean              Remove rootfs and all data

EXAMPLES:
  # First time
  ${SCRIPT} setup
  ${SCRIPT} build

  # Custom output path
  ${SCRIPT} build ./my-steam.AppImage

  # Rebuild after updating
  ${SCRIPT} update
  ${SCRIPT} build

  # Run the result
  ./Steam-opensuse-TW-x86_64.AppImage
EOF
}

main() {
    local cmd="${1:-}"
    shift 2>/dev/null || true

    case "$cmd" in
        setup)
            setup_steam
            ;;
        build)
            local rootfs="$BASE/rootfs"
            check_host_deps
            download_rootfs "$rootfs"
            build_steam "$rootfs" "${1:-./Steam-opensuse-TW-x86_64.AppImage}"
            ;;
        enter)
            check_host_deps
            download_rootfs "$BASE/rootfs"
            bwrap_shell "$BASE/rootfs" "/bin/bash"
            ;;
        shell)
            check_host_deps
            download_rootfs "$BASE/rootfs"
            [ $# -eq 0 ] && err "usage: $SCRIPT shell <command>"
            bwrap_run "$BASE/rootfs" "$*"
            ;;
        update)
            check_host_deps
            download_rootfs "$BASE/rootfs"
            zypper_update "$BASE/rootfs"
            ;;
        clean)
            warn "Removing $BASE"
            rm -rf "$BASE"
            info "Cleaned."
            ;;
        --version|-v)
            echo "Steam-AppImage (openSUSE Tumbleweed) v${VERSION}"
            ;;
        --help|-h|"")
            usage
            ;;
        *)
            err "Unknown: $cmd"; usage; exit 1
            ;;
    esac
}

main "$@"
