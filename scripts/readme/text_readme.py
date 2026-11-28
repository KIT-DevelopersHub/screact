"""README.md から、画像を使わない文字だけの README-text.md を作る。

README.md の図は画像なので、画像が読み込めないときにも同じ内容を読めるようにする。
文章は README.md のまま使い、<picture> だけを、同じ内容の文章・箇条書きに置き換える。
図の中身は、各 SVG の代替テキスト（<title>。図と同じデータから書いている）から作る。README-text.md は直接編集しない。

    python scripts/readme/text_readme.py
"""
import html
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import title  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


def alt_of(block):
    return html.unescape(re.search(r'alt="([^"]*)"', block).group(1))


def bullets(alt):
    """「見出し。項目。項目」を、太字の見出しと箇条書きにする。「名前：」で始まらない文は、直前の項目の続きにする。"""
    parts = [p for p in alt.split("。") if p]
    if len(parts) == 1:
        return parts[0] + "。"
    items = []
    for p in parts[1:]:
        if re.match(r"^[^、。：]{1,30}：", p) or not items:
            items.append(p + "。")
        else:
            items[-1] += p + "。"
    return f"**{parts[0]}**\n\n" + "\n".join(f"- {p}" for p in items)


def convert(block):
    if 'title-light.svg' in block:
        return f"Screact\n\n> {title.NOTE}\n\n**{title.CATCH}**"
    return bullets(alt_of(block))


def main():
    s = (ROOT / "README.md").read_text(encoding="utf-8")
    s = re.sub(r"<h1>(<picture>.*?</picture>)</h1>", lambda m: "# " + convert(m.group(1)), s, flags=re.S)
    s = re.sub(r"<picture>.*?</picture>", lambda m: convert(m.group(0)), s, flags=re.S)
    s = re.sub(r'<p align="center"><img [^>]*></p>\n\n', "", s)
    s = re.sub(r'<div align="center">\n  <a href="([^"]+)">\n    <img [^>]*>\n  </a>\n  <br>\n', r'<div align="center">\n', s)
    s = re.sub(r'<div align="center">\n  <img [^>]*>\n  <br>\n', '<div align="center">\n', s)
    s = re.sub(r'<img src="./docs/assets/media/processing-flow.png"[^>]*>', "", s)
    s = re.sub(r'<img src="[^"]*" alt="([^"]*)">', lambda m: m.group(1), s)  # 実際の画面の写真は、代替テキストにする
    assert "<picture>" not in s, "図が残っている"
    head = ("> [!NOTE]\n> 画像を使わない、文字だけの README です。図の入った通常版は [README.md](README.md) にあります。"
            "この文書は `python scripts/readme/text_readme.py` が README.md から作ります。\n\n")
    s = re.sub(r"^(# .*?\n)", lambda m: m.group(1) + "\n" + head, s, count=1, flags=re.S)
    (ROOT / "README-text.md").write_text(s, encoding="utf-8", newline="\n")
    print("wrote README-text.md")


if __name__ == "__main__":
    main()
