"""README.md から、画像を使わない文字だけの README-text.md を作る。

README.md のほとんどが画像なので、画像が読み込めないときにも同じ内容を読めるようにする。
文章は README.md のまま使い、<picture> だけを、同じ内容の見出し・箇条書きに置き換える。
図の中身は、各 SVG の代替テキスト（<title>。図と同じデータから書いている）から作る。README-text.md は直接編集しない。

    python scripts/readme/text_readme.py
"""
import html
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import heads  # noqa: E402
import title  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
HEAD = {num: (jp, en) for num, jp, en, _ in heads.HEADS}
PART = {p: (jp, en) for p, jp, en, _, _ in heads.PARTS}


def alt_of(block):
    return html.unescape(re.search(r'alt="([^"]*)"', block).group(1))


def bullets(alt):
    """「見出し。項目。項目」を、太字の見出しと箇条書きにする。"""
    parts = [p for p in alt.split("。") if p]
    if len(parts) == 1:
        return parts[0] + "。"
    items = []
    for p in parts[1:]:
        # 「名前：」で始まる文は新しい項目。そうでない文は、直前の項目の続き
        if re.match(r"^[^、。：]{1,30}：", p) or not items:
            items.append(p + "。")
        else:
            items[-1] += p + "。"
    return f"**{parts[0]}**\n\n" + "\n".join(f"- {p}" for p in items)


def convert(block):
    src = re.search(r'<img src="([^"]+)"', block).group(1)
    name = Path(src).name.replace("-light.svg", "")
    if name == "title":
        return (f"Screact\n\n> {title.NOTE}\n\n**{title.CATCH}**")
    m = re.match(r"play-(\d\d)$", name)
    if m:
        return f"{m.group(1)} {HEAD[m.group(1)][0]}"
    m = re.match(r"part-(\d)$", name)
    if m:
        jp, en = PART[m.group(1)]
        return f"PART {m.group(1)} {jp}（{en}）"
    m = re.match(r"toc-(\d\d)$", name)
    if m:
        return f"{m.group(1)} {HEAD[m.group(1)][0]}"
    m = re.match(r"toc-part-(\d)$", name)
    if m:
        return f"PART {m.group(1)} {PART[m.group(1)][0]}"
    if name.endswith("-title"):
        return f"**{alt_of(block)}**"
    if name == "video-cta":
        return "▶ デモ動画を見る（Google Drive・約33秒）"
    return bullets(alt_of(block))


def main():
    s = (ROOT / "README.md").read_text(encoding="utf-8")
    # 目次（画像の並び）は、文字のリンクの一覧にする
    def toc(m):
        out = []
        for part, (jp, en) in PART.items():
            first, last = [(f, l) for p, _, _, f, l in heads.PARTS if p == part][0]
            out.append(f"- [PART {part} {jp}](#{jp})")
            for num, (hj, _) in HEAD.items():
                if first <= num <= last:
                    anchor = [a for n, _, _, a in heads.HEADS if n == num][0]
                    out.append(f"  - [{num} {anchor}](#{anchor})")
        return "\n".join(out)
    s = re.sub(r"<p>\n<a href=\"#製品概要\">.*?</p>", toc, s, flags=re.S)
    s = re.sub(r"<h1>(<picture>.*?</picture>)</h1>", lambda m: "# " + convert(m.group(1)), s, flags=re.S)
    s = re.sub(r"<a href=\"([^\"]+)\"><picture>.*?</picture></a>", lambda m: f"[{convert(m.group(0))}]({m.group(1)})", s, flags=re.S)
    s = re.sub(r"<a href=\"([^\"]+)\"><img [^>]*></a>", "", s)
    s = re.sub(r"<picture>.*?</picture>", lambda m: convert(m.group(0)), s, flags=re.S)
    s = s.replace("<br>\n\n", "")
    assert "<picture>" not in s and "<img" not in s, "画像が残っている"
    head = ("> [!NOTE]\n> 画像を使わない、文字だけの README です。図の入った通常版は [README.md](README.md) にあります。"
            "この文書は `python scripts/readme/text_readme.py` が README.md から作ります。\n\n")
    s = re.sub(r"^(# .*?\n)", lambda m: m.group(1) + "\n" + head, s, count=1, flags=re.S)
    (ROOT / "README-text.md").write_text(s, encoding="utf-8", newline="\n")
    print("wrote README-text.md")


if __name__ == "__main__":
    main()
