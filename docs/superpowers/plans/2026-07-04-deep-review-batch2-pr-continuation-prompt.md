# Continuation prompt — Deep-Review Batch 2, финал: git rm docs/superpowers → единый PR (2026-07-04)

## TASK

Самый последний отрезок **Deep-Review Batch 2** (sketchup-mcp2): ВСЁ выполнено — 17/17 задач плана, live-DoD (smoke 25/25 + C-10, 2026-07-03), финальное whole-branch mesh-ревью с триажем и фиксами (2026-07-04). Осталось ровно два шага: **`git rm -r docs/superpowers/` + commit**, затем **единый PR `fix/deep-review-p2` → master** (оба батча). В ПРОШЛОЙ сессии не было доступа к `gh` — поэтому финиш перенесён сюда; в этой сессии `gh` должен работать (подтверждено владельцем). Перед PR проверить `gh auth status`.

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Run `git rm`, create the PR, push, or make any code changes
- Run any commands (except reading documents and cheap read-only git status/log)
- Assume what step to work on next

**The user will tell you exactly what to do.**

## DOCUMENTS

- Plan: `docs/superpowers/plans/2026-07-02-deep-review-batch2.md` — все 17 задач ✅; в хвосте «После плана» пункты 1 (mesh-ревью) и 3 (живой DoD) помечены Done; живым остался пункт 2 (git rm + PR) — это твоя фаза.
- Design: `docs/superpowers/specs/2026-07-02-deep-review-batch2-design.md`
- Прогресс-ledger: `.superpowers/sdd/progress.md` — читать ОБЕ секции ЦЕЛИКОМ: батч 1 (5 автономных решений для PR-описания) и батч 2 (все DEVIATION/девиации + в самом низу блок «Final whole-branch review (batch 2)» с полным итогом финального ревью — это первоисточник для PR-текста). НЕ перезаписывать, только дописывать вниз при необходимости.

## PROGRESS

**Всё выполнено, кроме двух финальных шагов:**
- [x] 17/17 задач плана (коммиты в плане и ledger)
- [x] Live-DoD 2026-07-03: smoke **25/25 PASSED** (0 skipped) + **C-10 PASSED** + T-55 живьём
- [x] Whole-branch mesh-ревью 2026-07-04 (`/claude-mesh:mesh-review default`, 7 ревьюеров: builtin rev-claude + codex + zai/glm + alibaba/qwen + deepseek/v4-pro + ollama/kimi + ollama/minimax): 0 подтверждённых Critical; **AUTO×20 → `16f3499`**; **disputed×3** — фикс композиции T-13.2×T-13.5 по выбору владельца → **`6e5f631`** (ClientState.queued_frames; sweep щадит клиентов с queued hello; behavioral-тест; закрыт ledger-кандидат Task 10 comment-4a), два минора rev-claude отклонены в **backlog P3** (transform empty-bounds position; num_tails/num_fingers cap); **DISMISSED×30** (в т.ч. опровергнуты: «Critical» minimax erase-before-commit — abort_operation откатывает; kimi CI actions:write — cache использует ACTIONS_RUNTIME_TOKEN; 8 из 9 kimi-Important — deliberate/documented/повторы refuted батча 1)
- [x] Попутно закрыты 6 ledger-Minor'ов (Tasks 1/4/9/11/16/17; в release.md EW-шаблонах меню обнаружен и учтён пункт «Restart Server»)
- [x] Счётчики CLAUDE.md актуальны: Ruby **423 runs / 1140 assertions / 0**, Python **177 passed** (оба прогона верифицированы независимым build-runner)
- [x] План: хвост «После плана» п.1 помечен Done (`e28653c`)

**Git:** ветка `fix/deep-review-p2`, HEAD `e28653c`, **63 коммита** master..HEAD (оба батча), tracked-дерево чистое.

**Remaining (порядок):**
- [ ] `git rm -r docs/superpowers/ && git commit` — снимает ТОЛЬКО tracked (план P1, 2 review-спеки, дизайн+план батча 2, merged/iter-файлы дизайн-ревью); untracked prompt-архив владельца (`docs/superpowers/plans/*prompt*.md`, включая этот файл) останется в дереве — норма, в PR не попадает. Коммит-месседж по конвенции проекта (английский, `docs:`/`chore:`).
- [ ] Push ветки + **один PR `fix/deep-review-p2` → master** через `gh` (сначала `gh auth status`). Убедиться, что в PR-диффе нет `docs/superpowers/`.

## SESSION CONTEXT

**PR-описание ОБЯЗАНО содержать (полный чек-лист):**
1. **5 автономных решений батча 1** (ledger, секция батча 1): пред-фикс хрупкого теста `165f214`; commit message «3.10-3.13»; 136 passed вместо «ровно 135»; deepseek/v4-pro принят REAL вопреки guard-эвристике; спорный source-guard `5de1987` применён по 60с-таймауту (откат = `git revert 5de1987`).
2. **Девиации батча 2** (ledger, секция батча 2): Task 8 санкционированное расширение скоупа (4 строки require_relative в legacy-шапках; откат = убрать их из `889293e`); Task 14 санкционированный 5-й коммит `5e545f4`; benign RED-описки брифов Tasks 5/6/7/10/11 (plan-side, adjudicated); P-17 rework не отражён в message `c29c590` (amend по желанию владельца); Task 15 review-fix `c32c865`.
3. **Финальное mesh-ревью батча 2**: deepseek снова false positive guard'а (num_turns=1 при 62 tool_use / 820 KB стрима) — принят REAL, DEVIATION ×2 теперь; AUTO×20 `16f3499`; disputed-фикс `6e5f631` (выбор владельца, вариант A); D2/D3 отклонены в backlog P3 (обоснования в ledger).
4. **Live-верификация — как DONE** (2026-07-03: smoke 25/25 + C-10; НЕ включать в «ручные шаги»).
5. **Оставшиеся ручные шаги владельца**: рестарт «живого» MCP-сервера Claude Desktop → `rm -rf .venv.broken-task8/`; **bump MIN-floor'ов при следующем релизе ОБЯЗАТЕЛЕН** (блок «Pending contract break» в `docs/release.md` покрывает оба батча).
6. Backlog вне PR: P3 (T-31…T-49, T-51…T-53), продуктовое решение T-47 (физическое исключение eval.rb из warehouse-сборки — до сабмита в EW), D2/D3 финального ревью.

**PR-механика:** base `master`, head `fix/deep-review-p2`, один PR на ОБА батча. Заголовок в духе «Deep-review fixes: batches 1+2 (audit P1+P2 closure)». Remote — проверить `git remote -v` (origin GitHub). Ветка ещё не пушилась — push с `-u`.

**MCP-окружение (если понадобится живой SketchUp):** `.mcp.json` — сервер `sketchup` (UV_PROJECT_ENVIRONMENT=/home/zinin/.venvs/sketchup-mcp2, SKETCHUP_MCP_HOST=192.168.20.20:9876); SketchUp 2026 на Windows, .rbz v0.2.0-warehouse @ d51b15f, eval включён владельцем. ⚠ Установленный .rbz НЕ содержит пост-ревью фиксов (16f3499/6e5f631) — для живых проверок новых валидаций пересобрать/переустановить; для PR это не требуется.

**Операционные паттерны:** build/test/lint — ТОЛЬКО через build-runner агента (никогда напрямую в main session); сабагенты РЕГУЛЯРНО уходят в idle, не прислав отчёт → SendMessage ТОМУ ЖЕ агенту (НЕ спавнить дубликата); диспатчи ревью/фиксеров — `model: "fable"`.

**Критические инварианты (нарушение = стоп):** `A.subtract(B) == B − A` — НИКОГДА не «чинить»; literal source-guard тесты — никаких форматтеров; версии `0.2.0` НЕ бампать (bump только при релизе владельцем); wire-протокол/handshake не трогать; коммиты английские conventional без AI-атрибуции.

**Untracked не трогать:** `.venv.broken-task8/` (экшн владельца после рестарта MCP-сервера), `.gemini/`, `.superpowers/`, `docs/superpowers/plans/*prompt*.md` (архив владельца).

## PLAN QUALITY WARNING

Задач плана больше нет; фаза механическая (git rm + PR), но правило прежнее: неоднозначность/конфликт (например, неожиданный remote, конфликт при push, вопросы по составу PR-описания) → СТОП и вопрос юзеру; молчаливых значимых девиаций не делать.

## INSTRUCTIONS

1. Read the documents listed above (план короткий; ledger — обе секции целиком)
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any actions
5. Ask: "What would you like me to work on?"
