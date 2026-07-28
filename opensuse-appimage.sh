#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# openSUSE-AppImage - Create portable AppImages from openSUSE Tumbleweed
# Based on the approach by ivan-hc (Steam-appimage / ArchImage)
# =============================================================================

VERSION="0.1.0"
SCRIPT_NAME="$(basename "$0")"
BASE_DIR="${HOME}/.local/share/opensuse-appimage"
OPENED="opensuse-tumbleweed-container"

# ---- Colors ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
banner(){ echo -e "${BLUE}$*${NC}"; }

# =============================================================================
# Dependencies
# =============================================================================

check_deps() {
    local missing=()
    for dep in bubblewrap curl zypper tar jq; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    if command -v mksquashfs &>/dev/null; then
        HAS_SQUASHFS=true
    else
        HAS_SQUASHFS=false
        missing+=("squashfs-tools (mksquashfs)")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing dependencies: ${missing[*]}"
        echo "  openSUSE: sudo zypper in bubblewrap curl zypper tar jq squashfs"
        echo "  Debian:   sudo apt install bubblewrap curl tar jq squashfs-tools"
        echo "  Fedora:   sudo dnf install bubblewrap curl tar jq squashfs-tools"
        echo "  Arch:     sudo pacman -S bubblewrap curl tar jq squashfs-tools"
        return 1
    fi
}

# =============================================================================
# Container Rootfs Management
# =============================================================================

# Download openSUSE Tumbleweed container image and extract rootfs
setup_rootfs() {
    local target="$1"
    local workdir="$2"

    mkdir -p "$workdir"

    if [ -d "$target" ] && [ -f "$target/etc/os-release" ]; then
        info "Rootfs already exists at $target"
        return 0
    fi

    step "Downloading openSUSE Tumbleweed container image..."

    local tmp_rootfs="$workdir/rootfs.tar"
    local image_url="https://download.opensuse.org/tumbleweed/appliances/opensuse-tumbleweed-container.x86_64.tar.xz"

    # Try multiple sources
    if ! curl -fSL --retry 3 --connect-timeout 30 -o "$tmp_rootfs.xz" "$image_url" 2>/dev/null; then
        # Fallback: use Docker hub image
        local docker_url="https://registry.hub.docker.com/v2/library/opensuse/tumbleweed/manifests/latest"
        warn "Primary source failed, trying alternative..."
        local manifest
        manifest=$(curl -fsSL "$docker_url" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" 2>/dev/null || true)
        if [ -n "$manifest" ]; then
            local digest=$(echo "$manifest" | jq -r '.layers[0].digest')
            local layer_url="https://registry.hub.docker.com/v2/library/opensuse/tumbleweed/blobs/$digest"
            curl -fsSL --retry 3 -o "$tmp_rootfs.gz" "$layer_url" || {
                err "Failed to download openSUSE image. Please try again later."
                rm -f "$tmp_rootfs.xz" "$tmp_rootfs.gz"
                return 1
            }
            mv "$tmp_rootfs.gz" "$tmp_rootfs"
        else
            err "Failed to download openSUSE image from all sources."
            rm -f "$tmp_rootfs.xz"
            return 1
        fi
    else
        mv "$tmp_rootfs.xz" "$tmp_rootfs.xz_final"
        xz -d "$tmp_rootfs.xz_final" 2>/dev/null || {
            # it might already be decompressed, try tar directly
            mv "$tmp_rootfs.xz_final" "$tmp_rootfs"
            # Check if it's a tar
            if ! tar tf "$tmp_rootfs" &>/dev/null; then
                warn "Uncompressing with xz..."
                xz -d -c "$tmp_rootfs.xz_final" > "$tmp_rootfs" 2>/dev/null || true
            fi
        }
        [ -f "$tmp_rootfs" ] || mv "$tmp_rootfs.xz_final" "$tmp_rootfs"
    fi

    step "Extracting rootfs to $target..."
    mkdir -p "$target"

    # Extract (handle both .tar and .tar.gz)
    if file "$tmp_rootfs" | grep -q gzip; then
        tar xzf "$tmp_rootfs" -C "$target"
    else
        tar xf "$tmp_rootfs" -C "$target"
    fi

    rm -f "$tmp_rootfs"*

    # Verify
    if [ -f "$target/etc/os-release" ]; then
        info "Rootfs ready: $(grep PRETTY_NAME "$target/etc/os-release" | cut -d= -f2 | tr -d '"')"
    else
        err "Rootfs extraction failed"
        return 1
    fi
}

# Create a writable overlay for the read-only rootfs
create_overlay() {
    local base="$1"
    local work="$2"
    local upper="$2/upper"
    local ov_work="$2/workdir"
    local merged="$2/merged"

    mkdir -p "$upper" "$ov_work" "$merged"
    echo "$merged"
}

# =============================================================================
# Bubblewrap Sandbox
# =============================================================================

# Enter the openSUSE environment using bubblewrap
enter_sandbox() {
    local rootfs="$1"
    shift
    local cmd="${*:-/bin/bash}"

    if [ ! -d "$rootfs" ]; then
        err "Rootfs not found: $rootfs"
        return 1
    fi

    # Sync resolv.conf for networking
    cp -f /etc/resolv.conf "$rootfs/etc/resolv.conf" 2>/dev/null || true

    # Find a working shell in the rootfs
    local shell="/bin/bash"
    [ -x "$rootfs/bin/bash" ] || [ -x "$rootfs/usr/bin/bash" ] || shell="/bin/sh"

    # Create necessary mount points
    mkdir -p "$rootfs/proc" "$rootfs/sys" "$rootfs/dev" "$rootfs/run" "$rootfs/tmp"

    exec bwrap \
        --unshare-all \
        --share-net \
        --die-with-parent \
        --ro-bind /sys /sys \
        --proc /proc \
        --dev /dev \
        --tmpfs /tmp \
        --tmpfs /run \
        --bind "$rootfs" / \
        --setenv PATH "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        --setenv HOME /root \
        --setenv container docker \
        --hostname opensuse-tumbleweed \
        --cap-add ALL \
        --seccomp unconfined \
        ${shell} -c "
            cd /root
            exec ${cmd}
        "
}

# Run a command non-interactively in the sandbox and return
run_in_sandbox() {
    local rootfs="$1"
    shift
    local cmd="$*"

    if [ ! -d "$rootfs" ]; then
        err "Rootfs not found: $rootfs"
        return 1
    fi

    cp -f /etc/resolv.conf "$rootfs/etc/resolv.conf" 2>/dev/null || true
    mkdir -p "$rootfs/proc" "$rootfs/sys" "$rootfs/dev" "$rootfs/run" "$rootfs/tmp"

    local shell="/bin/bash"
    [ -x "$rootfs/bin/bash" ] || [ -x "$rootfs/usr/bin/bash" ] || shell="/bin/sh"

    bwrap \
        --unshare-all \
        --share-net \
        --die-with-parent \
        --ro-bind /sys /sys \
        --proc /proc \
        --dev /dev \
        --tmpfs /tmp \
        --tmpfs /run \
        --bind "$rootfs" / \
        --setenv PATH "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        --setenv HOME /root \
        --setenv container docker \
        --hostname opensuse-tumbleweed \
        --cap-add ALL \
        --seccomp unconfined \
        ${shell} -c "
            cd /root
            ${cmd}
        "

    [ -f "$rootfs/etc/resolv.conf.bak" ] && mv "$rootfs/etc/resolv.conf.bak" "$rootfs/etc/resolv.conf" 2>/dev/null || true
}

# =============================================================================
# Zypper Package Management (inside sandbox)
# =============================================================================

# Install packages into the rootfs
install_packages() {
    local rootfs="$1"
    shift
    local packages="$*"

    step "Installing packages: $packages"

    cmd='
        zypper --non-interactive --no-gpg-checks refresh 2>/dev/null || true
        zypper --non-interactive --no-gpg-checks install '"$packages"'
    '

    run_in_sandbox "$rootfs" "$cmd"
}

# Update the rootfs (sync with Tumbleweed latest)
update_rootfs() {
    local rootfs="$1"

    step "Updating openSUSE Tumbleweed packages..."

    cmd='
        zypper --non-interactive --no-gpg-checks refresh 2>/dev/null || true
        zypper --non-interactive --no-gpg-checks update 2>/dev/null || true
    '

    run_in_sandbox "$rootfs" "$cmd"
}

# =============================================================================
# AppImage Builder
# =============================================================================

build_appimage() {
    local rootfs="$1"
    local app_name="$2"
    local output="$3"
    local entrypoint="${4:-"$app_name"}"

    if [ ! -d "$rootfs" ]; then
        err "Rootfs not found: $rootfs"
        return 1
    fi

    step "Building AppImage: $app_name"

    local build_dir="$BASE_DIR/build/$app_name"
    rm -rf "$build_dir"
    mkdir -p "$build_dir/AppDir"

    # Copy rootfs into AppDir
    info "Copying rootfs..."
    cp -a "$rootfs"/. "$build_dir/AppDir/"

    # Create AppRun
    cat > "$build_dir/AppDir/AppRun" << 'APPRUNEOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
export PATH="$HERE/usr/local/sbin:$HERE/usr/local/bin:$HERE/usr/sbin:$HERE/usr/bin:$HERE/sbin:$HERE/bin:$PATH"
export LD_LIBRARY_PATH="$HERE/usr/lib64:$HERE/usr/lib:$HERE/lib64:$HERE/lib:$LD_LIBRARY_PATH"
export XDG_DATA_DIRS="$HERE/usr/share:$XDG_DATA_DIRS"

if command -v bubblewrap &>/dev/null; then
    exec bwrap \
        --unshare-all \
        --share-net \
        --die-with-parent \
        --ro-bind /sys /sys \
        --proc /proc \
        --dev /dev \
        --tmpfs /tmp \
        --tmpfs /run \
        --bind "$HERE" / \
        --ro-bind /home /home \
        --ro-bind-try /mnt /mnt \
        --ro-bind-try /media /media \
        --ro-bind-try /run/media /run/media \
        --ro-bind-try /tmp /real-tmp \
        --bind-try /tmp/.X11-unix /tmp/.X11-unix \
        --bind-try /run/user /run/user \
        --bind-try /run/dbus /run/dbus \
        --ro-bind /etc/resolv.conf /etc/resolv.conf \
        --ro-bind-try /etc/localtime /etc/localtime \
        --setenv PATH "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        --setenv HOME "$HOME" \
        --hostname opensuse-appimage \
        --chdir "$HOME" \
        --unsetenv container \
        /bin/sh -c "
            cd \"$HOME\"
            exec %ENTRYPOINT% \"\$@\"
        " -- "$@"
else
    warn "bubblewrap not found on host, falling back to direct execution"
    export APPDIR="$HERE"
    export APPIMAGE="$0"
    cd "$HOME"
    exec "$HERE/usr/bin/%ENTRYPOINT%" "$@"
fi
APPRUNEOF
    chmod +x "$build_dir/AppDir/AppRun"

    # Replace placeholder
    sed -i "s|%ENTRYPOINT%|$entrypoint|g" "$build_dir/AppDir/AppRun"

    # Create .desktop file
    cat > "$build_dir/AppDir/${app_name}.desktop" << DESKEOF
[Desktop Entry]
Name=$app_name
Exec=$app_name
Type=Application
Categories=Utility;
DESKEOF

    # Copy icon if exists, otherwise create default
    local icon_path="$build_dir/AppDir/${app_name}.png"
    if [ ! -f "$icon_path" ]; then
        # Create a 1-pixel PNG as placeholder
        printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82' > "$icon_path" 2>/dev/null || true
    fi

    # Symlink for AppImage tooling
    ln -sf AppRun "$build_dir/AppDir/$app_name" 2>/dev/null || true

    # Build AppImage
    step "Creating AppImage..."

    if [ "$HAS_SQUASHFS" = true ]; then
        # Use appimagetool or mksquashfs directly
        if command -v appimagetool &>/dev/null; then
            ARCH=x86_64 appimagetool "$build_dir/AppDir" "$output" 2>/dev/null || {
                # Fallback: manual squashfs + runtime
                info "appimagetool failed, using manual method..."
                mksquashfs "$build_dir/AppDir" "$build_dir/fs.squashfs" -comp xz -b 1048576 -Xdict-size 100% -noappend 2>/dev/null
                cat_runtime > "$output"
                chmod +x "$output"
                # Append squashfs to runtime
            }
        else
            # Manual AppImage creation with mksquashfs
            mksquashfs "$build_dir/AppDir" "$build_dir/fs.squashfs" -comp xz -b 1048576 -Xdict-size 100% -noappend 2>/dev/null
            cat_runtime > "$output"
            chmod +x "$output"
            cat "$build_dir/fs.squashfs" >> "$output"
            rm -f "$build_dir/fs.squashfs"
        fi
    else
        # No squashfs: create a self-extracting tar.gz AppImage
        warn "squashfs-tools not available, creating self-extracting tar.gz..."
        {
            echo '#!/bin/bash'
            echo 'HERE="$(dirname "$(readlink -f "${0}")")"'
            echo 'EXTRACT_DIR="${TMPDIR:-/tmp}/.opensuse-appimage-$$"'
            echo 'mkdir -p "$EXTRACT_DIR"'
            echo 'ARCHIVE_START=$(awk "/^__ARCHIVE_BELOW__$/ {print NR+1; exit}" "$0")'
            echo 'tail -n +$ARCHIVE_START "$0" | tar xJ -C "$EXTRACT_DIR"'
            echo 'exec "$EXTRACT_DIR/AppRun" "$@"'
            echo 'exit'
            echo '__ARCHIVE_BELOW__'
            tar cJ -C "$build_dir/AppDir" .
        } > "$output"
        chmod +x "$output"
    fi

    rm -rf "$build_dir"
    info "AppImage created: $output"
    ls -lh "$output"
}

cat_runtime() {
    cat << 'RUNTIMEEOF'
#!/usr/bin/env bash
# AppImage Runtime for openSUSE
HERE="$(dirname "$(readlink -f "${0}")")"
APPDIR="${TMPDIR:-/tmp}/.mount_$(basename "$0")_$$"

cleanup() { fusermount -u "$APPDIR" 2>/dev/null; rmdir "$APPDIR" 2>/dev/null; }
trap cleanup EXIT

mkdir -p "$APPDIR"
OFFSET=$(awk '/^__END_RUNTIME__$/ {print NR+1; exit}' "$0")

# Try squashfuse first
if command -v squashfuse &>/dev/null; then
    tail -n +"$OFFSET" "$0" | squashfuse "$APPDIR" -o ro,allow_other 2>/dev/null || {
        # Fallback to extracting
        tail -n +"$OFFSET" "$0" | unsquashfs -d "$APPDIR" -f - 2>/dev/null
    }
elif command -v unsquashfs &>/dev/null; then
    tail -n +"$OFFSET" "$0" | unsquashfs -d "$APPDIR" -f -
else
    warn "Neither squashfuse nor unsquashfs found. Cannot run."
    exit 1
fi

export PATH="$APPDIR/usr/local/sbin:$APPDIR/usr/local/bin:$APPDIR/usr/sbin:$APPDIR/usr/bin:$APPDIR/sbin:$APPDIR/bin:$PATH"
export LD_LIBRARY_PATH="$APPDIR/usr/lib64:$APPDIR/usr/lib:$APPDIR/lib64:$APPDIR/lib:$LD_LIBRARY_PATH"
export XDG_DATA_DIRS="$APPDIR/usr/share:$XDG_DATA_DIRS"

if command -v bubblewrap &>/dev/null; then
    exec bwrap \
        --unshare-all \
        --share-net \
        --die-with-parent \
        --ro-bind /sys /sys \
        --proc /proc \
        --dev /dev \
        --tmpfs /tmp \
        --tmpfs /run \
        --bind "$APPDIR" / \
        --ro-bind /home /home \
        --ro-bind-try /mnt /mnt \
        --ro-bind-try /media /media \
        --ro-bind-try /run/media /run/media \
        --bind-try /tmp/.X11-unix /tmp/.X11-unix \
        --bind-try /run/user /run/user \
        --bind-try /run/dbus /run/dbus \
        --ro-bind /etc/resolv.conf /etc/resolv.conf \
        --ro-bind-try /etc/localtime /etc/localtime \
        --setenv PATH "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        --setenv HOME "$HOME" \
        --hostname opensuse-appimage \
        --chdir "$HOME" \
        /AppRun.real "$@"
else
    exec "$APPDIR/AppRun.real" "$@"
fi
__END_RUNTIME__
RUNTIMEEOF
}

# =============================================================================
# Helper: List packages installed in rootfs
# =============================================================================

list_packages() {
    local rootfs="$1"
    run_in_sandbox "$rootfs" "zypper search -i 2>/dev/null || rpm -qa"
}

# =============================================================================
# Main CLI
# =============================================================================

usage() {
    cat << EOF
${SCRIPT_NAME} - Create portable AppImages from openSUSE Tumbleweed

USAGE:
  ${SCRIPT_NAME} install <pkg1> [pkg2 ...]  Install packages into the container
  ${SCRIPT_NAME} build <appname> <output>    Build an AppImage
  ${SCRIPT_NAME} build <appname> <output> <entrypoint>
  ${SCRIPT_NAME} enter                       Enter the container shell
  ${SCRIPT_NAME} update                      Update all packages in the container
  ${SCRIPT_NAME} list                        List installed packages
  ${SCRIPT_NAME} shell <command>             Run a single command in the container
  ${SCRIPT_NAME} setup                       Download and setup the container

EXAMPLES:
  # Setup the container first
  ${SCRIPT_NAME} setup

  # Install Firefox
  ${SCRIPT_NAME} install MozillaFirefox

  # Build Firefox AppImage
  ${SCRIPT_NAME} build firefox ./Firefox-x86_64.AppImage firefox

  # Enter container for manual work
  ${SCRIPT_NAME} enter

VERSION: ${VERSION}
EOF
}

main() {
    local command="${1:-}"
    shift 2>/dev/null || true

    case "$command" in
        setup)
            check_deps
            setup_rootfs "$BASE_DIR/rootfs" "$BASE_DIR"
            # Basic bootstrap
            step "Bootstrapping base packages..."
            run_in_sandbox "$BASE_DIR/rootfs" '
                zypper --non-interactive --no-gpg-checks refresh 2>/dev/null || true
                zypper --non-interactive --no-gpg-checks install -y \
                    bash coreutils filesystem glibc glibc-locale-base 2>/dev/null || true
            '
            info "openSUSE Tumbleweed container is ready!"
            info "Next: opensuse-appimage install <packages>"
            ;;
        install)
            check_deps
            setup_rootfs "$BASE_DIR/rootfs" "$BASE_DIR"
            if [ $# -eq 0 ]; then
                err "No packages specified."
                echo "Usage: $SCRIPT_NAME install <pkg1> [pkg2 ...]"
                exit 1
            fi
            install_packages "$BASE_DIR/rootfs" "$*"
            info "Done."
            ;;
        build)
            check_deps
            setup_rootfs "$BASE_DIR/rootfs" "$BASE_DIR"
            if [ $# -lt 2 ]; then
                err "Usage: $SCRIPT_NAME build <appname> <output> [entrypoint]"
                exit 1
            fi
            build_appimage "$BASE_DIR/rootfs" "$1" "$2" "${3:-$1}"
            ;;
        enter)
            check_deps
            setup_rootfs "$BASE_DIR/rootfs" "$BASE_DIR"
            step "Entering openSUSE Tumbleweed sandbox..."
            enter_sandbox "$BASE_DIR/rootfs" "/bin/bash"
            ;;
        update)
            check_deps
            setup_rootfs "$BASE_DIR/rootfs" "$BASE_DIR"
            update_rootfs "$BASE_DIR/rootfs"
            info "Done."
            ;;
        list)
            check_deps
            setup_rootfs "$BASE_DIR/rootfs" "$BASE_DIR"
            list_packages "$BASE_DIR/rootfs"
            ;;
        shell)
            check_deps
            setup_rootfs "$BASE_DIR/rootfs" "$BASE_DIR"
            if [ $# -eq 0 ]; then
                err "No command specified."
                exit 1
            fi
            run_in_sandbox "$BASE_DIR/rootfs" "$*"
            ;;
        clean)
            warn "Removing container at $BASE_DIR/rootfs"
            rm -rf "$BASE_DIR/rootfs"
            info "Removed."
            ;;
        --version|-v)
            echo "openSUSE-AppImage v${VERSION}"
            ;;
        --help|-h|"")
            usage
            ;;
        *)
            err "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
