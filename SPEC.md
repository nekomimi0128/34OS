# 34OS 仕様書 v0.2

## 1. コンセプト
- 名前: 34OS（私の第3のハンドルであるサンヨン = 3・4 から）
- 一言で: **It's very hyper ultra super mega light-weight OS**
- 目標: **Puppy 以下の軽さ**で、**コマンドの使い心地は Ubuntu と同じ**
- 個人専用OS。使う人が使うものだけを表に出し、余計なものは裏に隠す

## 2. 目標（数値）
- ISOサイズ: 300MB台（FossaPup64 9.5 の 409MB 以下。現行 BookwormPup64 は約780MB）
- 起動後のメモリ使用量（CLI）: 200MB以下を目安
- 起動形態: ライブISO（USB起動）。将来はHDD/SSDへのインストールにも対応

## 3. 非目標（やらないこと）
- 多人数で使うサーバーOSや、堅牢なセキュリティ基盤にはしない
- 英語ロケールは公式では入れない（有志の対応に任せる）
- システム内部のコマンドを物理的に削除しない（壊れるため）

## 4. 土台
- Ubuntu 24.04 LTS (noble) を debootstrap の最小構成（minbase）で組む
- シェルは bash、コマンドは GNU coreutils（BusyBox の簡易版に置き換えない）
- パッケージ管理は apt
- ライブ起動は live-boot、ブートローダは GRUB（BIOS / UEFI 両対応）

## 5. ロケールと日本語入力
- **日本語（ja_JP.UTF-8）のみ**
- 日本語入力は **Mozc を標準搭載**する（GUI環境側で fcitx5-mozc を想定。CLIコンソールには入れない）

## 6. コマンド方針
### 6.1 表に出すコマンド（ユーザーが日常で叩く）
- 基本: cd / ls / cat / man / nano / history / sudo / apt / help
- ファイル操作の実用組: mkdir / rm / mv / cp / grep（ほか必要に応じて追加を検討）
- 独自コマンド:
  - `gogui` : GUI（Fluxbox）を起動する
  - `gocli` : GUIを落としてCLIに戻る
  - `browser` : ブラウザ（Firefox か Chromium）を開く
  - `img` : 画像を表示する（feh）
  - `play` : 動画を再生する（mpv）
  - `help` : 使えるコマンドの一覧と説明を出す

### 6.2 裏に隠すコマンド
- システム内部が使うコマンド（systemd、dpkg、grep/sed/awk 等のスクリプト定番、
  ネットワーク系など）は削除しない
- 「見せない」のは PATH の制御で実現する（v0 では未実施、通常構成から始める）

## 7. 軽量化の方針
- apt は --no-install-recommends で推奨パッケージを入れない
- ロケールは日本語のみ、ドキュメント・マニュアル類は削る
- ファームウェアは最小限（linux-firmware を丸ごと入れない）
- ルートファイルシステムは SquashFS（xz）で圧縮する（Puppy と同じ手法）
- ブラウザは本体に含めず、gogui 側のパックに分離する（本体の軽さを守るため）

## 8. GUI
- ウィンドウマネージャは Fluxbox（数MB級）
- アプリは原則ブラウザ中心。追加は feh（画像）と mpv（動画）のみ
- 普段は CLI で運用し、必要な時だけ `gogui` で画面を出す二段構え

## 9. 段階（ロードマップ）
- **v0（試作）**: CLIのみのライブISO。起動確認とサイズ測定が目的
- v1: 独自コマンド（gogui / gocli / browser / img / play / help）の実装と、表コマンドのPATH制御
- v2: Fluxbox + ブラウザ + feh / mpv + Mozc（fcitx5-mozc）の GUI パック
- 将来: 自宅サーバー（N100機）へのインストール、DWService でのリモート運用

## 10. 未決定事項
- ブラウザは Firefox か Chromium か
- 表コマンドの最終リスト（実用組の追加範囲）
- インストール方式（ライブのみか、インストーラを用意するか）

## 11. 備考
- 製作者はコードが書けないため、ビルドと実装は Muse が担当し、対話しながら進める
- 本書は決定のたびに更新する（現在 v0.2）
