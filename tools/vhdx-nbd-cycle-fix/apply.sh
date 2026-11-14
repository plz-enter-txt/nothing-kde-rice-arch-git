#!/usr/bin/env bash
# Break the boot ordering cycle created by vhdx-nbd.service / mnt-MCServer.mount.
#
# This is not part of the rice -- it is a machine-specific fix, kept here so it
# survives a reinstall. Run with sudo.
#
# The cycle (as systemd reports at boot, naming unrelated sockets because it
# breaks the loop by dropping whichever job it happens to pick):
#   vhdx-nbd.service -> basic.target -> sysinit.target -> local-fs.target
#                    -> mnt-MCServer.mount -> vhdx-nbd.service
#
# Cause: mnt-MCServer.mount Requires the service, and a .mount unit's default
# dependencies include Before=local-fs.target; the service's default
# dependencies include After=basic.target, which is ordered after
# sysinit.target, which runs before local-fs.target.
#
# Fix: DefaultDependencies=no on both units. The explicit Requires=/After= pair
# between them is preserved, the mount is still pulled in by multi-user.target,
# and it still waits on blockdev@dev-nbd0p1.target for the NBD partition.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

install -d /etc/systemd/system/vhdx-nbd.service.d
install -d /etc/systemd/system/mnt-MCServer.mount.d
install -m 644 "$HERE/vhdx-nbd.service.deps.conf"    /etc/systemd/system/vhdx-nbd.service.d/deps.conf
install -m 644 "$HERE/mnt-MCServer.mount.deps.conf"  /etc/systemd/system/mnt-MCServer.mount.d/deps.conf
systemctl daemon-reload
echo "applied. remaining ordering cycles:"
systemd-analyze verify vhdx-nbd.service mnt-MCServer.mount 2>&1 | grep -c 'ordering cycle' || true
