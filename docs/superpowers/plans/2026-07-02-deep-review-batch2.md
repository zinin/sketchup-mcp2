# Deep-Review Batch 2 (P1-остатки + P2 + UX-квиквины) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Закрыть все оставшиеся P1/P2-находки deep-research-аудита (T-05, T-07, T-06, T-11…T-19, T-21…T-23, T-25…T-29), три кандидата финального mesh-ревью батча 1 (MR-1 partial-EOF retry, MR-2 min-dimensions, MR-3 rotated-board coverage) и три живых UX-квиквина (T-50, T-54, T-55) — одним батчем на ветке `fix/deep-review-p2`, финиш — единый PR в master с обоими батчами.

**Architecture:** Проект — мост Claude ↔ SketchUp: Python MCP-сервер (`src/sketchup_mcp/`, FastMCP + persistent TCP-клиент) и Ruby-расширение (`mcp_for_sketchup/mcp_for_sketchup/`, TCP-сервер внутри SketchUp). JSON-RPC 2.0 поверх 4-байтового length-prefix фрейминга. Все правки локальны; wire-протокол и handshake НЕ меняются. Дизайн-первоисточник: `docs/superpowers/specs/2026-07-02-deep-review-batch2-design.md`.

**Tech Stack:** Python ≥3.10 (pytest, pytest-asyncio `asyncio_mode=auto`, pydantic v2/FastMCP, mcp locked `>=1.27,<2`), Ruby 3.2 (minitest, stdlib + rubyzip только в package-тесте), GitHub Actions (уже настроен).

## Global Constraints

- **Единицы:** на границе MCP — миллиметры и градусы; внутри SketchUp — дюймы. Конвертация `MM = 25.4` (`helpers/units.rb`).
- **`Group#subtract` РЕВЕРСИРОВАН:** `A.subtract(B)` возвращает `B − A`. НИКОГДА не «исправлять» порядок аргументов; тесты `test/test_boolean_direction.rb`, `test/test_operation_names.rb` пинят это намеренно.
- **Literal source-guard тесты** пинят точный текст хендлеров (вплоть до отступов): `test/test_operation_names.rb`, `test/test_transform_absolute.rb`, `test/test_joints_frame_compensation.rb`. НИКАКИХ авто-форматтеров; при рефакторинге пины обновлять осознанно, отдельным шагом.
- **Ruby-тесты:** каждый `test/test_*.rb` обязан проходить (a) standalone `ruby test/test_<name>.rb` и (b) в одном процессе `ruby test/run_all.rb`. Глобальные стабы (`module Sketchup`, `module Geom`) — либо guarded (`unless defined?(...)`) для не-реопенимых конструкций (Struct, классы с константами), либо **аддитивный реопен классов** (эталон: шапка `test/test_collect_components.rb`) — реопен предпочтителен, когда файлу нужны конкретные аксессоры: guarded-скип чужого скупого стаба их бы не дал. Singleton-поверхности патчить в `setup`/`teardown` с сохранением `Method`-объекта (эталон: `test/test_collect_components.rb`, патч `Helpers::Entities.active_model!`); ⚠ это касается И модульных `def self.`-методов — они СУТЬ singleton-методы, «снять стаб» через `remove_method` без сохранённого `Method` под run_all удаляет реальный метод насовсем.
- **Прогоны и базлайны на старте батча:** Ruby — `ruby test/run_all.rb` → **354 runs / 939 assertions / 0 failures / 0 errors** (~1.4 с); Python — `uv run pytest tests/ -q` → **136 passed** (~2.4 с). На старте исполнения ПЕРЕПРОГНАТЬ оба базлайна и зафиксировать фактические числа в ledger (счётчики CLAUDE.md могли устареть).
- **Версии не бампаем** (ни `pyproject.toml`/`__init__.py`, ни Ruby `Compat::SERVER_VERSION`, ни `package.rb VERSION`, ни `extension.json`) — все четыре сейчас `0.2.0`. Wire-протокол/handshake не трогаем.
- **Contract break копится:** T-07/T-50/T-54 добавляют параметры, T-27/T-28/T-55 меняют формы ответов. Фиксация — в `docs/release.md`, блок «Pending contract break» (Task 16); MIN-floor'ы здесь НЕ трогаем.
- **Коммиты:** английские, conventional (`fix:`/`test:`/`feat:`/`docs:`), без AI-атрибуции. Рабочая директория — корень репо, ветка `fix/deep-review-p2`.
- **Отчёт-первоисточник** (`docs/deep-research-review-report.md`) закоммичен в ДРУГОЙ ветке (`docs/deep-research-review`); план самодостаточен, идентификаторы T-xx/MR-x — трассировка. ⚠ Номера строк в тикетах датируются 2026-06-12 — искать по содержимому.
- Python-окружение — через `uv` (`uv run pytest tests/ -q`). НЕ трогать `.venv.broken-task8/` и untracked-мусор корня до Task 16.

## Карта задач

| # | Тикеты | Суть | Волна |
|---|---|---|---|
| 1 | T-12, T-26 | config.py: валидация ENV + тест-гигиена reload | 1: Python-ядро |
| 2 | T-11 | connection.py: UnicodeDecodeError + голый OSError | 1 |
| 3 | MR-1 | retry read-only при partial-EOF | 1 |
| 4 | T-21, T-22 | версии: metadata-тест + Ruby-тройка; валидация через реальные схемы | 1 |
| 5 | T-06 | entity id как int \| str | 2: сигнатуры |
| 6 | T-50, T-54 | create_component: name + видимый дефолт dimensions | 2 |
| 7 | T-07 | пагинация list/find + быстрый get_component_info | 2 |
| 8 | T-55 | пустой bbox → null вместо сентинела 2.54e31 | 2 |
| 9 | T-28 | скриншот: метаданные width/height/preset/style | 2 |
| 10 | T-13 | server.rb: батч устойчивости ×5 | 3: Ruby-надёжность |
| 11 | T-14, T-15, T-19, T-27 | compat-сообщение, OBJ-ключ, Logger-guard, export-warning | 3 |
| 12 | T-16 | make_unique перед мутацией definition-entities | 3 |
| 13 | T-17, MR-2, T-18 | валидация параметров + min-dims + case-insensitive поиск | 3 |
| 14 | T-23, MR-3 | Ruby-тестовые пробелы + rotated-board coverage | 4: тесты/контракт |
| 15 | T-05 | докстринг-оверхол 22 тулов + prompts.py sync | 4 |
| 16 | T-25, T-29 | зачистка доков, .gitignore, entry-points, release.md | 5: финиш |
| 17 | — | финальная верификация, счётчики, smoke-синк | 5 |

Порядок строгий: 5–9 (сигнатуры) до 15 (T-05 документирует финальное API); 10 до 14 (T-23 тестирует новые пути server.rb); 13 до 15 (валидация меняет схемы); 16–17 последними. Задачи 7, 8, 13 трогают `handlers/model.rb` — выполнять последовательно, не параллелить.

---

### Task 1: config.py — валидация ENV-переменных (T-12) + тест-гигиена reload (T-26)

✅ Done — see commits: `5b32278` (T-12), `82b9093` (T-26)

### Task 2: connection.py — дыры таксономии исключений (T-11)

✅ Done — see commit: `a486f86`

### Task 3: retry read-only тулов при partial-EOF (MR-1)

✅ Done — see commit: `c054fdc`

### Task 4: Версионные guard'ы и валидация через реальные схемы (T-21 + T-22)

✅ Done — see commit: `4685036`

### Task 5: Entity id как `int | str` (T-06)

✅ Done — see commit: `31733a5`

### Task 6: create_component — `name` + видимый дефолт dimensions (T-54 + T-50)

✅ Done — see commit: `27e1fb5`

### Task 7: Пагинация интроспекции + быстрый lookup (T-07)

✅ Done — see commit: `48eb213`

### Task 8: Пустой bbox → null вместо сентинела 2.54e31 (T-55)

✅ Done — see commit: `889293e` (incl. 4 sanctioned require_relative lines in legacy test headers — see .superpowers/sdd/progress.md)

### Task 9: Скриншот — метаданные width/height/preset/style (T-28)

✅ Done — see commit: `aa9aa39`

### Task 10: server.rb — батч устойчивости ×5 (T-13)

✅ Done — see commits: `34bd3db`, `390ba6d`, `c29c590`, `85688af`, `43e2d88` (5 sub-fixes T-13.1–13.5)

### Task 11: Ruby-мелочь — compat-сообщение, OBJ-ключ, Logger-guard, export-warning (T-14 + T-15 + T-19 + T-27)

✅ Done — see commits: `ac01d80`, `74c5955`, `d4cb531`, `bca648f` (T-14, T-15, T-19, T-27)

### Task 12: make_unique перед мутацией definition-entities (T-16)

✅ Done — see commit: `ef85f89`

### Task 13: Валидация параметров + min-dims + case-insensitive поиск (T-17 + MR-2 + T-18)

✅ Done — see commit: `16fed5e` (incl. LOOKUP_MAX_DEPTH comment fix — ACTION from Task 7 review)

### Task 14: Ruby-тестовые пробелы + rotated-board coverage (T-23 + MR-3)

✅ Done — see commits: `aee1edb`, `07f6526`, `ecd3e01`, `2194e7e`, `5e545f4` (5th commit = controller-sanctioned T-55 follow-up pins, see .superpowers/sdd/progress.md)

### Task 15: Докстринг-оверхол всех 22 тулов + синк prompts.py (T-05)

✅ Done — see commits: `06ecbf2`, `c32c865` (review fix: get_selection per-entity response shape)

### Task 16: Зачистка документации + entry-points + release.md (T-25 + T-29)

✅ Done — see commits: `e64c24e` (T-25 docs), `b794c14` (T-29 build)

### Task 17: Финальная верификация, счётчики, smoke-синк

✅ Done — see commit: `d51b15f` (counters 415 runs / 1109 assertions + 176 passed; pagination asserts in smoke)

---

## После плана (вне задач — исполнителю и владельцу)

1. **Финальное whole-branch mesh-ревью** (по образцу батча 1: `/claude-mesh:mesh-review default`) — диф двух батчей; per-task ревью уже несут основную нагрузку.
2. **Перед PR:** `git rm -r docs/superpowers/ && git commit` (ветка трекает P1-план, 2 review-спеки, дизайн и план батча 2, а также merged/iter-файлы дизайн-ревью — в PR-дифф не попадают, остаются в истории ветки). ⚠ C-02: git rm снимает ТОЛЬКО tracked; untracked prompt-файлы в `docs/superpowers/plans/` останутся в рабочем дереве — осознанно, это локальный архив владельца, в PR они не попадают. Затем единый PR `fix/deep-review-p2` → master, включающий ОБА батча. В описании PR напомнить владельцу 5 автономных решений батча 1 (см. ledger: пред-фикс `165f214`; commit message «3.10-3.13»; 136 vs «ровно 135»; deepseek принят REAL; спорный source-guard `5de1987`).
3. **Живой DoD:** ✅ Done 2026-07-03 из сессии (см. ledger, блок «Live verification from session»): smoke **25/25 PASSED**, 0 skipped (eval включён владельцем; split-host 192.168.20.20, .rbz v0.2.0-warehouse @ d51b15f) + **C-10 PASSED** (шаренная через add_instance пара; difference над одной копией не тронул вторую; бонус — set_material сделал make_unique живьём, T-16). T-55 подтверждён живьём: пустая модель → `bounding_box_mm: null`.
4. **Владелец:** рестарт живого MCP-сервера (нужен и для батча 2 — код Python-сервера изменился) → затем `rm -rf .venv.broken-task8/`.
5. **При следующем релизе:** bump MIN-floor'ов ОБЯЗАТЕЛЕН — блок «Pending contract break» в `docs/release.md` дополнен батчем 2 (Task 16.8).
6. **Остаток бэклога отчёта:** P3 (T-31…T-49, T-51…T-53) + продуктовое решение T-47 (физическое исключение eval.rb из warehouse-сборки — принять до сабмита в Extension Warehouse).




