# 2026-08-30 実装仕様書優先の再編

## 目的

参考にした `jphacks/kz_2504` と `razy6174/EnCounter` と同様に、`docs/` の直下を **実装済み仕様書の入口** にした。要件、途中の設計、評価、将来計画、台帳は `docs/work/` 以下へ移し、仕様書と混同しない構造にした。

## 移行対応表

| 再編前 | 再編後 | 扱い |
| --- | --- | --- |
| `docs/android/android-current-spec.md` | `docs/android-specification-v1.md` | 実装済み Android 仕様として前面化 |
| `docs/android/android-protocol-v1.md` | `docs/protocol-specification-v1.md` | 実装済み通信契約として前面化 |
| `docs/architecture/` | `docs/work/architecture/` | 補助的な設計・シーケンス資料として移行 |
| `docs/android/` の残り | `docs/work/requirements/android/` | 要件、判断、デバッグ、変更計画として移行 |
| `docs/desktop/` | `docs/work/requirements/desktop/` | 要件資料として移行 |
| `docs/system/` | `docs/work/requirements/system/` | 要件資料として移行 |
| `docs/planning/` | `docs/work/planning/` | 未実装を含む将来計画として移行 |
| `docs/quality/` | `docs/work/reviews/quality/` | 特定時点の改善レビューとして移行 |
| `docs/product/` / `docs/migration/` | `docs/work/records/` | 開発記録・情報源・移行記録として移行 |

既存の Markdown 文書は削除していない。移動に伴う相対リンクだけを更新する。

## 移行監査

- 既存14文書を、内容本体を削除せずに実装仕様・要件・設計・レビュー・記録の役割別パスへ移動した。
- `android-current-spec.md` と `android-protocol-v1.md` は、実装済みの正本として `docs/` 直下の仕様書へ昇格した。
- それ以外の要件・設計・レビュー・台帳は `docs/work/` 以下に保持し、作業資料として明示した。
- 移行後に全Markdown/HTMLローカルリンクを検査し、参照切れがないことを確認した。
