## TASK

Финишная фаза **Deep-Review Batch 2** (sketchup-mcp2): все 17 задач плана ВЫПОЛНЕНЫ и отревьюены (per-task: spec ✅ + quality approved). Осталась пост-плановая фаза «После плана»: live-smoke верификация (теперь возможна прямо из сессии через MCP), финальное whole-branch mesh-ревью, триаж накопленных ledger-Minor'ов, `git rm -r docs/superpowers/`, единый PR `fix/deep-review-p2` → master с обоими батчами.

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

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS

- Plan: `docs/superpowers/plans/2026-07-02-deep-review-batch2.md` — тримлен ПОЛНОСТЬЮ (132 строки): все 17 задач = ✅-строки с коммитами; живыми остались Global Constraints, карта задач и секция «После плана (вне задач)» — прочитать целиком, «После плана» — это твоя фаза.
- Design: `docs/superpowers/specs/2026-07-02-deep-review-batch2-design.md`
- Прогресс-ledger: `.superpowers/sdd/progress.md` — читать ОБЕ секции: батч 1 (сверху; 5 автономных решений для PR-описания) и батч 2 (снизу; все DEVIATION/ACTION/CANDIDATE/MINOR — вход финального триажа). НЕ перезаписывать батч 1, только дописывать вниз.

## PROGRESS

**Все 17 задач батча 2 завершены** (детали и коммиты — в плане и ledger). Последние три (эта сессия):
- [x] Task 15: докстринг-оверхол 22 тулов + prompts.py (T-05) — `06ecbf2` + review-fix `c32c865` (ревьюер поймал ложную форму ответа get_selection; исправлено, re-review approved)
- [x] Task 16: зачистка доков/entry-points (T-25, T-29) — `e64c24e` (docs) + `b794c14` (build); untracked-мусор корня удалён (diff.patch, 8× session-transfer)
- [x] Task 17: финальная верификация — `d51b15f` (счётчики CLAUDE.md 415/1109 + 176; T-07-ассерты в smoke шаге 16)

**Git:** ветка `fix/deep-review-p2`, HEAD `d86e8fd` (trim-коммит поверх `d51b15f`), 57 коммитов master..HEAD (оба батча), tracked-дерево чистое.

**Верифицированные счётчики (дважды, Tasks 16+17):** Ruby `ruby test/run_all.rb` → **415 runs / 1109 assertions / 0 failures / 0 errors**; Python `uv run pytest tests/ -q` → **176 passed**.

**Remaining (фаза «После плана», порядок рекомендуемый):**
- [ ] (опционально, по команде юзера) live-smoke по MCP/скриптом — см. SESSION CONTEXT
- [ ] Финальное whole-branch mesh-ревью: `/claude-mesh:mesh-review default`, дифф `master..HEAD` (оба батча; per-task ревью уже несут основную нагрузку)
- [ ] Триаж ledger-Minor'ов/CANDIDATE'ов по вердиктам ревью (фикс-волна ОДНИМ фиксером)
- [ ] `git rm -r docs/superpowers/ && git commit` (снимает только tracked; untracked prompt-архив владельца останется в дереве — это норма)
- [ ] Один PR `fix/deep-review-p2` → master (описание — см. SESSION CONTEXT)

## SESSION CONTEXT

**Окружение этой (новой) сессии:** в репо лежит `.mcp.json` — доступны MCP-серверы `sketchup` (наш Python MCP-сервер: `uv run --directory /opt/github/zinin/sketchup-mcp2 python -m sketchup_mcp`, `UV_PROJECT_ENVIRONMENT=/home/zinin/.venvs/sketchup-mcp2`, `SKETCHUP_MCP_HOST=192.168.20.20`, порт 9876), `context7`, `exa`. То есть тулы SketchUp вызываются ПРЯМО из сессии; сервер стартует свежим процессом из текущего кода ветки (`uv run` авто-синкает venv). Split-host: SketchUp 2026 на Windows `192.168.20.20`, dev box — Linux.

**Живой SketchUp:** владелец установил свежесобранный `.rbz` — `mcp_for_sketchup/mcp_for_sketchup_v0.2.0-warehouse.rbz` (собран на коде `d51b15f`, VARIANT=warehouse, EVAL_ENABLED_BY_DEFAULT=false, post-build verified) — и запустил сервер на ПУСТОМ шаблоне. ⚠ Для `eval_ruby` (и smoke-шага 22) нужно включить «Enable Ruby evaluation» в Plugins → MCP Server → Settings (blocking security confirm) — если владелец не включил, шаг 22 упадёт с -32010; это ожидаемо, не баг.

**Live-smoke (закрывает «ручной DoD» плана, если юзер попросит):** `SKETCHUP_MCP_HOST=192.168.20.20 uv run python examples/smoke_check.py` — 25 шагов; скрипт honors SKETCHUP_MCP_HOST/PORT; на split-host шаг 18 (export) проверяет только непустой путь (файл ложится на Windows-хосте). Живьём проверяет T-07 (пагинационный конверт — новые ассерты шага 16), T-16, T-54, T-55, T-27. Дополнительный ручной пункт C-10 (boolean над копией шаренной definition) — интерактивный, можно выполнить прямо MCP-тулами: create_component → eval_ruby-копия или transform+copy → boolean_operation над одной копией → get_component_info второй (должна остаться нетронутой).

**Mesh-review механика (образец батча 1, ledger):** `/claude-mesh:mesh-review default`; в батче 1 было 7 ревьюеров (builtin rev-claude + codex + zai/glm + alibaba/qwen + deepseek/v4-pro + ollama/kimi + ollama/minimax). Известные грабли: (а) delegation guard num_turns=1 может дать false positive на живой прогон (прецедент deepseek — принят REAL по 29 tool_use / 457 KB stream); (б) спорные находки — вопрос юзеру, при 60с-таймауте действовать по рекомендации контроллера с DEVIATION-записью (прецедент 5de1987); (в) AUTO-фиксы — одной волной, ОДИН фикс-сабагент со ВСЕМ списком находок, не per-finding; (г) DISMISSED-вердикты фиксировать в ledger со счётчиком. Диспатчи сабагентов — `model: "fable"` (config `dispatch_model=fable`).

**Триаж ledger (вход финального ревью).** Ключевые НОВЫЕ записи этой сессии (полный список — в ledger, там же все старые):
- Task 16 MINOR — `docs/release.md` :263/:266/:296 всё ещё несут короткие лейблы меню («shows Start, Stop, Settings...», «→ Stop», «Start / Stop / Settings menu items»); фактические — «Start Server» / «Stop Server» / «Show Log». Пробел брифа, НЕ ошибка имплементера; paste-verbatim шаблоны EW-модераторов — реальный кандидат на фикс перед PR.
- Task 17 MINOR ×2 (оба plan-mandated) — русские комментарии `smoke_check.py:194-195` в англоязычном файле; `isinstance(lc["total"], int)` пропускает bool / отсутствие ключей даёт KeyError — оба падают громко, отмечено как свойство текста плана.
- Task 15 MINOR (report-side) — арифметика id-параметров в task-15-report.md неверна (заявлено 9, фактически 14); код не задет.
- Из прежних сессий не закрыто: Task 10 CANDIDATE comment-4a («Стоп чтения ГЛОБАЛЬНЫЙ» строго верен только на входе тика) — осознанно оставлен финальному ревью; плюс все MINOR батча 2 в ledger.

**PR-описание обязано напомнить владельцу:**
- 5 автономных решений батча 1 (ledger, батч 1): пред-фикс хрупкого теста `165f214`; commit message «3.10-3.13»; 136 passed вместо «ровно 135»; deepseek/v4-pro принят REAL вопреки guard-эвристике; спорный source-guard `5de1987` по таймауту (откат = `git revert 5de1987`).
- Девиации батча 2 (ledger, батч 2): Task 8 санкционированное расширение скоупа (4 строки require_relative в legacy-шапках; откат = убрать их из `889293e`); Task 14 санкционированный 5-й коммит `5e545f4` (CANDIDATE-пины Task 8); benign RED-описки брифов Tasks 5/6/7/10/11 (plan-side); P-17 rework не отражён в message `c29c590` (amend по желанию владельца); Task 15 review-fix `c32c865` (ложная форма get_selection, поймана per-task ревью).
- Ручные шаги владельца: live-smoke 25 шагов (если не прогнали в сессии), C-10, рестарт «живого» MCP-сервера Claude Desktop → `rm -rf .venv.broken-task8/`, bump MIN-floor'ов при следующем релизе (блок «Pending contract break» в release.md дополнен батчем 2).

**Операционные паттерны сессий:** сабагенты РЕГУЛЯРНО уходят в idle, не прислав отчёт → SendMessage ТОМУ ЖЕ агенту с просьбой передать готовый отчёт (НЕ спавнить дубликата). Сабагенты иногда сами метят тудушки completed преждевременно — контроллер возвращает in_progress до конца ревью. Слоты `.superpowers/sdd/task-N-*.md` — переиспользуемый scratch.

**Критические инварианты (нарушение = стоп):** `A.subtract(B) == B − A` — НИКОГДА не «чинить»; literal source-guard тесты (`test_operation_names.rb`, `test_transform_absolute.rb`, `test_joints_frame_compensation.rb`, guard `carve_board2_slots`) — никаких форматтеров; версии НЕ бампать (все четыре точки `0.2.0` — bump только при релизе владельцем); wire-протокол/handshake не трогать; мм на границе MCP; коммиты английские conventional без AI-атрибуции.

**Untracked не трогать:** `.venv.broken-task8/` (экшн владельца после рестарта Claude-Desktop-сервера), `.gemini/` (теперь в .gitignore), `.superpowers/`, `docs/superpowers/plans/*prompt*.md` (включая этот файл — архив владельца; `git rm -r docs/superpowers/` их не снимет, они untracked). `diff.patch` и `docs/session-transfer-*.md` уже удалены (Task 16).

## PLAN QUALITY WARNING

Задач плана больше нет, но фаза финиша имеет свои развилки (спорные находки mesh-ревью, ledger-триаж). Правило прежнее: неоднозначность/конфликт → СТОП и вопрос юзеру; молчаливых значимых девиаций не делать. Единственное санкционированное исключение прошлых сессий (benign RED-описки брифов) к этой фазе неприменимо.

## INSTRUCTIONS

1. Read the documents listed above (план целиком — он короткий; ledger — обе секции)
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any actions
5. Ask: "What would you like me to work on?"
