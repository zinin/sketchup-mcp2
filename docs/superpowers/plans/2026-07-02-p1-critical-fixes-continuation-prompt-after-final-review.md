## TASK

Continue **P1 Critical Fixes (deep-research review, батч 1)** — ВСЁ ВЫПОЛНЕНО, включая финальное whole-branch ревью и фиксы его находок. Осталась ЕДИНСТВЕННАЯ фаза:

1. `superpowers:finishing-a-development-branch` (в предыдущей сессии не было доступа к `gh` — потому перенос сюда).

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start the finishing flow, create PRs, merge or delete anything
- Make any code changes
- Run any commands (except reading documents)
- Assume what to work on next

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS

- Design: **отсутствует** (дизайн-фазы не было; первоисточник аудита — на другой ветке, не искать).
- Plan (обрезан): `docs/superpowers/plans/2026-07-02-p1-critical-fixes.md` — все 10 задач «✅ Done»; живы Global Constraints и хвост «После плана».
- **Progress ledger (читать ОБЯЗАТЕЛЬНО):** `.superpowers/sdd/progress.md` — вся история по задачам + итоги финального ревью (низ файла).
- Review logs (справочно): `docs/superpowers/specs/2026-07-02-p1-critical-fixes-review-iter-1.md` (ревью ПЛАНА; финальное ревью КОДА логов в specs не имеет — итоги в ledger и здесь).
- ⚠ Прежние continuation/execution-промпты в этой папке — УСТАРЕЛИ; данный файл их заменяет. Промпт-файлы НЕ коммитить.

## PROGRESS

**Completed (всё):**
- [x] Задачи 1–10 плана — каждая с per-task ревью (коммиты `d708aa4`..`d73b7e5`, план обрезан `6275466`).
- [x] Финальное whole-branch ревью: `/claude-mesh:mesh-review default`, 7 ревьюеров (builtin rev-claude с полным брифом и триажем ledger-миноров + codex + zai/glm + alibaba/qwen + deepseek/v4-pro + ollama/kimi + ollama/minimax). Вердикт: **0 Critical / 0 Important, merge-ready** у всех.
- [x] Фиксы находок: AUTO ×11 → `9643539`; спорное ×1 (source-guard `carve_board2_slots`) → `5de1987`; DISMISSED ×25.
- [x] Прогоны после фиксов: Ruby **354 runs / 939 assertions / 0 failures** (новый guard-файл standalone 6/29/0), Python **136 passed**. Счётчики в CLAUDE.md обновлены.

**Remaining (в этой сессии):**
- [ ] `superpowers:finishing-a-development-branch`: выбор merge/PR/cleanup. **Перед PR ОБЯЗАТЕЛЬНО**: `git rm -r docs/superpowers/ && git commit` — конвенция проекта (ветка трекает там 3 файла: план + 2 review-спеки; в PR-дифф они попасть не должны, останутся в истории ветки).

**Remaining (вне сессии, владелец):**
- live-smoke 25 шагов на SketchUp 2026 (пересобрать `.rbz`; для шага 22 включить eval в Settings или собрать `--variant=github`);
- рестарт живого MCP-сервера → затем `rm -rf .venv.broken-task8/`;
- при следующем релизе — ОБЯЗАТЕЛЬНЫЙ bump MIN-floor'ов совместимости (теперь durable-записан в `docs/release.md`, блок «Pending contract break»).

## SESSION CONTEXT

- Ветка `fix/deep-review-p1`, HEAD = `5de1987`, 17 коммитов над master, tracked-дерево чистое. Untracked-мусор (`.gemini/`, `.superpowers/`, `.venv.broken-task8/`, `diff.patch`, `docs/session-transfer-*`, `docs/superpowers/*prompt*.md`) — НЕ трогать, НЕ чистить; `.venv.broken-task8/` удаляет владелец после рестарта MCP-сервера.
- Последние 2 коммита — ревью-фазы: `9643539` (11 авто-фиксов: стейл-докстринги app.py/connection.py; «cannot reconnect»→«cannot connect» + 2 тест-пина; poll-else `pytest.fail`; assert-msg в test_transform_absolute; smoke NB dovetail; CLAUDE.md rubyzip-уточнение + новый Non-Obvious Constraint про literal source-guards vs форматтеры; test.yml пин `rubyzip -v '~> 3'`; **docs/release.md «Pending contract break»** — durable-напоминание о bump MIN-floor'ов; README absolute-position) и `5de1987` (source-guard sibling-cutter паттерна `carve_board2_slots` + счётчики 354/939).
- **⚠ Автономные решения, НЕ подтверждённые пользователем — напомнить при финальном отчёте / создании PR:**
  1. Исполнение, Task 2: pre-existing хрупкий тест починен отдельным коммитом `165f214` (floor-raise запрещён Global Constraints).
  2. Исполнение, Task 2: commit message «3.10-3.13» вместо устаревшей строки плана.
  3. Исполнение, Task 8: 136 passed вместо «ровно 135» (добавлен недостающий send_command-тест по Step 3e).
  4. Ревью-фаза: deepseek/v4-pro помечен guard'ом BROKEN (num_turns=1) — ложное срабатывание (29 tool_use, 457 KB стрима, два result-события); принят как REAL.
  5. Ревью-фаза: спорный пункт (source-guard) применён по рекомендации контроллера после 60-с таймаута вопроса пользователю (прецедент CRIT-5 ревью плана); пересматривает решение MAJOR-2 «без нового покрытия — осознанно»; откат = `git revert 5de1987`.
- **Опровергнутые Important-находки внешних моделей — НЕ поднимать заново** (верифицировано по коду): kimi «add_parent_frame_prototype строит в active_entities — неверный фрейм для nested» (математика верна: definition хранит сырые числа, размещение задаёт явный `T_inst = T_board⁻¹`); qwen «re-raise NoMemoryError — мёртвый код» (арм нагрузочный: без него `rescue Exception` проглотил бы OOM); minimax «Interrupt глотается» (`Interrupt < SignalException`, ре-рейзится); kimi «smoke step 22 падает без eval» (`_maybe_skip_eval` даёт skip); qwen «aclose-тест тривиально истинен» (на до-T-08 коде финальный ассерт падает).
- **P2 бэклог-кандидаты из финального ревью** (упомянуть при планировании следующего батча): retry read-only tools при partial-EOF (`IncompleteReadError` с partial≠b"" сейчас намеренно не ретраится, connection.py:331); валидация минимальных dimensions (sub-tolerance радиус сферы может тихо дать дырявую сетку через last-resort rescue); rotated-board coverage для joints (юнит-фейк только translation; заявлены только translated).
- Паттерн окружения: сабагенты (ревьюеры, тест-раннеры) уходят в idle, НЕ прислав отчёт — это норма; слать SendMessage тому же агенту «пришли результат / доделай в foreground». Внешние ревью-врапперы оставляют артефакты в `~/.claude/plugins/data/claude-mesh-zinin/runs/<engine>/...` — правду о прогоне смотреть там.
- Критические инварианты неизменны: `A.subtract(B) == B − A` — НИКОГДА не «чинить»; версии/wire-протокол/handshake в ветке не трогать; mm на границе MCP, дюймы внутри; Ruby-тесты обязаны проходить standalone И через run_all.

## PLAN QUALITY WARNING

План исчерпан — осталась только финишная церемония по skill'у `superpowers:finishing-a-development-branch`. Если на финише всплывёт неожиданность (конфликт при `git rm -r docs/superpowers/`, расхождение с master, сюрпризы gh) — СТОП и вопрос пользователю, не импровизировать.

## INSTRUCTIONS

1. Read the documents listed above (ledger — первым)
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with anything
5. Ask: "What would you like me to work on?"
