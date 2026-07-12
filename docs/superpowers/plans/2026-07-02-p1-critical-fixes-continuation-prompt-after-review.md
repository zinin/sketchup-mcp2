## TASK

Execute the implementation plan for **P1 Critical Fixes (deep-research review, батч 1)** — 10 задач (тикеты T-30, T-09, T-01, T-10, T-02, T-04, T-03, T-08, T-24 + финальная верификация). План — **пост-ревью версия**: прошёл multi-agent design review (7 ревьюеров, 38 замечаний, все решения вшиты в текст плана).

Use `/superpowers:subagent-driven-development` skill for execution.

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start implementing tasks
- Make any code changes
- Run any commands (except reading documents)
- Assume what task to work on next

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS

- Design: **отсутствует** (дизайн-фазы не было; первоисточник — отчёт аудита `docs/deep-research-review-report.md` — существует ТОЛЬКО на ветке `docs/deep-research-review`, в рабочем дереве его НЕТ — не искать; план самодостаточен).
- Plan: `docs/superpowers/plans/2026-07-02-p1-critical-fixes.md` — читать ПЕРВЫМ; это обновлённая после ревью версия (коммиты `133538f` auto-fixes + `dafb5b0` decisions).
- Review log (справочно, читать при вопросах «почему так»): `docs/superpowers/specs/2026-07-02-p1-critical-fixes-review-iter-1.md` — решения по всем 38 замечаниям.
- ⚠ Файл `2026-07-02-p1-critical-fixes-execution-prompt.md` (в той же папке) — ПРЕДЫДУЩАЯ версия этого промпта, его session-context частично устарел (red/green-ожидания задач 3/7, sleep(0)-советы Task 8). НЕ использовать; данный файл его заменяет.

## PROGRESS

**Completed:**
- [x] План написан и закоммичен (`3556860`)
- [x] Multi-agent design review, итерация 1: 38 замечаний → 32 авто-фикса + 3 решения + 3 отклонения; план обновлён (`133538f`, `dafb5b0`)

**Remaining (порядок обязателен):**
- [ ] Task 1: cap `mcp[cli]>=1.27,<2` + `git rm requirements.txt` + `uv lock`
- [ ] Task 2: CI GitHub Actions (Ruby 3.2 + Python **3.10**–3.13, `--frozen`, `permissions`, кэш) + бейдж
- [ ] Task 3: eval_ruby — `rescue Exception` (re-raise NoMemoryError/SignalException) → `-32603` с диагностикой; **5** новых тестов
- [ ] Task 4: пины реверса `Group#subtract` — **5** source-guard'ов + поведенческий duck-typed тест; адверсариальная проверка тремя раздельными флипами
- [ ] Task 5: build_sphere — полюсные треугольники (manifold) + валидация `segments >= 3` (Step 3b) + калибровка оракула
- [ ] Task 6: `position` = АБСОЛЮТНАЯ цель bbox-min, применяется **ПОСЛЕДНЕЙ** (rotation → scale → position); pure-хелпер + source-guard + поведенческий fake-тест хендлера (Step 4b)
- [ ] Task 7: joints — carve-хелперы через world-frame prototype с компенсацией `board.transformation.inverse`; literal call-sites `subtract_tracked(cutter, …)` дословно
- [ ] Task 8: connection.py — `get_connection()` не коннектит; `ensure_connected()`/`aclose()` под `conn._lock`; `close_connection()` под `_get_connection_lock`; итог **135 passed**
- [ ] Task 9: smoke 22→25 шагов (сфера+union, dovetail на сдвинутой доске + идемпотентность position, eval-syntax-error)
- [ ] Task 10: финальные прогоны + актуализация счётчиков в CLAUDE.md/README

## SESSION CONTEXT

**Состояние ветки:** `fix/deep-review-p1`, HEAD = `dafb5b0`. В дереве незакоммиченный мусор (`diff.patch`, `docs/session-transfer-*`, `.gemini/`, старые файлы `docs/superpowers/`) — НЕ трогать, НЕ чистить; `git add` только файлы текущей задачи (каждый коммит плана перечисляет файлы явно; в Task 1 удаление стейджит `git rm`).

**Решения пользователя (2026-07-02), вшиты в план:**
- Скоуп: «P1-баги + guard'ы», 9 тикетов. T-05/T-07 (докстринги 22 тулов, пагинация) — ВНЕ скоупа, не расширять.
- T-04: АБСОЛЮТНАЯ семантика `position` (цель bbox-min); wire-имя сохраняется; rotation/scale относительные.
- T-08: «чистый» вариант — get_connection не коннектит, ensure_connected()/aclose() под инстансным `_lock`.

**Решения ревью iter-1 (2026-07-02), вшиты в план:**
- **CRIT-5 ⚠:** порядок применения `rotation → scale → position` (position ПОСЛЕДНЕЙ; дельта от пост-трансформационного `bounds.min`) — обещание «bbox-min ровно в цели» безусловно. Принято оркестратором ревью по рекомендации БЕЗ ответа пользователя (был AFK). Если пользователь велит пересмотреть — правки в 4 местах Task 6 (Interfaces, NOTE-комментарий, докстринг, prompts.py) + Interfaces-фраза.
- **MAJOR-4:** eval.rb ловит `Exception` (re-raise только `NoMemoryError`/`SignalException`; `SystemExit` конвертируется намеренно — `exit` из LLM-кода не должен убивать SketchUp). Dispatch belt-and-braces остаётся `ScriptError, SystemStackError`.
- **CRIT-4:** `requirements.txt` — мёртвый реликт форка, удаляется в Task 1 (Step 1b).
- Полный лог всех 38 решений — в review-iter-1 файле.

**Критические инварианты (нарушение = сломанный проект):**
- `Group#subtract` РЕВЕРСИРОВАН: `A.subtract(B) == B − A`. НИКОГДА не «исправлять» порядок под официальные доки. Task 4 закрепляет пятью guard'ами + поведенческим тестом.
- Task 7 обязан сохранить literal call-sites `subtract_tracked(cutter, pin_group)` / `subtract_tracked(cutter, group)` дословно (guard'ы Task 4 исполняются раньше).
- Версии НЕ бампать (ни pyproject, ни `SERVER_VERSION`); wire-протокол/handshake НЕ трогать.
- mm на границе MCP, дюймы внутри SketchUp (`MM = 25.4`).

**Конвенции Ruby-тестов (без них сьюта флакает):** все `test/test_*.rb` грузятся в ОДИН процесс (`ruby test/run_all.rb`) И запускаются поодиночке; глобальные стабы — только guarded (`unless defined?`); singleton-поверхности патчить в setup/teardown с восстановлением Method-объекта (эталоны: `test_collect_components.rb:232-236`, `test_helpers_geometry.rb`). Новые тест-файлы плана уже написаны по конвенции — не «упрощать».

**Порядок задач обязателен:** 4 → до 7 (guard'ы должны пережить переписывание joints.rb); 6 → до 9; 3, 5, 7 → до 9.

**Острые места / ожидания red-прогонов (ПОСЛЕ ревью — отличаются от старого промпта):**
- Task 1: `uv lock` требует сети; нет сети — остановиться и спросить. НЕ коммитить pyproject без обновлённого lock.
- Task 2: локальная проверка floor `uv run --python 3.10 pytest tests/ -q`; если 3.10 падает — СТОП и обсуждение с владельцем (не выкидывать из матрицы молча).
- Task 3, Step 2 (red): **5** новых тестов красные — 4 неперехваченным исключением (SyntaxError / SystemStackError / Exception / ScriptError), 1 ассертом (message без префикса класса).
- Task 4, Step 5: три АДВЕРСАРИАЛЬНЫХ флипа, тестовые файлы прогонять ПО ОДНОМУ (minitest игнорирует второй CLI-аргумент); откат точечной правкой, не `git checkout`.
- Task 7, Step 2 (red): красные **четыре** позиции — три bbox-ассерта (двойное смещение x≈60.7..63.3 при допуске 29.5..34.5) + source-пин `test_carve_helpers_route_through_parent_frame_prototype` (старый код не зовёт хелпер). `test_scratch_prototypes_are_erased_from_model_root` на старом коде vacuously зелёный — ожидаемо.
- Task 8: тест `test_aclose_cannot_clobber_concurrent_reconnect` синхронизируется через `started = asyncio.Event()` (уже в плане) — прежний совет «добавить ещё sleep(0) при флаки» УСТАРЕЛ, не применять. Существующие тесты `tests/test_app.py` фикс не ломает (мокают get_connection целиком); если чей-то мок предполагал «get_connection коннектит» — чинить мок по двухфазному образцу, не ослаблять прод-код. Итоговый счётчик: ровно 135 passed.
- Task 9: в сессии проверяется только синтаксис + pytest; живой smoke — РУЧНОЙ шаг вне сессии (SketchUp 2026; при закрытом eval-гейте шаг 22 скипается — для полного DoD T-01 включить eval в Settings или github-сборку, см. «После плана» п.1). Cleanup-список сверить с фактическими живыми переменными smoke (инструкция в Task 9 Step 3).
- Места, где план даёт ИНСТРУКЦИЮ вместо дословного кода (Task 6 Step 4b, Task 8 Step 3e, Task 9 cleanup-сверка): исполнитель адаптирует под фактический код, сохраняя смысл ассертов; при расхождении с реальностью — STOP и доложить.
- Базлайн до старта: Ruby `327 runs / 844 assertions / 0 failures`; Python `132 passed` (подтверждён прогонами в ревью-сессии). Task 10 фиксирует фактические числа после всех задач.

**После завершения плана (напоминания владельцу, есть в хвосте плана):**
- Перед PR: `git rm -r docs/superpowers/` + commit — план/промпты/ревью-логи не должны попасть в diff PR.
- При следующем релизе: ОБЯЗАТЕЛЬНО поднять MIN-floor'ы совместимости (семантика `position` изменилась).

## PLAN QUALITY WARNING

План прошёл 7-агентное ревью, но всё ещё может содержать ошибки в деталях, пропущенные edge cases и предположения, не совпадающие с кодовой базой.

**If you notice any issues during implementation:**
1. STOP before proceeding with the problematic step
2. Clearly describe the problem you found
3. Explain why the plan doesn't work or seems incorrect
4. Ask the user how to proceed

Do NOT silently work around plan issues or make significant deviations without user approval.

## INSTRUCTIONS

1. Read the documents listed above (plan первым)
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any implementation
5. Ask: "What would you like me to work on?"
