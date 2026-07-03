<p align="center">
  <img src="icon/icon-1024.png" width="160" alt="Pokémon Mouse Follower app icon">
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · <b>日本語</b>
</p>

# Pokémon Mouse Follower

macOS のメニューバーアプリです。画面上を歩き回るポケモンのキャラクターがマウスカーソルを追いかけます。
Dock にはアイコンを表示せず、上部メニューバーにアイコン（🐾）だけが出るバックグラウンドアプリです。

- 🐾 **メニューバー専用** — Dock アイコンなし（`LSUIElement`）
- 🎯 **独自の物理ベース追従** — カーソルと距離を保ち、キャラ自身の速度／加速度でなめらかに追いかける
- 🧭 **8方向アニメーション** — 移動方向に合わせてスプライトが向きを変える
- 😴 **待機 → 睡眠** — 一定時間止まっていると眠り、カーソルが動くとまた追いかける
- 🐱 **ポケモン251匹（第1・2世代）** — GUI で選択
- 🎨 **色違い（altColor）** — 対応する124匹は別パレットで表示可能
- 🌏 **多言語** — 英語 / 韓国語 / 日本語（UI + ポケモン名）
- 🖥️ **クリックを透過する透明オーバーレイ** — 下のアプリ操作を邪魔しない
- 🖥️🖥️ **マルチモニター対応** — ディスプレイ間を自然に移動

## 動作要件

- macOS 13（Ventura）以降
- Apple Silicon / Intel の両対応（universal ビルド）
- Xcode Command Line Tools（`swiftc`）— **ソースからビルドする場合のみ** 必要（`xcode-select --install`）

## インストール（開発者ツール不要）

[Releases](https://github.com/LimFull/pokemon-mouse-follower/releases/latest) から `.dmg` をダウンロードします。Xcode / Swift は不要です。

1. `PokemonMouseFollower-<version>.dmg` をダウンロードして開く
2. **Pokémon Mouse Follower** アイコンを **Applications** フォルダへドラッグ
3. Launchpad / アプリケーションから起動

## インストール（ソースからビルド）

```bash
./build.sh install
```

`PokemonMouseFollower.app` を universal バイナリとしてビルドし、ad-hoc 署名して `/Applications` にコピー・起動します。
メニューバーに 🐾 アイコンが出て、マウスを動かすとキャラが追いかけてきます。

ビルドのみ行う場合:

```bash
./build.sh          # ./PokemonMouseFollower.app を生成
open ./PokemonMouseFollower.app
```

> ソースビルドは ad-hoc 署名のため、Finder で初回に「未確認の開発者」警告が出たら右クリック → **開く** を一度実行してください。
> ログイン時の自動起動は、設定画面の **ログイン時に起動** オプションで有効にできます。

## 開発

素早い反復用スクリプト。arm64 デバッグビルドでコンパイルしてフォアグラウンド実行し、ログはターミナルに出力、Ctrl+C で終了します。

```bash
./dev.sh
```

## 設定

メニューバー 🐾 → **Settings…**（`⌘,`）、または実行中のアプリを再度起動すると設定画面が開きます。
値は即時に反映され、`UserDefaults` に保存されます。

画面の最上部には、選択中キャラのプレビュー（下向きの待機アニメーション）と **◀ ▶** 前／次の矢印、**ランダム** ボタンがあります。

| 項目 | 範囲 | 既定値 | 説明 |
|---|---|---|---|
| キャラクター | 251匹 | 007 ゼニガメ | 追いかけるポケモン |
| カーソルとの距離 | 0–200 px | 100 | カーソルと保つ間隔 |
| 最高速度 | 2–25 | 5 | 移動速度の上限 |
| キャラクターの大きさ | 1.0×–5.0× | 2.0× | スプライトの倍率 |
| 眠るまでの時間 | 5–120秒 | 30 | 停止後、睡眠に入るまでの時間 |
| 色違い | オン/オフ | オフ | 色違い（altColor）スプライトを使用（対応する124匹のみ） |
| 影 | オン/オフ | オフ | キャラの足元に影の楕円を表示（大きさは各ポケモンの `ShadowSize` に準拠） |
| ログイン時に起動 | オン/オフ | オフ | ログイン時に自動起動 |

## 動作の流れ

```
歩く(walk) → 停止 → 待機(idle) → [眠るまでの時間] → 睡眠(sleep)
                                              ↓ カーソル移動
                                            歩く(walk)
```

- 移動速度はマウス速度とは無関係です。マウスが速すぎるとキャラは一度遅れ、自分の速度で追いつきます。
- 停止状態から動き出すときは速度ゼロからなめらかに加速し、カーソル付近で減速して止まります。

## プロジェクト構成

```
Sources/main.swift        アプリ本体（オーバーレイウィンドウ、スプライトアニメ、物理、設定GUI）
Info.plist                バンドル設定（LSUIElement、ローカライズ一覧）
build.sh                  universal .app ビルド + ad-hoc 署名（+ install）
release.sh                ビルド + 署名 + .dmg 化 + 発行
dev.sh                    素早い arm64 デバッグビルド + フォアグラウンド実行
fetch-shadows.sh          -Shadow マーカーシートのダウンロード
fetch-altcolors.sh        色違い（altColor）スプライトのダウンロード
Localizable/*.lproj       en / ko / ja の文字列
animations/<番号>/        キャラ別スプライトシート + AnimData.xml
```

各キャラのフォルダには `Idle-Anim.png`、`Walk-Anim.png`、`Sleep-Anim.png` と、フレームサイズ情報を含む `AnimData.xml` が入っています。フレームサイズはキャラごとに異なり、アプリが `AnimData.xml` を読んで動的にスライスします。

## クレジット

- スプライト: [PMD Sprite Collab](https://sprites.pmdcollab.org/#/) — コミュニティ制作のドットアニメーション（アセットは `spriteserver.pmdcollab.org` から取得）。
- Pokémon © Nintendo / Creatures Inc. / GAME FREAK inc.

本プロジェクトは **非商用の個人ファンプロジェクト** です。ポケモンおよび関連する名称・画像の権利は各権利者に帰属します。
