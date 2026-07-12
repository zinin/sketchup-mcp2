# Continuation prompt — Deep-Review Batch 2, финиш: mesh-review → триаж → PR (2026-07-03)

## TASK

Финальный отрезок **Deep-Review Batch 2** (sketchup-mcp2): все 17 задач плана ВЫПОЛНЕНЫ и отревьюены (per-task: spec ✅ + quality approved); пост-плановая live-верификация (smoke 25/25 + C-10) ПРОЙДЕНА из прошлой сессии, обе сессионные находки зафикшены. Осталось: **whole-branch mesh-ревью** (юзер запустит `/claude-mesh:mesh-review default`), триаж накопленных ledger-Minor'ов по его вердиктам, `git rm -r docs/superpowers/`, единый PR `fix/deep-review-p2` → master с обоими батчами.

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Launch mesh-review, create PRs, run smoke checks, or make any code changes
- Run any commands (except reading documents)
- Assume what step to work on next

**The user will tell you exactly what to do.** Юзер планирует запустить `/claude-mesh:mesh-review default` сам — жди команды.

## DOCUMENTS

- Plan: `docs/superpowers/plans/2026-07-02-deep-review-batch2.md` — тримлен полностью: все 17 задач = ✅-строки с коммитами; живыми остались Global Constraints, карта задач и секция «После плана» (— это твоя фаза; её пункт 3 «Живой DoD» уже помечен ✅ Done).
- Design: `docs/superpowers/specs/2026-07-02-deep-review-batch2-design.md`
- Прогресс-ledger: `.superpowers/sdd/progress.md` — читать ОБЕ секции: батч 1 (сверху; 5 автономных решений для PR-описания) и батч 2 (снизу; все DEVIATION/ACTION/CANDIDATE/MINOR — вход финального триажа; в самом конце — блок «Live verification from session» с уже закрытыми пунктами). НЕ перезаписывать батч 1, только дописывать вниз.

## PROGRESS

**Все 17 задач батча 2 завершены** (детали и коммиты — в плане и ledger).

**Пост-плановая фаза, уже сделано (сессия 2026-07-03):**
- [x] Live-smoke `examples/smoke_check.py` — **25/25 PASSED, 0 skipped** (eval включён владельцем; split-host; шаг 18 path-only fallback; ассерты пагинации шага 16 отработали живьём). Ручной DoD плана закрыт.
- [x] C-10 — **PASSED** (шаренная definition-пара через `add_instance`; `boolean_operation difference` над одной копией не тронул вторую: bbox/def/18 entities/6 faces intact; бонусом прямой T-16: `set_material` на всё ещё шаренной паре развёл definitions, сосед не покрасился). Заодно живьём подтверждён T-55: пустая модель → `bounding_box_mm: null`.
- [x] Сессионные находки зафикшены: `8c07b2c` (cookbook: pitfall `Group#name=` уникализирует шаренную группу) + `6b8fb96` (smoke: хвост «(eval gate closed)» теперь условный). В ledger помечены «out of final triage».
- [x] План: пункт 3 «После плана» помечен Done (`71d20aa`).

**Git:** ветка `fix/deep-review-p2`, HEAD `71d20aa`, **60 коммитов** master..HEAD (оба батча), tracked-дерево чистое.

**Счётчики (после `6b8fb96` pytest перепроверен):** Ruby `ruby test/run_all.rb` → **415 runs / 1109 assertions / 0 failures / 0 errors**; Python `uv run pytest tests/ -q` → **176 passed**.

**Remaining (порядок):**
- [ ] Финальное whole-branch mesh-ревью: `/claude-mesh:mesh-review default`, дифф `master..HEAD` (оба батча; per-task ревью уже несут основную нагрузку) — юзер запустит сам
- [ ] Триаж ledger-Minor'ов/CANDIDATE'ов по вердиктам ревью (фикс-волна ОДНИМ фиксером)
- [ ] `git rm -r docs/superpowers/ && git commit` (снимает только tracked; untracked prompt-архив владельца останется в дереве — норма)
- [ ] Один PR `fix/deep-review-p2` → master (описание — см. ниже)

## SESSION CONTEXT

**MCP-окружение:** в репо `.mcp.json` — серверы `sketchup` (наш Python MCP: `uv run --directory /opt/github/zinin/sketchup-mcp2 python -m sketchup_mcp`, `UV_PROJECT_ENVIRONMENT=/home/zinin/.venvs/sketchup-mcp2`, `SKETCHUP_MCP_HOST=192.168.20.20`, порт 9876), `context7`, `exa`. Sketchup-сервер ВКЛЮЧЁН и проверен: тулы `mcp__sketchup__*` работают прямо из сессии. Живой SketchUp 2026 (build 26.1.256) на Windows `192.168.20.20`, установлен `.rbz` v0.2.0-warehouse (собран на `d51b15f`), **eval ВКЛЮЧЁН владельцем** (runtime pref). Если тулов sketchup нет в списке сессии — сервер поднялся позже её старта: попросить юзера `/mcp` → sketchup → Reconnect (прецедент прошлой сессии). Модель оставлена ПУСТОЙ (entity_count 0, слои [Layer0]).

**Гоча смоука (если перепрогонять):** шаг 24 `undo` воскрешает последний cleanup-delete (задокументировано в скрипте, не баг) — после прогона в модели остаётся dovetail pin-доска; прибрать `delete_component`. Слой «MCP Test» смоук тоже не удаляет (нет такого тула) — снять через `eval_ruby` `model.layers.remove(...)`.

**SketchUp-гоча (уже в кукбуке, `8c07b2c`):** `Group#name=` на группе с шаренной definition молча делает make_unique; `add_instance` сам по себе definition ШАРИТ. Для C-10-подобных проверок копии НЕ именовать.

**Mesh-review механика (образец батча 1, ledger):** `/claude-mesh:mesh-review default`; в батче 1 было 7 ревьюеров (builtin rev-claude + codex + zai/glm + alibaba/qwen + deepseek/v4-pro + ollama/kimi + ollama/minimax). Известные грабли: (а) delegation guard num_turns=1 может дать false positive на живой прогон (прецедент deepseek — принят REAL по 29 tool_use / 457 KB stream); (б) спорные находки — вопрос юзеру, при 60с-таймауте действовать по рекомендации контроллера с DEVIATION-записью (прецедент 5de1987); (в) AUTO-фиксы — одной волной, ОДИН фикс-сабагент со ВСЕМ списком находок, не per-finding; (г) DISMISSED-вердикты фиксировать в ledger со счётчиком. Диспатчи сабагентов — `model: "fable"` (config `dispatch_model=fable`).

**Триаж ledger (вход финального ревью; полный список — в ledger).** Ключевые незакрытые:
- Task 16 MINOR — `docs/release.md` :263/:266/:296 короткие лейблы меню («shows Start, Stop, Settings...», «→ Stop», «Start / Stop / Settings menu items»); фактические — «Start Server» / «Stop Server» / «Show Log». Paste-verbatim шаблоны EW-модераторов — реальный кандидат на фикс перед PR.
- Task 17 MINOR ×2 (оба plan-mandated) — русские комментарии `smoke_check.py:194-195`; `isinstance(lc["total"], int)` пропускает bool / отсутствие ключей даёт KeyError — оба падают громко.
- Task 10 CANDIDATE comment-4a — «Стоп чтения ГЛОБАЛЬНЫЙ» строго верен только на входе тика; кандидат на doc-строку или gap-тест.
- Task 15 MINOR (report-side) — арифметика id-параметров в task-15-report.md (заявлено 9, фактически 14); код не задет.
- Плюс россыпь MINOR по задачам 1–14 в ledger (в т.ч. батч-1 остатки «rejected» триажа батча 1 не переоткрывать).
- Сессионные два пункта (smoke suffix, cookbook pitfall) УЖЕ закрыты — «out of final triage».

**PR-описание обязано напомнить владельцу:**
- 5 автономных решений батча 1 (ledger, батч 1): пред-фикс хрупкого теста `165f214`; commit message «3.10-3.13»; 136 passed вместо «ровно 135»; deepseek/v4-pro принят REAL вопреки guard-эвристике; спорный source-guard `5de1987` по таймауту (откат = `git revert 5de1987`).
- Девиации батча 2 (ledger, батч 2): Task 8 санкционированное расширение скоупа (4 строки require_relative в legacy-шапках; откат = убрать их из `889293e`); Task 14 санкционированный 5-й коммит `5e545f4`; benign RED-описки брифов Tasks 5/6/7/10/11 (plan-side); P-17 rework не отражён в message `c29c590` (amend по желанию владельца); Task 15 review-fix `c32c865`.
- Выполненную live-верификацию упомянуть как done: smoke 25/25 + C-10 из сессии 2026-07-03 (НЕ включать в «ручные шаги»).
- Оставшиеся ручные шаги владельца: рестарт «живого» MCP-сервера Claude Desktop → `rm -rf .venv.broken-task8/`; bump MIN-floor'ов при следующем релизе (блок «Pending contract break» в release.md дополнен батчем 2).

**Операционные паттерны сессий:** сабагенты РЕГУЛЯРНО уходят в idle, не прислав отчёт → SendMessage ТОМУ ЖЕ агенту с просьбой передать готовый отчёт (НЕ спавнить дубликата). Сабагенты иногда сами метят тудушки completed преждевременно — контроллер возвращает in_progress до конца ревью. Слоты `.superpowers/sdd/task-N-*.md` — переиспользуемый scratch. Build/test/lint-команды — НЕ напрямую, через build-runner агента (конфиг юзера).

**Критические инварианты (нарушение = стоп):** `A.subtract(B) == B − A` — НИКОГДА не «чинить»; literal source-guard тесты (`test_operation_names.rb`, `test_transform_absolute.rb`, `test_joints_frame_compensation.rb`, guard `carve_board2_slots`) — никаких форматтеров; версии НЕ бампать (все четыре точки `0.2.0` — bump только при релизе владельцем); wire-протокол/handshake не трогать; мм на границе MCP; коммиты английские conventional без AI-атрибуции.

**Untracked не трогать:** `.venv.broken-task8/` (экшн владельца после рестарта Claude-Desktop-сервера), `.gemini/` (в .gitignore), `.superpowers/`, `docs/superpowers/plans/*prompt*.md` (включая этот файл — архив владельца; `git rm -r docs/superpowers/` их не снимет, они untracked).

## PLAN QUALITY WARNING

Задач плана больше нет, но фаза финиша имеет свои развилки (спорные находки mesh-ревью, ledger-триаж). Правило прежнее: неоднозначность/конфликт → СТОП и вопрос юзеру; молчаливых значимых девиаций не делать. Санкционированное исключение прошлых сессий (benign RED-описки брифов) к этой фазе неприменимо.

## INSTRUCTIONS

1. Read the documents listed above (план целиком — он короткий; ledger — обе секции)
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any actions
5. Ask: "What would you like me to work on?"
