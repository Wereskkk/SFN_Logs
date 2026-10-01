#!/usr/bin/env python3
"""
Превью окна SFN Logs в SVG.

Это не художественный макет: SVG собирается из тех же вызовов DrawList
(AddRectFilled / AddRect / AddLine / AddCircleFilled / AddText), которые
скрипт реально выдаёт в headless-моке mimgui. Координаты, размеры и цвета —
из кода, а не «на глаз».
"""
import lupa, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("package.path = './?.lua;./?/init.lua;' .. package.path")
L.execute(open('tests/stubs.lua', encoding='utf-8').read())
L.eval("function(s) return assert(load(s,'SFNLogs.lua')) end")(
    open('SFNLogs.lua', encoding='utf-8').read())()
render = L.eval("function(s) return assert(load(s,'render_scene')) end")(
    open('tests/render_scene.lua', encoding='utf-8').read())()


from svgbuild import build_svg, num  # общий построитель (tests/svgbuild.py)


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
</table>
<p>Превью окна помощника (журнал + вкладки Фото, Эфир, Соцопрос) —
в <a href="helper-index.html">helper-index.html</a>.</p>""")
print('\npreview/index.html')
