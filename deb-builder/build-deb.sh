#!/usr/bin/env bash
# Build the kiosk Electron app and package it into a .deb inside the pinned
# builder container. Reads sources from /repo, writes the .deb to /repo/build.
#
# Builds in a scratch dir (not the mounted tree) so the host checkout is never
# polluted with node_modules/out and the build is hermetic. Determinism comes
# from the pinned builder image + yarn --immutable + SOURCE_DATE_EPOCH, plus the
# two webpack settings in app/webpack.*.config.js (order-independent chunk ids
# and scope hoisting disabled) — see app/webpack.chunk-ids.js for why.
#
# electron-forge's maker-deb builds the package: it installs to /usr/lib/<name>/,
# symlinks /usr/bin/<name>, and ships chrome-sandbox setuid root (4755), which
# Electron requires or it FATALs at launch.
# pipefail matters here: the source copy below is a tar|tar pipeline, and without
# it a failing PRODUCER is invisible — the pipeline reports the consumer's status,
# so a truncated copy would sail through and build a .deb from partial sources.
set -euo pipefail

VERSION="$1"
REPO=/repo
OUT="$REPO/build"
WORK=/build
: "${SOURCE_DATE_EPOCH:=1}"
export SOURCE_DATE_EPOCH
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

# Hermetic copy of the app sources, excluding generated dirs.
mkdir -p "$WORK/app"
tar -C "$REPO/app" -cf - \
	--exclude=node_modules --exclude=out --exclude=.webpack --exclude=.yarn \
	--exclude=.git . \
	| tar -C "$WORK/app" -xf -

# Normalize permissions regardless of umask or upstream tooling:
# git only tracks the executable bit, so a developer with umask 002 produces
# 0664/0775 files/dirs while CI with umask 022 produces 0644/0755 -- causing
# electron-forge to emit a differently-permissioned resources/app and therefore
# a different deb and image hash.  Force everything to git's canonical modes.
find "$WORK/app" -type f ! -perm /111 -exec chmod 644 {} +  # non-executable files -> 644
find "$WORK/app" -type f   -perm /111 -exec chmod 755 {} +  # executable files -> 755
find "$WORK/app" -type d              -exec chmod 755 {} +  # directories -> 755

cd "$WORK/app"
yarn install --immutable
yarn run make

mkdir -p "$OUT"
DEB="$OUT/kiosk_${VERSION}_amd64.deb"
cp "$WORK/app/out/make/deb/x64/kiosk_${VERSION}_amd64.deb" "$DEB"
chown "${HOST_UID:-0}:${HOST_GID:-0}" "$DEB"
echo "Built $DEB"
