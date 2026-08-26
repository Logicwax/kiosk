#!/usr/bin/env bash
# Configure the rootfs — the bash replacement for the original Ansible playbook.
#
#     configure-rootfs.sh <rootfs> <app_user>
#
# Ansible bought us nothing here. Its main selling point is idempotency, but
# build-os.sh does `rm -rf "$WORK"` and bootstraps a fresh rootfs on every run, so
# nothing is ever applied twice. Against that it cost a Python interpreter and its
# dependency closure INSIDE the shipped appliance (python3, python3-apt,
# python3-setuptools and friends), purely so the chroot connection plugin had
# something to talk to. On an airgapped signing device that is real attack surface
# in exchange for a feature we do not use.
#
# Everything here is a plain file operation against $ROOTFS. Nothing needs to
# execute inside the chroot except the three commands that genuinely do:
# useradd/passwd (writes shadow), systemctl enable (resolves unit paths), and
# dracut (builds the initramfs).
set -euo pipefail

ROOTFS="${1:?usage: configure-rootfs.sh <rootfs> <app_user>}"
APP_USER="${2:?usage: configure-rootfs.sh <rootfs> <app_user>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$HERE/files"
HOME_DIR="$ROOTFS/home/$APP_USER"

say() { printf '  %s\n' "$*"; }

# --- helpers ---------------------------------------------------------------

in_chroot() { chroot "$ROOTFS" /bin/sh -c "$*"; }

# Ensure a config line is present, replacing whatever currently sets it.
#
#     set_line <file> <line>            # match (and replace) the line itself
#     set_line <file> <line> <regex>    # match something else, e.g. a stock default
#
# With no regex the LINE ITSELF is matched literally — it is regex-escaped first,
# because lines like 'filesystems+=" overlay "' contain ERE metacharacters and
# would otherwise match by accident rather than by intent.
#
# Pass a regex when you need to REPLACE a different line: the stock commented-out
# default (`^#NAutoVTs=6`) or an opposite setting (`^hostonly=yes`). Leaving those
# behind would mean two conflicting directives in one file.
#
# Either way the result is ASSERTED afterwards. The Ansible lineinfile tasks this
# replaces silently did nothing when upstream changed the text they matched, and
# two of them are security controls, so the outcome is checked rather than the
# mechanism trusted.
set_line() {
	local file="$1" line="$2" regex="${3:-}"
	if [ -z "$regex" ]; then
		# escape every ERE metacharacter in the literal
		regex="^$(printf '%s' "$line" | sed 's/[][\.*^$+?(){}|]/\\&/g')$"
	fi
	mkdir -p "$(dirname "$file")"
	touch "$file"
	if grep -qE "$regex" "$file"; then
		# escape the replacement too: & and \ are special on sed's RHS
		local repl; repl="$(printf '%s' "$line" | sed 's/[&\\|]/\\&/g')"
		sed -i -E "0,/$regex/s|$regex|$repl|" "$file"
	else
		printf '%s\n' "$line" >> "$file"
	fi
	grep -qxF "$line" "$file" || {
		echo "ERROR: failed to set '$line' in ${file#$ROOTFS}" >&2
		exit 1
	}
}

# The only template with substitution: everything else is a byte-for-byte copy.
render() {
	local src="$1" dst="$2" mode="$3"
	mkdir -p "$(dirname "$dst")"
	sed "s|{{ app_user }}|$APP_USER|g" "$src" > "$dst"
	chmod "$mode" "$dst"
}

# --- 1. the application user ----------------------------------------------
say "user: $APP_USER"
if ! in_chroot "id -u '$APP_USER' >/dev/null 2>&1"; then
	in_chroot "useradd --create-home --shell /bin/bash '$APP_USER'"
fi
# No password: the console autologins, and there is no other way in.
in_chroot "passwd --delete '$APP_USER'" >/dev/null

install -d -m 0755 "$HOME_DIR/.local/bin"

# --- 2. login shell -------------------------------------------------------
# Written whole rather than line-appended: the file is created fresh every build,
# so there is nothing to be idempotent against, and one heredoc is far easier to
# read than four separate append-if-absent rules.
say "login shell: /home/$APP_USER/.bash_profile"
cat > "$HOME_DIR/.bash_profile" <<EOF
clear
export PATH="/usr/local/bin:/home/$APP_USER/.local/bin:\$PATH"
[[ -z "\$DISPLAY" ]] && (( EUID )) && [ -x /usr/local/bin/kiosk-session ] && exec /usr/local/bin/kiosk-session
[[ -z "\$DISPLAY" ]] && (( EUID )) && exit
EOF
chmod 0755 "$HOME_DIR/.bash_profile"
: > "$HOME_DIR/.hushlogin"
chmod 0755 "$HOME_DIR/.hushlogin"

# --- 3. autologin on tty1 -------------------------------------------------
say "autologin: getty@tty1"
render "$FILES/autologin.conf" "$ROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf" 0755
in_chroot "systemctl enable getty@tty1.service" >/dev/null 2>&1

# --- 4. read-only root overlay (dracut) -----------------------------------
# systemd is not available in Debian's initramfs-tools, hence dracut.
say "initramfs: dracut (overlay root, reproducible)"
set_line "$ROOTFS/etc/dracut.conf.d/overlay.conf"          'filesystems+=" overlay "'
# squashfs is what the root actually is; ext4 is kept so the dracut shell can
# mount ext4 volumes when debugging.
set_line "$ROOTFS/etc/dracut.conf.d/udev.conf"             'filesystems+=" ext4 squashfs "'
set_line "$ROOTFS/etc/dracut.conf.d/10-debian.conf"        'hostonly=no' '^hostonly=yes'
# Without this dracut's cpio varies between builds (entry order + mtimes).
set_line "$ROOTFS/etc/dracut.conf.d/20-reproducible.conf"  'reproducible=yes'
in_chroot "SOURCE_DATE_EPOCH=1 dracut --regenerate-all --force"

# --- 5. disable the other TTYs -------------------------------------------
# Removes CTRL-ALT-Fx. This is a security control on an appliance with no other
# console access, so set_line asserts the result rather than trusting a match.
say "console: disabling other TTYs"
set_line "$ROOTFS/etc/systemd/logind.conf" 'NAutoVTs=0'  '^#?NAutoVTs=.*'
set_line "$ROOTFS/etc/systemd/logind.conf" 'ReserveVT=1' '^#?ReserveVT=.*'

# --- 6. the X session -----------------------------------------------------
say "X session"
install -D -m 0644 "$FILES/xorg.conf"     "$ROOTFS/etc/X11/xorg.conf"
install -D -m 0755 "$FILES/kiosk-session" "$ROOTFS/usr/local/bin/kiosk-session"
cat > "$HOME_DIR/.xinitrc" <<'EOF'
#!/bin/sh
xset s off -dpms
# Capture the app's own stderr: Electron prints its reason for giving up
# (GPU/GL init, sandbox, missing lib) and it is otherwise lost.
exec /usr/bin/kiosk >/tmp/kiosk.log 2>&1
EOF
chmod 0755 "$HOME_DIR/.xinitrc"

# --- 7. cleanup -----------------------------------------------------------
# No SSH server is ever installed (it is not in the lock), so this is a tripwire
# against one appearing, not a fix for one that is there.
say "cleanup"
mkdir -p "$ROOTFS/etc/systemd/system"
ln -sf /dev/null "$ROOTFS/etc/systemd/system/ssh.service"

# /var/log matters for REPRODUCIBILITY, not disk space: dpkg.log and apt/term.log
# embed the build's wall-clock time in their CONTENTS, and mksquashfs -reproducible
# only normalises inode mtimes.
rm -rf \
	"$ROOTFS/var/cache/apt" \
	"$ROOTFS/var/cache/debconf" \
	"$ROOTFS/var/lib/apt" \
	"$ROOTFS/var/log" \
	"$ROOTFS/usr/share/doc" \
	"$HOME_DIR/.cache"

# Owned by the app user, and readable only by them. The app itself lives under
# /usr/lib/kiosk and stays root-owned, so the setuid chrome-sandbox keeps 4755 root.
in_chroot "chown -R '$APP_USER:$APP_USER' /home/'$APP_USER'"
chmod -R 0700 "$HOME_DIR"

say "rootfs configured"
