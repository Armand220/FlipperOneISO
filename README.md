# FlipperOneISO

A bootable **x86_64 live ISO of the Flipper One OS** for VirtualBox or VMware. It is
Debian 13 (trixie) with Flipper's own UI, **flipctl**, compiled for x86_64, and two boot
modes:

- **Flipper One Mode (Handheld UI)**: flipctl alone on screen, scaled up by whole pixels,
  with the PC keyboard and mouse acting as the Flipper's buttons.
- **Flipper One Desktop Mode (External Monitor)**: Flipper's KDE Plasma desktop profile,
  with flipctl running in the background and its browser view on `http://localhost:8899`.

Everything Flipper-made comes from Flipper's repositories, unmodified:

| Repository | Used for |
|---|---|
| [flipperone-linux-build-scripts](https://github.com/flipperdevices/flipperone-linux-build-scripts) | package lists, `overlays/` (configs, KDE profile, wallpaper) |
| [flipctl-slint](https://github.com/flipperdevices/flipctl-slint) | flipctl, built natively for x86_64 with the same features as the device |
| [flipctl-apps](https://github.com/flipperdevices/flipctl-apps) | the app catalogue; its prebuilt apps are baked into the ISO |

This repository adds only the amd64 build script and `overlays/amd64-vm`.

## Build

On a Debian 13 amd64 machine or a WSL2 Debian 13 distro, in the Linux filesystem (not
under `/mnt/c`):

```sh
mkdir -p ~/flipperone-workspace && cd ~/flipperone-workspace
for r in flipperone-linux-build-scripts flipctl-slint flipctl-apps; do
    git clone --depth 1 https://github.com/flipperdevices/$r.git
done
git clone https://github.com/Armand220/FlipperOneISO.git

sudo bash FlipperOneISO/setup-host.sh                 # once: build tools, Rust from backports
cp -r FlipperOneISO/build-iso-amd64.sh FlipperOneISO/overlays flipperone-linux-build-scripts/
cd flipperone-linux-build-scripts
sudo ./build-iso-amd64.sh
```

The ISO lands in `out/flipperone-amd64.iso`. Under WSL it is also copied to the Windows
Desktop (`EXPORT_DIR` overrides where). A build takes about 15 to 20 minutes, most of it
the Debian and KDE install and flipctl's single-threaded LTO link.

It uses mmdebstrap and chroot, not debos: debos needs `/dev/kvm` for its fakemachine,
which WSL2 does not have.

## Run

Make a VM with **no disk**, **4 GB RAM** or more (2 GB is enough for handheld mode),
**VMSVGA** graphics, and the ISO in the optical drive. Log in as `user` / `user`. It is
a live system, so nothing persists across reboots.

The handheld screen appears once the system has booted. Under VirtualBox on a Windows
host with Hyper-V enabled (as WSL2 enables it), that can take a minute or two. Keys pressed
on the boot console before then do nothing.

## Controls (handheld mode)

The keycodes are the ones Flipper's input driver sends (`flipctl-slint`,
`crates/flipper-ui/src/key.rs`).

| Flipper One | Keyboard | Mouse |
|---|---|---|
| D-pad | Arrows, or W A S D | wheel (tilt for left/right) |
| OK | Enter, Space | left click |
| Back | Backspace, Esc | right click, thumb button |
| App switcher | Tab, H, Windows key | middle click |
| Soft keys, left to right (Esc, View/Menu, Power, Edit, Run) | Z X C V B | |
| Power | also P, F12 | |
| Push-to-talk | T | |
| Switch to desktop mode | Ctrl+Alt+D | |

On the home screen only **X** (Menu) and **B** do anything. On the text-input screen, **B**
is Done (only once a Wi-Fi password is 8 to 63 characters long), **Z** is Cancel, and **V**
deletes a character. Ctrl+Alt+F2 opens a text console.

## What `overlays/amd64-vm` adds

- **Boot modes**: `flipper-boot-mode` reads `flipper.mode=` from the kernel command line
  and starts `flipper-handheld.service` (sway kiosk + `flipctl --wayland`) or
  `flipper-desktop.target` (sddm + `flipctl --headless`).
- **Keyboard and mouse bridge** (`flipper-kbd-bridge.py`): grabs the VM's keyboard and
  mouse and re-emits them as a `Flipper One Buttons` uinput device.
- **MCU stand-in** (`flipper-mcu-mock.py`): a battery at 100% and charging (the kernel's
  `test_power`, built out of tree because Debian's amd64 kernel lacks it), a
  `Flipper One Software Buttons` device, and a serial CLI on `/dev/ttyFlipperMCU` that
  speaks the MCU firmware's `input dump` / `input send`.
- **Simulated Wi-Fi**: `mac80211_hwsim` radios plus a `FlipperOne-Lab` access point
  (password `flipperone`) in its own network namespace, routed to the VM's internet.
- **Flipper's prebuilt apps**: the catalogue's aarch64 AppImages, run through
  `qemu-user-binfmt`, with a binfmt rule for the AppImage header and the arm64 system
  libraries they expect from the device.

## Limits

- The catalogue's 9 script apps (`.py` / `.js`) are not included. Their runtimes run the
  system's x86 Python or Node, which cannot load the runtimes' aarch64 drawing library.
- Apps are emulated, so they start more slowly than on a Flipper. If flipctl says one
  "drew nothing", press Tab to switch to it.
- USB, FPV and SDR apps open but have no Flipper hardware to talk to.
- The `test_power` module is unsigned, so the battery is missing if Secure Boot is on in
  the VM.
