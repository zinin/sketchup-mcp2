## TASK

Continue executing the implementation plan for **Deep-Review Batch 2** (P1-остатки + P2 + UX-квиквины deep-research-аудита sketchup-mcp2).

Исполнение идёт через `/claude-mesh:do-plan` (обёртка над superpowers:subagent-driven-development с паузой по порогу контекста). Задачи 1–8 из 17 выполнены и отревьюены; сессия остановлена по STOP-порогу 250k на чистом чекпойнте.

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

- Design: `docs/superpowers/specs/2026-07-02-deep-review-batch2-design.md`
- Plan: `docs/superpowers/plans/2026-07-02-deep-review-batch2.md` — **ПОДРЕЗАН** (коммит `d14246a`): задачи 1–8 заменены ✅-строками с коммитами, задачи 9–17 полные (~2350 строк, читать целиком). Полные тексты выполненных задач — в git-истории плана (`e9fd870`, ревью-правки до `1bd6d3c`) и не нужны для продолжения.
- Прогресс-ledger: `.superpowers/sdd/progress.md` — секция «Deep-Review Batch 2» ВНИЗУ файла (батч 1 выше — не перезаписывать, только дописывать вниз). Читать полностью секцию батча 2: там DEVIATION/ACTION/CANDIDATE-записи, обязательные к учёту.
- Лог дизайн-ревью (по необходимости): `docs/superpowers/specs/2026-07-02-deep-review-batch2-review-iter-1.md`

## PROGRESS

**Completed (все с per-task ревью: spec ✅ + quality approved; ledger-записи есть):**
- [x] Task 1: config.py валидация ENV + reload-фикстура — `5b32278`, `82b9093`
- [x] Task 2: connection.py таксономия исключений — `a486f86`
- [x] Task 3: retry read-only при partial-EOF (MR-1) — `c054fdc`
- [x] Task 4: версионные guard'ы + схемо-тесты, фикстура dispatch_conn — `4685036`
- [x] Task 5: EntityId int|str (14 id-параметров) — `31733a5`
- [x] Task 6: create_component name + дефолт [100,100,100] — `27e1fb5`
- [x] Task 7: пагинация list/find + early-exit lookup — `48eb213`
- [x] Task 8: пустой bbox → null (T-55) — `889293e` (с санкционированным расширением скоупа, см. ниже)

**Remaining (порядок строгий; 13 после 8 — model.rb последовательно; 10 до 14):**
- [ ] Task 9: скриншот-метаданные (T-28) — СЛЕДУЮЩАЯ
- [ ] Task 10: server.rb батч устойчивости ×5 (T-13) — 5 под-коммитов
- [ ] Task 11: compat-msg, OBJ-ключ, Logger-guard, export-warning — 4 мини-цикла
- [ ] Task 12: make_unique перед мутацией (T-16)
- [ ] Task 13: валидация параметров + min-dims + case-insensitive поиск (T-17, MR-2, T-18)
- [ ] Task 14: Ruby gap-тесты + rotated-board (T-23, MR-3) — только тесты
- [ ] Task 15: докстринг-оверхол 22 тулов + prompts.py (T-05)
- [ ] Task 16: зачистка доков/gitignore/entry-points/release.md (T-25, T-29)
- [ ] Task 17: финальная верификация, счётчики, smoke-синк

## SESSION CONTEXT

**Git:** ветка `fix/deep-review-p2`, HEAD `d14246a` (trim-коммит поверх `889293e`). История батча 2: `5cd4b2d` (дизайн) → `e9fd870` (план) → `7dd2539`/`66ac538`/`8ca5137`/`1bd6d3c` (дизайн-ревью) → задачи 1–8 → `d14246a`. Tracked-дерево чистое.

**Верифицированные счётчики на HEAD:** Python `uv run pytest tests/ -q` → **167 passed**; Ruby `ruby test/run_all.rb` → **371 runs / 978 assertions / 0 failures**. (Стартовые базлайны 136/354/939 перепрогнаны и зафиксированы в ledger.)

**Оставшиеся счётчики-гейты Python:** Task 9 → 168, Task 12 → 168 (не задет), Task 13 → 171, Task 15 → 176. Ruby-ожидания — в тексте задач плана (Task 8 дал 371/978). Финальные ориентиры Task 17: Python 176, Ruby ~417 runs — ориентиры мягкие, авторитетен фактический прогон (при 0 failures расхождение фиксировать в ledger, не «чинить»).

**Механика исполнения (как это работало):**
- `/claude-mesh:do-plan` без аргумента: порог 250k из config, `dispatch_model=fable` → КАЖДЫЙ Agent-диспатч с `model: "fable"`; полный ригор ревью, токены не экономить.
- Скрипты скилла: `task-brief PLAN N` и `review-package BASE HEAD` из `$(find ~/.claude/plugins -path '*superpowers*/skills/subagent-driven-development/scripts' ...)`. Брифы/отчёты: `.superpowers/sdd/task-N-brief.md` / `task-N-report.md` (имплементер пишет отчёт в файл, возвращает <15 строк). BASE фиксировать ДО диспатча имплементера (не HEAD~1 — задачи бывают многокоммитные, Task 10 = 5 коммитов!).
- Ревьюер получает: бриф + отчёт + diff-файл + вербатим-констрейнты; Minor-находки НЕ чинятся в задаче — копятся в ledger для финального whole-branch ревью (конвенция сессии, прецедент батча 1).
- Сабагенты иногда уходят в idle не прислав отчёт — SendMessage тому же агенту, НЕ спавнить дубликат.

**⚠ Паттерн «benign RED-описки брифов» (Tasks 5/6/7, все адъюдицированы ревьюерами):** mcp 1.27 `ArgModelBase` использует pydantic `extra="ignore"` — неизвестные аргументы call_tool МОЛЧА отбрасываются. Поэтому RED-прогнозы брифов вида «unexpected keyword» материализуются как KeyError / DID-NOT-RAISE / mock-mismatch, и тальи брифов бывают арифметически недостижимы на их же коде. Протокол: имплементер документирует расхождение per-test и продолжает ТОЛЬКО если все содержательные причины совпали и тесты транскрибированы вербатим; ревьюер адъюдицирует независимо; в ledger — DEVIATION (plan-side). СТРУКТУРНО иной RED (NameError из стабов и т.п.) = реальный СТОП → BLOCKED (Task 8 это доказал).

**⚠ Task 8 — санкционированное расширение скоупа (DEVIATION в ledger, surface to owner):** перевод describe_component/describe_entity на `Helpers::Geometry.empty_bbox?` ломал standalone-прогон 4 legacy-тест-файлов (пустые module-стабы; run_all маскировал порядком загрузки). Контроллер санкционировал по прецеденту батча 1 (`165f214`): по одной строке `require_relative` хелпера geometry в шапках `test_transform_absolute.rb`, `test_geometry_builders.rb`, `test_collect_components.rb`, `test_model_pagination.rb`. Следствие для Tasks 13/14: эти файлы теперь требуют реальный helpers/geometry в шапке — имплементерам это ОЖИДАЕМО, не удивляться и не откатывать. Откат всего решения = убрать 4 строки из `889293e`.

**ACTION при диспатче Task 13 (из ревью Task 7):** включить в бриф-контекст однофразовую правку стейл-комментария над константой `LOOKUP_MAX_DEPTH` в model.rb («get_component_info reuses collect_components (see below)» — имя функции устарело; бриф 3f правил только комментарий метода).

**CANDIDATE при диспатче Task 14 (из ревью Task 8; решить при диспатче — не в тексте плана):** (a) пин строгой `>` семантики empty_bbox? — вырожденный min==max bbox обязан остаться НЕ-null; (b) прямой юнит nil-ветки `describe_entity`. Оба обязаны PASS на текущем коде (легитимный gap-fill той же категории, что T-23).

**Неявные знания плана, актуальные для 9–17 (из планирования, подтверждены):**
- Task 9: аннотация возврата СРАЗУ `-> list:` — `-> list[Image | str]` ПАДАЕТ на регистрации mcp 1.27 (верифицировано пробой); голый str → TextContent автоматически.
- Task 10: hello-ответ клиента с framing-ошибкой НАМЕРЕННО дропается (skip по close_after_response) — тест ждёт ровно 1 фрейм; parse-вариант — 2 фрейма и `stub_write_pending(times: 2)`. ТРИ существующих теста задают `pending_write_deadline_at` через `Time.now` — перевести на монотонные Float (Step 7c), иначе красные. ЕДИНСТВЕННЫЙ ожидаемый красный существующий тест — `test_pending_write_overflow_closes_client` в Step 6 (P-17): план предписывает переработку (малый head-append `"h" * 8` перед `near`) в том же коммите — это НЕ неожиданность.
- Task 11: Save-Method паттерн в стабах T-27 обязателен (`def self.` = singleton; голый remove_method под run_all удаляет реальный метод насовсем).
- Task 12: мутирующих call-sites `entity_collection` ЧЕТЫРЕ (materials apply_to_entity, joints place_tenon + add_parent_frame_prototype, operations run_edge_op); строка `cur_edges` — в ДРУГОМ методе (`find_current_edge_spec`), НЕ трогать.
- Task 13: MR-2 пороги per-type (решение пользователя): box ≥ 0.1 мм, sphere/cylinder/cone ≥ 1.0 мм; polar-chord 0.04 мм; Python `Field(ge=0.1)` — абсолютный floor, per-type — Ruby. Pydantic-коэрция типов оставлена намеренно — «зеркальность» по ГРАНИЦАМ значений.
- Task 14: если gap-тест обнаружит реальный баг — СТОП и в ledger, не чинить молча; MR-3 — обязательная проверка дискриминативности (временная замена `acc.compose(inst[:transformation])` → `acc`, оба теста обязаны упасть).
- Task 15: `tests/test_prompts.py` пинит подстроку `bbox_mm` — правки prompts.py её сохраняют; пины упали → обновить осознанно в том же коммите. Wire-пины обязаны пройти без правок.
- Task 16: `rm diff.patch docs/session-transfer-*.md` ЗДЕСЬ (untracked); `.gemini/` только в .gitignore.
- Номера строк в тикетах датируются 2026-06-12 и уплыли — искать по содержимому.

**Критические инварианты (нарушение = стоп):** `A.subtract(B) == B − A` — НИКОГДА не «чинить»; literal source-guard тесты (`test_operation_names.rb`, `test_transform_absolute.rb`, `test_joints_frame_compensation.rb`) — никаких форматтеров, пины обновлять только осознанно; версии не бампать (все четыре точки 0.2.0); wire-протокол/handshake не трогать; мм на границе MCP; каждый Ruby-тест зелёный standalone И через run_all; коммиты английские conventional без AI-атрибуции.

**Untracked-мусор:** НЕ трогать `.venv.broken-task8/` (владелец удалит после рестарта живого MCP-сервера), `.gemini/`, `.superpowers/`, `docs/superpowers/plans/*prompt*.md` (включая этот файл — они untracked-архив владельца). `diff.patch` и `docs/session-transfer-*.md` удаляются ТОЛЬКО в Task 16.

**После плана (вне 17 задач):** финальное whole-branch mesh-ревью (`/claude-mesh:mesh-review default`, дифф двух батчей) → `git rm -r docs/superpowers/ && git commit` (снимет только tracked) → ОДИН PR `fix/deep-review-p2` → master с обоими батчами. В PR напомнить владельцу 5 автономных решений батча 1: (1) пред-фикс хрупкого теста `165f214`; (2) commit message «3.10-3.13»; (3) 136 passed вместо «ровно 135»; (4) deepseek/v4-pro принят REAL вопреки guard-эвристике; (5) спорный source-guard `5de1987` по таймауту (откат = `git revert 5de1987`). Плюс девиации батча 2 из ledger (Task 8 scope extension — главная). Ручные шаги владельца: live-smoke 25 шагов на SketchUp 2026 + пункт C-10 (boolean над копией шаренной группы), рестарт MCP-сервера → `rm -rf .venv.broken-task8/`, bump MIN-floor'ов при релизе.

## PLAN QUALITY WARNING

The plan was written for a large task and may contain errors, oversights, or assumptions that don't match the codebase (три benign RED-описки и один реальный standalone-пробел уже найдены — см. выше).

**If you notice any issues during implementation:**
1. STOP before proceeding with the problematic step
2. Clearly describe the problem you found
3. Explain why the plan doesn't work or seems incorrect
4. Ask the user how to proceed

Do NOT silently work around plan issues or make significant deviations without user approval. Benign-tally протокол (см. SESSION CONTEXT) — единственное санкционированное исключение; структурные расхождения — всегда СТОП.

## INSTRUCTIONS

1. Read the documents listed above (план читать целиком — он подрезан; ledger-секцию батча 2 — полностью)
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any implementation
5. Ask: "What would you like me to work on?"
