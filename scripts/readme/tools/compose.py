"""readme.tpl.md の [[名前]] を <picture> に展開して README.md を書く（一度だけ使う下書き用の道具）。"""
import html
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
A = "docs/assets/readme"


def alt(name):
    s = (REPO / A / f"{name}-light.svg").read_text(encoding="utf-8")
    t = re.search(r"<title>(.*?)</title>", s, re.S).group(1)
    return html.unescape(t).replace('"', "&quot;")


def pic(name, width=None, limit=700, extra=""):
    w = f' width="{width}"' if width else ""
    return (f'<picture><source media="(max-width: {limit}px) and (prefers-color-scheme: dark)" srcset="{A}/{name}-narrow-dark.svg">'
            f'<source media="(max-width: {limit}px)" srcset="{A}/{name}-narrow-light.svg">'
            f'<source media="(prefers-color-scheme: dark)" srcset="{A}/{name}-dark.svg">'
            f'<img src="{A}/{name}-light.svg"{w}{extra} alt="{alt(name)}"></picture>')


def main():
    tpl = Path(sys.argv[1]).read_text(encoding="utf-8")

    def repl(m):
        name = m.group(1)
        if name == "title":
            return pic("title", limit=1100, extra=' align="absbottom"')
        if name.startswith("heads/play-") or name.startswith("heads/part-") or name.endswith("-title"):
            return pic(name)
        return pic(name)
    out = re.sub(r"\[\[([a-z][\w/\-]*)\]\]", repl, tpl)
    (REPO / "README.md").write_text(out, encoding="utf-8", newline="\n")
    print("README.md", len(out))


if __name__ == "__main__":
    main()
