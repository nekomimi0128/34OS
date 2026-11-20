#!/usr/bin/env bash
# 34OS v1 build for GitHub Actions (ubuntu-24.04 runner) / any normal Ubuntu host.
# The local sandbox build (build-v0.sh) needs several workarounds that a normal
# machine does not, so CI uses this clean version.
set -euo pipefail
cd "$(dirname "$0")"

SUITE=noble
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu/}"
WORK="$PWD/build"
ROOTFS=$WORK/rootfs
ISODIR=$WORK/iso
OUT="$PWD/34os-v1.2.iso"

echo "=== 34OS v1 CI build started: $(date -Is) ==="

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

# v1 branding: show 34OS, not Ubuntu (login banner + release info)
sudo tee "$ROOTFS/etc/issue" >/dev/null <<'EOS'
34OS v1.2 \n \l
EOS
sudo sed -i 's/^NAME=.*/NAME="34OS"/; s/^PRETTY_NAME=.*/PRETTY_NAME="34OS v1.2"/' "$ROOTFS/etc/os-release"
if [ -f "$ROOTFS/etc/lsb-release" ]; then
  sudo sed -i 's/^DISTRIB_ID=.*/DISTRIB_ID=34OS/; s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION="34OS v1.2"/' "$ROOTFS/etc/lsb-release"
fi

in_chroot apt-get update
in_chroot apt-get install -y --no-install-recommends \
  linux-image-generic live-boot systemd-sysv \
  bash nano locales sudo zstd \
  iproute2 iputils-ping less man-db fbterm fonts-vlgothic kbd \
  grub-pc-bin grub-efi-amd64-bin grub-common grub2-common os-prober dosfstools squashfs-tools parted efibootmgr

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
if command -v fluxbox >/dev/null 2>&1; then
  exec startx /usr/bin/fluxbox -- :0
fi
echo "GUIパックはまだ入っていません（v2で追加されます）。いまはCLIで操作してください。"
EOS

sudo tee "$ROOTFS/usr/local/bin/gocli" >/dev/null <<'EOS'
#!/bin/bash
if [ -n "${DISPLAY:-}" ]; then
  echo "GUIを終了するには、Fluxboxのメニューから Exit を選んでください。"
else
  echo "いまはCLIです。"
fi
EOS

sudo tee "$ROOTFS/usr/local/bin/browser" >/dev/null <<'EOS'
#!/bin/bash
for b in firefox chromium chromium-browser google-chrome; do
  if command -v "$b" >/dev/null 2>&1; then exec "$b" "$@"; fi
done
echo "ブラウザはまだ入っていません（GUIパック＝v2で追加されます）。"
EOS

sudo tee "$ROOTFS/usr/local/bin/img" >/dev/null <<'EOS'
#!/bin/bash
if command -v feh >/dev/null 2>&1; then exec feh "$@"; fi
echo "画像ビューア（feh）はまだ入っていません（GUIパック＝v2で追加されます）。"
EOS

sudo tee "$ROOTFS/usr/local/bin/play" >/dev/null <<'EOS'
#!/bin/bash
if command -v mpv >/dev/null 2>&1; then exec mpv "$@"; fi
echo "動画プレイヤー（mpv）はまだ入っていません（GUIパック＝v2で追加されます）。"
EOS

# v1.2: installer (install34) - installs the live system to disk
sudo tee "$ROOTFS/usr/local/bin/install34" >/dev/null <<'EOS34'
#!/bin/bash
# install34 - 34OS installer: installs the running live system to a disk.
# Modes: wipe (whole disk) / dual boot (install into free space).
set -u

say() { printf '%s\n' "$*"; }
die() { say "エラー: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root で実行してください: sudo install34"

# --- find the live medium (source squashfs) ---
SQFS=""
for p in /run/live/medium/casper/filesystem.squashfs \
         /lib/live/mount/medium/casper/filesystem.squashfs \
         /cdrom/casper/filesystem.squashfs; do
  [ -f "$p" ] && SQFS="$p" && break
done
[ -n "$SQFS" ] || die "ライブ環境から実行してください（コピー元が見つかりません）"
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
say "=== 34OS インストーラ ==="
say "インストール先のディスクを選んでください（ライブメディア自身は選べません）:"
mapfile -t ALL_DISKS < <(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}')
DISKS=()
i=1
for d in "${ALL_DISKS[@]}"; do
  [ "$d" = "$MEDIUM_DISK" ] && continue
  case "$d" in loop*|ram*) continue ;; esac
  DISKS+=("$d")
  printf '  %d) %s\n' "$i" "$(lsblk -dno NAME,SIZE,MODEL "/dev/$d" | sed 's/  */ /g')"
  i=$((i+1))
done
[ "${#DISKS[@]}" -gt 0 ] || die "インストールできるディスクがありません"
printf '番号: '; read -r NUM || exit 1
case "$NUM" in ''|*[!0-9]*) die "番号を入力してください" ;; esac
[ "$NUM" -ge 1 ] && [ "$NUM" -le "${#DISKS[@]}" ] || die "その番号はありません"
DISK_NAME="${DISKS[$((NUM-1))]}"
DISK="/dev/$DISK_NAME"
DISK_BYTES=$(lsblk -bdno SIZE "$DISK")
say "対象: $DISK （約 $((DISK_BYTES/1024/1024/1024)) GB）"

# --- choose mode ---
say ""
say "モードを選んでください:"
say "  1) ディスク全消し（中身は全部消えます）"
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
  say "!!! 警告: $DISK の内容は **すべて消えます**。元に戻せません !!!"
  printf '本当に消しますか？（yes と入力）: '; read -r A1 || exit 1
  [ "$A1" = "yes" ] || die "中止しました"
  printf '確認のため、対象ディスク名（%s）を入力してください: ' "$DISK_NAME"; read -r A2 || exit 1
  [ "$A2" = "$DISK_NAME" ] || die "ディスク名が一致しません。中止しました"
  printf '最終確認。本当に消す場合は DELETE と入力してください: '; read -r A3 || exit 1
  [ "$A3" = "DELETE" ] || die "中止しました"

  if [ "$UEFI" -eq 1 ]; then
    parted -s "$DISK" mklabel gpt || die "パーティション作成に失敗しました"
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB || die "パーティション作成に失敗しました"
    parted -s "$DISK" set 1 esp on || true
    parted -s "$DISK" mkpart root ext4 513MiB 100% || die "パーティション作成に失敗しました"
    ESP_PART=$(part_path "$DISK_NAME" 1); ROOT_PART=$(part_path "$DISK_NAME" 2)
  else
    parted -s "$DISK" mklabel msdos || die "パーティション作成に失敗しました"
    parted -s "$DISK" mkpart primary ext4 1MiB 100% || die "パーティション作成に失敗しました"
    parted -s "$DISK" set 1 boot on || true
    ROOT_PART=$(part_path "$DISK_NAME" 1)
  fi
  partprobe "$DISK" 2>/dev/null || true; udevadm settle || true
  [ -n "$ESP_PART" ] && { mkfs.vfat -F 32 "$ESP_PART" >/dev/null || die "ESP のフォーマットに失敗しました"; }
  mkfs.ext4 -F "$ROOT_PART" >/dev/null || die "フォーマットに失敗しました"
else
  # ============ DUAL BOOT ============
  show_disk_state
  # largest free region (MiB) from parted machine output
  FREE_LINE=$(parted -sm "$DISK" unit MiB print free 2>/dev/null | awk -F: '$7=="free;"{gsub(/MiB/,"",$2); gsub(/MiB/,"",$3); gsub(/MiB/,"",$4); print $4, $2, $3}' | sort -rn | head -1)
  [ -n "$FREE_LINE" ] || die "空き領域が見つかりません。先に既存 OS 側で領域を空けてください"
  FREE_SIZE=$(printf '%s' "$FREE_LINE" | awk '{printf "%d", $1}')
  FREE_START=$(printf '%s' "$FREE_LINE" | awk '{printf "%d", $2}')
  FREE_END=$(printf '%s' "$FREE_LINE" | awk '{printf "%d", $3}')
  NEED=10240; [ "$UEFI" -eq 1 ] && NEED=10752
  [ "$FREE_SIZE" -ge "$NEED" ] || die "空き領域が足りません（${FREE_SIZE}MiB しかありません。10GB 以上空けてください）"
  say ""
  say "空き領域 ${FREE_SIZE}MiB（${FREE_START}MiB 〜 ${FREE_END}MiB）に 34OS を入れます。"
  say "既存のパーティションは変更しません。"
  printf '実行しますか？（yes と入力）: '; read -r A1 || exit 1
  [ "$A1" = "yes" ] || die "中止しました"
  printf '確認のため、対象ディスク名（%s）を入力してください: ' "$DISK_NAME"; read -r A2 || exit 1
  [ "$A2" = "$DISK_NAME" ] || die "ディスク名が一致しません。中止しました"

  BEFORE=$(lsblk -lnpo NAME "$DISK" | tail -n +2 | sort)
  ROOT_START=$FREE_START
  if [ "$UEFI" -eq 1 ]; then
    ESP_NUM=$(parted -s "$DISK" print 2>/dev/null | awk '/esp/{print $1; exit}')
    case "$ESP_NUM" in ''|*[!0-9]*) ESP_NUM="" ;; esac
    if [ -n "$ESP_NUM" ]; then
      ESP_PART=$(part_path "$DISK_NAME" "$ESP_NUM")
      say "既存の EFI パーティション（$ESP_PART）を共用します（フォーマットしません）"
    else
      parted -s "$DISK" unit MiB mkpart ESP fat32 "${FREE_START}MiB" "$((FREE_START+512))MiB" || die "パーティション作成に失敗しました"
      NEWEST=$(comm -13 <(printf '%s\n' "$BEFORE") <(lsblk -lnpo NAME "$DISK" | tail -n +2 | sort) | head -1)
      ESP_PART="$NEWEST"
      ESP_N=$(basename "$ESP_PART" | grep -o '[0-9]*$')
      parted -s "$DISK" set "$ESP_N" esp on || true
      partprobe "$DISK" 2>/dev/null || true; udevadm settle || true
      mkfs.vfat -F 32 "$ESP_PART" >/dev/null || die "ESP のフォーマットに失敗しました"
      BEFORE=$(lsblk -lnpo NAME "$DISK" | tail -n +2 | sort)
      ROOT_START=$((FREE_START+512))
    fi
  fi
  parted -s "$DISK" unit MiB mkpart primary ext4 "${ROOT_START}MiB" "${FREE_END}MiB" || die "パーティション作成に失敗しました"
  partprobe "$DISK" 2>/dev/null || true; udevadm settle || true
  ROOT_PART=$(comm -13 <(printf '%s\n' "$BEFORE") <(lsblk -lnpo NAME "$DISK" | tail -n +2 | sort) | head -1)
  [ -n "$ROOT_PART" ] || die "作成したパーティションを特定できませんでした"
  mkfs.ext4 -F "$ROOT_PART" >/dev/null || die "フォーマットに失敗しました"
fi

# --- account / hostname ---
say ""
while :; do
  printf 'インストール後のユーザー名（英小文字で。live 用の user は使えません）: '; read -r NEWUSER || exit 1
  case "$NEWUSER" in
    user|root) say "その名前は使えません" ;;
    [a-z]*) case "$NEWUSER" in *[!a-z0-9_-]*) say "使えるのは英小文字・数字・- _ です" ;; *) break ;; esac ;;
    *) say "英小文字で始めてください" ;;
  esac
done
while :; do
  printf 'パスワード: '; read -rs NEWPASS; say ""
  [ -n "$NEWPASS" ] || { say "パスワードを入力してください"; continue; }
  printf 'パスワード（確認）: '; read -rs NEWPASS2; say ""
  [ "$NEWPASS" = "$NEWPASS2" ] && break
  say "パスワードが一致しません。もう一度どうぞ"
done
printf 'ホスト名 [34os]: '; read -r NEWHOST || exit 1
[ -z "$NEWHOST" ] && NEWHOST=34os
case "$NEWHOST" in *[!a-z0-9-]*) say "ホスト名に使えない文字があったので 34os にします"; NEWHOST=34os ;; esac

# --- copy the system ---
say ""
say "システムをコピーしています（数分かかります）..."
mkdir -p "$TGT"
mount "$ROOT_PART" "$TGT" || die "マウントに失敗しました"
cleanup_mounts() {
  umount "$TGT/boot/efi" 2>/dev/null || true
  umount "$TGT/sys" "$TGT/proc" "$TGT/dev/pts" "$TGT/dev" 2>/dev/null || true
  umount "$TGT" 2>/dev/null || true
}
trap cleanup_mounts EXIT
if [ -n "$ESP_PART" ]; then
  mkdir -p "$TGT/boot/efi"
  mount "$ESP_PART" "$TGT/boot/efi" || die "ESP のマウントに失敗しました"
fi
unsquashfs -f -d "$TGT" "$SQFS" >/dev/null || die "コピーに失敗しました"

# drop build-time leftovers that must not ship to an installed system
rm -f "$TGT/etc/apt/apt.conf.d/99build-proxy"
printf '# managed by the system\n' > "$TGT/etc/resolv.conf"
rm -f "$TGT/etc/sudoers.d/34os"

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
chroot "$TGT" useradd -m -s /bin/bash -G sudo,video,input "$NEWUSER" || die "ユーザー作成に失敗しました"
printf '%s:%s\n' "$NEWUSER" "$NEWPASS" | chroot "$TGT" chpasswd || die "パスワード設定に失敗しました"

if grep -q '^#GRUB_DISABLE_OS_PROBER' "$TGT/etc/default/grub" 2>/dev/null; then
  sed -i 's/^#GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$TGT/etc/default/grub"
elif ! grep -q '^GRUB_DISABLE_OS_PROBER' "$TGT/etc/default/grub" 2>/dev/null; then
  echo 'GRUB_DISABLE_OS_PROBER=false' >> "$TGT/etc/default/grub"
fi

say "ブートローダを入れています..."
if [ "$UEFI" -eq 1 ]; then
  chroot "$TGT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=34OS || die "GRUB のインストールに失敗しました"
  # removable-media fallback path, in case the NVRAM entry is ignored
  if [ -f "$TGT/boot/efi/EFI/34OS/grubx64.efi" ]; then
    mkdir -p "$TGT/boot/efi/EFI/BOOT"
    cp "$TGT/boot/efi/EFI/34OS/grubx64.efi" "$TGT/boot/efi/EFI/BOOT/BOOTX64.EFI" || true
  fi
else
  chroot "$TGT" grub-install --target=i386-pc "$DISK" || die "GRUB のインストールに失敗しました"
fi
chroot "$TGT" update-grub || die "GRUB 設定の生成に失敗しました"
chroot "$TGT" update-initramfs -u || die "initramfs の再生成に失敗しました"
rm -f "$TGT/usr/sbin/policy-rc.d"

cleanup_mounts
trap - EXIT
sync
say ""
say "=== インストール完了 ==="
say "ライブメディアを取り外して、再起動してください。"
say "ログイン: $NEWUSER（設定したパスワード）"
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
printf '34OS 本体は WTFPL です。好きに使ってください。改変版を配る場合は、同じ WTFPL の条件を引き継いでください。\n同梱プログラムのライセンスは各自のものを継承します（/usr/share/doc/*/copyright 参照）。\n' | sudo tee "$ROOTFS/etc/legal" >/dev/null
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
in_chroot systemctl enable 34os-keymap.service

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
  exec /usr/bin/fbterm
fi
EOF2



# v1.2: do not ship build-time network config (sandbox proxy / DNS)
sudo rm -f "$ROOTFS/etc/apt/apt.conf.d/99build-proxy"
printf '# managed by the system\n' | sudo tee "$ROOTFS/etc/resolv.conf" >/dev/null

# 3) slimming: firmware trim (keep common NIC / Wi-Fi only), docs, apt cache
if [ -d "$ROOTFS/usr/lib/firmware" ]; then
  sudo find "$ROOTFS/usr/lib/firmware" -mindepth 1 -maxdepth 1 \
    ! -name 'rtl_nic' ! -name 'iwlwifi-*' ! -name 'intel' \
    ! -name 'rtw88' ! -name 'rtw89' ! -name 'ath10k' ! -name 'ath11k' \
    ! -name 'brcm' ! -name 'e100' ! -name 'tigon' \
    -exec rm -rf {} +
fi
in_chroot apt-get clean
sudo rm -rf "$ROOTFS/usr/share/doc/"* \
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
menuentry "34OS v1.2 (CLI live)" {
  linux /casper/vmlinuz boot=live live-media-path=/casper hostname=34os locales=ja_JP.UTF-8 ---
  initrd /casper/initrd.img
}
EOF
echo "34OS v1.2 - CLI live prototype" > "$ISODIR/README.txt"

# 5) ISO (BIOS + UEFI hybrid via grub-mkrescue)
rm -f "$OUT"
grub-mkrescue -o "$OUT" "$ISODIR"

echo "--- result ---"
du -h "$ISODIR/casper/filesystem.squashfs" "$OUT"
echo "=== 34OS v1 CI build finished: $(date -Is) ==="
