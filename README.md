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
| GUI | 独自 UI「Astro」（自作ウィンドウマネージャ `34os-wm`、v2.1〜）。Fluxbox はフォールバックとして残置 |
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
| `gogui` | GUI（Astro。フォールバック時は Fluxbox）を起動する |
| `gocli` | GUIを落としてCLIに戻る |
| `browser` | ブラウザを開く |
| `img` | 画像を表示する（feh） |
| `play` | 動画を再生する（mpv） |
| `help` | 使えるコマンドの一覧と説明を出す |
| `install34` | ライブセッションから HDD/SSD へインストールする（全消し／デュアルブート） |

※ システム内部が使うコマンドは消さない（消すと起動や apt が壊れるため）。
「見せない」のは PATH の制御で実現する。

## ステータス

開発中。現在の最新版は **v2.1「34OS Hachiroku-Rail TopNumber」**（初の製品名付きリリース）：独自 UI「Astro」（自作ウィンドウマネージャ＋パネル）を搭載する。CI ビルド成功済み、実機テスト報告は募集中。

これまでの経緯：v1 が dynabook（初代 Core i5）で実機起動に成功。v1.1 は完成し、QEMU 検証オールクリア（コンソールの日本語表示・日本語キー配列・man 修正など）。v1.2 でインストーラ `install34` を搭載し、ライブ起動から HDD/SSD へのインストール（全消し／デュアルブート）が可能に。v2 で GUI パックを実装。v2.0.5 はスリム化で削りすぎたカーネルドライバの復旧版、v2.0.6 はその実機テストで見つかった問題（ネットワークポリシー・DNS・ファイルマネージャ）の修正版で、dynabook 実機テストでは表示・画質・Firefox・ネットワーク権限が正常動作を確認（残課題：ホットスポットの SSID が他端末から見えない、音声調整の導線、Firefox のホームページ初期表示）。v2.1 で独自 UI「Astro」に移行した。

## ロードマップ

- **v0**: CLIのみのライブISO（起動確認とサイズ測定）
- **v1**: 独自コマンド（gogui / gocli / browser / img / play / help）の実装
- **v1.1**: v1 の完成形（コンソール日本語表示・日本語キー配列・man 修正・WTFPL 文面）
- **v1.2**: インストーラ（install34）搭載。全消し／デュアルブートの2モード、UEFI／BIOS 両対応
- **v2**: Fluxbox + Firefox + feh / mpv + Mozc の GUI パック（ターミナルは sakura、標準壁紙は蒸気機関車の線画）
- **v2.0.5**: スリム化で削除しすぎたカーネルドライバ（GPU・ネットワーク・サウンド等）を復旧
- **v2.0.6**: 実機テストで判明した問題の修正（ライブユーザーのグループ所属、DNS フォールバック、PCManFM の実行確認ダイアログ）
- **v2.1**: 独自 UI「Astro」（自作ウィンドウマネージャ＋パネル）搭載。製品名「34OS Hachiroku-Rail TopNumber」（略称 34OS H-TNum）としてリリース
- **v2.1 ライト化（予定）**: ISO サイズを 550〜600MB へ（ファームウェア／ドライバ分類の見直し。ドライバ網羅は維持）
- その先: Secure Boot 対応（Ubuntu の署名済みブートチェーン流用を検討）、自宅サーバーへのインストール、DWService でのリモート運用

## ビルド

```bash
./build-v2.1.sh
```

CI 版は `build-v2.1-ci.sh`（ワークフロー: `.github/workflows/build-v2.1.yml`）。GitHub Actions で自動ビルドされ、ISO は Artifacts（名前: `34os-v2.1-iso`）からダウンロードできる（ワークフローの `path:` は最新の ISO 名に合わせること）。CLI 版は `build-v1.2.sh` / `build-v1.2-ci.sh`。

Ubuntu 24.04 上で debootstrap / squashfs-tools / grub / xorriso を使って ISO を生成する。

## 起動メディア

USB への書き込みは Rufus の DD モード、または Ventoy（インストール済み USB に ISO をコピーするだけ）で可能。
注意：比較的新しい世代の Secure Boot 搭載 BIOS/UEFI では、Secure Boot を無効化しておく必要があります（34OS のブートローダは未署名のため）。

## 協力者募集（PR歓迎）

個人プロジェクトですが、協力者は歓迎します。特に募集中なのはこのあたり：

- **英語ロケールの追加**（現在は日本語のみ。方針として英語は有志に任せています）
- **実機テスト**：手元の古い PC で起動・インストールしてみた報告（動いた／動かなかった、機種名があると助かります）
- **軽量化**：ISO サイズ削減（CLI 版は約 500MB → 目標 300MB 台。GUI 版は v2.0.6 で 747MB、v2.1 のライト化目標は 550〜600MB。ドライバを削ると実機で動かなくなるため、削る場所の見極めが課題）

進め方は fork → Pull Request で。コードでなくても、Issue での相談・バグ報告だけでも歓迎です。

ライセンス：34OS 本体は WTFPL（コピーレフト条項付き）です。改変版を配布する場合は、同じ条件で公開してください。©MximizR/Nekomimi

> Contributors welcome! Especially looking for: English localization, real-hardware test reports, and ISO size reduction. Fork & PR. License: WTFPL (copyleft variant) — if you distribute a modified version, publish it under the same terms.

## 詳細

仕様の詳細は [SPEC.md](SPEC.md) を参照。
