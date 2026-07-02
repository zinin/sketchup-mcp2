# Deep-Review Batch 2 — Design (P1-остатки + P2 + UX-квиквины)

**Дата:** 2026-07-02
**Ветка:** `fix/deep-review-p2` (создана `git switch -c` от `fix/deep-review-p1`, HEAD `5de1987`)
**Статус:** одобрен пользователем (brainstorming-сессия 2026-07-02)
**Первоисточник находок:** `docs/deep-research-review-report.md` — закоммичен ТОЛЬКО в ветке
`docs/deep-research-review`, в рабочем дереве этой ветки отсутствует. Идентификаторы `T-xx`
(тикеты) и `PY-*/RB-*/API-*/TEST-*/QUAL-*/D.*` (находки) — трассировка в отчёт. План,
написанный по этому дизайну, обязан быть самодостаточным (конвенция P1-батча).
⚠ Номера строк из отчёта датируются 2026-06-12 и могли уплыть после P1-фиксов — при
написании плана и исполнении искать по содержимому, не по номерам.

## 1. Цель

Закрыть все оставшиеся P1/P2-находки deep-research-аудита плюс три живьём найденных
UX-квиквина из P3, чтобы после единого PR из отчёта остался только модернизационный
P3-бэклог. Батч 1 (ветка `fix/deep-review-p1`, 17 коммитов) закрыл T-30, T-09, T-01, T-10,
T-02, T-04, T-03, T-08, T-24; T-20 закрыт фактически (CI ставит `rubyzip -v '~> 3'`,
CLAUDE.md уточнён; Gemfile сознательно не заводим).

## 2. Скоуп — 23 позиции

### P1-остатки

| № | Размер | Суть | Файлы-мишени |
|---|---|---|---|
| T-05 | M | Оверхол LLM-видимых описаний всех 22 тулов: units (мм/градусы), `Field(description=...)` на каждом параметре, per-type семантика dimensions, строка «Returns:», убрать утёкшие маинтейнерские заметки, перечислить цвета `set_material`, return-семантика `eval_ruby`; синк `prompts.py` с фактическими формами ответов | `tools.py`, `prompts.py` |
| T-07 | M | Пагинация интроспекции: `limit` (дефолт ~50) + `offset` + поля `total`/`truncated` у `list_components`/`find_components`; `response_format: concise\|detailed`; `get_component_info` — lookup по id без полного обхода модели | `handlers/model.rb`, `tools.py` |

### P2

| № | Размер | Суть | Файлы-мишени |
|---|---|---|---|
| T-06 | S | Entity id как `int \| str` во всех id-тулах, пересылка `str(id)` (Ruby `require_id` уже парсит оба); поправить `prompts.py` | `tools.py`, `prompts.py` |
| T-11 | S | Таксономия исключений: `except (json.JSONDecodeError, UnicodeDecodeError)` в обоих parse-местах; голый `OSError` (после ConnectionError-ветки!) → `disconnect()` + `SketchUpError(-32000)`, не `_StaleSocketError` | `connection.py` |
| T-12 | S | Валидация ENV: имя переменной в ошибке парсинга, порт 1..65535, TIMEOUT > 0, warning на неизвестный LOG_LEVEL | `config.py` |
| T-13 | M | Батч устойчивости server.rb ×5: (1) error-envelope при занятом write-буфере — реюз `close_after_response` + глушение чтения; (2) кап диспатча за тик + backpressure с сохранением FIFO; (3) overflow-guard учитывает head-frame отдельно (один легитимный >16 MiB ответ не приговаривает клиента); (4) write-deadline на `Process.clock_gettime(CLOCK_MONOTONIC)`; (5) pre-handshake дедлайн ~30 с (не завершившие hello коннекты закрываются — иначе 64 молчаливых коннекта навсегда исчерпывают слоты) | `core/server.rb` |
| T-14 | S | `msg_python_too_new` не предлагает переустановить уже установленную версию: указывать вперёд (новый .rbz) или назад (`uv pip install sketchup-mcp2==…`); обновить `test_compat.rb` | `core/compat.rb`, `test/test_compat.rb` |
| T-15 | S | Ключ OBJ-экспортёра `double_sided_faces:` → официальный `:doublesided_faces`; заодно сверить все exporter-хеши с официальными таблицами опций | `handlers/export.rb` |
| T-16 | S | `make_unique` перед мутацией definition-entities (покраска/резка одного экземпляра не должна менять все); эффект задокументировать в докстрингах (подхватит T-05) | `helpers/entities.rb`, call-sites (`materials.rb`, `joints.rb`) |
| T-17 | S–M | Валидация параметров: `\|s\| > 1e-9` для scale (на SU2026 `Transformation#inverse` на необратимой кидает ArgumentError); угол dovetail (0,60]; `V.optional_bool/int_positive/number` в `model.rb` (`recursive`/`max_depth`/`name`) и joints-offsets; зеркальные pydantic-констрейнты | `handlers/geometry.rb`, `handlers/joints.rb`, `handlers/model.rb`, `tools.py` |
| T-18 | S | `find_components`: case-insensitive substring (downcase обеих сторон) | `handlers/model.rb` |
| T-19 | S | `defined?(Logger)` → `defined?(Core::Logger)` (паттерн уже есть в `client_state.rb`) | `core/config.rb` |
| T-21 | S | Version-тест через `importlib.metadata.version("sketchup-mcp2") == __version__` вместо тавтологии; Ruby-guard тройки `package.rb VERSION == extension.json == Compat::SERVER_VERSION` | `tests/test_compat.py`, `test/` |
| T-22 | S | Валидационные тесты через `mcp.call_tool(...)` (паттерн из `test_screenshot.py`) вместо локальных TypeAdapter-зеркал; + кейс `transform_component` с position/rotation/scale | `tests/test_tools.py` |
| T-23 | M | Пробелы Ruby-тестов: (1) FIFO-интерливинг между клиентами через spy на `Dispatch.handle` (паттерн `instance_method`/`define_method` уже в файле); (2) кап 50 reads/tick; (3) error-paths dispatch (generic `StandardError → -32603`, eval raises); (4) чистые хелперы (`pick_color`, `filter_edges`, `closest_face`) | `test/` |
| T-25 | S | Зачистка доков: (1) убрать 4 несуществующих example-скрипта из README/CLAUDE.md, вписать реальную пару `smoke_check.py`/`smoke_multi_client.py`; (2) `server.py` — не «Legacy helpers», а live CLI entry point + его докстринг называет неверную команду; `core/client_state.rb` в таблицу core/; (3) названия пунктов меню в paste-verbatim EW-инструкциях («Start» vs «Start Server», release.md, README); (4) висячие ссылки (`helpers/geometry.rb` → cookbook; `settings_dialog.rb` уехавший номер строки); (5) `.gemini/` в `.gitignore`, удалить `diff.patch` и `docs/session-transfer-*` из корня | `README.md`, `CLAUDE.md`, `docs/release.md`, `.gitignore`, комментарии в коде |
| T-26 | S | `tests/test_config.py`: yield-фикстура с повторным `reload_config()` в teardown — модуль config не должен оставаться с чужим окружением | `tests/test_config.py` |
| T-27 | S | `export_scene(skp)` на untitled-модели: поле `warning` в ответе («документ привязан к temp-пути») | `handlers/export.rb` |
| T-28 | S | Скриншот: вернуть `(Image, текстовый блок)` с width/height/preset_used вместо выбрасывания метаданных | `tools.py` |
| T-29 | S | Удалить `[project.entry-points.mcp]` (потребитель неизвестен), переписать комментарий в `app.py` на истинную причину side-effect-импортов | `pyproject.toml`, `app.py` |

### Кандидаты финального mesh-ревью батча 1 (2026-07-02)

| № | Размер | Суть | Файлы-мишени |
|---|---|---|---|
| MR-1 | S | Retry read-only тулов при partial-EOF: `IncompleteReadError` с partial≠b"" сейчас НАМЕРЕННО не ретраится — решение пересматриваем: для `_RETRY_SAFE_TOOLS` обрыв посреди фрейма безопасен. Поведенческий тест обязателен | `connection.py` |
| MR-2 | S | Валидация минимальных dimensions: sub-tolerance радиус сферы сейчас может тихо дать дырявую сетку через last-resort rescue | `handlers/geometry.rb` |
| MR-3 | M | Rotated-board coverage для joints: юнит-фейк покрывает только translation, заявлены только translated-доски | `test/` |

### P3 UX-квиквины (живые находки этапа 2 аудита)

| № | Размер | Суть | Файлы-мишени |
|---|---|---|---|
| T-50 | S | Дефолт `dimensions=[1,1,1]` мм (невидимый кубик) → `[100,100,100]`; параметр НЕ делаем обязательным | `tools.py` |
| T-54 | S | `create_component` принимает опциональный `name` → `group.name=`; снимает часть боли T-18 | `tools.py`, `handlers/geometry.rb` |
| T-55 | S | Пустой bbox не течёт сентинелом `2.54e+31`: при `entity_count == 0` / пустых bounds отдавать `bounding_box_mm: null`; проверить тот же сентинел в `list_components`/`get_component_info` | `handlers/model.rb`, `helpers/` |

## 3. Ветка и PR

- Батч 2 строится ПОВЕРХ P1-фиксов: ветка `fix/deep-review-p2` от `fix/deep-review-p1`
  (HEAD `5de1987`). Отдельная finishing-церемония для P1 отменена — её заменяет финиш
  батча 2.
- В конце — **один PR `fix/deep-review-p2` → master**, включающий оба батча.
- Перед PR: `git rm -r docs/superpowers/ && git commit` (конвенция проекта; ветка трекает
  P1-план, 2 review-спеки и новые дизайн+план батча 2 — в PR-дифф не попадают, остаются в
  истории ветки).
- При создании PR напомнить владельцу 5 автономных решений батча 1, не подтверждённых
  явно: (1) пред-фикс хрупкого теста отдельным коммитом `165f214`; (2) commit message
  «3.10-3.13» вместо устаревшей строки плана; (3) 136 passed вместо «ровно 135»;
  (4) deepseek/v4-pro принят как REAL вопреки guard-эвристике; (5) спорный source-guard
  `5de1987` применён по таймауту (откат = `git revert 5de1987`).

## 4. Структура батча (волны; ~15–17 задач, нарезка за writing-plans)

1. **Python-ядро:** T-12 + T-26 (config) → T-11 + MR-1 (connection.py) → T-21 + T-22
   (pytest-гигиена).
2. **Сигнатурные изменения тулов — строго ДО T-05:** T-06 (int|str id), T-54 + T-50
   (name + видимый дефолт), T-07 (пагинация), T-28 (метаданные скриншота), T-55
   (bbox → null).
3. **Ruby-надёжность:** T-13 (server.rb ×5), кластер мелочи T-14 + T-15 + T-19, T-16
   (make_unique), T-17 + MR-2 (валидация), T-18 (поиск).
4. **Тесты и контракт:** T-23 + MR-3 (Ruby-тестовые пробелы) → **T-05 последним из
   кодовых** — докстринг-оверхол документирует финальное состояние API.
5. **Финиш:** T-25 + T-29 (доки, entry-points) → финальная верификация со счётчиками →
   whole-branch mesh-ревью → `git rm docs/superpowers/` → единый PR.

Порядковые зависимости: T-05 после T-06/T-07/T-28/T-50/T-54/T-16/T-17 (документирует их
итог); T-23 после T-13 (тестирует в т.ч. новые пути server.rb); T-25 последним из
контентных (фиксирует финальные счётчики и состав examples).

## 5. Ключевые решения (одобрены на brainstorming)

- **T-16 — чинить, не документировать:** `make_unique` перед мутацией definition-entities;
  «4 стула краснеют разом» противоречит интуиции модели. Изменение семантики для
  повторных инстансов описывается в докстрингах (T-05).
- **MR-1 — намеренное поведение пересмотрено:** read-only тулы ретраятся и при
  partial-EOF. Существующий комментарий-обоснование в `connection.py` заменить новым.
- **T-50 — дефолт, не обязательность:** `[100,100,100]` мм; ломаем меньше.
- **T-29 — удалить группу**, не искать потребителя.
- **T-25 — полная зачистка**, включая untracked `diff.patch` и `docs/session-transfer-*`,
  `.gemini/` в `.gitignore`. НЕ трогать: `.venv.broken-task8/` (экшн владельца после
  рестарта живого MCP-сервера) и `docs/superpowers/plans/*prompt*.md` (уйдут вместе с
  `git rm -r docs/superpowers/` перед PR).
- **T-13(5) — wire-протокол НЕ меняется:** pre-handshake дедлайн — чисто серверный таймер.

## 6. Тестирование и верификация

- Конвенции батча 1 без изменений: TDD где осмысленно (RED-прогноз до фикса), Ruby-тесты
  проходят standalone И через `run_all.rb`, pytest зелёный; per-task ревью; финальная
  задача обновляет счётчики в CLAUDE.md.
- Стартовые базлайны батча 2: Ruby **354 runs / 939 assertions / 0 failures**, Python
  **136 passed**.
- Изменения форм ответов (T-07, T-28, T-55, T-27) отражаются в юнит-тестах и — где smoke
  уже касается этих путей — в `examples/smoke_check.py` (например, шаг `list_components`
  получает ассерт на `total`).
- Живой 25-шаговый smoke на SketchUp 2026 остаётся ручным шагом владельца (как для P1).
- Финал — whole-branch mesh-ревью (по образцу батча 1).

## 7. Риски и ограничения

- **Global Constraints батча 1 наследуются:** версии НЕ бампаем (ни pyproject, ни
  `Compat::SERVER_VERSION`); wire-протокол/handshake не трогаем; `A.subtract(B) == B − A`
  неприкосновенен; мм на границе MCP, дюймы внутри; коммиты английские conventional без
  AI-атрибуции.
- **Literal source-guard тесты** (`test_operation_names.rb`, `test_transform_absolute.rb`,
  `test_joints_frame_compensation.rb`, guard `carve_board2_slots`) пинят точный текст
  хендлеров — T-13/T-16/T-17 работают рядом; пины обновлять только осознанно, никаких
  форматтеров.
- **Contract break копится:** T-07/T-50/T-54 добавляют параметры, T-55/T-28/T-27 меняют
  формы ответов → дополнить блок «Pending contract break» в `docs/release.md` упоминанием
  батча 2 (bump MIN-floor'ов при релизе уже обязателен из-за T-04).
- Финальному ревью достанется дифф двух батчей — основную нагрузку несут per-task ревью.
- `handlers/model.rb` — горячая точка батча (T-07, T-18, T-17, T-55): задачи волн 2–3,
  которые его трогают, исполнять последовательно, не параллельно.

## 8. Вне скоупа

T-47 (продуктовое решение про физическое исключение `eval.rb` из warehouse-сборки — до
сабмита в Extension Warehouse), остальной P3 (T-31…T-49, T-51–T-53), миграция на mcp v2,
Gemfile, live-smoke прогон (ручной шаг владельца), рестарт MCP-сервера и удаление
`.venv.broken-task8/` (экшн владельца).
