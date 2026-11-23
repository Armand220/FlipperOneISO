#!/usr/bin/python3
"""Stand-in for the Flipper One's RP2350 MCU on a VM.

On the device the MCU reaches Linux through kernel drivers: buttons over the I2C
intercom at 0x69 into flipper-one-input.c and out as evdev, the battery through the
bq27xxx gauge as a power_supply, and a debug CLI on its UART. flipctl reads only the
kernel side, never the MCU directly, so that side is what this provides:

  battery   test_power's test_battery, held at 100% and charging; flipctl takes the
            first power_supply whose type is Battery
  buttons   a "Flipper One Software Buttons" uinput device, the name the real driver
            gives injected presses
  serial    a PTY linked at /dev/ttyFlipperMCU (group dialout) with the firmware
            CLI's `input` command:
              input dump                 stream button events, Ctrl+C to stop
              input send <key> <type>    inject one, e.g. `input send OK Short`
            plus `power` (the battery as flipctl sees it), `date` (the clock, which
            the VM's RTC already keeps) and `help`
"""

import grp
import os
import select
import socket
import subprocess
import sys
import time
import tty

import evdev
from evdev import ecodes as e

PTY_LINK = "/dev/ttyFlipperMCU"
EVENTS = "/run/flipper-mcu/events.sock"
SUPPLY = "/sys/class/power_supply/test_battery"
TEST_POWER = "/sys/module/test_power/parameters"
BATTERY = {
    "ac_online": "on",
    "usb_online": "off",
    "battery_present": "true",
    "battery_health": "good",
    "battery_status": "charging",
    "battery_capacity": "100",
}
PROMPT = b"\r\nmcu-mock> "
# applications/services/input/input.c: INPUT_PRESS_TICKS (150) * INPUT_LONG_PRESS_COUNTS (2)
LONG_PRESS_S = 0.300

# The MCU's key names (furi_hal_resources_pins.c) -> the code flipper-one-input.c
# sends for each (crates/flipper-ui/src/key.rs).
KEYS = {
    "Up": e.KEY_UP,
    "Down": e.KEY_DOWN,
    "Left": e.KEY_LEFT,
    "Right": e.KEY_RIGHT,
    "OK": e.KEY_ENTER,
    "Back": e.KEY_BACKSPACE,
    "Sw": e.KEY_TAB,
    "PTT": e.KEY_A,
    "Key1": e.KEY_Z,
    "Key2": e.KEY_X,
    "Power": e.KEY_C,
    "Key4": e.KEY_V,
    "Key5": e.KEY_B,
}
TYPES = ("Press", "Release", "Short", "Long")


def log(message):
    print(f"flipper-mcu-mock: {message}", file=sys.stderr, flush=True)


def start_battery():
    subprocess.run(["modprobe", "test_power"], check=True)
    for name, value in BATTERY.items():
        with open(f"{TEST_POWER}/{name}", "w") as f:
            f.write(value)
    log("test_battery at 100%, charging, on AC")


def open_pty():
    master, slave = os.openpty()
    tty.setraw(slave)
    os.set_blocking(master, False)
    node = os.ttyname(slave)
    os.chown(node, 0, grp.getgrnam("dialout").gr_gid)
    os.chmod(node, 0o660)
    if os.path.lexists(PTY_LINK):
        os.unlink(PTY_LINK)
    os.symlink(node, PTY_LINK)
    log(f"serial CLI on {PTY_LINK} -> {node}")
    # The slave stays open here, so a terminal closing it does not hang up the master.
    return master, slave


def open_events():
    if os.path.exists(EVENTS):
        os.unlink(EVENTS)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(EVENTS)
    sock.setblocking(False)
    return sock


class Mcu:
    def __init__(self):
        self.buttons = evdev.UInput(
            {e.EV_KEY: list(range(e.KEY_ESC, e.KEY_MICMUTE + 1))},
            name="Flipper One Software Buttons",
            bustype=e.BUS_VIRTUAL,
        )
        self.master, self.slave = open_pty()
        self.events = open_events()
        self.line = bytearray()
        self.dumping = False

    def write(self, data):
        try:
            os.write(self.master, data)
        except BlockingIOError:
            # Nobody has the PTY open, and its buffer is full: like a UART with
            # nothing on the other end, the bytes are gone.
            pass

    def say(self, text):
        self.write(text.replace("\n", "\r\n").encode())

    def event(self, key, kind):
        if self.dumping:
            self.say(f"key: {key} type: {kind}\n")

    def press(self, key, down):
        self.buttons.write(e.EV_KEY, KEYS[key], 1 if down else 0)
        self.buttons.syn()

    def inject(self, key, kind):
        if kind == "Press":
            self.press(key, True)
        elif kind == "Release":
            self.press(key, False)
        elif kind == "Short":
            self.press(key, True)
            self.press(key, False)
        else:
            self.press(key, True)
            time.sleep(LONG_PRESS_S)
            self.press(key, False)
        self.event(key, kind)

    def command(self, text):
        args = text.split()
        if not args:
            return
        if args[0] == "help":
            self.say(
                "input dump                 stream button events, Ctrl+C to stop\n"
                "input send <key> <type>    inject a button event\n"
                f"    <key> = {', '.join(KEYS)}\n"
                f"    <type> = {', '.join(TYPES)}\n"
                "power                      the battery as flipctl sees it\n"
                "date                       the clock (kept by the VM's RTC)\n"
            )
        elif args[:2] == ["input", "dump"]:
            self.dumping = True
            self.say("Press CTRL+C to stop\n")
        elif args[:2] == ["input", "send"] and len(args) == 4:
            if args[2] not in KEYS or args[3] not in TYPES:
                self.say(f"unknown key or type; keys: {', '.join(KEYS)}; types: {', '.join(TYPES)}\n")
            else:
                self.inject(args[2], args[3])
        elif args[0] == "power":
            for prop in ("status", "capacity", "health"):
                with open(f"{SUPPLY}/{prop}") as f:
                    self.say(f"{prop}: {f.read().strip()}\n")
        elif args[0] == "date":
            self.say(time.strftime("%Y-%m-%d %H:%M:%S %Z\n"))
        else:
            self.say(f"{args[0]}: unknown command, try help\n")

    def typed(self, data):
        for byte in data:
            if byte == 0x03:  # Ctrl+C
                self.dumping = False
                self.line.clear()
                self.write(PROMPT)
            elif self.dumping:
                continue
            elif byte in (0x0D, 0x0A):
                text = self.line.decode(errors="replace")
                self.line.clear()
                self.write(b"\r\n")
                self.command(text)
                if not self.dumping:
                    self.write(PROMPT)
            elif byte in (0x08, 0x7F):
                if self.line:
                    self.line.pop()
                    self.write(b"\b \b")
            elif 0x20 <= byte < 0x7F:
                self.line.append(byte)
                self.write(bytes([byte]))

    def run(self):
        self.write(PROMPT)
        while True:
            ready, _, _ = select.select([self.master, self.events], [], [])
            if self.master in ready:
                self.typed(os.read(self.master, 1024))
            if self.events in ready:
                text = self.events.recv(256).decode(errors="replace")
                # The bridge sends the firmware's own line, "key: Up type: Press".
                if self.dumping:
                    self.say(text + "\n")


if __name__ == "__main__":
    start_battery()
    Mcu().run()
