.PHONY: \
	all \
	base-image-update \
	build \
	boot-check \
	build-deb-check \
	builder-update \
	check-buildx-driver \
	clean \
	deb-package \
	distclean \
	flash-disk \
	os-builder \
	os-builder-update \
	os-image \
	rootfs-update \
	secureboot-key \
	sign \
	verify \
	setup \
	test-boot \
	update-deps

SHELL=/bin/bash
BUILD_VERSION := $(strip $(shell node -p "require('./app/package.json').version"))

# Boot chain.
#   grub (default) — stock Debian chain: MS-signed shim -> Debian-signed GRUB ->
#                    Debian-signed kernel. Boots with Secure Boot ON and NO
#                    enrollment. GRUB verifies only the kernel, so grub.cfg and
#                    initrd sit unverified on the ESP.
#   uki            — kernel + initrd + cmdline sealed into one EFI-stub binary.
#                    Requires a one-time MokManager enrollment per machine.
BOOT ?= grub

# Secure Boot signing of the UKI (NOT the GPG release signing that `make sign`
# does — that is a separate thing). Applies to BOOT=uki ONLY; the build errors
# out if it is set with BOOT=grub, where nothing of ours is signed.
# UNSIGNED BY DEFAULT so that any two builds of the same commit produce a
# byte-identical image: an Authenticode signature embeds a signing time, so
# a signed image can never be byte-reproducible.
#   no (default) — never sign; any key on disk is ignored and left untouched
#   yes          — sign; FAILS if the signing key is missing (never silently
#                  downgrades to unsigned, which is what the old `auto` did)
BOOTSIGN ?= no

# Optional: pin the build containers to a CPU subset, e.g. CPUSET=0-3. Only
# useful for proving the build is reproducible regardless of how much
# parallelism is available. Empty = all cores.
CPUSET ?=
DOCKER_CPUSET := $(if $(CPUSET),--cpuset-cpus=$(CPUSET),)

DEB_BUILDER_IMAGE := kiosk-deb-builder
OS_BUILDER_IMAGE  := kiosk-os-builder
DEB := build/kiosk_$(BUILD_VERSION)_amd64.deb
RAW := build/kiosk-v$(BUILD_VERSION).img
IMG_GZ := $(RAW).gz
# Pinned base image digests. The apt snapshot date lives in */lock/debian.sources
# (the source of truth); bump with `make builder-update` / `make os-builder-update`.
DEBIAN_HASH    := $(strip $(shell cat deb-builder/lock/debian-img-hash-lock.txt))
OS_DEBIAN_HASH := $(strip $(shell cat os-builder/lock/build-toolchain-debian-img-hash-lock.txt))

# Prints a clearly visible banner so each build stage stands out in the log
# instead of scrolling past as one undifferentiated wall of text.
define stage
	@echo ""
	@echo "=============================================================================="
	@echo "  $(1)"
	@echo "=============================================================================="
	@echo ""
endef

default: all

all: build

build: os-image

clean:
	rm -rf build app/node_modules app/out app/.yarn

distclean: clean

	npm cache clean -f
	yarn cache clean --all
	docker image rm -f kiosk-deb-builder kiosk-os-builder 2>/dev/null || true
	docker buildx prune --force --builder reproducible-builder 2>/dev/null || true

# ---------------------------------------------------------------------------
# Attestation. Whoever builds this can sign the manifest of what they built, and
# `make verify` checks those signatures against the current manifest using only
# the keys in attestation/signers/.
#
#   make build && make sign     -> writes attestation/signatures/manifest.<KEYID>.asc
#   make verify                 -> re-checks every signature against the manifest
#
# A rebuild that produces different artifacts rewrites the manifest and PURGES the
# signatures, because they attest to bytes that no longer exist.
# ---------------------------------------------------------------------------
sign:
	@./scripts/attest-sign

verify:
	@./scripts/attest-verify 1

# One-time host setup: installs the required packages, enables Docker's
# containerd-snapshotter, and creates the pinned buildx builder. Idempotent —
# re-running it on a configured host changes nothing. FORCE=1 skips the prompts.
setup:
	@./scripts/setup-host

# Reproducible builds need the docker-container buildx driver (the default
# "docker" driver can't do rewrite-timestamp / deterministic output).
check-buildx-driver:
	@driver=$$(docker buildx inspect | grep '^Driver:' | awk '{print $$2}'); \
	if [ "$$driver" != "docker-container" ]; then \
		echo "ERROR: buildx driver must be 'docker-container' (found '$$driver')."; \
		echo "Run: docker buildx create --name reproducible-builder --driver docker-container --use"; \
		exit 1; \
	fi

# ---------------------------------------------------------------------------
# stages 1-2: the app, compiled reproducibly into a .deb
# ---------------------------------------------------------------------------
deb-package: check-buildx-driver
	$(call stage,STAGE 1/3  Build the .deb builder image + compile the app ($(DEB_BUILDER_IMAGE)))
	SOURCE_DATE_EPOCH=1 docker buildx build \
		--build-arg DEBIAN_HASH=$(DEBIAN_HASH) \
		--build-arg SOURCE_DATE_EPOCH=1 \
		--build-arg BUILDKIT_DOCKERFILE_CHECK=skip=InvalidDefaultArgInFrom \
		--provenance=false \
		--output type=docker,name=$(DEB_BUILDER_IMAGE),rewrite-timestamp=true,annotation.org.opencontainers.image.created=1970-01-01T00:00:01Z \
		deb-builder
	mkdir -p build
	docker run --rm $(DOCKER_CPUSET) \
		-v $(CURDIR):/repo \
		-e HOST_UID=$(shell id -u) \
		-e HOST_GID=$(shell id -g) \
		$(DEB_BUILDER_IMAGE) \
		/repo/deb-builder/build-deb.sh $(BUILD_VERSION)

# Build the .deb twice and compare — does it come out byte-identical?
build-deb-check:
	$(MAKE) --no-print-directory deb-package
	cp $(DEB) /tmp/kiosk-deb-1.deb
	$(MAKE) --no-print-directory deb-package
	cp $(DEB) /tmp/kiosk-deb-2.deb
	sha256sum /tmp/kiosk-deb-1.deb /tmp/kiosk-deb-2.deb
	@if cmp -s /tmp/kiosk-deb-1.deb /tmp/kiosk-deb-2.deb; then \
		echo "REPRODUCIBLE: the two .deb builds are byte-identical"; \
	else \
		echo "NOT reproducible: the .deb builds differ"; \
	fi

# ---------------------------------------------------------------------------
# stages 3-4: the OS image
# ---------------------------------------------------------------------------
os-builder: check-buildx-driver
	$(call stage,STAGE 2/3  Build the OS builder image ($(OS_BUILDER_IMAGE)))
	SOURCE_DATE_EPOCH=1 docker buildx build \
		--build-arg DEBIAN_HASH=$(OS_DEBIAN_HASH) \
		--build-arg SOURCE_DATE_EPOCH=1 \
		--build-arg BUILDKIT_DOCKERFILE_CHECK=skip=InvalidDefaultArgInFrom \
		--provenance=false \
		--output type=docker,name=$(OS_BUILDER_IMAGE),rewrite-timestamp=true,annotation.org.opencontainers.image.created=1970-01-01T00:00:01Z \
		os-builder

# Validate the boot flags BEFORE building anything — build-os.sh checks these too,
# but only after the .deb and both builder images are built.
boot-check:
	@if [ -n "$(SIGN)" ]; then \
		echo "ERROR: SIGN= was renamed to BOOTSIGN= (it is Secure Boot signing, not the"; \
		echo "       GPG release signing that 'make sign' does). Use BOOTSIGN=$(SIGN)."; \
		exit 1; \
	fi
	@case "$(BOOT)" in \
		grub|uki) ;; \
		*) echo "ERROR: BOOT='$(BOOT)' is not valid (expected: grub, uki)"; exit 1 ;; \
	esac
	@case "$(BOOTSIGN)" in \
		yes|no) ;; \
		auto) echo "WARNING: BOOTSIGN=auto is deprecated — use BOOTSIGN=yes" ;; \
		*) echo "ERROR: BOOTSIGN='$(BOOTSIGN)' is not valid (expected: yes, no)"; exit 1 ;; \
	esac
	@if [ "$(BOOT)" = "grub" ] && [ "$(BOOTSIGN)" != "no" ]; then \
		echo "ERROR: BOOTSIGN=$(BOOTSIGN) is meaningless with BOOT=grub — nothing of ours is"; \
		echo "       signed there (shim, GRUB and the kernel are all signed by Debian)."; \
		echo "       Use 'make BOOT=uki BOOTSIGN=yes' to sign, or drop BOOTSIGN."; \
		exit 1; \
	fi

# mmdebstrap --mode=unshare must create a user namespace: Docker's default
# seccomp/apparmor block that, and hosts with
# kernel.apparmor_restrict_unprivileged_userns=1 (Ubuntu 24.04+) also need
# CAP_SYS_ADMIN to write uid_map.
os-image: boot-check deb-package os-builder
	$(call stage,STAGE 3/3  Assemble the OS image (mmdebstrap -> configure rootfs -> squashfs -> boot chain -> genimage))
	docker run --rm $(DOCKER_CPUSET) \
		--cap-add SYS_ADMIN \
		--cap-add MKNOD \
		--security-opt seccomp=unconfined \
		--security-opt apparmor=unconfined \
		-v $(CURDIR):/repo \
		-v $(CURDIR)/os-builder/secureboot:/secureboot \
		-e HOST_UID=$(shell id -u) \
		-e HOST_GID=$(shell id -g) \
		-e KIOSK_BOOTSIGN=$(BOOTSIGN) \
		-e KIOSK_BOOT=$(BOOT) \
		$(OS_BUILDER_IMAGE) \
		/repo/os-builder/build-os.sh $(BUILD_VERSION)
	gzip -n -c $(RAW) > $(IMG_GZ)
	@./scripts/attest-manifest $(DEB) $(RAW) $(IMG_GZ)
	@{ \
		w=0; while IFS= read -r line; do \
			file=$$(echo "$$line" | awk '{print $$2}'); \
			len=$$(echo -n "$$file" | wc -c); \
			if [ $$len -gt $$w ]; then w=$$len; fi; \
		done < attestation/manifest.txt; \
		sep=$$(printf '%*s' $$((64 + 2 + w)) '' | tr ' ' '='); \
		echo ""; echo "Manifest:"; echo "$$sep"; \
		printf '%-64s  %s\n' "SHA256 Hash" "File"; \
		echo "$$sep"; \
		while IFS= read -r line; do \
			hash=$$(echo "$$line" | awk '{print $$1}'); \
			file=$$(echo "$$line" | awk '{print $$2}'); \
			printf '%-64s  %s\n' "$$hash" "$$file"; \
		done < attestation/manifest.txt; \
		echo "$$sep"; echo ""; \
	}

# Generate a Secure Boot signing key + certificate for signing the UKI. Without
# a key (or with BOOTSIGN=no, the default) the build still produces an UNSIGNED UKI.
secureboot-key:
	$(call stage,Generating a Secure Boot signing key + certificate)
	@if [ -e os-builder/secureboot/kiosk.key ]; then \
		echo "REFUSING: os-builder/secureboot/kiosk.key already exists."; \
		exit 1; \
	fi
	mkdir -p os-builder/secureboot
	docker run --rm \
		-v $(CURDIR)/os-builder/secureboot:/secureboot \
		-e HOST_UID=$(shell id -u) -e HOST_GID=$(shell id -g) \
		debian@sha256:$(OS_DEBIAN_HASH) \
		bash -c 'apt-get -qq update && apt-get -qq install -y openssl >/dev/null && \
			openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
			-subj "/CN=kiosk Secure Boot/" \
			-keyout /secureboot/kiosk.key -out /secureboot/kiosk.crt 2>/dev/null && \
			chmod 600 /secureboot/kiosk.key && \
			chown $${HOST_UID}:$${HOST_GID} /secureboot/kiosk.key /secureboot/kiosk.crt'
	@echo "Key written to os-builder/secureboot/ (gitignored)."

# ---------------------------------------------------------------------------
# dependency updates — every one rewrites a committed lock file
# ---------------------------------------------------------------------------

# Re-resolve the Debian base image digest that both builders are FROM. Bump this
# FIRST — the toolchain locks below are resolved inside a container built from it.
base-image-update:
	$(call stage,Re-resolving the Debian base image digest (debian:trixie))
	docker pull debian:trixie
	@digest=$$(docker image inspect debian:trixie \
		--format '{{index .RepoDigests 0}}' | cut -d@ -f2 | cut -d: -f2); \
	if [ -z "$$digest" ]; then echo "ERROR: could not resolve digest"; exit 1; fi; \
	echo "$$digest" > deb-builder/lock/debian-img-hash-lock.txt; \
	echo "$$digest" > os-builder/lock/build-toolchain-debian-img-hash-lock.txt; \
	echo "debian:trixie -> sha256:$$digest (written to both lock files)"

# Bump the deb builder's apt snapshot to today and regenerate its locks.
builder-update:
	docker run --rm \
		-v $(CURDIR)/deb-builder:/config \
		-e NODE_VERSION=$(strip $(shell sed 's/^v//' .nvmrc)) \
		-e LOCAL_USER=$(shell id -u):$(shell id -g) \
		debian@sha256:$(DEBIAN_HASH) \
		bash -c "cp /config/scripts/* /usr/local/bin/ && touch /.dockerenv && packages-update"

# Bump the OS builder's apt snapshot + regenerate its locks.
os-builder-update:
	docker run --rm \
		-v $(CURDIR)/os-builder:/config \
		-e LOCAL_USER=$(shell id -u):$(shell id -g) \
		debian@sha256:$(OS_DEBIAN_HASH) \
		bash -c "cp /config/scripts/* /usr/local/bin/ && touch /.dockerenv && build-toolchain-pkgs-update"

# Regenerate the locks for the packages shipped INSIDE the image. Run after
# editing os-builder/rootfs-packages.list — the build installs from the LOCK, so
# a package added without relocking silently never appears in the image.
rootfs-update: os-builder-update os-builder
	$(call stage,Regenerating rootfs package locks)
	docker run --rm \
		--cap-add SYS_ADMIN \
		--cap-add MKNOD \
		--security-opt seccomp=unconfined \
		--security-opt apparmor=unconfined \
		-v $(CURDIR)/os-builder:/config \
		-e LOCAL_USER=$(shell id -u):$(shell id -g) \
		$(OS_BUILDER_IMAGE) \
		/config/scripts/rootfs-pkgs-update

# Refresh EVERY pinned dependency except the app's yarn/node_modules (those live
# in app/yarn.lock and are bumped deliberately with yarn, not here).
#
# Order matters and is why this is a recipe of $(MAKE) calls rather than a list
# of prerequisites — prerequisites may run in parallel under -j, and these must
# not: each step is resolved inside an image produced by the previous one.
update-deps:
	$(MAKE) base-image-update
	$(MAKE) builder-update
	$(MAKE) os-builder-update
	$(MAKE) rootfs-update
	$(call stage,All dependency locks refreshed — review `git diff */lock/` before committing)

# ---------------------------------------------------------------------------
# using the image
# ---------------------------------------------------------------------------
flash-disk: $(RAW)
	sudo umount -qf $(DISK)* || true
	sync
	sudo dd if=$(RAW) of=$(DISK) status=progress bs=16M conv=fsync oflag=dsync

test-boot: $(RAW)
	qemu-system-x86_64 \
		-m 2048M \
		-machine type=pc,accel=kvm \
		-bios /usr/share/ovmf/OVMF.fd \
		-device virtio-scsi-pci,id=scsi0 \
		-device scsi-hd,bus=scsi0.0,drive=drive0 \
		-drive format=raw,if=none,id=drive0,file=$(RAW)

$(RAW):
	$(MAKE) os-image
