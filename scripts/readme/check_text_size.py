"""README の画像（SVG）の文字が、GitHub上で何pxで表示されるかを見積もる。

GitHub の本文欄は PC で 838px、幅390px のスマホで 324px（どちらも実測）。本文は16px。
<picture> の source から、幅ごとに表示される画像を選び、表示幅 ÷ 画像の幅 で文字を縮めた大きさを出す。
飾り（区切りの帯）を除き、MIN_PX より小さい文字があれば一覧にして終了コード1を返す。

    python scripts/readme/check_text_size.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# 名前 → (本文欄の幅, 画面の幅)。<source> の max-width は画面の幅と比べる
COLUMNS = {"PC": (838, 1280), "スマホ": (324, 390)}
MIN_PX = 12.5
DECOR = ()
FIXED = ()


def svg_info(path):
    s = (ROOT / path).read_text(encoding="utf-8")
    width = float(re.search(r'viewBox="[-\d.]+ [-\d.]+ ([\d.]+) ', s).group(1))
    # 見出しの横の舞台（入れ子の svg）には文字を置かない
    s = re.sub(r"<svg x=.*?</svg>", "", s, flags=re.S)
    sizes = []
    for m in re.finditer(r'<text[^>]*font-size="([\d.]+)"[^>]*>([^<]*)</text>', s):
        sizes.append((float(m.group(1)), m.group(2)))
    return width, sizes


def pick(block, screen):
    """picture 要素から、画面の幅 screen（ライト）で表示される画像を返す。"""
    for media, src in re.findall(r'<source media="([^"]+)" srcset="([^"]+)"', block):
        if "prefers-color-scheme: dark" in media:
            continue
        limit = re.search(r"max-width: (\d+)px", media)
        if limit and screen <= int(limit.group(1)):
            return src
    return re.search(r'<img src="([^"]+)"', block).group(1)


def main():
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    blocks = re.findall(r"<picture>.*?</picture>", readme, re.S)
    rest = re.sub(r"<picture>.*?</picture>", "", readme, flags=re.S)
    blocks += re.findall(r"<img [^>]*>", rest)
    bad = []
    for name, (col, screen) in COLUMNS.items():
        print(f"== {name}（本文欄 {col}px、本文16px）")
        for block in blocks:
            src = pick(block, screen)
            if not src.endswith(".svg") or src.startswith("http"):
                continue
            w_attr = re.search(r'<img[^>]*\swidth="([\d.]+)(%?)"', block)
            h_attr = re.search(r'<img[^>]*\sheight="([\d.]+)"', block)
            width, sizes = svg_info(src)
            if not sizes:
                continue
            if w_attr and w_attr.group(2) == "%":
                shown = col * float(w_attr.group(1)) / 100
            elif w_attr:
                shown = min(float(w_attr.group(1)), col)
            elif h_attr:
                continue  # 高さ指定の小さな印
            else:
                shown = min(width, col)
            k = shown / width
            small = min(sizes)[0] * k
            print(f"  {src:60s} 倍率{k:.2f}  最小{small:5.1f}px  最大{max(sizes)[0] * k:5.1f}px")
            if small < MIN_PX and not src.startswith(DECOR + FIXED):
                worst = sorted({t for sz, t in sizes if sz * k < MIN_PX})[:3]
                bad.append(f"{name} {src}: {small:.1f}px {worst}")
    if bad:
        print("\n小さすぎる文字：\n  " + "\n  ".join(bad))
        sys.exit(1)
    print(f"\nPASS: 飾りを除くすべての画像の文字が {MIN_PX}px 以上")


if __name__ == "__main__":
    main()
