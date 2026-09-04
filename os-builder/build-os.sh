#!/usr/bin/env bash
# Build the complete kiosk disk image, start to finish, inside the container.
#
#   mmdebstrap  -> Debian rootfs from the pinned live+snapshot sources
#   kiosk.deb   -> the reproducible Electron app package (built separately by
#                  the deb-builder image; consumed here)
#   configure-rootfs.sh -> users, autologin, dracut, X session, cleanup
#   mksquashfs  -> read-only compressed root
#   ukify       -> UKI: kernel + initramfs + cmdline in one EFI-stub binary
#   genimage    -> GPT disk with fixed UUIDs
#
# The rootfs and all scratch live in /build — the container's OWN filesystem,
# never a bind mount — so nothing root-owned is ever written to the host. The
# ONLY thing crossing back out is the finished .img, chowned to the caller.
set -euo pipefail

REPO=/repo
WORK=/build
ROOTFS="$WORK/rootfs"
OUT="$REPO/build"
: "${SOURCE_DATE_EPOCH:=1}"
export SOURCE_DATE_EPOCH

VERSION="${1:-dev}"

# Must match the root partition-uuid in os-builder/genimage-*.cfg (both modes).
ROOT_PARTUUID=c105c0de-0000-4000-8000-000000000003
# Shown by GRUB as it boots (BOOT=grub only — a UKI has no menu). GRUB echoes
# "Booting `<title>'", so this is the string users see on the boot screen.
BOOT_TITLE="kiosk"

# Carried over from the old GRUB config, minus GRUB itself.
# `rootovl` is what gives the read-only root + tmpfs overlay (reset on reboot).
CMDLINE="root=PARTUUID=${ROOT_PARTUUID} rootfstype=squashfs rootovl quiet splash loglevel=0 console=ttyS0,115200 earlyprintk=ttyS0,115200 nofb"

KIOSK_DEB="$REPO/build/kiosk_${VERSION}_amd64.deb"
if [ ! -f "$KIOSK_DEB" ]; then
	echo "ERROR: $KIOSK_DEB not found — run 'make deb-package' first" >&2
	echo "       (found instead: $(ls "$REPO"/build/*.deb 2>/dev/null | tr '\n' ' ' || echo none))" >&2
	exit 1
fi
echo "Using app package: $(basename "$KIOSK_DEB")"
# Warn loudly if other versions are lying around — they are not being installed,
# but their presence usually means a stale build/ that should be cleaned.
_other="$(ls "$REPO"/build/kiosk_*_amd64.deb 2>/dev/null | grep -v "^$KIOSK_DEB$" || true)"
[ -z "$_other" ] || echo "WARNING: ignoring other .deb(s) in build/: $(echo "$_other" | xargs -n1 basename | tr '\n' ' ')"

rm -rf "$WORK"; mkdir -p "$ROOTFS"

# ---------------------------------------------------------------------------
# 1. rootfs
# ---------------------------------------------------------------------------
# Package set for the image: the LOCK, and only the lock (exact pkg=version for
# the full resolved closure). --variant=custom installs exactly this list, so it
# defines the whole rootfs; with bare names apt would take the highest version
# across the live+snapshot sources, so any
# Debian security update would silently change the image. Regenerate the lock
# deliberately with `make rootfs-pkgs-update`.
LOCKFILE="$REPO/os-builder/lock/rootfs-pkgs-version-lock.list"
if [ -s "$LOCKFILE" ]; then
	PKG_LIST="$(grep -vE '^\s*(#|$)' "$LOCKFILE" | paste -sd, -)"
	echo "==> using pinned rootfs package versions ($(grep -cvE '^\s*(#|$)' "$LOCKFILE") packages)"
else
	# No fallback: under --variant=custom the lock IS the package set, so building
	# without it would silently install only the handful of names in
	# rootfs-packages.list and produce a broken rootfs that still "succeeded".
	echo "ERROR: no rootfs version lock at $LOCKFILE." >&2
	echo "       Run 'make rootfs-pkgs-update' first — it discovers the package set" >&2
	echo "       with --variant=important and records it for --variant=custom." >&2
	exit 1
fi


# --variant=custom: install EXACTLY the --include list. The base set is then our
# lock file rather than whatever Debian currently flags Essential/required, so an
# upstream promotion or demotion cannot change what we ship — or fail a release
# build. rootfs-update still uses --variant=important to DISCOVER the closure.
#
# --mode=unshare. NOTE: --mode=root was tried and does NOT work at full scale:
# with no extra caps dpkg dies ("Can not write log (Is /dev/pts mounted?)")
# because root mode must bind-mount /dev/pts for maintainer scripts, and adding
# CAP_SYS_ADMIN makes mmdebstrap fail differently (signal PIPE during setup).
# unshare mode + the flags the Makefile passes is the config that actually works.
# NOTE on the `trixie` argument below: mmdebstrap takes SUITE TARGET [MIRROR...].
# Because we pass an explicit deb822 sources file as MIRROR, that file governs
# package resolution AND is copied verbatim into the target's apt config — the
# SUITE is inert (verified: passing 'bookworm' still produced a trixie rootfs).
# It is positionally required, so keep it matching rootfs-debian.sources; nothing will
# warn you if the two drift apart.
echo "==> mmdebstrap: bootstrapping rootfs"
# Hash enforcement: with --variant=custom mmdebstrap downloads the whole locked
# set in one go before installing anything, so every .deb is present at
# --extract-hook and one exact check covers all of them. (Under --variant=important
# there were two phases with the cache wiped between them, needing a lock each.)
HASHLOCK="$REPO/os-builder/lock/rootfs-pkgs-hash-lock.txt"

mmdebstrap \
	--mode=unshare \
	--variant=custom \
	--format=directory \
	--include="$PKG_LIST" \
	--aptopt='APT::Keep-Downloaded-Packages "true"' \
	--extract-hook="/repo/os-builder/scripts/rootfs-verify-deb-pkgs \"\$1\" '$HASHLOCK' rootfs" \
	--customize-hook="copy-in $KIOSK_DEB /tmp" \
	--customize-hook="chroot \"\$1\" apt-get install -y --no-install-recommends /tmp/$(basename "$KIOSK_DEB")" \
	--customize-hook="chroot \"\$1\" rm -f /tmp/$(basename "$KIOSK_DEB")" \
	trixie \
	"$ROOTFS" \
	"$REPO/os-builder/lock/rootfs-debian.sources"

# Composition check: rootfs-verify-deb-pkgs proved every downloaded .deb was locked; this
# proves the rootfs ended up holding exactly the locked set. The app .deb is the
# one sanctioned addition — it is copied in and dpkg-installed, so it never passes
# through the hash lock.
APP_PKG="$(dpkg-deb -f "$KIOSK_DEB" Package)=$(dpkg-deb -f "$KIOSK_DEB" Version)"
# Deliberately checked HERE, before configure-rootfs.sh. The locks describe what
# mmdebstrap is allowed to bring in; configuration afterwards is free to add or
# remove packages without tripping a lock.
"$REPO/os-builder/scripts/rootfs-verify-installed-pkgs" "$ROOTFS" "$LOCKFILE" "$APP_PKG" "after mmdebstrap, before configure"

# ---------------------------------------------------------------------------
# 2. configuration (configure-rootfs.sh, plain bash against $ROOTFS)
# ---------------------------------------------------------------------------
echo "==> configure: applying rootfs configuration"
# The roles are pure configuration: the package set was installed by mmdebstrap
# from rootfs-pkgs-version-lock.list and already verified above, and boot is
# assembled by ukify/grub+genimage below. Anything the roles add or remove after
# this point is deliberately outside the locks.
#
# Temporary resolv.conf so any task needing the network can resolve; removed
# again below so no host DNS config is baked into the image.
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

# Minimal device nodes. The chroot has no /dev of its own, so tools
# that need them fail (git: "unable to get random bytes" without /dev/urandom).
# Created with mknod at their fixed, well-known major/minor numbers — universal
# on every Linux system, so they add NO host coupling. They also legitimately
# belong in the image; devtmpfs overmounts /dev at boot anyway.
rm -f "$ROOTFS/dev/null"
mkdir -p "$ROOTFS/dev"
mknod -m 666 "$ROOTFS/dev/null"    c 1 3
mknod -m 666 "$ROOTFS/dev/zero"    c 1 5
mknod -m 666 "$ROOTFS/dev/full"    c 1 7
mknod -m 666 "$ROOTFS/dev/random"  c 1 8
mknod -m 666 "$ROOTFS/dev/urandom" c 1 9
mknod -m 666 "$ROOTFS/dev/tty"     c 5 0

cd "$REPO"
# The app user. Passed to the configure script rather than hardcoded inside it.
APP_USER="airgap"

"$REPO/os-builder/configure-rootfs.sh" "$ROOTFS" "$APP_USER"

rm -f "$ROOTFS/etc/resolv.conf"

# mmdebstrap copies the BUILD CONTAINER's hostname (a random Docker container
# ID) into the rootfs — pure host coupling that changes every build. Pin it to
# the same name the old preseed flow used.
echo kiosk > "$ROOTFS/etc/hostname"
# Drop build-time entropy/state that must not be baked into the image.
rm -f "$ROOTFS/etc/machine-id" "$ROOTFS/var/lib/dbus/machine-id"
: > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/systemd/random-seed"
echo "==> rootfs ready ($(du -sh "$ROOTFS" 2>/dev/null | cut -f1))"

# ---------------------------------------------------------------------------
# 3. image assembly
# ---------------------------------------------------------------------------
# Exactly one kernel is expected. `ls | head -1` would silently pick the
# alphabetically-first of several — the same failure shape as the .deb selection
# above, where a stale package was chosen without a word. Fail closed instead.
# (It also avoids a SIGPIPE-prone pipeline now that pipefail is on.)
mapfile -t _kvers < <(ls "$ROOTFS"/lib/modules)
if [ "${#_kvers[@]}" -ne 1 ]; then
	echo "ERROR: expected exactly one kernel in /lib/modules, found ${#_kvers[@]}: ${_kvers[*]-none}" >&2
	exit 1
fi
KVER="${_kvers[0]}"
echo "==> kernel $KVER"

# NOTE: the output FILENAMES here are the contract with the genimage config — it
# resolves them BY NAME inside --inputpath ($WORK), so renaming an output here means
# renaming it in os-builder/genimage-*.cfg too.
#
# ORDER MATTERS: the kernel + initramfs must be read out of $ROOTFS/boot BEFORE
# /boot is stripped below, and that strip must happen BEFORE mksquashfs packs the
# tree.
#
# Two boot chains, selected by KIOSK_BOOT (`make BOOT=...`).
#   grub (default) — the stock Debian chain: MS-signed shim -> Debian-signed GRUB ->
#                    Debian-signed kernel (verified through the SHIM_LOCK protocol,
#                    which calls back into the still-resident shim). Boots on a
#                    stock laptop with Secure Boot ON and NO enrollment. The catch:
#                    GRUB verifies only the KERNEL — grub.cfg and initrd.img sit
#                    unverified on the FAT ESP.
#
#   uki            — kernel + initrd + cmdline sealed into a single EFI-stub binary,
#                    so all three are covered by one signature. Costs a one-time
#                    MokManager enrollment per machine, because shim does not trust
#                    our key: the certificate if signed (BOOTSIGN=yes), or the binary's
#                    hash if not.
BOOT_MODE="${KIOSK_BOOT:-grub}"

# Debian's MS-signed shim is the first stage in BOTH modes; MokManager rides along
# so a verification failure lands somewhere useful instead of a dead end.
cp /usr/lib/shim/shimx64.efi.signed "$WORK/shimx64.efi"
cp /usr/lib/shim/mmx64.efi.signed   "$WORK/mmx64.efi"

case "$BOOT_MODE" in
grub)
	if [ "${KIOSK_BOOTSIGN:-no}" != "no" ]; then
		echo "ERROR: BOOTSIGN=${KIOSK_BOOTSIGN} is meaningless with BOOT=grub — nothing of ours" >&2
		echo "       is signed there (shim, GRUB and the kernel are signed by Debian)." >&2
		echo "       Use 'make BOOT=uki BOOTSIGN=yes' to sign, or drop BOOTSIGN." >&2
		exit 1
	fi
	echo "==> boot: Debian shim -> Debian-signed GRUB -> Debian-signed kernel"
	echo "    (Secure Boot works with no enrollment; initrd + cmdline are NOT verified)"
	cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed "$WORK/grubx64.efi"
	cp "$ROOTFS/boot/vmlinuz-$KVER"    "$WORK/vmlinuz"
	cp "$ROOTFS/boot/initrd.img-$KVER" "$WORK/initrd.img"
	# GRUB sets $root to the partition grub.cfg was loaded from (the ESP), so the
	# kernel/initrd paths here are relative to that partition. The cmdline is the
	# same $CMDLINE the UKI would bake in — one definition, two carriers.
	cat > "$WORK/grub.cfg" <<-EOF
		set default=0
		set timeout=0

		menuentry '$BOOT_TITLE' {
		    linux /vmlinuz $CMDLINE
		    initrd /initrd.img
		}
	EOF
	GENIMAGE_CFG=genimage-grub.cfg
	;;
uki)
	# KIOSK_BOOTSIGN defaults to "no" (matching `BOOTSIGN ?= no` in the Makefile): builds are
	# UNSIGNED unless signing is explicitly requested, so that any two builds of the
	# same commit are byte-identical. An Authenticode signature embeds a signing
	# time, so a signed image can never be byte-reproducible.
	SB_KEY=/secureboot/kiosk.key
	SB_CRT=/secureboot/kiosk.crt
	# `auto` was the original value, meaning "sign if a key happens to be there". That
	# fails open — a release build without the key produced an UNSIGNED image and still
	# exited 0. It is now a deprecated alias for `yes`, which fails closed.
	BOOTSIGN_MODE="${KIOSK_BOOTSIGN:-no}"
	if [ "$BOOTSIGN_MODE" = "auto" ]; then
		echo "WARNING: BOOTSIGN=auto is deprecated — use BOOTSIGN=yes (same intent, but it now" >&2
		echo "         fails if the signing key is missing instead of silently not signing)." >&2
		BOOTSIGN_MODE=yes
	fi
	if [ "$BOOTSIGN_MODE" = "no" ]; then
		SB_KEY=/nonexistent
		SB_CRT=/nonexistent
	elif [ ! -r "$SB_KEY" ] || [ ! -r "$SB_CRT" ]; then
		echo "ERROR: BOOTSIGN=yes but no readable signing key at /secureboot." >&2
		echo "       Expected kiosk.key + kiosk.crt (mounted from os-builder/secureboot/)." >&2
		echo "       Run 'make secureboot-key' for a dev pair, or build with BOOTSIGN=no." >&2
		exit 1
	fi
	SIGN_ARGS=()
	if [ -r "$SB_KEY" ] && [ -r "$SB_CRT" ]; then
		echo "==> boot: signed UKI (enroll EFI/kiosk.der once per machine via MokManager)"
		SIGN_ARGS=(--signtool=sbsign --secureboot-private-key="$SB_KEY" --secureboot-certificate="$SB_CRT")
	else
		echo "==> boot: UNSIGNED UKI — BOOTSIGN=no (default), key (if any) untouched"
		echo "    (reproducible mode; Secure Boot needs a per-image hash enroll)"
	fi

	echo "==> ukify: kernel + initramfs + cmdline -> EFI-stub binary"
	ukify build \
		--linux="$ROOTFS/boot/vmlinuz-$KVER" \
		--initrd="$ROOTFS/boot/initrd.img-$KVER" \
		--cmdline="$CMDLINE" \
		--stub=/usr/lib/systemd/boot/efi/linuxx64.efi.stub \
		"${SIGN_ARGS[@]}" \
		--output="$WORK/BOOTX64.EFI"

	# Our certificate in DER form, so the user can enroll it straight off the ESP.
	if [ -r "$SB_CRT" ]; then
		openssl x509 -in "$SB_CRT" -outform DER -out "$WORK/kiosk.der"
	else
		: > "$WORK/kiosk.der"   # placeholder; genimage requires the file to exist
	fi
	GENIMAGE_CFG=genimage-uki.cfg
	;;
*)
	echo "ERROR: unknown BOOT mode '$BOOT_MODE' (expected: grub, uki)" >&2
	exit 1
	;;
esac

# The kernel and initramfs now live on the ESP (p1) in both modes — inside the UKI,
# or as plain files GRUB loads — so the copies in the rootfs are dead weight
# (~41 MB); neither boot path ever reads /boot.
# Safe because dracut has already run (configure, above) and /lib/modules, which
# IS needed at runtime for module loading, is untouched.
echo "==> trimming /boot from the rootfs (kernel now lives on the ESP)"
rm -f "$ROOTFS"/boot/vmlinuz-* "$ROOTFS"/boot/initrd.img-*

echo "==> mksquashfs: packing read-only root"
# THIS is where file timestamps get normalized. Nothing upstream tries to control
# them: mmdebstrap unpacks and configure edits files with whatever wall-clock time the
# container happens to have, so every file in $ROOTFS carries a build-time mtime.
# Those mtimes never reach the image — `-reproducible` plus SOURCE_DATE_EPOCH (=1,
# set as an ENV in the builder image) makes mksquashfs stamp every inode with that
# fixed epoch instead of what is on disk, along with the filesystem creation time.
# Verified: all ~27.5k files in the packed rootfs share the single timestamp
# 1970-01-01 00:00:01 UTC.
#
# Normalizing once here, at the boundary, is deliberate: the alternative is chasing
# timestamps through every configure step and package postinst that writes a file, and
# missing one silently costs you reproducibility.
mksquashfs "$ROOTFS" "$WORK/rootfs.squashfs" \
	-noappend -no-progress \
	-comp zstd \
	-reproducible

# Consumes, BY NAME from --inputpath: rootfs.squashfs (p2) and BOOTX64.EFI
# (copied into the FAT ESP it builds as p1).
echo "==> genimage: assembling GPT disk (fixed UUIDs)"
mkdir -p "$WORK/gtmp" "$WORK/groot"
# The ESP needs a DIFFERENT epoch from the squashfs above. FAT stores timestamps
# relative to 1980, so SOURCE_DATE_EPOCH=1 (1970) is unrepresentable and mtools
# wraps it far into the future (observed: 2098) — and a future timestamp on the
# ESP is something GRUB does not like and will refuse to boot from. So the FAT
# side uses 1980-01-01 (315561600) while the squashfs side keeps
# epoch 1: two layers, two fixed epochs, each forced by what the filesystem format
# can represent. The genimage config pins the rest of the FAT nondeterminism —
# mkfs.vfat --invariant (no random volume id) and fixed disk/partition UUIDs.
SOURCE_DATE_EPOCH=315561600 \
genimage \
	--config "$REPO/os-builder/$GENIMAGE_CFG" \
	--inputpath "$WORK" \
	--outputpath "$WORK" \
	--rootpath "$WORK/groot" \
	--tmppath "$WORK/gtmp"

# ---------------------------------------------------------------------------
# 4. hand the finished image back (the only thing that leaves the container)
# ---------------------------------------------------------------------------
mkdir -p "$OUT"
IMG="$OUT/kiosk-v${VERSION}.img"
mv "$WORK/kiosk.img" "$IMG"
chown "${HOST_UID:-0}:${HOST_GID:-0}" "$IMG"

# Debug escape hatch: KEEP_ROOTFS=1 also exports the rootfs as a tar so it can
# be inspected on the host. Off by default — the rootfs normally dies with the
# container, which is the point (nothing root-owned lands on the host).
if [ "${KEEP_ROOTFS:-0}" = "1" ]; then
	tar -C "$ROOTFS" --numeric-owner --sort=name -cf "$OUT/rootfs.tar" .
	chown "${HOST_UID:-0}:${HOST_GID:-0}" "$OUT/rootfs.tar"
	echo "==> rootfs exported: $OUT/rootfs.tar"
fi

echo "==> image ready: $IMG"
ls -lh "$IMG"
sha256sum "$IMG"
