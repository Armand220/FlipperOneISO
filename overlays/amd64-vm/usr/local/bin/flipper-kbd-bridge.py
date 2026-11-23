#!/usr/bin/python3
"""PC keyboard and mouse -> Flipper One buttons, for handheld mode.

The mouse has no pointer to move on the panel, so it is buttons too: the wheel is
the D-pad (tilt for left and right), left click OK, right click Back, middle click
the app switcher. Movement is dropped.

Grabs every keyboard the VM has and re-emits it through one uinput device named
"Flipper One Buttons", the name the MCU input driver gives the real buttons. Keys
that stand for a Flipper button are rewritten to the code flipper-one-input.c sends
for it (crates/flipper-ui/src/key.rs in flipctl-slint); every other key passes
through untouched, so modifiers, VT switching and typing still work.

Grabbing is what keeps a press from arriving twice: sway would otherwise read the
raw keyboard as well as this device, and flipctl would see both.

Remapping applies only while the handheld session's VT is in front and neither Ctrl
nor Alt is held. On a text console (Ctrl+Alt+F2 and up) every key is itself.

Each button press is also published in the MCU firmware CLI's own `input dump`
format ("key: Up type: Press") to flipper-mcu-mock, which serves it on its PTY.
"""

import os
import select
import socket
import subprocess
import sys
import time

import evdev
from evdev import ecodes as e

DEVICE_NAME = "Flipper One Buttons"
HANDHELD_VT = "tty1"
ACTIVE_VT = "/sys/class/tty/tty0/active"
MCU_EVENTS = "/run/flipper-mcu/events.sock"
RESCAN_S = 2.0
# applications/services/input/input.c: INPUT_PRESS_TICKS (150) * INPUT_LONG_PRESS_COUNTS (2)
LONG_PRESS_S = 0.300

# Keys that already are Flipper codes (arrows, Enter, Backspace, Tab, Z X C V B) pass
# through as themselves. These are the extra ones.
REMAP = {
    e.KEY_W: e.KEY_UP,
    e.KEY_S: e.KEY_DOWN,
    e.KEY_A: e.KEY_LEFT,
    e.KEY_D: e.KEY_RIGHT,
    e.KEY_SPACE: e.KEY_ENTER,  # OK
    e.KEY_KPENTER: e.KEY_ENTER,
    e.KEY_ESC: e.KEY_BACKSPACE,  # Back
    # The Flipper has no Home key. The app switcher is the key that leaves a hosted
    # app for flipctl's own screens, so Home is that.
    e.KEY_H: e.KEY_TAB,
    e.KEY_LEFTMETA: e.KEY_TAB,
    e.KEY_RIGHTMETA: e.KEY_TAB,
    e.KEY_P: e.KEY_C,  # Power, the middle soft key; hold for a long press
    e.KEY_F12: e.KEY_C,
    # Push-to-talk is KEY_A on the device, and A is now D-pad left.
    e.KEY_T: e.KEY_A,
}

MOUSE_BUTTONS = {
    e.BTN_LEFT: e.KEY_ENTER,  # OK
    e.BTN_RIGHT: e.KEY_BACKSPACE,  # Back
    e.BTN_MIDDLE: e.KEY_TAB,  # app switcher
    e.BTN_SIDE: e.KEY_BACKSPACE,  # the thumb "back" button
}
# (axis, direction of one notch) -> the button a notch taps
WHEEL = {
    (e.REL_WHEEL, 1): e.KEY_UP,
    (e.REL_WHEEL, -1): e.KEY_DOWN,
    (e.REL_HWHEEL, 1): e.KEY_RIGHT,
    (e.REL_HWHEEL, -1): e.KEY_LEFT,
}

# Flipper code -> the MCU's name for the key (furi_hal_resources_pins.c). The bottom
# row is esc, view, power, edit, run left to right, as Key1, Key2, Power, Key4, Key5.
MCU_KEY = {
    e.KEY_UP: "Up",
    e.KEY_DOWN: "Down",
    e.KEY_LEFT: "Left",
    e.KEY_RIGHT: "Right",
    e.KEY_ENTER: "OK",
    e.KEY_BACKSPACE: "Back",
    e.KEY_TAB: "Sw",
    e.KEY_A: "PTT",
    e.KEY_Z: "Key1",
    e.KEY_X: "Key2",
    e.KEY_C: "Power",
    e.KEY_V: "Key4",
    e.KEY_B: "Key5",
}

CTRL = {e.KEY_LEFTCTRL, e.KEY_RIGHTCTRL}
ALT = {e.KEY_LEFTALT, e.KEY_RIGHTALT}


def log(message):
    print(f"flipper-kbd-bridge: {message}", file=sys.stderr, flush=True)


def handheld_vt_in_front():
    with open(ACTIVE_VT) as f:
        return f.read().strip() == HANDHELD_VT


def is_keyboard(dev):
    keys = dev.capabilities().get(e.EV_KEY, [])
    return e.KEY_A in keys and e.KEY_ENTER in keys


def is_pointer(dev):
    # A mouse, or the absolute tablet VirtualBox and VMware give a guest.
    return e.BTN_LEFT in dev.capabilities().get(e.EV_KEY, [])


class Bridge:
    def __init__(self):
        self.out = evdev.UInput(
            {e.EV_KEY: list(range(e.KEY_ESC, e.KEY_MICMUTE + 1))},
            name=DEVICE_NAME,
            bustype=e.BUS_VIRTUAL,
        )
        self.sources = {}  # path -> grabbed InputDevice
        self.ignored = set()  # paths that are not keyboards, or are ours
        self.mods = set()  # Ctrl and Alt keys held
        self.held = {}  # PC code -> the code its press was sent as
        self.swallow = set()  # PC codes whose release must not be sent
        self.pressed = {}  # Flipper code -> [press time, long already published]
        self.mcu = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.mcu.setblocking(False)

    def scan(self):
        for path in evdev.list_devices():
            if path in self.sources or path in self.ignored:
                continue
            dev = evdev.InputDevice(path)
            if dev.name.startswith("Flipper One") or not (is_keyboard(dev) or is_pointer(dev)):
                self.ignored.add(path)
                dev.close()
                continue
            dev.grab()
            self.sources[path] = dev
            log(f"grabbed {path} ({dev.name})")

    def drop(self, path):
        dev = self.sources.pop(path)
        log(f"lost {path} ({dev.name})")
        dev.close()

    def remapping(self):
        return not self.mods and handheld_vt_in_front()

    def emit(self, code, value):
        self.out.write(e.EV_KEY, code, value)
        self.out.syn()

    def publish(self, code, kind):
        try:
            self.mcu.sendto(f"key: {MCU_KEY[code]} type: {kind}".encode(), MCU_EVENTS)
        except (FileNotFoundError, ConnectionRefusedError, BlockingIOError):
            # Nobody listening, or nobody keeping up: the dump is a debugging aid
            # and a press must never wait on it.
            pass

    def key(self, code, value):
        if code in CTRL | ALT:
            if value:
                self.mods.add(code)
            else:
                self.mods.discard(code)

        if code == e.KEY_D and value == 1 and self.mods & CTRL and self.mods & ALT:
            self.swallow.add(code)
            self.to_desktop()
            return
        if code in self.swallow:
            if value == 0:
                self.swallow.discard(code)
            return

        if code in MOUSE_BUTTONS:
            self.mouse_button(code, value)
            return

        # A release goes out as whatever its press went out as, whatever changed since.
        if value == 1:
            out = REMAP.get(code, code) if self.remapping() else code
            self.held[code] = out
            if out in MCU_KEY and self.remapping():
                self.pressed[out] = [time.monotonic(), False]
                self.publish(out, "Press")
        elif value == 0:
            out = self.held.pop(code, code)
            press = self.pressed.pop(out, None)
            if press is not None:
                self.publish(out, "Release")
                if not press[1]:
                    self.publish(out, "Short")
        else:
            out = self.held.get(code, code)
        self.emit(out, value)

    def mouse_button(self, code, value):
        # Held like a key, so holding the left button is a long OK. Off the handheld
        # VT there is nothing for a click to mean, and the grab keeps it from anyone else.
        if value == 1 and self.remapping():
            out = MOUSE_BUTTONS[code]
            self.held[code] = out
            self.pressed[out] = [time.monotonic(), False]
            self.publish(out, "Press")
            self.emit(out, 1)
        elif value == 0 and code in self.held:
            out = self.held.pop(code)
            press = self.pressed.pop(out, None)
            if press is not None:
                self.publish(out, "Release")
                if not press[1]:
                    self.publish(out, "Short")
            self.emit(out, 0)

    def wheel(self, axis, value):
        if not self.remapping():
            return
        out = WHEEL.get((axis, 1 if value > 0 else -1))
        for _ in range(abs(value)):
            self.emit(out, 1)
            self.emit(out, 0)
            for kind in ("Press", "Release", "Short"):
                self.publish(out, kind)

    def publish_long_presses(self):
        now = time.monotonic()
        for code, press in self.pressed.items():
            if not press[1] and now - press[0] >= LONG_PRESS_S:
                press[1] = True
                self.publish(code, "Long")

    def to_desktop(self):
        log("Ctrl+Alt+D: switching to desktop mode")
        for out in self.held.values():
            self.emit(out, 0)
        self.held.clear()
        self.pressed.clear()
        # Stops flipper-handheld.service, and this unit with it (PartOf), which
        # releases the grabs.
        subprocess.run(["systemctl", "--no-block", "start", "flipper-desktop.target"], check=True)

    def run(self):
        next_scan = 0.0
        while True:
            now = time.monotonic()
            if now >= next_scan:
                self.scan()
                next_scan = now + RESCAN_S
            timeout = min(next_scan - now, LONG_PRESS_S / 3) if self.pressed else next_scan - now
            ready, _, _ = select.select(list(self.sources.values()), [], [], max(timeout, 0))
            for dev in ready:
                try:
                    events = list(dev.read())
                except OSError:
                    self.drop(dev.path)
                    continue
                for ev in events:
                    if ev.type == e.EV_KEY:
                        self.key(ev.code, ev.value)
                    elif ev.type == e.EV_REL and ev.code in (e.REL_WHEEL, e.REL_HWHEEL) and ev.value:
                        self.wheel(ev.code, ev.value)
            self.publish_long_presses()


if __name__ == "__main__":
    if not os.path.exists("/dev/uinput"):
        sys.exit("flipper-kbd-bridge: no /dev/uinput (is the uinput module loaded?)")
    Bridge().run()
