#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Превью окна SFN_Helper в SVG (все вкладки, включая модули редакции).

Как и render_svg.py, картинка собирается из реальных вызовов DrawList скрипта
в headless-моке mimgui: это не макет, а то, что пользователь увидит в игре.
Сцены покрывают оба состояния модулей — «Эфир» идёт и «Эфир» закрыт замком,
«Соцопрос» в стадии согласия и в стадии второго скриншота.

Запуск из delivery/proekt:  python tests/render_helper_svg.py
Результат: preview/helper-*.svg + preview/helper-index.html (таблица сцен).
"""
import os
import sys

import lupa

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from svgbuild import build_svg, num          # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("package.path = './?.lua;./?/init.lua;' .. package.path")
L.execute(open('tests/stubs.lua', encoding='utf-8').read())
os.makedirs('/tmp/sfnhelper_preview', exist_ok=True)
L.eval("function(s) return assert(load(s,'SFN_Helper.lua')) end")(
    open('../../SFN_Helper.lua', encoding='utf-8').read())()
render = L.eval("function(s) return assert(load(s,'render_helper_scene')) end")(
    open('tests/render_helper_scene.lua', encoding='utf-8').read())()

# (имя файла, вкладка, строк журнала, DPI, состояние модулей)
SCENES = [
    ('helper-01-journal',    1, 9, 1.0, ''),
    ('helper-02-photo',      3, 0, 1.0, ''),
    ('helper-03-efir',       4, 0, 1.0, 'quiz'),
    ('helper-04-efir-lock',  4, 0, 1.0, 'locked'),
    ('helper-05-social',     5, 0, 1.0, 'survey'),
    ('helper-06-social2',    5, 0, 1.0, 'flyer'),
    ('helper-07-settings',   6, 0, 1.0, ''),
    ('helper-08-about',      7, 0, 1.0, ''),
    ('helper-09-dpi150',     1, 6, 1.5, ''),
]

os.makedirs('preview', exist_ok=True)
index = []
bad = 0
for name, tab, nrows, dpi, state in SCENES:
    scene = render(tab, nrows, dpi, state)
    open(f'preview/{name}.svg', 'w', encoding='utf-8').write(build_svg(scene))
    errs = [str(scene.errors[i]) for i in range(1, len(scene.errors) + 1)]
    bad += len(errs)
    print(f"{name:22s} окно {num(scene.win.w):6.0f} x {num(scene.win.h):5.0f}   "
          f"примитивов {len(scene.rects) + len(scene.texts):5d}   ошибок раскладки {len(errs)}")
    for e in errs[:3]:
        print('      ', ''.join(ch if ord(ch) < 128 else '.' for ch in e))
    index.append((name, num(scene.win.w), num(scene.win.h), len(errs)))

rows = '\n'.join(
    f'<tr><td><a href="{n}.svg">{n}</a></td><td>{w:.0f} × {h:.0f}</td>'
    f'<td>{"—" if e == 0 else str(e)}</td></tr>'
    for n, w, h, e in index)
open('preview/helper-index.html', 'w', encoding='utf-8').write(f"""<!doctype html>
<meta charset="utf-8"><title>SFN_Helper — превью интерфейса</title>
<style>
body{{font:14px/1.6 system-ui,sans-serif;background:#08090c;color:#e9ecf3;padding:28px}}
h1{{color:#e8b44c;font-size:20px}} td,th{{padding:6px 18px;border-bottom:1px solid #252b38;text-align:left}}
a{{color:#e8b44c}} code{{color:#8c95a8}}
</style>
<h1>SFN_Helper — превью интерфейса</h1>
<p>Окно помощника: ядро SFN Logs (Журнал, Поиск, Настройки, О скрипте) и три
вкладки модулей редакции — Фото, Эфир, Соцопрос. Каждый файл собран из реальных
вызовов DrawList скрипта (headless-прогон на моке mimgui), а не нарисован
вручную: координаты, размеры и цвета — те самые, которые скрипт выдаёт в игре.</p>
<table><tr><th>сцена</th><th>размер окна, px</th><th>ошибки раскладки</th></tr>
{rows}
</table>
<p>Превью самого журнала — в <a href="index.html">index.html</a>.</p>""")
print('\npreview/helper-index.html')
sys.exit(1 if bad else 0)
