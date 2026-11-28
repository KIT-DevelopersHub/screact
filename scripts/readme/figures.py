"""README の本文の図を生成する。見た目は Screact のチラシとロゴに合わせる（art.py の説明を参照）。

    python scripts/readme/figures.py

| 図 | README の置き場所 |
|:--|:--|
| concept | 「Screactとは」：スマホが見る → PCへ送る → 画面が応える |
| gestures | 「できること」：①〜④の操作と、そのときの手指21点の形 |
| retrofit | 「後付けという選択」：必要なもの・いらないもの |
| scenes | 「利用場面」：会議・授業・接客 |
| evidence | 「直接操作の価値」：先行研究の数値 |
| focus | 「技術」の4つのこだわり |
| journey | 「実績」：予選 → 本戦 → 技育博 → 技育展 |
| footer | 締め |
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import art  # noqa: E402
from art import INK, OPS, PC_W, PHONE_W, VIOLET, YOU, card, para, skeleton, sticker, tab, text, tw  # noqa: E402

RED = "#F0503C"
EASE = "cubic-bezier(.45,0,.55,1)"


class Anim:
    """図の中の小さな動き。秒で書き、1周 dur 秒で繰り返す。"""

    def __init__(self, key, dur):
        self.key, self.dur, self.n, self.css = key, dur, 0, []

    def kf(self, frames, prop="transform", origin=None, ease=EASE):
        self.n += 1
        name = f"{self.key}{self.n}"
        body = "".join(f"{f[0] / self.dur * 100:.2f}%{{{prop}:{f[1]}}}" for f in frames)
        org = f"transform-box:fill-box;transform-origin:{origin};" if origin else ""
        self.css.append(f"@keyframes {name}{{{body}}}.{name}{{animation:{name} {self.dur}s {ease} infinite;{org}}}")
        return name

    def g(self, body, frames, prop="transform", origin=None, ease=EASE):
        return f'<g class="{self.kf(frames, prop, origin, ease)}">{body}</g>'

    def show(self, body, spans):
        fr = [(0, "0")]
        for a, b in spans:
            fr += [(max(a - .01, 0), "0"), (a, "1"), (b - .01, "1"), (b, "0")]
        fr.append((self.dur, "0"))
        return self.g(body, sorted(fr, key=lambda f: f[0]), "opacity", ease="steps(1,end)")


def finish(W, H, b, t, alt, css="", top=12, bottom=24):
    return art.svg(W, H + top + bottom, f'<g transform="translate(0 {top})">{"".join(b)}</g>', t, alt, css)


def chevron(x, y, down=False, color=VIOLET):
    r = 90 if down else 0
    return (f'<g transform="translate({x:.1f} {y:.1f}) rotate({r})"><path d="M-6 -11L6 0L-6 11" fill="none" stroke="{INK}" '
            f'stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/><path d="M-6 -11L6 0L-6 11" fill="none" '
            f'stroke="{color}" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/></g>')


def laptop(x, y, w, t):
    h = w * .6
    return (f'<rect x="{x:.1f}" y="{y:.1f}" width="{w}" height="{h:.1f}" rx="5" fill="{t["screen"]}" stroke="{t["frame"]}" stroke-width="2.4"/>'
            f'<path d="M{x - w * .12:.1f} {y + h + 3:.1f}H{x + w * 1.12:.1f}l-5 7H{x - w * .12 + 5:.1f}Z" fill="{t["stand"]}"/>')


def waves(x, y, color, s=1.0, flip=False):
    sg = -1 if flip else 1
    return "".join(f'<path d="M{x + sg * (6 + k * 7) * s:.1f} {y - (7 + k * 6) * s:.1f}a{(10 + k * 8) * s:.1f} {(10 + k * 8) * s:.1f} 0 0 {1 if not flip else 0} 0 {(14 + k * 12) * s:.1f}" '
                   f'fill="none" stroke="{color}" stroke-width="3" stroke-linecap="round"/>' for k in range(3))


# ---------- Screactとは ----------
CONCEPT = [("1 スマホが見る", "画面の横に置いたスマホのカメラが、手指の21点と画面の四隅を、端末の中で認識します。"),
           ("2 PCへ送る", "カメラの映像ではなく、座標と状態だけを、同じLANのPCへリアルタイムに送ります。"),
           ("3 画面が応える", "PCが座標を画面に合わせ、手の形を操作に変えて、いつものアプリを動かします。")]
CONCEPT_ALT = "Screactの仕組み。" + "。".join(f"{a[2:]}：{b}" for a, b in CONCEPT)


def concept(t, narrow=False):
    an = Anim("cc", 6.0)
    W = PHONE_W if narrow else PC_W
    gap = 30
    colw = W if narrow else (W - 2 * gap) / 3
    ill_h = 128
    b = []

    def ill(k, x, y, w):
        cx = x + w / 2
        if k == 0:  # スマホと、その前で動く手の骨格
            hand_ = an.g(skeleton("point", 0, 0, .95, OPS["draw"], t, mark=(8,)),
                         [(0, f"translate({cx - 44:.1f}px,{y + 118:.1f}px)"), (3, f"translate({cx - 24:.1f}px,{y + 108:.1f}px)"),
                          (6, f"translate({cx - 44:.1f}px,{y + 118:.1f}px)")])
            ph = art.phone(cx + 34, y + 30, 72, t)
            beam = f'<path d="M{cx + 50:.1f} {y + 50:.1f}L{cx - 34:.1f} {y + 18:.1f}M{cx + 50:.1f} {y + 50:.1f}L{cx - 40:.1f} {y + 114:.1f}" stroke="{YOU["iris"]}" stroke-width="2.4" stroke-dasharray="4 5"/>'
            return beam + hand_ + ph
        if k == 1:  # スマホ → ノートPC。座標の点が流れる
            out = [art.phone(x + 20, y + 40, 60, t), laptop(x + w - 96, y + 56, 78, t), waves(x + 58, y + 64, OPS["scroll"], .8)]
            for i in range(3):
                d = i * .9
                out.append(an.g(f'<circle r="5" fill="{VIOLET}" stroke="{INK}" stroke-width="2"/>',
                                [(0, f"translate({x + 66:.1f}px,{y + 76:.1f}px) scale(0)"), (d, f"translate({x + 66:.1f}px,{y + 76:.1f}px) scale(0)"),
                                 (d + .1, f"translate({x + 66:.1f}px,{y + 76:.1f}px) scale(1)"), (d + 2.2, f"translate({x + w - 66:.1f}px,{y + 76:.1f}px) scale(1)"),
                                 (d + 2.3, f"translate({x + w - 66:.1f}px,{y + 76:.1f}px) scale(0)"), (6, f"translate({x + w - 66:.1f}px,{y + 76:.1f}px) scale(0)")],
                                ease="linear"))
            out.append(text(cx, y + ill_h - 4, "x, y, 手の形", 13, t["muted"], weight=700, anchor="middle"))
            return "".join(out)
        # モニター：カーソルが動き、線が描かれる
        mw = min(w - 24, 170)
        mx, my = cx - mw / 2, y + 8
        L = 150
        line = (f'<path d="M{mx + 22:.1f} {my + 70:.1f}c18-34 38-34 50-6s30 28 52 -8" fill="none" stroke="{OPS["draw"]}" stroke-width="4" '
                f'stroke-linecap="round" stroke-dasharray="{L} {L}"/>')
        out = [art.monitor(mx, my, mw, t), an.g(line, [(0, str(L)), (.8, str(L)), (3.2, "0"), (5.2, "0"), (6, str(L))], prop="stroke-dashoffset")]
        cur = f'<path d="M0 0l0 16 4-4 3 7 3-1-3-7 6 0z" fill="{t["card"]}" stroke="{INK}" stroke-width="1.6" stroke-linejoin="round"/>'
        out.append(an.g(cur, [(0, f"translate({mx + 22:.1f}px,{my + 70:.1f}px)"), (.8, f"translate({mx + 22:.1f}px,{my + 70:.1f}px)"),
                              (2.0, f"translate({mx + 72:.1f}px,{my + 62:.1f}px)"), (3.2, f"translate({mx + 124:.1f}px,{my + 56:.1f}px)"),
                              (5.2, f"translate({mx + 124:.1f}px,{my + 56:.1f}px)"), (6, f"translate({mx + 22:.1f}px,{my + 70:.1f}px)")]))
        return "".join(out)

    y = 0
    for k, (label, body) in enumerate(CONCEPT):
        x = 0 if narrow else k * (colw + gap)
        s2, n2 = para(x + 18, 20 + ill_h + 30, body, 14, t["ink"], colw - 36, 22, 600)
        h = 20 + ill_h + 30 + (n2 - 1) * 22 + 22
        top = y if narrow else 0
        b += [card(x, top + 16, colw, h, t, VIOLET), ill(k, x, top + 34, colw),
              tab(x + colw / 2, top + 16, label, VIOLET, 16)[0],
              f'<g transform="translate(0 {top + 16})">{s2}</g>']
        if narrow:
            y += h + 16 + 30
            if k < 2:
                b.append(chevron(W / 2, y - 22, down=True))
        else:
            if k < 2:
                b.append(chevron(x + colw + gap / 2, 16 + h / 2))
            Hc = h + 16
    H = y - 30 if narrow else Hc
    return finish(W, H, b, t, CONCEPT_ALT, "".join(an.css))


# ---------- できること ----------
GESTURES = [("draw", "① 描く・消す", [("two", "人差し指と中指をくっつけて動かすと描ける"), ("fist", "手をグーにして動かすと消せる")]),
            ("click", "② クリック", [("pinch", "親指と人差し指をつまむと、その場所をクリック")]),
            ("drag", "③ ドラッグ", [("pinch", "つまんだまま動かすと、つかんで運べる")]),
            ("scroll", "④ スクロール", [("thumbsup", "グッドサインで、親指を向けた方へスクロール")])]
GESTURES_ALT = "できること。" + "。".join(f"{label[2:]}：" + "、".join(h for _, h in hows) for _, label, hows in GESTURES)


def gesture_screen(op, an, x, y, w, t):
    """操作の結果をモニターの中で見せる。"""
    h = w * .62
    c = OPS[op]
    inner = []
    if op == "draw":
        L = 160
        inner.append(an.g(f'<path d="M{w * .15:.1f} {h * .62:.1f}c{w * .12:.1f}-{h * .5:.1f} {w * .26:.1f}-{h * .5:.1f} {w * .34:.1f}-{h * .1:.1f}s{w * .2:.1f} {h * .45:.1f} {w * .36:.1f}-{h * .12:.1f}" '
                          f'fill="none" stroke="{c}" stroke-width="4" stroke-linecap="round" stroke-dasharray="{L} {L}"/>',
                          [(0, str(L)), (.3, str(L)), (2.6, "0"), (3.4, "0"), (5.2, str(-L)), (6, str(-L))], prop="stroke-dashoffset"))
    elif op == "click":
        s = w * .2
        ic = (f'<rect x="{w / 2 - s / 2:.1f}" y="{h / 2 - s / 2:.1f}" width="{s:.1f}" height="{s:.1f}" rx="{s * .25:.1f}" fill="#AEC8D0"/>'
              + art.youray(w / 2, h / 2 + s * .32, s / 150, animate=False))
        inner.append(an.g(ic, [(0, "scale(1)"), (2.4, "scale(1)"), (2.6, "scale(.86)"), (2.9, "scale(1)"), (6, "scale(1)")], origin="50% 50%"))
        inner.append(an.g(f'<circle cx="{w / 2:.1f}" cy="{h / 2:.1f}" r="{s * .7:.1f}" fill="none" stroke="{c}" stroke-width="3"/>',
                          [(0, "scale(0)"), (2.5, "scale(0)"), (2.6, "scale(.6)"), (3.4, "scale(1.4)"), (3.41, "scale(0)"), (6, "scale(0)")],
                          origin="50% 50%"))
    elif op == "drag":
        note = (f'<rect x="0" y="0" width="{w * .26:.1f}" height="{w * .2:.1f}" rx="3" fill="#FFE27A" stroke="{INK}" stroke-width="1.6"/>'
                f'<path d="M{w * .04:.1f} {w * .07:.1f}h{w * .17:.1f}M{w * .04:.1f} {w * .12:.1f}h{w * .12:.1f}" stroke="{INK}" stroke-width="1.6" opacity=".55"/>')
        inner.append(an.g(note, [(0, f"translate({w * .12:.1f}px,{h * .25:.1f}px)"), (1.6, f"translate({w * .12:.1f}px,{h * .25:.1f}px)"),
                                 (3.8, f"translate({w * .6:.1f}px,{h * .45:.1f}px)"), (5.0, f"translate({w * .6:.1f}px,{h * .45:.1f}px)"),
                                 (6, f"translate({w * .12:.1f}px,{h * .25:.1f}px)")]))
    else:
        rows = "".join(f'<rect x="{w * .14:.1f}" y="{h * .14 + k * 12:.1f}" width="{w * (.66 - (k % 3) * .14):.1f}" height="6" rx="3" fill="{t["line"]}"/>' for k in range(10))
        inner.append(f'<clipPath id="sc{an.key}"><rect x="4" y="4" width="{w - 8:.1f}" height="{h - 8:.1f}" rx="4"/></clipPath>'
                     f'<g clip-path="url(#sc{an.key})">' + an.g(rows, [(0, "translate(0px,0px)"), (1.4, "translate(0px,0px)"),
                                                                    (4.2, "translate(0px,-48px)"), (5.4, "translate(0px,-48px)"), (6, "translate(0px,0px)")]) + "</g>")
        inner.append(f'<rect x="{w - 12:.1f}" y="8" width="4" height="{h - 16:.1f}" rx="2" fill="{t["line"]}"/>')
        inner.append(an.g(f'<rect x="{w - 12:.1f}" y="8" width="4" height="{h * .35:.1f}" rx="2" fill="{c}"/>',
                          [(0, "translate(0px,0px)"), (1.4, "translate(0px,0px)"), (4.2, f"translate(0px,{h * .45:.1f}px)"),
                           (5.4, f"translate(0px,{h * .45:.1f}px)"), (6, "translate(0px,0px)")]))
    return art.monitor(x, y, w, t, "".join(inner))


def gesture_hand(op, an, x, y, s, t):
    """操作のときの手指21点。描く・消すは2つの形を入れ替え、ドラッグとスクロールは画面の動きと同じ向きに動かす。"""
    c = OPS[op]
    if op == "draw":
        return (an.show(skeleton("two", x, y, s, c, t, mark=(8, 12)), [(0, 3.4)])
                + an.show(skeleton("fist", x, y, s, c, t), [(3.4, 6.0)]))
    if op == "click":
        return (an.show(skeleton("point", x, y, s, c, t), [(0, 2.3), (3.4, 6.0)])
                + an.show(skeleton("pinch", x, y, s, c, t, mark=(4, 8)), [(2.3, 3.4)]))
    if op == "drag":
        body = skeleton("pinch", 0, 0, s, c, t, mark=(4, 8))
        return an.g(body, [(0, f"translate({x:.1f}px,{y:.1f}px)"), (1.6, f"translate({x:.1f}px,{y:.1f}px)"),
                           (3.8, f"translate({x + 22:.1f}px,{y + 6:.1f}px)"), (5.0, f"translate({x + 22:.1f}px,{y + 6:.1f}px)"),
                           (6, f"translate({x:.1f}px,{y:.1f}px)")])
    body = skeleton("thumbsup", 0, 0, s, c, t, mark=(4,))
    return an.g(body, [(0, f"translate({x:.1f}px,{y:.1f}px)"), (1.4, f"translate({x:.1f}px,{y:.1f}px)"),
                       (4.2, f"translate({x:.1f}px,{y - 14:.1f}px)"), (5.4, f"translate({x:.1f}px,{y - 14:.1f}px)"),
                       (6, f"translate({x:.1f}px,{y:.1f}px)")])


def gestures(t, narrow=False):
    W = PHONE_W if narrow else PC_W
    gap = 18
    cols = 1 if narrow else 2
    colw = (W - gap * (cols - 1)) / cols
    css, b, rows_h = [], [], []
    cells = []
    for k, (op, label, hows) in enumerate(GESTURES):
        an = Anim(f"g{k}", 6.0)
        pad = 18
        mw = 150 if not narrow else 160
        ill_h = mw * .62 + mw * .09 + 6
        txt_y = 26 + ill_h + 26
        parts, n = [], 0
        for kind, how in hows:
            s1, k1 = para(pad, txt_y + n * 22, how, 14, t["ink"], colw - 2 * pad, 22, 700)
            parts.append(s1)
            n += k1
        h = txt_y + (n - 1) * 22 + 22
        body = [card(0, 0, colw, h, t, OPS[op]),
                gesture_screen(op, an, pad + 4, 30, mw, t),
                gesture_hand(op, an, pad + mw + (colw - pad - mw) / 2 + 2, 30 + ill_h - 6, .95, t),
                tab(colw / 2, 0, label, OPS[op], 16)[0]] + parts
        cells.append((body, h))
        css += an.css
    y = 18
    for r in range(0, len(cells), cols):
        row = cells[r:r + cols]
        h = max(hh for _, hh in row)
        for k, (body, _) in enumerate(row):
            x = k * (colw + gap)
            b.append(f'<g transform="translate({x:.1f} {y})">{"".join(body)}</g>')
        y += h + 34
    return finish(W, y - 34, b, t, GESTURES_ALT, "".join(css))


# ---------- 後付けという選択 ----------
NEED = [("phone", "スマホ"), ("pc", "PC"), ("monitor", "今ある画面")]
NOPE = [("ir", "赤外線カメラ"), ("sensor", "センサー類"), ("pen", "電子ペン")]
RETRO_ALT = "後付けという選択。必要なのは、手元のスマホとPCと今ある画面だけ。赤外線カメラ、センサー類、電子ペンなどの専用機器はいらず、タッチ対応の画面へ買い替える必要もない"


def thing(kind, cx, cy, t):
    if kind == "phone":
        return art.phone(cx - 18, cy - 36, 72, t)
    if kind == "pc":
        return laptop(cx - 36, cy - 22, 72, t)
    if kind == "monitor":
        return art.monitor(cx - 44, cy - 34, 88, t)
    if kind == "ir":
        return (f'<rect x="{cx - 30}" y="{cy - 18}" width="44" height="30" rx="6" fill="{t["card"]}" stroke="{t["frame"]}" stroke-width="2.4"/>'
                f'<circle cx="{cx - 8}" cy="{cy - 3}" r="9" fill="{t["screen"]}" stroke="{t["frame"]}" stroke-width="2.4"/>'
                f'<path d="M{cx + 14} {cy - 8}l16-8v26l-16-8z" fill="{t["card"]}" stroke="{t["frame"]}" stroke-width="2.4" stroke-linejoin="round"/>')
    if kind == "sensor":
        return (f'<path d="M{cx - 22} {cy + 12}a22 22 0 0 1 44 0z" fill="{t["card"]}" stroke="{t["frame"]}" stroke-width="2.4"/>'
                + "".join(f'<path d="M{cx - 10 - k * 8} {cy - 14 - k * 6}a{14 + k * 9} {14 + k * 9} 0 0 1 {20 + k * 16} 0" fill="none" stroke="{t["frame"]}" stroke-width="2.4" stroke-linecap="round"/>' for k in range(2)))
    return (f'<path d="M{cx - 24} {cy + 20}l6-16 32-32 10 10-32 32z" fill="{t["card"]}" stroke="{t["frame"]}" stroke-width="2.4" stroke-linejoin="round"/>'
            f'<path d="M{cx - 24} {cy + 20}l4-12 8 8z" fill="{t["frame"]}"/>')


def cross(cx, cy, r=26):
    return (f'<path d="M{cx - r} {cy - r}L{cx + r} {cy + r}M{cx + r} {cy - r}L{cx - r} {cy + r}" stroke="{RED}" stroke-width="7" '
            f'stroke-linecap="round" opacity=".92"/>')


def retrofit(t, narrow=False):
    W = PHONE_W if narrow else PC_W
    gap = 20
    colw = W if narrow else (W - gap) / 2
    b = []

    def panel(x, y, title, items, ok):
        h = 196
        out = [card(x, y, colw, h, t, VIOLET if ok else RED, rx=20), sticker(x + colw / 2, y + 50, title, 24, anchor="middle")]
        step = colw / len(items)
        for k, (kind, label) in enumerate(items):
            cx = x + step * (k + .5)
            out.append(thing(kind, cx, y + 110, t))
            if not ok:
                out.append(cross(cx, y + 108))
            elif k < len(items) - 1:
                out.append(text(x + step * (k + 1), y + 116, "+", 26, t["muted"], cls="rnd", weight=800, anchor="middle"))
            out.append(text(cx, y + 176, label, 14, t["ink"], weight=700, anchor="middle"))
        return "".join(out), h

    p1, h1 = panel(0, 0, "必要なのはこれだけ！", NEED, True)
    p2, h2 = panel(0 if narrow else colw + gap, h1 + gap if narrow else 0, "専用機器は一切不要！", NOPE, False)
    b += [p1, p2]
    H = h1 + gap + h2 if narrow else max(h1, h2)
    return finish(W, H, b, t, RETRO_ALT)


# ---------- 利用場面 ----------
SCENES = [("会議・共同作業", "情報を動かしながら、\n一緒に考える。", "注目している箇所や意図をその場で共有でき、対話や共同作業に加わりやすくなります。"),
          ("授業・プレゼン", "説明・身振り・操作が\nひとつになる。", "説明する人は伝えることに集中でき、聞く人も注目する場所をつかみやすくなります。"),
          ("接客・相談・提案", "同じ情報を指しながら\n対話する。", "相手の反応や質問に合わせて、その場で書き込みながら説明できます。")]
SCENES_ALT = "利用場面。" + "。".join(f"{a}：{b}{c}" for a, b, c in SCENES)


def person(cx, by, color, t, s=1.0):
    return (f'<circle cx="{cx:.1f}" cy="{by - 40 * s:.1f}" r="{9 * s:.1f}" fill="{t["card"]}" stroke="{INK}" stroke-width="2.2"/>'
            f'<path d="M{cx - 15 * s:.1f} {by:.1f}c0-16 6-24 {15 * s:.1f}-24s{15 * s:.1f} 8 {15 * s:.1f} 24z" fill="{color}" stroke="{INK}" stroke-width="2.2" stroke-linejoin="round"/>')


def scene_ill(k, an, x, y, w, t):
    cx = x + w / 2
    mw = 120
    mx, my = cx - mw / 2, y + 6
    inner, out = [], []
    if k == 0:  # 付箋を動かしながら議論する
        for i, (nx, ny, col) in enumerate([(14, 12, "#FFE27A"), (46, 30, "#B9F0E3"), (80, 14, "#F7C6DA")]):
            note = f'<rect width="24" height="18" rx="2" fill="{col}" stroke="{INK}" stroke-width="1.4"/>'
            if i == 1:
                inner.append(an.g(note, [(0, f"translate({nx}px,{ny}px)"), (1.5, f"translate({nx}px,{ny}px)"), (3.5, f"translate({nx + 30}px,{ny + 14}px)"),
                                         (5.5, f"translate({nx + 30}px,{ny + 14}px)"), (7, f"translate({nx}px,{ny}px)")]))
            else:
                inner.append(f'<g transform="translate({nx} {ny})">{note}</g>')
        out += [person(cx - 66, y + 118, OPS["click"], t, .9), person(cx + 66, y + 118, OPS["drag"], t, .9)]
    elif k == 1:  # グラフを丸で囲んで説明する
        inner.append(f'<path d="M14 58L40 40L62 48L96 18" fill="none" stroke="{t["frame"]}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>')
        L = 120
        inner.append(an.g(f'<ellipse cx="94" cy="22" rx="14" ry="11" fill="none" stroke="{OPS["scroll"]}" stroke-width="3" stroke-dasharray="{L} {L}"/>',
                          [(0, str(L)), (1.5, str(L)), (3.0, "0"), (5.5, "0"), (7, str(L))], prop="stroke-dashoffset"))
        out += [person(cx - 70, y + 118, OPS["draw"], t, 1.0)]
    else:  # 同じ画面を見ながら、チェックを書き込む
        for i in range(3):
            inner.append(f'<rect x="16" y="{14 + i * 16}" width="10" height="10" rx="2" fill="none" stroke="{t["frame"]}" stroke-width="2"/>'
                         f'<rect x="32" y="{17 + i * 16}" width="{60 - i * 10}" height="5" rx="2.5" fill="{t["line"]}"/>')
        L = 30
        inner.append(an.g(f'<path d="M15 33l5 5 9-10" fill="none" stroke="{OPS["drag"]}" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round" stroke-dasharray="{L} {L}"/>',
                          [(0, str(L)), (2, str(L)), (2.8, "0"), (6, "0"), (7, str(L))], prop="stroke-dashoffset"))
        out += [person(cx - 70, y + 118, OPS["click"], t, .9), person(cx + 70, y + 118, OPS["scroll"], t, .9)]
    out.insert(0, art.monitor(mx, my, mw, t, "".join(inner)))
    out.append(art.youray(cx + mw / 2 - 16, my + 3, .2, delay=k * .4))
    return "".join(out)


def scenes(t, narrow=False):
    an = Anim("sn", 7.0)
    W = PHONE_W if narrow else PC_W
    gap = 16
    colw = W if narrow else (W - 2 * gap) / 3
    pad = 16
    cells = []
    for k, (title, lead, body) in enumerate(SCENES):
        s1, n1 = para(pad, 166, lead, 15, t["ink"], colw - 2 * pad, 22, 800)
        s2, n2 = para(pad, 166 + n1 * 22 + 8, body, 14, t["muted"], colw - 2 * pad, 21, 600)
        cells.append((title, s1, s2, 166 + n1 * 22 + 8 + (n2 - 1) * 21 + 22))
    b = []
    y = 18
    hmax = max(c[3] for c in cells)
    for k, (title, s1, s2, h) in enumerate(cells):
        x = 0 if narrow else k * (colw + gap)
        yy = y if narrow else 18
        hh = h if narrow else hmax
        b.append(f'<g transform="translate({x:.1f} {yy})">{card(0, 0, colw, hh, t, VIOLET)}{scene_ill(k, an, 0, 26, colw, t)}'
                 f'{tab(colw / 2, 0, title, VIOLET, 16)[0]}{s1}{s2}</g>')
        if narrow:
            y += h + 36
    H = y - 36 if narrow else 18 + hmax
    return finish(W, H, b, t, SCENES_ALT, "".join(an.css))


# ---------- 直接操作の価値 ----------
EVIDENCE = [("35%", "短い", "高齢者の操作時間が、\nマウスより約35%短い", "タッチスクリーンとマウスの比較 [1]"),
            ("16%", "短い", "若年者の操作時間が、\nマウスより約16%短い", "タッチスクリーンとマウスの比較 [1]"),
            ("両手", "", "両手を使う作業では、\n直接タッチが有利", "テーブル型ディスプレイでの比較 [2]")]
EVIDENCE_ALT = ("直接操作の価値（先行研究）。" + "。".join(f"{q.replace(chr(10), '')}（{src}）" for _, _, q, src in EVIDENCE)
                + "。これらは先行研究の結果であり、Screact自体で測った効果ではない")


def evidence(t, narrow=False):
    W = PHONE_W if narrow else PC_W
    gap = 16
    colw = W if narrow else (W - 2 * gap) / 3
    pad = 18
    b, y = [], 0
    for k, (num, word, q, src) in enumerate(EVIDENCE):
        x = 0 if narrow else k * (colw + gap)
        yy = y if narrow else 0
        s1, n1 = para(pad, 108, q, 15, t["ink"], colw - 2 * pad, 22, 700)
        h = 108 + n1 * 22 + 34
        num_ = sticker(pad + 2, 74, num, 50)
        b.append(f'<g transform="translate({x:.1f} {yy})">{card(0, 0, colw, h, t, VIOLET)}{num_}{s1}'
                 + text(pad, h - 18, src, 13, t["muted"], weight=600) + "</g>")
        if narrow:
            y += h + 14
    H = y - 14 if narrow else h
    return finish(W, H, b, t, EVIDENCE_ALT)


# ---------- 4つのこだわり ----------
FOCUS = [("1 導入の手軽さ", "ユーザー操作は最小限", "PCがUDPで居場所を知らせ、スマホが見つけて自動で接続します。位置合わせも、画面の四隅のマーカーを読むだけで終わります。"),
         ("2 設置の自由度", "スマホは斜めからでもOK", "4つのマーカーからホモグラフィ（射影変換）を求め、斜めから見た座標を画面の座標へ補正します。"),
         ("3 操作性", "直感的なジェスチャーと滑らかさ", "止めていても揺れる指先を One-Euro Filter で落ち着かせ、動き出しの速さは保ちます。"),
         ("4 汎用性", "実カーソル入力で、どのアプリでも", "OSの実際の入力としてクリックやスクロールを送り、描画はクリック透過のオーバーレイに重ねます。")]
FOCUS_ALT = "4つのこだわり。" + "。".join(f"{a[2:]}（{b}）：{c}" for a, b, c in FOCUS)


def focus_ill(k, an, x, y, w, t):
    cx = x + w / 2
    if k == 0:
        out = [art.phone(cx - 80, y + 6, 66, t), laptop(cx + 30, y + 22, 72, t), waves(cx - 40, y + 40, OPS["scroll"], .8),
               waves(cx + 22, y + 40, OPS["scroll"], .8, flip=True)]
        chk = (f'<circle cx="{cx:.1f}" cy="{y + 40}" r="14" fill="{OPS["drag"]}" stroke="{INK}" stroke-width="2.4"/>'
               f'<path d="M{cx - 6:.1f} {y + 40}l4 5 8-9" fill="none" stroke="#FFFFFF" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>')
        out.append(an.g(chk, [(0, "scale(0)"), (1.2, "scale(0)"), (1.6, "scale(1.15)"), (1.8, "scale(1)"), (5.4, "scale(1)"), (6, "scale(0)")], origin="50% 50%"))
        return "".join(out)
    if k == 1:
        mw = 110
        mx, my = cx - 70, y + 4
        h = mw * .62
        marks = "".join(f'<rect x="{px:.1f}" y="{py:.1f}" width="11" height="11" fill="{t["frame"]}"/>'
                        for px, py in [(5, 5), (mw - 16, 5), (mw - 16, h - 16), (5, h - 16)])
        out = [art.monitor(mx, my, mw, t, marks), art.phone(cx + 52, y + 14, 56, t, tilt=-22)]
        quad = an.show(f'<rect x="{mx + 3:.1f}" y="{my + 3:.1f}" width="{mw - 6}" height="{h - 6:.1f}" rx="4" fill="none" stroke="{VIOLET}" stroke-width="3"/>', [(1.5, 5.6)])
        rays = f'<path d="M{cx + 60:.1f} {y + 34}L{mx + mw - 4:.1f} {my + 8}M{cx + 60:.1f} {y + 34}L{mx + mw - 4:.1f} {my + h - 8:.1f}" stroke="{YOU["iris"]}" stroke-width="2.2" stroke-dasharray="4 5"/>'
        return "".join(out) + rays + quad
    if k == 2:
        jit = "M" + "L".join(f"{cx - 90 + i * 6:.1f} {y + 34 + (5 if i % 2 else -5) * (1 if i % 3 else .4):.1f}" for i in range(31))
        smooth_ = f"M{cx - 90:.1f} {y + 56}C{cx - 40:.1f} {y + 40} {cx + 20:.1f} {y + 72} {cx + 90:.1f} {y + 54}"
        return (f'<path d="{jit}" fill="none" stroke="{t["muted"]}" stroke-width="2" opacity=".55" transform="translate(0 -10)"/>'
                f'<path d="{smooth_}" fill="none" stroke="{VIOLET}" stroke-width="4" stroke-linecap="round"/>'
                + an.g(f'<circle r="6" fill="{OPS["draw"]}" stroke="{INK}" stroke-width="2"/>',
                       [(0, f"translate({cx - 90:.1f}px,{y + 56}px)"), (3, f"translate({cx:.1f}px,{y + 56}px)"),
                        (5.4, f"translate({cx + 90:.1f}px,{y + 54}px)"), (6, f"translate({cx - 90:.1f}px,{y + 56}px)")]))
    wins = []
    for i, (wx, wy, col) in enumerate([(-92, 6, OPS["click"]), (-30, 18, OPS["drag"]), (32, 8, OPS["scroll"])]):
        wins.append(f'<rect x="{cx + wx:.1f}" y="{y + wy}" width="64" height="48" rx="5" fill="{t["card"]}" stroke="{t["frame"]}" stroke-width="2.2"/>'
                    f'<rect x="{cx + wx:.1f}" y="{y + wy}" width="64" height="11" rx="5" fill="{col}"/>')
    cur = f'<path d="M0 0l0 18 5-5 4 8 3-1-4-8 7 0z" fill="{t["card"]}" stroke="{INK}" stroke-width="1.8" stroke-linejoin="round"/>'
    wins.append(an.g(cur, [(0, f"translate({cx - 70:.1f}px,{y + 34}px)"), (2, f"translate({cx - 4:.1f}px,{y + 44}px)"),
                           (4, f"translate({cx + 60:.1f}px,{y + 32}px)"), (6, f"translate({cx - 70:.1f}px,{y + 34}px)")]))
    return "".join(wins)


def focus(t, narrow=False):
    an = Anim("fc", 6.0)
    W = PHONE_W if narrow else PC_W
    gap = 18
    cols = 1 if narrow else 2
    colw = (W - gap * (cols - 1)) / cols
    pad = 18
    cells = []
    for k, (title, lead, body) in enumerate(FOCUS):
        s0 = text(pad, 128, lead, 15, VIOLET if t["page"] == "#FFFFFF" else "#A79BFF", weight=800)
        s2, n2 = para(pad, 152, body, 14, t["ink"], colw - 2 * pad, 22, 600)
        cells.append((title, s0 + s2, 152 + (n2 - 1) * 22 + 22))
    b, y = [], 18
    for r in range(0, 4, cols):
        row = cells[r:r + cols]
        h = max(c[2] for c in row)
        for i, (title, body, _) in enumerate(row):
            k = r + i
            x = i * (colw + gap)
            b.append(f'<g transform="translate({x:.1f} {y})">{card(0, 0, colw, h, t, VIOLET)}{focus_ill(k, an, 0, 22, colw, t)}'
                     f'{tab(colw / 2, 0, title, VIOLET, 16)[0]}{body}</g>')
        y += h + 34
    return finish(W, y - 34, b, t, FOCUS_ALT, "".join(an.css))


# ---------- 実績 ----------
JOURNEY = [("2026.08.09", "THE HACK 2026", "オンライン予選", "第1位で通過"),
           ("2026.08.22", "THE HACK 2026", "本戦（大阪）", "大賞"),
           ("2026.09.19", "技育博 2026", "展示", "実機で体験展示"),
           ("2026.11.28", "技育展 2026", "決勝", "決勝で発表")]
JOURNEY_ALT = ("実績。" + "。".join(f"{d}：{ev} {st}・{res}" for d, ev, st, res in JOURNEY) + "。THE HACK 2026 本戦の大賞は最高賞（賞金30万円）")


def journey(t, narrow=False):
    DUR = 12.0
    an = Anim("jr", DUR)
    W = PHONE_W if narrow else PC_W
    stops = [.8, 3.4, 6.0, 8.6]
    b = []
    if narrow:
        x0, y0, gy = 52, 40, 96
        pts = [(x0, y0 + k * gy) for k in range(4)]
        H = pts[-1][1] + 50
        road = f"M{x0} {y0}V{pts[-1][1]}"
    else:
        y0 = 120
        pts = [(90 + k * (W - 180) / 3, y0) for k in range(4)]
        H = 240
        road = f"M{pts[0][0]} {y0}H{pts[-1][0]}"
    b.append(art.blobs(t, [(W * .12, H * .3, 70, "aqua"), (W * .86, H * .7, 80, "mint"), (W * .5, H * .1, 60, "lav")]) if not narrow else
             art.blobs(t, [(W * .85, H * .2, 60, "aqua"), (W * .2, H * .8, 70, "mint")]))
    b.append(f'<path d="{road}" stroke="{INK}" stroke-width="12" stroke-linecap="round"/><path d="{road}" stroke="{art.LAV}" stroke-width="6" stroke-linecap="round"/>')
    for k, ((d, ev, st, res), (x, y)) in enumerate(zip(JOURNEY, pts)):
        big = k == 1
        r = 17 if big else 12
        col = "#F5B400" if big else VIOLET
        lit = an.show(f'<circle cx="{x}" cy="{y}" r="{r - 5}" fill="{col}"/>', [(stops[k], DUR - .4)])
        b.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{t["card"]}" stroke="{INK}" stroke-width="4"/>' + lit)
        if narrow:
            tx = x0 + 44
            b += [text(tx, y - 16, d, 13, t["muted"], weight=700), text(tx, y + 6, ev, 16, t["ink"], weight=800),
                  text(tx, y + 27, f"{st}・{res}", 14, "#D99A00" if big else t["muted"], weight=800 if big else 600)]
        else:
            b += [text(x, y - 76, d, 13, t["muted"], weight=700, anchor="middle"),
                  text(x, y - 54, ev, 15, t["ink"], weight=800, anchor="middle"),
                  text(x, y + 46, st, 14, t["muted"], weight=600, anchor="middle")]
            b.append(sticker(x, y + 84, res, 26, anchor="middle", fill="#FFE27A") if big else text(x, y + 76, res, 16, t["ink"], weight=800, anchor="middle"))
    # YouRay が駅を跳んで進む
    fr = []
    for k, (x, y) in enumerate(pts):
        gx, gy = (x, y - 18) if not narrow else (x - 28, y + 10)
        if k:
            px, py = (pts[k - 1][0], pts[k - 1][1] - 18) if not narrow else (pts[k - 1][0] - 28, pts[k - 1][1] + 10)
            fr += [(stops[k] - 1.4, f"translate({px:.1f}px,{py:.1f}px)"),
                   (stops[k] - .7, f"translate({(px + gx) / 2:.1f}px,{(py + gy) / 2 - (24 if not narrow else 0):.1f}px)")]
        fr.append((stops[k], f"translate({gx:.1f}px,{gy:.1f}px)"))
    first = (pts[0][0], pts[0][1] - 18) if not narrow else (pts[0][0] - 28, pts[0][1] + 10)
    fr = [(0, f"translate({first[0]:.1f}px,{first[1]:.1f}px)")] + fr + [(DUR - .6, fr[-1][1]), (DUR - .3, f"translate({first[0]:.1f}px,{first[1]:.1f}px)"), (DUR, f"translate({first[0]:.1f}px,{first[1]:.1f}px)")]
    b.append(an.g(f'<g transform="scale(.3)">{art.ghost()}</g>', fr))
    return finish(W, H, b, t, JOURNEY_ALT, "".join(an.css), top=4, bottom=8)


# ---------- 締め ----------

def footer(t, narrow=False):
    W, H = (PHONE_W, 236) if narrow else (PC_W, 214)
    cx = W / 2
    b = [f'<clipPath id="ft"><rect width="{W}" height="{H}" rx="24"/></clipPath><g clip-path="url(#ft)">',
         f'<rect width="{W}" height="{H}" fill="{t["page"]}"/>',
         art.blobs(t, [(W * .1, H * .2, 90, "aqua"), (W * .9, H * .85, 110, "mint"), (W * .55, H * 1.05, 90, "lav"), (W * .78, H * .05, 60, "lav")]),
         "</g>", f'<rect x="1.5" y="1.5" width="{W - 3}" height="{H - 3}" rx="24" fill="none" stroke="{INK}" stroke-width="3"/>']
    if narrow:
        b += [sticker(cx, 62, "描いて、", 34, anchor="middle"), sticker(cx, 108, "動かせる画面へ。", 34, anchor="middle"),
              text(cx, 146, "普通の Screen が、人の動きに React する。", 13, t["ink"], cls="rnd", weight=800, anchor="middle")]
        gy, s = 214, .42
    else:
        b += [sticker(cx, 78, "描いて、動かせる画面へ。", 44, anchor="middle"),
              text(cx, 122, "普通の Screen が、人の動きに React する。", 17, t["ink"], cls="rnd", weight=800, anchor="middle")]
        gy, s = 196, .52
    b.append(art.youray(cx, gy, s, delay=.3))
    return art.svg(W, H, "".join(b), t, "描いて、動かせる画面へ。普通の Screen が、人の動きに React する。")


FIGS = {"concept": concept, "gestures": gestures, "retrofit": retrofit, "scenes": scenes, "evidence": evidence,
        "focus": focus, "journey": journey, "footer": footer}


def main():
    files = {}
    for name, draw in FIGS.items():
        for mode, t in art.THEMES.items():
            files[f"{name}-{mode}.svg"] = draw(t)
            files[f"{name}-narrow-{mode}.svg"] = draw(t, narrow=True)
    print(f"wrote {art.write(files)} files to {art.OUT}")


if __name__ == "__main__":
    main()
