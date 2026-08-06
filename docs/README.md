# YubiBoardドキュメント索引

プロジェクト文書を責任範囲ごとに分け、Androidとデスクトップの並行作業で同じMarkdownファイルを編集する機会を減らす。

## 分類

```text
docs/
├─ README.md
├─ system/
│  └─ system-requirements.md
├─ android/
│  ├─ android-app-requirements.md
│  ├─ android-ui-requirements.md
│  ├─ android-camera-resolution-decision.md
│  ├─ android-production-ui-change-plan.md
│  ├─ android-current-spec.md
│  ├─ android-protocol-v1.md
│  └─ android-debug-tutorial.md
└─ desktop/
   └─ desktop-app-requirements.md
```

## 文書一覧

### システム全体

- [システム全体要件定義書](./system/system-requirements.md): AndroidとPCを含む製品の目的、責任境界、完成形

正常系の正本はシステム全体要件定義書の「デモクリティカルな利用フロー」とする。各担当資料では、接続、配置確認、ArUco、追跡、PC処理の順序を変更しない。

### Android

- [Androidアプリ要件定義書](./android/android-app-requirements.md): Android側の機能・非機能要件
- [Android UI要件定義書](./android/android-ui-requirements.md): デザイナー向けの本番UI、画面、状態、文言、アクセシビリティ要件
- [Androidカメラ解像度・プレビューサイズ判断書](./android/android-camera-resolution-decision.md): 本番の解析解像度、画面上の最大表示、フォールバック、受入基準
- [Android本番UI・処理変更計画](./android/android-production-ui-change-plan.md): 現在のデバッグ中心UIから本来の操作フローへ移行する実装計画
- [Androidアプリ現行仕様書](./android/android-current-spec.md): 実装済みのAs-Built仕様
- [Android通信プロトコル v1](./android/android-protocol-v1.md): Android・PC間のJSON契約
- [Android実機デバッグ・チュートリアル](./android/android-debug-tutorial.md): 開発者向けの実機確認手順

### Desktop

- [デスクトップアプリ要件定義書](./desktop/desktop-app-requirements.md): PC側の機能・非機能要件

## 編集ルール

1. 製品全体の目的やAndroid・PC間の責任境界は`system/`だけで定義する。
2. Android固有の要件、現行仕様、変更計画、デバッグ手順は`android/`でファイルを分ける。
3. PC固有の要件と実装計画は`desktop/`へ置く。
4. 目標を変更するときは要件定義書、実装結果を記録するときは現行仕様書、作業順を変更するときは変更計画だけを編集する。
5. 通信フィールドは`android-protocol-v1.md`を正本とし、他文書には重複して完全定義しない。
6. 複数領域へ影響する変更は、正本を先に更新し、関連文書はリンクまたは短い要約だけを更新する。
7. 新しい議題を既存の大規模要件書へ追記し続けず、責務が独立する場合は専用ファイルを作成してこの索引へ追加する。
