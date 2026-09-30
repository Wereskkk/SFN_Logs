#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Общий для раннеров вывод кода возврата по результату Lua-тестов.

Две проблемы, которые здесь закрыты:

1. Внутри lupa нет `os.exit` (а если бы и был, он убил бы процесс Python вместо
   возврата кода), поэтому `os.exit(failed == 0 and 0 or 1)` в конце
   test_logic.lua / test_ui.lua не срабатывает и раннер всегда выходил с кодом 0
   — CI был бы зелёным даже на проваленных тестах. Код возврата определяется по
   напечатанному итогу «N passed, M failed».

2. Lua-`print` пишет напрямую в C stdout, минуя `sys.stdout`, а Lua-`os.exit`
   в lupa убивает процесс Python. Раннер обязан поставить оба перехвата
   (`install_hooks`) ДО загрузки тестов, иначе итог не попадёт в разбираемый
   текст, а на провале CI получит пустой лог.
"""
import io
import re
import sys
from contextlib import redirect_stdout

SUMMARY = re.compile(r"(\d+)\s+passed,\s+(\d+)\s+failed")

# Две подмены в Lua-рантайме, без которых раннер в CI бесполезен:
#
# 1. print -> вызов Python-функции. Lua-print пишет напрямую в C stdout мимо
#    sys.stdout, поэтому contextlib.redirect_stdout его не видит и итог теста
#    не попадает в разбираемый текст. sys.stdout берётся в момент вызова, так
#    что redirect_stdout к этому моменту уже действует.
#
# 2. os.exit -> запись кода в __lua_exit_code. lupa мапит os.exit на C exit(),
#    то есть `os.exit(failed == 0 and 0 or 1)` в конце test_logic.lua/test_ui.lua
#    молча убивал ВЕСЬ процесс Python: вывод не успевал допечататься, а код
#    возврата оказывался «случайно правильным» только на зелёных тестах
#    (на красных CI увидел бы пустой лог).
INSTALL_HOOKS = """
local __pyprint = ...
print = function(...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring(select(i, ...)) end
    __pyprint(table.concat(parts, '\\t'))
end
os = os or {}
__lua_exit_code = nil
os.exit = function(code)
    if code == nil then code = 0 end
    if code == true then code = 0 end
    __lua_exit_code = tonumber(code) or 1
end
"""


def install_hooks(L):
    """Ставит перехват print и os.exit. Вызывать ДО загрузки тестов."""
    L.execute(INSTALL_HOOKS, lambda s: print(s))


# обратная совместимость с прежним именем
install_print = install_hooks


class _Tee:
    """Печатает в настоящий stdout и одновременно копит текст для вердикта."""

    def __init__(self, orig):
        self.orig = orig
        self.buf = io.StringIO()

    def write(self, s):
        self.orig.write(s)
        self.buf.write(s)

    def flush(self):
        self.orig.flush()

    def text(self):
        return self.buf.getvalue()


def verdict(out):
    """Возвращает (код_возврата, пояснение). 0 — всё зелёное."""
    if not isinstance(out, str):
        out = str(out or "")
    if "ОШИБКА ВЫПОЛНЕНИЯ" in out:
        return 2, "lua-ошибка выполнения"
    fail_lines = [l for l in out.splitlines() if l.startswith("  FAIL")]
    m = SUMMARY.findall(out)
    if not m:
        return 1, "в выводе нет строки итога «N passed, M failed» — тест не доехал до конца"
    passed = sum(int(a) for a, _ in m)
    failed = sum(int(b) for _, b in m)
    if passed == 0:
        return 1, "не прошло ни одной проверки"
    if failed or fail_lines:
        return 1, f"{failed} провалено по итогу, {len(fail_lines)} строк FAIL"
    return 0, f"{passed} passed"


def run_lua(L, chunk, name):
    """Выполняет Lua-чанк под pcall, печатает вывод и возвращает код возврата.

    pcall обязателен: без него traceback lua-ошибки печатается в C stderr мимо
    перехвата, и в логе CI осталась бы только голая цифра кода возврата.
    """
    wrapped = L.eval(
        "function(f) return function() "
        "local ok, err = pcall(f) "
        "if not ok then print('ОШИБКА ВЫПОЛНЕНИЯ: ' .. tostring(err)) return false end "
        "return true end end"
    )(chunk)
    tee = _Tee(sys.stdout)
    with redirect_stdout(tee):
        try:
            wrapped()
        except Exception as e:                       # на случай не-lua ошибок
            print(f"[{name}] ОШИБКА ВЫПОЛНЕНИЯ: {e}")
            return 2
        text = tee.text()
    code, why = verdict(text)
    # тест мог сам запросить ненулевой код через os.exit (он у нас no-op)
    lua_code = L.globals()["__lua_exit_code"]
    if lua_code is not None and int(lua_code) != 0 and code == 0:
        code, why = int(lua_code), f"тест запросил os.exit({int(lua_code)})"
    tag = "OK" if code == 0 else "FAIL"
    print(f"[{name}] {tag}: {why}")
    return code


def report(name, out):
    """Вердикт по уже накопленному тексту (для раннеров со своим потоком)."""
    code, why = verdict(out)
    tag = "OK" if code == 0 else "FAIL"
    print(f"[{name}] {tag}: {why}")
    return code
