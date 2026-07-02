# P1 Critical Fixes (deep-research review, батч 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Закрыть критический батч находок многоагентного аудита (тикеты T-30, T-09, T-01, T-10, T-02, T-04, T-03, T-08, T-24 из `docs/deep-research-review-report.md`, ветка `docs/deep-research-review`): срочный cap зависимости mcp, CI, четыре живо-подтверждённых бага, гонка локов, guard-тесты и расширение smoke-матрицы.

**Architecture:** Проект — мост Claude ↔ SketchUp из двух компонентов: Python MCP-сервер (`src/sketchup_mcp/`, FastMCP + persistent TCP-клиент) и Ruby-расширение SketchUp (`mcp_for_sketchup/mcp_for_sketchup/`, TCP-сервер внутри SketchUp, обработчики в `handlers/*`). JSON-RPC 2.0 поверх 4-байтового length-prefix фрейминга. Все фиксы локальны, wire-протокол и handshake НЕ меняются.

**Tech Stack:** Python ≥3.10 (pytest, pytest-asyncio `asyncio_mode=auto`, pydantic/FastMCP), Ruby 3.2 (minitest, stdlib-only + rubyzip у одного существующего теста), GitHub Actions.

## Global Constraints

- **Единицы:** на границе MCP — миллиметры и градусы; внутри SketchUp — дюймы. Конвертация `MM = 25.4` (`helpers/units.rb`: `U.mm_to_inch` / `U.inch_to_mm`).
- **`Group#subtract` РЕВЕРСИРОВАН:** `A.subtract(B)` возвращает `B − A` (проверено эмпирически на SketchUp 2026; официальные доки противоречат сами себе). Чтобы получить «target − tool», зовут `tool.subtract(target)`. НИКОГДА не «исправлять» порядок аргументов — задача 4 как раз закрепляет это тестами.
- **Ruby-тесты:** все файлы `test/test_*.rb` (a) запускаются по одному (`ruby test/test_<name>.rb`) и (b) грузятся в ОДИН процесс через `ruby test/run_all.rb`. Поэтому: глобальные стабы (`module Sketchup`, `module Geom`) — только guarded (`unless defined?(...)`); общие singleton-поверхности не переопределять на уровне load, а патчить в `setup`/`teardown` с сохранением/восстановлением `Method`-объекта. Эталон паттерна: `test/test_collect_components.rb:232-236` (патчит `Helpers::Entities.active_model!`), `test/test_helpers_geometry.rb` (runtime-патч методов Geom::BoundingBox).
- **Прогоны:** Ruby — `ruby test/run_all.rb` (~1.3 с, базлайн 327 runs / 844 assertions / 0 failures); Python — `uv run pytest tests/ -q` (~2.4 с, базлайн 132 passed).
- **Версии не бампаем** (ни `pyproject.toml` version, ни Ruby `Compat::SERVER_VERSION`) — релизный флоу отдельный (`docs/release.md`). После мержа при релизе рекомендуется поднять MIN-floor'ы совместимости (семантика `position` меняется — см. задачу 6), но это решение релиз-времени, не этого плана.
- **Коммиты:** английские, conventional (`fix:`/`test:`/`ci:`/`build:`/`feat:`/`docs:`), без AI-атрибуции. Рабочая директория — корень репозитория, ветка `fix/deep-review-p1`.
- **Отчёт-первоисточник** (`docs/deep-research-review-report.md`) закоммичен в ДРУГОЙ ветке (`docs/deep-research-review`) и в рабочем дереве этой ветки ОТСУТСТВУЕТ — план самодостаточен, ссылки на тикеты (T-xx) и находки (RB-H-xx и т.п.) — только идентификаторы для трассировки.

## Карта задач → тикеты отчёта

| Задача | Тикет | Суть | Файлы-мишени |
|---|---|---|---|
| 1 | T-30 | cap `mcp<2` (v2 с breaking changes — июль 2026) | `pyproject.toml` |
| 2 | T-09 | CI: GitHub Actions, Ruby + Python matrix | `.github/workflows/test.yml`, `README.md` |
| 3 | T-01 | `eval_ruby("def broken(")` вешает клиента на 60 с | `handlers/eval.rb`, `handlers/dispatch.rb` |
| 4 | T-10 | Реверс `Group#subtract` не закреплён ни одним тестом | `test/`, `handlers/operations.rb` (комментарий) |
| 5 | T-02 | Сферы non-manifold: полюсные грани молча выбрасываются | `handlers/geometry.rb` |
| 6 | T-04 | `transform_component.position` — relative, подан как absolute → делаем ABSOLUTE | `handlers/geometry.rb`, `tools.py`, `prompts.py`, `smoke_check.py` |
| 7 | T-03 | dovetail/finger режут мимо на сдвинутых досках (смешение систем координат) | `handlers/joints.rb` |
| 8 | T-08 | Гонка двух локов: connect/disconnect затирают чужой сокет | `connection.py`, `app.py`, `tools.py` |
| 9 | T-24 | Smoke-матрица: сфера+boolean, dovetail на сдвинутой доске, eval-syntax-error | `examples/smoke_check.py`, `CLAUDE.md` |
| 10 | — | Финальная верификация, актуализация счётчиков тестов в доках | `CLAUDE.md`, `README.md` |

Порядок исполнения = порядок задач: 6 (absolute position) обязана идти ДО 9 (smoke использует новую семантику); 3, 5, 7 — до 9 (smoke-шаги проверяют эти фиксы).

---

### Task 1: Cap зависимости `mcp` ниже 2.0 (T-30)

✅ Done — commit `d708aa4`. Ревью: clean.

---

### Task 2: CI — GitHub Actions (T-09)

✅ Done — commits `165f214` (санкционированный пред-фикс version-fragile теста `test_send_command_lock_serializes_concurrent` — падал на py3.10 И py3.11, причина gh-96764; поднятие floor запрещено Global Constraints, поэтому «чинить») + `f6a9789` (workflow + бейдж; в commit message фактическая матрица «3.10-3.13» вместо устаревшей строки плана). Матрица 3.10–3.13 локально зелёная. Ревью: clean.

---

### Task 3: `eval_ruby` с SyntaxError — мгновенная диагностика вместо 60-секундного зависания (T-01)

✅ Done — commit `d6fcf95`. Red-прогноз совпал дословно; +5 тестов. Ревью: clean.

---

### Task 4: Закрепить тестами реверс `Group#subtract` (T-10)

✅ Done — commit `4eaaf29`. Адверсариальные флипы 3/3 подтверждены. Ревью: clean.

---

### Task 5: Сферы manifold — треугольники на полюсах вместо молча выброшенных граней (T-02)

✅ Done — commit `0595125`. Калибровка оракула пройдена. Ревью: clean.

---

### Task 6: `transform_component.position` — абсолютная семантика (T-04)

✅ Done — commit `6b7d133` (feat!). Step 4b fake-тест дискриминирует старую семантику (15-vs-5). Ревью: clean.

---

### Task 7: Joints — построение в правильной системе координат (T-03)

✅ Done — commit `942a16c`. Carve-математика идентична старой (проверено по ханкам); пины Task 4 целы. Ревью: clean.

---

### Task 8: `connection.py` — все мутации сокета под одним замком (T-08)

✅ Done — commit `fa25069`. Итог **136 passed** (Step 3e нашёл недостающий send_command-тест и добавил его; план предсказывал 135). Ревью: clean.

---

### Task 9: Расширить smoke-матрицу (T-24)

✅ Done — commit `3e9409e`. Cleanup-список сверен по факту и расширен до 10 ID (MINOR-2). Ревью: clean.

---

### Task 10: Финальная верификация и актуализация доков

✅ Done — commit `d73b7e5`. Фактические счётчики: Ruby 353 runs / 934 assertions / 0 failures; Python 136 passed (независимо перемерено ревьюером). Ревью: clean.

---

## После плана (вне задач — заметки исполнителю и владельцу)

1. **Живой DoD для T-01/T-02/T-03:** пересобрать плагин (`cd mcp_for_sketchup && ruby package.rb --variant=warehouse`), установить `.rbz` в SketchUp 2026, перезапустить сервер плагина и прогнать `uv run python examples/smoke_check.py` — все 25 шагов зелёные. ⚠ На warehouse-сборке eval по умолчанию ВЫКЛЮЧЕН — шаг 22 (eval syntax error) при закрытом гейте скипается через `_maybe_skip_eval`, и live-DoD T-01 НЕ выполняется. Для полного DoD перед прогоном включить «Enable Ruby evaluation» в Settings (или собрать/поставить `--variant=github`); прогон с закрытым гейтом закрывает T-01 только юнит-тестами задачи 3. Это ручной шаг (нужен живой SketchUp).
2. **Перед созданием PR:** по конвенции проекта `git rm -r docs/superpowers/ && git commit` — план не должен попасть в diff PR (останется в истории ветки).
3. **При следующем релизе** (docs/release.md): ПОДНЯТЬ MIN_PYTHON (Ruby) / MIN_RUBY (Python) floor'ы — обязательный пункт релизного чеклиста, не «подумать»: семантика `position` изменилась (T-04, `feat!`), смешение старого клиента с новым сервером (и наоборот) даёт ТИХИЕ промахи позиционирования без какой-либо ошибки. В этой ветке floor'ы не трогаем (Global Constraints: версии не бампаем); до релиза новая семантика существует только в этой ветке, риск несёт лишь сам владелец.
4. **Не в этом плане:** T-05/T-07 (LLM-контракт: докстринги всех 22 тулов, пагинация интроспекции) — следующий план; P2-батч (T-06, T-11…T-29) и P3 — по карте тикетов отчёта. Продуктовое решение T-47 (физическое исключение eval.rb из warehouse-сборки) — принять до сабмита в Extension Warehouse.
