#!/bin/sh
# Inside the handheld sway: scale each output by the largest whole number at which the
# 256x144 panel fits, then run flipctl as a client of it (it takes its keys from sway,
# which is where flipper-kbd-bridge's "Flipper One Buttons" device lands). When flipctl
# exits, sway exits with it and flipper-handheld.service starts both again.
set -eu

PANEL_W=256
PANEL_H=144

swaymsg -t get_outputs -r |
	jq -r '.[] | select(.active) | "\(.name) \(.current_mode.width) \(.current_mode.height)"' |
	while read -r name width height; do
		scale=$((width / PANEL_W))
		if [ $((height / PANEL_H)) -lt "$scale" ]; then
			scale=$((height / PANEL_H))
		fi
		if [ "$scale" -lt 1 ]; then
			scale=1
		fi
		swaymsg output "$name" scale "$scale" >/dev/null
		echo "flipper-handheld: $name ${width}x${height}, panel at ${scale}x"
	done

cd /usr/share/flipctl
status=0
FLIPCTL_APPS_URL=file:///usr/share/flipctl/catalogue/apps.toml \
	/usr/bin/flipctl --wayland --remote '[::]:8899' --assets /usr/share/flipctl/assets/remote ||
	status=$?
swaymsg exit
exit "$status"
