#!/usr/bin/env bash
# Run as root in the worker's host mount namespace.
# Initializes an unused local NVMe disk; never forces formatting over signatures.
set -euo pipefail

DEVICE=/dev/nvme0n1
MOUNT_DIR=/mnt/mooncake-nvme
LABEL=mooncake-nvme

fail() { echo "STOP: $*" >&2; exit 1; }
[[ $(id -u) == 0 ]] || fail "Run as root on the worker."
for tool in lsblk findmnt wipefs blkid mkfs.ext4 mount mountpoint flock; do
  command -v "$tool" >/dev/null || fail "Missing host utility: $tool"
done
exec 9>/run/mooncake-nvme-prepare.lock
flock -n 9 || fail "Another preparation process is running."
[[ -b "$DEVICE" ]] || fail "$DEVICE is not a block device."
[[ $(lsblk -dnro TYPE "$DEVICE") == disk ]] || fail "Expected a whole disk."
[[ $(blockdev --getro "$DEVICE") == 0 ]] || fail "Disk is read-only."
[[ $(blockdev --getsize64 "$DEVICE") -gt 3000000000000 ]] || fail "Unexpected disk size."
[[ $(lsblk -nr -o NAME "$DEVICE" | wc -l) -eq 1 ]] || fail "Disk has child devices or partitions."
[[ -z $(ls -A /sys/class/block/nvme0n1/holders) ]] || fail "Disk has device-mapper/RAID holders."

ROOT_SOURCE=$(findmnt -nro SOURCE /)
ROOT_DEVICES=$(lsblk -s -nr -o PATH "$ROOT_SOURCE") || fail "Cannot identify root backing disks."
if printf '%s\n' "$ROOT_DEVICES" | grep -Fxq "$DEVICE"; then
  fail "$DEVICE backs the root filesystem."
fi

TYPE=$(lsblk -dnro FSTYPE "$DEVICE")
DISK_LABEL=$(lsblk -dnro LABEL "$DEVICE")
EXISTING_MOUNTS=$(lsblk -dnro MOUNTPOINTS "$DEVICE")

# Refuse any pre-existing entry for this destination unless it describes our disk.
UUID=$(blkid -s UUID -o value "$DEVICE" || true)
while read -r source target rest; do
  [[ "$target" == "$MOUNT_DIR" ]] || continue
  [[ -n "$UUID" && "$source" == "UUID=$UUID" ]] || fail "Conflicting fstab entry for $MOUNT_DIR."
done < /etc/fstab

if [[ -n "$EXISTING_MOUNTS" ]]; then
  [[ "$TYPE" == ext4 && "$DISK_LABEL" == "$LABEL" ]] || fail "Disk is already mounted for another use."
  [[ "$EXISTING_MOUNTS" == "$MOUNT_DIR" ]] || fail "Disk is mounted at an unexpected location."
fi

if mountpoint -q "$MOUNT_DIR"; then
  [[ $(findmnt -nro UUID --mountpoint "$MOUNT_DIR") == "$UUID" && -n "$UUID" ]] || fail "Destination contains another mounted filesystem."
elif [[ -e "$MOUNT_DIR" ]]; then
  [[ -d "$MOUNT_DIR" && ! -L "$MOUNT_DIR" ]] || fail "Destination is not an ordinary directory."
  [[ -z $(ls -A "$MOUNT_DIR") ]] || fail "Unmounted destination contains files; refusing to hide them."
fi

if [[ -z "$TYPE" ]]; then
  SIGNATURES=$(wipefs --no-act --noheadings --output TYPE "$DEVICE")
  [[ -z "$SIGNATURES" ]] || fail "Existing signatures detected: $SIGNATURES"
  [[ -z "$EXISTING_MOUNTS" ]] || fail "Disk has existing mounts."
  echo "Initializing $DEVICE on $(hostname) as ext4 for Mooncake."
  mkfs.ext4 -m 0 -L "$LABEL" "$DEVICE"
elif [[ "$TYPE" != ext4 || "$DISK_LABEL" != "$LABEL" ]]; then
  fail "Existing filesystem ($TYPE, label=$DISK_LABEL); refusing to format."
else
  echo "Reusing the existing Mooncake filesystem."
fi

UUID=$(blkid -s UUID -o value "$DEVICE")
[[ -n "$UUID" ]] || fail "Filesystem UUID is missing."
install -d -m 0755 "$MOUNT_DIR"

if ! awk -v uuid="UUID=$UUID" -v target="$MOUNT_DIR" \
  '$1 == uuid && $2 == target {found=1} END {exit !found}' /etc/fstab; then
  cp -a /etc/fstab "/etc/fstab.before-mooncake.$(date -u +%Y%m%dT%H%M%SZ)"
  printf 'UUID=%s %s ext4 defaults,noatime,nofail,x-systemd.device-timeout=30s 0 2\n' \
    "$UUID" "$MOUNT_DIR" >> /etc/fstab
fi

systemctl daemon-reload
mountpoint -q "$MOUNT_DIR" || mount "$MOUNT_DIR"
[[ $(findmnt -nro UUID --mountpoint "$MOUNT_DIR") == "$UUID" ]] || fail "Mounted filesystem UUID mismatch."
install -d -m 0750 "$MOUNT_DIR/store"
echo "READY: $(hostname)"
findmnt --mountpoint "$MOUNT_DIR"
df -hT "$MOUNT_DIR"
