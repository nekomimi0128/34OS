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
OUT="$PWD/34os-v1.1.iso"

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
34OS v1.1 \n \l
EOS
sudo sed -i 's/^NAME=.*/NAME="34OS"/; s/^PRETTY_NAME=.*/PRETTY_NAME="34OS v1.1"/' "$ROOTFS/etc/os-release"
if [ -f "$ROOTFS/etc/lsb-release" ]; then
  sudo sed -i 's/^DISTRIB_ID=.*/DISTRIB_ID=34OS/; s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION="34OS v1.1"/' "$ROOTFS/etc/lsb-release"
fi

in_chroot apt-get update
in_chroot apt-get install -y --no-install-recommends \
  linux-image-generic live-boot systemd-sysv \
  bash nano locales sudo zstd \
  iproute2 iputils-ping less man-db fbterm fonts-vlgothic kbd

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

sudo chmod +x "$ROOTFS/usr/local/bin/help" "$ROOTFS/usr/local/bin/gogui" "$ROOTFS/usr/local/bin/gocli" \
  "$ROOTFS/usr/local/bin/browser" "$ROOTFS/usr/local/bin/img" "$ROOTFS/usr/local/bin/play"

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

# v1.1: ship a clean /etc/hosts. The build host's hosts file was copied in
# for build-time networking and must not ship; a proper 34os entry also
# fixes sudo's "unable to resolve host 34os" warning.
printf '127.0.0.1 localhost\n127.0.1.1 34os\n::1 localhost ip6-localhost ip6-loopback\nfe00::0 ip6-localnet\nff00::0 ip6-mcastprefix\nff02::1 ip6-allnodes\nff02::2 ip6-allrouters\n' | sudo tee "$ROOTFS/etc/hosts" >/dev/null
# v1.1: Japanese keyboard. The live user's keyboard is a JIS layout, so
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

# v1.1: Japanese on the console. The raw console font has no Japanese
# glyphs (text renders as blocks), so tty1 sessions are handed to fbterm,
# which renders Japanese with VL Gothic. Other ttys stay plain (fallback).
printf 'font-names=VL Gothic\nfont-size=16\n' | sudo tee "$ROOTFS/home/user/.fbtermrc" "$ROOTFS/etc/skel/.fbtermrc" >/dev/null
in_chroot chown user:user /home/user/.fbtermrc
sudo tee "$ROOTFS/etc/profile.d/34os-fbterm.sh" >/dev/null <<'EOF2'
# 34OS: hand tty1 to fbterm so Japanese renders on the console.
if [ "$(/usr/bin/tty)" = "/dev/tty1" ] && [ -z "${FBTERM_STARTED:-}" ] && [ -x /usr/bin/fbterm ] && [ -e /dev/fb0 ]; then
  FBTERM_STARTED=1
  export FBTERM_STARTED
  exec /usr/bin/fbterm
fi
EOF2



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
menuentry "34OS v1.1 (CLI live)" {
  linux /casper/vmlinuz boot=live live-media-path=/casper hostname=34os locales=ja_JP.UTF-8 ---
  initrd /casper/initrd.img
}
EOF
echo "34OS v1.1 - CLI live prototype" > "$ISODIR/README.txt"

# 5) ISO (BIOS + UEFI hybrid via grub-mkrescue)
rm -f "$OUT"
grub-mkrescue -o "$OUT" "$ISODIR"

echo "--- result ---"
du -h "$ISODIR/casper/filesystem.squashfs" "$OUT"
echo "=== 34OS v1 CI build finished: $(date -Is) ==="
