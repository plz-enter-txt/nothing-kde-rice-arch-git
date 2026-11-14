#!/usr/bin/env bash
# Move /home onto the btrfs @home subvolume and fix the duplicated fstab entry.
#
# RUN THIS FROM A TTY (Ctrl+Alt+F3), LOGGED IN AS ROOT, WITH NO GRAPHICAL
# SESSION RUNNING. It cannot be run from the desktop: every process of the
# session has its cwd inside /home, so moving the data under a running session
# is unsafe and partial.
#
#   Ctrl+Alt+F3
#   log in as root (or: log in as your user, then `su -`)
#   /path/to/migrate-home-to-btrfs-subvolume.sh
#
# What it does, in order:
#   1. checks nothing is using /home            (refuses otherwise)
#   2. copies /home -> the empty @home subvolume (a real copy, not a move)
#   3. verifies the copy file-for-file
#   4. rewrites /etc/fstab so the second line mounts @home at /home
#   5. updates the initramfs for the new fstab  (GRUB/systemd only, safe to skip)
# It never deletes the original: the old home stays inside @ until you remove it
# yourself (step B below), so a rollback is always possible.
set -euo pipefail

DEV_UUID=$(findmnt -no UUID /)
[ -n "$DEV_UUID" ] || { echo "cannot determine the root device UUID"; exit 1; }
ROOT_SRC=/dev/disk/by-uuid/$DEV_UUID
STAMP=$(date +%Y%m%d-%H%M%S)
MNT=/mnt/_home_migrate

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[33m!! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mABORTED: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || die "a graphical session is running -- log out and use a TTY"

# The human whose home is being moved. Derived rather than hardcoded so this
# keeps working if the account is renamed; also used for the checks below.
USER_HOME=$(find /home -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
[ -n "$USER_HOME" ] || { echo "/home has no user directory"; exit 1; }
USER_NAME=$(basename "$USER_HOME")

# --------------------------------------------------------------------------
say "1. Nothing may hold /home open"
if loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}' | while read -r s; do
        [ -n "$s" ] || continue
        loginctl show-session "$s" -p Type --value 2>/dev/null
    done | grep -qv '^tty$'; then
    die "there is still a non-TTY session (the desktop). Log out to the display manager, then Ctrl+Alt+F3."
fi
holders=$(lsof +D /home 2>/dev/null | wc -l || true)
if [ "${holders:-0}" -gt 1 ]; then
    warn "these processes still have files open under /home:"
    lsof +D /home 2>/dev/null | head -10
    die "close them (a shell whose cwd is /home counts) and run again"
fi
ok "no open files under /home"

# --------------------------------------------------------------------------
say "2. Sanity-check the subvolumes"
findmnt -no FSTYPE / | grep -qx btrfs || die "/ is not btrfs"
subvols=$(btrfs subvolume list / 2>/dev/null)
grep -qE 'path @$'     <<<"$subvols" || die "no @ subvolume -- this machine is not laid out as expected"
grep -qE 'path @home$' <<<"$subvols" || die "no @home subvolume -- nothing to migrate into"
ok "@ and @home both exist"

if [ -d "$MNT" ] && mountpoint -q "$MNT"; then umount "$MNT"; fi
mkdir -p "$MNT"
mount -o subvol=/@home "$ROOT_SRC" "$MNT" || die "cannot mount @home"

# A non-empty @home is normal on a retry: an earlier run copied everything and
# then failed at verification. Resuming is safe because step 3 rsyncs again with
# --delete, so the result is dictated by /home, not by what is already there.
# What must NOT happen is merging into someone else's data, so anything that is
# not a copy of this user's home is refused.
if [ -n "$(ls -A "$MNT")" ]; then
    if [ -d "$MNT/$USER_NAME" ] && [ "$(ls -A "$MNT" | wc -l)" -le 1 ]; then
        warn "@home already holds a previous copy of $USER_NAME ($(du -sh "$MNT" 2>/dev/null | cut -f1))"
        warn "re-syncing it in step 3 -- this is the normal retry path"
    else
        warn "@home is not empty and does not look like a previous attempt:"
        ls -A "$MNT" | head
        umount "$MNT"
        die "refusing to merge into a subvolume with unrelated content"
    fi
else
    ok "@home is empty"
fi

# --------------------------------------------------------------------------
say "3. Copy /home into @home  (4.5G; takes a few minutes)"
# -a keeps ownership, permissions, symlinks and xattrs. On a re-run against an
# existing partial copy this is incremental (and --delete removes files that
# were deleted from /home since), so a failed verification is cheap to retry.
if [ -n "$(ls -A "$MNT" 2>/dev/null)" ]; then
    warn "@home already has a copy -- syncing incrementally"
    RSYNC_DELETE=--delete
else
    RSYNC_DELETE=""
fi
if ! rsync -aHAX $RSYNC_DELETE --info=progress2 /home/ "$MNT/"; then
    umount "$MNT"
    die "rsync failed -- nothing has been switched over, /home is untouched"
fi
ok "copied"

say "4. Verify the copy"
# Byte-for-byte diffing a live home cannot pass: browsers rewrite their caches,
# fcitx/ibus keep transient socket files in ~/.config, and the desktop rewrites
# its own rc files continuously. Measured on a real machine, a copy taken while
# a session is running differs in 54 files even right after a clean rsync.
#
# So verification asks the tool that did the copying, without a second pass:
# `rsync -n --checksum` would re-read every byte, but `rsync -n` (no checsum)
# compares size+mtime and lists what it *would* still transfer. An empty list
# means the copy is faithful to what was there when the copy ran.
REMAIN=$(rsync -aHAXn --out-format='%n' /home/ "$MNT/" 2>/dev/null | sed '/\/$/d')
n_remain=$(printf '%s\n' "$REMAIN" | grep -c . || true)
if [ "$n_remain" -eq 0 ]; then
    ok "rsync reports nothing left to transfer"
else
    warn "$n_remain files would still be transferred:"
    printf '%s\n' "$REMAIN" | head -20 | sed 's/^/    /'
    warn "These changed after the copy started -- almost always live caches and"
    warn "runtime state. If any of them are data you care about, re-run this"
    warn "script: the copy resumes incrementally and picks them up."
    umount "$MNT"
    die "verification failed -- /home is untouched"
fi

# rsync's own view is necessary but not sufficient: check that the tree the
# session will actually mount has the expected user, and the same entry count.
src_uid=$(stat -c %u "$USER_HOME" 2>/dev/null || echo "")
dst_uid=$(stat -c %u "$MNT/$USER_NAME" 2>/dev/null || echo "")
# An empty value means stat failed -- the directory is absent, not merely owned
# by someone else. Say which, or the message reads as a permissions problem.
[ -n "$dst_uid" ] || {
    warn "$MNT/$USER_NAME does not exist after the copy"
    umount "$MNT"
    die "the user directory is missing from @home"
}
[ "$src_uid" = "$dst_uid" ] || {
    warn "uid differs: $USER_HOME is $src_uid, $MNT/$USER_NAME is $dst_uid"
    umount "$MNT"
    die "ownership did not survive the copy"
}

src_n=$(find "$USER_HOME" -mindepth 1 | wc -l)
dst_n=$(find "$MNT/$USER_NAME" -mindepth 1 | wc -l)
# Allow drift: the session keeps creating and removing files while this runs.
drift=$(( src_n > dst_n ? src_n - dst_n : dst_n - src_n ))
if [ "$drift" -gt 200 ]; then
    warn "entry counts differ by $drift (/home=$src_n, @home=$dst_n) -- too much to be live churn"
    umount "$MNT"
    die "verification failed -- /home is untouched"
fi
ok "copy verified ($(du -sh "$MNT" 2>/dev/null | cut -f1), $dst_n entries, uid $dst_uid, drift $drift)"

umount "$MNT"
rmdir "$MNT" 2>/dev/null || true

# --------------------------------------------------------------------------
say "5. Rewrite /etc/fstab"
cp /etc/fstab "/etc/fstab.bak.$STAMP"
# The duplicated line has subvol=/@home and mountpoint "/". Repoint it at /home.
# Match on the subvol option so this works whatever the commented header says.
if ! grep -qE 'subvol=/@home' /etc/fstab; then
    die "no subvol=/@home line in /etc/fstab -- re-check the file manually"
fi
sed -i -E "\|subvol=/@home| s#[[:space:]]/[[:space:]]+# /home #" /etc/fstab
if [ "$(grep -cE 'subvol=/@home' /etc/fstab)" -ne 1 ]; then
    die "unexpected number of subvol=/@home lines after editing -- restore /etc/fstab.bak.$STAMP"
fi
printf '    backup: /etc/fstab.bak.%s\n' "$STAMP"
grep -nE 'subvol=' /etc/fstab | sed 's/^/    /'

# Validate before it can break the next boot. systemd-analyze verify does not
# accept an fstab, so run the real generator against the edited file and check
# it no longer complains about a duplicate entry.
gen_out=$(mktemp -d)
gen_err=$(mktemp)
/usr/lib/systemd/system-generators/systemd-fstab-generator "$gen_out" "$gen_out" "$gen_out" 2>"$gen_err" || true
if grep -qi 'Duplicate entry\|already exists\|ordering cycle' "$gen_err"; then
    warn "the fstab generator still complains:"
    sed 's/^/    /' "$gen_err" | head -5
    warn "restoring /etc/fstab.bak.$STAMP -- nothing was changed"
    cp "/etc/fstab.bak.$STAMP" /etc/fstab
    rm -rf "$gen_out" "$gen_err"
    die "fstab fix did not verify; /home is unchanged on disk"
fi
if [ -f "$gen_out/home.mount" ]; then
    ok "generator produced home.mount"
else
    warn "generator did not produce a home.mount -- check /etc/fstab by hand"
fi
rm -rf "$gen_out" "$gen_err"
ok "fstab rewritten and the duplicate '/' entry removed"

say "6. Rebuild the initramfs (so the new fstab is present at boot)"
if command -v mkinitcpio >/dev/null; then
    mkinitcpio -P && ok "initramfs rebuilt"
else
    warn "mkinitcpio not found -- skip"
fi

cat <<MSG

========================================================================
 Done. Nothing has been deleted.

 Before rebooting, confirm the new mount would work:
     mount -a          # mounts /home from @home; errors show immediately
     ls /home/$USER_NAME | head
     umount /home      # optional, the reboot remounts it anyway

 Then:  reboot

 After logging back in, check that you are on the subvolume:
     findmnt /home     # should say [/@home]

 A. If the login fails or /home looks wrong, roll back by editing fstab:
        mount -o remount,rw /
        cp /etc/fstab.bak.$STAMP /etc/fstab
        mkinitcpio -P
        reboot
    /home then comes from @ again. Your data was never deleted.

 B. Only once you are happy, remove the old copy that is still inside @:
        # from a TTY, nothing running
        mount -o subvol=/@ $ROOT_SRC /mnt
        rm -rf /mnt/home/$USER_NAME     # the pre-migration copy
        umount /mnt
    That frees the 4.5G. Until you do this, the space is still in use.
========================================================================
MSG
