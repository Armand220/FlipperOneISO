#!/bin/bash
# One-time setup of a Debian 13 (trixie) amd64 build host for build-iso-amd64.sh:
# the image tools, plus cargo and rustc from trixie-backports, because flipctl
# needs rustc >= 1.92 and trixie ships 1.85. Run as root.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# WSL's Debian image already lists trixie-backports; a plain install may not.
if ! grep -rqs 'trixie-backports' /etc/apt/sources.list /etc/apt/sources.list.d/; then
	echo 'deb http://deb.debian.org/debian trixie-backports main' \
		>/etc/apt/sources.list.d/trixie-backports.list
fi

apt-get update
apt-get install -y --no-install-recommends \
	git curl ca-certificates build-essential binutils python3 debian-archive-keyring \
	mmdebstrap squashfs-tools xorriso mtools grub-common grub-pc-bin grub-efi-amd64-bin
apt-get install -y --no-install-recommends -t trixie-backports cargo rustc libstd-rust-dev

cd /
cargo --version
rustc --version
