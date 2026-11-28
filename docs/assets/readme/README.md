# README用の図版

[画像素材](../README.md) ／ [製品README](../../../README.md) ／ [READMEのデザイン](../../readme-design.md)

製品READMEで使う図版です。どの図も `-light`／`-dark`（GitHubのテーマ）と `-narrow-`（幅700px以下の画面）の4種類があり、READMEの `<picture>` が切り替えます。SVGは手で編集せず、`scripts/readme/` の生成スクリプトから書き出します。

| ファイル | 内容 | 生成スクリプト |
|:--|:--|:--|
| `title-*.svg` | 作品名の見出し（h1）。ロゴの手が「r」をつまみ上げ、YouRay が顔を出し、「操作できる」を丸で囲んで消す。1周23秒、最初の約4.5秒は止まっている。画面の幅1100px以下でスマホ用に切り替える | `title.py` |
| `heads/play-*.svg` | 項目の見出し（01〜12）。右側で YouRay が見出しの内容を演じる | `heads.py` |
| `heads/part-*.svg` | 大見出し（製品概要・開発技術） | `heads.py` |
| `heads/toc-*.svg` | 目次の見出しと項目。項目名はGitHubのリンクの色で描く | `heads.py` |
| `heads/awards-title-*.svg` | 「受賞・出展」の節の見出し | `heads.py` |
| `video-cta-*.svg` | デモ動画のサムネイルの下に置く、Google Driveへの誘導 | `figures.py` |
| `journey-*.svg` | 受賞・出展の道のり。YouRay が駅を進み、着いた駅が光る | `figures.py` |
| `message-*.svg` | 背景の考え方（情報を映す画面から、情報と関わる画面へ） | `figures.py` |
| `roles-*.svg` | 製品の仕組み（見る → 送る → 応える） | `figures.py` |
| `screens-*.svg` | 実際の画面（PCの位置合わせ、スマホの手の追跡）。`android/`・`desktop/` の撮影画像をJPEGで埋め込む | `figures.py` |
| `gestures-*.svg` | 4つの操作とジェスチャー | `figures.py` |
| `features-*.svg`・`compare-*.svg` | 特長の3枚のカードと、専用の機器との比べ | `figures.py` |
| `scenes-*.svg` | 利用場面（会議・授業・接客） | `figures.py` |
| `stats-*.svg` | 直接操作に関する先行研究の数値（Screact自体の効果ではない） | `figures.py` |
| `focus-*.svg` | 注力したこと（導入の手軽さ・設置の自由度・操作性・汎用性） | `figures.py` |
| `roadmap-*.svg` | 今後の展望（まず → その先） | `figures.py` |
| `architecture-*.svg` | システム構成。流れる点（`animateMotion`）が、手の動きが画面に届くまでの道をたどる | `figures.py` |
| `techstack-*.svg` | 活用した技術 | `figures.py` |
| `footer-*.svg` | 締めの「描いて、動かせる画面へ。」 | `figures.py` |
| `android/`・`desktop/` | アプリの画面の撮影画像（[ギャラリー](../../gallery.md)でも使う） | — |
| `presentation/` | THE HACK の発表資料の図（履歴として保持） | — |

## フォント

`<img>` で表示したSVGは外部のフォントを読めないため、締めの文字は使う字だけに絞ったフォントを埋め込みます。グラデーションの数字は、iPhone の Safari でぼやけないよう、フォントの輪郭（`<path>`）にして描きます。どれも [google/fonts](https://github.com/google/fonts) の固定した版から取得します。

| フォント | 使う場所 | ライセンス |
|:--|:--|:--|
| M PLUS Rounded 1c | 締めの説明文 | [SIL Open Font License 1.1](fonts/OFL-MPLUSRounded1c.txt) |
| Yusei Magic | 締めの「描いて、動かせる画面へ。」 | [SIL Open Font License 1.1](fonts/OFL-YuseiMagic.txt) |
| Anton | グラデーションの数字。輪郭にして描く | [SIL Open Font License 1.1](fonts/OFL-Anton.txt) |
| Noto Sans | 「PART 1」「Screact」などグラデーションの英字。輪郭にして描く | [SIL Open Font License 1.1](fonts/OFL-NotoSans.txt) |
| Noto Sans JP | 「両手」などグラデーションの日本語。輪郭にして描く | [SIL Open Font License 1.1](fonts/OFL-NotoSansJP.txt) |

## 作り直し方

```bash
python scripts/readme/title.py
python scripts/readme/heads.py
python scripts/readme/figures.py
python scripts/readme/text_readme.py
python scripts/readme/check_text_size.py
```

Windows で文字化けする場合は `python -X utf8` で実行してください。
