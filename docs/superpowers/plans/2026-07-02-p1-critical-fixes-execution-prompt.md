## TASK

Execute the implementation plan for **P1 Critical Fixes (deep-research review, батч 1)** — закрытие критических находок аудита sketchup-mcp2 (9 тикетов: T-30, T-09, T-01, T-10, T-02, T-04, T-03, T-08, T-24 + финальная верификация).

Use `/superpowers:subagent-driven-development` skill for execution.

## DOCUMENTS

- Design: **отсутствует** (дизайн-фазы не было; спека — отчёт многоагентного аудита `docs/deep-research-review-report.md`, который существует ТОЛЬКО на ветке `docs/deep-research-review` и в рабочем дереве текущей ветки НЕ виден — не искать его; план самодостаточен).
- Plan: `docs/superpowers/plans/2026-07-02-p1-critical-fixes.md`

Read the plan document first.

## IMPORTANT: DO NOT START WORK YET

After reading the documents:
1. Confirm you have loaded all context
2. Summarize your understanding briefly
3. **WAIT for user instruction before taking any action**

Do NOT begin implementation until the user explicitly tells you to start.

## SESSION CONTEXT

**Состояние ветки:**
- Рабочая ветка `fix/deep-review-p1` уже создана от `master`, план закоммичен (коммит `3556860`). Проверить `git branch --show-current`; если сессия не на ней — `git switch fix/deep-review-p1`.
- В рабочем дереве много незакоммиченного мусора (`diff.patch`, `docs/session-transfer-*.md`, `.gemini/`, старые файлы в `docs/superpowers/`) — НЕ трогать, НЕ чистить; в `git add` включать только файлы текущей задачи (в плане каждый коммит перечисляет файлы явно).

**Решения пользователя (2026-07-02), уже вшитые в план:**
- Скоуп батча: «P1-баги + guard'ы» (9 тикетов). T-05/T-07 (LLM-контракт: докстринги всех 22 тулов, пагинация) — сознательно ВНЕ скоупа, отдельным планом позже. Не расширять.
- T-04: выбрана **абсолютная** семантика `position` (вариант «б» отчёта — цель для bbox-min). Отклонены: (а) оставить relative + переименовать параметр; (в) два параметра `position`+`translate`. Wire-имя `position` сохраняется, `rotation`/`scale` остаются относительными.
- T-08: выбран «чистый» вариант (а) — `get_connection()` перестаёт коннектить, появляются `ensure_connected()`/`aclose()` под инстансным `_lock`. Минимальный вариант (writer-identity guard в `disconnect()`) отклонён.
- Ветка — простой `git switch -c` (не worktree) — уже сделано.

**Критические инварианты (нарушение = сломанный проект):**
- `Group#subtract` РЕВЕРСИРОВАН на SketchUp: `A.subtract(B) == B − A`. Официальные доки противоречат сами себе — НИКОГДА не «исправлять» порядок аргументов под доки. Задача 4 закрепляет это тестами.
- Задача 7 обязана сохранить literal call-sites `subtract_tracked(cutter, pin_group)` / `subtract_tracked(cutter, group)` дословно — иначе упадут source-guard'ы задачи 4 (задача 4 исполняется раньше).
- Версии НЕ бампать (ни pyproject `version`, ни Ruby `SERVER_VERSION`); wire-протокол и handshake НЕ трогать.
- mm на границе MCP, дюймы внутри SketchUp (`MM = 25.4`).

**Конвенции Ruby-тестов (без них сьюта флакает):**
- Все `test/test_*.rb` грузятся в ОДИН процесс (`ruby test/run_all.rb`) И запускаются поодиночке. Глобальные стабы (`module Sketchup`, `module Geom`) — только guarded (`unless defined?`); общие singleton-поверхности патчить в `setup`/`teardown` с сохранением `Method`-объекта. Эталоны: `test_collect_components.rb:232-236` (патч `Helpers::Entities.active_model!`), `test_helpers_geometry.rb` (runtime-патч Geom). Новые тест-файлы плана уже написаны по этой конвенции — не «упрощать» их.

**Порядок задач обязателен:**
- Task 6 (absolute position) — строго ДО Task 9 (smoke использует новую семантику).
- Tasks 3, 5, 7 — до Task 9 (smoke-шаги проверяют эти фиксы).
- Task 4 — до Task 7 (guard'ы должны пережить переписывание joints.rb).

**Известные острые места / edge cases:**
- Task 1: `uv lock` требует сети; если сети нет — остановиться и спросить, НЕ коммитить pyproject без обновлённого lock.
- Task 7, Step 2 (red-прогон): красными должны быть только три bbox-ассерта; `test_scratch_prototypes_are_erased_from_model_root` на старом коде vacuously зелёный — это ожидаемо.
- Task 8: два существующих теста ПЕРЕПИСЫВАЮТСЯ (`test_get_connection_raises_connection_error_when_refused` → два новых; cold-start race тест — новое тело). Существующие тесты `tests/test_app.py` фикс НЕ ломает (они мокают `get_connection` целиком). Если какой-то другой тест мокал старое «get_connection коннектит» — чинить мок по двухфазному образцу (`get_connection` + `ensure_connected`), не ослаблять прод-код.
- Task 8, тест `test_aclose_cannot_clobber_concurrent_reconnect`: скедулинг на `await asyncio.sleep(0)` — если наблюдается flakiness, добавить ещё один `sleep(0)` после создания задач (не увеличивать таймауты).
- Task 9: в сессии проверяется только синтаксис + pytest (`tests/test_smoke_helpers.py` импортирует smoke-модуль). Живой прогон smoke — РУЧНОЙ шаг вне сессии: пересобрать `.rbz`, установить в SketchUp 2026, запустить `uv run python examples/smoke_check.py`. Это definition of done для T-01/T-02/T-03, но не блокер завершения плана.
- Базлайн тестов до старта: Ruby `327 runs / 844 assertions / 0 failures`; Python `132 passed`. Task 10 обновляет счётчики в CLAUDE.md/README фактическими числами после всех задач.

**После завершения плана (напоминания владельцу, уже в хвосте плана):**
- Перед созданием PR: `git rm -r docs/superpowers/` + commit — план и этот промпт не должны попасть в diff PR (конвенция пользователя).
- При следующем релизе рассмотреть поднятие MIN-floor'ов совместимости (семантика `position` изменилась).

## PLAN QUALITY WARNING

The plan was written for a large task and may contain:
- Errors or inaccuracies in implementation details
- Oversights about edge cases or dependencies
- Assumptions that don't match the actual codebase
- Missing steps or incomplete instructions

**If you notice any issues during implementation:**
1. STOP before proceeding with the problematic step
2. Clearly describe the problem you found
3. Explain why the plan doesn't work or seems incorrect
4. Ask the user how to proceed

Do NOT silently work around plan issues or make significant deviations without user approval.
