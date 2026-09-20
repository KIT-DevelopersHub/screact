# 2026-08-30 文書構造移行

## 目的

README を作品の入口、`docs/` を根拠と詳細の入口として整理した。既存の文書内容は削除していない。ルート直下にあった横断文書を、役割が分かるフォルダへ **移動** し、リンクを更新した。

この構成は、参考にした `jphacks/kz_2504` の「README → 最新仕様 / archive」導線と、`razy6174/EnCounter` の「README → 分野別仕様」導線を踏まえ、Screact の既存資料量に合わせたものである。

## パス対応表

| 移行前 | 移行後 | 分類 | 内容の変更 |
| --- | --- | --- | --- |
| `docs/Screact_プロダクト・開発台帳_2026-08-30.md` | `docs/product/Screact_プロダクト・開発台帳_2026-08-30.md` | 開発記録 | 相対リンクのみ更新 |
| `docs/sequence-zero-config-pairing.md` | `docs/architecture/pairing.md` | 現行仕様・実装参照 | なし |
| `docs/sequence-calibration-flow.md` | `docs/architecture/calibration.md` | 現行仕様・実装参照 | なし |
| `docs/two-person-two-hand-integration-sheet.md` | `docs/architecture/two-person-two-hand-integration-sheet.md` | 現行仕様・実装参照 | 相対リンクのみ更新 |
| `docs/hand-coordinate-and-gesture-precision-review.md` | `docs/quality/hand-coordinate-and-gesture-precision-review.md` | 計画・レビュー | なし |
| `docs/connection-auth-spec-v1.md` | `docs/planning/connection-auth-roadmap.md` | 計画・レビュー | なし |

`docs/android/`、`docs/desktop/`、`docs/system/`、`docs/assets/` は、すでに分野別の階層を持っていたため、移動せず維持した。

## 互換性

> **段階について:** 本記録は 2026-08-30 の第一段階（役割別フォルダへの移動）を記録したものです。その後、実装済み仕様書を `docs/` 直下へ前面化する第二段階を実施しました。現在の最終パスと対応は、[実装仕様書優先の再編](./2026-08-30-implementation-first.md)を正本とします。

- 移行前パスを参照していたリポジトリ内 Markdown は、新しい相対パスへ更新した。
- 外部から移行前 URL を参照している場合は Git の履歴上で追跡できるが、恒久 URL としてはこの対応表の移行後パスを使う。
- 今後、完了済みの設計資料を履歴として固定する場合は、`docs/archive/<時点>/` へ内容を保持したまま移動し、この表を追記する。
