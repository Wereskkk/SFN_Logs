#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Набор «lua51»: синтаксис игровых файлов для LuaJIT + фазз bit-шима.

Зачем: MoonLoader исполняет скрипты на LuaJIT (Lua 5.1), а тесты идут через
lupa (Lua 5.4+). Файл, который грузится в lupa, может не компилироваться в
игре: операторы & | ~ << >> // появились только в Lua 5.3. Регресс 0.3.0:
bit-шим «только для тестов» на операторах 5.3 уронил загрузку SFN_Helper.lua
в игре на строке шима. Этот набор ловит такой класс ошибок намертво:

  1. `luac5.1 -p` (настоящий парсер Lua 5.1) прогоняется по всем игровым
     .lua-файлам репозитория (кроме тестовой обвязки — она живёт в 5.4);
  2. из SFN_Helper.lua вырезаются bit-шим и SHA-256 и прогоняются на
     НАСТОЯЩЕМ интерпретаторе Lua 5.1 (или LuaJIT, если найден): ~8000
     дифференциальных кейсов против эталонной семантики LuaJIT bit
     (src/lib_bit.c, vm_x64.dasc) + эталонные векторы SHA-256 (RFC 6234,
     hashlib). Под LuaJIT тот же фазз сверяет нативную bit-библиотеку с
     эталоном — заодно проверяется сам эталон.

Бинарники ищутся: $LUAC51/$LUA51/$LUAJIT -> ../tools/ (рядом с репозиторием)
-> PATH. Сборка из исходников (нужен любой C-компилятор, ~15 секунд):

    curl -sSLO https://www.lua.org/ftp/lua-5.1.5.tar.gz && tar xzf lua-5.1.5.tar.gz
    cd lua-5.1.5/src
    gcc -O1 -w -o luac5.1 luac.c print.c lapi.c lcode.c ldebug.c ldo.c ldump.c \
        lfunc.c lgc.c llex.c lmem.c lobject.c lopcodes.c lparser.c lstate.c \
        lstring.c ltable.c ltm.c lundump.c lvm.c lzio.c lauxlib.c lbaselib.c \
        ldblib.c liolib.c lmathlib.c loslib.c ltablib.c lstrlib.c loadlib.c linit.c -lm
    gcc -O1 -w -o lua5.1 lua.c lapi.c lcode.c ldebug.c ldo.c ldump.c lfunc.c \
        lgc.c llex.c lmem.c lobject.c lopcodes.c lparser.c lstate.c lstring.c \
        ltable.c ltm.c lundump.c lvm.c lzio.c lauxlib.c lbaselib.c ldblib.c \
        liolib.c lmathlib.c loslib.c ltablib.c lstrlib.c loadlib.c linit.c -lm

В CI (.github/workflows/tests.yml) Lua 5.1 собирается шагом «Lua 5.1 для
проверки синтаксиса LuaJIT» и пути передаются через $LUAC51/$LUA51.
"""
import hashlib
import io
import os
import random
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROEKT = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(PROEKT))
WS = os.path.dirname(REPO)
HELPER = os.path.join(REPO, "SFN_Helper.lua")

# Тестовая обвязка исполняется в Lua 5.4+ и вправе использовать его синтаксис.
EXCLUDE_DIRS = {os.path.join(PROEKT, "tests")}
EXCLUDE_PREFIXES = (os.path.join(PROEKT, "test_"),)


# ---------------------------------------------------------------------------
# Эталон: семантика LuaJIT bit (src/lib_bit.c + vm_x64.dasc, x86-путь).
# Результаты — знаковые int32; расстояния сдвигов — tobit(n) & 31; rshift
# логический; tohex: strочные, ноль-паддинг, n<0 -> ЗАГЛАВНЫЕ, n<8 -> маска.
# Область совпадения с LuaJIT: |v| < 2^51 (дальше у LuaJIT ломается точность
# double-преобразования; sha256 такие величины не порождает — суммы < 2^35).
# ---------------------------------------------------------------------------
M32 = 0xFFFFFFFF


def tobit(v):
    v &= M32
    return v - 2**32 if v >= 2**31 else v


def pattern(v):
    return v & M32


def ref_band(*a):
    r = pattern(a[0])
    for x in a[1:]:
        r &= pattern(x)
    return tobit(r)


def ref_bor(*a):
    r = pattern(a[0])
    for x in a[1:]:
        r |= pattern(x)
    return tobit(r)


def ref_bxor(*a):
    r = pattern(a[0])
    for x in a[1:]:
        r ^= pattern(x)
    return tobit(r)


def ref_bnot(a):
    return tobit(~pattern(a))


def shdist(n):
    return tobit(n) & 31


def ref_lshift(a, n):
    return tobit((pattern(a) << shdist(n)) & M32)


def ref_rshift(a, n):
    return tobit(pattern(a) >> shdist(n))


def ref_arshift(a, n):
    return tobit(tobit(a) >> shdist(n))


def ref_rol(a, n):
    n, x = shdist(n), pattern(a)
    if n == 0:
        return tobit(x)
    return tobit(((x << n) | (x >> (32 - n))) & M32)


def ref_ror(a, n):
    n, x = shdist(n), pattern(a)
    if n == 0:
        return tobit(x)
    return tobit(((x >> n) | (x << (32 - n))) & M32)


def ref_bswap(a):
    x = pattern(a)
    return tobit(int.from_bytes(x.to_bytes(4, "little"), "big"))


def ref_tohex(v, n=None):
    x = pattern(v)
    n = 8 if n is None else tobit(n)
    up = False
    if n < 0:
        up, n = True, tobit(-n)
    if n > 254:
        n = 254
    if n < 8:
        x &= (1 << (4 * n)) - 1
    s = "" if (n == 0 and x == 0) else format(x, "x")
    if n > 0:
        s = s.rjust(n, "0")
    return s.upper() if up else s


# ---------------------------------------------------------------------------
# Генерация кейсов (детерминированная)
# ---------------------------------------------------------------------------
def gen_cases():
    random.seed(20260929)
    edges = [0, 1, -1, 2, -2, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x100000000,
             0x100000001, -0x80000000, 0xDEADBEEF, 0x55555555, 0xAAAAAAAA,
             123456789, 2**31 - 1, 2**35 + 7, -(2**35 + 7), 2**51 - 1, -(2**51 - 1)]
    rand = [random.getrandbits(32) for _ in range(120)]
    rand += [random.getrandbits(random.choice([33, 40, 50, 51])) * random.choice([1, -1])
             for _ in range(60)]
    vals = edges + rand
    ns = [-66, -64, -63, -33, -32, -31, -5, -1, 0, 1, 5, 31, 32, 33, 63, 64, 66,
          0x100000000, 0x100000003, -0x80000000, 0x7FFFFFFF, 2**31 + 5]
    nvals = edges[:6] + rand[:34]
    lines, count = [], 0

    def num(name, got, want):
        nonlocal count
        count += 1
        lines.append("num('%s', %s, %s)" % (name, got, want))

    for i, a in enumerate(vals):
        num('tobit#%d' % i, 'bit.tobit(%d)' % a, tobit(a))
        num('bnot#%d' % i, 'bit.bnot(%d)' % a, ref_bnot(a))
        num('bswap#%d' % i, 'bit.bswap(%d)' % a, ref_bswap(a))
    for i, a in enumerate(nvals):
        for j, b in enumerate(nvals[:20]):
            num('band#%d_%d' % (i, j), 'bit.band(%d, %d)' % (a, b), ref_band(a, b))
            num('bor#%d_%d' % (i, j), 'bit.bor(%d, %d)' % (a, b), ref_bor(a, b))
            num('bxor#%d_%d' % (i, j), 'bit.bxor(%d, %d)' % (a, b), ref_bxor(a, b))
    for i in range(0, len(nvals), 3):
        a = nvals[i % len(nvals)]
        b = nvals[(i + 5) % len(nvals)]
        c = nvals[(i + 11) % len(nvals)]
        d = nvals[(i + 17) % len(nvals)]
        num('bxor3#%d' % i, 'bit.bxor(%d, %d, %d)' % (a, b, c), ref_bxor(a, b, c))
        num('bor4#%d' % i, 'bit.bor(%d, %d, %d, %d)' % (a, b, c, d), ref_bor(a, b, c, d))
        num('band3#%d' % i, 'bit.band(%d, %d, %d)' % (a, b, c), ref_band(a, b, c))
        num('band1#%d' % i, 'bit.band(%d)' % a, ref_band(a))
    for a in nvals:
        for n in ns:
            num('lshift(%d,%d)' % (a, n), 'bit.lshift(%d, %d)' % (a, n), ref_lshift(a, n))
            num('rshift(%d,%d)' % (a, n), 'bit.rshift(%d, %d)' % (a, n), ref_rshift(a, n))
            num('arshift(%d,%d)' % (a, n), 'bit.arshift(%d, %d)' % (a, n), ref_arshift(a, n))
            num('rol(%d,%d)' % (a, n), 'bit.rol(%d, %d)' % (a, n), ref_rol(a, n))
            num('ror(%d,%d)' % (a, n), 'bit.ror(%d, %d)' % (a, n), ref_ror(a, n))
    for a in edges + rand[:20]:
        for n in [None, 0, 1, 2, 7, 8, 9, 10, -1, -8, -4, 254, 300]:
            arg = '%d' % a if n is None else '%d, %d' % (a, n)
            num('tohex(%s)' % arg, 'bit.tohex(%s)' % arg, "'%s'" % ref_tohex(a, n))

    msgs = [b'', b'abc', b'a',
            b'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
            b'a' * 55, b'a' * 56, b'a' * 57, b'a' * 63, b'a' * 64, b'a' * 65,
            b'a' * 127, b'a' * 128, b'a' * 129,
            'Прямой эфир San Fierro News'.encode('utf-8'),
            ('Jonny_Wilde' + 'SFN_2026_SECURE_x7p9nq2m').encode('utf-8'),
            bytes(range(256))]
    for i, m in enumerate(msgs):
        lit = '"' + ''.join('\\%d' % ch for ch in m) + '"'
        num('sha256#%d' % i, 'sha256.hash(%s)' % lit,
            "'%s'" % hashlib.sha256(m).hexdigest())
    return lines, count


DRIVER_HEAD = """
local fails, total = 0, 0
local shown = 0
local function num(name, got, want)
    total = total + 1
    if got ~= want then
        fails = fails + 1
        if shown < 25 then shown = shown + 1
            print('FAIL ' .. name .. '  got=' .. tostring(got) ..
                  '  want=' .. tostring(want)) end
    end
end
"""
DRIVER_TAIL = """
print(string.format('CASES %d FAILS %d', total, fails))
if fails > 0 then os.exit(1) end
os.exit(0)
"""


def extract_blocks(src):
    """Вырезать из SFN_Helper.lua bit-шим и SHA-256 (маркеры сборки)."""
    i0 = src.index("local bit\nif type(_G.bit) == 'table' and _G.bit.band then")
    i1 = src.index("\n-- SHA-256:", i0)
    shim = src[i0:i1].rstrip("\n")
    j0 = src.index("local sha256 = (function()")
    j1 = src.index("\nend)()\n", j0) + len("\nend)()")
    return shim, src[j0:j1]


# ---------------------------------------------------------------------------
# Поиск бинарников Lua 5.1 / LuaJIT
# ---------------------------------------------------------------------------
def _version_ok(path, needle):
    try:
        out = subprocess.run([path, "-v"], capture_output=True, text=True, timeout=15)
    except OSError:
        return False
    return needle in (out.stdout or "") or needle in (out.stderr or "")


def find_binary(envvar, tools_name, path_names, needle):
    cands = []
    env = os.environ.get(envvar)
    if env:
        cands.append(env)
    tools = os.path.join(WS, "tools", tools_name)
    if os.path.exists(tools):
        cands.append(tools)
    for n in path_names:
        p = shutil.which(n)
        if p:
            cands.append(p)
    for c in cands:
        if os.path.exists(c) and _version_ok(c, needle):
            return c
    return None


def game_lua_files():
    files = []
    for root, dirs, names in os.walk(REPO):
        dirs[:] = [d for d in dirs if d != ".git"]
        for n in sorted(names):
            if not n.endswith(".lua"):
                continue
            full = os.path.join(root, n)
            if any(full.startswith(d + os.sep) for d in EXCLUDE_DIRS):
                continue
            if any(full.startswith(p) for p in EXCLUDE_PREFIXES):
                continue
            files.append(full)
    return sorted(files)


def rel(p):
    return os.path.relpath(p, REPO).replace(os.sep, "/")


def main():
    problems = []

    luac = find_binary("LUAC51", "luac5.1", ["luac5.1", "luac51", "luac-5.1", "luac"], "5.1")
    if not luac:
        print("НЕ НАЙДЕН luac 5.1 ($LUAC51, ../tools/luac5.1, PATH).")
        print("Инструкция по сборке — в шапке этого файла; CI собирает сам.")
        return 2
    print("luac 5.1:", luac)

    # 1) синтаксис всех игровых файлов настоящим парсером Lua 5.1
    files = game_lua_files()
    for f in files:
        r = subprocess.run([luac, "-p", f], capture_output=True, text=True)
        if r.returncode != 0:
            problems.append("синтаксис 5.1: %s: %s" %
                            (rel(f), (r.stderr or "").strip().splitlines()[-1:]))
    print("синтаксис Lua 5.1 (LuaJIT): %d файлов проверено" % len(files))

    # 2) фазз шима и sha256 на настоящем интерпретаторе
    interps = []
    lua51 = find_binary("LUA51", "lua5.1", ["lua5.1", "lua51", "lua-5.1", "lua"], "5.1")
    if lua51:
        interps.append(("lua5.1", lua51))
    luajit = find_binary("LUAJIT", "luajit", ["luajit"], "LuaJIT")
    if luajit:
        interps.append(("luajit", luajit))
    if not interps:
        print("НЕ НАЙДЕН интерпретатор Lua 5.1/LuaJIT ($LUA51/$LUAJIT, ../tools/, PATH).")
        return 2

    src = io.open(HELPER, encoding="utf-8").read()
    try:
        shim, sha = extract_blocks(src)
    except ValueError as e:
        print("не удалось вырезать шим/sha256 из SFN_Helper.lua:", e)
        return 2
    # страховка: в КОДЕ шима (без строк-комментариев) не должно быть
    # операторов Lua 5.3+ — именно они уронили загрузку в игре в 0.3.0
    code = "\n".join(l.split("--", 1)[0] for l in shim.splitlines())
    for bad in (" & ", " | ", " << ", " >> ", "//"):
        if bad in code:
            problems.append("в коде шима остался оператор Lua 5.3+: %r" % bad)

    lines, count = gen_cases()
    tmpdir = tempfile.mkdtemp(prefix="lua51fuzz")
    fuzz = os.path.join(tmpdir, "fuzz.lua")
    io.open(fuzz, "w", encoding="utf-8", newline="\n").write(
        shim + "\n\n" + sha + "\n" + DRIVER_HEAD + "\n".join(lines) + DRIVER_TAIL)
    for name, interp in interps:
        r = subprocess.run([interp, fuzz], capture_output=True, text=True,
                           timeout=600, cwd=tmpdir)
        tail = (r.stdout or "").strip().splitlines()[-1:] or ["<нет вывода>"]
        print("фазз %-7s: %s (exit=%d)" % (name, tail[0], r.returncode))
        if r.returncode != 0 or "FAILS 0" not in tail[0]:
            problems.append("фазз %s: %s\n%s" % (name, tail[0],
                                                 (r.stdout or "")[-2000:]))
    shutil.rmtree(tmpdir, ignore_errors=True)

    print("кейсов фазза на интерпретатор: %d" % count)
    if problems:
        print("\nПРОВАЛ (%d):" % len(problems))
        for p in problems:
            print(" -", p)
        return 1
    print("lua51: все проверки зелёные")
    return 0


if __name__ == "__main__":
    sys.exit(main())
