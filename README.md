# 34OS

> It's very hyper ultra super mega light-weight OS

バカ軽いOSを目指して作っている、個人専用の Linux ディストリビューション（になる予定のもの）。
名前の由来は「サンヨン = 3・4」。

## コンセプト

- **Puppy Linux 以下の軽さ**を目指す
- でも**コマンドの使い心地は Ubuntu と同じ**（GNU coreutils + bash + apt）
- 使う人が使うものだけを表に出す。余計なものは裏に隠す

軽さの稼ぎ方はコマンドを削ることではなく、ロケール・ドキュメント・ファームウェアを削ぎ落として、ファイルシステムを SquashFS で圧縮すること。

## 仕様

| 項目 | 内容 |
|---|---|
| 土台 | Ubuntu 24.04 LTS（debootstrap 最小構成） |
| シェル | bash |
| パッケージ管理 | apt |
| ロケール | **日本語（ja_JP.UTF-8）のみ**。英語は有志に任せる |
| 日本語入力 | Mozc 標準搭載（GUI側、fcitx5-mozc） |
| GUI | Fluxbox（必要な時だけ起動） |
| ブラウザ | Firefox（Mozilla公式 .deb。snap は使わない） |

## コマンド

日常コマンドは厳選して表に出す方針。

```
cd / ls / cat / man / nano / history / sudo / apt / help
mkdir / rm / mv / cp / grep ...
```

独自コマンド:

| コマンド | 意味 |
|---|---|
| `gogui` | GUI（Fluxbox）を起動する |
| `gocli` | GUIを落としてCLIに戻る |
| `browser` | ブラウザを開く |
| `img` | 画像を表示する（feh） |
| `play` | 動画を再生する（mpv） |
| `help` | 使えるコマンドの一覧と説明を出す |
| `install34` | ライブセッションから HDD/SSD へインストールする（全消し／デュアルブート） |

※ システム内部が使うコマンドは消さない（消すと起動や apt が壊れるため）。
「見せない」のは PATH の制御で実現する。

## ステータス

開発中。v1 が dynabook（初代 Core i5）で実機起動に成功。v1.1 は完成し、QEMU 検証オールクリア（コンソールの日本語表示・日本語キー配列・man 修正など）。現在の最新版は **v1.2**：インストーラ `install34` を搭載し、ライブ起動から HDD/SSD へのインストール（全消し／デュアルブート）が可能に。CI ビルド成功済み、ISO サイズは約 500MB（目標は 300MB 台）。インストールの実機テスト報告は募集中。

## ロードマップ

- **v0**: CLIのみのライブISO（起動確認とサイズ測定）
- **v1**: 独自コマンド（gogui / gocli / browser / img / play / help）の実装
- **v1.1**: v1 の完成形（コンソール日本語表示・日本語キー配列・man 修正・WTFPL 文面）
- **v1.2**: インストーラ（install34）搭載。全消し／デュアルブートの2モード、UEFI／BIOS 両対応
- **v2**: Fluxbox + Firefox + feh / mpv + Mozc の GUI パック（ターミナルは sakura、標準壁紙は蒸気機関車の線画）
- その先: 自宅サーバーへのインストール、DWService でのリモート運用

## ビルド

```bash
./build-v1.2.sh
```

CI 版は `build-v1.2-ci.sh`。GitHub Actions で自動ビルドされ、ISO は Artifacts からダウンロードできる。

Ubuntu 24.04 上で debootstrap / squashfs-tools / grub / xorriso を使って ISO を生成する。

## 協力者募集（PR歓迎）

個人プロジェクトですが、協力者は歓迎します。特に募集中なのはこのあたり：

- **英語ロケールの追加**（現在は日本語のみ。方針として英語は有志に任せています）
- **実機テスト**：手元の古い PC で起動・インストールしてみた報告（動いた／動かなかった、機種名があると助かります）
- **軽量化**：initrd 再生成による ISO サイズ削減（現在 約500MB → 目標 300MB 台。initrd 単体で 112MB あり）

進め方は fork → Pull Request で。コードでなくても、Issue での相談・バグ報告だけでも歓迎です。

ライセンス：34OS 本体は WTFPL（コピーレフト条項付き）です。改変版を配布する場合は、同じ条件で公開してください。©MximizR/Nekomimi

> Contributors welcome! Especially looking for: English localization, real-hardware test reports, and ISO size reduction. Fork & PR. License: WTFPL (copyleft variant) — if you distribute a modified version, publish it under the same terms.

## 詳細

仕様の詳細は [SPEC.md](SPEC.md) を参照。
