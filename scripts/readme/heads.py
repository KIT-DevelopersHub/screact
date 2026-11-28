"""項目の見出し・大見出し・目次・節の見出しを生成する。項目の見出しの右側では YouRay が内容を演じる。

舞台は幅560・高さ100（地面は94）。PC は見出しの文字の右側に縮めて置き、地面を見出しの文字の基準線にそろえる。
スマホは横に空きがないので、番号の行の上に幅いっぱいの舞台を置く。舞台の左右の端は、GitHub の背景色の
グラデーションを重ねて溶かす（マスクは Safari でぼやけるので使わない）。
場面の中には文字を置かず、形と動きだけで伝える。

    python scripts/readme/heads.py
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import art  # noqa: E402
from art import OPS, PC_W, PHONE_W, YOU, text  # noqa: E402

SW, SH, G = 560, 100, 94
PC_SCALE = .57
BASE = 55
SEP = 44

# 見出し：番号・日本語・英字ラベル。目次の項目名は短い形にする。
HEADS = [
    ("01", "背景（製品開発のきっかけ）", "BACKGROUND", "背景"),
    ("02", "製品説明（具体的な製品の説明）", "PRODUCT", "製品説明"),
    ("03", "できること", "GESTURES", "できること"),
    ("04", "特長", "FEATURES", "特長"),
    ("05", "利用場面", "SCENES", "利用場面"),
    ("06", "直接操作の価値", "EVIDENCE", "直接操作の価値"),
    ("07", "注力したこと（こだわり等）", "FOCUS", "注力したこと"),
    ("08", "今後の展望", "FUTURE", "今後の展望"),
    ("09", "システム構成", "ARCHITECTURE", "システム構成"),
    ("10", "活用した技術", "TECH STACK", "活用した技術"),
    ("11", "クイックスタート", "QUICK START", "クイックスタート"),
    ("12", "ドキュメント", "DOCUMENTS", "ドキュメント"),
]
PARTS = [("1", "製品概要", "PRODUCT", "01", "08"), ("2", "開発技術", "TECHNOLOGY", "09", "12")]
FIRST = {"01", "09"}
LINK = {"light": "#0969DA", "dark": "#4493F8"}
TOC_W = {False: 410, True: 158}

IO = "cubic-bezier(.45,0,.55,1)"
OUT_ = "cubic-bezier(.2,.8,.3,1)"
IN_ = "cubic-bezier(.6,0,.9,.4)"
STEP = "steps(1,end)"
LIN = "linear"


# ---------- 場面の仕組み ----------

class Scene:
    """幅560・高さ100の舞台。動きは秒で書き、1周 dur 秒で繰り返す。"""

    def __init__(self, key, t, dur):
        self.key, self.t, self.dur = key, t, dur
        self.svg, self.css = [], []
        self.n = 0

    def name(self):
        self.n += 1
        return f"{self.key}{self.n}"

    def kf(self, frames, prop="transform", origin=None):
        """frames: [(秒, 値[, 次への緩急])]。0秒と dur 秒を必ず含める。"""
        nm = self.name()
        body = []
        for f in frames:
            e = f";animation-timing-function:{f[2]}" if len(f) > 2 and f[2] else ""
            body.append(f"{f[0] / self.dur * 100:.3f}%{{{prop}:{f[1]}{e}}}")
        org = f"transform-box:fill-box;transform-origin:{origin};" if origin else ""
        self.css.append(f"@keyframes {nm}{{{''.join(body)}}}.{nm}{{animation:{nm} {self.dur}s linear infinite;{org}}}")
        return nm

    def add(self, body, frames=None, prop="transform", origin=None):
        if frames is None:
            self.svg.append(body)
            return
        self.svg.append(f'<g class="{self.kf(frames, prop, origin)}">{body}</g>')

    def show(self, body, spans):
        """spans [(出る秒, 消える秒)] の間だけ見せる。"""
        frames = [(0, "0")]
        for a, b in spans:
            frames += [(max(a - .01, 0), "0", STEP), (a, "1", STEP), (b - .01, "1", STEP), (b, "0", STEP)]
        frames.append((self.dur, "0"))
        frames = sorted(frames, key=lambda f: f[0])
        self.add(body, frames, prop="opacity")

    def ghost(self, path, moods=None, s=.5, origin="50% 100%"):
        """YouRay。path: [(秒, x, y[, 回転, 縦横の伸び(sx, sy), 緩急])]（足元の位置）。
        moods: [(出る秒, 消える秒, 目)]。それ以外の時間はふつうの目でまばたきする。"""
        moods = moods or []
        eyes = []
        busy = sorted((a, b) for a, b, _ in moods)
        nf = [(0, "1")]
        for a, b in busy:
            nf += [(max(a - .01, 0), "1", STEP), (a, "0", STEP), (b - .01, "0", STEP), (b, "1", STEP)]
        nf.append((self.dur, "1"))
        eyes.append(f'<g class="{self.kf(sorted(nf, key=lambda f: f[0]), "opacity")}">{art.eye("normal")}</g>')
        for a, b, m in moods:
            fr = sorted([(0, "0"), (max(a - .01, 0), "0", STEP), (a, "1", STEP), (b - .01, "1", STEP), (b, "0", STEP),
                         (self.dur, "0")], key=lambda f: f[0])
            eyes.append(f'<g class="{self.kf(fr, "opacity")}">{art.eye(m, "")}</g>')
        body = (f'<g transform="translate(-60 -{art.FOOT})"><path d="{art.GHOST}" fill="{YOU["body"]}" stroke="{YOU["line"]}" '
                f'stroke-width="4.5" stroke-linejoin="round"/>{"".join(eyes)}</g>')
        frames = []
        for f in path:
            sec, x, y = f[0], f[1], f[2]
            r = f[3] if len(f) > 3 else 0
            sx, sy = f[4] if len(f) > 4 and f[4] else (1, 1)
            ease = f[5] if len(f) > 5 else IO
            frames.append((sec, f"translate({x:.1f}px,{y:.1f}px) rotate({r}deg) scale({sx * s:.3f},{sy * s:.3f})", ease))
        self.add(f'<g class="float">{body}</g>', frames)

    def shadow_of(self, path, w=50):
        frames = [(f[0], f"translate({f[1]:.1f}px,{G}px) scale({max(.35, 1 - (G - f[2]) / 70):.2f})", IO) for f in path]
        self.add(f'<ellipse cx="0" cy="0" rx="{w / 2}" ry="4" fill="{self.t["ink"]}" opacity=".13"/>', frames)

    def render(self):
        return "".join(self.svg), "".join(self.css)


def tr(x, y, r=0, s=1):
    return f"translate({x:.1f}px,{y:.1f}px) rotate({r}deg) scale({s})"


def bubble(sc, x, y, kind, spans):
    """吹き出し（文字なし。…・？・！・ハート）。"""
    t = sc.t
    w = 34
    shape = (f'<rect x="{x - w / 2}" y="{y - 26}" width="{w}" height="24" rx="12" fill="{t["panel"]}" stroke="{t["line"]}" stroke-width="1.5"/>'
             f'<path d="M{x - 4} {y - 3}l4 6 3-6" fill="{t["panel"]}" stroke="{t["line"]}" stroke-width="1.5" stroke-linejoin="round"/>'
             f'<rect x="{x - 5}" y="{y - 5}" width="10" height="3" fill="{t["panel"]}"/>')
    ink = t["ink"]
    if kind == "dots":
        mark = "".join(f'<circle cx="{x - 8 + i * 8}" cy="{y - 14}" r="2.4" fill="{ink}"/>' for i in range(3))
    elif kind == "q":
        mark = (f'<path d="M{x - 4.5} {y - 18}q0-5 4.5-5t4.5 4.5q0 3-4.5 4.5v2" fill="none" stroke="{ink}" stroke-width="2.4" stroke-linecap="round"/>'
                f'<circle cx="{x}" cy="{y - 7.5}" r="1.6" fill="{ink}"/>')
    elif kind == "ex":
        mark = (f'<rect x="{x - 1.4}" y="{y - 22}" width="2.8" height="10" rx="1.4" fill="{OPS["draw"]}"/>'
                f'<circle cx="{x}" cy="{y - 8}" r="1.7" fill="{OPS["draw"]}"/>')
    else:  # heart
        mark = (f'<path d="M{x} {y - 7}c-7-5-9-8-9-11a4.5 4.5 0 0 1 9-1a4.5 4.5 0 0 1 9 1c0 3-2 6-9 11z" fill="{OPS["draw"]}"/>')
    frames = [(0, "scale(0)")]
    for a, b in spans:
        frames += [(max(a - .01, 0), "scale(0)", OUT_), (a + .25, "scale(1.08)", IO), (a + .4, "scale(1)"),
                   (b - .2, "scale(1)", IN_), (b, "scale(0)")]
    frames.append((sc.dur, "scale(0)"))
    sc.add(shape + mark, sorted(frames, key=lambda f: f[0]), origin="50% 100%")


def screen(sc, x, y, w, inner=""):
    """モニター（足を含む）。足の下端が地面に来るよう y を決める。"""
    sc.add(art.monitor(x, y, w, sc.t, inner))


def mon_y(w):
    return G - w * .62 - w * .1 - 3


def cursor_ring(r=6, color=None):
    c = color or OPS["click"]
    return f'<circle cx="0" cy="0" r="{r}" fill="none" stroke="{c}" stroke-width="2.4"/><circle cx="0" cy="0" r="2" fill="{c}"/>'


def phone_stand(sc, x, h=44, tilt=0, look=None):
    """スタンドに立てたスマホ（背面のカメラが目）。x は中心。look: [(秒, 瞳のdx)]。"""
    t = sc.t
    w = h * .52
    y = G - h - 6
    body = (f'<path d="M{x - 9} {G}l9-10 9 10z" fill="{t["stand"]}"/>'
            f'<g transform="rotate({tilt} {x} {y + h})"><rect x="{x - w / 2:.1f}" y="{y}" width="{w:.1f}" height="{h}" rx="{w * .22:.1f}" '
            f'fill="{t["panel"]}" stroke="{t["frame"]}" stroke-width="2"/>'
            f'<circle cx="{x}" cy="{y + h * .24:.1f}" r="{w * .24:.1f}" fill="{YOU["iris"]}" stroke="{YOU["line"]}" stroke-width="1.8"/></g>')
    sc.add(body)
    pupil = f'<circle cx="{x}" cy="{y + h * .24:.1f}" r="{w * .09:.1f}" fill="{YOU["pupil"]}"/>'
    if look:
        sc.add(pupil, [(f[0], f"translate({f[1]:.1f}px,{f[2] if len(f) > 2 else 0:.1f}px)", IO) for f in look])
    else:
        sc.add(pupil)


# ---------- 場面 ----------

def s01(t):
    """背景：ふつうの画面に触ってみても、何も起きない。"""
    sc = Scene("a", t, 7.0)
    w = 120
    mx, my = 300, mon_y(w)
    screen(sc, mx, my, w, f'<rect x="10" y="12" width="60" height="7" rx="3.5" fill="{t["line"]}"/>'
                          f'<rect x="10" y="26" width="90" height="5" rx="2.5" fill="{t["line"]}"/>'
                          f'<rect x="10" y="36" width="76" height="5" rx="2.5" fill="{t["line"]}"/>')
    path = [(0, 150, G - 6), (1.4, 262, G - 14), (1.9, 282, G - 22, 0, (1.08, .92)), (2.05, 268, G - 18, -8),
            (2.6, 262, G - 14), (4.8, 262, G - 14), (5.8, 150, G - 6), (7.0, 150, G - 6)]
    sc.shadow_of(path)
    sc.ghost(path, [(1.9, 2.6, "closed"), (2.8, 4.6, "up")])
    # ぶつかった画面がかすかに揺れる波紋（反応はしない）
    sc.add(f'<circle cx="{mx + 12}" cy="{my + 40}" r="10" fill="none" stroke="{t["muted"]}" stroke-width="1.5"/>',
           [(0, "scale(0)"), (1.89, "scale(0)", STEP), (1.9, "scale(.4)", OUT_), (2.5, "scale(1.6)"), (2.51, "scale(0)", STEP), (7, "scale(0)")],
           origin="50% 50%")
    bubble(sc, 268, G - 52, "dots", [(2.9, 4.5)])
    return sc


def s02(t):
    """製品説明：スマホが YouRay の動きを見て、画面のカーソルが同じように動く。"""
    sc = Scene("b", t, 7.0)
    w = 120
    mx, my = 330, mon_y(w)
    screen(sc, mx, my, w)
    phone_stand(sc, 488, look=[(0, -3), (1.75, -3, ), (3.5, -2), (5.25, -3), (7, -3)])
    # YouRay が上下左右に動き、画面のカーソルが同じ形で動く
    pts = [(0, 200, G - 8), (1.75, 250, G - 34), (3.5, 220, G - 4), (5.25, 180, G - 30), (7, 200, G - 8)]
    sc.shadow_of(pts)
    sc.ghost([(p[0], p[1], p[2], (p[1] - 215) * .15) for p in pts], [(1.6, 2.4, "happy"), (5.1, 5.9, "happy")])
    cur = [(p[0], f"translate({mx + 60 + (p[1] - 200) * 1.2:.1f}px,{my + 50 - (G - p[2]) * 1.1:.1f}px)", IO) for p in pts]
    sc.add(cursor_ring(), cur)
    # 視線（スマホから YouRay へ）
    sc.add(f'<path d="M478 {G - 40}L250 {G - 30}" stroke="{YOU["iris"]}" stroke-width="2" stroke-dasharray="3 6" class="flow" opacity=".9"/>')
    return sc


def s03(t):
    """できること：画面に描いて、消して、スクロールする。"""
    sc = Scene("c", t, 9.0)
    w = 150
    mx, my = 250, mon_y(w)
    lines_ = "".join(f'<rect x="12" y="{14 + k * 14}" width="{100 - (k % 3) * 22}" height="5" rx="2.5" fill="{t["line"]}"/>' for k in range(8))
    clip = f'<clipPath id="c-scr"><rect x="{mx + 3}" y="{my + 3}" width="{w - 6}" height="{w * .62 - 6:.1f}" rx="5"/></clipPath>'
    screen(sc, mx, my, w)
    sc.svg.append(f'<defs>{clip}</defs><g clip-path="url(#c-scr)">')
    sc.add(f'<g transform="translate({mx + 4} {my + 4})">{lines_}</g>',
           [(0, "translate(0px,0px)"), (6.0, "translate(0px,0px)", IO), (7.4, "translate(0px,-42px)"), (8.6, "translate(0px,-42px)", STEP),
            (8.61, "translate(0px,0px)"), (9, "translate(0px,0px)")])
    # インク（波線）。描いて、消す
    wave = f"M{mx + 24} {my + 58}c14-22 26-22 34 0s22 22 34 0 26-22 40-4"
    L = 150
    sc.add(f'<path d="{wave}" fill="none" stroke="{OPS["draw"]}" stroke-width="4" stroke-linecap="round" '
           f'stroke-dasharray="{L} {L + 10}"/>',
           [(0, str(L)), (.6, str(L), LIN), (2.6, "0"), (3.6, "0", LIN), (4.8, str(-L)), (9, str(-L))], prop="stroke-dashoffset")
    sc.svg.append("</g>")
    # YouRay：描く → グーで消す（つぶれる）→ 上へ動かしてスクロール
    path = [(0, 150, G - 10), (.6, 160, G - 30), (1.3, 175, G - 12), (2.0, 190, G - 30), (2.6, 200, G - 16),
            (3.6, 160, G - 20, 0, (1.15, .8)), (4.8, 200, G - 20, 0, (1.15, .8)), (5.4, 180, G - 10),
            (6.0, 180, G - 4), (7.4, 180, G - 40, 0, (.9, 1.1)), (8.2, 165, G - 10), (9, 150, G - 10)]
    sc.shadow_of(path)
    sc.ghost(path, [(3.6, 4.8, "closed"), (7.4, 8.2, "happy")])
    return sc


def s04(t):
    """特長：今ある画面に、スマホを置くだけで「操作できる」が付く。"""
    sc = Scene("d", t, 8.0)
    w = 130
    mx, my = 250, mon_y(w)
    screen(sc, mx, my, w)
    # 画面が光る（後付けされた）
    glow = (f'<rect x="{mx + 4}" y="{my + 4}" width="{w - 8}" height="{w * .62 - 8:.1f}" rx="5" fill="url(#brand)" opacity=".16"/>'
            + art.sparkle(mx + 30, my + 22, 7, OPS["click"]) + art.sparkle(mx + w - 26, my + 50, 6, "#F5B400")
            + art.sparkle(mx + w / 2, my + 34, 9, OPS["drag"]))
    sc.show(glow, [(4.4, 7.4)])
    # YouRay がスマホを頭にのせて運び、モニターの横に置く
    path = [(0, 90, G - 4), (2.2, 410, G - 14), (2.8, 418, G - 4, 0, (1.1, .9)), (3.4, 400, G - 10), (4.4, 330, G - 32),
            (7.2, 330, G - 32), (8, 90, G - 4)]
    sc.shadow_of(path)
    sc.ghost(path, [(4.3, 7.4, "happy")])
    # スマホは頭の上にのせて運び、モニターの横のスタンドに置く（置いた後はそのまま。最後に元へ戻る）
    ph = art.phone_icon(-11, -46, 40, t)
    sc.add(f'<path d="M409 {G}l9-8 9 8z" fill="{t["stand"]}"/>')
    sc.add(ph, [(0, f"translate(90px,{G - 41:.1f}px)", IO), (2.2, f"translate(410px,{G - 51:.1f}px)", IO),
                (2.8, f"translate(418px,{G - 2:.1f}px)", STEP), (7.99, f"translate(418px,{G - 2:.1f}px)", STEP),
                (8, f"translate(90px,{G - 41:.1f}px)")])
    # 置いたスマホから画面へ視線
    sc.show(f'<path d="M412 {G - 34}L{mx + w - 6} {my + 40}" stroke="{YOU["iris"]}" stroke-width="2" stroke-dasharray="3 6" class="flow"/>',
            [(3.2, 7.6)])
    return sc


def s05(t):
    """利用場面：会議・授業・接客の3つの画面を、YouRay が順にめぐる。"""
    sc = Scene("e", t, 9.0)
    w = 96
    xs = [70, 232, 394]
    my = mon_y(w)
    icons = [  # 会議（人が2人）、授業（ペン）、接客（吹き出し2つ）
        lambda x, y: "".join(f'<circle cx="{x + dx}" cy="{y + 20}" r="7" fill="{OPS["click"]}"/><rect x="{x + dx - 11}" y="{y + 30}" width="22" height="14" rx="7" fill="{OPS["click"]}"/>' for dx in (34, 58)),
        lambda x, y: (f'<path d="M{x + 28} {y + 44}l30-26 8 8-30 26-11 3z" fill="{OPS["draw"]}"/>'
                      f'<path d="M{x + 18} {y + 50}q20-8 40 0" fill="none" stroke="{OPS["draw"]}" stroke-width="2.5" stroke-linecap="round"/>'),
        lambda x, y: (f'<rect x="{x + 18}" y="{y + 12}" width="34" height="20" rx="8" fill="{OPS["scroll"]}"/>'
                      f'<rect x="{x + 44}" y="{y + 30}" width="34" height="20" rx="8" fill="{OPS["drag"]}"/>'),
    ]
    for k, x in enumerate(xs):
        screen(sc, x, my, w)
        sc.add(f'<g transform="translate(-4 -4)">{icons[k](x + 4, my + 4)}</g>',
               [(0, ".25"), (1 + 3 * k - .01, ".25", STEP), (1 + 3 * k, "1", STEP), (3 + 3 * k, "1", STEP), (3 + 3 * k + .01, ".25"), (9, ".25")],
               prop="opacity")
    path = [(0, xs[0] + w / 2, G - 2)]
    for k, x in enumerate(xs):
        cx = x + w / 2
        path += [(.4 + 3 * k, cx, G - 4), (.75 + 3 * k, cx, G - 14, 0, (1.12, .9)), (1.0 + 3 * k, cx, G - 8),
                 (2.6 + 3 * k, cx, G - 8)]
        nx = xs[k + 1] + w / 2 if k < 2 else xs[0] + w / 2
        path += [(3.0 + 3 * k - .2, (cx + nx) / 2, G - 48 if k < 2 else G - 60), (3.4 + 3 * k - .2, nx, G - 4)]
    path = [p for p in path if p[0] <= 9] + [(9, xs[0] + w / 2, G - 2)]
    path = sorted({p[0]: p for p in path}.values())
    sc.shadow_of(path)
    sc.ghost(path, [(1.0 + 3 * k, 2.6 + 3 * k, "happy") for k in range(3)], s=.42)
    return sc


def s06(t):
    """直接操作の価値：マウスとタッチの棒グラフ。タッチの方が短い。"""
    sc = Scene("f", t, 7.0)
    x0, base = 250, G - 4
    sc.add(f'<rect x="{x0 - 10}" y="{base}" width="230" height="2" rx="1" fill="{t["line"]}"/>')
    # マウスの印とタッチ（指）の印
    mouse = (f'<rect x="{x0 - 2}" y="{base - 64}" width="18" height="26" rx="9" fill="none" stroke="{t["muted"]}" stroke-width="2"/>'
             f'<path d="M{x0 + 7} {base - 64}v9" stroke="{t["muted"]}" stroke-width="2"/>')
    finger = (f'<path d="M{x0 + 4} {base - 22}v-14a3.5 3.5 0 0 1 7 0v8l7 2c3 1 4 3 3 6l-2 8h-13z" fill="none" stroke="{OPS["click"]}" '
              f'stroke-width="2" stroke-linejoin="round"/>')
    sc.add(mouse + finger)
    bars = [(base - 58, 190, t["muted"], .3), (base - 26, 120, "url(#brand)", 1.3)]
    for y, L, fill, st in bars:
        sc.add(f'<rect x="{x0 + 32}" y="{y}" width="{L}" height="16" rx="8" fill="{fill}"/>',
               [(0, "scaleX(0)"), (st, "scaleX(0)", OUT_), (st + 1.1, "scaleX(1)"), (6.4, "scaleX(1)", IN_), (6.9, "scaleX(0)"), (7, "scaleX(0)")],
               origin="0% 50%")
    # 差の印（タッチの方が短い）
    sc.show(f'<path d="M{x0 + 158} {base - 18}h56" stroke="{OPS["draw"]}" stroke-width="2.4" stroke-dasharray="4 4"/>'
            + art.sparkle(x0 + 222, base - 18, 7, "#F5B400"), [(2.8, 6.3)])
    path = [(0, 150, G - 6), (1.2, 175, G - 10), (2.6, 175, G - 10), (2.9, 175, G - 24, 0, (.92, 1.1)), (3.2, 175, G - 8, 0, (1.1, .9)),
            (3.5, 175, G - 10), (6.2, 175, G - 10), (7, 150, G - 6)]
    sc.shadow_of(path)
    sc.ghost(path, [(1.2, 2.6, "right"), (2.8, 3.8, "surprised"), (3.8, 6.2, "happy")])
    return sc


def s07(t):
    """注力したこと：斜めに置いたスマホでも、四隅のマーカーを読んで位置が合う。"""
    sc = Scene("g", t, 8.0)
    w = 140
    mx, my = 250, mon_y(w)
    screen(sc, mx, my, w)
    h = w * .62
    corners = [(mx + 6, my + 6), (mx + w - 18, my + 6), (mx + w - 18, my + h - 18), (mx + 6, my + h - 18)]
    for k, (cx, cy) in enumerate(corners):
        mk = (f'<rect x="{cx}" y="{cy}" width="12" height="12" fill="{t["ink"]}"/>'
              f'<rect x="{cx + 3}" y="{cy + 3}" width="3" height="3" fill="{t["screen"]}"/><rect x="{cx + 6}" y="{cy + 6}" width="3" height="3" fill="{t["screen"]}"/>')
        sc.add(mk)
        ring = f'<rect x="{cx - 3}" y="{cy - 3}" width="18" height="18" rx="3" fill="none" stroke="{OPS["scroll"]}" stroke-width="2.4"/>'
        sc.show(ring, [(1.4 + k * .45, 6.8)])
    # 枠がそろう（位置合わせの完了）
    sc.show(f'<rect x="{mx + 2}" y="{my + 2}" width="{w - 4}" height="{h - 4:.1f}" rx="6" fill="none" stroke="url(#brand)" stroke-width="3"/>'
            + f'<path d="M{mx + w / 2 - 12} {my + h / 2}l8 8 16-16" fill="none" stroke="{OPS["scroll"]}" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>',
            [(3.5, 6.8)])
    phone_stand(sc, 460, tilt=-18, look=[(0, -3, 0), (1.3, -4, -1), (3.4, -3, 1), (8, -3, 0)])
    sc.add(f'<path d="M448 {G - 38}L{mx + w - 4} {my + 30}" stroke="{YOU["iris"]}" stroke-width="2" stroke-dasharray="3 6" class="flow"/>')
    path = [(0, 160, G - 6), (3.4, 170, G - 8), (3.7, 170, G - 24, 0, (.92, 1.1)), (4.0, 170, G - 6, 0, (1.1, .9)), (4.3, 170, G - 8),
            (7.0, 170, G - 8), (8, 160, G - 6)]
    sc.shadow_of(path)
    sc.ghost(path, [(1.2, 3.4, "right"), (3.6, 6.8, "happy")])
    return sc


def s08(t):
    """今後の展望：点線の道を進み、次の旗を立てる。"""
    sc = Scene("h", t, 8.0)
    sc.add(f'<path d="M150 {G - 2}H520" stroke="{t["line"]}" stroke-width="2.5" stroke-dasharray="2 8" stroke-linecap="round"/>')
    flag = lambda x, c: (f'<rect x="{x}" y="{G - 52}" width="2.5" height="50" fill="{t["frame"]}"/>'  # noqa: E731
                         f'<path d="M{x + 2.5} {G - 52}h26l-6 8 6 8h-26z" fill="{c}"/>')
    sc.add(flag(220, OPS["click"]))
    sc.add(flag(460, OPS["draw"]), [(0, "scaleY(0)"), (4.2, "scaleY(0)", OUT_), (4.8, "scaleY(1.08)"), (5.0, "scaleY(1)"),
                                    (7.4, "scaleY(1)", IN_), (7.8, "scaleY(0)"), (8, "scaleY(0)")], origin="50% 100%")
    path = [(0, 170, G - 6)]
    for k in range(6):
        x = 190 + k * 44
        path += [(.4 + k * .6, x - 10, G - 22, 0, (.94, 1.06)), (.7 + k * .6, x + 10, G - 4, 0, (1.08, .92))]
    path += [(4.2, 430, G - 8), (4.9, 430, G - 26, 0, (.92, 1.1)), (5.3, 430, G - 8), (7.2, 430, G - 8), (8, 170, G - 6)]
    sc.shadow_of(path)
    sc.ghost(path, [(4.8, 7.2, "happy")], s=.45)
    bubble(sc, 430, G - 52, "heart", [(5.0, 6.8)])
    return sc


def s09(t):
    """システム構成：スマホ → PC → 画面へ、座標の点が流れる。YouRay が点に乗る。"""
    sc = Scene("i", t, 6.0)
    phone_stand(sc, 170)
    # ノートPC
    lx, ly = 290, G - 44
    sc.add(f'<rect x="{lx}" y="{ly}" width="66" height="40" rx="4" fill="{t["screen"]}" stroke="{t["frame"]}" stroke-width="2.2"/>'
           f'<path d="M{lx - 8} {G - 3}h82l-6 3h-70z" fill="{t["stand"]}"/>')
    w = 110
    screen(sc, 420, mon_y(w), w)
    sc.add(f'<path d="M188 {G - 34}H{lx - 6}M{lx + 72} {G - 24}H414" stroke="{t["line"]}" stroke-width="2.4" stroke-dasharray="6 8" class="flow"/>')
    pts = [(0, 186, G - 34), (1.4, lx - 4, G - 34), (2.0, lx + 33, G - 26), (2.6, lx + 70, G - 24), (4.0, 425, G - 24), (4.6, 470, mon_y(w) + 40)]
    dot = f'<circle r="6" fill="url(#brand)"/>'
    frames = [(p[0], f"translate({p[1]}px,{p[2]}px) scale(1)", LIN) for p in pts]
    frames += [(4.61, f"translate({pts[-1][1]}px,{pts[-1][2]}px) scale(1.8)", OUT_), (5.2, f"translate({pts[-1][1]}px,{pts[-1][2]}px) scale(0)", STEP),
               (6, f"translate({pts[0][1]}px,{pts[0][2]}px) scale(1)")]
    sc.add(dot, frames)
    sc.add(f'<g transform="translate(470 {mon_y(w) + 40})">{cursor_ring(8)}</g>',
           [(0, "0"), (4.59, "0", STEP), (4.6, "1", STEP), (5.8, "1", STEP), (5.81, "0"), (6, "0")], prop="opacity")
    gp = [(p[0], p[1], p[2] - 6) for p in pts[:5]] + [(4.6, 440, G - 6), (5.4, 300, G - 2), (6, 186, G - 40)]
    sc.ghost([(p[0], p[1], p[2], 0, None, LIN) for p in gp], [(1.4, 4.2, "happy")], s=.3)
    return sc


def s10(t):
    """活用した技術：4色のブロックを積み上げる。"""
    sc = Scene("j", t, 8.0)
    bw, bh, x0 = 54, 16, 300
    for k, n in enumerate(art.ORDER):
        y = G - bh * (k + 1)
        st = .6 + k * 1.1
        sc.add(f'<rect x="{x0}" y="{y}" width="{bw}" height="{bh - 2}" rx="5" fill="{OPS[n]}"/>',
               [(0, "translate(0px,-120px)"), (st, "translate(0px,-120px)", IN_), (st + .45, "translate(0px,0px)", OUT_),
                (st + .55, "translate(0px,-3px)", IN_), (st + .65, "translate(0px,0px)"), (7.4, "translate(0px,0px)", IN_),
                (7.9, "translate(0px,-120px)"), (8, "translate(0px,-120px)")])
    path = [(0, 220, G - 6)]
    for k in range(4):
        st = .6 + k * 1.1
        path += [(st + .5, 236, G - 6), (st + .7, 236, G - 18, 0, (.94, 1.06)), (st + .9, 236, G - 6)]
    path += [(5.4, 236, G - 6), (5.8, 270, G - 70), (6.2, 327, G - 4 * bh - 2, 0, (1.1, .9)), (7.2, 327, G - 4 * bh - 2), (8, 220, G - 6)]
    sc.shadow_of(path)
    sc.ghost(path, [(5.8, 7.2, "happy")], s=.42)
    return sc


def s11(t):
    """クイックスタート：「はじめる」を押すと、つながって、画面が使えるようになる。"""
    sc = Scene("k", t, 7.0)
    w = 116
    mx, my = 330, mon_y(w)
    screen(sc, mx, my, w)
    # 大きな再生ボタン（押すとへこむ）
    bx, by = 238, G - 22
    sc.add(f'<circle cx="{bx}" cy="{by}" r="18" fill="url(#brand)"/><path d="M{bx - 5} {by - 8}l13 8-13 8z" fill="#FFFFFF"/>',
           [(0, "scale(1)"), (1.6, "scale(1)", IN_), (1.8, "scale(.82)", OUT_), (2.1, "scale(1)"), (7, "scale(1)")], origin="50% 50%")
    # つながる波
    for k in range(3):
        sc.show(f'<path d="M{mx - 26 + k * 7} {my + 22 - k * 6}a{14 + k * 7} {14 + k * 7} 0 0 1 0 {16 + k * 12}" fill="none" stroke="{OPS["scroll"]}" stroke-width="2.4" stroke-linecap="round"/>',
                [(2.3 + k * .25, 6.4)])
    sc.show(f'<rect x="{mx + 4}" y="{my + 4}" width="{w - 8}" height="{w * .62 - 8:.1f}" rx="5" fill="url(#brand)" opacity=".18"/>'
            + f'<g transform="translate({mx + w / 2} {my + w * .31})">{cursor_ring(8)}</g>', [(3.2, 6.4)])
    path = [(0, 160, G - 6), (1.2, 205, G - 30), (1.6, 222, G - 26, -12), (1.8, 226, G - 20, -16, (1.06, .94)), (2.2, 205, G - 30),
            (3.2, 190, G - 10), (3.5, 190, G - 26, 0, (.92, 1.1)), (3.8, 190, G - 8), (6.4, 190, G - 8), (7, 160, G - 6)]
    sc.shadow_of(path)
    sc.ghost(path, [(1.6, 2.2, "closed"), (3.2, 6.4, "happy")], s=.42)
    return sc


def s12(t):
    """ドキュメント：本を開いて読む。ページがめくれる。"""
    sc = Scene("l", t, 7.0)
    bx, by = 300, G - 6
    pg = t["panel"]
    sc.add(f'<path d="M{bx} {by}l-60-8v-34l60 8z" fill="{pg}" stroke="{t["frame"]}" stroke-width="2" stroke-linejoin="round"/>'
           f'<path d="M{bx} {by}l60-8v-34l-60 8z" fill="{pg}" stroke="{t["frame"]}" stroke-width="2" stroke-linejoin="round"/>'
           + "".join(f'<path d="M{bx - 50} {by - 32 + k * 7}l40 5" stroke="{t["line"]}" stroke-width="2.4" stroke-linecap="round"/>'
                     f'<path d="M{bx + 10} {by - 27 + k * 7}l40-5" stroke="{t["line"]}" stroke-width="2.4" stroke-linecap="round"/>' for k in range(4)))
    # めくれるページ
    sc.add(f'<path d="M{bx} {by}l60-8v-34l-60 8z" fill="{pg}" stroke="{t["frame"]}" stroke-width="2" stroke-linejoin="round"/>',
           [(0, "scaleX(1)"), (2.6, "scaleX(1)", IO), (3.1, "scaleX(0)", STEP), (3.11, "scaleX(0)", IO), (3.6, "scaleX(-1)"),
            (3.61, "scaleX(1)", STEP), (5.4, "scaleX(1)", IO), (5.9, "scaleX(0)", STEP), (5.91, "scaleX(0)", IO), (6.4, "scaleX(-1)"),
            (6.41, "scaleX(1)"), (7, "scaleX(1)")], origin="0% 100%")
    path = [(0, 220, G - 30), (7, 220, G - 30)]
    sc.shadow_of(path)
    sc.ghost([(0, 210, G - 34), (3.5, 214, G - 30), (7, 210, G - 34)],
             [(0, 1.2, "right"), (1.2, 2.4, "left"), (2.4, 3.4, "right"), (3.4, 4.6, "left"), (4.6, 5.8, "right"), (5.8, 7, "happy")], s=.42)
    return sc


PLAY = {"01": s01, "02": s02, "03": s03, "04": s04, "05": s05, "06": s06, "07": s07, "08": s08, "09": s09, "10": s10,
        "11": s11, "12": s12}
DESC = {"01": "YouRayがふつうの画面に触ってみるが、何も起きない", "02": "スマホがYouRayの動きを見て、画面のカーソルが同じように動く",
        "03": "画面に線を描き、グーで消し、上へ動かしてスクロールする", "04": "YouRayがスマホを運んでモニターの横に置くと、画面が操作できるようになる",
        "05": "会議・授業・接客の3つの画面を、YouRayが順にめぐる", "06": "マウスより、タッチの方が短い棒グラフを見て、YouRayが驚いて喜ぶ",
        "07": "斜めに置いたスマホが四隅のマーカーを読み、画面の位置が合う", "08": "点線の道を進み、次の旗が立つ",
        "09": "スマホからPC、画面へ座標の点が流れ、YouRayが乗っていく", "10": "4色のブロックを積み上げ、YouRayが一番上に乗る",
        "11": "YouRayが再生ボタンを押すと、つながって画面が使えるようになる", "12": "YouRayが本を開いて読み、ページがめくれる"}


# ---------- 見出しの組み立て ----------

def fit(s, size, avail):
    w = art.tw(s, size)
    return avail if w > avail else None


def wrap(s, size, avail):
    if art.tw(s, size) <= avail:
        return [s]
    ok = [i for i in range(1, len(s)) if art.tw(s[:i], size) <= avail and art.tw(s[i:], size) <= avail
          and s[i] not in "、。）)ーぁぃぅぇぉっゃゅょ" and s[i - 1] not in "（("]
    good = [i for i in ok if s[i - 1] in "、）)" or s[i] in "（("]
    i = good[-1] if good else max(ok, key=lambda k: min(art.tw(s[:k], size), art.tw(s[k:], size)))
    return [s[:i], s[i:]]


def head_parts(num, jp, en, t, narrow=False):
    if narrow:
        ls = wrap(jp, 27, PHONE_W - 4)
        W, H = PHONE_W, 50 + 36 * len(ls)
        b = [text(0, 42, num, 42, "url(#brand)", cls="disp", weight=400, length=44),
             text(58, 34, en, 13, t["muted"], weight=600, extra=' letter-spacing="3"')]
        b += [text(-13.5 if ln[0] in "（「" else 0, 80 + 36 * k, ln, 27, t["ink"], weight=600) for k, ln in enumerate(ls)]
    else:
        W, H = PC_W, 68
        b = [text(0, 52, num, 42, "url(#brand)", cls="disp", weight=400, length=44),
             text(60, 26, en, 13, t["muted"], weight=600, extra=' letter-spacing="3"'),
             text(58, 55, jp, 27, t["ink"], weight=600, length=fit(jp, 27, W - 58 - 8))]
    return W, H, "".join(b)


def stage(sc, x, y, k, t, fade_l=.14, fade_r=.06):
    w, h = SW * k, SH * k
    page = t["page"]
    sid = f"st{sc.key}"
    defs = (f'<linearGradient id="{sid}f" x1="{x}" y1="0" x2="{x + w}" y2="0" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="{page}"/><stop offset="{fade_l}" stop-color="{page}" stop-opacity="0"/>'
            f'<stop offset="{1 - fade_r}" stop-color="{page}" stop-opacity="0"/><stop offset="1" stop-color="{page}"/></linearGradient>'
            f'<clipPath id="{sid}c"><rect x="{x}" y="{y - 20}" width="{w}" height="{h + 40}"/></clipPath>')
    body, _ = sc.render()
    return (f'<defs>{defs}</defs><g clip-path="url(#{sid}c)"><svg x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" '
            f'viewBox="0 0 {SW} {SH}" overflow="visible">{body}</svg>'
            f'<rect x="{x}" y="{y - 20}" width="{w}" height="{h + 40}" fill="url(#{sid}f)"/></g>')


def play_head(num, jp, en, t, narrow=False):
    sc = PLAY[num](t)
    _, css = sc.render()
    if narrow:
        k = PHONE_W / SW
        top = round(G * k) - 4
        W, H, body = head_parts(num, jp, en, t, narrow=True)
        body = stage(sc, 0, 0, k, t, .06, .06) + f'<g transform="translate(0 {top})">{body}</g>'
        H += top
    else:
        k = PC_SCALE
        W, H, body = head_parts(num, jp, en, t)
        body = stage(sc, PC_W - SW * k, BASE - G * k, k, t) + body
    if num not in FIRST:
        x1 = W - 53
        sep = f'<rect x="0" y="8.25" width="{x1}" height="1.5" rx=".75" fill="{t["line"]}"/>' + art.four_dots(x1 + 10, 9)
        body = sep + f'<g transform="translate(0 {SEP})">{body}</g>'
        H += SEP
    return art.svg(W, H, body, t, f"{num} {jp}（{DESC[num]}）", css)


def part_banner(part, jp, en, first, last, t, narrow=False):
    W, H = (PHONE_W, 96) if narrow else (PC_W, 104)
    b = [f'<rect width="{W}" height="{H}" rx="18" fill="url(#bg)"/>',
         f'<clipPath id="card"><rect width="{W}" height="{H}" rx="18"/></clipPath><g clip-path="url(#card)">',
         f'<g transform="translate({W if narrow else W - 230} {H}) scale(-1 -1)">{art.dots(14, 14, 8, 5, 12, 2.4, t["dot"])}</g>',
         f'<rect width="7" height="{H}" fill="url(#brand)"/></g>',
         f'<rect x="{66 if narrow else 80}" y="22" width="1.5" height="{H - 44}" fill="{t["line"]}"/>']
    if narrow:
        b += [text(20, 34, "PART", 13, t["muted"], weight=600, extra=' letter-spacing="1"'),
              text(24, 80, part, 48, "url(#brand)", cls="disp", weight=400),
              text(82, 34, en, 13, t["muted"], weight=600, extra=' letter-spacing="3"'),
              text(82, 70, jp, 30, t["ink"], weight=700),
              text(W - 18, 34, f"{first}–{last}", 15, "url(#brand)", cls="disp", weight=400, anchor="end", extra=' letter-spacing="1"')]
    else:
        b += [text(32, 40, "PART", 13, t["muted"], weight=600, extra=' letter-spacing="3"'),
              text(32, 86, part, 52, "url(#brand)", cls="disp", weight=400),
              text(100, 40, en, 13, t["muted"], weight=600, extra=' letter-spacing="4"'),
              text(100, 78, jp, 34, t["ink"], weight=700),
              text(W - 32, 40, "SECTIONS", 13, t["muted"], weight=600, anchor="end", extra=' letter-spacing="3"'),
              text(W - 32, 80, f"{first} – {last}", 32, "url(#brand)", cls="disp", weight=400, anchor="end", extra=' letter-spacing="1"')]
        # 帯の右寄りで YouRay がふわふわ浮かぶ
        b.append(art.youray(W - 250, 84, .42, delay=.6 * int(part)))
    return art.svg(W, H, "".join(b), t, f"{jp}（{en}）")


def section_head(jp, en, W, t, ls=4):
    ex = 24 * len(jp) + 12
    b = [text(0, 31, jp, 24, t["ink"], weight=700),
         text(ex, 30, en, 13, t["muted"], weight=600, extra=f' letter-spacing="{ls}"')]
    x0, x1 = ex + round(len(en) * 8.06 + (len(en) - 1) * ls) + 20, W - 53
    if x1 - x0 >= 24:
        b.append(f'<rect x="{x0}" y="24.5" width="{x1 - x0}" height="1.5" rx=".75" fill="{t["line"]}"/>')
    b.append(art.four_dots(x1 + 10, 25.25))
    return "".join(b)


def toc_title(t, narrow=False):
    W = PHONE_W if narrow else PC_W
    return art.svg(W, 40, section_head("目次", "CONTENTS", W, t), t, "目次")


def toc_item(num, label, en, mode, narrow=False):
    t = art.THEMES[mode]
    W = TOC_W[narrow]
    b = [text(0, 23, num, 21, "url(#brand)", cls="disp", weight=400, length=23),
         text(29, 21, label, 16, LINK[mode], weight=400)]
    if not narrow:
        b.append(text(W - 14, 20, en, 13, t["muted"], weight=600, anchor="end", extra=' letter-spacing="1.5" opacity=".75"'))
    b.append(f'<rect x="29" y="30" width="{W - 43}" height="1" fill="{t["line"]}"/>')
    return art.svg(W, 34, "".join(b), t, f"{num} {label}")


def toc_part(part, jp, en, mode, narrow=False):
    t = art.THEMES[mode]
    W = TOC_W[narrow]
    b = [text(0, 15, f"PART {part}", 13, "url(#brand)", weight=700, extra=' letter-spacing="2"'),
         text(0, 41, jp, 19, t["ink"], weight=700)]
    if not narrow:
        b.append(text(W - 14, 41, en, 13, t["muted"], weight=600, anchor="end", extra=' letter-spacing="3"'))
    b.append(f'<rect y="50" width="{W - 14}" height="3" rx="1.5" fill="url(#brand)"/>')
    return art.svg(W, 62, "".join(b), t, f"{jp}（{en}）")


def main():
    files = {}
    for mode, t in art.THEMES.items():
        for sfx, narrow in (("", False), ("-narrow", True)):
            for num, jp, en, _ in HEADS:
                files[f"heads/play-{num}{sfx}-{mode}.svg"] = play_head(num, jp, en, t, narrow)
            for num, _, en, label in HEADS:
                files[f"heads/toc-{num}{sfx}-{mode}.svg"] = toc_item(num, label, en, mode, narrow)
            for part, jp, en, first, last in PARTS:
                files[f"heads/part-{part}{sfx}-{mode}.svg"] = part_banner(part, jp, en, first, last, t, narrow)
                files[f"heads/toc-part-{part}{sfx}-{mode}.svg"] = toc_part(part, jp, en, mode, narrow)
            files[f"heads/toc-title{sfx}-{mode}.svg"] = toc_title(t, narrow)
            W = PHONE_W if narrow else PC_W
            files[f"heads/awards-title{sfx}-{mode}.svg"] = art.svg(W, 40, section_head("受賞・出展", "AWARDS", W, t), t, "受賞・出展")
    print(f"wrote {art.write(files)} files to {art.OUT / 'heads'}")


if __name__ == "__main__":
    main()
