#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Разнести канонический SFNLogs.lua и превью по всем копиям + пересобрать пакет.

Канонический источник — `delivery/proekt/SFNLogs.lua`: рядом с ним живут тесты,
поэтому правки делаются там. В репозитории исторически четыре копии одного файла
(корень, delivery/, delivery/proekt/, delivery/moonloader_pack/), и они обязаны
совпадать побайтово — этот скрипт их синхронизирует и пересобирает zip-пакет
установки.

Запуск из корня репозитория:   python3 delivery/proekt/tools/sync_delivery.py
Проверка (без записи):          python3 delivery/proekt/tools/sync_delivery.py --check
"""
import hashlib
import io
import os
import shutil
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROEKT = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(PROEKT))
CANON = os.path.join(PROEKT, "SFNLogs.lua")

LUA_TARGETS = [
    os.path.join(REPO, "SFNLogs.lua"),
    os.path.join(REPO, "delivery", "SFNLogs.lua"),
    os.path.join(REPO, "delivery", "moonloader_pack", "SFNLogs.lua"),
]
PREVIEW_SRC = os.path.join(PROEKT, "preview")
PREVIEW_DST = os.path.join(REPO, "delivery", "preview")
PACK = os.path.join(REPO, "delivery", "moonloader_pack")
PACK_ZIP = os.path.join(REPO, "delivery", "moonloader_pack.zip")


def md5(path):
    with io.open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def rel(path):
    return os.path.relpath(path, REPO).replace(os.sep, "/")


def check():
    """True, если всё уже синхронно."""
    problems = []
    src = md5(CANON)
    for t in LUA_TARGETS:
        if not os.path.exists(t):
            problems.append(f"нет файла {rel(t)}")
        elif md5(t) != src:
            problems.append(f"{rel(t)} отличается от канонической копии")
    for name in sorted(os.listdir(PREVIEW_SRC)):
        if not (name.endswith(".svg") or name.endswith(".html")):
            continue
        dst = os.path.join(PREVIEW_DST, name)
        if not os.path.exists(dst):
            problems.append(f"в delivery/preview нет {name}")
        elif md5(dst) != md5(os.path.join(PREVIEW_SRC, name)):
            problems.append(f"delivery/preview/{name} устарел")
    if not os.path.exists(PACK_ZIP):
        problems.append("нет delivery/moonloader_pack.zip")
    else:
        with zipfile.ZipFile(PACK_ZIP) as z:
            names = set(z.namelist())
            want = set()
            for root, _dirs, files in os.walk(PACK):
                for f in files:
                    want.add(os.path.relpath(os.path.join(root, f), PACK).replace(os.sep, "/"))
            if names != want:
                problems.append(f"zip устарел: {sorted(names ^ want)}")
            else:
                for n in sorted(want):
                    inzip = hashlib.md5(z.read(n)).hexdigest()
                    if inzip != md5(os.path.join(PACK, n)):
                        problems.append(f"в zip устарел {n}")
    return problems


def sync():
    src = io.open(CANON, encoding="utf-8").read()
    for t in LUA_TARGETS:
        io.open(t, "w", encoding="utf-8", newline="").write(src)
        print(f"  = {rel(t)}  ({md5(t)[:10]})")
    copied = 0
    for name in sorted(os.listdir(PREVIEW_SRC)):
        if name.endswith(".svg") or name.endswith(".html"):
            shutil.copy2(os.path.join(PREVIEW_SRC, name), os.path.join(PREVIEW_DST, name))
            copied += 1
    print(f"  = delivery/preview/  ({copied} файлов)")
    names = []
    with zipfile.ZipFile(PACK_ZIP, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _dirs, files in os.walk(PACK):
            for f in sorted(files):
                full = os.path.join(root, f)
                arc = os.path.relpath(full, PACK).replace(os.sep, "/")
                z.write(full, arc)
                names.append(arc)
    print(f"  = {rel(PACK_ZIP)}  ({os.path.getsize(PACK_ZIP)} байт): {', '.join(names)}")


if __name__ == "__main__":
    if "--check" in sys.argv:
        bad = check()
        if bad:
            print("НЕ СИНХРОННО:")
            for b in bad:
                print("  -", b)
            sys.exit(1)
        print("всё синхронно:", rel(CANON), "->", len(LUA_TARGETS), "копии, превью и zip")
        sys.exit(0)
    sync()
    bad = check()
    print("проверка:", "всё синхронно" if not bad else "ЕСТЬ РАСХОЖДЕНИЯ: " + "; ".join(bad))
    sys.exit(1 if bad else 0)
