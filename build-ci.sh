#!/usr/bin/env bash
# 34OS v0 build for GitHub Actions (ubuntu-24.04 runner) / any normal Ubuntu host.
# The local sandbox build (build-v0.sh) needs several workarounds that a normal
# machine does not, so CI uses this clean version.
set -euo pipefail
cd "$(dirname "$0")"

SUITE=noble
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu/}"
WORK="$PWD/build"
ROOTFS=$WORK/rootfs
ISODIR=$WORK/iso
OUT="$PWD/34os-v0.iso"

echo "=== 34OS v0 CI build started: $(date -Is) ==="

# 0) host tools
sudo apt-get update
sudo apt-get install -y debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools

# 1) base system (minbase)
mkdir -p "$WORK"
sudo rm -rf "$ROOTFS"
sudo debootstrap --variant=minbase "$SUITE" "$ROOTFS" "$MIRROR"

in_chroot() { sudo chroot "$ROOTFS" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive "$@"; }

sudo mount -t proc proc "$ROOTFS/proc"
sudo mount --bind /dev "$ROOTFS/dev"
sudo mount -t devpts devpts "$ROOTFS/dev/pts" || true

# 2) sources + packages (kernel, live boot, editor, locale)
echo "deb $MIRROR $SUITE main universe" | sudo tee "$ROOTFS/etc/apt/sources.list" >/dev/null
echo "deb $MIRROR $SUITE-updates main universe" | sudo tee -a "$ROOTFS/etc/apt/sources.list" >/dev/null
echo "34os" | sudo tee "$ROOTFS/etc/hostname" >/dev/null

in_chroot apt-get update
in_chroot apt-get install -y --no-install-recommends \
  linux-image-generic live-boot systemd-sysv \
  bash nano locales sudo zstd \
  iproute2 iputils-ping less

# locale: Japanese only
echo "ja_JP.UTF-8 UTF-8" | sudo tee "$ROOTFS/etc/locale.gen" >/dev/null
in_chroot locale-gen ja_JP.UTF-8
echo "LANG=ja_JP.UTF-8" | sudo tee "$ROOTFS/etc/default/locale" >/dev/null

# live user (live-boot default is 'user'; passwordless sudo for v0)
echo "user ALL=(ALL) NOPASSWD:ALL" | sudo tee "$ROOTFS/etc/sudoers.d/34os" >/dev/null
sudo chmod 440 "$ROOTFS/etc/sudoers.d/34os"

# 3) slimming: firmware trim (keep common NIC / Wi-Fi only), docs, apt cache
if [ -d "$ROOTFS/usr/lib/firmware" ]; then
  sudo find "$ROOTFS/usr/lib/firmware" -mindepth 1 -maxdepth 1 \
    ! -name 'rtl_nic' ! -name 'iwlwifi-*' ! -name 'intel' \
    ! -name 'rtw88' ! -name 'rtw89' ! -name 'ath10k' ! -name 'ath11k' \
    ! -name 'brcm' ! -name 'e100' ! -name 'tigon' \
    -exec rm -rf {} +
fi
in_chroot apt-get clean
sudo rm -rf "$ROOTFS/usr/share/doc/"* "$ROOTFS/usr/share/man/"* \
            "$ROOTFS/var/lib/apt/lists/"* "$ROOTFS/var/cache/apt/"*.bin \
            "$ROOTFS/tmp/"* "$ROOTFS/root/.bash_history" 2>/dev/null || true

sudo umount "$ROOTFS/dev/pts" 2>/dev/null || true
sudo umount "$ROOTFS/dev" 2>/dev/null || true
sudo umount "$ROOTFS/proc" 2>/dev/null || true

echo "--- rootfs size (uncompressed) ---"
sudo du -sh "$ROOTFS" || true

# 4) squashfs + kernel/initrd for live boot
sudo mkdir -p "$ISODIR/casper" "$ISODIR/boot/grub"
sudo chown -R "$(id -u):$(id -g)" "$ISODIR"
sudo rm -f "$ISODIR/casper/filesystem.squashfs"
sudo mksquashfs "$ROOTFS" "$ISODIR/casper/filesystem.squashfs" -comp xz -noappend -wildcards -e "boot/vmlinuz-*" "boot/initrd.img-*"

VMLINUZ=$(ls "$ROOTFS"/boot/vmlinuz-* | sort -V | tail -1)
INITRD=$(ls "$ROOTFS"/boot/initrd.img-* | sort -V | tail -1)
sudo cp "$VMLINUZ" "$ISODIR/casper/vmlinuz"
sudo cp "$INITRD" "$ISODIR/casper/initrd.img"
sudo chown -R "$(id -u):$(id -g)" "$ISODIR"

cat > "$ISODIR/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=5
menuentry "34OS v0 (CLI live)" {
  linux /casper/vmlinuz boot=live hostname=34os locales=ja_JP.UTF-8 quiet ---
  initrd /casper/initrd.img
}
EOF
echo "34OS v0 - CLI live prototype" > "$ISODIR/README.txt"

# 5) ISO (BIOS + UEFI hybrid via grub-mkrescue)
rm -f "$OUT"
grub-mkrescue -o "$OUT" "$ISODIR"

echo "--- result ---"
du -h "$ISODIR/casper/filesystem.squashfs" "$OUT"
echo "=== 34OS v0 CI build finished: $(date -Is) ==="
