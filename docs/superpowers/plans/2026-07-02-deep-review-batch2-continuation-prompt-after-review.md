## TASK

Continue executing the implementation plan for **Deep-Review Batch 2** (P1-остатки + P2 + UX-квиквины deep-research-аудита sketchup-mcp2).

Фаза дизайн-ревью ЗАВЕРШЕНА (mesh-design-review, итерация 1). Следующая фаза — ИСПОЛНЕНИЕ плана: `/claude-mesh:do-plan` (обёртка над superpowers:subagent-driven-development с паузой по порогу контекста).

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

- Design: `docs/superpowers/specs/2026-07-02-deep-review-batch2-design.md` (обновлён ревью: T-17 «зеркальность по границам», MR-2 per-type пороги, §5 untracked-судьба)
- Plan: `docs/superpowers/plans/2026-07-02-deep-review-batch2.md` (17 задач, 5 волн, ~3.9 тыс. строк — обновлён по 48 карточкам ревью)
- Лог ревью (контекст решений): `docs/superpowers/specs/2026-07-02-deep-review-batch2-review-iter-1.md`
- Прогресс-ledger: `.superpowers/sdd/progress.md` — батч 1 завершён; батч 2 ДОПИСЫВАЕТСЯ вниз новой секцией, НЕ перезаписывать.

Read design + plan fully (план читать кусками ~1200 строк). Iter-файл — по необходимости.

## PROGRESS

**Completed (фаза ревью, кода проекта не касалась):**
- [x] Дизайн-ревью итерация 1: 6 ревьюеров (builtin claude, codex gpt-5.5, qwen, deepseek, glm частично, minimax частично; kimi — 3 обрыва стрима, без результата), 48 карточек, 35 авто-фиксов + 7 авто-после-анализа + 1 пользовательское решение + 9 отклонено. Коммиты: `7dd2539` (авто-фиксы), `66ac538` (решения + лог), `8ca5137` (фиксап гейта Task 8), `1bd6d3c` (дельта парсера в лог).

**Remaining (все 17 задач плана):**
- [ ] Tasks 1–4 (волна 1: Python-ядро), 5–9 (волна 2: сигнатуры), 10–13 (волна 3: Ruby-надёжность), 14–15 (волна 4: тесты/контракт), 16–17 (волна 5: финиш). Порядок строгий; задачи 7/8/13 (handlers/model.rb) — последовательно.

## SESSION CONTEXT

**Git-состояние:** ветка `fix/deep-review-p2` (от fix/deep-review-p1, HEAD батча 1 = 5de1987), HEAD сейчас `1bd6d3c`. История: 5cd4b2d (дизайн) → e9fd870 (план) → 7dd2539 → 66ac538 → 8ca5137 → 1bd6d3c.

**Базлайны на старте:** Ruby `ruby test/run_all.rb` → 354 runs / 939 assertions / 0; Python `uv run pytest tests/ -q` → 136 passed. План теперь ТРЕБУЕТ перепрогнать оба на старте исполнения и зафиксировать фактические числа в ledger.

**Обновлённые счётчики-гейты Python по задачам (после ревью):** Task 1 → 147, T2 → 150, T3 → 151, T4 → 154, T5 → 160, T6 → 164, T7 → 167, T8 → 167 (не задет), T9 → 168, T12 → 168 (не задет), T13 → 171, T15 → 176. Финальные ориентиры Task 17: Python 176 passed, Ruby ~413 runs (354 + ~59) — ориентиры мягкие, авторитетен фактический прогон (при 0 failures расхождение — не ошибка, фиксировать в ledger).

**Ключевые пост-ревью изменения плана (уже вписаны — не удивляться):**
- MR-2 пороги per-type (выбор пользователя): box ≥ 0.1 мм (шпон легитимен), sphere/cylinder/cone ≥ 1.0 мм; `validate_min_dimensions!(dims_mm, type)`; polar-chord порог 0.04 мм; Python `Field(ge=0.1)` — абсолютный floor, per-type — Ruby-инстанция.
- `EntityId = Annotated[int, Field(strict=True)] | Annotated[str, Field(min_length=1)]` — strict закрывает bool-дыру (True→id «1»); проба подтвердила anyOf-схему на mcp 1.27.
- Скриншот: аннотация СРАЗУ `-> list:` — `-> list[Image | str]` ПАДАЕТ на регистрации mcp 1.27 (верифицировано пробой); голый str конвертируется в TextContent автоматически.
- Task 10 Step 6 (T-13.3): существующий `test_pending_write_overflow_closes_client` под новой семантикой СТАНЕТ КРАСНЫМ — план предписывает переработку (малый head-append перед `near`); это НЕ неожиданность, не откатывать фикс.
- Pydantic-коэрция типов ПРИНЯТА намеренно (Python — ранний фильтр для LLM, Ruby — строгая инстанция); «зеркальность» — по границам значений.
- `layer` включён в concise-набор пагинации; Ruby-граница limit ≤ 500 (`optional_int_range`); pre-handshake свип пропускает `close_after_response`; backpressure-guard внутри read-цикла.
- Save-Method паттерн обязателен при стабах модульных `def self.`-методов (они singleton! remove_method без сохранения удаляет реальный метод под run_all) — план это прописывает в Tasks 11/13, Global Constraints.
- Граница T-16 (C-10): subtract-пути make_unique НЕ требуют (subtract потребляет вход, создаёт новую группу) — подтверждается только live-smoke владельца (пункт добавлен в «После плана»).

**Неявные знания планирования (актуальны):**
- Task 10.1: hello-ответ клиента с framing-ошибкой НАМЕРЕННО дропается (skip по close_after_response) — тест ждёт ровно 1 фрейм; parse-вариант ждёт 2 фрейма и `stub_write_pending(times: 2)`.
- Task 10 Step 7c: ТРИ существующих теста задают `pending_write_deadline_at` через `Time.now` — перевести на монотонные секунды, иначе красные.
- Task 12: мутирующих call-sites `entity_collection` ЧЕТЫРЕ (включая `operations.rb::run_edge_op`); строка `cur_edges` — в другом методе (`find_current_edge_spec`), её не трогать.
- Task 6: pydantic-форма опционального name — `Optional[Annotated[str, Field(min_length=1)]]`.
- `tests/test_prompts.py` пинит подстроку `bbox_mm` — правки prompts.py в Tasks 5/15 её сохраняют.
- Wire-pin таблица `test_tool_wrapper_calls_ruby_correctly` правится ТОЛЬКО в Task 7 (5 строк получают пагинационные дефолты; expected теперь включает `"limit": 50, "offset": 0, "response_format": "detailed"`).
- Номера строк в тикетах отчёта датируются 2026-06-12 и уплыли — искать по содержимому (план даёт якоря).

**Критические инварианты (нарушение = стоп):**
- `A.subtract(B) == B − A` — НИКОГДА не «чинить»; literal source-guard тесты (`test_operation_names.rb`, `test_transform_absolute.rb`, `test_joints_frame_compensation.rb`) — никаких форматтеров; пины обновлять только осознанно отдельным решением.
- Версии не бампать (все четыре точки = 0.2.0), wire-протокол/handshake не трогать, мм на границе MCP.
- Каждый Ruby-тест зелёный standalone И через `run_all.rb`; глобальные стабы — guarded ИЛИ аддитивный реопен (эталон test_collect_components.rb); коммиты английские conventional без AI-атрибуции.

**Untracked-мусор — правила:** НЕ трогать `.venv.broken-task8/` (владелец удалит после рестарта живого MCP-сервера), `.gemini/`, `.superpowers/`, `docs/superpowers/plans/*prompt*.md`. `diff.patch` и `docs/session-transfer-*.md` удаляются ТОЛЬКО в Task 16.

**Паттерн окружения:** сабагенты (исполнители, ревьюеры) иногда уходят в idle, НЕ прислав отчёт — норма; слать SendMessage тому же агенту («пришли результат / доделай в foreground»), НЕ спавнить дубликат. При лимите модели — дождаться сброса и продолжить тем же агентом.

**После плана (фазы вне 17 задач):** финальное whole-branch mesh-ревью (`/claude-mesh:mesh-review default`) → `git rm -r docs/superpowers/ && git commit` (снимет только tracked; untracked prompt-файлы остаются владельцу — осознанно) → ОДИН PR `fix/deep-review-p2` → master с обоими батчами. В PR напомнить владельцу 5 автономных решений батча 1: (1) пред-фикс хрупкого теста `165f214`; (2) commit message «3.10-3.13»; (3) 136 passed вместо «ровно 135»; (4) deepseek/v4-pro принят REAL вопреки guard-эвристике; (5) спорный source-guard `5de1987` по таймауту (откат = `git revert 5de1987`). Ручные шаги владельца: live-smoke 25 шагов на SketchUp 2026 (шаг 22 — включить eval или github-сборка) + новый пункт C-10 (boolean над копией шаренной группы), рестарт MCP-сервера → `rm -rf .venv.broken-task8/`, bump MIN-floor'ов при релизе (в docs/release.md, блок дополняется в Task 16).

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

Особо: если RED-прогноз задачи не совпал с фактическим провалом (другая ошибка, другой счётчик) — это сигнал расхождения плана с кодом, а не повод подогнать тест. Если Task 14 (gap-filling тесты) обнаружит реальный баг — СТОП и в ledger, не чинить молча. Единственный ОЖИДАЕМЫЙ красный существующий тест — overflow-тест в Task 10 Step 6 (план предписывает его переработку).

## INSTRUCTIONS

1. Read the documents listed above
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any implementation
5. Ask: "What would you like me to work on?"
