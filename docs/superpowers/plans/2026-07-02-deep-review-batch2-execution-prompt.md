## TASK

Execute the implementation plan for **Deep-Review Batch 2** (P1-остатки + P2 + UX-квиквины deep-research-аудита sketchup-mcp2).

Use `/superpowers:subagent-driven-development` skill for execution. (В этом проекте обычная обёртка — `/claude-mesh:do-plan`, она сама поднимает subagent-driven-development и паузу по порогу контекста; допустимы оба входа.)

## DOCUMENTS

- Design: `docs/superpowers/specs/2026-07-02-deep-review-batch2-design.md`
- Plan: `docs/superpowers/plans/2026-07-02-deep-review-batch2.md` (17 задач, 5 волн, ~3.7 тыс. строк)

Read both documents first. Прогресс-ledger батча 1 — `.superpowers/sdd/progress.md`: НЕ перезаписывать, батч 2 ДОПИСЫВАЕТСЯ вниз новой секцией.

## IMPORTANT: DO NOT START WORK YET

After reading the documents:
1. Confirm you have loaded all context
2. Summarize your understanding briefly
3. **WAIT for user instruction before taking any action**

Do NOT begin implementation until the user explicitly tells you to start.

## SESSION CONTEXT

**Ветка и git-состояние:**
- Рабочая ветка `fix/deep-review-p2`, отрезана от `fix/deep-review-p1` (HEAD батча 1 = `5de1987`). На ней уже 2 коммита: `5cd4b2d` (дизайн) + `e9fd870` (план).
- Finishing-церемония батча 1 ОТМЕНЕНА: в конце батча 2 — ОДИН PR `fix/deep-review-p2` → master, включающий оба батча. Перед PR: `git rm -r docs/superpowers/ && git commit` (конвенция).
- Стартовые базлайны: Ruby `ruby test/run_all.rb` → **354 runs / 939 assertions / 0 failures**; Python `uv run pytest tests/ -q` → **136 passed**. Целевые ориентиры плана: ~411 runs / 172 passed — СТАТИЧЕСКИЕ прогнозы; авторитетны фактические прогоны (при 0 failures расхождение — не ошибка, фиксировать факт в ledger).

**Untracked-мусор — правила:**
- НЕ трогать: `.venv.broken-task8/` (владелец удалит после рестарта живого MCP-сервера), `.gemini/`, `.superpowers/`, `docs/superpowers/plans/*prompt*.md`.
- `diff.patch` и `docs/session-transfer-*.md` удаляются ТОЛЬКО в Task 16 (T-25, санкционировано дизайном) — не раньше.

**Ключевые решения дизайна (одобрены пользователем, не пересматривать):**
- T-16 — ЧИНИТЬ через make_unique, а не документировать («4 стула краснеют разом»).
- MR-1 — сознательный пересмотр намеренного решения батча 1 (partial-EOF не ретраился): безопасность retry теперь целиком на whitelist `_RETRY_SAFE_TOOLS`; старый комментарий-обоснование в connection.py заменяется.
- T-50 — дефолт `[100,100,100]`, параметр НЕ обязателен. T-29 — entry-points группу удалить. T-20 считается закрытым (CI-пин rubyzip есть, Gemfile НЕ заводить).
- Вне скоупа: T-47, остальной P3, миграция mcp v2. Отвергнутые подходы: два последовательных спринта и «план с отсечением хвоста» — выбран один плоский план.

**Неявные знания из планирования (в план встроены, но легко пропустить):**
- Task 10.1: hello-ответ клиента с framing-ошибкой НАМЕРЕННО дропается (skip по `close_after_response` в process_frame_queue) — тест ждёт ровно 1 фрейм; parse-вариант ждёт 2 фрейма и требует `stub_write_pending(times: 2)`.
- Task 10.7c: три СУЩЕСТВУЮЩИХ теста задают `pending_write_deadline_at` через `Time.now` — их обязательно перевести на монотонные секунды, иначе красные.
- Task 12: мутирующих call-sites `entity_collection` ЧЕТЫРЕ — включая `operations.rb::run_edge_op` (в тикете отчёта назван только materials+joints; четвёртый найден при чтении кода).
- Task 13/MR-2: статический floor 1 мм НЕ ловит high-segment сферы — формула полярной хорды `2·r·sin²(π/segments)` с порогом 0.03 мм обязательна (кейс d=10 мм, segments=96).
- Task 6: pydantic-форма опционального name — `Optional[Annotated[str, Field(min_length=1)]]` (констрейнт на внутреннем типе, не на Optional).
- Task 9: аннотация возврата скриншота `-> list[Image | str]`; если FastMCP 1.27 споткнётся на регистрации — fallback `-> list:`, выбор зафиксировать в commit message.
- `tests/test_prompts.py` пинит только подстроку `bbox_mm` — правки prompts.py в Tasks 5/15 её сохраняют.
- Wire-pin таблица `test_tool_wrapper_calls_ruby_correctly` правится ТОЛЬКО в Task 7 (5 строк list/find получают пагинационные дефолты); остальные задачи обязаны оставить её зелёной без правок.
- Номера строк в тикетах отчёта датируются 2026-06-12 и уплыли — искать по содержимому (план даёт точные якоря).

**Критические инварианты (Global Constraints плана — нарушение = стоп):**
- `A.subtract(B) == B − A` — НИКОГДА не «чинить»; literal source-guard тесты (`test_operation_names.rb`, `test_transform_absolute.rb`, `test_joints_frame_compensation.rb`) — никаких форматтеров, пины обновлять только осознанно отдельным решением.
- Версии не бампать (все четыре точки = 0.2.0), wire-протокол/handshake не трогать, mm на границе MCP.
- Каждый Ruby-тест зелёный standalone И через `run_all.rb`; коммиты английские conventional без AI-атрибуции.

**Паттерн окружения:** сабагенты (исполнители задач, ревьюеры) иногда уходят в idle, НЕ прислав отчёт — это норма; слать SendMessage тому же агенту («пришли результат / доделай в foreground»), не спавнить дубликат.

**После плана (фазы вне 17 задач):** финальное whole-branch mesh-ревью (`/claude-mesh:mesh-review default`, образец батча 1) → `git rm -r docs/superpowers/` → единый PR. В описании PR напомнить владельцу 5 автономных решений батча 1: (1) пред-фикс хрупкого теста `165f214`; (2) commit message «3.10-3.13»; (3) 136 passed вместо «ровно 135»; (4) deepseek/v4-pro принят REAL вопреки guard-эвристике; (5) спорный source-guard `5de1987` по таймауту (откат = `git revert 5de1987`). Ручные шаги владельца: live-smoke 25 шагов на SketchUp 2026 (шаг 22 — включить eval или github-сборка), рестарт MCP-сервера → `rm -rf .venv.broken-task8/`, bump MIN-floor'ов при релизе (durable-запись в `docs/release.md`).

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

Особо: если RED-прогноз задачи не совпал с фактическим провалом (другая ошибка, другой счётчик) — это сигнал расхождения плана с кодом, а не повод подогнать тест; если Task 14 (gap-filling тесты) обнаружит реальный баг — СТОП и в ledger, не чинить молча.
