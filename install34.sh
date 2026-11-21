#!/bin/bash
# install34 - 34OS installer: installs the running live system to a disk.
# Modes: wipe (whole disk) / dual boot (install into free space).
set -u

say() { printf '%s\n' "$*"; }
die() { say "エラー: $*"; exit 1; }
diecode() { say "エラー [$1]: $2"; exit 1; }

[ "$(id -u)" -eq 0 ] || diecode NO_PERMISSION "この操作を実行するために必要な権限がありません。コマンド実行時、先頭に「sudo」を入力してから実行してください"

# --- find the live medium (source squashfs) ---
SQFS=""
for p in /run/live/medium/casper/filesystem.squashfs \
         /lib/live/mount/medium/casper/filesystem.squashfs \
         /cdrom/casper/filesystem.squashfs; do
  [ -f "$p" ] && SQFS="$p" && break
done
[ -n "$SQFS" ] || diecode NOT_FOUND_COPY_SOURCE "コピー元が見つかりません。ライブ環境で実行されているかを確かめて、やり直してください"
MEDIUM_MNT=$(dirname "$(dirname "$SQFS")")
MEDIUM_SRC=$(findmnt -no SOURCE "$MEDIUM_MNT" 2>/dev/null | head -1)
MEDIUM_DISK=$(lsblk -no PKNAME "$MEDIUM_SRC" 2>/dev/null | head -1)
[ -z "$MEDIUM_DISK" ] && [ -n "$MEDIUM_SRC" ] && MEDIUM_DISK=$(basename "$MEDIUM_SRC")

part_path() { # $1=disk name (sda/nvme0n1), $2=partition number
  case "$1" in
    nvme*|mmcblk*) echo "/dev/$1p$2" ;;
    *) echo "/dev/$1$2" ;;
  esac
}

# --- choose target disk ---
say "=== 34OS-Installer ==="
say "インストール先のディスクを選んでください（ライブメディア自身は選べません）:"
mapfile -t ALL_DISKS < <(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}')
DISKS=()
i=1
for d in "${ALL_DISKS[@]}"; do
  [ "$d" = "$MEDIUM_DISK" ] && continue
  case "$d" in loop*|ram*|fd*) continue ;; esac
  DISKS+=("$d")
  printf '  %d) %s\n' "$i" "$(lsblk -dno NAME,SIZE,MODEL "/dev/$d" | sed 's/  */ /g')"
  i=$((i+1))
done
[ "${#DISKS[@]}" -gt 0 ] || diecode AVAILABLE_INSTALL_DISK_NOT_FOUND "インストールできるディスクがありません。"
printf '番号: '; read -r NUM || exit 1
case "$NUM" in ''|*[!0-9]*) diecode NOT_ENTERED_NUMBER "番号を入力してください。" ;; esac
[ "$NUM" -ge 1 ] && [ "$NUM" -le "${#DISKS[@]}" ] || diecode NOT_VALID_NUMBER "その番号は存在しないか、利用できません。"
DISK_NAME="${DISKS[$((NUM-1))]}"
DISK="/dev/$DISK_NAME"
DISK_BYTES=$(lsblk -bdno SIZE "$DISK")
say "対象: $DISK （約 $((DISK_BYTES/1024/1024/1024))GB）"

# --- choose mode ---
say ""
say "モードを選んでください:"
say "  1) ディスク内を全て消去し、新たにインストールする（中身は全部消えます）"
say "  2) デュアルブート（既存のパーティションには触らず、空き領域に入れます）"
printf '番号: '; read -r MODE || exit 1
[ "$MODE" = "1" ] || [ "$MODE" = "2" ] || die "1 か 2 を選んでください"

UEFI=0; [ -d /sys/firmware/efi ] && UEFI=1
TGT=/mnt/34os-target
ESP_PART=""; ROOT_PART=""

show_disk_state() {
  say "--- 現在の $DISK の中身 ---"
  lsblk -o NAME,SIZE,FSTYPE,LABEL "$DISK" || true
  if command -v os-prober >/dev/null 2>&1; then
    FOUND=$(timeout 30 os-prober 2>/dev/null | grep "^$DISK" || true)
    [ -n "$FOUND" ] && { say "検出された OS:"; say "$FOUND"; }
  fi
}

if [ "$MODE" = "1" ]; then
  # ============ WIPE ============
  [ "$DISK_BYTES" -ge 8589934592 ] || die "ディスクが小さすぎます（8GB 以上が必要です）"
  show_disk_state
  say ""
  say "!!! 警告: $DISK の中身の**すべてが削除されます**。この操作は元には戻せません !!!"
  printf '本当に消去してよろしいですか？（yes と入力）: '; read -r A1 || exit 1
  [ "$A1" = "yes" ] || die "中止しました。"
  printf '本当に？（確認のため、対象のディスク名（%s）を入力してください）: ' "$DISK_NAME"; read -r A2 || exit 1
  [ "$A2" = "$DISK_NAME" ] || diecode MISMATCH_DISKNAME "ディスク名が一致しません。中止しました。"
  printf '最終確認です。本当に消す場合は DELETE と入力してください。消したデータは元には戻りません。 **こうかいしませんね？**: '; read -r A3 || exit 1
  [ "$A3" = "DELETE" ] || die "中止しました。"

  if [ "$UEFI" -eq 1 ]; then
    parted -s "$DISK" mklabel gpt || diecode CREATE_PARTITION_FAILED "パーティション作成に失敗しました"
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB || diecode CREATE_PARTITION_FAILED "パーティション作成に失敗しました"
    parted -s "$DISK" set 1 esp on || true
    parted -s "$DISK" mkpart root ext4 513MiB 100% || diecode CREATE_PARTITION_FAILED "パーティション作成に失敗しました"
    ESP_PART=$(part_path "$DISK_NAME" 1); ROOT_PART=$(part_path "$DISK_NAME" 2)
  else
    parted -s "$DISK" mklabel msdos || diecode CREATE_PARTITION_FAILED "パーティション作成に失敗しました"
    parted -s "$DISK" mkpart primary ext4 1MiB 100% || diecode CREATE_PARTITION_FAILED "パーティション作成に失敗しました"
    parted -s "$DISK" set 1 boot on || true
    ROOT_PART=$(part_path "$DISK_NAME" 1)
  fi
  partprobe "$DISK" 2>/dev/null || true; udevadm settle || true
  [ -n "$ESP_PART" ] && { mkfs.vfat -F 32 "$ESP_PART" >/dev/null || diecode ESP_FORMAT_FAILED "ESP のフォーマットに失敗しました"; }
  mkfs.ext4 -F "$ROOT_PART" >/dev/null || diecode FORMAT_FAILED "フォーマットに失敗しました"
else
  # ============ DUAL BOOT ============
  show_disk_state
  # largest free region (MiB) from parted machine output
  FREE_LINE=$(parted -sm "$DISK" unit MiB print free 2>/dev/null | awk -F: '$5=="free;"{gsub(/MiB/,"",$2); gsub(/MiB/,"",$3); gsub(/MiB/,"",$4); print $4, $2, $3}' | sort -rn | head -1)
  [ -n "$FREE_LINE" ] || diecode NOT_FOUND_SPACE "空き領域が見つかりません。先に既存OS側で領域を空けてください"
  FREE_SIZE=$(printf '%s' "$FREE_LINE" | awk '{printf "%d", $1}')
  FREE_START=$(printf '%s' "$FREE_LINE" | awk '{printf "%d", $2}')
  FREE_END=$(printf '%s' "$FREE_LINE" | awk '{printf "%d", $3}')
  NEED=10240; [ "$UEFI" -eq 1 ] && NEED=10752
  [ "$FREE_SIZE" -ge "$NEED" ] || diecode NOT_ENOUGH_SPACE "空き領域が足りません（${FREE_SIZE}MiBしかありません。10GB以上空けてください）"
  say ""
  say "空き領域 ${FREE_SIZE}MiB（${FREE_START}MiB 〜 ${FREE_END}MiB）に 34OS を入れます。"
  say "既存のパーティションは変更しません。"
  printf '実行しますか？（yes と入力）: '; read -r A1 || exit 1
  [ "$A1" = "yes" ] || die "中止しました。"
  printf '確認のため、対象のディスク名（%s）を入力してください: ' "$DISK_NAME"; read -r A2 || exit 1
  [ "$A2" = "$DISK_NAME" ] || diecode MISMATCH_DISKNAME "ディスク名が一致しません。中止しました。"

  BEFORE=$(lsblk -lnpo NAME "$DISK" | tail -n +2 | sort)
  ROOT_START=$FREE_START
  if [ "$UEFI" -eq 1 ]; then
    ESP_NUM=$(parted -s "$DISK" print 2>/dev/null | awk '/esp/{print $1; exit}')
    case "$ESP_NUM" in ''|*[!0-9]*) ESP_NUM="" ;; esac
    if [ -n "$ESP_NUM" ]; then
      ESP_PART=$(part_path "$DISK_NAME" "$ESP_NUM")
      say "既存の EFI パーティション（$ESP_PART）を共用します（フォーマットしません）"
    else
      parted -s "$DISK" unit MiB mkpart ESP fat32 "${FREE_START}MiB" "$((FREE_START+512))MiB" || diecode CREATE_PARTITION_FAILED "パーティション作成に失敗しました"
      NEWEST=$(comm -13 <(printf '%s\n' "$BEFORE") <(lsblk -lnpo NAME "$DISK" | tail -n +2 | sort) | head -1)
      ESP_PART="$NEWEST"
      ESP_N=$(basename "$ESP_PART" | grep -o '[0-9]*$')
      parted -s "$DISK" set "$ESP_N" esp on || true
      partprobe "$DISK" 2>/dev/null || true; udevadm settle || true
      mkfs.vfat -F 32 "$ESP_PART" >/dev/null || diecode ESP_FORMAT_FAILED "ESP のフォーマットに失敗しました"
      BEFORE=$(lsblk -lnpo NAME "$DISK" | tail -n +2 | sort)
      ROOT_START=$((FREE_START+512))
    fi
  fi
  # parted rejects an end position exactly at the device size, so use
  # 100% when the free region reaches the end of the disk.
  END_ARG="${FREE_END}MiB"
  DISK_MIB=$((DISK_BYTES/1024/1024))
  [ "$FREE_END" -ge $((DISK_MIB-1)) ] && END_ARG="100%"
  parted -s "$DISK" unit MiB mkpart primary ext4 "${ROOT_START}MiB" "$END_ARG" || diecode CREATE_PARTITION_FAILED "パーティション作成に失敗しました"
  partprobe "$DISK" 2>/dev/null || true; udevadm settle || true
  ROOT_PART=$(comm -13 <(printf '%s\n' "$BEFORE") <(lsblk -lnpo NAME "$DISK" | tail -n +2 | sort) | head -1)
  [ -n "$ROOT_PART" ] || diecode PARTITION_SPECIFY_FAILED "作成したパーティションを特定できませんでした"
  mkfs.ext4 -F "$ROOT_PART" >/dev/null || diecode FORMAT_FAILED "フォーマットに失敗しました"
fi

# --- account / hostname ---
say ""
while :; do
  printf 'インストール後のユーザー名（英小文字で。live 用の user は使えません）: '; read -r NEWUSER || exit 1
  case "$NEWUSER" in
    user|root) say "その名前は使えません。" ;;
    [a-z]*) case "$NEWUSER" in *[!a-z0-9_-]*) say "使えるのは英小文字・数字・- _ です。" ;; *) break ;; esac ;;
    *) say "英小文字で始めてください。" ;;
  esac
done
while :; do
  printf 'パスワード: '; read -rs NEWPASS; say ""
  [ -n "$NEWPASS" ] || { say "パスワードを入力してください"; continue; }
  printf 'パスワード（確認）: '; read -rs NEWPASS2; say ""
  [ "$NEWPASS" = "$NEWPASS2" ] && break
  say "パスワードが一致しません。もう一度入力してください"
done
printf 'ホスト名 [34os]: '; read -r NEWHOST || exit 1
[ -z "$NEWHOST" ] && NEWHOST=34os
case "$NEWHOST" in *[!a-z0-9-]*) say "ホスト名に使用できない文字があります。自動でホスト名は 34os になります"; NEWHOST=34os ;; esac

# --- copy the system ---
say ""
say "システムをコピーしています（数分かかります）..."
mkdir -p "$TGT"
mount "$ROOT_PART" "$TGT" || diecode MOUNT_FAILED "マウントに失敗しました"
cleanup_mounts() {
  umount "$TGT/boot/efi" 2>/dev/null || true
  umount "$TGT/sys" "$TGT/proc" "$TGT/dev/pts" "$TGT/dev" 2>/dev/null || true
  umount "$TGT" 2>/dev/null || true
}
trap cleanup_mounts EXIT
if [ -n "$ESP_PART" ]; then
  mkdir -p "$TGT/boot/efi"
  mount "$ESP_PART" "$TGT/boot/efi" || diecode ESP_MOUNT_FAILED "ESP のマウントに失敗しました"
fi
unsquashfs -f -d "$TGT" "$SQFS" >/dev/null || diecode COPY_FAILED "コピーに失敗しました"

# drop build-time leftovers that must not ship to an installed system
rm -f "$TGT/etc/apt/apt.conf.d/99build-proxy"
printf '# managed by the system\n' > "$TGT/etc/resolv.conf"
rm -f "$TGT/etc/sudoers.d/34os"

# The live squashfs excludes the kernel and initrd (on the ISO they live in
# /casper, outside the squashfs), so the copy above leaves only dangling
# /boot symlinks and the installed system cannot boot. Copy them from the
# live medium under their versioned names.
KVER=$(uname -r)
CASPER_DIR=$(dirname "$SQFS")
[ -f "$CASPER_DIR/vmlinuz" ] || diecode NOT_FOUND_KERNEL_ON_LIVEMEDIA "ライブメディアに kernel が見つかりません"
cp "$CASPER_DIR/vmlinuz" "$TGT/boot/vmlinuz-$KVER" || diecode KERNEL_COPY_FAILED "kernel のコピーに失敗しました"
cp "$CASPER_DIR/initrd.img" "$TGT/boot/initrd.img-$KVER" || diecode INITRD_COPY_FAILED "initrd のコピーに失敗しました"

# fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
{
  echo "UUID=$ROOT_UUID / ext4 defaults 0 1"
  if [ -n "$ESP_PART" ]; then
    ESP_UUID=$(blkid -s UUID -o value "$ESP_PART")
    echo "UUID=$ESP_UUID /boot/efi vfat umask=0077 0 1"
  fi
} > "$TGT/etc/fstab"
echo "$NEWHOST" > "$TGT/etc/hostname"
sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $NEWHOST/" "$TGT/etc/hosts"

# --- configure inside the target ---
mount --bind /dev "$TGT/dev"; mount --bind /dev/pts "$TGT/dev/pts"
mount -t proc proc "$TGT/proc"; mount -t sysfs sys "$TGT/sys"
printf '#!/bin/sh\nexit 101\n' > "$TGT/usr/sbin/policy-rc.d"; chmod +x "$TGT/usr/sbin/policy-rc.d"

chroot "$TGT" apt-get purge -y live-boot live-boot-initramfs-tools live-tools >/dev/null 2>&1 || true
chroot "$TGT" userdel -r user >/dev/null 2>&1 || true
chroot "$TGT" useradd -m -s /bin/bash -G sudo,video,input "$NEWUSER" || diecode USER_CREATE_FAILED "ユーザー作成に失敗しました"
printf '%s:%s\n' "$NEWUSER" "$NEWPASS" | chroot "$TGT" chpasswd || diecode PASSWORD_SET_FAILED "パスワード設定に失敗しました"

if grep -q '^#GRUB_DISABLE_OS_PROBER' "$TGT/etc/default/grub" 2>/dev/null; then
  sed -i 's/^#GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$TGT/etc/default/grub"
elif ! grep -q '^GRUB_DISABLE_OS_PROBER' "$TGT/etc/default/grub" 2>/dev/null; then
  echo 'GRUB_DISABLE_OS_PROBER=false' >> "$TGT/etc/default/grub"
fi

say "ブートローダをインストールしています..."
if [ "$UEFI" -eq 1 ]; then
  chroot "$TGT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=34OS || diecode GRUB_INSTALL_FAILED "GRUB のインストールに失敗しました"
  # removable-media fallback path, in case the NVRAM entry is ignored
  if [ -f "$TGT/boot/efi/EFI/34OS/grubx64.efi" ]; then
    mkdir -p "$TGT/boot/efi/EFI/BOOT"
    cp "$TGT/boot/efi/EFI/34OS/grubx64.efi" "$TGT/boot/efi/EFI/BOOT/BOOTX64.EFI" || true
  fi
else
  chroot "$TGT" grub-install --target=i386-pc "$DISK" || diecode GRUB_INSTALL_FAILED "GRUB のインストールに失敗しました"
fi
chroot "$TGT" update-initramfs -u || diecode INITRAMFS_REGENERATION_FAILED "initramfs の再生成に失敗しました"
chroot "$TGT" update-grub || diecode GRUB_SETTING_GENERATION_FAILED "GRUB 設定の生成に失敗しました"
rm -f "$TGT/usr/sbin/policy-rc.d"

cleanup_mounts
trap - EXIT
sync
say ""
say "=== インストール完了 ==="
say "ライブメディアを取り外して、再起動してください。"
say "ログイン: $NEWUSER パスワード:（設定したパスワード）"
