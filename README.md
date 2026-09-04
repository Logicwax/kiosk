# kiosk

A minimal, deterministic / reproducible, immutable, offline fully bootable disk image builder that boots straight into X11/Xorg and displays a hello-world HTML/Electron app in full screen with no way for a user to do anything but interact with the app.  All writes to disk are kept in RAM and never commited to disk; just reboot and you are back to a clean state (just like a live boot disk!).  Works great for building interactive airgapped cryptocurrency wallets, password managers, data viewers, kiosks, art installations, or anything else that requires a locked down "kiosk" experience in a reproducible way to mitigate centralized supply-chain risk (anyone can build and arrive at the same hash / byte-for-byte disk image).

Swap the contents of `app/src/` for whatever you want on screen.

The image is built **reproducibly**: independent builds of the same commit produce a
byte-identical `.img`.  Build in CI, at home, cloud VMs to all arrive at a signular hash to mitigate any concerns of backdoors being slipped in.  Compatible with secureboot (via debian shim) or bring your own key and do full unified kernel image signing with MOK enrollment or hash enrollment.

***Example Application:*** Checkout the [Portalwallet-airgap](https://github.com/Logicwax/PortalWallet-airgap) project for a real-world use-case of kiosk.

## Requirements

**`make setup` does all of this for you.** It checks what is already present,
installs what is missing, verifies you can reach the Docker daemon,
enables the Docker feature, and creates the pinned
builder — then verifies the result. It is idempotent, so re-running it on a
configured host reports OK and changes nothing. Anything that touches the host
(a package install, writing `/etc/docker/daemon.json`, restarting Docker) prints
what it will do and asks first; `FORCE=1 make setup` answers yes to all of them,
for unattended use. `daemon.json` is merged with `jq` and backed up, never
overwritten.

```bash
make setup
```

The manual equivalents are below, if you would rather do it yourself or need to
see exactly what `make setup` changes:

- Linux host with Docker
- **Your user must be in the `docker` group.** The daemon socket is
  `root:docker`, so having the `docker` CLI on `PATH` is not the same as being
  able to use it — without membership every build fails with a permission error
  on `/var/run/docker.sock`.

    ```bash
    sudo usermod -aG docker "$USER"
    ```

    Group changes do **not** apply to your current shell: log out and back in, or
    run `newgrp docker`, before building. (`make setup` checks this, offers to add
    you, and tells you to re-login.)
- **`containerd-snapshotter` enabled.** Create `/etc/docker/daemon.json` with:

    ```json
    {
      "features": {
        "containerd-snapshotter": true
      }
    }
    ```

    then `sudo systemctl restart docker`. Without it Docker uses the legacy
    graphdriver, which does not preserve image digests through `docker load`, so a
    locally built builder image can differ from the same image elsewhere.

- Buildx `docker-container` driver, with BuildKit pinned so the builder itself is
  not a moving part:

```bash
docker buildx create \
  --name reproducible-builder \
  --driver docker-container \
  --driver-opt image=moby/buildkit:v0.26.2 \
  --use && \
docker buildx inspect --bootstrap reproducible-builder
```

- `qemu-system-x86` + `ovmf` (only to boot-test), `jq`, `git`

```bash
sudo apt-get install docker.io qemu-system-x86 ovmf jq git
```

## Build

```bash
make build                      # -> build/kiosk-v<VERSION>.img
make verify                     # verify the untampered image
DISK=/dev/sdX make flash-disk   # write it to a USB stick
make test-boot                  # boot it in QEMU (for testing purposes)
```

## Boot chains

`BOOT` picks the boot chain; `BOOTSIGN` only applies to `BOOT=uki`.

| command | boot chain | Secure Boot on a stock laptop | reproducible |
|---|---|---|---|
| `make build` | **grub** (default) | ✅ boots, **nothing to enroll** | ✅ |
| `make build BOOT=uki` | unsigned UKI | ⚠️ needs a *hash* enroll, per image, per machine | ✅ |
| `make build BOOT=uki BOOTSIGN=yes` | signed UKI | ⚠️ needs a *certificate* enroll, once per machine | ❌ |

**`BOOT=grub`** ships the stock Debian chain, every link signed by a key the machine
already trusts:

```
firmware ──db(Microsoft CA)──▶ BOOTX64.EFI = Debian's MS-signed shim
shim     ──embedded Debian cert──▶ grubx64.efi = Debian's signed GRUB
GRUB     ──SHIM_LOCK, back into shim──▶ vmlinuz = Debian's signed kernel
```

> [!NOTE]
> GRUB verifies only the **kernel**;
`EFI/debian/grub.cfg` and `initrd.img` sit unverified on the FAT ESP.  This is a limitation of
> any debian-based secureboot system.

**`BOOT=uki`** seals kernel + initrd + cmdline into one EFI-stub binary, so a single
signature covers all three (Which then requires MOK enrollment at first boot, using the
included/integrated Mokutil), because shim does not trust a custom chosen
key.

`BOOTSIGN=yes` needs `os-builder/secureboot/kiosk.{key,crt}` (make one with
`make secureboot-key`).

> [!NOTE]
> Only `BOOTSIGN=yes` is non-reproducible: an Authenticode
signature embeds a signing timestamp which is mutually exclusive with full image reproducibility.

## Reproducibility

Every input is pinned in a committed lock file:

| What | Where |
|---|---|
| Base image digest | `*/lock/debian-img-hash-lock.txt` |
| apt sources + snapshot date | `*/lock/debian.sources` |
| Builder toolchain versions/hashes | `*/lock/build-toolchain-*-lock.*` |
| Packages shipped in the image | `os-builder/lock/rootfs-pkgs-*-lock.*` |

#### Refreshing the dependency locks

> ### `make update-deps`
>
> Refreshes every lock above, in dependency order — each step is resolved inside an
> image built by the previous one, so they cannot be run in parallel or reordered.
>
> ```bash
> make update-deps
> git diff */lock/          # ALWAYS review before committing
> ```

Individual steps, if you only need one: `base-image-update`, `builder-update`,
`os-builder-update`, `rootfs-update`.

#### Adding or removing a package

> ### `edit` → `make rootfs-update` → `make build`
>
> 1. edit `os-builder/rootfs-packages.list`
> 2. **`make rootfs-update`** — re-resolves the closure and rewrites both locks
> 3. `make build`
>
> **Step 2 is not optional and its absence is silent.** The build installs the
> package set from `rootfs-pkgs-version-lock.list`, never from
> `rootfs-packages.list`, so a package added without relocking simply never appears
> in the image — and the build still succeeds.

App dependencies (`app/yarn.lock`) are deliberately **not** part of `update-deps`.


## Attestation

Every build writes `attestation/manifest.txt` — the sha256 of the `.deb` and the
`.img`. Whoever builds can sign it, and anyone can re-check those signatures later.

```bash
make build          # writes attestation/manifest.txt
make sign           # signs it -> attestation/signatures/manifest.<KEYID>.asc
make verify         # re-checks every signature against the current manifest
```

```bash
make clean build verify
```

Signatures are verified in an **isolated keyring built only from
`attestation/signers/`**, so a signature from any other key is reported as
`NOT A SIGNER` and does not count.

A rebuild that produces different artifacts rewrites the manifest and **purges the
signatures** — they attest to bytes that no longer exist.

## What gets built, in what order

Two builder images and two build scripts:

```
              debian@sha256:…  (pinned base, one digest for both)
                      │
        ┌─────────────┴─────────────┐
        ▼                           ▼
 kiosk-deb-builder     kiosk-os-builder
  (Node, yarn, electron-      (mmdebstrap, ansible, squashfs,
   forge — version-locked)     dracut, shim, GRUB, ukify, genimage)
        │                           │
        ▼                           │
 deb-builder/build-deb.sh           │
        │                           ▼
        └──▶ kiosk_*.deb ──▶ os-builder/build-os.sh ──▶ kiosk-v*.img
```

1. **Build `kiosk-deb-builder`** — Debian base pinned by digest, toolchain from
   `deb-builder/lock/`.
2. **Compile the app** — sources are copied into a scratch dir *inside* the
   container (never the mounted tree), then `yarn install --immutable` and
   electron-forge produce a `.deb`.
3. **Build `kiosk-os-builder`** — same pinned base, image-build toolchain.
4. **Assemble the image** — `mmdebstrap` bootstraps a Debian rootfs from exact,
   hash-verified package versions; the `.deb` is installed into it; Ansible
   configures it over a `chroot` connection; `mksquashfs` packs the read-only root
   (**this is where all file timestamps are normalized**); the boot chain is staged
   per `BOOT`; `genimage` assembles the GPT disk with fixed UUIDs.

The result is a **UEFI-only live image**: a FAT ESP plus a read-only squashfs root.
All writes go to a tmpfs overlay (`rootovl`), so every boot starts clean and nothing
on the USB is ever modified. The app runs as **`airgap`**, autologin on tty1, which
`exec startx`s straight into `/usr/bin/kiosk` with **no window manager** (Electron sizes
its own full-screen window).

## Layout

```
Makefile                    # build / flash / test-boot / lock-update targets
VERSION                     # image version string
app/                        # minimal Electron app (main.js + src/)
deb-builder/                # pinned builder image that compiles the app -> .deb
  Dockerfile, build-deb.sh, pkgs.list, lock/, scripts/
os-builder/                 # pinned builder image that assembles the OS image
  Dockerfile, build-os.sh
  genimage-grub.cfg         # ESP layout for BOOT=grub
  genimage-uki.cfg          # ESP layout for BOOT=uki
  rootfs-packages.list      # what ships INSIDE the image
  ansible/                  # roles: common -> kiosk -> cleanup (config only)
  lock/, scripts/, secureboot/
```
