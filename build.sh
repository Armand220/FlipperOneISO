#!/bin/bash
# build.sh - build flipperone-amd64.iso from a clone of this repository.
#
# Fetches Flipper's three repositories at the commits this port was tested against
# into src/, puts build-iso-amd64.sh and overlays/amd64-vm into the build-scripts
# checkout, and runs the build there. Run setup-host.sh once first. Run as root.
#
# The finished ISO is src/flipperone-linux-build-scripts/out/flipperone-amd64.iso,
# and under WSL it is also copied to the Windows Desktop (EXPORT_DIR overrides that).
set -euo pipefail

# Flipper's sources, as tested. Moving one is a new port: its overlays, package
# lists or flipctl may have changed under build-iso-amd64.sh.
PINS=(
	"flipperone-linux-build-scripts https://github.com/flipperdevices/flipperone-linux-build-scripts.git 1f8a286642c366598f9baf897be6312ad64392f9"
	"flipctl-slint https://github.com/flipperdevices/flipctl-slint.git 258e19a1ead6e32f27c89f272d6ec92be986ad61"
	"flipctl-apps https://github.com/flipperdevices/flipctl-apps.git 13d3e393a51103c1994d15cc23fa44d551df6555"
)

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/src

die() { echo "build.sh: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo ./build.sh"
case "$HERE" in
	/mnt/*) die "$HERE is on a Windows drive; clone this repository into the Linux filesystem (cd ~ first)" ;;
esac
command -v git >/dev/null || die "git not found: run setup-host.sh first"

# A shallow fetch of exactly the pinned commit. Re-running reuses the checkout and
# its build caches, and resets tracked files to the pin.
mkdir -p "$SRC"
for pin in "${PINS[@]}"; do
	read -r name url commit <<<"$pin"
	dir=$SRC/$name
	echo "== $name @ ${commit:0:7}"
	if [ ! -d "$dir/.git" ]; then
		git init -q "$dir"
		git -C "$dir" remote add origin "$url"
	fi
	git -C "$dir" fetch -q --depth 1 origin "$commit"
	git -C "$dir" -c advice.detachedHead=false checkout -q --force "$commit"
done

echo "== adding the amd64 port to the build scripts"
cp "$HERE/build-iso-amd64.sh" "$SRC/flipperone-linux-build-scripts/"
rm -rf "$SRC/flipperone-linux-build-scripts/overlays/amd64-vm"
cp -r "$HERE/overlays/amd64-vm" "$SRC/flipperone-linux-build-scripts/overlays/"

cd "$SRC/flipperone-linux-build-scripts"
exec ./build-iso-amd64.sh
