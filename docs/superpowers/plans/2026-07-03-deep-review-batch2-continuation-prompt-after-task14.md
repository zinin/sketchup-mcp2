## TASK

Continue executing the implementation plan for **Deep-Review Batch 2** (P1-остатки + P2 + UX-квиквины deep-research-аудита sketchup-mcp2).

Исполнение идёт через `/claude-mesh:do-plan` (обёртка над superpowers:subagent-driven-development с паузой по порогу контекста). Задачи 1–14 из 17 выполнены и отревьюены; сессия остановлена по STOP-порогу 250k на чистом чекпойнте после Task 14 (пауза через `/claude-mesh:pause-after-current-task`).

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
- Plan: `docs/superpowers/plans/2026-07-02-deep-review-batch2.md` — **ПОДРЕЗАН** (коммиты `d14246a` задачи 1–8, `30a6d30` задачи 9–14): выполненные задачи заменены ✅-строками с коммитами, задачи 15–17 полные (~511 строк, читать целиком). Полные тексты выполненных задач — в git-истории плана и не нужны для продолжения.
- Прогресс-ledger: `.superpowers/sdd/progress.md` — секция «Deep-Review Batch 2» ВНИЗУ файла (батч 1 выше — не перезаписывать, только дописывать вниз). Читать секцию батча 2 полностью: там DEVIATION/ACTION/CANDIDATE/MINOR-записи, обязательные к учёту при финальном ревью.
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
- [x] Task 8: пустой bbox → null (T-55) — `889293e` (санкционированное расширение скоупа: 4 require_relative в legacy-шапках)
- [x] Task 9: скриншот-метаданные (T-28) — `aa9aa39`
- [x] Task 10: server.rb батч устойчивости ×5 (T-13) — `34bd3db`, `390ba6d`, `c29c590`, `85688af`, `43e2d88`
- [x] Task 11: compat-msg, OBJ-ключ, Logger-guard, export-warning — `ac01d80`, `74c5955`, `d4cb531`, `bca648f`
- [x] Task 12: make_unique перед мутацией (T-16) — `ef85f89` (ревью без единой находки)
- [x] Task 13: валидация + min-dims + case-insensitive поиск (T-17, MR-2, T-18) — `16fed5e` (вкл. ACTION: комментарий LOOKUP_MAX_DEPTH)
- [x] Task 14: Ruby gap-тесты + rotated-board (T-23, MR-3) — `aee1edb`, `07f6526`, `ecd3e01`, `2194e7e`, `5e545f4` (5-й = санкционированные контроллером CANDIDATE-пины из ревью Task 8; багов gap-тестами не найдено; C-14 дискриминативность доказана)

**Remaining (порядок строгий):**
- [ ] Task 15: докстринг-оверхол 22 тулов + prompts.py (T-05) — СЛЕДУЮЩАЯ; гейт Python 176 passed
- [ ] Task 16: зачистка доков/gitignore/entry-points/release.md (T-25, T-29) — 2 коммита; именно здесь `rm diff.patch docs/session-transfer-*.md`
- [ ] Task 17: финальная верификация, счётчики, smoke-синк — 1 коммит

## SESSION CONTEXT

**Git:** ветка `fix/deep-review-p2`, HEAD `30a6d30` (trim-коммит поверх `5e545f4`). Tracked-дерево чистое. История батча 2: `5cd4b2d` (дизайн) → `e9fd870` (план) → дизайн-ревью до `1bd6d3c` → задачи 1–8 → `d14246a` (trim 1–8) → задачи 9–14 → `30a6d30` (trim 9–14).

**Верифицированные счётчики на `5e545f4`:** Python `uv run pytest tests/ -q` → **171 passed**; Ruby `ruby test/run_all.rb` → **415 runs / 1109 assertions / 0 failures / 0 errors**.

**Оставшиеся счётчики-гейты:** Task 15 → Python 176 (171 + 5 новых в test_tool_descriptions.py). Task 16 → 176 (не меняется; после правки pyproject.toml может понадобиться `uv pip install -e .`). Task 17 → фиксация ФАКТИЧЕСКИХ чисел в CLAUDE.md:84-85 (сейчас там устаревшие 354/939 и 136; ожидаемо станет 415/1109 и 176 — Ruby-тестов задачи 15–17 не добавляют). Ориентиры плана мягкие («~413 runs» писалось до санкционированного 5-го коммита Task 14) — авторитетен фактический прогон; при 0 failures расхождение фиксировать в ledger, не «чинить».

**Механика исполнения (как это работало):**
- `/claude-mesh:do-plan` без аргумента: порог 250k из config, `dispatch_model=fable` → КАЖДЫЙ Agent-диспатч с `model: "fable"`; полный ригор ревью, токены не экономить. Новая сессия сама запишет свой per-session config при запуске do-plan.
- Скрипты скилла: `task-brief PLAN N` и `review-package BASE HEAD` из `$(find ~/.claude/plugins -path '*superpowers*/skills/subagent-driven-development/scripts' -type d | head -1)` (в кеше две версии 6.1.0/6.1.1 — find даёт 6.1.0, работает). Брифы/отчёты: `.superpowers/sdd/task-N-brief.md` / `task-N-report.md` (имплементер пишет отчёт в файл, возвращает <15 строк). BASE фиксировать ДО диспатча имплементера (не HEAD~1 — задачи бывают многокоммитные).
- Ревьюер получает: бриф + отчёт + diff-файл + вербатим-констрейнты из Global Constraints плана; Minor-находки НЕ чинятся в задаче — копятся в ledger для финального whole-branch ревью (конвенция сессии, прецеденты батчей 1–2).
- Сабагенты РЕГУЛЯРНО уходят в idle, не прислав отчёт (в этой сессии — 5 из 6 ревьюеров): SendMessage тому же агенту с просьбой передать готовый отчёт, НЕ спавнить дубликат.
- Слоты `.superpowers/sdd/task-N-*.md` переиспользуются между батчами (untracked scratch) — перезапись старых отчётов нормальна, durable-запись несёт ledger.

**⚠ Паттерн «benign RED-описки брифов» (прецеденты: Tasks 5/6/7 — mcp 1.27 `extra="ignore"`; Task 10 — flood-тест NameError'ится на константе первой строкой, поведенческий RED добывается частичным стейджингом GREEN; Task 11 — негативный пин проходит pre-fix по построению + minitest assert_includes/assert_match = 2 assertions каждый):** тальи брифов бывают арифметически недостижимы на их же коде. Протокол: имплементер документирует расхождение per-test и продолжает ТОЛЬКО если все содержательные причины совпали и тесты транскрибированы вербатим; ревьюер адъюдицирует независимо; в ledger — DEVIATION (plan-side). СТРУКТУРНО иной RED (load-ошибки, неожиданный красный существующий тест) = реальный СТОП → BLOCKED.

**Неявные знания для Task 15 (важно):**
- Аннотация `-> list:` у get_viewport_screenshot уже стоит (Task 9); докстринг тула уже переписан Task 9 — Task 15 добавляет только Field(description) его параметрам + фразу P-14 про retry/flicker. НЕ трогать аннотацию: `-> list[Image | str]` РОНЯЕТ регистрацию на mcp 1.27 (проверено пробой).
- Step 0 (P-12): grep маинтейнерских заметок прогнать СВЕЖИМ перед правкой — номера строк из плана уплыли после Task 13.
- M-11: в новых текстах докстрингов/description НЕ должно быть подстрок «Ruby tool name» и «pydantic» (любой регистр) — их ищет leak-тест.
- `tests/test_prompts.py` пинит подстроку `bbox_mm` — правки prompts.py её сохраняют; пины упали → обновить осознанно в том же коммите. Wire-пины (test_tool_wrapper_calls_ruby_correctly) обязаны пройти БЕЗ правок.
- Русские комментарии, транскрибированные вербатим в tools.py/tests (Task 9), — известный Minor в ledger; языковая унификация = решение финального ревью/владельца, Task 15 её не делает.

**Неявные знания для Task 16:**
- C-12: в README:137-138 фантомные строки ТОЛЬКО удалить — корректные строки про smoke_check/smoke_multi_client УЖЕ стоят выше (README:135-136), вставка даст дубликат.
- `rm diff.patch docs/session-transfer-*.md` — только здесь (untracked, в git не были). `.gemini/` — только строка в .gitignore.
- Два коммита строго по плану: docs-коммит и build-коммит (entry-points + app.py комментарий).
- Номера строк в тексте задачи датируются 2026-06-12 — искать по содержимому.

**Неявные знания для Task 17:**
- smoke_check.py шаг 16: два assert'а пагинационного конверта (total/truncated) после строки `ids = [...]`; шаг 17 отдельного ассерта не требует.
- В CLAUDE.md:84-85 записать фактические числа прогонов; сверка ветки — greps из Step 3 плана.

**Критические инварианты (нарушение = стоп):** `A.subtract(B) == B − A` — НИКОГДА не «чинить»; literal source-guard тесты (`test_operation_names.rb`, `test_transform_absolute.rb`, `test_joints_frame_compensation.rb`) — никаких форматтеров, пины обновлять только осознанно; версии не бампать (все четыре точки 0.2.0); wire-протокол/handshake не трогать; мм на границе MCP; каждый Ruby-тест зелёный standalone И через run_all; коммиты английские conventional без AI-атрибуции.

**Untracked-мусор:** НЕ трогать `.venv.broken-task8/` (владелец удалит после рестарта живого MCP-сервера), `.gemini/`, `.superpowers/`, `docs/superpowers/plans/*prompt*.md` (включая этот файл — untracked-архив владельца). `diff.patch` и `docs/session-transfer-*.md` удаляются ТОЛЬКО в Task 16.

**После плана (вне 17 задач):** финальное whole-branch mesh-ревью (`/claude-mesh:mesh-review default`, дифф двух батчей от master) → `git rm -r docs/superpowers/ && git commit` (снимет только tracked) → ОДИН PR `fix/deep-review-p2` → master с обоими батчами. В PR напомнить владельцу 5 автономных решений батча 1: (1) пред-фикс хрупкого теста `165f214`; (2) commit message «3.10-3.13»; (3) 136 passed вместо «ровно 135»; (4) deepseek/v4-pro принят REAL вопреки guard-эвристике; (5) спорный source-guard `5de1987` по таймауту (откат = `git revert 5de1987`). Плюс девиации батча 2 из ledger: главные — Task 8 scope extension (4 строки require_relative, откат = убрать их из `889293e`); Task 14 санкционированный 5-й коммит `5e545f4` (CANDIDATE-пины; Task 10 comment-4a CANDIDATE осознанно НЕ включён — остался финальному ревью); plan-side RED-описки Tasks 10/11; P-17 rework не отражён в message `c29c590` (самопротиворечие брифа; amend по желанию владельца). Все MINOR-находки ledger триажирует финальное ревью. Ручные шаги владельца: live-smoke 25 шагов на SketchUp 2026 + пункт C-10 (boolean над копией шаренной группы), рестарт MCP-сервера → `rm -rf .venv.broken-task8/`, bump MIN-floor'ов при релизе.

## PLAN QUALITY WARNING

The plan was written for a large task and may contain errors, oversights, or assumptions that don't match the codebase (серия benign RED-описок — Tasks 5/6/7/10/11 — и один реальный standalone-пробел Task 8 уже найдены и обработаны; см. SESSION CONTEXT и ledger).

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
