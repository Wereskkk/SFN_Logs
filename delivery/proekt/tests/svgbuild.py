#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Построитель SVG-превью из примитивов DrawList (общий для SFN Logs и Helper).

SVG собирается из тех же вызовов, которые скрипт реально выдаёт в
headless-моке mimgui (AddRectFilled / AddRect / AddLine / AddCircleFilled /
AddText): координаты, размеры и цвета — из кода, а не «на глаз».
"""
import html


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


