#!/usr/bin/env python3
"""
Превью окна SFN Logs в SVG.

Это не художественный макет: SVG собирается из тех же вызовов DrawList
(AddRectFilled / AddRect / AddLine / AddCircleFilled / AddText), которые
скрипт реально выдаёт в headless-моке mimgui. Координаты, размеры и цвета —
из кода, а не «на глаз».
"""
import lupa, os, html

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("package.path = './?.lua;./?/init.lua;' .. package.path")
L.execute(open('tests/stubs.lua', encoding='utf-8').read())
L.eval("function(s) return assert(load(s,'SFNLogs.lua')) end")(
    open('SFNLogs.lua', encoding='utf-8').read())()
render = L.eval("function(s) return assert(load(s,'render_scene')) end")(
    open('tests/render_scene.lua', encoding='utf-8').read())()


def num(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def css(col):
    if col is None:
        return '#888888', 1.0
    try:
        return '#%02x%02x%02x' % (int(col.r), int(col.g), int(col.b)), num(col.a, 1.0)
    except AttributeError:
        return '#888888', 1.0


def build_svg(scene, pad=28):
    W, H = num(scene.win.w, 800), num(scene.win.h, 600)
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W + pad * 2:.0f}" height="{H + pad * 2:.0f}" '
        f'viewBox="{-pad:.0f} {-pad:.0f} {W + pad * 2:.0f} {H + pad * 2:.0f}" '
        f'font-family="Trebuchet MS, Verdana, sans-serif">',
        f'<rect x="{-pad}" y="{-pad}" width="{W + pad * 2}" height="{H + pad * 2}" fill="#08090c"/>',
        f'<rect x="7" y="11" width="{W}" height="{H}" rx="10" fill="#000" opacity="0.5"/>',
    ]
    gid = 0
    for i in range(1, len(scene.rects) + 1):
        rc = scene.rects[i]
        kind = str(rc.kind)
        x, y, w, h = num(rc.x), num(rc.y), num(rc.w), num(rc.h)
        c, a = css(rc.col)
        rr = num(rc.r)
        if kind in ('fill', 'grad'):
            if kind == 'grad' and rc.col2 is not None:
                c2, a2 = css(rc.col2)
                gid += 1
                out.append(
                    f'<defs><linearGradient id="g{gid}" x1="0" y1="0" x2="1" y2="0">'
                    f'<stop offset="0" stop-color="{c}" stop-opacity="{a:.3f}"/>'
                    f'<stop offset="0.5" stop-color="{c2}" stop-opacity="{a2:.3f}"/>'
                    f'<stop offset="1" stop-color="{c}" stop-opacity="{a:.3f}"/>'
                    f'</linearGradient></defs>')
                out.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" '
                           f'rx="{rr:.1f}" fill="url(#g{gid})"/>')
            else:
                out.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" '
                           f'rx="{rr:.1f}" fill="{c}" opacity="{a:.3f}"/>')
        elif kind == 'stroke':
            out.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{rr:.1f}" '
                       f'fill="none" stroke="{c}" stroke-opacity="{a:.3f}" '
                       f'stroke-width="{max(1.0, num(rc.thick, 1)):.1f}"/>')
        elif kind == 'line':
            out.append(f'<line x1="{num(rc.ax):.1f}" y1="{num(rc.ay):.1f}" x2="{num(rc.bx):.1f}" '
                       f'y2="{num(rc.by):.1f}" stroke="{c}" stroke-opacity="{a:.3f}" '
                       f'stroke-width="{max(1.0, num(rc.thick, 1)):.1f}"/>')
        elif kind == 'circle':
            out.append(f'<circle cx="{num(rc.cx):.1f}" cy="{num(rc.cy):.1f}" r="{num(rc.rr):.1f}" '
                       f'fill="{c}" opacity="{a:.3f}"/>')

    for i in range(1, len(scene.texts) + 1):
        tx = scene.texts[i]
        c, a = css(tx.col)
        x, y = num(tx.x), num(tx.y)
        size = 13.5
        out.append(f'<text x="{x:.1f}" y="{y + size:.1f}" fill="{c}" opacity="{a:.3f}" '
                   f'font-size="{size}" xml:space="preserve">{html.escape(str(tx.text))}</text>')
    out.append('</svg>')
    return '\n'.join(out)


SCENES = [
    ('01-journal',  1, 9, 1.0, False, True),
    ('02-search',   2, 3, 1.0, False, False),
    ('03-settings', 3, 9, 1.0, False, True),
    ('04-about',    4, 9, 1.0, False, True),
    ('05-empty',    1, 0, 1.0, False, False),
    ('06-dpi150',   1, 6, 1.5, False, True),
    ('07-longnick', 1, 5, 1.0, True,  True),
    ('08-hover',    1, 6, 1.0, False, False, 2),
    ('09-rowmenu',  1, 6, 1.0, False, False, 0, 2),
    ('10-members',  1, 0, 1.0, False, False, 2, 0, True),
]

os.makedirs('preview', exist_ok=True)
index = []
for sc in SCENES:
    name, tab, n, dpi, longn, dis = sc[:6]
    hov = sc[6] if len(sc) > 6 else 0
    menu = sc[7] if len(sc) > 7 else 0
    memb = sc[8] if len(sc) > 8 else False
    scene = render(tab, n, dpi, longn, dis, hov, menu, memb)
    open(f'preview/{name}.svg', 'w', encoding='utf-8').write(build_svg(scene))
    errs = [str(scene.errors[i]) for i in range(1, len(scene.errors) + 1)]
    print(f"{name:12s} окно {num(scene.win.w):6.0f} x {num(scene.win.h):5.0f}   "
          f"примитивов {len(scene.rects) + len(scene.texts):5d}   ошибок раскладки {len(errs)}")
    for e in errs[:2]:
        print('      ', ''.join(ch if ord(ch) < 128 else '.' for ch in e))
    index.append((name, num(scene.win.w), num(scene.win.h), len(errs)))

rows = '\n'.join(
    f'<tr><td><a href="{n}.svg">{n}</a></td><td>{w:.0f} × {h:.0f}</td>'
    f'<td>{"—" if e == 0 else str(e)}</td></tr>'
    for n, w, h, e in index)
open('preview/index.html', 'w', encoding='utf-8').write(f"""<!doctype html>
<meta charset="utf-8"><title>SFN Logs — превью интерфейса</title>
<style>
body{{font:14px/1.6 system-ui,sans-serif;background:#08090c;color:#e9ecf3;padding:28px}}
h1{{color:#e8b44c;font-size:20px}} td,th{{padding:6px 18px;border-bottom:1px solid #252b38;text-align:left}}
a{{color:#e8b44c}} code{{color:#8c95a8}}
</style>
<h1>SFN Logs — превью интерфейса</h1>
<p>Каждый файл собран из реальных вызовов DrawList скрипта (headless-прогон
на моке mimgui, Dear ImGui 1.76), а не нарисован вручную: координаты, размеры
и цвета — те самые, которые скрипт выдаёт в игре.</p>
<table><tr><th>сцена</th><th>размер окна, px</th><th>ошибки раскладки</th></tr>
{rows}
</table>""")
print('\npreview/index.html')
