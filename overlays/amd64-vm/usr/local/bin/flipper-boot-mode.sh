#!/bin/sh
# Start the session the GRUB entry asked for with flipper.mode= on the kernel command line:
#   handheld  flipctl alone, scaled up, keyboard as the Flipper's buttons (the default)
#   desktop   KDE Plasma through sddm, flipctl's remote view on http://localhost:8899
set -eu

mode=handheld
for arg in $(cat /proc/cmdline); do
	case "$arg" in
	flipper.mode=*) mode=${arg#flipper.mode=} ;;
	esac
done

case "$mode" in
handheld) exec systemctl --no-block start flipper-handheld.service ;;
desktop) exec systemctl --no-block start flipper-desktop.target ;;
*)
	echo "flipper-boot-mode: flipper.mode=$mode is neither handheld nor desktop" >&2
	exit 1
	;;
esac
