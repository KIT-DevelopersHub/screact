"""README の図に共通する部品（テーマ・色・YouRay・文字・SVG の書き出し）。

図はすべて、ライト・ダーク × PC（幅838）・スマホ（幅324）の4種類を書き出し、README の <picture> で切り替える。
デザインの考え方は docs/readme-design.md にある。kz_2613（Re:Cooplay）の README の仕組みを Screact 向けに組み直した。

<img> で表示した SVG は外部のフォントを読めないため、締めと吹き出しの文字は使う字だけに絞ったフォント（OFL）を
埋め込む。フォントは google/fonts の固定した版から取得し、data/local/readme-fonts/（Git 対象外）に置いて再利用する。
"""
import base64
import io
import math
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs" / "assets" / "readme"
FONT_CACHE = ROOT / "data" / "local" / "readme-fonts"
GOOGLE_FONTS = "https://raw.githubusercontent.com/google/fonts/5bd87dfc525c8a0d1d8529d3684716e00c3fc59a/ofl/"
EMBED = {
    ("rnd", 700): ("ScRounded", "mplusrounded1c/MPLUSRounded1c-Bold.ttf"),
    ("rnd", 800): ("ScRounded", "mplusrounded1c/MPLUSRounded1c-ExtraBold.ttf"),
    ("hand", 400): ("ScHand", "yuseimagic/YuseiMagic-Regular.ttf"),
}
USED = {}

PC_W = 838
PHONE_W = 324

# 4つの操作の色。図の中で「どの操作か」を示すときは、必ずこの4色を使う。
OPS = {
    "draw": "#F2669E",    # 描く・消す
    "click": "#6F7DF2",   # クリック・選択
    "drag": "#A06BFF",    # 掴む（ドラッグ）
    "scroll": "#3DB5C8",  # スクロール
}
ORDER = ["draw", "click", "drag", "scroll"]

# YouRay（アプリのアイコンとスプラッシュの一つ目のゴースト）。desktop/assets/production_character.png の色。
YOU = {"body": "#FAFAFA", "line": "#424242", "iris": "#B4CACA", "pupil": "#2F2F2F", "icon": "#AEC8D0"}
SKIN, SKIN_LINE = "#FBE3CB", "#3F3F3F"  # ロゴの手

THEMES = {
    "light": {
        "bg1": "#F1ECFB", "bg2": "#E5F0F3", "ink": "#2F2C3E", "muted": "#645F72", "line": "#DAD6E6",
        "dot": "#CFC7F2", "dot2": "#B7D3DB", "panel": "#FFFFFF", "panel2": "#F6F5FA", "screen": "#F7F8FB",
        "frame": "#3F3F48", "stand": "#9A97A8", "page": "#FFFFFF",
    },
    "dark": {
        "bg1": "#1C1933", "bg2": "#14222A", "ink": "#EEF0F6", "muted": "#AEB2C2", "line": "#363A4E",
        "dot": "#3B356A", "dot2": "#24485A", "panel": "#1B1F2B", "panel2": "#202534", "screen": "#262B3A",
        "frame": "#8B8FA3", "stand": "#5F6378", "page": "#0D1117",
    },
}

FONTS = """
.jp{font-family:'Hiragino Sans','Hiragino Kaku Gothic ProN','Yu Gothic UI','Yu Gothic','Meiryo','Noto Sans JP','Noto Sans CJK JP',sans-serif}
.disp{font-family:Impact,Haettenschweiler,'Anton','Arial Narrow Bold','Arial Black',sans-serif}
.gh{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','Noto Sans',Helvetica,Arial,sans-serif}
.rnd{font-family:ScRounded,'Hiragino Maru Gothic ProN','Yu Gothic UI','Noto Sans JP',sans-serif}
.hand{font-family:ScHand,'Hiragino Maru Gothic ProN','Yu Gothic UI','Noto Sans JP',sans-serif}
.mono{font-family:ui-monospace,SFMono-Regular,'Cascadia Mono',Consolas,'Liberation Mono',monospace}
"""

MOTION = """
@keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-4px)}}
@keyframes blink{0%,92%,100%{transform:scaleY(1)}95%{transform:scaleY(.1)}}
@keyframes flow{to{stroke-dashoffset:-28}}
.float{animation:float 3.2s ease-in-out infinite}
.blink{transform-box:fill-box;transform-origin:center;animation:blink 5.2s infinite}
.flow{stroke-dasharray:6 8;animation:flow 1.1s linear infinite}
@media (prefers-reduced-motion:reduce){*{animation:none!important}}
"""

# ---------- YouRay ----------
# 原寸は幅120・高さ92。足元（すその中央）が (60, 89)。
GHOST = ("M60 4C86 4 99 21 103 43C106 58 109 66 115 72C121 78 118 85 109 85"
         "C96 86 88 82 78 84C70 86 66 89 60 89C54 89 50 86 42 84C32 82 24 86 11 85"
         "C2 85-1 78 5 72C11 66 14 58 17 43C21 21 34 4 60 4Z")
GHOST_W, GHOST_H, FOOT = 120, 92, 89


def eye(mood="normal", cls="blink"):
    """一つ目。mood: normal・happy・surprised・closed・left・right・up。"""
    ring = f'<circle cx="60" cy="34" r="12.5" fill="{YOU["iris"]}" stroke="{YOU["line"]}" stroke-width="5"/>'
    if mood == "happy":
        return f'<path d="M48 37q12-15 24 0" fill="none" stroke="{YOU["line"]}" stroke-width="5" stroke-linecap="round"/>'
    if mood == "closed":
        return f'<path d="M48 35q12 9 24 0" fill="none" stroke="{YOU["line"]}" stroke-width="5" stroke-linecap="round"/>'
    dx, dy, r = {"normal": (0, 1, 4.6), "surprised": (0, 0, 2.6), "left": (-5, 1, 4.6), "right": (5, 1, 4.6),
                 "up": (0, -4, 4.6)}[mood]
    big = ' transform="translate(60 34) scale(1.15) translate(-60 -34)"' if mood == "surprised" else ""
    return (f'<g class="{cls}"{big}>{ring}<circle cx="{60 + dx}" cy="{34 + dy}" r="{r}" fill="{YOU["pupil"]}"/>'
            f'<circle cx="{61.6 + dx}" cy="{35.8 + dy}" r="1.4" fill="#FFFFFF"/></g>')


def ghost(mood="normal", cls="blink", blush=False):
    """原点が足元（すその中央）になる YouRay。大きさは呼び出し側で scale する。"""
    cheeks = (f'<ellipse cx="40" cy="50" rx="6" ry="3.2" fill="#F6B8C8" opacity=".75"/>'
              f'<ellipse cx="80" cy="50" rx="6" ry="3.2" fill="#F6B8C8" opacity=".75"/>') if blush else ""
    return (f'<g transform="translate(-60 -{FOOT})"><path d="{GHOST}" fill="{YOU["body"]}" stroke="{YOU["line"]}" '
            f'stroke-width="4.5" stroke-linejoin="round"/>{cheeks}{eye(mood, cls)}</g>')


def youray(x, y, s=1.0, mood="normal", animate=True, delay=0.0, blush=False):
    """(x, y) に足元を置いた YouRay。s=1 で幅120。"""
    fl = f' class="float" style="animation-delay:{delay:.2f}s"' if animate else ""
    return (f'<g transform="translate({x:.1f} {y:.1f}) scale({s:.4f})"><g{fl}>'
            f'{ghost(mood, "blink" if animate else "", blush)}</g></g>')


def shadow(x, y, w, t, opacity=.16):
    return f'<ellipse cx="{x:.1f}" cy="{y:.1f}" rx="{w / 2:.1f}" ry="{w / 9:.1f}" fill="{t["ink"]}" opacity="{opacity}"/>'


# ---------- ロゴの手（つまむ形） ----------
# 原点が、親指と人差し指の先が合わさる点。手の甲は右上へ伸びる（ロゴの手と同じ向き）。原寸は約 幅80・高さ56。
HAND_BACK = ("M76-34C78-46 66-54 52-52L22-48C10-46 2-38 1-26L0-8C0-2 7 0 9-5L12-18"
             "C14-24 20-27 27-26L58-22C68-20 75-25 76-34Z")
HAND_THUMB = "M30-24C34-14 30-4 20 0C14 2 8 4 4 3C-1 2 0-4 5-5C10-6 14-8 16-12C18-17 22-24 30-24Z"
HAND_NAIL = "M1-12C1-17 7-17 7-12L6-7C5-4 2-4 1-7Z"


def hand(open_=False):
    """ロゴと同じ、親指と人差し指でつまむ手。open_=True で親指を少し離す。"""
    th = ' transform="translate(2 5) rotate(10 26 -20)"' if open_ else ""
    line = f'stroke="{SKIN_LINE}" stroke-width="2.4" stroke-linejoin="round"'
    return (f'<g><path d="{HAND_BACK}" fill="{SKIN}" {line}/><path d="{HAND_NAIL}" fill="#F5C59D"/>'
            f'<g{th}><path d="{HAND_THUMB}" fill="{SKIN}" {line}/></g></g>')


# ---------- フォント・文字 ----------

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
    import vector
    faces = font_faces()
    return vector.vectorize(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img">'
        f'<title>{title}</title><defs>'
        '<filter id="glow" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="1.6"/></filter>'
        '<linearGradient id="brand" x1="0" y1="0" x2="1" y2="0">'
        '<stop offset="0" stop-color="#A06BFF"/><stop offset=".55" stop-color="#7A7EF0"/>'
        '<stop offset="1" stop-color="#3DB5C8"/></linearGradient>'
        f'<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{t["bg1"]}"/>'
        f'<stop offset="1" stop-color="{t["bg2"]}"/></linearGradient>'
        f'<style>{faces}{FONTS}{MOTION}{extra_css}</style></defs>{body}</svg>')


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size, fill, cls="gh", weight=700, anchor="start", length=None, extra=""):
    if cls in ("rnd", "hand"):
        key = (cls, 400 if cls == "hand" else (800 if weight >= 800 else 700))
        USED.setdefault(key, set()).update(s)
    fit = f' textLength="{length}" lengthAdjust="spacingAndGlyphs"' if length else ""
    return (f'<text x="{x}" y="{y}" class="{cls}" font-size="{size}" font-weight="{weight}" '
            f'fill="{fill}" text-anchor="{anchor}"{fit}{extra}>{esc(s)}</text>')


def dots(x0, y0, cols, rows, gap, r, fill, fade=True):
    out = []
    for j in range(rows):
        for i in range(cols):
            o = 1 - (i + j) / (cols + rows) if fade else 1
            if o > 0.08:
                out.append(f'<circle cx="{x0 + i * gap}" cy="{y0 + j * gap}" r="{r}" fill="{fill}" opacity="{o:.2f}"/>')
    return "".join(out)


def sparkle(cx, cy, r, fill, opacity=1.0, cls=""):
    c = f' class="{cls}"' if cls else ""
    d = f"M{cx} {cy - r}Q{cx + r * .14} {cy - r * .14} {cx + r} {cy}Q{cx + r * .14} {cy + r * .14} {cx} {cy + r}" \
        f"Q{cx - r * .14} {cy + r * .14} {cx - r} {cy}Q{cx - r * .14} {cy - r * .14} {cx} {cy - r}Z"
    return f'<path{c} d="{d}" fill="{fill}" opacity="{opacity}"/>'


def star(cx, cy, r, fill, opacity=1.0):
    pts = []
    for k in range(10):
        rad = r if k % 2 == 0 else r * 0.45
        a = -math.pi / 2 + k * math.pi / 5
        pts.append(f"{cx + rad * math.cos(a):.1f},{cy + rad * math.sin(a):.1f}")
    return f'<polygon points="{" ".join(pts)}" fill="{fill}" opacity="{opacity}"/>'


def four_dots(x, cy, r=4, gap=13):
    return "".join(f'<circle cx="{x + i * gap}" cy="{cy}" r="{r}" fill="{OPS[n]}"/>' for i, n in enumerate(ORDER))


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
    import re
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


def card(x, y, w, h, t, rx=14, stroke=None):
    return (f'<rect x="{x + .75}" y="{y + .75}" width="{w - 1.5}" height="{h - 1.5}" rx="{rx}" fill="none" '
            f'stroke="{stroke or t["line"]}" stroke-width="1.5"/>')


def pill(x, y, label, color, size=13, fg="#FFFFFF", h=24):
    w = tw(label, size) + 20
    return (f'<rect x="{x}" y="{y}" width="{w:.1f}" height="{h}" rx="{h / 2}" fill="{color}"/>'
            + text(x + w / 2, y + h / 2 + size * .36, label, size, fg, weight=700, anchor="middle")), w


def number(x, y, n, size=30, anchor="start"):
    return text(x, y, n, size, "url(#brand)", cls="disp", weight=400, anchor=anchor)


# ---------- 小さな画面（モニター） ----------

def monitor(x, y, w, t, inner="", stand=True):
    """枠だけのモニター。(x, y) は左上、高さは w*0.62。inner は画面の座標（0..w-8 × 0..h-8）で描く。"""
    h = w * .62
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h:.1f}" rx="{w * .05:.1f}" fill="{t["screen"]}" '
           f'stroke="{t["frame"]}" stroke-width="2.2"/>']
    if inner:
        out.append(f'<g transform="translate({x + 4} {y + 4})">{inner}</g>')
    if stand:
        out.append(f'<rect x="{x + w / 2 - 3}" y="{y + h:.1f}" width="6" height="{w * .1:.1f}" fill="{t["stand"]}"/>'
                   f'<rect x="{x + w / 2 - w * .16:.1f}" y="{y + h + w * .1:.1f}" width="{w * .32:.1f}" height="3" rx="1.5" fill="{t["stand"]}"/>')
    return "".join(out)


def phone_icon(x, y, h, t, fill=None, cam=True):
    """立てたスマホ（左上が (x, y)、幅は高さの0.52）。背面カメラの目を描く。"""
    w = h * .52
    f = fill or t["frame"]
    eye_ = (f'<circle cx="{x + w / 2:.1f}" cy="{y + h * .2:.1f}" r="{w * .2:.1f}" fill="{YOU["iris"]}" stroke="{YOU["line"]}" stroke-width="1.6"/>'
            f'<circle cx="{x + w / 2:.1f}" cy="{y + h * .2:.1f}" r="{w * .07:.1f}" fill="{YOU["pupil"]}"/>') if cam else ""
    return (f'<rect x="{x}" y="{y}" width="{w:.1f}" height="{h}" rx="{w * .2:.1f}" fill="{t["panel"]}" stroke="{f}" stroke-width="2"/>'
            + eye_)


def write(files):
    """{相対パス: SVG} を書き出す。XML として読めることを確かめる（壊れた SVG は GitHub で表示されない）。"""
    import xml.etree.ElementTree as ET
    for name, body in files.items():
        ET.fromstring(body)
        path = OUT / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body + "\n", encoding="utf-8", newline="\n")
    return len(files)
