# Reproducible builder image for the kiosk .deb.
#
#   - base image by digest (deb-builder/lock/debian-img-hash-lock.txt),
#   - Debian toolchain via a frozen snapshot.debian.org + version + sha256 hash
#     lock (deb-builder/lock + deb-builder/scripts/packages-install).
#
ARG DEBIAN_HASH
FROM debian@sha256:${DEBIAN_HASH}

# Fixed, build-independent reproducibility settings. SOURCE_DATE_EPOCH=1 clamps
# timestamps; TZ=UTC keeps formatting deterministic.
ENV SOURCE_DATE_EPOCH=1 \
    TZ=UTC \
    LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# Copy ONLY what the image build consumes. build-deb.sh runs from the /repo bind
# mount at RUN time, so it deliberately is NOT copied — baking it in would
# invalidate this layer on every edit and force a full toolchain reinstall.
COPY packages.list /config/
COPY pgp/nodesource.asc /config/pgp/
COPY lock/debian.sources /config/lock/
COPY lock/packages-version-lock.list /config/lock/
COPY lock/packages-hash-lock.txt /config/lock/
COPY scripts/ /usr/local/bin/
RUN touch /.dockerenv

# Debian build toolchain — snapshot-pinned, version + hash locked. This includes
# nodejs + node-corepack; corepack then provisions the exact yarn named by
# app/package.json's `packageManager` field.
RUN packages-install && corepack enable
