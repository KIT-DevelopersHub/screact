# README用の図版

[画像素材](../README.md) ／ [製品README](../../../README.md) ／ [READMEのデザイン](../../readme-design.md)

製品READMEで使う図版です。どの図も `-light`／`-dark`（GitHubのテーマ）と `-narrow-`（幅700px以下の画面）の4種類があり、READMEの `<picture>` が切り替えます。SVGは手で編集せず、`scripts/readme/` の生成スクリプトから書き出します。

| ファイル | READMEの置き場所 | 内容 | 生成スクリプト |
|:--|:--|:--|:--|
| `title-*.svg` | 冒頭（h1） | ロゴの手が「r」をつまみ上げ、YouRay が顔を出し、「操作できる」にマーカーを引いて消す。画面の幅1100px以下でスマホ用に切り替える | `title.py` |
| `concept-*.svg` | Screactとは | スマホが見る → PCへ送る → 画面が応える | `figures.py` |
| `gestures-*.svg` | できること | ①〜④の操作と、そのときの手指21点の骨格 | `figures.py` |
| `retrofit-*.svg` | 後付けという選択 | 必要なもの（スマホ・PC・今ある画面）と、いらない専用機器 | `figures.py` |
| `scenes-*.svg` | 利用場面 | 会議・授業・接客 | `figures.py` |
| `evidence-*.svg` | 直接操作の価値 | 先行研究の数値（Screact自体の効果ではない） | `figures.py` |
| `focus-*.svg` | 技術の4つのこだわり | 導入の手軽さ・設置の自由度・操作性・汎用性 | `figures.py` |
| `journey-*.svg` | 実績 | 予選 → 本戦（大賞）→ 技育博 → 技育展 | `figures.py` |
| `footer-*.svg` | 末尾 | 描いて、動かせる画面へ。 | `figures.py` |
| `screact-logo.png` | Screactとは | ロゴ | — |
| `android/`・`desktop/` | 画面 | アプリの画面の撮影画像（[ギャラリー](../../gallery.md)でも使う） | — |
| `presentation/` | — | THE HACK の発表資料の図（履歴として保持） | — |

フォントは、丸ゴシックの [M PLUS Rounded 1c](fonts/OFL-MPLUSRounded1c.txt)（SIL Open Font License 1.1）を、使う字だけに絞ってSVGに埋め込んでいます。
