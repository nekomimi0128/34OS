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
| ブラウザ | Firefox か Chromium |

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

※ システム内部が使うコマンドは消さない（消すと起動や apt が壊れるため）。
「見せない」のは PATH の制御で実現する。

## ステータス

開発中。現在 v0（CLIのみのライブISO試作）をビルド中。

## ロードマップ

- **v0**: CLIのみのライブISO（起動確認とサイズ測定）
- **v1**: 独自コマンド（gogui / gocli / browser / img / play / help）の実装
- **v2**: Fluxbox + ブラウザ + feh / mpv + Mozc の GUI パック
- その先: 自宅サーバーへのインストール、DWService でのリモート運用

## ビルド

```bash
./build-v0.sh
```

Ubuntu 24.04 上で debootstrap / squashfs-tools / grub / xorriso を使って ISO を生成する。

## 詳細

仕様の詳細は [SPEC.md](SPEC.md) を参照。
