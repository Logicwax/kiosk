# kiosk

A disk image builder that builds a minimal, bare-bones Debian disk image that boots straight into X11/Xorg and
displays a "hello world" HTML page inside a tiny Electron app as a full screen kiosk interface.  No options for users to do anything else other than interact with your webapp!

It is built using Packer + a preseeded Debian netinst + Ansible and launches an
Electron app that has all web assets packed.

## What it does

- Preseeded Debian 13 (trixie) netinst install via Packer/QEMU
- Read-only root overlay (dracut), EFI + legacy GRUB, serial console
- Autologin as the **`airgap`** user on tty1, which `exec startx`'s into X
- X session = the packaged Electron binary `/opt/kiosk/kiosk`, run directly
  from `.xinitrc` with **no window manager** (Electron fullscreens its own
  window), rendering `app/src/index.html`

The Electron app lives in `app/` — a hello-world `index.html` + `style.css`
loaded by `main.js` in a frameless, full-screen, kiosk-mode `BrowserWindow`.
Node.js is installed only to package the app at build time (`yarn run package`)
and is removed again in the `cleanup` role. Swap the contents of `app/src/` for
whatever you want the kiosk to display.

## Layout

```
Makefile                         # build / flash / test-boot targets
VERSION                          # image version string
app/                             # minimal Electron app (main.js + src/ page)
packer/build.json                # Packer template (QEMU builder + ansible)
packer/preseed.cfg               # Debian installer preseed
ansible/main.yml                 # roles: common -> kiosk -> cleanup
ansible/roles/common/            # shared base
ansible/roles/kiosk/             # X libs + Node, builds & launches Electron app
ansible/roles/cleanup/           # disable ssh, drop build deps + Node, trim
ansible/templates/               # autologin.conf, xorg.conf
```

## Requirements

- Debian/Ubuntu host with QEMU + KVM
- `ovmf`, `ansible`, `packer`, `jq`, `curl`

```bash
sudo apt-get install qemu-system-x86 qemu-utils ovmf ansible packer jq curl
packer plugins install github.com/hashicorp/qemu
packer plugins install github.com/hashicorp/ansible
```

## Build

```bash
make            # -> build/kiosk-v<VERSION>.raw (+ .raw.gz)
```

## Test in a VM

```bash
make test-boot          # EFI
make test-boot-legacy   # legacy BIOS
```

## Flash to a disk

```bash
DISK=/dev/sdX make flash-disk
```


## Config Notes

If you experience build errors from your app ballooning in size, adjust `disk_size` in `packer/build.json` accordingly.