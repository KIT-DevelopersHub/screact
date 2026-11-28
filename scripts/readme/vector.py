"""README の SVG を、iPhone の Safari でもぼやけない形に直す（build_art.svg が書き出しの最後に通す）。

Safari（WebKit）は、<img> で表示した SVG の中の次の3つを、いったん画像（ImageBuffer）にしてから描く。
その画像が端末の倍率を考えずに作られるため、高解像度の画面ではぼやける（2026-11-22、利用者が iPhone で
見出しの番号のぼやけを確認。原因は WebKit の描き方からの推測で、WebKit の Windows 版では再現しない）。

1. グラデーションで塗った <text>（見出しの「01」など）。文字の形をマスクの画像にしてから塗るため。
   → フォントの輪郭を <path> にする（vector_text）。<path> のグラデーションは画像を作らずに塗られる。
2. 光彩のフィルタ（filter="url(#glow)"）。フィルタを通した図形は丸ごと画像になる。
   → にじみ（ぼかし）だけをフィルタで描き、元の図形はフィルタの外に重ねる（split_glow）。
     にじみはもともとぼやけた絵なので、画像になっても見た目は変わらない。
3. マスク（mask）。見出しの舞台の端のフェードは head_play.stage でマスクを使わない形にした。

輪郭に使うフォントは google/fonts の固定した版（OFL）から取得する。ブラウザの書体指定（Impact など）とは
少し形が違うが、どの端末でも同じ形になる。
"""
import re
import urllib.request
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FONT_CACHE = ROOT / "data" / "local" / "readme-fonts"
GOOGLE_FONTS = "https://raw.githubusercontent.com/google/fonts/5bd87dfc525c8a0d1d8529d3684716e00c3fc59a/ofl/"

# (クラス, 太さ) → (google/fonts のパス, 可変フォントの軸, 大きさの倍率)。CSS の書体指定に近い OFL のフォント。
# Anton は Impact より数字が約7.5%高い（数字の高さ 0.867em と 0.806em）。0.93倍にして同じ高さにそろえる。
OUTLINE = {
    ("disp", 400): ("anton/Anton-Regular.ttf", None, 0.93),  # Impact に近い細長い太字。引用符の形も近い
    ("gh", 700): ("notosans/NotoSans[wdth,wght].ttf", {"wght": 700, "wdth": 100}, 1.0),
    ("gh", 800): ("notosans/NotoSans[wdth,wght].ttf", {"wght": 800, "wdth": 100}, 1.0),
    ("jp", 900): ("notosansjp/NotoSansJP[wght].ttf", {"wght": 900}, 1.0),
}


@lru_cache(maxsize=None)
def font(cls, weight):
    from fontTools.ttLib import TTFont
    path, axes, _ = OUTLINE[(cls, weight)]
    local = FONT_CACHE / Path(path).name
    if not local.exists():
        FONT_CACHE.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(GOOGLE_FONTS + path.replace("[", "%5B").replace("]", "%5D"), local)
    f = TTFont(local, recalcTimestamp=False)
    if axes:
        from fontTools.varLib import instancer
        f = instancer.instantiateVariableFont(f, axes)
    return f


def width(s, size, cls="disp", weight=400):
    """輪郭にする書体での、文字列の幅（字間なし）。数字の後ろに単位を並べる位置の計算に使う。"""
    f = font(cls, weight)
    cmap, hmtx = f.getBestCmap(), f["hmtx"]
    if cls == "disp":
        s = s.replace("–", "—")
    return sum(hmtx[cmap[ord(c)]][0] for c in s) * size * OUTLINE[(cls, weight)][2] / f["head"].unitsPerEm


def _num(a, name, default=None):
    m = re.search(rf'\s{name}="([-\d.]+)"', a)
    return float(m.group(1)) if m else default


def _str(a, name, default=None):
    m = re.search(rf'\s{name}="([^"]*)"', a)
    return m.group(1) if m else default


def _unescape(s):
    return s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&#39;", "'").replace("&amp;", "&")


def text_path(attrs, s):
    """<text> の属性と文字列から、同じ位置・大きさの <path> を作る。"""
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.transformPen import TransformPen
    cls = _str(attrs, "class")
    weight = int(_num(attrs, "font-weight", 400))
    f = font(cls, weight)
    cmap, gs, hmtx = f.getBestCmap(), f.getGlyphSet(), f["hmtx"]
    upem = f["head"].unitsPerEm
    size = _num(attrs, "font-size") * OUTLINE[(cls, weight)][2]
    k = size / upem
    ls = _num(attrs, "letter-spacing", 0.0)
    s = _unescape(s)
    if cls == "disp":
        s = s.replace("–", "—")  # Anton の en dash は Impact より短く細い。長さの近い em dash で描く
    names = []
    for ch in s:
        if ord(ch) not in cmap:
            raise SystemExit(f"輪郭のフォントに字がない：{ch!r}（{cls} {weight}）")
        names.append(cmap[ord(ch)])
    # 字送り（ブラウザと同じく、字間は各字の後ろに足す）
    adv = [hmtx[n][0] * k + ls for n in names]
    total = sum(adv)
    sx = 1.0
    length = _num(attrs, "textLength")
    if length is not None and _str(attrs, "lengthAdjust") == "spacingAndGlyphs":
        sx = length / total
        total = length
    anchor = _str(attrs, "text-anchor", "start")
    x = _num(attrs, "x", 0.0) - {"start": 0, "middle": total / 2, "end": total}[anchor]
    y = _num(attrs, "y", 0.0)
    pen = SVGPathPen(gs, ntos=lambda v: f"{v:.2f}".rstrip("0").rstrip("."))
    cx = x
    for n, a in zip(names, adv):
        gs[n].draw(TransformPen(pen, (k * sx, 0, 0, -k, cx, y)))
        cx += a * sx
    keep = ""
    for name in ("fill", "opacity", "fill-opacity", "stroke", "stroke-width", "paint-order", "stroke-linejoin", "class", "style", "transform"):
        v = _str(attrs, name)
        if v is not None and name != "class":
            keep += f' {name}="{v}"'
    # 読み上げと検索のために元の文字を残す（画面には出さない）
    return f'<path d="{pen.getCommands()}"{keep}><title>{s}</title></path>'


def vector_text(svg):
    """グラデーションで塗った <text> を <path> にする。"""
    def repl(m):
        attrs, s = m.group(1), m.group(2)
        if not re.search(r'\sfill="url\(#', attrs):
            return m.group(0)
        return text_path(attrs, s)
    return re.sub(r"<text(\s[^>]*)>([^<]*)</text>", repl, svg)


def _group_end(svg, start):
    """svg[start] の <g ...> に対応する </g> の直後の位置。"""
    depth, i = 0, start
    for m in re.compile(r"<(/?)g[\s>]").finditer(svg, start):
        depth += -1 if m.group(1) else 1
        if depth == 0:
            return svg.index(">", m.start()) + 1
        i = m.end()
    raise ValueError("<g> が閉じていない")


def split_glow(svg):
    """<g filter="url(#glow)" …>中身</g> を、にじみだけのフィルタの <g> と、フィルタのない同じ中身の <g> に分ける。"""
    out, pos = [], 0
    pat = re.compile(r'<g filter="url\(#glow\)"([^>]*)>')
    while True:
        m = pat.search(svg, pos)
        if not m:
            out.append(svg[pos:])
            return "".join(out)
        end = _group_end(svg, m.start())
        inner = svg[m.end():end - len("</g>")]
        assert 'filter="url(#glow)"' not in inner and " id=" not in inner, "光彩の中に光彩や id がある"
        out.append(svg[pos:m.start()])
        out.append(f'<g filter="url(#glow)" aria-hidden="true"{m.group(1)}>{inner}</g><g{m.group(1)}>{inner}</g>')
        pos = end


def vectorize(svg):
    return split_glow(vector_text(svg))
