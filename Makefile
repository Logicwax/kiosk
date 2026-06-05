ISO_CHECKSUM := 95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a
ISO_URL := http://cdimage.debian.org/mirror/cdimage/release/13.5.0/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso

.PHONY: \
	all \
	build \
	clean \
	distclean \
	flash-disk \
	test-boot \
	test-boot-legacy

SHELL=/bin/bash
export CHECKPOINT_DISABLE := 1
export PACKER_CACHE_DIR := \
	$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))/.packer/cache

BUILD_VERSION := $(strip $(shell cat VERSION))

default: all

all: build

build: build/kiosk-v$(BUILD_VERSION).raw

clean:
	rm -rf \
		build \
		.packer/build \
		ansible/main.retry \
		app/node_modules \
		app/out \
		app/.yarn

distclean: clean
	rm -rf .packer

build/kiosk-v$(BUILD_VERSION).raw:

	$(eval ISO_URL_WORKING = $(shell curl --fail --silent --output /dev/null $(ISO_URL) && echo $(ISO_URL) || echo $(ISO_URL) | sed s/release/archive/g))
	packer build \
	-var "build_version=$(BUILD_VERSION)" \
	-var "iso_url=$(ISO_URL_WORKING)" \
	-var "iso_checksum=$(ISO_CHECKSUM)" \
	packer/build.json
	mkdir -p build
	mv .packer/build/packer-qemu build/kiosk-v$(BUILD_VERSION).raw
	gzip build/kiosk-v$(BUILD_VERSION).raw -c > build/kiosk-v$(BUILD_VERSION).raw.gz

flash-disk: build/kiosk-v$(BUILD_VERSION).raw

	sudo umount -qf $(DISK)* || true && \
	sync && \
	sudo dd if=build/kiosk-v$(BUILD_VERSION).raw of=$(DISK) status=progress bs=16M conv=fsync oflag=dsync

test-boot: build/kiosk-v$(BUILD_VERSION).raw

	qemu-system-x86_64 \
		-m 2048M \
		-machine type=pc,accel=kvm \
		-bios /usr/share/qemu/OVMF.fd \
		-device virtio-scsi-pci,id=scsi0 \
		-device scsi-hd,bus=scsi0.0,drive=drive0 \
		-drive format=raw,if=none,id=drive0,file=build/kiosk-v$(BUILD_VERSION).raw

test-boot-legacy: build/kiosk-v$(BUILD_VERSION).raw

	qemu-system-x86_64 \
		-m 2048M \
		-machine type=pc,accel=kvm \
		-drive format=raw,file=build/kiosk-v$(BUILD_VERSION).raw
