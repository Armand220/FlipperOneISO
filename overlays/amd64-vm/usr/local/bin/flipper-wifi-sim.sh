#!/bin/sh
# The FlipperOne-Lab access point, on the second simulated radio.
#
# The radio is moved into a network namespace of its own, a separate router box
# joined to the VM by a veth cable. In the VM's own namespace the AP's addresses
# would be local ones, and the kernel would answer for the AP without anything
# crossing the simulated air. In the box: hostapd, DHCP and DNS from dnsmasq, and
# NAT onto the cable; the VM then NATs that out through its own internet.
set -eu

NS=flipper-ap
AP_MAC=02:00:00:00:01:00
AP_ADDR=192.168.77.1/24
DHCP_RANGE=192.168.77.10,192.168.77.50,12h
# the cable: VM side .1, box side .2
LINK_HOST=fap-host
LINK_BOX=fap-box
LINK_NET=10.77.0
in_box() { ip netns exec "$NS" "$@"; }

# A restart starts from nothing: deleting the box hands the radio back to the VM.
ip netns delete "$NS" 2>/dev/null || true
ip link delete "$LINK_HOST" 2>/dev/null || true

ap=""
for dev in /sys/class/net/*; do
	# bonding_masters and the like are files, not interfaces
	[ -f "$dev/address" ] || continue
	if [ "$(cat "$dev/address")" = "$AP_MAC" ]; then
		ap=${dev##*/}
	fi
done
[ -n "$ap" ] || { echo "flipper-wifi-sim: no radio with $AP_MAC (is mac80211_hwsim loaded?)" >&2; exit 1; }
phy=$(cat "/sys/class/net/$ap/phy80211/name")

ip netns add "$NS"
iw phy "$phy" set netns name "$NS"
ip link add "$LINK_HOST" type veth peer name "$LINK_BOX"
ip link set "$LINK_BOX" netns "$NS"

ip addr add "$LINK_NET.1/30" dev "$LINK_HOST"
ip link set "$LINK_HOST" up
sysctl -q -w net.ipv4.ip_forward=1
nft -f - <<EOF
table ip flipper_wifi_sim
delete table ip flipper_wifi_sim
table ip flipper_wifi_sim {
	chain postrouting {
		type nat hook postrouting priority srcnat;
		ip saddr $LINK_NET.0/30 oifname != "$LINK_HOST" masquerade
	}
}
EOF

in_box ip link set lo up
in_box ip addr add "$LINK_NET.2/30" dev "$LINK_BOX"
in_box ip link set "$LINK_BOX" up
in_box ip route add default via "$LINK_NET.1"
in_box ip addr add "$AP_ADDR" dev "$ap"
in_box ip link set "$ap" up
in_box sysctl -q -w net.ipv4.ip_forward=1
in_box nft -f - <<EOF
table ip flipper_wifi_sim {
	chain postrouting {
		type nat hook postrouting priority srcnat;
		oifname "$LINK_BOX" masquerade
	}
}
EOF

# DNS goes to the VM's own upstream servers, which the box reaches over the cable;
# resolved's 127.0.0.53 is on the VM's loopback, not the box's.
in_box dnsmasq --keep-in-foreground --conf-file=/dev/null --interface="$ap" --bind-interfaces \
	--resolv-file=/run/systemd/resolve/resolv.conf \
	--dhcp-range="$DHCP_RANGE" --dhcp-option=option:router,192.168.77.1 &
exec ip netns exec "$NS" hostapd -i "$ap" /etc/hostapd/flipper-lab.conf
