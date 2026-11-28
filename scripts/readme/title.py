"""README の作品名（h1）を、GitHub の見出しと同じ見た目の SVG アニメーションにする。

最初はふつうの見出しにしか見えない。少したつと、ロゴの手が「Screact」の「r」をつまんで持ち上げ、
すき間から YouRay が顔を出す（ロゴの絵と同じ場面）。YouRay が外へ出ると手は「r」を戻し、
キャッチコピーの「操作できる」をペンで囲む。YouRay が喜んだあと、手は線をなぞって消し、みんな去って元の見出しに戻る。
1周は約23秒で、最初の約4.5秒は止まっている。

一番上の「※技育展2026 決勝での内容です」は、GitHub の引用（> で始まる行）と同じ見た目で描く。
1行目の作品名は GitHub の h1（32px・太さ600）、2行目以降のキャッチコピーは h2 と同じ24px。
1文字ずつの幅は、GitHub と同じフォント指定で Chrome が測った値（WIDTHS）を使う。
README では <h1> の中に align="absbottom" で入れ、見出しの下線までの間隔をふつうの見出しと同じにする。
画面の幅 1100px 以下ではスマホ用（-narrow-）に切り替える（GitHub は幅768px以上で横に欄を出し、本文欄が狭くなるため）。

    python scripts/readme/title.py
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import art  # noqa: E402

NAME = "Screact"
CATCH = "今ある画面を買い替えず、「操作できる」を後付けする。"
NOTE = "※技育展2026 決勝での内容です"
# GitHub の h1（32px・太さ600）で測った各文字の幅（Windows・Chrome、2026-11-28）
WIDTHS = [17.42, 15.05, 11.84, 17.00, 16.70, 15.05, 11.56]
R = 2  # 持ち上げる「r」
# キャッチコピーの行（PC は1行、スマホは3行）。全角はすべて24px。
CATCH_LINES = {"wide": [CATCH], "narrow": ["今ある画面を買い替えず、", "「操作できる」を", "後付けする。"]}
MARK = "「操作できる」"
GAP = 24
INK = {"light": "#1F2328", "dark": "#F0F6FC"}
MUTED = {"light": "#59636E", "dark": "#9198A1"}
QUOTE = {"light": "#D1D9E0", "dark": "#3D444D"}
FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI','Noto Sans',Helvetica,Arial,sans-serif"
LEAD, DUR = 4.5, 18.5  # 止まっている時間と、動いている時間（秒）
ALT = f"{NOTE} {NAME} {CATCH}"


def ease(name):
    return {"out": "cubic-bezier(.2,.8,.3,1)", "in": "cubic-bezier(.6,0,.9,.4)", "io": "cubic-bezier(.45,0,.55,1)",
            "lin": "linear", "step": "steps(1,end)"}[name]


class Anim:
    def __init__(self):
        self.css = []

    def pct(self, sec):
        return round((LEAD + sec) / (LEAD + DUR) * 100, 3)

    def kf(self, name, frames, prop="transform", origin=None):
        """frames: [(秒, 値, 次への緩急)]。秒は動きが始まってからの時間。先頭と末尾は止まった状態でそろえる。"""
        body = [f"0%{{{prop}:{frames[0][1]}}}"]
        for f in frames:
            e = f";animation-timing-function:{ease(f[2])}" if len(f) > 2 else ""
            body.append(f"{self.pct(f[0])}%{{{prop}:{f[1]}{e}}}")
        body.append(f"100%{{{prop}:{frames[-1][1]}}}")
        org = f"transform-box:fill-box;transform-origin:{origin};" if origin else ""
        self.css.append(f"@keyframes {name}{{{''.join(body)}}}"
                        f".{name}{{animation:{name} {LEAD + DUR}s linear infinite;{org}}}")
        return name


def tr(x=0, y=0, r=0, s=1):
    return f"translate({x:.1f}px,{y:.1f}px) rotate({r:.1f}deg) scale({s})"


def ellipse_pts(cx, cy, rx, ry, n=20, start=-.55, turn=1.08):
    """手描きの丸（少し行き過ぎて閉じる）。start は角度の始まり（ラジアン）。"""
    pts = []
    for k in range(n + 1):
        a = start + 2 * math.pi * turn * k / n
        wob = 1 + .04 * math.sin(3 * a)
        pts.append((cx + rx * wob * math.cos(a), cy + ry * wob * math.sin(a)))
    return pts


def build(kind, mode):
    W = art.PC_W if kind == "wide" else art.PHONE_W
    cl = CATCH_LINES[kind]
    tops, y = [], 24 + GAP
    rows = [(NAME, 32)] + [(c, 24) for c in cl]
    for _, size in rows:
        tops.append(y)
        y += size * 1.25
    H = y

    def base(row):
        size = rows[row][1]
        return tops[row] + size * 1.25 / 2 + 13 * size / 32

    ink, t = INK[mode], art.THEMES[mode]
    a = Anim()
    b1 = base(0)
    xs = [sum(WIDTHS[:i]) for i in range(len(WIDTHS) + 1)]
    rx0, rw = xs[R], WIDTHS[R]
    out = [f'<rect x="0" y="0" width="4" height="24" rx="2" fill="{QUOTE[mode]}"/>',
           f'<text x="16" y="17" class="q">{art.esc(NOTE)}</text>',
           f'<text x="0" y="{b1:.2f}" class="h1" textLength="{xs[R]:.2f}" lengthAdjust="spacingAndGlyphs">{NAME[:R]}</text>',
           f'<text x="{xs[R + 1]:.2f}" y="{b1:.2f}" class="h1" textLength="{xs[-1] - xs[R + 1]:.2f}" '
           f'lengthAdjust="spacingAndGlyphs">{NAME[R + 1:]}</text>']
    for i, line in enumerate(cl):
        out.append(f'<text x="0" y="{base(i + 1):.2f}" class="h2" textLength="{24 * len(line)}" '
                   f'lengthAdjust="spacingAndGlyphs">{art.esc(line)}</text>')

    # ---- 時刻（秒）----
    T_ARRIVE, T_PINCH, T_LIFT, T_UP = 1.4, 1.75, 2.0, 2.8
    T_POP, T_POPPED = 2.8, 3.4
    T_LEAVE, T_PERCH = 6.2, 7.6
    T_DOWN, T_DOWNED, T_RELEASE = 6.9, 7.7, 7.95
    T_INK0, T_INK1 = 8.9, 11.1
    T_JOY0, T_JOY1 = 11.1, 12.4
    T_ER0, T_ER1 = 12.6, 14.2
    T_HAND_OUT = 15.2
    T_GO0, T_GO1 = 14.6, 16.6

    # ---- 「r」：つままれて持ち上がり、戻る ----
    lift = (6, -24, -12)
    a.kf("rr", [(T_LIFT, tr(), "out"), (T_UP, tr(*lift)), (T_DOWN, tr(*lift), "in"), (T_DOWNED - .1, tr(0, 1.5)),
                (T_DOWNED, tr())], origin="50% 100%")
    out.append(f'<text x="{rx0:.2f}" y="{b1:.2f}" class="h1 rr" textLength="{rw:.2f}" lengthAdjust="spacingAndGlyphs">r</text>')

    # ---- 手 ----
    px, py = rx0 + rw * .62, b1 - 17.5  # 「r」の上をつまむ点
    lx, ly = px + lift[0], py + lift[1]

    # ---- 丸で囲む言葉の位置 ----
    mrow = next(i for i, line in enumerate(cl) if MARK in line) + 1
    mx0 = 24 * cl[mrow - 1].index(MARK)
    mcx, mcy = mx0 + 24 * len(MARK) / 2, base(mrow) - 9
    erx, ery = 24 * len(MARK) / 2 + 12, 15.5
    if mcx - erx * 1.04 < 2:  # 行頭の「（スマホ）は、丸が画像の左にはみ出さないよう少し右へ寄せて小さくする
        mcx += 6
        erx = (mcx - 3) / 1.04
    pts = ellipse_pts(mcx, mcy, erx, ery)
    d = "M" + "L".join(f"{x:.1f} {y:.1f}" for x, y in pts)
    plen = sum(math.dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1))

    off = (min(W + 60, px + 220), -70)
    hf = [(0, tr(*off)), (.05, tr(*off), "out"), (T_ARRIVE, tr(px + 3, py - 4), "io"), (T_PINCH, tr(px, py), "out"),
          (T_LIFT, tr(px, py), "out"), (T_UP, tr(lx, ly)), (T_DOWN, tr(lx, ly), "in"), (T_DOWNED, tr(px, py)),
          (T_RELEASE + .15, tr(px, py), "io"), (T_RELEASE + .55, tr(px + 10, py - 14), "io"),
          (T_INK0 - .1, tr(*pts[0]), "lin")]
    seg = (T_INK1 - T_INK0) / (len(pts) - 1)
    hf += [(T_INK0 + k * seg, tr(*p), "lin") for k, p in enumerate(pts)]
    hf += [(T_INK1 + .25, tr(pts[-1][0] + 6, pts[-1][1] - 8), "io"), (T_ER0 - .05, tr(*pts[0]), "lin")]
    seg = (T_ER1 - T_ER0) / (len(pts) - 1)
    hf += [(T_ER0 + k * seg, tr(p[0], p[1] + 1), "lin") for k, p in enumerate(pts)]
    hf += [(T_ER1 + .1, tr(pts[-1][0], pts[-1][1]), "in"), (T_HAND_OUT, tr(*off))]
    a.kf("hd", hf)
    # 親指：近づくときは開き、つまむと閉じる。「r」を放すと開き、線を描く間は閉じる
    a.kf("th", [(0, "translate(3px,6px) rotate(14deg)"), (T_PINCH, "translate(3px,6px) rotate(14deg)", "out"),
                (T_PINCH + .25, "translate(0px,0px) rotate(0deg)"), (T_RELEASE, "translate(0px,0px) rotate(0deg)", "out"),
                (T_RELEASE + .2, "translate(3px,6px) rotate(14deg)"), (T_INK0 - .5, "translate(3px,6px) rotate(14deg)", "out"),
                (T_INK0 - .2, "translate(0px,0px) rotate(0deg)"), (T_HAND_OUT - .6, "translate(0px,0px) rotate(0deg)", "out"),
                (T_HAND_OUT - .3, "translate(3px,6px) rotate(14deg)")], origin="80% 10%")
    sk = f'stroke="{art.SKIN_LINE}" stroke-width="2.4" stroke-linejoin="round"'
    hand = (f'<g class="hd"><g transform="scale(.5)"><path d="{art.HAND_BACK}" fill="{art.SKIN}" {sk}/>'
            f'<path d="{art.HAND_NAIL}" fill="#F5C59D"/><g class="th"><path d="{art.HAND_THUMB}" fill="{art.SKIN}" {sk}/></g></g></g>')

    # ---- インク（描いて、なぞって消す）----
    L = plen + 2
    a.kf("ink", [(T_INK0, f"{L:.1f}", "lin"), (T_INK1, "0"), (T_ER0, "0", "lin"), (T_ER1, f"{-L:.1f}")],
         prop="stroke-dashoffset")
    out.append(f'<path class="ink" d="{d}" fill="none" stroke="{art.OPS["draw"]}" stroke-width="3" stroke-linecap="round" '
               f'stroke-linejoin="round" stroke-dasharray="{L:.1f} {L + 4:.1f}" stroke-dashoffset="{L:.1f}"/>')

    # ---- YouRay ----
    s = .24
    gx0 = rx0 + rw / 2
    perch = (xs[-1] + 26, b1 + 1) if kind == "wide" else (xs[-1] + 30, b1 + 1)
    hide = (gx0, b1 + 26)
    joy = [(T_JOY0 + k * .32, tr(perch[0], perch[1] - (7 if k % 2 == 0 else 0)), "io") for k in range(4)]
    gf = [(0, tr(*hide)), (T_POP, tr(*hide), "out"), (T_POPPED, tr(gx0, b1 + 2), "io"), (T_POPPED + .25, tr(gx0, b1 + 3.5), "io"),
          (T_POPPED + .55, tr(gx0, b1 + 2), "io"), (T_LEAVE, tr(gx0, b1 + 2), "io"),
          (T_LEAVE + .6, tr(gx0 + 18, b1 - 30, 8), "io"), (T_PERCH, tr(*perch), "out"), (T_JOY0 - .01, tr(*perch), "io")]
    gf += joy + [(T_GO0, tr(*perch), "io"), (T_GO0 + .5, tr(perch[0] - 6, perch[1] - 4, -6), "in"),
                 (T_GO1, tr(W + 40, perch[1] - 26, 10), "step"), (T_GO1 + .2, tr(*hide))]
    a.kf("gh", gf)
    # 目：驚く → まばたき → 左右を見る → 喜ぶ → ふつう → 線を見る → 喜ぶ → ふつう
    moods = ["normal", "surprised", "left", "right", "happy", "down", "happy2"]
    on = {
        "surprised": [(T_POPPED, T_POPPED + 1.0)],
        "left": [(T_POPPED + 1.3, T_POPPED + 1.9)],
        "right": [(T_POPPED + 1.9, T_POPPED + 2.5)],
        "happy": [(T_POPPED + 2.5, T_LEAVE + .4)],
        "down": [(T_INK0, T_INK1)],
        "happy2": [(T_INK1, T_GO0)],
    }
    eyes = []
    busy = sorted(x for v in on.values() for x in v)
    for m in moods:
        spans = on.get(m) if m != "normal" else None
        if spans is None:  # ふつうの目は、ほかの目が出ていない間だけ出す
            frames, cur = [(0, "1")], 1
            for s0, s1 in busy:
                frames += [(s0 - .01, "1", "step"), (s0, "0", "step"), (s1 - .01, "0", "step"), (s1, "1", "step")]
        else:
            frames = [(0, "0")]
            for s0, s1 in spans:
                frames += [(s0 - .01, "0", "step"), (s0, "1", "step"), (s1 - .01, "1", "step"), (s1, "0", "step")]
        name = a.kf(f"e-{m}", frames, prop="opacity")
        look = {"happy2": "happy", "down": "right"}.get(m, m)
        eyes.append(f'<g class="{name}">{art.eye(look, "blink" if m == "normal" else "")}</g>')
    body = (f'<g transform="translate(-60 -{art.FOOT})"><path d="{art.GHOST}" fill="{art.YOU["body"]}" '
            f'stroke="{art.YOU["line"]}" stroke-width="4.5" stroke-linejoin="round"/>{"".join(eyes)}</g>')
    # すきまから出てくるまでは、見出しの基準線より下を隠す
    clip = f'<clipPath id="gclip"><rect x="-50" y="-200" width="{W + 200}" height="{b1 + 200 + 1.5:.1f}"/></clipPath>'
    out.insert(0, f'<defs>{clip}</defs><g clip-path="url(#gclip)"><g class="gh"><g transform="scale({s})">{body}</g></g></g>')

    # ---- きらきら（喜ぶとき）----
    for k, (dx, dy, r) in enumerate([(-erx - 10, -14, 6), (erx + 8, -16, 7), (erx + 14, 6, 5)]):
        st = T_JOY0 + k * .18
        a.kf(f"sp{k}", [(st, "scale(0)", "out"), (st + .3, "scale(1.15)", "io"), (st + .6, "scale(.85)", "io"),
                        (st + .9, "scale(1)", "in"), (T_ER0 - .2, "scale(1)", "in"), (T_ER0, "scale(0)")],
             origin="50% 50%")
        out.append(f'<g class="sp{k}">{art.sparkle(mcx + dx, mcy + dy, r, art.OPS["click"] if k == 1 else "#F5B400")}</g>')

    out.append(hand)
    css = (f".q{{font-family:{FONT};font-size:16px;fill:{MUTED[mode]}}}"
           f".h1{{font-family:{FONT};font-size:32px;font-weight:600;fill:{ink}}}"
           f".h2{{font-family:{FONT};font-size:24px;font-weight:600;fill:{ink}}}"
           + "".join(a.css) + art.MOTION)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H:.0f}" width="{W}" height="{H:.0f}" role="img">'
            f'<title>{art.esc(ALT)}</title><style>{css}</style>{"".join(out)}</svg>')


def main():
    files = {}
    for kind in ("wide", "narrow"):
        for mode in ("light", "dark"):
            suffix = "-narrow" if kind == "narrow" else ""
            files[f"title{suffix}-{mode}.svg"] = build(kind, mode)
    print(f"wrote {art.write(files)} files to {art.OUT}")


if __name__ == "__main__":
    main()
