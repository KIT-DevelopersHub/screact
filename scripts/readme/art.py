"""README の図に共通する部品（色・YouRay・ロゴの手・手指の骨格・ステッカー文字・カード・SVG の書き出し）。

見た目は Screact のロゴ・チラシ・アプリから取っている。
- ロゴのステッカー文字：太い黒の縁取り、ラベンダーの塗り、右下にずらした青紫の影
- チラシのカード：操作の色の枠と、①〜④の丸いタブ。強調はマーカーを引く
- アプリ：水彩の背景、ラベンダーのヘッダー、一つ目のゴースト YouRay
- 手の形は、スマホが実際に見ている手指21点の骨格で示す

図はすべて、ライト・ダーク × PC（幅838）・スマホ（幅324）の4種類を書き出し、README の <picture> で切り替える。
<img> で表示した SVG は外部のフォントを読めないため、丸ゴシックの文字は、使う字だけに絞ったフォント（OFL）を
埋め込む。フォントは google/fonts の固定した版から取得し、data/local/readme-fonts/（Git 対象外）に置いて再利用する。
"""
import base64
import io
import math
import re
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs" / "assets" / "readme"
FONT_CACHE = ROOT / "data" / "local" / "readme-fonts"
GOOGLE_FONTS = "https://raw.githubusercontent.com/google/fonts/5bd87dfc525c8a0d1d8529d3684716e00c3fc59a/ofl/"
EMBED = {
    ("rnd", 700): ("ScRounded", "mplusrounded1c/MPLUSRounded1c-Bold.ttf"),
    ("rnd", 800): ("ScRounded", "mplusrounded1c/MPLUSRounded1c-ExtraBold.ttf"),
}
USED = {}

PC_W = 838
PHONE_W = 324

# ロゴの色
INK = "#2E2E2E"        # 縁取り
LAV = "#F1DAFD"        # 文字の塗り
VIOLET = "#6E5CFF"     # ずらした影
SKIN, NAIL, SLEEVE = "#FFEBD8", "#FFC387", "#C8CCE8"
MARKER = "#FFB26B"     # チラシのマーカー

# チラシの4つの操作の色（①描く・消す ②クリック ③ドラッグ ④スクロール）
OPS = {"draw": "#6B6FD6", "click": "#F2A93B", "drag": "#2FB58A", "scroll": "#F0679E"}
ORDER = ["draw", "click", "drag", "scroll"]

# YouRay（desktop/assets/production_character.png と同じ色）
YOU = {"body": "#FAFAFA", "line": "#424242", "iris": "#B4CACA", "pupil": "#2F2F2F"}

THEMES = {
    "light": {"ink": "#2E2C38", "muted": "#5F5B6B", "line": "#D9D5E5", "page": "#FFFFFF", "tint": .12,
              "card": "#FFFFFF", "screen": "#F6F8FB", "frame": "#3F3F48", "stand": "#9C99AA", "dot": "#FFFFFF",
              "aqua": "#C6F1F6", "mint": "#C3F2E6", "lav": "#E9E1FB"},
    "dark": {"ink": "#EEF0F6", "muted": "#AEB2C2", "line": "#3A3F52", "page": "#0D1117", "tint": .16,
             "card": "#161B26", "screen": "#222838", "frame": "#9095A8", "stand": "#5E6377", "dot": "#0D1117",
             "aqua": "#12333A", "mint": "#113630", "lav": "#231E3A"},
}

FONTS = """
.gh{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','Noto Sans','Hiragino Sans','Yu Gothic UI','Meiryo',Helvetica,Arial,sans-serif}
.rnd{font-family:ScRounded,'Hiragino Maru Gothic ProN','Yu Gothic UI','Noto Sans JP',sans-serif}
"""

MOTION = """
@keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-3px)}}
@keyframes blink{0%,92%,100%{transform:scaleY(1)}95%{transform:scaleY(.1)}}
.float{animation:float 3.2s ease-in-out infinite}
.blink{transform-box:fill-box;transform-origin:center;animation:blink 5.2s infinite}
@media (prefers-reduced-motion:reduce){*{animation:none!important}}
"""


def mix(hex_color, bg, k):
    """hex_color を bg に k の割合で重ねた色。"""
    c = [int(hex_color[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(bg[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(b[i] + (c[i] - b[i]) * k):02X}" for i in range(3))


# ---------- YouRay ----------
GHOST = ("M60 4C86 4 99 21 103 43C106 58 109 66 115 72C121 78 118 85 109 85"
         "C96 86 88 82 78 84C70 86 66 89 60 89C54 89 50 86 42 84C32 82 24 86 11 85"
         "C2 85-1 78 5 72C11 66 14 58 17 43C21 21 34 4 60 4Z")
FOOT = 89


def eye(mood="normal", cls="blink"):
    ring = f'<circle cx="60" cy="34" r="12.5" fill="{YOU["iris"]}" stroke="{YOU["line"]}" stroke-width="5"/>'
    if mood == "happy":
        return f'<path d="M48 37q12-15 24 0" fill="none" stroke="{YOU["line"]}" stroke-width="5" stroke-linecap="round"/>'
    if mood == "closed":
        return f'<path d="M48 35q12 9 24 0" fill="none" stroke="{YOU["line"]}" stroke-width="5" stroke-linecap="round"/>'
    dx, dy, r = {"normal": (0, 1, 4.6), "surprised": (0, 0, 2.6), "left": (-5, 1, 4.6), "right": (5, 1, 4.6),
                 "up": (0, -4, 4.6), "down": (2, 5, 4.6)}[mood]
    big = ' transform="translate(60 34) scale(1.15) translate(-60 -34)"' if mood == "surprised" else ""
    c = f' class="{cls}"' if cls else ""
    return (f'<g{c}{big}>{ring}<circle cx="{60 + dx}" cy="{34 + dy}" r="{r}" fill="{YOU["pupil"]}"/>'
            f'<circle cx="{61.6 + dx}" cy="{35.8 + dy}" r="1.4" fill="#FFFFFF"/></g>')


def ghost(mood="normal", cls="blink"):
    """原点が足元（すその中央）になる YouRay。原寸は幅120。"""
    return (f'<g transform="translate(-60 -{FOOT})"><path d="{GHOST}" fill="{YOU["body"]}" stroke="{YOU["line"]}" '
            f'stroke-width="4.5" stroke-linejoin="round"/>{eye(mood, cls)}</g>')


def youray(x, y, s=1.0, mood="normal", animate=True, delay=0.0):
    fl = f' class="float" style="animation-delay:{delay:.2f}s"' if animate else ""
    return (f'<g transform="translate({x:.1f} {y:.1f}) scale({s:.4f})"><g{fl}>'
            f'{ghost(mood, "blink" if animate else "")}</g></g>')


# ---------- ロゴの手 ----------
# docs/assets/readme/screact-logo.png の手の輪郭をなぞった点（ロゴを切り抜いた座標）。爪は親指の先。
_HAND = [(590, 187), (574, 183), (549, 172), (499, 140), (462, 105), (437, 73), (423, 60), (401, 48), (368, 43),
         (331, 48), (260, 66), (229, 76), (187, 94), (159, 115), (109, 162), (77, 185), (71, 194), (70, 204),
         (76, 214), (96, 217), (131, 207), (162, 190), (176, 175), (191, 152), (245, 136), (270, 131), (283, 147),
         (296, 153), (308, 155), (312, 161), (312, 169), (294, 230), (286, 238), (217, 271), (196, 286), (182, 305),
         (181, 328), (187, 333), (207, 333), (219, 331), (233, 324), (256, 317), (300, 312), (326, 317), (370, 337),
         (404, 342), (427, 339), (495, 317), (526, 317), (551, 323), (564, 296), (576, 262), (588, 210)]
_NAIL = [(227, 160), (236, 175), (250, 190), (268, 202), (284, 206), (294, 170), (276, 163), (264, 150)]
GRIP = (128, 252)  # 人差し指の先と親指のあいだ。つまむ物の上端をここに合わせる


def smooth(pts, closed=True, t=.5):
    """点の列を Catmull-Rom の曲線（3次ベジェ）にする。"""
    n = len(pts)
    d = f"M{pts[0][0]:.1f} {pts[0][1]:.1f}"
    for i in range(n if closed else n - 1):
        p0, p1, p2, p3 = pts[(i - 1) % n], pts[i], pts[(i + 1) % n], pts[(i + 2) % n]
        c1 = (p1[0] + (p2[0] - p0[0]) * t / 3, p1[1] + (p2[1] - p0[1]) * t / 3)
        c2 = (p2[0] - (p3[0] - p1[0]) * t / 3, p2[1] - (p3[1] - p1[1]) * t / 3)
        d += f"C{c1[0]:.1f} {c1[1]:.1f} {c2[0]:.1f} {c2[1]:.1f} {p2[0]:.1f} {p2[1]:.1f}"
    return d + ("Z" if closed else "")


def hand(scale, sleeve=True, stroke=12):
    """ロゴの手。原点がつまむ点（GRIP）。scale はロゴの大きさに対する倍率。手首には袖を付ける。"""
    gx, gy = GRIP
    body = (f'<path d="{smooth(_HAND)}" fill="{SKIN}" stroke="{INK}" stroke-width="{stroke}" stroke-linejoin="round"/>'
            f'<path d="{smooth(_NAIL)}" fill="{NAIL}"/>')
    cuff = (f'<path d="M548 150L700 112L744 300L560 336Z" fill="{SLEEVE}" stroke="{INK}" stroke-width="{stroke}" stroke-linejoin="round"/>'
            if sleeve else "")
    return f'<g transform="scale({scale:.4f}) translate({-gx} {-gy})">{cuff}{body}</g>'


# ---------- 手指21点の骨格（MediaPipe の並び） ----------
BONES = [(0, 1), (1, 2), (2, 3), (3, 4), (0, 5), (5, 6), (6, 7), (7, 8), (5, 9), (9, 10), (10, 11), (11, 12),
         (9, 13), (13, 14), (14, 15), (15, 16), (13, 17), (0, 17), (17, 18), (18, 19), (19, 20)]
TIPS = (4, 8, 12, 16, 20)


def _chain(base, ang, lens, curls):
    pts, (x, y), a = [], base, math.radians(ang)
    for L, c in zip(lens, curls):
        a += math.radians(c)
        x, y = x + L * math.cos(a), y + L * math.sin(a)
        pts.append((x, y))
    return pts


BASES = {"thumb": (-16, -12), "index": (-17, -46), "middle": (-4, -50), "ring": (9, -47), "pinky": (20, -40)}
UP = {"index": -100, "middle": -91, "ring": -82, "pinky": -72}
LENS = {"index": (22, 14, 11), "middle": (24, 15, 12), "ring": (22, 14, 11), "pinky": (17, 11, 9)}


def _unit(ang):
    a = math.radians(ang)
    return math.cos(a), math.sin(a)


def _straight(f, ang=None):
    ux, uy = _unit(UP[f] if ang is None else ang)
    bx, by = BASES[f]
    out, d = [], 0
    for L in LENS[f]:
        d += L
        out.append((bx + ux * d, by + uy * d))
    return out


def _curl(f):
    """握った指：少し上に出て、手のひらの側へ折り返す（正面から見た形）。"""
    ux, uy = _unit(UP[f])
    bx, by = BASES[f]
    return [(bx + ux * 13, by + uy * 13), (bx + ux * 8 + 1, by + uy * 8 + 2), (bx + ux * 1 + 1, by + uy * 1 + 5)]


def _bend(base, tip, bulge, n=4):
    """base から tip へ、外側にふくらむ曲線の上に n 点を置く（最後が tip）。"""
    (x0, y0), (x1, y1) = base, tip
    mx, my = (x0 + x1) / 2, (y0 + y1) / 2
    dx, dy = x1 - x0, y1 - y0
    L = math.hypot(dx, dy) or 1
    cx, cy = mx - dy / L * bulge, my + dx / L * bulge
    out = []
    for i in range(1, n + 1):
        t = i / n
        out.append(((1 - t) ** 2 * x0 + 2 * (1 - t) * t * cx + t * t * x1, (1 - t) ** 2 * y0 + 2 * (1 - t) * t * cy + t * t * y1))
    return out


def pose(kind):
    """手のひらを見せた右手の21点（手首が原点、上が -y、手の高さ約100）。"""
    fingers = {f: _straight(f) for f in UP}
    thumb = _bend(BASES["thumb"], (-46, -42), -6, 3)
    if kind in ("point", "fist", "pinch", "two", "thumbsup"):
        for f in ("middle", "ring", "pinky"):
            fingers[f] = _curl(f)
    if kind == "point":
        thumb = _bend(BASES["thumb"], (-6, -34), 10, 3)
    elif kind == "pinch":
        t_ = (-44, -66)
        fingers["index"] = _bend(BASES["index"], t_, 9, 3)
        thumb = _bend(BASES["thumb"], (t_[0] + 2, t_[1] + 4), -10, 3)
    elif kind == "two":
        fingers["index"] = _straight("index", -94)
        fingers["middle"] = _straight("middle", -99)
        thumb = _bend(BASES["thumb"], (-6, -34), 10, 3)
    elif kind == "fist":
        fingers["index"] = _curl("index")
        thumb = _bend(BASES["thumb"], (0, -30), 10, 3)
    elif kind == "thumbsup":
        fingers["index"] = _curl("index")
        thumb = _bend(BASES["thumb"], (-30, -78), -4, 3)
    pts = [(0, 0), BASES["thumb"]] + thumb
    for f in ("index", "middle", "ring", "pinky"):
        pts += [BASES[f]] + fingers[f]
    return pts


def skeleton(kind, x, y, s, color, t, mark=()):
    """手指21点の骨格。(x, y) は手首。骨は操作の色の線、関節は縁取りした点。mark の点は大きく光らせる。"""
    pts = [(x + px * s, y + py * s) for px, py in pose(kind)]
    k = s ** .5
    lines_ = "".join(f'<path d="M{pts[a][0]:.1f} {pts[a][1]:.1f}L{pts[b][0]:.1f} {pts[b][1]:.1f}"/>' for a, b in BONES)
    hi = "".join(f'<circle cx="{pts[i][0]:.1f}" cy="{pts[i][1]:.1f}" r="{7.5 * k:.1f}" fill="{color}" opacity=".3"/>' for i in mark)
    joints = "".join(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="{(3.4 if i in TIPS else 2.7) * k:.1f}"/>' for i, (px, py) in enumerate(pts))
    return (hi + f'<g stroke="{color}" stroke-width="{2.6 * k:.1f}" stroke-linecap="round">{lines_}</g>'
            f'<g fill="{t["dot"]}" stroke="{color}" stroke-width="{1.6 * k:.1f}">{joints}</g>')


def tip(kind, x, y, s, i):
    px, py = pose(kind)[i]
    return x + px * s, y + py * s


# ---------- 文字 ----------

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size, fill, cls="gh", weight=700, anchor="start", extra=""):
    if cls == "rnd":
        USED.setdefault(("rnd", 800 if weight >= 800 else 700), set()).update(s)
    return (f'<text x="{x:.1f}" y="{y:.1f}" class="{cls}" font-size="{size}" font-weight="{weight}" '
            f'fill="{fill}" text-anchor="{anchor}"{extra}>{esc(s)}</text>')


def sticker(x, y, s, size, anchor="start", fill=LAV, shadow=VIOLET):
    """ロゴと同じステッカーの文字：右下にずらした青紫の影、太い黒の縁取り、ラベンダーの塗り。"""
    sw = size * .17
    off = size * .07
    common = ' stroke-linejoin="round" paint-order="stroke"'
    return (text(x + off, y + off * 1.25, s, size, shadow, cls="rnd", weight=800, anchor=anchor,
                 extra=f' stroke="{shadow}" stroke-width="{sw:.1f}"{common}')
            + text(x, y, s, size, fill, cls="rnd", weight=800, anchor=anchor,
                   extra=f' stroke="{INK}" stroke-width="{sw:.1f}"{common}'))


def marker(x, y, w, h=10, color=MARKER, opacity=.7):
    """チラシと同じ、文字の下に引いたマーカー（少し右上がり）。(x, y) は左上。"""
    return (f'<path d="M{x:.1f} {y + h * .2:.1f}L{x + w:.1f} {y - h * .05:.1f}L{x + w - 3:.1f} {y + h * .85:.1f}'
            f'L{x + 2:.1f} {y + h * 1.05:.1f}Z" fill="{color}" opacity="{opacity}"/>')


def font_faces():
    from fontTools import subset
    from fontTools.ttLib import TTFont
    css = []
    for (cls, weight), chars in sorted(USED.items()):
        family, path = EMBED[(cls, weight)]
        local = FONT_CACHE / Path(path).name
        if not local.exists():
            FONT_CACHE.mkdir(parents=True, exist_ok=True)
            urllib.request.urlretrieve(GOOGLE_FONTS + path, local)
        font = TTFont(local, recalcTimestamp=False)
        opts = subset.Options()
        opts.flavor = "woff"
        opts.name_IDs = ["*"]
        opts.hinting = False
        sub = subset.Subsetter(opts)
        sub.populate(text="".join(sorted(chars)))
        sub.subset(font)
        buf = io.BytesIO()
        font.flavor = "woff"
        font.save(buf)
        data = base64.b64encode(buf.getvalue()).decode()
        css.append(f"@font-face{{font-family:{family};font-weight:{weight};"
                   f"src:url(data:font/woff;base64,{data}) format('woff')}}")
    USED.clear()
    return "".join(css)


def svg(w, h, body, t, title, extra_css=""):
    faces = font_faces()
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h:.0f}" width="{w}" height="{h:.0f}" role="img">'
            f'<title>{esc(title)}</title><style>{faces}{FONTS}{MOTION}{extra_css}</style>{body}</svg>')


# ---------- 文字の折り返し ----------
NO_START = set("、。，．）」』】！？ー…・〜ぁぃぅぇぉっゃゅょァィゥェォッャュョ％%)")
BREAK_AFTER = set("、。・／）」』！？")


def cw(c, size):
    return size * (0.6 if ord(c) < 0x2E80 else 1.0)


def tw(s, size):
    return sum(cw(c, size) for c in s)


def lines(s, size, avail):
    if "\n" in s:
        return [ln for part in s.split("\n") for ln in lines(part, size, avail)]
    out, cur = [], ""
    for c in s:
        if cur and tw(cur + c, size) > avail:
            if c in NO_START:
                cur += c
                continue
            m = re.search(r"[A-Za-z0-9.%\-]+$", cur)
            if m and m.start() > 0 and re.match(r"[A-Za-z0-9.%\-]", c):
                out.append(cur[:m.start()])
                cur = cur[m.start():] + c
                continue
            k = max((i for i, ch in enumerate(cur) if ch in BREAK_AFTER), default=-1)
            if 0 <= k < len(cur) - 1 and len(cur) - 1 - k <= 6 and tw(cur[:k + 1], size) >= avail * .8:
                out.append(cur[:k + 1])
                cur = cur[k + 1:] + c
                continue
            out.append(cur)
            cur = c
        else:
            cur += c
    if cur:
        out.append(cur)
    return out


def para(x, y, s, size, fill, avail, lh, weight=400, anchor="start"):
    ls = lines(s, size, avail)
    return "".join(text(x, y + i * lh, ln, size, fill, weight=weight, anchor=anchor) for i, ln in enumerate(ls)), len(ls)


# ---------- カード（チラシの形） ----------

def card(x, y, w, h, t, color, rx=18):
    """操作の色の枠と、うすく色を敷いた面。"""
    base = t["page"] if t["page"] == "#FFFFFF" else t["card"]
    return (f'<rect x="{x + 1.5:.1f}" y="{y + 1.5:.1f}" width="{w - 3:.1f}" height="{h - 3:.1f}" rx="{rx}" '
            f'fill="{mix(color, base, t["tint"])}" stroke="{color}" stroke-width="3"/>')


def tab(cx, y, label, color, size=17, fg="#FFFFFF"):
    """カードの上の枠に重ねる丸いタブ（チラシの「① 描く/消す」の形）。(cx, y) は中心。(svg, 幅) を返す。"""
    w = tw(label, size) + 30
    return (f'<rect x="{cx - w / 2:.1f}" y="{y - 17}" width="{w:.1f}" height="34" rx="17" fill="{color}"/>'
            + text(cx, y + size * .36, label, size, fg, cls="rnd", weight=800, anchor="middle")), w


def blobs(t, spots):
    """水彩の背景（アプリと同じ、水色・ミント・ラベンダーのにじみ）。spots: [(x, y, r, 色の名前)]。"""
    global _BLOB
    out = []
    for x, y, r, c in spots:
        _BLOB += 1
        gid = f"wc{_BLOB}"
        out.append(f'<radialGradient id="{gid}"><stop offset="0" stop-color="{t[c]}"/><stop offset=".6" stop-color="{t[c]}" stop-opacity=".75"/>'
                   f'<stop offset="1" stop-color="{t[c]}" stop-opacity="0"/></radialGradient>'
                   f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="url(#{gid})"/>')
    return "".join(out)


_BLOB = 0


def monitor(x, y, w, t, inner="", stand=True, sw=2.4):
    """枠だけのモニター。inner はモニターの左上を原点に描く。高さは w*0.62。"""
    h = w * .62
    out = [f'<rect x="{x:.1f}" y="{y:.1f}" width="{w}" height="{h:.1f}" rx="{w * .04:.1f}" fill="{t["screen"]}" stroke="{t["frame"]}" stroke-width="{sw}"/>']
    if inner:
        out.append(f'<g transform="translate({x:.1f} {y:.1f})">{inner}</g>')
    if stand:
        out.append(f'<rect x="{x + w / 2 - 3:.1f}" y="{y + h:.1f}" width="6" height="{w * .09:.1f}" fill="{t["stand"]}"/>'
                   f'<rect x="{x + w / 2 - w * .15:.1f}" y="{y + h + w * .09:.1f}" width="{w * .3:.1f}" height="4" rx="2" fill="{t["stand"]}"/>')
    return "".join(out)


def phone(x, y, h, t, tilt=0):
    """スマホ。画面に Screact のアプリ（YouRay のアイコン）を出す。(x, y) は左上。"""
    w = h * .5
    s = w * .56
    icon = (f'<rect x="{x + (w - s) / 2:.1f}" y="{y + h * .3:.1f}" width="{s:.1f}" height="{s:.1f}" rx="{s * .25:.1f}" fill="#AEC8D0"/>'
            + youray(x + w / 2, y + h * .3 + s * .8, s / 170, animate=False))
    return (f'<g transform="rotate({tilt} {x + w / 2:.1f} {y + h:.1f})"><rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h}" '
            f'rx="{w * .18:.1f}" fill="{t["card"]}" stroke="{t["frame"]}" stroke-width="2.4"/>{icon}'
            f'<circle cx="{x + w / 2:.1f}" cy="{y + h * .1:.1f}" r="{w * .05:.1f}" fill="{t["frame"]}"/></g>')


def write(files):
    import xml.etree.ElementTree as ET
    for name, body in files.items():
        ET.fromstring(body)
        path = OUT / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body + "\n", encoding="utf-8", newline="\n")
    return len(files)
