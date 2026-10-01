# SFN — скрипты редакции San Fierro News (Evolve RP)

Репозиторий MoonLoader-скриптов редакции **San Fierro News** (SA-MP, Evolve
Role Play, сервер Saint-Louis). Два готовых к установке файла в корне:

| файл | что это | версия |
|---|---|---|
| [`SFN_Helper.lua`](SFN_Helper.lua) | **всё в одном**: журнал состава + модули редакции в общем окне с вкладками | 0.3.0 |
| [`SFNLogs.lua`](SFNLogs.lua) | только журнал состава (прежний отдельный скрипт) | 2.2.4 |

Оба файла обновляют себя сами из ветки `main`, поэтому **коммит в `main` =
релиз для всех, кто установил скрипт**. Перед вливанием обязан пройти
GitHub Actions (`.github/workflows/tests.yml`): 554 + 272 + 149 проверок
SFN Logs и 853 + 192 проверки SFN_Helper.

---

## SFN_Helper — что внутри

Одно окно, тёмный сайдбар с фирменным знаком редакции, вкладки:

| вкладка | зачем | перенесено из |
|---|---|---|
| **Журнал** | состав редакции: приёмы, повышения, понижения, увольнения, сроки до следующего ранга, лимиты должностей | ядро (SFN Logs) |
| **Поиск** | найти игрока в журнале Evolve Logs и сразу поставить в состав | ядро (SFN Logs)
| **Фото** | недельные лимиты фото игроков и мест, метки `[V]`/`[X]` прямо в заказ-диалоге папарацци | `sfn_photo_helper.lua` v13.4.1 |
| **Эфир** | викторины в эфире (математика, анаграммы, вышибалы), счёт, речи, топ, реклама, скриншоты | `sfn_efir_helper.lua` v7.0.1 |
| **Соцопрос** | социальный опрос игроков и раздача листовок: цикл по стадиям, скриншоты, базы | `sfn_social.lua` v4.0 |
| **Настройки** | окно, состав из игры, данные Evolve Logs, обновления + по секции на модуль | — |
| **О скрипте** | версия, пути, список модулей | — |

Хоткеи: **F9** — окно, **F11** — вкладка «Эфир», **F10** — вкладка
«Соцопрос» (клавиши меняются в настройках и на вкладках).

Команды: `/sfnhelper` (окно; подкоманды `save`, `export`, `add`, `members`,
`update`, `api`, `ui` и имена вкладок), `/efir`, `/efirlist`, `/efirwhoami`,
`/efirversion`, `/social`, `/socialstart`, `/socialstop`, `/socialreset`,
`/genders`.

### Установка SFN_Helper

```
moonloader\SFN_Helper.lua              <- скрипт
moonloader\lib\fAwesome6_solid.lua     <- иконки FontAwesome 6 (есть в delivery/lib/)
moonloader\lib\mimgui\                 <- стандартная библиотека MoonLoader
moonloader\lib\samp\events.lua         <- SAMPFUNCS: перехват /members, чата, диалогов
```

Данные скрипт держит в `moonloader\SFNHelper\` (журнал, настройки, состояние
обновлений, общая база полов). Модули читают и пишут **прежние** папки своих
скриптов — `sfn_photo_data\` и `sfn_data\`, поэтому переход ничего не теряет.

### Переход с трёх отдельных скриптов

1. Скопируйте `SFN_Helper.lua` в `moonloader\`.
2. Удалите (или выгрузите) `sfn_photo_helper.lua`, `sfn_efir_helper.lua`,
   `sfn_social.lua` — иначе их окна и хоткеи будут дублироваться.
3. В игре введите `/reload`. Данные подхватятся сами: журнал состава и
   настройки переедут из `moonloader\SFNLogs\` в `moonloader\SFNHelper\`
   (исходные файлы не удаляются), фото и соцопрос читаются из
   `sfn_photo_data\`, эфир — из `sfn_data\`, пол игроков при первом запуске
   сливается в общий `SFNHelper\genders.json`. Откат на прежние скрипты
   возможен: ничего не перезаписывается и не удаляется.
4. Доступ к «Эфиру» — по нику (список ведущих перенесён из оригинала); если
   вкладка показывает замок, обратитесь к Jonny Wilde.

---

## SFN Logs — журнал состава

Отдельный скрипт журнала: те же «Журнал», «Поиск», «Настройки», «О скрипте»,
без модулей редакции. Нужен тем, кто пока не хочет ставить помощник целиком.

* инструкция, команды, устройство окна и данные API —
  [`delivery/proekt/README.md`](delivery/proekt/README.md);
* готовый набор для установки — `delivery/moonloader_pack/` и
  `delivery/moonloader_pack.zip`;
* история изменений всех версий — [`CHANGELOG.md`](CHANGELOG.md).

---

## Как устроен репозиторий

```
SFN_Helper.lua                 собранный помощник (ядро + Фото + Эфир + Соцопрос)
SFNLogs.lua                    копия журнала для автообновления игроков
CHANGELOG.md                   история версий SFN Logs и SFN_Helper
SFN_Helper/README.md           куда класть новые скрипты редакции
SFN_Helper/CONTRACT.md         как скрипт становится вкладкой (контракт)
SFN_Helper/inbox/              исходные скрипты редакции (переносятся в модули)
delivery/proekt/               канонический исходник SFN Logs + тесты и инструменты
delivery/proekt/tests/         наборы тестов (lupa + headless-мок mimgui)
delivery/proekt/tools/         sync_delivery.py — синхронизация копий и zip
delivery/proekt/preview/       SVG-превью разделов из реальных вызовов DrawList
delivery/moonloader_pack/      набор для ручной установки
.github/workflows/tests.yml    CI: синтаксис, синхронность копий, все наборы
```

`SFNLogs.lua` лежит в четырёх местах (корень, `delivery/`, `delivery/proekt/`,
`delivery/moonloader_pack/`); канон — `delivery/proekt/SFNLogs.lua`, остальные
копии, превью и zip обновляет `python delivery/proekt/tools/sync_delivery.py`,
а CI проверяет, что копии не разъехались (`--check`).

`SFN_Helper.lua` руками не правится: файл собирается из канонического
`delivery/proekt/SFNLogs.lua` цепочкой сборочных скриптов (ядро → «Фото» →
«Эфир» → общая база полов → «Соцопрос»), поэтому любое изменение ядра
автоматически попадает в помощник.

## Проверка перед коммитом

```bash
pip install lupa pillow pyyaml
python delivery/proekt/tests/run_logic.py          # 554 passed
python delivery/proekt/tests/run_ui.py             # 272 passed
python delivery/proekt/tests/run_api.py            # 149 passed
python delivery/proekt/tests/run_helper_logic.py   # 853 passed
python delivery/proekt/tests/run_helper_ui.py      # 192 passed
python delivery/proekt/tools/sync_delivery.py --check
```

## Теги

`vX.Y.Z` — версии SFN Logs, `helper-vX.Y.Z` — версии SFN_Helper.
