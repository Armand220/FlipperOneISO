#!/bin/bash
# build-iso-amd64.sh - Flipper One OS as a Debian 13 (trixie) amd64 live ISO for
# VirtualBox and VMware, with a GRUB menu for handheld mode and desktop mode.
#
# The arm64 image comes from debos (debian-rk3576-ospack.yaml, then
# debian-rk3576-img.yaml). This builds the amd64 counterpart without debos: WSL2 has
# no /dev/kvm for fakemachine, so the root is bootstrapped by mmdebstrap into a
# directory and finished with plain chroot steps, then squashed and wrapped in a
# hybrid BIOS + UEFI ISO by grub-mkrescue.
#
# What it takes from the arm64 build, and what it leaves:
#   kept     the ospack package list, overlays/configs, overlays/usr/local,
#            overlays/home, overlays/profile-kde with the @Desktop KDE packages,
#            the default user, flipctl built the way build-flipctl.sh builds it
#   dropped  U-Boot, the RK3576 kernels and device trees, the btrfs profile/BLS
#            boot machinery, Broadcom WiFi/BT firmware, USB gadget, EXT GPIO,
#            panel seat and MCU units (see STRIP below), and the rk3576 test suite
#   added    linux-image-amd64 + live-boot, overlays/amd64-vm (mode switch,
#            keyboard bridge, MCU stand-in)
#
# Normally run through build.sh, which fetches the pinned sources and puts this file
# and overlays/amd64-vm in place. Run as root. Inputs, overridable from the environment:
#   FLIPCTL_DIR  flipctl-slint checkout          (default ../flipctl-slint)
#   APPS_DIR     flipctl-apps checkout           (default ../flipctl-apps)
#   EXPORT_DIR   where the finished ISO is copied; under WSL it defaults to the
#                Windows user's Desktop, elsewhere nothing is copied
set -euo pipefail

: "${SUITE:=trixie}"
: "${MIRROR:=http://deb.debian.org/debian}"
: "${IMG_OUT:=out}"
: "${WORK:=build-amd64}"
: "${FLIPCTL_DIR:=../flipctl-slint}"
: "${APPS_DIR:=../flipctl-apps}"
: "${FLIPCTL_FEATURES:=device,slint,remote,wayland,gpu}"
: "${EXPORT_DIR:=}"

ISO_NAME=flipperone-amd64.iso
ISO_VOLID=FLIPPERONE
# slint 1.17.1 sets the floor, as build-flipctl.sh says
FLIPCTL_MSRV=92

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
FLIPCTL_DIR=$(realpath "$FLIPCTL_DIR")
APPS_DIR=$(realpath "$APPS_DIR")
ROOT=$HERE/$WORK/rootfs
ISODIR=$HERE/$WORK/iso
STAGE=$HERE/$WORK/flipctl

die() { echo "build-iso-amd64: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

# --- packages -----------------------------------------------------------------

# debian-rk3576-ospack.yaml's mmdebstrap list, minus bluez-firmware and
# firmware-misc-nonfree (Broadcom and SoC blobs) and libubootenv-tool (U-Boot).
OSPACK_PACKAGES=(
	acl adduser alsa-ucm-conf alsa-utils apt-transport-https avahi-daemon
	bash-completion bc bluez bluez-meshd bsdextrautils bsdmainutils btrfs-compsize
	btrfs-progs build-essential busybox ca-certificates cec-utils chromium curl
	device-tree-compiler dmidecode dnsmasq-base drm-info e2fsprogs edid-decode evtest
	file fio fuse3 gcc git glmark2-wayland gpiod gstreamer1.0-plugins-bad
	gstreamer1.0-tools htop i2c-tools inetutils-telnet initramfs-tools iperf3 iproute2
	iptables iputils-ping iw jq kexec-tools kmscube less libcanberra-pulse
	libdrm-tests libfreeaptx0 liblc3-1 libldacbt-abr2 libldacbt-enc2 libopus0
	libqmi-utils libsbc1 libspa-0.2-bluetooth libtypec-utils libusb-1.0-0-dev links
	linux-cpupower linux-sysctl-defaults lm-sensors locales lshw lsof make mc
	mesa-utils modemmanager nano network-manager-config-connectivity-debian nftables
	nodejs openssh-server p7zip pciutils pipewire-alsa powercap-utils pv python3-evdev
	python3-pandas python3-plotly rfkill rsync samba sox strace stress-ng sudo sway
	sysstat systemd systemd-repart systemd-resolved systemd-sysv systemd-timesyncd
	tcpdump tinycbor-utils traceroute udev upower usb-modeswitch usbip usbutils
	util-linux-extra v4l-utils vim-tiny wget wireless-regdb wireplumber wpasupplicant
	zstd
	# the ospack's second apt step, minus cog (the panel kiosk), firmware-mediatek,
	# mesa-teflon-delegate (the RK3576 NPU), lpac (the modem's eSIM) and umtp-responder
	# (USB gadget)
	duperemove ffmpeg libavcodec-extra libavfilter-extra libavformat-extra
)

# debian-rk3576-img.yaml's @Desktop list, minus krdp, whose autostart would add a
# virtual monitor beside the VM's own screen.
DESKTOP_PACKAGES=(
	bluedevil blueman breeze-gtk-theme kde-config-gtk-style kde-config-screenlocker
	kde-spectacle kde-standard konsole kscreen mpv plasma-nm plasma-systemmonitor
	powerdevil sddm sddm-theme-breeze systemsettings
)

# What a PC live system needs that the arm64 image gets elsewhere or not at all.
# The image is built without Recommends, as the arm64 one is, so the session pieces
# a desktop normally drags in by recommendation are named here.
AMD64_PACKAGES=(
	# headers from the same run as the kernel, so they match it: test_power is
	# built against them (see "test_power" below)
	linux-image-amd64 linux-headers-amd64 live-boot
	login libpam-systemd dbus-user-session network-manager
	plasma-workspace kwin-wayland libgl1-mesa-dri libegl-mesa0
	fonts-noto-core fonts-hack swaybg python3
	# Flipper's prebuilt apps are aarch64 AppImages (see "apps" below): qemu-user runs
	# them through binfmt_misc. Their bundles carry everything but glibc and what the
	# device's own image already has, found by scanning all fifteen for NEEDED entries
	# and dlopen()ed names: winit's Wayland and xkbcommon and Slint's fontconfig (every
	# framework app), libudev (FPV, Doom), zlib and zstd (Speed test), gbm, libmount
	# and libselinux (Doom).
	qemu-user-binfmt libc6:arm64
	libwayland-client0:arm64 libxkbcommon0:arm64 libfontconfig1:arm64 libudev1:arm64
	zlib1g:arm64 libzstd1:arm64 libgbm1:arm64 libmount1:arm64 libselinux1:arm64
	# Doom, found by running it: libpulse's private libpulsecommon is looked up in the
	# system's pulseaudio directory, not the bundle's; the system ALSA config routes to
	# PipeWire, whose plugin must match the bundle's arch; and SDL2 on Wayland draws
	# through EGL even in software mode, which on the device is its Mesa and here is
	# Mesa's llvmpipe.
	libpulse0:arm64 pipewire-alsa:arm64
	libegl1:arm64 libegl-mesa0:arm64 libgles2:arm64 libgl1-mesa-dri:arm64
	# the simulated FlipperOne-Lab access point (overlays/amd64-vm, flipper-wifi-sim)
	hostapd
)

# Catalogue folders not baked in: the runtimes run the image's own python3 and node,
# which are amd64 and cannot load the aarch64 drawing stack the runtimes carry, so
# they and every script app that needs them would install and then fail to start.
APPS_SKIP_FOLDERS=(Runtimes)

# --- what the overlays bring that a VM must not have --------------------------

# Paths relative to the root. Each one is named for a reason, in the comment above it.
STRIP=(
	# the BLS/btrfs boot machinery: install.conf turns off initrd generation, which
	# live-boot depends on, and the hooks call a kernel-install layout this image lacks
	etc/kernel/install.conf
	etc/kernel/devicetreedir
	etc/kernel/flipper-profiles
	etc/kernel/postinst.d/zz-kernel-install
	etc/kernel/postrm.d/zz-kernel-install
	etc/initramfs/post-update.d/zz-flipper-kernel-install
	etc/repart.d/50-rootfs.conf
	# Flipper's own apt repository carries arm64 kernels only
	etc/apt/sources.list.d/flipper.list
	etc/apt/keyrings/alchark.gpg
	# the SPI panel's seat, its cog kiosk, and the upstream flipctl --panel autostart:
	# the panel is replaced by the modes in overlays/amd64-vm
	etc/systemd/system/cog-seat1.service
	etc/systemd/system/fake-flipctl-node-server.service
	etc/systemd/system/multi-user.target.wants/flipctl.service
	etc/udev/rules.d/72-seat-cog.rules
	# the MCU's I2C cpustate reports
	etc/systemd/system/flipper-one-online.service
	etc/systemd/system/flipper-one-poweroff.service
	etc/systemd/system/flipper-one-reboot.service
	etc/systemd/system/multi-user.target.wants/flipper-one-online.service
	etc/systemd/system/poweroff.target.wants
	etc/systemd/system/reboot.target.wants
	# the btrfs boot counting, whose tools this image does not carry
	etc/systemd/system/multi-user.target.wants/flipper-bless-boot.service
	etc/systemd/system/boot-complete.target.requires
	# the EXT connector GPIOs
	etc/systemd/system/ext-gpio.service
	etc/systemd/system/multi-user.target.wants/ext-gpio.service
	etc/udev/rules.d/71-ext.rules
	usr/local/bin/ext-gpio.sh
	# the USB gadget link to a computer
	etc/systemd/system/flipusb0-dhcp.service
	etc/systemd/system/multi-user.target.wants/flipusb0-dhcp.service
	etc/systemd/system/usb-msc-gadget.service
	etc/systemd/system/usb-ncm-gadget.service
	etc/systemd/system/usb-ncm-msc-gadget.service
	etc/systemd/system/usb-ncm-msc-mtp-gadget.service
	etc/systemd/system/usb-ncm-mtp-acm-gadget.service
	etc/systemd/system/multi-user.target.wants/usb-ncm-mtp-acm-gadget.service
	etc/systemd/network/10-flipusb.link
	etc/udev/rules.d/90-flipserial.rules
	etc/udev/rules.d/90-flipusb-managed.rules
	etc/NetworkManager/system-connections/flipusb0-static.nmconnection
	usr/local/bin/usb-acm-gadget.sh
	usr/local/bin/usb-gadget-setup.sh
	usr/local/bin/usb-msc-gadget.sh
	usr/local/bin/usb-mtp-gadget.sh
	usr/local/bin/usb-ncm-gadget.sh
	usr/local/bin/usb-ncm-msc-gadget.sh
	usr/local/bin/usb-ncm-msc-mtp-gadget.sh
	usr/local/bin/usb-ncm-mtp-acm-gadget.sh
	# board identity from the RK3576 OTP and device tree
	etc/systemd/system/set-hostname-and-banner.service
	etc/systemd/system/multi-user.target.wants/set-hostname-and-banner.service
	etc/update-motd.d/00-flipperone
	usr/local/bin/set-hostname-and-banner.sh
	usr/local/bin/rk3576_cpu_serial.sh
	# the board's LEDs, charger, codecs and modem
	etc/udev/rules.d/99-charger-status.rules
	etc/udev/rules.d/99-network-leds.rules
	etc/udev/rules.d/90-flipper-kameleon.rules
	etc/NetworkManager/dispatcher.d/91-wifi-led
	etc/NetworkManager/system-connections/cellular-vodafone-uk.nmconnection
	etc/NetworkManager/system-connections/router-wan.nmconnection
	etc/wireplumber/wireplumber.conf.d/51-nau8822-rename.conf
	etc/wireplumber/wireplumber.conf.d/52-es8388-rename.conf
	etc/wireplumber/wireplumber.conf.d/53-rt5616-rename.conf
	etc/wireplumber/wireplumber.conf.d/59-audio-rename.conf
	etc/systemd/system/serial-getty@ttyFIQ0.service.d
	usr/local/bin/flipper-esim-provision.sh
	usr/local/bin/battery-log.sh
	usr/share/alsa/ucm2/Rockchip
	usr/share/alsa/ucm2/conf.d/rockchip-dp0
	usr/share/alsa/ucm2/conf.d/rockchip-hdmi
	usr/share/alsa/ucm2/conf.d/simple-card
	# krdp, with its package (see DESKTOP_PACKAGES)
	etc/systemd/user/plasma-workspace.target.wants/app-org.kde.krdpserver.service
	etc/systemd/user/app-org.kde.krdpserver.service.d
	etc/systemd/user/krdp-certificate.service
	etc/udev/rules.d/90-flipper-krdp.rules
	etc/xdg/krdpserverrc
	usr/local/bin/flipper-krdp.sh
)

# --- chroot plumbing ----------------------------------------------------------

MOUNTS=()
unmount_all() {
	local i
	for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
		umount "${MOUNTS[i]}"
	done
	MOUNTS=()
}
# On an error exit the mounts still have to go, or the next run's rm -rf of the
# root walks into the host's /dev and /sys. Lazy, because whatever failed may still
# hold them.
trap 'for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do umount -l "${MOUNTS[i]}"; done' EXIT

mount_root() {
	mount --bind /dev "$ROOT/dev"
	MOUNTS+=("$ROOT/dev")
	mount --bind /dev/pts "$ROOT/dev/pts"
	MOUNTS+=("$ROOT/dev/pts")
	mount -t proc proc "$ROOT/proc"
	MOUNTS+=("$ROOT/proc")
	mount -t sysfs sysfs "$ROOT/sys"
	MOUNTS+=("$ROOT/sys")
}

in_root() {
	chroot "$ROOT" /usr/bin/env -i HOME=/root LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		/bin/sh -euc "$1"
}

# --- preflight ----------------------------------------------------------------

step "preflight"
[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"
[ "$(uname -m)" = x86_64 ] || die "this builds amd64 natively, which needs an x86_64 builder"
case "$HERE" in
	/mnt/*) die "$HERE is on a Windows drive; move the workspace into the Linux filesystem" ;;
esac
for tool in mmdebstrap mksquashfs grub-mkrescue xorriso mformat cargo rustc chroot readelf python3 curl; do
	command -v "$tool" >/dev/null || die "$tool not found"
done
[ -d /usr/lib/grub/i386-pc ] || die "no /usr/lib/grub/i386-pc: install grub-pc-bin for BIOS boot"
[ -d /usr/lib/grub/x86_64-efi ] || die "no /usr/lib/grub/x86_64-efi: install grub-efi-amd64-bin for UEFI boot"
[ -f "$FLIPCTL_DIR/bin/flipctl/Cargo.toml" ] || die "no flipctl-slint checkout at $FLIPCTL_DIR"
[ -f "$APPS_DIR/apps.toml" ] || die "no flipctl-apps checkout at $APPS_DIR"
[ -d overlays/amd64-vm ] || die "no overlays/amd64-vm beside this script"

ver=$(cargo --version | awk '{print $2}')
minor=${ver#1.}
minor=${minor%%.*}
[ "$minor" -ge "$FLIPCTL_MSRV" ] 2>/dev/null ||
	die "cargo $ver is too old; flipctl needs 1.$FLIPCTL_MSRV (on Debian: apt-get install -t trixie-backports cargo rustc)"

# --- flipctl --------------------------------------------------------------------

# build-flipctl.sh's staging, natively for x86_64-unknown-linux-gnu: that script
# cross-compiles for aarch64 whenever the builder is not aarch64, so it is not
# called. Same cargo invocation and the same staged tree under /usr.
step "flipctl for x86_64 ($FLIPCTL_FEATURES)"
rm -rf "$STAGE"
cargo install --path "$FLIPCTL_DIR/bin/flipctl" --root "$STAGE" --no-track --locked \
	--target-dir "$FLIPCTL_DIR/target" --features "$FLIPCTL_FEATURES"
grep -q 'Machine:.*X86-64' <<<"$(readelf -h "$STAGE/bin/flipctl")" || die "flipctl did not come out x86-64"
mkdir -p "$STAGE/share/flipctl/assets"
cp -a "$FLIPCTL_DIR/crates/flipper-ui/assets/remote" "$STAGE/share/flipctl/assets/remote"
install -D -m 644 "$FLIPCTL_DIR/systemd/flipctl.service" "$STAGE/lib/systemd/system/flipctl.service"
install -D -m 644 "$FLIPCTL_DIR/systemd/flipctl.sysusers.conf" "$STAGE/lib/sysusers.d/flipctl.conf"
install -D -m 644 "$FLIPCTL_DIR/systemd/70-flipctl-devices.rules" \
	"$STAGE/lib/udev/rules.d/70-flipctl-devices.rules"
install -D -m 644 "$FLIPCTL_DIR/systemd/flipctl-devices.conf" \
	"$STAGE/lib/modules-load.d/flipctl-devices.conf"
# The app catalogue, read from disk instead of the network: the modes'
# units point FLIPCTL_APPS_URL at it.
install -D -m 644 "$APPS_DIR/apps.toml" "$STAGE/share/flipctl/catalogue/apps.toml"
echo "staged $(du -sh "$STAGE" | cut -f1) in $STAGE"

# --- apps -----------------------------------------------------------------------

# Every prebuilt AppImage the catalogue offers, into the folder flipctl lists the
# image's own apps from (bundle::SYSTEM, /usr/share/flipctl/apps), at the path the
# catalogue files it under. Checked against the catalogue's sha256, and kept in a
# cache across builds. Scripts are left to the App Manager: see APPS_SKIP_FOLDERS.
step "apps from the catalogue (aarch64, run through qemu-user)"
APPS_CACHE=$HERE/$WORK/apps-cache
mkdir -p "$APPS_CACHE"
python3 - "$APPS_DIR/apps.toml" "${APPS_SKIP_FOLDERS[@]}" >"$WORK/apps.list" <<'PY'
import sys, tomllib
catalogue, skip = sys.argv[1], set(sys.argv[2:])
for app in tomllib.load(open(catalogue, "rb"))["app"]:
    if app["path"].endswith(".AppImage") and app["path"].split("/")[0] not in skip:
        print(app["sha256"], app["url"], app["path"], sep="\t")
PY
[ -s "$WORK/apps.list" ] || die "the catalogue lists no AppImages"
while IFS=$'\t' read -r sha url path; do
	cached=$APPS_CACHE/$sha
	if [ ! -f "$cached" ]; then
		curl -fsSL -o "$cached.part" "$url"
		mv "$cached.part" "$cached"
	fi
	echo "$sha  $cached" | sha256sum -c --quiet || die "$path does not match the catalogue's sha256"
	install -D -m 755 "$cached" "$STAGE/share/flipctl/apps/$path"
	echo "  $path"
done <"$WORK/apps.list"

# --- root filesystem ------------------------------------------------------------

step "bootstrapping Debian $SUITE amd64 into $ROOT"
rm -rf "$ROOT"
mkdir -p "$(dirname "$ROOT")"
mmdebstrap --mode=root --format=directory --variant=minbase --architectures=amd64,arm64 \
	--components="main contrib non-free non-free-firmware" \
	--aptopt='APT::Install-Recommends "false"' \
	--include="$(IFS=,; echo "${OSPACK_PACKAGES[*]},${DESKTOP_PACKAGES[*]},${AMD64_PACKAGES[*]}")" \
	"$SUITE" "$ROOT" "$MIRROR"

mount_root

step "locale"
in_root 'sed -i "s/^# en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen && locale-gen'
echo "LANG=en_US.UTF-8" >"$ROOT/etc/default/locale"

step "overlays"
# Root-owned, as debos's overlay action leaves them. cp -a would keep the checkout
# owner's uid, which inside the image is `user`: sudo then ignores sudoers.d/user,
# and `user` owns /etc and / itself, since copying dir/. carries the directory's own
# attributes onto the target.
overlay() { cp -dR --preserve=mode,timestamps "$1/." "$2/"; }
# The order debian-rk3576-ospack.yaml uses: configs before the user exists, so
# useradd copies skel; then usr/local, usr/share, flipctl, the KDE profile and home.
overlay overlays/configs "$ROOT/etc"
overlay overlays/usr/local "$ROOT/usr/local"
overlay overlays/usr/share "$ROOT/usr/share"
overlay "$STAGE" "$ROOT/usr"
overlay overlays/profile-kde "$ROOT"
for path in "${STRIP[@]}"; do
	[ -e "$ROOT/$path" ] || [ -L "$ROOT/$path" ] || die "STRIP names $path, which the overlays no longer ship"
	rm -rf "${ROOT:?}/$path"
done
# Last, so it wins over anything above it.
overlay overlays/amd64-vm "$ROOT"

step "users"
in_root '
	useradd -s /bin/bash -m user
	echo "user:user" | chpasswd
	for group in audio bluetooth sudo input video render dialout plugdev; do
		gpasswd -a user "$group"
	done
	systemd-sysusers
'
overlay overlays/home/user "$ROOT/home/user"
mkdir -p "$ROOT/home/user/Apps"
in_root '
	chown -R user:user /home/user
	chmod 700 /home/user/.local/share/kwalletd
	chmod 600 /home/user/.local/share/kwalletd/kdewallet.kwl /home/user/.local/share/kwalletd/kdewallet.salt
'
owned=$(find "$ROOT" -xdev -path "$ROOT/home" -prune -o -uid 1000 -print -quit)
[ -z "$owned" ] || die "$owned belongs to user; only /home may"

step "services"
# multi-user is the default, as on every arm64 profile but @Desktop; which session
# then runs is flipper-boot-mode's choice, from flipper.mode= on the command line.
# sddm is started only by flipper-desktop.target, so it loses its display-manager alias.
in_root '
	systemctl set-default multi-user.target
	systemctl disable sddm.service
	systemctl enable NetworkManager.service flipper-boot-mode.service flipper-mcu-mock.service flipper-wifi-sim.service
'

step "identity"
# The checkout belongs to the WSL user and this runs as root, which git refuses
# without the directory being named safe.
GIT_INFO=$(git -c safe.directory="$HERE" -C "$HERE" log -1 --format='%h %s' | tr -dc '[:alnum:][:space:]')
echo "BUILD_GIT=\"amd64-live $GIT_INFO\"" >>"$ROOT/etc/os-release"
echo "BUILD_ID=$(date -u +%Y%m%d-%H%M)" >>"$ROOT/etc/os-release"
# Empty, not absent: every boot of the live system is then a first boot with a fresh id.
: >"$ROOT/etc/machine-id"
rm -f "$ROOT/var/lib/dbus/machine-id"

step "kernel and initramfs"
kernels=("$ROOT"/boot/vmlinuz-*)
[ ${#kernels[@]} -eq 1 ] && [ -e "${kernels[0]}" ] || die "expected one kernel in /boot, found: ${kernels[*]}"
KVER=${kernels[0]##*/vmlinuz-}
# After STRIP: built with install.conf still in place, the initrd would be skipped.
in_root "update-initramfs -u -k $KVER"
grep -qE '(^|/)scripts/live$' <<<"$(in_root "lsinitramfs /boot/initrd.img-$KVER")" ||
	die "the initrd for $KVER has no live-boot scripts"

step "test_power"
# flipper-mcu-mock's battery is test_power's test_battery, and Debian's amd64 kernel
# leaves CONFIG_TEST_POWER unset. Built out of tree from the upstream source of the
# image kernel's own version (6.12.117+deb13-amd64 -> v6.12.117), against its headers.
# Unsigned: it loads on a VM without Secure Boot, which is VirtualBox's and VMware's default.
UPSTREAM=${KVER%%+*}
mkdir -p "$ROOT/usr/src/test_power"
curl -fsSL -o "$ROOT/usr/src/test_power/test_power.c" \
	"https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/power/supply/test_power.c?h=v$UPSTREAM"
echo 'obj-m := test_power.o' >"$ROOT/usr/src/test_power/Kbuild"
in_root "
	make -C /usr/lib/modules/$KVER/build M=/usr/src/test_power modules
	install -D -m 644 /usr/src/test_power/test_power.ko /usr/lib/modules/$KVER/updates/test_power.ko
	depmod $KVER
	rm -rf /usr/src/test_power
"

for module in uinput test_power mac80211_hwsim; do
	grep -q "/$module.ko" "$ROOT/usr/lib/modules/$KVER/modules.builtin" ||
		[ -n "$(find "$ROOT/usr/lib/modules/$KVER" -name "$module.ko*")" ] ||
		die "kernel $KVER has no $module, which overlays/amd64-vm needs"
done
# In the chroot, so a symlink resolves inside the image and not on the builder.
in_root 'test -x /usr/libexec/qemu-binfmt/aarch64-binfmt-P' ||
	die "no qemu aarch64 binfmt interpreter, which etc/binfmt.d/qemu-aarch64-appimage.conf names"
in_root 'test -x /usr/lib/ld-linux-aarch64.so.1' || die "no aarch64 glibc for the prebuilt apps"

in_root 'apt-get clean'
rm -rf "$ROOT"/var/lib/apt/lists/* "$ROOT"/tmp/* "$ROOT"/var/tmp/*
unmount_all

# --- ISO --------------------------------------------------------------------------

step "squashfs"
rm -rf "$ISODIR"
mkdir -p "$ISODIR/live" "$ISODIR/boot/grub"
cp "$ROOT/boot/vmlinuz-$KVER" "$ISODIR/live/vmlinuz"
cp "$ROOT/boot/initrd.img-$KVER" "$ISODIR/live/initrd.img"
mksquashfs "$ROOT" "$ISODIR/live/filesystem.squashfs" -noappend -comp zstd -Xcompression-level 19 -b 1M

step "grub"
cat >"$ISODIR/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=8
insmod all_video
search --no-floppy --set=root --file /live/filesystem.squashfs

menuentry "Flipper One Mode (Handheld UI)" --id handheld {
	linux /live/vmlinuz boot=live quiet flipper.mode=handheld
	initrd /live/initrd.img
}

menuentry "Flipper One Desktop Mode (External Monitor)" --id desktop {
	linux /live/vmlinuz boot=live quiet flipper.mode=desktop
	initrd /live/initrd.img
}
EOF

step "ISO"
mkdir -p "$IMG_OUT"
ISO=$(realpath "$IMG_OUT")/$ISO_NAME
grub-mkrescue -o "$ISO" "$ISODIR" -- -volid "$ISO_VOLID"
# Root built it; hand it and the cargo cache back to whoever ran sudo, or failing
# that to whoever owns the checkout.
owner=$(stat -c %u:%g "$HERE")
[ -z "${SUDO_UID:-}" ] || owner=$SUDO_UID:$SUDO_GID
chown -R "$owner" "$IMG_OUT" "$FLIPCTL_DIR/target"
echo "$(du -h "$ISO" | cut -f1) $ISO"

# --- export -----------------------------------------------------------------------

# By full path: sudo resets PATH, which drops the Windows directories WSL appends,
# and cmd.exe is then "command not found".
WIN_CMD=/mnt/c/Windows/System32/cmd.exe
if [ -z "$EXPORT_DIR" ] && [ -x "$WIN_CMD" ]; then
	profile=$(cd /mnt/c && "$WIN_CMD" /c 'echo %USERPROFILE%' | tr -d '\r')
	EXPORT_DIR=$(wslpath "$profile")/Desktop
fi
if [ -n "$EXPORT_DIR" ]; then
	step "export to $EXPORT_DIR"
	[ -d "$EXPORT_DIR" ] || die "no directory $EXPORT_DIR"
	cp "$ISO" "$EXPORT_DIR/$ISO_NAME"
	ls -l "$EXPORT_DIR/$ISO_NAME"
fi
