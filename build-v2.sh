#!/usr/bin/env bash
# 34OS v1 prototype build: CLI-only live ISO on Ubuntu 24.04 (noble) minbase
set -euo pipefail
cd "$(dirname "$0")"

SUITE=noble
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu/}"
WORK="/mnt/34os/build"
mkdir -p "$WORK"
ROOTFS=$WORK/rootfs
ISODIR=$WORK/iso
OUT=34os-v2.iso
LOG=build-v1.log

exec > >(tee -a "$LOG") 2>&1
echo "=== 34OS v1 build started: $(date -Is) ==="

# 1) base system (minbase) — pass proxy env through sudo for debootstrap's wget
if [ ! -d "$ROOTFS/bin" ]; then
  sudo rm -rf "$ROOTFS"
  sudo env http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" HTTP_PROXY="${http_proxy:-}" HTTPS_PROXY="${https_proxy:-}" \
    TAR_OPTIONS="--no-same-owner" \
    debootstrap --variant=minbase "$SUITE" "$ROOTFS" "$MIRROR"
fi

# helper to run commands inside the rootfs
in_chroot() { sudo chroot "$ROOTFS" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive "$@"; }

# chroot needs /proc mounted and a writable /dev/null.
# (This sandbox forbids mknod and cross-session mounts, so do it here, every run:
#  /proc is mounted fresh, and debootstrap's regular-file /dev/null is made world-writable.)
sudo mountpoint -q "$ROOTFS/proc" || sudo mount -t proc proc "$ROOTFS/proc" || true
[ -f "$ROOTFS/dev/null" ] && sudo chmod 666 "$ROOTFS/dev/null" || true

# 2) sources + packages (kernel, live boot, editor, locale)
# chroot has no DNS config of its own; copy the host's resolv.conf and hosts in
# (hosts maps the egress proxy name to the gateway; without it apt resolves a dead fake IP)
sudo cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" || true
sudo cp /etc/hosts "$ROOTFS/etc/hosts" || true
# apt inside chroot needs the proxy written to a config file (env is cleared in chroot)
if [ -n "${http_proxy:-}" ]; then
  printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$http_proxy" "$https_proxy" \
    | sudo tee "$ROOTFS/etc/apt/apt.conf.d/99build-proxy" >/dev/null
fi
echo "deb $MIRROR $SUITE main universe" | sudo tee "$ROOTFS/etc/apt/sources.list" >/dev/null
echo "deb $MIRROR $SUITE-updates main universe" | sudo tee -a "$ROOTFS/etc/apt/sources.list" >/dev/null
echo "34os" | sudo tee "$ROOTFS/etc/hostname" >/dev/null

# v1 branding: show 34OS, not Ubuntu (login banner + release info)
sudo tee "$ROOTFS/etc/issue" >/dev/null <<'EOS'
34OS v2 \n \l
EOS
sudo sed -i 's/^NAME=.*/NAME="34OS"/; s/^PRETTY_NAME=.*/PRETTY_NAME="34OS v2"/' "$ROOTFS/etc/os-release"
if [ -f "$ROOTFS/etc/lsb-release" ]; then
  sudo sed -i 's/^DISTRIB_ID=.*/DISTRIB_ID=34OS/; s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION="34OS v2"/' "$ROOTFS/etc/lsb-release"
fi

# v2: ca-certificates first: the Mozilla repo is HTTPS-only and a fresh
# minbase chroot cannot verify TLS yet. Without this, apt silently skips
# the Mozilla repo and Ubuntu's snap-stub firefox gets installed instead
# (this killed the first v2 CI run at the langpack download).
in_chroot apt-get update
in_chroot apt-get install -y --no-install-recommends ca-certificates

# v2: Mozilla official APT repository (Firefox .deb, no snap)
sudo mkdir -p "$ROOTFS/etc/apt/keyrings"
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg | sudo tee "$ROOTFS/etc/apt/keyrings/packages.mozilla.org.asc" >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" | sudo tee "$ROOTFS/etc/apt/sources.list.d/mozilla.list" >/dev/null
printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' | sudo tee "$ROOTFS/etc/apt/preferences.d/mozilla" >/dev/null

in_chroot apt-get update
in_chroot apt-get install -y --no-install-recommends \
  linux-image-generic live-boot systemd-sysv \
  bash nano locales sudo \
  iproute2 iputils-ping less man-db fbterm fonts-vlgothic kbd \
  grub-pc-bin grub-efi-amd64-bin grub-common grub2-common os-prober dosfstools squashfs-tools parted efibootmgr

# v2: GUI pack (X + Fluxbox + apps + Japanese input + network + sound)
in_chroot apt-get install -y --no-install-recommends \
  xserver-xorg-core xserver-xorg-legacy xserver-xorg-input-libinput xserver-xorg-video-fbdev xserver-xorg-video-vesa \
  xinit x11-xserver-utils x11-apps procps \
  fluxbox sakura pcmanfm galculator abiword \
  fcitx5 fcitx5-mozc \
  network-manager network-manager-gnome policykit-1-gnome \
  alsa-utils apulse librsvg2-common volumeicon-alsa cbatticon \
  feh mpv scrot firefox

# v2: Firefox Japanese langpack. The Mozilla APT repo ships no l10n debs,
# so bundle the official langpack XPI matching the installed Firefox version.
FFVER=$(in_chroot dpkg-query -W -f='${Version}' firefox | sed -e 's/^[^:]*://' -e 's/~.*//' -e 's/-.*//')
case "$FFVER" in *snap*) echo "ERROR: Ubuntu snap-stub firefox installed; Mozilla repo/pin failed" >&2; exit 1;; esac
echo "Firefox version for langpack: $FFVER"
sudo mkdir -p "$ROOTFS/usr/lib/firefox/browser/extensions"
curl -fsSL "https://releases.mozilla.org/pub/firefox/releases/${FFVER}/linux-x86_64/xpi/ja.xpi" | sudo tee "$ROOTFS/usr/lib/firefox/browser/extensions/langpack-ja@firefox.mozilla.org.xpi" >/dev/null

# locale: Japanese only
echo "ja_JP.UTF-8 UTF-8" | sudo tee "$ROOTFS/etc/locale.gen" >/dev/null
in_chroot locale-gen ja_JP.UTF-8
echo "LANG=ja_JP.UTF-8" | sudo tee "$ROOTFS/etc/default/locale" >/dev/null

# live user: created at build time (this image has no live-config, so nothing
# would create the account at boot and the getty login could never succeed).
# Login: user / live. Sudo is passwordless.
in_chroot useradd -m -s /bin/bash user
in_chroot usermod -aG video,input user
echo "user:live" | in_chroot chpasswd
echo "user ALL=(ALL) NOPASSWD:ALL" | sudo tee "$ROOTFS/etc/sudoers.d/34os" >/dev/null
sudo chmod 440 "$ROOTFS/etc/sudoers.d/34os"

# --- v1: custom commands (GUI ones activate when the v2 GUI pack is present) ---
sudo tee "$ROOTFS/usr/local/bin/help" >/dev/null <<'EOS'
#!/bin/bash
cat <<'EOT'
34OS で使えるコマンド
  ls / cat / man / nano    見る・読む・編集する
  mkdir / rm / mv / cp     ファイル操作
  grep                     文字列を探す
  sudo / apt               管理・ソフトの追加
  browser                  ブラウザを開く
  img <ファイル>           画像を表示する
  play <ファイル>          動画を再生する
  gogui                    GUI を起動する
  gocli                    CLI に戻る
  install34                ディスクにインストールする
  help                     この一覧
EOT
EOS

sudo tee "$ROOTFS/usr/local/bin/gogui" >/dev/null <<'EOS'
#!/bin/bash
if [ -x /usr/bin/fluxbox ] && [ -x /usr/bin/startx ]; then
  # The CLI front PATH hides helper commands (tty, expr, xauth, ...) that
  # startx and the X session scripts call by bare name. The GUI session
  # runs with the standard PATH; the CLI keeps the curated one.
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  exec /usr/bin/startx
fi
echo "GUIは、この環境にインストールされていません。34OS v2以降で使えるようになります。"
EOS

sudo tee "$ROOTFS/usr/local/bin/gocli" >/dev/null <<'EOS'
#!/bin/bash
if [ -n "${DISPLAY:-}" ]; then
  echo "CLI操作に切り替えました。"
  /usr/bin/pkill -x fluxbox
else
  echo "いまはCLIです。"
fi
EOS

sudo tee "$ROOTFS/usr/local/bin/browser" >/dev/null <<'EOS'
#!/bin/bash
for b in firefox chromium chromium-browser google-chrome; do
  if [ -x "/usr/bin/$b" ]; then
    if [ -x /usr/bin/apulse ]; then exec /usr/bin/apulse "/usr/bin/$b" "$@"; fi
    exec "/usr/bin/$b" "$@"
  fi
done
echo "ブラウザ（Firefox）は、この環境にインストールされていません。34OS v2以降で使えるようになります。"
EOS

sudo tee "$ROOTFS/usr/local/bin/img" >/dev/null <<'EOS'
#!/bin/bash
if [ -x /usr/bin/feh ]; then exec /usr/bin/feh "$@"; fi
echo "画像ビューアー（feh）は、この環境にインストールされていません。34OS v2以降で使えるようになります。"
EOS

sudo tee "$ROOTFS/usr/local/bin/play" >/dev/null <<'EOS'
#!/bin/bash
if [ -x /usr/bin/mpv ]; then exec /usr/bin/mpv "$@"; fi
echo "動画ビューアー（mpv）は、この環境にインストールされていません。34OS v2以降で使えるようになります。"
EOS

# v1.2: installer (install34) - installs the live system to disk
sudo tee "$ROOTFS/usr/local/bin/install34" >/dev/null <<'EOS34'
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
EOS34

sudo chmod +x "$ROOTFS/usr/local/bin/help" "$ROOTFS/usr/local/bin/gogui" "$ROOTFS/usr/local/bin/gocli" \
  "$ROOTFS/usr/local/bin/browser" "$ROOTFS/usr/local/bin/img" "$ROOTFS/usr/local/bin/play" \
  "$ROOTFS/usr/local/bin/install34"

# --- v1: front-stage PATH control ---
# Front commands are symlinks in /usr/local/34os-front. The live user's PATH
# is limited to the front stage + /usr/local/bin, so system internals stay
# installed but out of sight. Root keeps the full PATH.
FRONT_CMDS="ls cat man nano sudo apt mkdir rm mv cp grep less dircolors lesspipe basename dirname iconv col tbl nroff groff grotty eqn pic gzip groups"
sudo mkdir -p "$ROOTFS/usr/local/34os-front"
for c in $FRONT_CMDS; do
  for d in usr/bin bin usr/sbin sbin; do
    if [ -e "$ROOTFS/$d/$c" ]; then sudo ln -sf "/$d/$c" "$ROOTFS/usr/local/34os-front/$c"; break; fi
  done
done
printf 'export PATH="/usr/local/34os-front:/usr/local/bin"\n' | sudo tee "$ROOTFS/etc/profile.d/34os-path.sh" >/dev/null
printf '\n# 34OS v1: front-stage commands only\nexport PATH="/usr/local/34os-front:/usr/local/bin"\n' | sudo tee -a "$ROOTFS/etc/bash.bashrc" >/dev/null

printf 'enable -n help\n' | sudo tee -a "$ROOTFS/etc/bash.bashrc" >/dev/null

# v1 polish: 34OS login texts (replace the Ubuntu MOTD help text and legal)
printf '34OS本体のライセンスはWTFPLです。好きに改変してもらって構いません。改変版を配布する場合、同じWTFPLを継承してください。\n同梱プログラムのライセンスは各自のものを継承します。\n（/usr/share/doc/*/copyright を参照）\n' | sudo tee "$ROOTFS/etc/legal" >/dev/null
if [ -f "$ROOTFS/etc/update-motd.d/10-help-text" ]; then
  printf '#!/bin/sh\necho " * Help: type help for the 34OS command list"\n' | sudo tee "$ROOTFS/etc/update-motd.d/10-help-text" >/dev/null
  sudo chmod +x "$ROOTFS/etc/update-motd.d/10-help-text"
fi

# v1.2: ship a clean /etc/hosts. The build host's hosts file was copied in
# for build-time networking and must not ship; a proper 34os entry also
# fixes sudo's "unable to resolve host 34os" warning.
printf '127.0.0.1 localhost\n127.0.1.1 34os\n::1 localhost ip6-localhost ip6-loopback\nfe00::0 ip6-localnet\nff00::0 ip6-mcastprefix\nff02::1 ip6-allnodes\nff02::2 ip6-allrouters\n' | sudo tee "$ROOTFS/etc/hosts" >/dev/null
# v1.2: Japanese keyboard. The live user's keyboard is a JIS layout, so
# load the jp106 console keymap at boot (the default US map puts symbols
# on the wrong keys). /etc/default/keyboard also documents the layout
# for the future X session in v2.
printf 'XKBMODEL="pc105"\nXKBLAYOUT="jp"\nXKBVARIANT=""\nXKBOPTIONS=""\nBACKSPACE="guess"\n' | sudo tee "$ROOTFS/etc/default/keyboard" >/dev/null
sudo tee "$ROOTFS/etc/systemd/system/34os-keymap.service" >/dev/null <<'EOF3'

[Unit]
Description=34OS: load the Japanese console keymap
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/bin/loadkeys jp106
[Install]
WantedBy=multi-user.target
EOF3

# fbterm's shell startup path reads neither /etc/profile.d nor bashrc in
# a way we can hook, so give fbterm a wrapper shell: it wipes the keymap
# warning fbterm printed before spawning it, then hands over to bash.
sudo tee "$ROOTFS/usr/local/bin/34os-fbshell" >/dev/null <<'EOF4'
#!/bin/bash
# 34OS: first thing inside fbterm - clear its keymap warning, then bash.
printf '\033[H\033[2J'
FBTERM_CLEARED=1
export FBTERM_CLEARED
exec /bin/bash -l
EOF4
sudo chmod +x "$ROOTFS/usr/local/bin/34os-fbshell"
in_chroot systemctl enable 34os-keymap.service

# 34OS is Japanese-only: pin the timezone to JST (the base image is UTC).
in_chroot ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
printf 'Asia/Tokyo\n' | sudo tee "$ROOTFS/etc/timezone" >/dev/null

# v1.2: Japanese on the console. The raw console font has no Japanese
# glyphs (text renders as blocks), so tty1 sessions are handed to fbterm,
# which renders Japanese with VL Gothic. Other ttys stay plain (fallback).
printf 'font-names=DejaVu Sans Mono,VL Gothic\nfont-size=16\n' | sudo tee "$ROOTFS/home/user/.fbtermrc" "$ROOTFS/etc/skel/.fbtermrc" >/dev/null
in_chroot chown user:user /home/user/.fbtermrc
sudo tee "$ROOTFS/etc/profile.d/34os-fbterm.sh" >/dev/null <<'EOF2'
# 34OS: hand tty1 to fbterm so Japanese renders on the console.
if [ "$(/usr/bin/tty)" = "/dev/tty1" ] && [ -z "${FBTERM_STARTED:-}" ] && [ -x /usr/bin/fbterm ] && [ -e /dev/fb0 ]; then
  FBTERM_STARTED=1
  export FBTERM_STARTED
  exec /usr/bin/fbterm -- /usr/local/bin/34os-fbshell 2>/tmp/fbterm-start.log
elif [ -n "${FBTERM_STARTED:-}" ] && [ -z "${FBTERM_CLEARED:-}" ]; then
  # fbterm prints its keymap warning straight to the terminal, not to
  # stderr, so the redirect above cannot catch it. Wipe the screen once
  # the shell inside fbterm is up so the login starts clean.
  FBTERM_CLEARED=1
  export FBTERM_CLEARED
  printf '\033[H\033[2J'
fi
EOF2

# fbterm spawns a non-login shell, so /etc/profile.d is not sourced inside
# it. Hook the same one-time screen wipe into bashrc, which every
# interactive bash reads.
sudo tee -a "$ROOTFS/etc/bash.bashrc" >/dev/null <<'EOF3'
# 34OS: fbterm prints its keymap warning straight to the terminal before
# the shell starts; clear it once per fbterm session.
if [ -n "${FBTERM_STARTED:-}" ] && [ -z "${FBTERM_CLEARED:-}" ]; then
  FBTERM_CLEARED=1
  export FBTERM_CLEARED
  printf '\033[H\033[2J'
fi
EOF3



# v1.2: do not ship build-time network config (sandbox proxy / DNS)
sudo rm -f "$ROOTFS/etc/apt/apt.conf.d/99build-proxy"
printf '# managed by the system\n' | sudo tee "$ROOTFS/etc/resolv.conf" >/dev/null


# ============ v2 slimming ============
# Firmware for datacenter/server hardware and discrete GPUs: 34OS
# targets old laptops (integrated graphics, common Wi-Fi chipsets).
# Removing subpackages also removes the linux-firmware and
# linux-image-generic metas; the versioned kernel packages stay.
in_chroot apt-get remove -y linux-firmware-nvidia-graphics linux-firmware-mellanox-spectrum linux-firmware-marvell-prestera linux-firmware-qualcomm-misc linux-firmware-qlogic linux-firmware-netronome || true
# Extra kernel modules for uncommon hardware: the main modules
# package keeps the common laptop drivers (Puppy-style curation).
in_chroot bash -c "apt-get remove -y 'linux-modules-extra-*-generic'" || true
# iwlwifi firmware for API versions newer than kernel 6.8 requests:
# the driver asks for its own max API and walks down, and every
# version it can ask for stays on disk.
in_chroot bash -c 'rm -f /usr/lib/firmware/intel/iwlwifi/*-c9[1-9].ucode.zst /usr/lib/firmware/intel/iwlwifi/*-c10[0-9].ucode.zst /usr/lib/firmware/intel/iwlwifi/*-9[1-9].ucode.zst /usr/lib/firmware/intel/iwlwifi/*-10[0-9].ucode.zst' || true
# xz-compressed initramfs: a smaller live initrd for some boot CPU.
sudo printf 'COMPRESS=xz\n' | sudo tee "$ROOTFS/etc/initramfs-tools/conf.d/34os-compress.conf" >/dev/null
in_chroot update-initramfs -u || true

# ============ v2: GUI pack configuration ============
# NetworkManager on (Wi-Fi + hotspot are operated from the tray)
in_chroot systemctl enable NetworkManager || true

# Xorg.wrap only lets "console users" run X, but a session inside fbterm
# has a pty as its controlling terminal, so the check fails. 34OS is a
# single-user system: allow any local user to start the X server.
printf 'allowed_users=anybody\nneeds_root_rights=yes\n' | sudo tee "$ROOTFS/etc/X11/Xwrapper.config" >/dev/null

# wallpapers (bundled set; users can add their own into ~/Pictures)
sudo mkdir -p "$ROOTFS/usr/share/34os/wallpapers"
sudo cp ./wallpaper-34os-16x9.png "$ROOTFS/usr/share/34os/wallpapers/steam-locomotive.png"
sudo cp ./wallpaper-mountain-16x9.png "$ROOTFS/usr/share/34os/wallpapers/mountain-moon.png"
sudo cp ./wallpaper-lighthouse-16x9.png "$ROOTFS/usr/share/34os/wallpapers/lighthouse.png"
# the live user must be able to READ the wallpapers: files copied from
# the build tree land root-only (640), and pcmanfm then silently falls
# back to the plain background color
sudo chmod 644 "$ROOTFS/usr/share/34os/wallpapers/"*.png

# Firefox default preferences (homepage = the hidden page for 34OS users)
sudo mkdir -p "$ROOTFS/usr/lib/firefox/defaults/pref"
sudo tee "$ROOTFS/usr/lib/firefox/defaults/pref/34os-prefs.js" >/dev/null <<'EOF2'
pref("browser.startup.homepage", "https://34os.nekomimi0128.com/for-34os.html");
pref("browser.shell.checkDefaultBrowser", false);
pref("intl.locale.requested", "ja");
EOF2

# hotspot helper (NetworkManager; driven from the Fluxbox menu)
sudo tee "$ROOTFS/usr/local/bin/34os-hotspot" >/dev/null <<'EOF2'
#!/bin/bash
# 34OS hotspot helper: start/stop a Wi-Fi access point via NetworkManager.
SSID="34OS"
PASS="34os1234"
notify() {
  if [ -n "${DISPLAY:-}" ] && [ -x /usr/bin/xmessage ]; then
    /usr/bin/xmessage -center "$1" &
  else
    echo "$1"
  fi
}
case "${1:-}" in
  on)
    DEV=$(/usr/bin/nmcli -t -f DEVICE,TYPE device 2>/dev/null | /usr/bin/awk -F: '$2=="wifi"{print $1; exit}')
    if [ -z "$DEV" ]; then notify "エラー [WIFI_ADAPTER_NOT_FOUND]: Wi-Fiアダプタが見つからないので、ホットスポットは使えません。"; exit 1; fi
    if /usr/bin/nmcli device wifi hotspot ifname "$DEV" ssid "$SSID" password "$PASS"; then
      notify "ホットスポットを開始しました。SSID: $SSID / パスワード: $PASS"
    else
      notify "ホットスポットの開始に失敗しました。"
    fi
    ;;
  off)
    /usr/bin/nmcli connection down Hotspot >/dev/null 2>&1 && notify "ホットスポットを停止しました。"
    ;;
  *) echo "usage: 34os-hotspot on|off" ;;
esac
EOF2
sudo chmod +x "$ROOTFS/usr/local/bin/34os-hotspot"

# Fluxbox menu generator: Japanese menu; the wallpaper submenu is rebuilt
# from the wallpaper folders on every X start, so wallpapers a user drops
# into ~/Pictures show up automatically.
sudo tee "$ROOTFS/usr/local/bin/34os-genmenu" >/dev/null <<'EOF2'
#!/bin/bash
MENU="$HOME/.fluxbox/menu"
mkdir -p "$HOME/.fluxbox"
wp_label() {
  case "$(basename "$1")" in
    steam-locomotive.png) echo "加速する動輪（標準）" ;;
    mountain-moon.png) echo "月影" ;;
    lighthouse.png) echo "道標" ;;
    *) basename "$1" ;;
  esac
}
{
  echo '[begin] (34OS)'
  echo '  [exec] (Firefox) {/usr/local/bin/browser}'
  echo '  [exec] (書庫) {/usr/bin/pcmanfm}'
  echo '  [exec] (ターミナル) {/usr/bin/sakura}'
  echo '  [exec] (タイプライター) {/usr/bin/abiword}'
  echo '  [exec] (電卓) {/usr/bin/galculator}'
  echo '  [separator]'
  echo '  [submenu] (壁紙)'
  for f in /usr/share/34os/wallpapers/*.png /usr/share/34os/wallpapers/*.jpg "$HOME"/Pictures/*.png "$HOME"/Pictures/*.jpg; do
    [ -f "$f" ] || continue
    echo "    [exec] ($(wp_label "$f")) {/usr/bin/pcmanfm --set-wallpaper $f}"
  done
  echo '    [exec] (壁紙フォルダ) {/usr/bin/pcmanfm Pictures}'
  echo '  [end]'
  echo '  [submenu] (共感通信)'
  echo '    [exec] (スタート) {/usr/local/bin/34os-hotspot on}'
  echo '    [exec] (ストップ) {/usr/local/bin/34os-hotspot off}'
  echo '  [end]'
  echo '  [separator]'
  echo '  [workspaces] (作業場)'
  echo '  [config] (Fluxbox設定)'
  echo '  [separator]'
  echo '  [exec] (CLIに戻る) {/usr/local/bin/gocli}'
  echo '  [exec] (再起動) {/usr/bin/systemctl reboot}'
  echo '  [exec] (シャットダウン) {/usr/bin/systemctl poweroff}'
  echo '[end]'
} > "$MENU"
EOF2
sudo chmod +x "$ROOTFS/usr/local/bin/34os-genmenu"

# X session files for the live user and future users (skel)
for D in "$ROOTFS/etc/skel" "$ROOTFS/home/user"; do
  sudo mkdir -p "$D/.fluxbox" "$D/.config/fcitx5" "$D/.config/pcmanfm/default" "$D/Desktop" "$D/Pictures"
  sudo tee "$D/.xinitrc" >/dev/null <<'EOF2'
#!/bin/sh
# 34OS X session startup
/usr/bin/setxkbmap jp
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
[ -x /usr/local/bin/34os-genmenu ] && /usr/local/bin/34os-genmenu
/usr/bin/fcitx5 -d 2>/dev/null
/usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1 &
/usr/bin/nm-applet &
/usr/bin/volumeicon &
/usr/bin/cbatticon &
/usr/bin/pcmanfm --desktop &
exec /usr/bin/fluxbox
EOF2
  # ship a complete init: a partial one makes fluxbox log a
  # "Failed to read" line for every missing key when the session ends
  sudo tee "$D/.fluxbox/init" >/dev/null <<'EOF2'
session.screen0.toolbar.tools: workspacename, prevworkspace, nextworkspace, iconbar, systemtray, clock
session.screen0.clockFormat: %H:%M
session.screen0.toolbar.widthPercent: 100
session.screen0.workspaces: 2
session.screen0.toolbar.visible: true
session.screen0.toolbar.alpha: 255
session.screen0.toolbar.layer: AboveDock
session.screen0.toolbar.onhead: 0
session.screen0.toolbar.placement: BottomCenter
session.screen0.toolbar.height: 0
session.screen0.iconbar.alignment: Relative
session.screen0.iconbar.iconWidth: 128
session.screen0.iconbar.iconTextPadding: 10
session.screen0.iconbar.usePixmap: true
session.screen0.strftimeFormat: %H:%M
session.screen0.titlebar.left: Stick
session.screen0.titlebar.right: Minimize Maximize Close
session.screen0.toolbar.autoHide: false
session.screen0.toolbar.maxOver: false
session.screen0.slit.acceptKdeDockapps: true
session.screen0.slit.autoHide: false
session.screen0.slit.maxOver: false
session.screen0.slit.alpha: 255
session.screen0.slit.onhead: 0
session.screen0.slit.layer: AboveDock
EOF2
  sudo tee "$D/.config/fcitx5/profile" >/dev/null <<'EOF2'
[Groups/0]
Name=Default
Default Layout=jp
DefaultIM=mozc

[Groups/0/Items/0]
Name=keyboard-jp
Layout=

[Groups/0/Items/1]
Name=mozc
Layout=

[GroupOrder]
0=Default
EOF2
  sudo tee "$D/.config/pcmanfm/default/pcmanfm.conf" >/dev/null <<'EOF2'
[desktop]
wallpaper_mode=crop
wallpaper=/usr/share/34os/wallpapers/steam-locomotive.png
desktop_bg=#1a1d20
show_documents=0
show_trash=1
show_home=1
show_mounts=0
EOF2
done
sudo chmod +x "$ROOTFS/etc/skel/.xinitrc" "$ROOTFS/home/user/.xinitrc"
in_chroot chown -R user:user /home/user/.xinitrc /home/user/.fluxbox /home/user/.config /home/user/Desktop /home/user/Pictures

# desktop icons: the apps' own .desktop files (they carry Japanese names)
for app in firefox pcmanfm sakura abiword galculator; do
  if [ -f "$ROOTFS/usr/share/applications/$app.desktop" ]; then
    sudo cp "$ROOTFS/usr/share/applications/$app.desktop" "$ROOTFS/etc/skel/Desktop/"
    sudo cp "$ROOTFS/usr/share/applications/$app.desktop" "$ROOTFS/home/user/Desktop/"
  fi
done
in_chroot chown -R user:user /home/user/Desktop

# 3) slimming: docs, apt cache/lists
in_chroot apt-get clean
sudo rm -rf "$ROOTFS/usr/share/doc/"* \
            "$ROOTFS/var/lib/apt/lists/"* "$ROOTFS/var/cache/apt/"*.bin \
            "$ROOTFS/tmp/"* "$ROOTFS/root/.bash_history" 2>/dev/null || true

# firmware trim: keep common NIC / Wi-Fi only (linux-firmware alone is ~650MB;
# nvidia/mellanox/qcom etc. are dead weight for a minimal live ISO)
if [ -d "$ROOTFS/usr/lib/firmware" ]; then
  sudo find "$ROOTFS/usr/lib/firmware" -mindepth 1 -maxdepth 1 \
    ! -name 'rtl_nic' ! -name 'iwlwifi-*' ! -name 'intel' \
    ! -name 'rtw88' ! -name 'rtw89' ! -name 'ath10k' ! -name 'ath11k' \
    ! -name 'brcm' ! -name 'e100' ! -name 'tigon' \
    -exec rm -rf {} +
fi

# unmount /proc and empty the fake /dev/null before measuring / packing
sudo umount "$ROOTFS/proc" 2>/dev/null || true
[ -f "$ROOTFS/dev/null" ] && sudo truncate -s 0 "$ROOTFS/dev/null" || true

echo "--- rootfs size (uncompressed) ---"
sudo du -sh "$ROOTFS" || true

# 4) squashfs + kernel/initrd for live boot
mkdir -p "$ISODIR/casper" "$ISODIR/boot/grub"
sudo rm -f "$ISODIR/casper/filesystem.squashfs"
sudo mksquashfs "$ROOTFS" "$ISODIR/casper/filesystem.squashfs" -comp xz -b 1048576 -noappend -wildcards -e "boot/vmlinuz-*" "boot/initrd.img-*" || \
sudo mksquashfs "$ROOTFS" "$ISODIR/casper/filesystem.squashfs" -comp xz -b 1048576 -noappend

VMLINUZ=$(ls "$ROOTFS"/boot/vmlinuz-* | sort -V | tail -1)
INITRD=$(ls "$ROOTFS"/boot/initrd.img-* | sort -V | tail -1)
sudo cp "$VMLINUZ" "$ISODIR/casper/vmlinuz"
sudo cp "$INITRD" "$ISODIR/casper/initrd.img"
sudo chown -R "$(id -u):$(id -g)" "$ISODIR"

cat > "$ISODIR/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=5
menuentry "34OS v2 (live)" {
  linux /casper/vmlinuz boot=live live-media-path=/casper hostname=34os locales=ja_JP.UTF-8 ---
  initrd /casper/initrd.img
}
EOF
echo "34OS v2" > "$ISODIR/README.txt"

# 5) ISO (BIOS + UEFI hybrid via grub-mkrescue)
rm -f "$OUT"
grub-mkrescue -o "$OUT" "$ISODIR"

echo "--- result ---"
du -h "$ISODIR/casper/filesystem.squashfs" "$OUT"
echo "=== 34OS v1 build finished: $(date -Is) ==="
