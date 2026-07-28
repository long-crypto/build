#!/usr/bin/env bash
set -e

export ARCH="$(uname -m)"
export DESKTOP=~/steam.desktop
export ICON=~/steam.png
export STARTUPWMCLASS=steam
export UPINFO="gh-releases-zsync|$(echo "$GITHUB_REPOSITORY" | tr '/' '|')|latest|*-$ARCH.AppImage.zsync"

URUNTIME="https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/refs/heads/main/useful-tools/uruntime2appimage.sh"

ROOTFS_DIR="$(pwd)/opensuse-rootfs"

ensure_zypper() {
	if ! command -v zypper &>/dev/null; then
		echo '== installing zypper on host'
		if command -v apt-get &>/dev/null; then
			sudo apt-get update && sudo apt-get install -y zypper
		elif command -v dnf &>/dev/null; then
			sudo dnf install -y zypper
		else
			echo "ERROR: cannot install zypper (only apt and dnf supported on host)" >&2
			exit 1
		fi
	fi
}

bootstrap_opensuse() {
	echo '== bootstrapping openSUSE Tumbleweed rootfs'
	rm -rf "$ROOTFS_DIR"
	mkdir -p "$ROOTFS_DIR"/{dev,proc,sys,run,tmp,var/cache/zypp,etc/zypp/repos.d}

	sudo zypper --root "$ROOTFS_DIR" --non-interactive --gpg-auto-import-keys addrepo --refresh \
		"https://download.opensuse.org/tumbleweed/repo/oss/" tumbleweed-oss
	sudo zypper --root "$ROOTFS_DIR" --non-interactive --gpg-auto-import-keys addrepo --refresh \
		"https://download.opensuse.org/tumbleweed/repo/non-oss/" tumbleweed-non-oss
	sudo zypper --root "$ROOTFS_DIR" --non-interactive --gpg-auto-import-keys addrepo --refresh \
		"https://download.opensuse.org/update/tumbleweed/" tumbleweed-update

	sudo zypper --root "$ROOTFS_DIR" --non-interactive --gpg-auto-import-keys refresh
	sudo zypper --root "$ROOTFS_DIR" --non-interactive --gpg-auto-import-keys install --no-recommends \
		patterns-base-minimal_base \
		steam \
		Mesa-libEGL1 Mesa-libGL1 \
		vulkan-tools libvulkan1 \
		libvulkan_intel libvulkan_radeon \
		pipewire libpipewire-0_3-0 libpulse0 \
		libfreetype6 \
		libfuse2 \
		mangohud gamemode \
		zenity \
		wget curl bash sed gawk grep \
		xdg-utils \
		libstdc++6 libgcc_s1 glibc glibc-locale glibc-utils

	VERSION=$(sudo zypper --root "$ROOTFS_DIR" info steam 2>/dev/null | awk '/^Version/ {print $3}' | head -1)
	[ -n "$VERSION" ] && echo "$VERSION" > ~/version

	cp "$ROOTFS_DIR/usr/share/icons/hicolor/256x256/apps/steam.png" ~/ 2>/dev/null || true
	cp "$ROOTFS_DIR/usr/share/applications/steam.desktop" ~/ 2>/dev/null || true
}

chroot_setup() {
	echo '== setting up chroot bind mounts'
	mkdir -p "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/etc"
	sudo mount --bind /dev "$ROOTFS_DIR/dev"
	sudo mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
	sudo mount --bind /proc "$ROOTFS_DIR/proc"
	sudo mount --bind /sys "$ROOTFS_DIR/sys"
	sudo mount --bind /run "$ROOTFS_DIR/run"
	sudo cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
}

chroot_teardown() {
	echo '== tearing down chroot mounts'
	sudo umount "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
	sudo umount "$ROOTFS_DIR/dev" 2>/dev/null || true
	sudo umount "$ROOTFS_DIR/proc" 2>/dev/null || true
	sudo umount "$ROOTFS_DIR/sys" 2>/dev/null || true
	sudo umount "$ROOTFS_DIR/run" 2>/dev/null || true
}

run_install() {
	set -e

	ensure_zypper
	bootstrap_opensuse
	chroot_setup

	echo '== allow steam to run as root'
	STEAM_BIN_SH="$ROOTFS_DIR/usr/lib/steam/bin_steam.sh"
	if [ -f "$STEAM_BIN_SH" ]; then
		sudo sed -i 's|"$(id -u)" == "0"|"$(id -u)" == "69"|' "$STEAM_BIN_SH"
		sudo sed -i 's|\[ ! -L "$DESKTOP_DIR/$STEAMPACKAGE.desktop" \]|false|' "$STEAM_BIN_SH"
	fi

	echo '== steam-runtime symlinks'
	sudo ln -sf ./steam "$ROOTFS_DIR/usr/bin/steam-runtime" 2>/dev/null || true
	sudo ln -sf ./steam "$ROOTFS_DIR/usr/bin/steam-native" 2>/dev/null || true

	chroot_teardown

	VERSION="$(cat ~/version 2>/dev/null || echo "unknown")"
	[ -z "$VERSION" ] && VERSION="unknown"
	echo "$VERSION" > ~/version

	rm -rf ./RunDir
	mkdir -p ./RunDir/rootfs
	echo '== copying rootfs'
	sudo cp -a "$ROOTFS_DIR/." ./RunDir/rootfs/
	sudo chown -R "$(id -u):$(id -g)" ./RunDir/rootfs/
}
export -f run_install

run_install

mv ./RunDir ./AppDir

echo '#!/bin/bash' > ./AppDir/AppRun
cat >> ./AppDir/AppRun << 'APPEOF'
HERE="$(dirname "$(readlink -f "$0")")"
export PATH="$HERE/rootfs/usr/bin:$HERE/rootfs/usr/sbin:$PATH"
export LD_LIBRARY_PATH="$HERE/rootfs/usr/lib:$HERE/rootfs/usr/lib64:$HERE/rootfs/lib64:$LD_LIBRARY_PATH"
export STEAM_RUNTIME=0
exec "$HERE/rootfs/usr/bin/steam" "$@"
APPEOF
chmod +x ./AppDir/AppRun

cp "$ROOTFS_DIR/usr/share/icons/hicolor/256x256/apps/steam.png" ./AppDir/steam.png 2>/dev/null || true
cp "$ROOTFS_DIR/usr/share/applications/steam.desktop" ./AppDir/steam.desktop 2>/dev/null || true

ln -s ./steam ./AppDir/rootfs/usr/bin/steam-runtime 2>/dev/null || true
ln -s ./steam ./AppDir/rootfs/usr/bin/steam-native 2>/dev/null || true

echo '== debloating rootfs'
rm -rfv ./AppDir/rootfs/usr/share/man/ 2>/dev/null || true
rm -rfv ./AppDir/rootfs/usr/share/doc/ 2>/dev/null || true
rm -rfv ./AppDir/rootfs/usr/share/info/ 2>/dev/null || true
rm -rfv ./AppDir/rootfs/usr/share/licenses/ 2>/dev/null || true
rm -rfv ./AppDir/rootfs/usr/share/locale/*/ 2>/dev/null || true
find ./AppDir/rootfs -name '*.a' -delete 2>/dev/null || true
find ./AppDir/rootfs -name '*.la' -delete 2>/dev/null || true
rm -rfv ./AppDir/rootfs/var/cache/zypp/ 2>/dev/null || true
rm -rfv ./AppDir/rootfs/var/log/ 2>/dev/null || true
rm -rfv ./AppDir/rootfs/etc/zypp/ 2>/dev/null || true

echo "Generating AppImage..."
VERSION="$(cat ~/version 2>/dev/null || echo "unknown")"
[ -z "$VERSION" ] && VERSION="unknown"
export VERSION
export OUTNAME=Steam-"$VERSION"-anylinux-"$ARCH".AppImage
wget --retry-connrefused --tries=30 "$URUNTIME" -O ./uruntime2appimage
chmod +x ./uruntime2appimage

export ADD_PERMA_ENV_VARS='RIM_ALLOW_ROOT=1'
./uruntime2appimage || {
	echo "uruntime2appimage failed, trying alternative method..."
	ARCH_APPIMAGE="$(which appimagetool 2>/dev/null || true)"
	if [ -z "$ARCH_APPIMAGE" ]; then
		wget -qO ./appimagetool "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
		chmod +x ./appimagetool
		ARCH_APPIMAGE=./appimagetool
	fi
	"$ARCH_APPIMAGE" ./AppDir "$OUTNAME"
}

UPINFO="gh-releases-zsync|$(echo "$GITHUB_REPOSITORY" | tr '/' '|')|latest|*$ARCH*.AppBundle.zsync"
wget -qO ./pelf "https://github.com/xplshn/pelf/releases/latest/download/pelf_$ARCH" || true
chmod +x ./pelf 2>/dev/null || true

if [ -x ./pelf ]; then
	echo "Generating [sqfs]AppBundle...(Go runtime)"
	./pelf --add-appdir ./AppDir \
		--compression "-comp zstd -Xcompression-level 22 -b 1M" \
		--appbundle-id="com.valvesoftware.Steam-$(date +%d_%m_%Y)-ivanHC" \
		--appimage-compat --disable-use-random-workdir \
		--add-updinfo "$UPINFO" \
		--output-to "Steam-${VERSION}-anylinux-${ARCH}.sqfs.AppBundle"
	zsyncmake ./*.AppBundle -u ./*.AppBundle 2>/dev/null || true
fi

echo "All Done!"
