# Screact コンテスト応募用文面

コンテスト応募フォーム、作品紹介ページ、審査資料へそのまま転記できる定型文です。文字数制限がある場合は短縮版を、制限がない場合は標準版を使ってください。主コピーはチーム確定の表記を使用しています。

## 一言紹介文

```text
ただの画面を、描いて動かせる画面へ。Screactは、Androidスマホを画面の「目」にして、既存のPC画面を手で操作できるようにするシステムです。
```

## 作品概要（標準）

```text
Screactは、既存のディスプレイやプロジェクターを買い替えずに、AndroidスマホとPCで手による操作を後付けするシステムです。スマホのカメラで画面四隅のArUcoマーカーと手指21点を認識し、PC側で画面座標へ変換します。ブラウザ、PDF、スライドの上に透明オーバーレイを重ね、描画、クリック、ドラッグ、スクロールを実現します。
```

## 作品概要（短縮）

```text
Androidスマホを画面の「目」にして、既存のPC画面を手で操作するシステムです。ArUcoと手指21点の認識結果を画面座標へ変換し、ブラウザやスライドへ描画・クリック・スクロールを後付けします。
```

## 背景・解決したい課題

```text
授業やプレゼンテーションでは、説明者がスクリーンの前に立ち、操作のたびにPCの前へ戻ることで、説明やコミュニケーションの流れが途切れます。Screactは、専用タッチディスプレイへ買い替えるのではなく、手元のAndroidスマホとPCで、今ある画面に「操作できる」を後付けします。
```

## こだわり・PRポイント

```text
・既存設備の活用：専用センサーや電子ペンを前提にせず、AndroidスマホとPCで成立させました。
・画面への対応付け：ArUcoマーカー4点とHomographyで、斜めに設置したスマホの座標も画面全体へ変換します。
・操作感の実装：One-Euro Filter、最新フレーム優先、ジェスチャー状態管理で、移動・クリック・描画・消去・スクロールを使い分けます。
・安全性：手の喪失や切断時に押下・描画状態を解除し、透明・クリック透過オーバーレイで背後のアプリを隠しません。
・データ設計：カメラ映像をPCへ連続送信せず、端末内で認識した手指ランドマークと状態だけを送ります。
```

## 技術要素

```text
Android：Kotlin / Jetpack Compose / CameraX
手指・画面認識：MediaPipe Hand Landmarker / OpenCV ArUco
Desktop：Flutter / Dart
通信：UDP Discovery / WebSocket
座標・操作処理：Homography / One-Euro Filter / Gesture Engine
OS連携：macOS CGEvent / Windows SendInput
```

## デモ・実績

```text
デモ動画：https://drive.google.com/file/d/14SZvVKVLxcpKkB3tEl41TTzPK-4H_XEj/view?usp=sharing
（THE HACK 2026 予選発表時に収録した約33秒のデモ）

実績：THE HACK 2026 本戦 大賞（THE WIN / Team 35）
```

## チーム情報

```text
チーム名：THE WIN
作品名：Screact
メンバー：久米蒼輝、マルチェンコ・ダニール、高岡己太朗、松本絆那
```

## 参照先

- [ルートREADME](../README.md) — 製品紹介、デモ、技術、ギャラリー
- [プロダクト・開発台帳](./work/records/product/Screact_プロダクト・開発台帳_2026-08-30.md) — 根拠、実装状態、検証記録
- [作品資料の採用根拠](./work/records/product/source-register-2026-08-30.md) — Drive素材、動画、主コピーの出典
