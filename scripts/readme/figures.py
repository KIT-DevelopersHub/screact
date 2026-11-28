"""README の本文の図（受賞の道のり・考え方・製品の仕組み・実際の画面・操作・特長・利用場面・研究・こだわり・展望・
構成図・技術・締め）を生成する。

どの図も背景を塗らず、枠線だけのカードで組む。実際の画面は docs/assets/readme/{android,desktop}/ の撮影画像を
縮めて JPEG で埋め込み、ふつうの端末の枠に入れる（YouRay の演出と、実際の画面を見た目で分ける）。
PC 版は本文欄の幅838、スマホ版は324で描き、README では原寸で表示する（文字は13px以上）。

    python scripts/readme/figures.py
"""
import base64
import io
import math
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import art  # noqa: E402
import vector  # noqa: E402
from art import OPS, PC_W, PHONE_W, YOU, card, para, text, tw  # noqa: E402

GAP = 16
SHOTS = art.ROOT / "docs" / "assets" / "readme"


def finish(W, H, b, t, alt, top=10, bottom=30, css=""):
    return art.svg(W, H + top + bottom, f'<g transform="translate(0 {top})">{"".join(b)}</g>', t, alt, css)


# ---------- アイコンのタイル ----------

def tile(kind, x, y, color, s=56):
    """角丸の正方形を色で塗り、白い線のアイコンを載せる。"""
    k = s / 56
    w = "#FFFFFF"
    line = f'fill="none" stroke="{w}" stroke-width="{3 / k:.2f}" stroke-linecap="round" stroke-linejoin="round"'
    out = [f'<rect x="{x}" y="{y}" width="{s}" height="{s}" rx="{14 * k:.1f}" fill="{color}"/>',
           f'<g transform="translate({x} {y}) scale({k:.3f})">']
    if kind == "pen":
        out.append(f'<path d="M16 40l20-20 6 6-20 20-9 3z" {line}/><path d="M32 24l6 6" {line}/>')
    elif kind == "eraser":
        out.append(f'<path d="M14 36l14-14 12 12-10 10h-10z" {line}/><path d="M24 44h20" {line}/>')
    elif kind == "click":
        out.append(f'<path d="M22 14l18 12-8 2 6 10-4 2-6-10-6 6z" fill="{w}"/>'
                   f'<path d="M14 18l-4-2M18 11l-1-4M12 25H8" {line}/>')
    elif kind == "drag":
        out.append(f'<rect x="12" y="16" width="20" height="16" rx="3" {line}/><path d="M30 36l12 8M42 36v8h-8" {line}/>')
    elif kind == "scroll":
        out.append(f'<rect x="20" y="10" width="16" height="36" rx="8" {line}/><path d="M28 18v6M24 34l4 4 4-4" {line}/>')
    elif kind == "monitor":
        out.append(f'<rect x="10" y="12" width="36" height="24" rx="3" {line}/><path d="M28 36v7M20 44h16" {line}/>')
    elif kind == "nodevice":
        out.append(f'<rect x="14" y="16" width="14" height="24" rx="3" {line}/><path d="M32 20l10 10M42 20l-10 10" {line}/>'
                   f'<path d="M8 46l40-36" stroke="{w}" stroke-width="3" stroke-linecap="round" opacity=".0"/>')
    elif kind == "anywhere":
        out.append(f'<path d="M28 46s-12-12-12-21a12 12 0 0 1 24 0c0 9-12 21-12 21z" {line}/><circle cx="28" cy="25" r="4.5" {line}/>')
    elif kind == "meeting":
        out.append(f'<circle cx="20" cy="20" r="5" {line}/><circle cx="36" cy="20" r="5" {line}/>'
                   f'<path d="M11 40c1-7 5-10 9-10s8 3 9 10M27 40c1-7 5-10 9-10s8 3 9 10" {line}/>')
    elif kind == "class":
        out.append(f'<rect x="10" y="12" width="36" height="22" rx="2" {line}/><path d="M16 28l7-7 5 4 9-8" {line}/><path d="M22 44l6-10 6 10" {line}/>')
    elif kind == "talk":
        out.append(f'<path d="M10 14h22v14H20l-6 5v-5h-4z" {line}/><path d="M36 22h10v14h-4v5l-6-5h-10v-4" {line}/>')
    elif kind == "auto":
        out.append(f'<path d="M14 24a14 14 0 0 1 28 0M19 28a9 9 0 0 1 18 0" {line}/><circle cx="28" cy="34" r="3" fill="{w}"/>'
                   f'<path d="M20 44l5 4 11-10" {line}/>')
    elif kind == "angle":
        out.append(f'<rect x="10" y="14" width="22" height="16" rx="2" {line}/><rect x="36" y="22" width="10" height="18" rx="3" transform="rotate(-20 41 31)" {line}/>'
                   f'<path d="M12 44h32" {line} stroke-dasharray="3 5"/>')
    elif kind == "smooth":
        out.append(f'<path d="M8 36l4-6 3 5 3-7 3 6" {line} opacity=".55"/><path d="M24 30c6-10 12-10 16-4s6 6 9 2" {line}/>')
    elif kind == "apps":
        out.append(f'<rect x="10" y="12" width="16" height="14" rx="3" {line}/><rect x="30" y="12" width="16" height="14" rx="3" {line}/>'
                   f'<rect x="10" y="30" width="16" height="14" rx="3" {line}/><path d="M34 32l10 6-4 1 3 5-3 1-3-5-3 3z" fill="{w}"/>')
    elif kind == "flag":
        out.append(f'<path d="M16 46V10M16 12h24l-5 8 5 8H16" {line}/>')
    elif kind == "rocket":
        out.append(f'<path d="M28 9c8 5 10 14 8 24h-16c-2-10 0-19 8-24z" {line}/><circle cx="28" cy="22" r="3.5" {line}/>'
                   f'<path d="M20 30l-6 8h6M36 30l6 8h-6M24 39l4 7 4-7" {line}/>')
    elif kind == "android":
        out.append(f'<rect x="14" y="22" width="28" height="20" rx="3" {line}/><path d="M16 22a12 12 0 0 1 24 0M20 12l3 4M36 12l-3 4" {line}/>')
    elif kind == "eye":
        out.append(f'<circle cx="28" cy="28" r="12" {line}/><circle cx="28" cy="28" r="4.5" fill="{w}"/>')
    elif kind == "chip":
        out.append(f'<rect x="16" y="16" width="24" height="24" rx="4" {line}/><path d="M22 10v6M28 10v6M34 10v6M22 40v6M28 40v6M34 40v6M10 22h6M10 28h6M10 34h6M40 22h6M40 28h6M40 34h6" {line}/>')
    elif kind == "laptop":
        out.append(f'<rect x="12" y="14" width="32" height="20" rx="3" {line}/><path d="M8 40h40" {line}/>')
    elif kind == "wave":
        out.append(f'<path d="M14 22a20 20 0 0 1 28 0M19 28a12 12 0 0 1 18 0" {line}/><circle cx="28" cy="35" r="3.5" fill="{w}"/>')
    elif kind == "grid":
        out.append(f'<path d="M12 18l32-6v32l-32-6z" {line}/><path d="M12 28h32M28 15v26" {line}/>')
    elif kind == "keys":
        out.append(f'<rect x="8" y="16" width="40" height="24" rx="4" {line}/><path d="M15 24h2M23 24h2M31 24h2M39 24h2M18 32h20" {line}/>')
    elif kind == "check":
        out.append(f'<path d="M15 29l9 9 17-19" {line}/>')
    elif kind == "apple":
        out.append(f'<path d="M28 18c-3-4-12-4-14 4s3 20 8 20c3 0 4-2 6-2s3 2 6 2c5 0 9-11 9-14-4-1-6-4-6-8 0-3 2-5 3-6-3-2-8-1-12 4z" {line}/>'
                   f'<path d="M29 15c0-3 2-6 5-6" {line}/>')
    out.append("</g>")
    return "".join(out)


# ---------- 受賞の道のり ----------
# 金沢の4人が、予選 → 本戦（大賞）→ 技育博 → 技育展の決勝へ進んだ道のりを、YouRay が駅をたどって演じる。
JOURNEY = [
    ("2026.08.09", "THE HACK 2026", "オンライン予選", "第1位で通過", OPS["click"], "badge1"),
    ("2026.08.22", "THE HACK 2026", "本戦（大阪）", "大賞", "#F5B400", "trophy"),
    ("2026.09.19", "技育博 2026", "展示", "実機で体験展示", OPS["scroll"], "booth"),
    ("2026.11.28", "技育展 2026", "決勝", "決勝で発表", OPS["drag"], "mic"),
]
JOURNEY_ALT = ("受賞・出展の記録。" + "。".join(f"{d}：{ev} {stage}・{res}" for d, ev, stage, res, _, _ in JOURNEY)
               + "。THE HACK 2026 本戦の大賞は最高賞（賞金30万円）")


def badge(kind, cx, cy, color, t):
    if kind == "trophy":
        return (f'<path d="M{cx - 9} {cy - 9}h18v5a9 9 0 0 1-18 0z" fill="{color}"/>'
                f'<path d="M{cx - 9} {cy - 7}h-4a4 4 0 0 0 4 6M{cx + 9} {cy - 7}h4a4 4 0 0 1-4 6" fill="none" stroke="{color}" stroke-width="2"/>'
                f'<rect x="{cx - 2}" y="{cy + 4}" width="4" height="4" fill="{color}"/><rect x="{cx - 6}" y="{cy + 8}" width="12" height="3" rx="1.5" fill="{color}"/>')
    if kind == "badge1":
        return (f'<circle cx="{cx}" cy="{cy}" r="10" fill="{color}"/>'
                + text(cx, cy + 4.5, "1", 13, "#FFFFFF", weight=800, anchor="middle"))
    if kind == "booth":
        return (f'<rect x="{cx - 10}" y="{cy - 8}" width="20" height="13" rx="2" fill="none" stroke="{color}" stroke-width="2.2"/>'
                f'<path d="M{cx - 4} {cy + 9}h8M{cx} {cy + 5}v4" stroke="{color}" stroke-width="2.2" stroke-linecap="round"/>')
    return (f'<rect x="{cx - 4}" y="{cy - 11}" width="8" height="14" rx="4" fill="{color}"/>'
            f'<path d="M{cx - 8} {cy - 1}a8 8 0 0 0 16 0M{cx} {cy + 7}v4" fill="none" stroke="{color}" stroke-width="2" stroke-linecap="round"/>')


def journey(t, narrow=False):
    """駅をつないだ道のり。YouRay が駅を1つずつ進み、駅に着くたびに札が光る。"""
    css = []
    DUR = 16.0
    stops = [1.0, 4.2, 7.4, 10.6]  # 各駅に着く時刻（秒）

    def pct(s):
        return f"{s / DUR * 100:.3f}%"

    b = []
    if narrow:
        W = PHONE_W
        y0, gapy = 40, 92
        pts = [(62, y0 + k * gapy) for k in range(4)]
        H = pts[-1][1] + 54
        b.append(f'<path d="M62 {y0}V{pts[-1][1]}" stroke="{t["line"]}" stroke-width="4" stroke-linecap="round"/>')
        lit = f'<path d="M62 {y0}V{pts[-1][1]}" stroke="url(#brandv)" stroke-width="4" stroke-linecap="round" class="jl" pathLength="1" stroke-dasharray="1 1"/>'
    else:
        W = PC_W
        y0 = 142
        xs = [84 + k * (W - 168) / 3 for k in range(4)]
        pts = [(x, y0) for x in xs]
        H = 258
        b.append(f'<path d="M{xs[0]} {y0}H{xs[-1]}" stroke="{t["line"]}" stroke-width="4" stroke-linecap="round"/>')
        lit = f'<path d="M{xs[0]} {y0}H{xs[-1]}" stroke="url(#brand)" stroke-width="4" stroke-linecap="round" class="jl" pathLength="1" stroke-dasharray="1 1"/>'
    b.append(lit)
    # 線の伸び：駅に着くたびに次の区間まで光る
    frames = ["0%{stroke-dashoffset:1}"]
    for k in range(1, 4):
        frames += [f"{pct(stops[k - 1] + .5)}{{stroke-dashoffset:{1 - (k - 1) / 3:.4f}}}", f"{pct(stops[k])}{{stroke-dashoffset:{1 - k / 3:.4f}}}"]
    frames += [f"{pct(14.6)}{{stroke-dashoffset:0}}", f"{pct(15.4)}{{stroke-dashoffset:1}}", "100%{stroke-dashoffset:1}"]
    css.append(f"@keyframes jl{{{''.join(frames)}}}.jl{{animation:jl {DUR}s ease-in-out infinite}}")
    for k, ((d, ev, stage, res, color, kind), (x, y)) in enumerate(zip(JOURNEY, pts)):
        big = kind == "trophy"
        r = 15 if big else 11
        b.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{t["page"]}" stroke="{t["line"]}" stroke-width="3"/>')
        b.append(f'<g class="js{k}"><circle cx="{x}" cy="{y}" r="{r}" fill="{t["page"]}" stroke="{color}" stroke-width="3.5"/>'
                 f'<circle cx="{x}" cy="{y}" r="{r - 6}" fill="{color}"/></g>')
        on = stops[k]
        css.append(f"@keyframes js{k}{{0%,{pct(on - .01)}{{opacity:0}}{pct(on)},{pct(15.2)}{{opacity:1}}{pct(15.6)},100%{{opacity:0}}}}"
                   f".js{k}{{animation:js{k} {DUR}s linear infinite}}")
        if narrow:
            tx = 98
            b += [text(tx, y - 20, d, 13, t["muted"], weight=600, extra=' letter-spacing="1"'),
                  text(tx, y + 2, f"{ev}", 16, t["ink"], weight=700),
                  text(tx, y + 23, f"{stage}・{res}", 14 if not big else 15, color if big else t["muted"], weight=700 if big else 600)]
            bx, by = W - 26, y
        else:
            b += [text(x, y - 96, d, 13, t["muted"], weight=600, anchor="middle", extra=' letter-spacing="1"'),
                  text(x, y - 74, ev, 15, t["ink"], weight=700, anchor="middle"),
                  text(x, y + 44, stage, 14, t["muted"], weight=600, anchor="middle"),
                  text(x, y + 70, res, 22 if big else 16, color if big else t["ink"], weight=800 if big else 700, anchor="middle")]
            bx, by = x, y - 24 - 6
        if narrow:
            b.append(badge(kind, bx, by, color, t))
        else:
            b.append(badge(kind, x + (36 if big else 30), y - 4, color, t))
        if big:  # 大賞の駅では、着いた瞬間にきらきらが弾ける
            sp = "".join(art.sparkle(x + dx, y + dy, rr, c) for dx, dy, rr, c in
                         [(-24, -18, 6, "#F5B400"), (26, 16, 5, OPS["draw"]), (-20, 20, 4, OPS["click"])])
            b.append(f'<g class="jsp">{sp}</g>')
            css.append(f"@keyframes jsp{{0%,{pct(on - .01)}{{opacity:0;transform:scale(.3)}}{pct(on + .3)}{{opacity:1;transform:scale(1.15)}}"
                       f"{pct(on + .6)},{pct(15.2)}{{opacity:1;transform:scale(1)}}{pct(15.6)},100%{{opacity:0;transform:scale(.3)}}}}"
                       f".jsp{{animation:jsp {DUR}s ease-out infinite;transform-box:fill-box;transform-origin:center}}")
    # YouRay：駅から駅へ、ふわっと跳んで進む
    s = .3 if narrow else .34
    frames = []
    first = pts[0]
    frames.append(("0%", first, 0, "1"))
    for k, (x, y) in enumerate(pts):
        on = stops[k]
        if k > 0:
            px, py = pts[k - 1]
            mx, my = (px + x) / 2, (py + y) / 2
            frames.append((pct(on - 1.6), (px, py), 0, "1"))
            hop = (mx - 14, my) if narrow else (mx, my - 20)
            frames.append((pct(on - .8), hop, -8 if not narrow else 0, "1"))
        frames.append((pct(on), (x, y), 0, "1"))
    frames += [(pct(14.4), pts[-1], 0, "1"), (pct(15.2), pts[-1], 0, "0"), (pct(15.3), first, 0, "0"), ("100%", first, 0, "1")]
    gy = -14 if not narrow else 0
    gx = 0 if not narrow else -38
    body = "".join(f"{p}{{transform:translate({q[0] + gx:.1f}px,{q[1] + gy - (0 if narrow else 4):.1f}px) rotate({r}deg);opacity:{o}}}" for p, q, r, o in frames)
    css.append(f"@keyframes jy{{{body}}}.jy{{animation:jy {DUR}s cubic-bezier(.45,0,.55,1) infinite}}")
    b.append(f'<g class="jy"><g transform="scale({s})"><g class="float">{art.ghost()}</g></g></g>')
    defs = ('<defs><linearGradient id="brandv" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#A06BFF"/>'
            '<stop offset=".55" stop-color="#7A7EF0"/><stop offset="1" stop-color="#3DB5C8"/></linearGradient></defs>')
    css.append("@media (prefers-reduced-motion:reduce){.jy{opacity:0}.jl{stroke-dashoffset:0}.js0,.js1,.js2,.js3,.jsp{opacity:1}}")
    return art.svg(W, H, defs + card(0, 0, W, H, t, rx=18) + "".join(b), t, JOURNEY_ALT, "".join(css))


# ---------- 冒頭の誘導 ----------

def video_cta(t, narrow=False):
    W, H = (PHONE_W, 60) if narrow else (PC_W, 60)
    c = OPS["drag"]
    b = [card(0, 0, W, H, t, rx=12),
         f'<circle cx="34" cy="{H / 2}" r="17" fill="url(#brand)"/>',
         f'<path d="M29 {H / 2 - 7.5}L41 {H / 2}L29 {H / 2 + 7.5}Z" fill="#FFFFFF" stroke="#FFFFFF" stroke-width="2" stroke-linejoin="round"/>',
         text(64, 27, "デモ動画を見る", 16, t["ink"], weight=700),
         text(64, 46, "Google Driveで再生します（約33秒）", 13, t["muted"], weight=600),
         f'<path d="M{W - 28} {H / 2 - 7}l7 7-7 7" fill="none" stroke="{t["muted"]}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>']
    del c
    return art.svg(W, H, "".join(b), t, "デモ動画を見る（Google Drive・約33秒）")


# ---------- 01 背景：考え方 ----------
MESSAGE = ("情報を映す画面から、\n情報と関わる画面へ。",
           "普通のモニターやマウスでも、説明や会議は成り立ちます。Screactは、そこに「画面を直接さわって動かす」体験を足し、"
           "指し示す・書き込む・動かすを、話しながらその場でできるようにします。")


def message(t, narrow=False):
    W = PHONE_W if narrow else PC_W
    size, lh = (20, 30) if narrow else (28, 40)
    q = 40 if narrow else 56
    tx = q + 10
    b = [text(0, q * 1.05, "“", q * 1.7, "url(#brand)", cls="disp", weight=400)]
    s1, n1 = para(tx, size + 8, MESSAGE[0], size, t["ink"], W - tx - 14, lh, 800)
    y = size + 8 + (n1 - 1) * lh + 22
    b.append(f'<rect x="{tx}" y="{y}" width="56" height="4" rx="2" fill="url(#brand)"/>')
    s2, n2 = para(tx, y + 34, MESSAGE[1], 15, t["muted"], W - tx - 14, 25, 600)
    b += [s1, s2]
    H = y + 34 + (n2 - 1) * 25 + 8
    if not narrow:  # 右上で YouRay が画面を見上げる
        b.append(art.youray(W - 60, 86, .5, delay=.4))
    return finish(W, H, b, t, MESSAGE[0].replace("\n", "") + MESSAGE[1], top=18, bottom=34)


# ---------- 02 製品説明：見る → 送る → 応える ----------
ROLES = [("eye", OPS["scroll"], "STEP 1", "スマホが「見る」", "画面の横に置いたスマホのカメラが、手指の21点と画面の四隅を、端末の中で認識します。"),
         ("wave", OPS["click"], "STEP 2", "PCへ「送る」", "カメラの映像ではなく、座標と状態だけを、同じLANのPCへリアルタイムに送ります。"),
         ("apps", OPS["drag"], "STEP 3", "画面が「応える」", "PCが座標を画面に合わせ、手の形を操作に変えて、いつものアプリを動かします。")]


def roles(t, narrow=False):
    b = []
    if narrow:
        W, pad = PHONE_W, 18
        y = 0
        for k, (icon, c, step, title, body) in enumerate(ROLES):
            s2, n2 = para(pad, 92, body, 14, t["muted"], W - 2 * pad, 22)
            h = 92 + (n2 - 1) * 22 + 22
            b += [card(0, y, W, h, t), f'<g transform="translate(0 {y})">', tile(icon, pad, 18, c, 48),
                  art.pill(pad + 62, 20, step, c, 13, h=22)[0], text(pad + 62, 64, title, 17, t["ink"], weight=700), s2, "</g>"]
            y += h
            if k < 2:
                b.append(f'<path d="M{W / 2 - 7} {y + 6}l7 7 7-7" fill="none" stroke="url(#brand)" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>')
                y += 22
        H = y
    else:
        W, pad = PC_W, 20
        arrow = 28
        colw = (W - 2 * arrow) / 3
        parts = [para(pad, 128, body, 14, t["muted"], colw - 2 * pad, 22) for *_, body in ROLES]
        H = 128 + max(n for _, n in parts) * 22 + 8
        for k, ((icon, c, step, title, _), (s2, _)) in enumerate(zip(ROLES, parts)):
            x = k * (colw + arrow)
            b += [card(x, 0, colw, H, t), f'<g transform="translate({x:.1f} 0)">', tile(icon, pad, 20, c, 52),
                  art.pill(colw - pad - tw("STEP 1", 13) - 20, 34, step, c, 13, h=22)[0],
                  text(pad, 102, title, 18, t["ink"], weight=700), s2, "</g>"]
            if k < 2:
                ax = x + colw + arrow / 2
                b.append(f'<path d="M{ax - 4} {H / 2 - 8}l8 8-8 8" fill="none" stroke="url(#brand)" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>')
    alt = "製品の仕組み。" + "。".join(f"{step}：{title}。{body}" for _, _, step, title, body in ROLES)
    return finish(W, H, b, t, alt)


# ---------- 02 実際の画面 ----------
_cache = {}


def shot(rel, w):
    key = (rel, w)
    if key not in _cache:
        im = Image.open(SHOTS / rel).convert("RGB")
        ratio = im.width / im.height
        im = im.resize((w, round(w / ratio)), Image.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=84, optimize=True, progressive=True)
        _cache[key] = ("data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode(), ratio)
    return _cache[key]


_clip = [0]


def device(rel, x, y, w, t, kind):
    """ふつうの端末の枠（モニターまたは横持ちのスマホ）に、実際の画面を入れる。(svg, 高さ) を返す。"""
    uri, ratio = shot(rel, min(1000, round(w * 2)))
    edge = "#4A5062" if t is art.THEMES["dark"] else "#2A2E38"
    _clip[0] += 1
    cid = f"dv{_clip[0]}"
    if kind == "phone":
        bz = max(5.0, w * .028)
        sw, sh = w - 2 * bz, (w - 2 * bz) / ratio
        h = sh + 2 * bz
        return (f'<rect x="{x}" y="{y}" width="{w}" height="{h:.1f}" rx="{h * .16:.1f}" fill="#16181F" stroke="{edge}" stroke-width="1.2"/>'
                f'<clipPath id="{cid}"><rect x="{x + bz}" y="{y + bz}" width="{sw:.1f}" height="{sh:.1f}" rx="{h * .11:.1f}"/></clipPath>'
                f'<image clip-path="url(#{cid})" x="{x + bz}" y="{y + bz}" width="{sw:.1f}" height="{sh:.1f}" preserveAspectRatio="xMidYMid slice" href="{uri}"/>'
                f'<circle cx="{x + w - bz * .55:.1f}" cy="{y + h / 2:.1f}" r="{bz * .28:.1f}" fill="#3A3F52"/>'), h
    bz = max(6.0, w * .02)
    sw, sh = w - 2 * bz, (w - 2 * bz) / ratio
    h = sh + 2 * bz
    stand = (f'<path d="M{x + w / 2 - 22} {y + h + 22}h44l-6-22h-32z" fill="{t["stand"]}"/>'
             f'<rect x="{x + w / 2 - 44}" y="{y + h + 20}" width="88" height="5" rx="2.5" fill="{t["stand"]}"/>')
    return (stand + f'<rect x="{x}" y="{y}" width="{w}" height="{h:.1f}" rx="10" fill="#16181F" stroke="{edge}" stroke-width="1.2"/>'
            f'<clipPath id="{cid}"><rect x="{x + bz}" y="{y + bz}" width="{sw:.1f}" height="{sh:.1f}" rx="4"/></clipPath>'
            f'<image clip-path="url(#{cid})" x="{x + bz}" y="{y + bz}" width="{sw:.1f}" height="{sh:.1f}" preserveAspectRatio="xMidYMid slice" href="{uri}"/>'), h + 25


SCREENS = [("desktop/04-calibration-target.jpg", "monitor", "PC", "位置合わせ", "画面の四隅にArUcoマーカーを出す"),
           ("android/android-tracking.jpg", "phone", "スマホ", "手の追跡", "手指の21点を追い、座標と状態を送る")]


def caption(x, y, who, title, sub, t, color, anchor="start"):
    pill, pw = art.pill(x if anchor == "start" else x - (tw(who, 13) + 20) / 2, y, who, color, 13, h=22)
    return (pill + text(x if anchor == "start" else x, y + 46, title, 16, t["ink"], weight=700, anchor=anchor)
            + text(x, y + 68, sub, 13, t["muted"], weight=600, anchor=anchor))


def screens(t, narrow=False):
    b = []
    (m_rel, _, mwho, mtitle, msub), (p_rel, _, pwho, ptitle, psub) = SCREENS
    if narrow:
        W = PHONE_W
        s1, h1 = device(m_rel, 20, 0, W - 40, t, "monitor")
        y = h1 + 14
        b += [s1, caption(W / 2, y, mwho, mtitle, msub, t, OPS["click"], "middle")]
        y += 96
        s2, h2 = device(p_rel, 0, y, W, t, "phone")
        b += [s2, caption(W / 2, y + h2 + 14, pwho, ptitle, psub, t, OPS["scroll"], "middle")]
        H = y + h2 + 14 + 76
    else:
        W = PC_W
        mw = 400
        s1, h1 = device(m_rel, 0, 0, mw, t, "monitor")
        pw = W - mw - 40
        s2, h2 = device(p_rel, mw + 40, 40, pw, t, "phone")
        b += [s1, s2]
        cy = max(h1, 40 + h2) + 16
        b += [caption(mw / 2, cy, mwho, mtitle, msub, t, OPS["click"], "middle"),
              caption(mw + 40 + pw / 2, cy, pwho, ptitle, psub, t, OPS["scroll"], "middle")]
        H = cy + 76
    alt = f"実際の画面。{mwho}：{mtitle}（{msub}）。{pwho}：{ptitle}（{psub}）"
    return finish(W, H, b, t, alt)


# ---------- 03 できること ----------
GESTURES = [("pen", "draw", "描く・消す", "DRAW", [("描く", "人差し指と中指をくっつけて動かす"), ("消す", "手をグーにして動かす")],
             "透明なオーバーレイに描くので、ブラウザやスライドを隠しません"),
            ("click", "click", "クリック・選択", "CLICK", [("", "親指と人差し指をつまむ")], "OSの実際のクリックとして、いつものアプリに届きます"),
            ("drag", "drag", "掴む（ドラッグ）", "DRAG", [("", "つまんだまま動かす")], "ファイルや付箋、ウィンドウを、つまんで運びます"),
            ("scroll", "scroll", "スクロール", "SCROLL", [("", "グッドサイン（親指だけを立てる）")], "親指を向けた方向へ、縦にも横にもスクロールします")]
GESTURE_NOTE = "人差し指を動かすとポインターが動きます。各操作は設定画面で1つずつ有効・無効を切り替えられます。"


def how_lines(x, y, hows, t, avail, color):
    out, n = [], 0
    for label, how in hows:
        if label:
            pw = art.tw(label, 12) + 16
            out.append(f'<rect x="{x}" y="{y + n * 21 - 15}" width="{pw:.1f}" height="20" rx="10" fill="none" stroke="{color}" stroke-width="1.4"/>'
                       + text(x + pw / 2, y + n * 21 - 1, label, 12.5, color, weight=700, anchor="middle"))
            s1, k = para(x + pw + 8, y + n * 21, how, 14, t["ink"], avail - pw - 8, 21, 700)
        else:
            s1, k = para(x, y + n * 21, how, 14, t["ink"], avail, 21, 700)
        out.append(s1)
        n += k + (0.35 if label else 0)
    return "".join(out), n


def gestures(t, narrow=False):
    b = []
    if narrow:
        W, pad = PHONE_W, 16
        y = 0
        for icon, op, jp, en, hows, note in GESTURES:
            s1, n1 = how_lines(pad, 82, hows, t, W - 2 * pad, OPS[op])
            s2, n2 = para(pad, 82 + n1 * 21 + 6, note, 13, t["muted"], W - 2 * pad, 20, 600)
            h = 82 + n1 * 21 + 6 + (n2 - 1) * 20 + 20
            b += [card(0, y, W, h, t), f'<g transform="translate(0 {y})">',
                  f'<rect x="{pad}" y="0" width="{W - 2 * pad}" height="3" rx="1.5" fill="{OPS[op]}"/>',
                  tile(icon, pad, 16, OPS[op], 40), text(pad + 54, 42, jp, 17, t["ink"], weight=700),
                  text(W - pad, 40, en, 13, OPS[op], weight=700, anchor="end", extra=' letter-spacing="2"'), s1, s2, "</g>"]
            y += h + 10
        H = y - 10
    else:
        W, pad = PC_W, 18
        n = len(GESTURES)
        g = 12
        colw = (W - g * (n - 1)) / n
        parts = []
        for icon, op, jp, en, hows, note in GESTURES:
            s1, n1 = how_lines(pad, 132, hows, t, colw - 2 * pad, OPS[op])
            s2, n2 = para(pad, 132 + n1 * 21 + 8, note, 13, t["muted"], colw - 2 * pad, 20, 600)
            parts.append((s1, s2, 132 + n1 * 21 + 8 + (n2 - 1) * 20 + 22))
        H = max(p[2] for p in parts)
        for k, ((icon, op, jp, en, _, _), (s1, s2, _)) in enumerate(zip(GESTURES, parts)):
            x = k * (colw + g)
            b += [card(x, 0, colw, H, t), f'<g transform="translate({x:.1f} 0)">',
                  f'<rect x="{pad}" y="0" width="{colw - 2 * pad:.1f}" height="3" rx="1.5" fill="{OPS[op]}"/>',
                  tile(icon, pad, 22, OPS[op], 48),
                  text(colw - pad, 40, en, 13, OPS[op], weight=700, anchor="end", extra=' letter-spacing="2"'),
                  text(pad, 102, jp, 18, t["ink"], weight=700), s1, s2, "</g>"]
    alt = "できること。" + "。".join(f"{jp}：" + "、".join(f"{lb}は{how}" if lb else how for lb, how in hows) + f"（{note}）"
                                    for _, _, jp, _, hows, note in GESTURES) + "。ポインター：人差し指を動かすと動く。設定：各操作は設定画面で1つずつ有効・無効を切り替えられる"
    return finish(W, H, b, t, alt)


# ---------- 04 特長 ----------
FEATURES = [("monitor", OPS["click"], "今ある画面を、\nそのまま使う",
             "教室・会議室・店舗にあるモニターやプロジェクターを、買い替えずに使います。タッチ対応の画面へ入れ替える必要はありません。"),
            ("nodevice", OPS["drag"], "専用の機器が\nいらない",
             "赤外線カメラやセンサー、電子ペンは使いません。誰もが持っているスマホとPCに、アプリを入れるだけで始められます。"),
            ("anywhere", OPS["scroll"], "いつでも、\nどこでも",
             "スマホを持ち運べば、その場の画面が操作できる画面になります。スマホは斜めに置いても位置を合わせられます。")]


def features(t, narrow=False):
    b = []
    if narrow:
        W, pad = PHONE_W, 18
        y = 0
        for k, (icon, c, title, body) in enumerate(FEATURES):
            s1, n1 = para(pad + 62, 30, title, 16, t["ink"], W - pad * 2 - 62 - 26, 23, 700)
            top = max(24 + n1 * 24, 66) + 12
            s2, n2 = para(pad, top + 16, body, 14, t["muted"], W - pad * 2, 22)
            h = top + 16 + (n2 - 1) * 22 + 22
            b += [card(0, y, W, h, t), f'<g transform="translate(0 {y})">', tile(icon, pad, 18, c, 48),
                  art.number(W - pad, 40, f"{k + 1:02d}", 26, "end"), s1, s2, "</g>"]
            y += h + 12
        H = y - 12
    else:
        W, pad = PC_W, 22
        colw = (W - 2 * GAP) / 3
        parts = []
        for icon, c, title, body in FEATURES:
            s1, n1 = para(pad, 104, title, 17, t["ink"], colw - pad * 2, 25, 700)
            s2, n2 = para(pad, 104 + n1 * 25 + 14, body, 14, t["muted"], colw - pad * 2, 23)
            parts.append((s1, s2, 104 + n1 * 25 + 14 + (n2 - 1) * 23 + 24))
        H = max(h for _, _, h in parts)
        for k, ((icon, c, _, _), (s1, s2, _)) in enumerate(zip(FEATURES, parts)):
            x = k * (colw + GAP)
            b += [card(x, 0, colw, H, t), f'<g transform="translate({x:.1f} 0)">', tile(icon, pad, 22, c),
                  art.number(colw - pad, 52, f"{k + 1:02d}", 30, "end"), s1, s2, "</g>"]
    alt = "特長。" + "。".join(f"{k + 1}：{title.replace(chr(10), '')}。{body}" for k, (_, _, title, body) in enumerate(FEATURES))
    return finish(W, H, b, t, alt)


# ---------- 04 特長：専用の機器との比べ ----------
COMPARE = [("画面", "タッチ対応の画面へ買い替える", "今あるモニター・プロジェクターを使う"),
           ("追加の機器", "赤外線カメラ・センサー・電子ペンなど", "いらない（手元のスマホとPCだけ）"),
           ("導入", "設置の工事や設定", "アプリを入れるだけ"),
           ("場所", "設置した場所に固定", "スマホを持ち運べば、どこでも")]


def compare(t, narrow=False):
    b = []
    if narrow:
        W, pad = PHONE_W, 16
        y = 0
        b.append(text(0, 16, "専用の機器を入れる場合と比べて", 14, t["muted"], weight=700))
        y = 30
        for k, (row, old, new) in enumerate(COMPARE):
            s1, n1 = para(pad, 56, old, 13, t["muted"], W - 2 * pad - 20, 19, 600)
            s2, n2 = para(pad + 20, 56 + n1 * 19 + 10, new, 15, t["ink"], W - 2 * pad - 20, 22, 700)
            h = 56 + n1 * 19 + 10 + (n2 - 1) * 22 + 18
            b += [card(0, y, W, h, t), f'<g transform="translate(0 {y})">', text(pad, 30, row, 13, t["muted"], weight=700, extra=' letter-spacing="1"'),
                  f'<path d="M{pad} {56 + n1 * 19 + 4}l8 0" stroke="none"/>',
                  f'<path d="M{pad + 1} {56 + n1 * 19 + 4}l6 6 6-6" fill="none" stroke="url(#brand)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" transform="rotate(-90 {pad + 7} {56 + n1 * 19 + 7})"/>',
                  s1, s2, "</g>"]
            y += h + 8
        H = y - 8
    else:
        W = PC_W
        c0, c1 = 150, 330
        rh = 50
        H = 46 + rh * len(COMPARE)
        b += [card(0, 0, W, H, t),
              f'<rect x="{c0 + c1}" y="1.5" width="{W - c0 - c1 - 1.5}" height="{H - 3}" rx="0" fill="url(#brand)" opacity=".08"/>',
              text(c0 + 20, 30, "専用の機器を入れる", 14, t["muted"], weight=700),
              text(c0 + c1 + 20, 30, "Screact", 15, "url(#brand)", weight=800),
              f'<rect x="0" y="44" width="{W}" height="1.5" fill="{t["line"]}"/>']
        for k, (row, old, new) in enumerate(COMPARE):
            y = 46 + k * rh
            if k:
                b.append(f'<rect x="16" y="{y}" width="{W - 32}" height="1" fill="{t["line"]}"/>')
            b += [text(20, y + 31, row, 14, t["ink"], weight=700),
                  text(c0 + 20, y + 31, old, 14, t["muted"], weight=600),
                  text(c0 + c1 + 20, y + 31, new, 15, t["ink"], weight=700)]
    alt = "専用の機器を入れる場合との比べ。" + "。".join(f"{row}：専用の機器は{old}、Screactは{new}" for row, old, new in COMPARE)
    return finish(W, H, b, t, alt)


# ---------- 05 利用場面 ----------
SCENES = [("meeting", OPS["click"], "会議・共同作業", "MEETING", "情報を動かしながら、\n一緒に考える。",
           "注目している箇所や意図を、その場で共有できます。画面を囲んだ全員が、対話や共同作業に加わりやすくなります。"),
          ("class", OPS["draw"], "授業・プレゼン", "CLASS", "説明・身振り・操作が\nひとつになる。",
           "説明する人は画面の前から離れず、伝えることに集中できます。聞く人も、どこを見ればよいかをつかみやすくなります。"),
          ("talk", OPS["scroll"], "接客・相談・提案", "CONSULTING", "同じ情報を指しながら\n対話する。",
           "相手の反応や質問に合わせて、その場で書き込みながら説明できます。")]


def scenes(t, narrow=False):
    b = []
    if narrow:
        W, pad = PHONE_W, 18
        y = 0
        for icon, c, jp, en, lead, body in SCENES:
            s1, n1 = para(pad, 92, lead, 16, t["ink"], W - 2 * pad, 24, 700)
            s2, n2 = para(pad, 92 + n1 * 24 + 8, body, 14, t["muted"], W - 2 * pad, 22)
            h = 92 + n1 * 24 + 8 + (n2 - 1) * 22 + 22
            b += [card(0, y, W, h, t), f'<g transform="translate(0 {y})">', tile(icon, pad, 18, c, 44),
                  text(pad + 58, 34, en, 13, c, weight=700, extra=' letter-spacing="2"'), text(pad + 58, 56, jp, 17, t["ink"], weight=700),
                  f'<rect x="{pad}" y="72" width="40" height="3" rx="1.5" fill="{c}"/>', s1, s2, "</g>"]
            y += h + 12
        H = y - 12
    else:
        W, pad = PC_W, 22
        colw = (W - 2 * GAP) / 3
        parts = []
        for *_, lead, body in SCENES:
            s1, n1 = para(pad, 126, lead, 16, t["ink"], colw - 2 * pad, 24, 700)
            s2, n2 = para(pad, 126 + n1 * 24 + 10, body, 14, t["muted"], colw - 2 * pad, 22)
            parts.append((s1, s2, 126 + n1 * 24 + 10 + (n2 - 1) * 22 + 24))
        H = max(p[2] for p in parts)
        for k, ((icon, c, jp, en, _, _), (s1, s2, _)) in enumerate(zip(SCENES, parts)):
            x = k * (colw + GAP)
            b += [card(x, 0, colw, H, t), f'<g transform="translate({x:.1f} 0)">', tile(icon, pad, 22, c),
                  text(colw - pad, 40, en, 13, c, weight=700, anchor="end", extra=' letter-spacing="2"'),
                  text(pad, 100, jp, 19, t["ink"], weight=700), s1, s2, "</g>"]
    alt = "利用場面。" + "。".join(f"{jp}：{lead.replace(chr(10), '')}{body}" for _, _, jp, _, lead, body in SCENES)
    return finish(W, H, b, t, alt)


# ---------- 06 直接操作の価値 ----------
STATS = [("35", "%", "短い", "高齢者の操作時間が\nマウスより", "タッチスクリーンとマウスの比較 [1]"),
         ("16", "%", "短い", "若年者の操作時間が\nマウスより", "タッチスクリーンとマウスの比較 [1]"),
         ("両手", "", "", "両手を使う作業では\n直接タッチが有利", "テーブル型ディスプレイでの比較 [2]")]
STATS_NOTE = "先行研究の結果であり、Screact自体で測った効果ではありません。"


def big(x, y, num, unit, size, anchor="start"):
    if num.isascii():
        w = vector.width(num, size)
        s = text(x, y, num, size, "url(#brand)", cls="disp", weight=400, anchor=anchor)
        if unit:
            s += text(x + w + 2 if anchor == "start" else x + 2, y, unit, size * .5, "url(#brand)", cls="disp", weight=400)
        return s
    return text(x, y - size * .06, num, size * .8, "url(#brand)", cls="jp", weight=900, anchor=anchor)


def stats(t, narrow=False):
    b = []
    if narrow:
        W, pad = PHONE_W, 18
        y = 0
        for num, unit, word, q, src in STATS:
            s1, n1 = para(124, 34, q.replace("\n", "") + (f"約{num}{unit}{word}" if word else ""), 15, t["ink"], W - 124 - pad, 22, 700)
            h = max(34 + n1 * 22 + 4 + 20, 82)
            b += [card(0, y, W, h, t), f'<g transform="translate(0 {y})">', big(pad, 58, num, unit, 44), s1,
                  text(124, 34 + n1 * 22 + 6, src, 13, t["muted"], weight=600), "</g>"]
            y += h + 10
        H = y - 10
    else:
        W, pad = PC_W, 22
        colw = (W - 2 * GAP) / 3
        parts = [para(pad, 110, q + (f"約{num}{unit}{word}" if word else ""), 15, t["ink"], colw - 2 * pad, 22, 700) for num, unit, word, q, _ in STATS]
        nmax = max(n for _, n in parts)
        H = 110 + nmax * 22 + 30
        for k, ((num, unit, _, _, src), (s1, _)) in enumerate(zip(STATS, parts)):
            x = k * (colw + GAP)
            b += [card(x, 0, colw, H, t), f'<g transform="translate({x:.1f} 0)">', big(pad, 78, num, unit, 60), s1,
                  text(pad, H - 22, src, 13, t["muted"], weight=600), "</g>"]
    alt = "直接操作の価値（先行研究）。" + "。".join(f"{q.replace(chr(10), '')}{('約' + num + unit + word) if word else ''}（{src}）" for num, unit, word, q, src in STATS) + "。注意：" + STATS_NOTE
    return finish(W, H, b, t, alt)


# ---------- 07 注力したこと ----------
FOCUS = [("auto", OPS["click"], "導入の手軽さ", "ユーザー操作は最小限",
          "PCがUDPで居場所を知らせ、スマホが見つけて自動で接続します。位置合わせも、画面の四隅のマーカーを読むだけで終わります。",
          ["UDP自動発見", "WebSocket", "手動接続も用意"]),
         ("angle", OPS["scroll"], "設置の自由度", "スマホは斜めからでもOK",
          "4つのマーカーからホモグラフィ（射影変換）を求め、斜めから見た座標を画面の座標へ補正します。説明者や聞き手の邪魔になりません。",
          ["ArUco", "Homography"]),
         ("smooth", OPS["drag"], "操作性", "直感的なジェスチャーと滑らかさ",
          "止めていても揺れる指先を、One-Euro Filterで落ち着かせつつ、動き出しの速さは保ちます。判定は行き来の幅を持たせ、線の途切れを防ぎます。",
          ["One-Euro Filter", "ヒステリシス", "安全な解除"]),
         ("apps", OPS["draw"], "汎用性", "実カーソル入力で、どのアプリでも",
          "OSの実際の入力としてクリック・ドラッグ・スクロールを送ります。描画はクリック透過のオーバーレイに重ね、普段のアプリをそのまま使えます。",
          ["CGEvent", "SendInput", "透明オーバーレイ"])]


def chips(x, y, labels, color, t, avail, h=26):
    out, cx, cy = [], x, y
    for label in labels:
        w = tw(label, 13) + 34
        if cx > x and cx + w > x + avail:
            cx, cy = x, cy + h + 8
        out.append(f'<rect x="{cx + .5}" y="{cy + .5}" width="{w - 1:.1f}" height="{h - 1}" rx="{h / 2}" fill="none" stroke="{color}" stroke-width="1.5"/>'
                   f'<circle cx="{cx + 13}" cy="{cy + h / 2}" r="4.5" fill="{color}"/>'
                   + text(cx + 24, cy + h / 2 + 4.7, label, 13, t["ink"], weight=600))
        cx += w + 8
    return "".join(out), cy + h - y


def focus(t, narrow=False):
    b = []
    if narrow:
        W, pad = PHONE_W, 18
        y = 0
        for k, (icon, c, title, lead, body, tags) in enumerate(FOCUS):
            s2, n2 = para(pad, 104, body, 14, t["muted"], W - 2 * pad, 22)
            ch, chh = chips(pad, 104 + (n2 - 1) * 22 + 16, tags, c, t, W - 2 * pad)
            h = 104 + (n2 - 1) * 22 + 16 + chh + 20
            b += [card(0, y, W, h, t), f'<g transform="translate(0 {y})">', tile(icon, pad, 18, c, 44),
                  art.number(W - pad, 44, f"{k + 1:02d}", 28, "end"),
                  text(pad + 58, 36, title, 17, t["ink"], weight=700), text(pad + 58, 56, lead, 13, c, weight=700),
                  f'<rect x="{pad}" y="76" width="3" height="10" rx="1.5" fill="none"/>', s2, ch, "</g>"]
            y += h + 12
        H = y - 12
    else:
        W, pad = PC_W, 22
        colw = (W - GAP) / 2
        rows = []
        for icon, c, title, lead, body, tags in FOCUS:
            s2, n2 = para(pad, 102, body, 14, t["muted"], colw - 2 * pad, 22)
            ch, chh = chips(pad, 102 + (n2 - 1) * 22 + 18, tags, c, t, colw - 2 * pad)
            rows.append((s2, ch, 102 + (n2 - 1) * 22 + 18 + chh + 22))
        hs = [max(rows[0][2], rows[1][2]), max(rows[2][2], rows[3][2])]
        y = 0
        for k, ((icon, c, title, lead, _, _), (s2, ch, _)) in enumerate(zip(FOCUS, rows)):
            x = (k % 2) * (colw + GAP)
            y = 0 if k < 2 else hs[0] + GAP
            h = hs[k // 2]
            b += [card(x, y, colw, h, t), f'<g transform="translate({x:.1f} {y})">', tile(icon, pad, 22, c),
                  art.number(colw - pad, 54, f"{k + 1:02d}", 34, "end"),
                  text(pad + 72, 44, title, 19, t["ink"], weight=700), text(pad + 72, 68, lead, 14, c, weight=700),
                  s2, ch, "</g>"]
        H = hs[0] + GAP + hs[1]
    alt = "注力したこと。" + "。".join(f"{k + 1}：{title}（{lead}）。{body}" for k, (_, _, title, lead, body, _) in enumerate(FOCUS))
    return finish(W, H, b, t, alt)


# ---------- 08 今後の展望 ----------
ROADMAP = [("NOW", "まず", "rocket", "使い続けられる品質へ",
            "通信環境によるカクつきや、意図しない描画を減らします。描き直しのためのUndoや、長い時間使っても安定することを確かめます。"),
           ("NEXT", "その先", "flag", "場面に合わせた操作へ",
            "スライドごとに書き込みを残すプレゼンモードや、用途ごとのジェスチャーの組み合わせを、実際に使ってもらいながら形にします。")]


def roadmap(t, narrow=False):
    def one(k, en, jp, icon, title, body, w):
        pad = 22
        c = OPS["click"] if k == 0 else OPS["drag"]
        s = [tile(icon, pad, pad, c, 44),
             text(pad + 58, pad + 15, en, 13, t["muted"], weight=700, extra=' letter-spacing="3"'),
             text(pad + 58, pad + 39, jp, 20, t["ink"], weight=700)]
        s1, n1 = para(pad, pad + 78, title, 16, t["ink"], w - pad * 2, 24, 700)
        s2, n2 = para(pad, pad + 78 + n1 * 24 + 10, body, 14, t["muted"], w - pad * 2, 22)
        return "".join(s) + s1 + s2, pad + 78 + n1 * 24 + 10 + (n2 - 1) * 22 + 26

    b = []
    arrow = (lambda x, y, down=False: f'<g transform="translate({x} {y}) rotate({90 if down else 0})">'
             f'<circle r="15" fill="none" stroke="{t["line"]}" stroke-width="1.5"/>'
             f'<path d="M-5 0h10M1 -5l5 5-5 5" fill="none" stroke="url(#brand)" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></g>')
    if narrow:
        W, y = PHONE_W, 0
        for k, r in enumerate(ROADMAP):
            s, h = one(k, *r, W)
            b += [card(0, y, W, h, t), f'<g transform="translate(0 {y})">{s}</g>']
            y += h
            if k == 0:
                b.append(arrow(W / 2, y + 22, down=True))
                y += 44
        H = y
    else:
        W, gap = PC_W, 48
        cwid = (W - gap) / 2
        parts = [one(k, *r, cwid) for k, r in enumerate(ROADMAP)]
        H = max(h for _, h in parts)
        for k, (s, _) in enumerate(parts):
            x = k * (cwid + gap)
            b += [card(x, 0, cwid, H, t), f'<g transform="translate({x:.1f} 0)">{s}</g>']
        b.append(arrow(W / 2, H / 2))
    alt = "今後の展望。" + "。".join(f"{jp}：{title}。{body}" for _, jp, _, title, body in ROADMAP)
    return finish(W, H, b, t, alt)


# ---------- 09 システム構成 ----------

def box(x, y, w, h, t, title, sub, color, icon=None):
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{t["panel"]}" stroke="{t["line"]}" stroke-width="1.5"/>',
           f'<rect x="{x}" y="{y + 12}" width="3" height="{h - 24}" rx="1.5" fill="{color}"/>']
    tx = x + 16
    if icon:
        out.append(tile(icon, x + 12, y + (h - 36) / 2, color, 36))
        tx = x + 58
    out.append(text(tx, y + h / 2 - 3, title, 15, t["ink"], weight=700))
    out.append(text(tx, y + h / 2 + 17, sub, 13, t["muted"], weight=600))
    return "".join(out)


def frame(x, y, w, h, t, label, color):
    lw = tw(label, 13) + 24
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="{color}" fill-opacity=".06" stroke="{color}" stroke-opacity=".55" stroke-width="1.5" stroke-dasharray="5 5"/>'
            f'<rect x="{x + 16}" y="{y - 12}" width="{lw:.1f}" height="24" rx="12" fill="{t["page"]}" stroke="{color}" stroke-width="1.5"/>'
            + text(x + 16 + lw / 2, y + 4.5, label, 13, color, weight=700, anchor="middle"))


def arrow(x0, y0, x1, y1, t, main=False):
    ang = math.atan2(y1 - y0, x1 - x0)
    hx, hy = x1 - 7 * math.cos(ang), y1 - 7 * math.sin(ang)
    c = "url(#brand)" if main else t["muted"]
    stroke = t["muted"] if not main else "#7A7EF0"
    return (f'<path d="M{x0:.1f} {y0:.1f}L{hx:.1f} {hy:.1f}" stroke="{stroke}" stroke-width="{2.6 if main else 1.6}" fill="none"/>'
            f'<path d="M{x1:.1f} {y1:.1f}l{-9 * math.cos(ang - .45):.1f} {-9 * math.sin(ang - .45):.1f}M{x1:.1f} {y1:.1f}l{-9 * math.cos(ang + .45):.1f} {-9 * math.sin(ang + .45):.1f}" '
            f'stroke="{stroke}" stroke-width="{2.6 if main else 1.6}" stroke-linecap="round" fill="none"/>'), c


ARCH_ALT = ("システム構成。スマホ（Android：Kotlin・Jetpack Compose・CameraX／iOS：SwiftUI・AVFoundation、実験的）が、"
            "MediaPipe Hand Landmarker で手指21点を、OpenCV ArUco で画面四隅のマーカーを端末の中で認識する。"
            "PC（Flutter Desktop）は UDP 8766 で接続情報を広告し、スマホは WebSocket 8765（/ws/v1/input）で座標と状態だけを送る。"
            "PCは Homography で画面座標へ変換し、One-Euro Filter で揺れを抑え、ジェスチャーを判定して、"
            "透明・クリック透過のオーバーレイへの描画と、OSの実入力（macOS：CGEvent、Windows：SendInput）に変える。"
            "それがブラウザ・スライド・PDFなどの既存のアプリに届く。流れる点は、手の動きが画面に届くまでの道")


def architecture(t, narrow=False):
    b = []
    P, D, A = OPS["scroll"], OPS["click"], OPS["drag"]
    if narrow:
        W = PHONE_W
        y = 14
        b.append(frame(0, y, W, 214, t, "スマホ（目）", P))
        b += [box(14, y + 26, W - 28, 50, t, "カメラ", "CameraX / AVFoundation", P, "eye"),
              box(14, y + 88, W - 28, 50, t, "手指21点の認識", "MediaPipe Hand Landmarker", P, "smooth"),
              box(14, y + 150, W - 28, 50, t, "画面四隅の認識", "OpenCV ArUco", P, "grid")]
        y2 = y + 214 + 66
        b.append(frame(0, y2, W, 214, t, "PC（Flutter Desktop）", D))
        b += [box(14, y2 + 26, W - 28, 50, t, "座標変換", "Homography", D, "angle"),
              box(14, y2 + 88, W - 28, 50, t, "平滑化", "One-Euro Filter", D, "smooth"),
              box(14, y2 + 150, W - 28, 50, t, "ジェスチャー判定", "描く・消す・クリック・掴む・スクロール", D, "click")]
        y3 = y2 + 214 + 50
        b += [box(0, y3, (W - 10) / 2, 62, t, "描画", "透明オーバーレイ", A),
              box((W + 10) / 2, y3, (W - 10) / 2, 62, t, "OSの入力", "CGEvent／SendInput", A)]
        y4 = y3 + 62 + 40
        b.append(box(0, y4, W, 54, t, "既存のアプリ", "ブラウザ・スライド・PDF など", A, "apps"))
        H = y4 + 54
        # 通信（2本）
        mid = y + 214
        b += [arrow(W / 2 + 40, y2 - 4, W / 2 + 40, mid + 6, t)[0],
              text(W / 2 + 50, mid + 26, "UDP :8766", 13, t["muted"], weight=600),
              text(W / 2 + 50, mid + 44, "接続情報の広告", 13, t["muted"], weight=600)]
        b += [arrow(W / 2 - 40, mid + 6, W / 2 - 40, y2 - 4, t, True)[0],
              text(W / 2 - 50, mid + 26, "WebSocket :8765", 13, t["ink"], weight=700, anchor="end"),
              text(W / 2 - 50, mid + 44, "座標・状態だけ", 13, t["muted"], weight=600, anchor="end")]
        b += [arrow(W / 4, y2 + 214 + 4, W / 4, y3 - 4, t, True)[0], arrow(W * 3 / 4, y2 + 214 + 4, W * 3 / 4, y3 - 4, t, True)[0],
              arrow(W / 4, y3 + 66, W / 4, y4 - 4, t, True)[0], arrow(W * 3 / 4, y3 + 66, W * 3 / 4, y4 - 4, t, True)[0]]
        route = f"M{W / 2 - 40} {y + 200}V{y2 + 200}H{W / 4}V{y4 + 27}"
    else:
        W = PC_W
        fw = 252
        y = 14
        b.append(frame(0, y, fw, 232, t, "スマホ（目）", P))
        b += [box(14, y + 28, fw - 28, 56, t, "カメラ", "CameraX / AVFoundation", P, "eye"),
              box(14, y + 96, fw - 28, 56, t, "手指21点の認識", "MediaPipe", P, "smooth"),
              box(14, y + 164, fw - 28, 56, t, "画面四隅の認識", "OpenCV ArUco", P, "grid")]
        px = fw + 96
        pw = W - px
        b.append(frame(px, y, pw, 232, t, "PC（Flutter Desktop）", D))
        bw = (pw - 28 - 24) / 3
        names = [("座標変換", "Homography", "angle"), ("平滑化", "One-Euro Filter", "smooth"), ("判定", "ジェスチャー", "click")]
        for k, (n, s, ic) in enumerate(names):
            bx = px + 14 + k * (bw + 12)
            b.append(box(bx, y + 28, bw, 56, t, n, s, D))
            if k < 2:
                b.append(f'<path d="M{bx + bw + 3} {y + 51}l4 5-4 5" fill="none" stroke="#7A7EF0" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>')
        ow = (pw - 28 - 12) / 2
        b += [box(px + 14, y + 132, ow, 56, t, "描画", "透明オーバーレイ", A),
              box(px + 26 + ow, y + 132, ow, 56, t, "OSの入力", "CGEvent／SendInput", A)]
        jx = px + 14 + 2 * (bw + 12) + bw / 2
        b += [arrow(jx, y + 86, px + 14 + ow / 2, y + 130, t, True)[0], arrow(jx, y + 86, px + 26 + ow * 1.5, y + 130, t, True)[0]]
        b.append(text(px + pw / 2, y + 214, "クリック透過・最前面のウィンドウ／ネイティブの入力", 13, t["muted"], weight=600, anchor="middle"))
        # 既存のアプリ
        ay = y + 232 + 46
        b.append(box(px, ay, pw, 58, t, "既存のアプリ", "ブラウザ・スライド・PDF など、いつものアプリをそのまま操作", A, "apps"))
        b += [arrow(px + 14 + ow / 2, y + 232 + 2, px + 14 + ow / 2, ay - 2, t, True)[0],
              arrow(px + 26 + ow * 1.5, y + 232 + 2, px + 26 + ow * 1.5, ay - 2, t, True)[0]]
        H = ay + 58
        # 通信
        b += [arrow(fw + 6, y + 120, px - 6, y + 120, t, True)[0],
              text(fw + 48, y + 108, "WebSocket", 13, t["ink"], weight=700, anchor="middle"),
              text(fw + 48, y + 140, ":8765", 13, t["muted"], weight=600, anchor="middle"),
              arrow(px - 6, y + 178, fw + 6, y + 178, t)[0],
              text(fw + 48, y + 168, "UDP :8766", 13, t["muted"], weight=600, anchor="middle"),
              text(fw + 48, y + 198, "居場所を広告", 13, t["muted"], weight=600, anchor="middle")]
        b.append(f'<rect x="0" y="{y + 252}" width="3" height="40" rx="1.5" fill="url(#brand)"/>')
        b.append(text(14, y + 268, "映像は送らない。端末の中で認識し、", 13, t["ink"], weight=700))
        b.append(text(14, y + 288, "座標と状態だけを送る", 13, t["ink"], weight=700))
        route = f"M{fw - 40} {y + 192}V{y + 120}H{px + 14 + bw / 2}V{y + 56}H{jx}V{y + 160}H{px + 14 + ow / 2}V{ay + 29}"
    dot = (f'<g class="pk"><circle r="6" fill="#7A7EF0"><animateMotion dur="5s" repeatCount="indefinite" path="{route}" '
           f'keyPoints="0;1" keyTimes="0;1" calcMode="linear"/></circle>'
           f'<circle r="11" fill="#7A7EF0" opacity=".25"><animateMotion dur="5s" repeatCount="indefinite" path="{route}"/></circle></g>')
    b.append(dot)
    return finish(W, H, b, t, ARCH_ALT, top=4, css="@media (prefers-reduced-motion:reduce){.pk{display:none}}")


# ---------- 10 活用した技術 ----------
TECH = [
    ("android", OPS["scroll"], "Android", "android/・Kotlin", [
        ("Kotlin・Jetpack Compose", "状態ごとのガイド、接続、設定の画面"),
        ("CameraX", "背面カメラ・古いフレームは捨てる（KEEP_ONLY_LATEST）"),
        ("OkHttp WebSocket・UDP", "PCの自動発見と、リアルタイムの送信"),
        ("Android Keystore", "信頼済みの再接続に使うトークンを AES/GCM で保護")]),
    ("eye", OPS["drag"], "認識", "スマホの中で完結", [
        ("MediaPipe Hand Landmarker", "手指21点・既定は1手、設定で最大2手"),
        ("OpenCV ArUco", "DICT_4X4_50 の四隅マーカー・ID 10〜13"),
        ("解像度のフォールバック", "1280×720 → 960×540 → 640×480")]),
    ("laptop", OPS["click"], "Desktop", "desktop/・Flutter", [
        ("Flutter・Dart", "接続・位置合わせ・オーバーレイ・設定の4画面"),
        ("Homography", "4点のマーカーから、カメラ座標を画面座標へ"),
        ("One-Euro Filter", "静止時の揺れを抑え、動き出しの応答は保つ"),
        ("ジェスチャー判定", "手の大きさで正規化したしきい値と、ヒステリシス")]),
    ("keys", OPS["draw"], "OSとの連携", "ネイティブ", [
        ("macOS：Swift・CGEvent", "ポインター・クリック・ドラッグ・スクロール"),
        ("Windows：C++・Win32・SendInput", "実マウス入力と、透明・最前面・クリック透過のウィンドウ"),
        ("ショートカット", "オーバーレイの解除 ⌘⇧O／Ctrl+Shift+O")]),
    ("wave", OPS["scroll"], "通信", "同じLANの中で完結", [
        ("UDP :8766", "PCの居場所・ポート・6桁コードの広告（自動発見専用）"),
        ("WebSocket :8765", "/ws/v1/input で、認証・位置合わせ・手指21点・状態"),
        ("自動再接続", "1・2・4・8秒、以後10秒ごとに再試行、ネットワークが戻ればすぐ再接続")]),
    ("apple", "#8E8E93", "iOS（実験的）", "ios/・SwiftUI", [
        ("SwiftUI・AVFoundation", "Androidと同じ通信の契約で動くクライアント"),
        ("NWConnection", "RFC 6455 の WebSocket を生のTCPの上に実装"),
        ("Bonjour", "iPhone ↔ macOS の自動接続を実機で確認")]),
]


def techstack(t, narrow=False):
    b = []

    def block(icon, c, name, sub, items, w):
        pad = 18
        out = [tile(icon, pad, 18, c, 40), text(pad + 54, 34, name, 17, t["ink"], weight=700),
               text(pad + 54, 53, sub, 13, t["muted"], weight=600)]
        y = 86
        for k, (n, d) in enumerate(items):
            out.append(f'<circle cx="{pad + 4}" cy="{y - 5}" r="3.5" fill="{c}"/>')
            s1, n1 = para(pad + 16, y, n, 14, t["ink"], w - 2 * pad - 16, 20, 700)
            s2, n2 = para(pad + 16, y + n1 * 20 + 2, d, 13, t["muted"], w - 2 * pad - 16, 19, 600)
            out += [s1, s2]
            y += n1 * 20 + 2 + n2 * 19 + 12
        return "".join(out), y + 2

    if narrow:
        W, y = PHONE_W, 0
        for icon, c, name, sub, items in TECH:
            s, h = block(icon, c, name, sub, items, W)
            b += [card(0, y, W, h, t), f'<g transform="translate(0 {y})">{s}</g>']
            y += h + 12
        H = y - 12
    else:
        W = PC_W
        cols = 3
        colw = (W - GAP * (cols - 1)) / cols
        blocks = [block(*tk, colw) for tk in TECH]
        rows = [blocks[i:i + cols] for i in range(0, len(blocks), cols)]
        y = 0
        for r, row in enumerate(rows):
            h = max(bh for _, bh in row)
            for k, (s, _) in enumerate(row):
                x = k * (colw + GAP)
                b += [card(x, y, colw, h, t), f'<g transform="translate({x:.1f} {y})">{s}</g>']
            y += h + GAP
        H = y - GAP
    alt = "活用した技術。" + "。".join(f"{name}（{sub}）：" + "、".join(f"{n}（{d}）" for n, d in items) for _, _, name, sub, items in TECH)
    return finish(W, H, b, t, alt)


# ---------- 締め ----------

def footer(t, narrow=False):
    W, H = (PHONE_W, 250) if narrow else (PC_W, 220)
    cx = W / 2
    b = [f'<rect width="{W}" height="{H}" rx="22" fill="url(#bg)"/>',
         f'<clipPath id="fcard"><rect width="{W}" height="{H}" rx="22"/></clipPath><g clip-path="url(#fcard)">',
         art.dots(18, 18, 7, 5, 13, 2.6, t["dot"]),
         f'<g transform="translate({W} {H}) scale(-1 -1)">{art.dots(18, 18, 7, 5, 13, 2.6, t["dot2"])}</g></g>']
    if narrow:
        b += [text(cx, 54, "描いて、動かせる画面へ。", 26, t["ink"], cls="hand", weight=400, anchor="middle"),
              text(cx, 82, "普通の Screen が、", 14, t["muted"], cls="rnd", weight=700, anchor="middle"),
              text(cx, 102, "人の動きに React する。", 14, t["muted"], cls="rnd", weight=700, anchor="middle")]
        gy, s = 214, .62
    else:
        b += [text(cx, 60, "描いて、動かせる画面へ。", 36, t["ink"], cls="hand", weight=400, anchor="middle"),
              text(cx, 92, "普通の Screen が、人の動きに React する。", 16, t["muted"], cls="rnd", weight=700, anchor="middle")]
        gy, s = 190, .66
    # YouRay と、手が描いた波線（描いて、消える）
    L = 200
    wave = f"M{cx - 150} {gy - 30}c20-26 40-26 60 0s40 26 60 0"
    b.append(f'<path class="fw" d="{wave}" fill="none" stroke="{OPS["draw"]}" stroke-width="4" stroke-linecap="round" '
             f'stroke-dasharray="{L} {L + 20}"/>')
    b.append(art.sparkle(cx + 104, gy - 62, 8, "#F5B400", cls="tw1") + art.sparkle(cx - 96, gy - 70, 6, OPS["click"], cls="tw2"))
    b.append(art.shadow(cx + 40, gy + 4, 70, t, .12))
    b.append(art.youray(cx + 40, gy, s, "normal", delay=.2))
    css = (f"@keyframes fw{{0%{{stroke-dashoffset:{L}}}35%,70%{{stroke-dashoffset:0}}100%{{stroke-dashoffset:{-L}}}}}"
           f".fw{{animation:fw 6s ease-in-out infinite}}"
           "@keyframes tw{0%,100%{opacity:.2;transform:scale(.6)}50%{opacity:1;transform:scale(1)}}"
           ".tw1,.tw2{transform-box:fill-box;transform-origin:center;animation:tw 2.4s ease-in-out infinite}.tw2{animation-delay:1.2s}"
           "@media (prefers-reduced-motion:reduce){.fw{stroke-dashoffset:0}}")
    return art.svg(W, H, "".join(b), t, "描いて、動かせる画面へ。普通の Screen が、人の動きに React する。", css)


FIGS = {"journey": journey, "video-cta": video_cta, "message": message, "roles": roles, "screens": screens,
        "gestures": gestures, "features": features, "compare": compare, "scenes": scenes, "stats": stats,
        "focus": focus, "roadmap": roadmap, "architecture": architecture, "techstack": techstack, "footer": footer}


def main():
    files = {}
    for name, draw in FIGS.items():
        for mode, t in art.THEMES.items():
            files[f"{name}-{mode}.svg"] = draw(t)
            files[f"{name}-narrow-{mode}.svg"] = draw(t, narrow=True)
    print(f"wrote {art.write(files)} files to {art.OUT}")


if __name__ == "__main__":
    main()
