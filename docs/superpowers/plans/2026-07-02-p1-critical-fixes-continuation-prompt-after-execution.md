## TASK

Continue **P1 Critical Fixes (deep-research review, батч 1)** — ВСЕ 10 задач плана ВЫПОЛНЕНЫ (каждая прошла spec+quality ревью). Остались финальные фазы `superpowers:subagent-driven-development`:

1. Финальное whole-branch ревью всей ветки.
2. Триаж/фикс подтверждённых находок (ОДИН fix-сабагент на весь список + re-review).
3. `superpowers:finishing-a-development-branch`.

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start the final review or any subagents
- Make any code changes
- Run any commands (except reading documents)
- Assume what to work on next

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS

- Design: **отсутствует** (дизайн-фазы не было; первоисточник аудита живёт на другой ветке — не искать).
- Plan (ОБРЕЗАН после выполнения): `docs/superpowers/plans/2026-07-02-p1-critical-fixes.md` — тела задач заменены на «✅ Done — commit …»; живы Global Constraints, карта задач и хвост «После плана». Полные тела задач — в git-истории файла (до коммита `6275466`).
- **Progress ledger (читать ОБЯЗАТЕЛЬНО):** `.superpowers/sdd/progress.md` — по-задачная история: коммиты, отклонения, env-инцидент и ВСЕ Minor-находки пер-задачных ревью для триажа финальным ревью.
- Review log плана (справочно): `docs/superpowers/specs/2026-07-02-p1-critical-fixes-review-iter-1.md`.
- Брифы/отчёты/дифф-пакеты задач (справочно): `.superpowers/sdd/task-*-{brief,report}.md`, `.superpowers/sdd/review-*.diff`.
- ⚠ Прежние continuation/execution-промпты в этой папке — УСТАРЕЛИ; данный файл их заменяет.

## PROGRESS

**Completed (все, с ревью):**
- [x] Task 1: cap `mcp[cli]>=1.27,<2` + git rm requirements.txt (`d708aa4`)
- [x] Task 2: CI Ruby+Python 3.10–3.13 + бейдж (`165f214` пред-фикс хрупкого теста + `f6a9789`)
- [x] Task 3: eval_ruby → `-32603` с диагностикой, +5 тестов (`d6fcf95`)
- [x] Task 4: пины реверса `Group#subtract`, флипы 3/3 (`4eaaf29`)
- [x] Task 5: manifold-сферы + `segments>=3` (`0595125`)
- [x] Task 6: absolute `position` (bbox-min, применяется ПОСЛЕДНЕЙ), feat! (`6b7d133`)
- [x] Task 7: joints через world-frame prototype с компенсацией `board.transformation.inverse` (`942a16c`)
- [x] Task 8: connection.py — вся мутация сокета под `conn._lock`; итог 136 passed (`fa25069`)
- [x] Task 9: smoke 22→25 шагов (`3e9409e`)
- [x] Task 10: свежие прогоны + счётчики доков (`d73b7e5`)
- [x] План обрезан (`6275466`)

**Remaining (в сессии):**
- [ ] Финальное whole-branch ревью: пакет `scripts/review-package $(git merge-base master HEAD) HEAD` (скрипт — в skill-папке superpowers/subagent-driven-development), шаблон `superpowers:requesting-code-review` → code-reviewer.md, самая способная модель; на вход ревьюеру — дифф-пакет файлом + Global Constraints из плана + список Minor-находок из ledger для триажа. НЕ давать ревьюеру пред-суждений.
- [ ] Если находки: ОДИН fix-сабагент на весь список (не по-находочный) + re-review.
- [ ] `superpowers:finishing-a-development-branch`; перед PR обязательно `git rm -r docs/superpowers/ && git commit` (конвенция проекта).

**Remaining (вне сессии, владелец):** live-smoke 25 шагов на SketchUp 2026 (пересобрать .rbz; для шага 22 включить eval или github-сборку); рестарт живого MCP-сервера → `rm -rf .venv.broken-task8/`; при релизе — ОБЯЗАТЕЛЬНЫЙ bump MIN-floor'ов совместимости (семантика position изменилась).

## SESSION CONTEXT

- Ветка `fix/deep-review-p1`, HEAD = `6275466`, 15 коммитов над master, дерево чистое (кроме заведомо untracked мусора: `.gemini/`, `diff.patch`, `docs/session-transfer-*`, лишние `docs/superpowers/*prompt*.md`, `.superpowers/`, `.venv.broken-task8/` — НЕ трогать, НЕ чистить).
- Свежие прогоны (Task 10, независимо перемерено ревьюером): Ruby **353 runs / 934 assertions / 0 failures**; Python **136 passed**; матрица 3.10–3.13 локально зелёная (Task 2).
- Исполнение шло по `superpowers:subagent-driven-development` под `/claude-mesh:do-plan` (STOP-порог 250k сработал после Task 10). Dispatch-модель сабагентов: `fable` (config claude-mesh).
- **Автономные решения контроллера (пользователь видел чекпойнт-отчёт, но явно НЕ подтверждал — при финальном отчёте напомнить):**
  1. Task 2: floor-проверка 3.10 упала на PRE-EXISTING хрупком тесте `test_send_command_lock_serializes_concurrent` (одиночный `sleep(0)`; `asyncio.wait_for` порождает child-task на CPython ≤3.11 — gh-96764; падал на 3.10 И 3.11). Развилка плана «поднять floor или чинить» коллапсировала (floor-raise запрещён Global Constraints) → тест починен отдельным коммитом `165f214` (bounded poll, ассерты не ослаблены). Откатывается одним revert.
  2. Task 2: commit message «Python 3.10-3.13 matrix» — исправление устаревшей строки плана (матрица с 3.10 = решение ревью MAJOR-1).
  3. Task 8: итог **136 passed**, а не «ровно 135» — Step 3e плана велел добавить недостающий тест `send_command → ConnectionError`; добавлен.
- Env-инцидент Task 8: у пользователя запущен живой MCP-сервер (`python -m sketchup_mcp`, PID 1075476), державший старый `.venv`; остаток переименован в `.venv.broken-task8/`, новый `.venv` пересобран из lock, зелёный. Каталог удалять ТОЛЬКО после рестарта сервера пользователем.
- Minor-находки для триажа финальным ревью — построчно в ledger; среди них два «MUST land» из Task 8: стейл-докстринги `app.py:30` (lifespan: «faults from get_connection()») и `connection.py:6` (module docstring не упоминает ensure_connected/aclose) — они НЕ попали в Task 10 (там только счётчики) и всё ещё висят.
- Паттерн сабагентов в этой конфигурации: имплементеры иногда делегируют прогоны тестов фоновым агентам и возвращаются «ждать» — результаты до них НЕ доходят. При таком возврате: SendMessage тому же agentId с указанием доделать самому в foreground (двух таких случаев хватило: Task 2, Task 10).
- Критические инварианты неизменны: `A.subtract(B) == B − A` — НИКОГДА не «чинить» под доки; версии/wire-протокол/handshake не трогать; mm на границе MCP, дюймы внутри; Ruby-тесты standalone + run_all (guarded-стабы, Method-restore).

## PLAN QUALITY WARNING

Пер-задачные ревью прошли, но финальное whole-branch ревью ещё НЕ выполнялось — межзадачные взаимодействия могли остаться незамеченными. Если находка финального ревью конфликтует с текстом плана — это решение пользователя: предъявить находку и текст плана, спросить, что главнее. НЕ отклонять находку из-за «так велел план» и НЕ фиксить вопреки плану без вопроса.

## INSTRUCTIONS

1. Read the documents listed above (plan и ledger — первыми)
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with anything
5. Ask: "What would you like me to work on?"
