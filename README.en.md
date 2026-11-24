# 34OS

[日本語](README.md)

> It's very hyper ultra super mega light-weight OS

A personal Linux distribution (in the making) that aims to be absurdly lightweight.
The name comes from "Sanyon = 3 · 4".

## Concept

- Aims to be **lighter than Puppy Linux**
- But with **the everyday command-line feel of Ubuntu** (GNU coreutils + bash + apt)
- Only what the user actually uses is shown up front; everything else is kept behind the scenes

The weight is saved not by removing commands, but by trimming locales, documentation and firmware, and compressing the file system with SquashFS.

## Specifications

| Item | Details |
|---|---|
| Base | Ubuntu 24.04 LTS (minimal debootstrap) |
| Shell | bash |
| Package management | apt |
| Locale | **Japanese (ja_JP.UTF-8) only**. English is left to volunteers |
| Japanese input | Mozc included by default (GUI side, fcitx5-mozc) |
| GUI | Fluxbox is the standard session. The custom UI "Astro" (in-house window manager `34os-wm`) is bundled and under testing |
| Browser | Firefox (official Mozilla .deb; snap is not used) |

## Commands

Everyday commands are a curated set, shown up front.

```
cd / ls / cat / man / nano / history / sudo / apt / help
mkdir / rm / mv / cp / grep ...
```

Custom commands:

| Command | Meaning |
|---|---|
| `gogui` | Start the GUI (Fluxbox by default, or Astro if `~/.34os-astro` exists) |
| `gocli` | Stop the GUI and return to the CLI |
| `browser` | Open the browser |
| `img` | Display an image (feh) |
| `play` | Play a video (mpv) |
| `help` | List the available commands with explanations |
| `install34` | Install from the live session to HDD/SSD (full wipe / dual boot) |

* Commands used internally by the system are not deleted (deleting them would break booting and apt). They are "hidden" purely through PATH control.

## Status

Under development. The current release is **v2.1d** (preview): the standard session is Fluxbox, and the custom UI "Astro" is bundled for testing (started via the `~/.34os-astro` flag). The 2.1x series is being hardened through repeated real-hardware tests, and the final, bug-free 2.1x build will be promoted as-is to the first branded release, **v2.2 "TopNumber"** (34OS Hachiroku-Rail TopNumber), scheduled for **December 25, 2026**.

History so far: v1 booted successfully on real hardware (a dynabook with a first-generation Core i5). v1.1 was completed and passed the full QEMU verification (Japanese console display, Japanese keyboard layout, man fixes, and more). v1.2 added the `install34` installer, making installation from the live session to HDD/SSD possible (full wipe / dual boot). v2 implemented the GUI pack. v2.0.5 restored kernel drivers that had been cut too aggressively during slimming; v2.0.6 fixed issues found in its real-hardware test (network policy, DNS, file manager), and on the dynabook the display, rendering quality, Firefox and network permissions were confirmed working. v2.1 (the Astro-standard edition) was postponed based on real-hardware test results, and v2.0.6b — Fluxbox standard with Astro bundled — was released first. After that, development continued in the 2.1x line: v2.1b (bundled wpasupplicant and rfkill, live user added to the audio group, tray and desktop handling in Astro), v2.1c (dnsmasq added, Astro's built-in panel indicators, a Recovery screen shown when the boot medium is missing), and v2.1d (fixed the notification watcher, a black stop screen shown when the USB medium is removed, and Astro's desktop icon column).

## About version notation

A trailing letter (b, c, d…) marks a **fix release of the same version**; it is not a new version. The unmarked release is the first one (an implicit "a"), and fixes advance the letter: b, c, d…. For example, v2.1 → v2.1b → v2.1c → v2.1d are all revisions of v2.1. Only when the numbers go up is it a new version.

## Roadmap

- **v0**: CLI-only live ISO (boot check and size measurement)
- **v1**: Custom commands (gogui / gocli / browser / img / play / help)
- **v1.1**: The completed form of v1 (Japanese console display, Japanese keyboard layout, man fixes, WTFPL text)
- **v1.2**: Installer (install34) included. Two modes — full wipe / dual boot — UEFI and BIOS both supported
- **v2**: The GUI pack — Fluxbox + Firefox + feh / mpv + Mozc (terminal is sakura; the default wallpaper is a steam locomotive line drawing)
- **v2.0.5**: Restored kernel drivers (GPU, network, sound, etc.) that slimming had removed too aggressively
- **v2.0.6**: Fixes for issues found in real-hardware testing (live user's group membership, DNS fallback, PCManFM run confirmation dialog)
- **v2.0.6b**: Stable release that returned the standard session to Fluxbox after Astro issues found in the v2.1 real-hardware test (such as the missing cursor). Astro, with the cursor fixed, is bundled and can be tried via a flag file
- **v2.1b / v2.1c / v2.1d**: The 2.1x fix series — Astro improvements (tray, desktop icons, built-in panel indicators), hotspot support components (wpasupplicant, dnsmasq), the Recovery screen and the black stop screen
- **v2.2 "TopNumber" (scheduled: December 25, 2026)**: The release in which the custom UI "Astro" becomes the standard session. Product name "34OS Hachiroku-Rail TopNumber" (short form: 34OS H-TNum). The final 2.1x build will be promoted to v2.2 as-is
- **Lightening (planned)**: ISO size down to 550–600 MB (reviewing firmware/driver classification, while keeping driver coverage)
- Further ahead: Secure Boot support (considering reusing Ubuntu's signed boot chain), installation on a home server, remote operation via DWService

## Building

```bash
./build-v2.1d.sh
```

The CI variant is `build-v2.1d-ci.sh` (workflow: `.github/workflows/build-v2.1d.yml`). Builds run automatically on GitHub Actions, and the ISO can be downloaded from Artifacts (name: `34os-v2.1d-iso`) — note that the workflow's `path:` must match the latest ISO name. The CLI edition uses `build-v1.2.sh` / `build-v1.2-ci.sh`.

The ISO is generated on Ubuntu 24.04 using debootstrap / squashfs-tools / grub / xorriso.

## Boot media

Write the ISO to USB with Rufus in DD mode, or with Ventoy (just copy the ISO onto a Ventoy-installed USB stick).
Note: on relatively recent BIOS/UEFI systems with Secure Boot, Secure Boot must be disabled first (the 34OS bootloader is unsigned).

## Contributors welcome (PRs welcome)

This is a personal project, but contributors are welcome. Especially wanted:

- **Adding an English locale** (currently Japanese only; by policy, English is left to volunteers)
- **Real-hardware tests**: reports from trying it on your own old PC (whether it worked or not; the machine model helps)
- **Lightening**: reducing the ISO size (the CLI edition is about 500 MB with a goal in the 300 MB range; the GUI edition was 747 MB at v2.0.6, and the lightening goal for the v2.1 line is 550–600 MB. Cutting drivers breaks real hardware, so judging what can be cut is the challenge)

The workflow is fork → Pull Request. Even without code, questions and bug reports via Issues are welcome.

License: 34OS itself is WTFPL (with a copyleft clause). If you distribute a modified version, publish it under the same terms. ©MximizR/Nekomimi

> Contributors welcome! Especially looking for: English localization, real-hardware test reports, and ISO size reduction. Fork & PR. License: WTFPL (copyleft variant) — if you distribute a modified version, publish it under the same terms.

## Details

See [SPEC.md](SPEC.md) for the detailed specification (Japanese).
