## TASK

Continue executing the implementation plan for «Кровать 90×200 с ящиками — модель в SketchUp через MCP» (две кровати-варианта в одной сцене).

Tasks 1–12 плана ВЫПОЛНЕНЫ: обе кровати построены в живой модели SketchUp, все bbox сверены, теги видимости настроены. У пользователя остались ЗАМЕЧАНИЯ (правки к модели) — он озвучит их в этой сессии. Работа = точечные правки живой модели отдельными `eval_ruby`-чанками.

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

- Design: `docs/superpowers/specs/2026-07-10-bed-90x200-design.md`
- Plan: `docs/superpowers/plans/2026-07-10-bed-90x200-model.md` — тримлен (коммит `61c95af`): тела Tasks 1–11 заменены на ✅-строки; **Global Constraints и Прелюдия сохранены — они обязательны для правок**. Полный исходный план: `git show 4b7be1b:docs/superpowers/plans/2026-07-10-bed-90x200-model.md`
- Progress ledger: `.superpowers/sdd/progress.md` (вне git) — история исполнения, амендменты, правки

Read all three documents first.

## PROGRESS

**Completed (всё — в живой модели SketchUp; git-коммитов исполнение не создавало):**
- [x] Task 1: preflight — SketchUp 26.1.256, eval_ruby включён, python 0.3.0 ↔ ruby 0.3.0
- [x] Tasks 2–11: обе кровати построены и собраны в `Bed_A`/`Bed_B`; все bbox сошлись с эталонами с первого прохода (ни одного undo не понадобилось)
- [x] Task 12: скриншоты сняты, чек-лист пройден; export_scene не нужен — пользователь сохранил модель на диск сам
- [x] Правка 1: теги видимости «Матрасы» (2), «Ламели» (26), «Ящики» (25 — коробки без фасадов/направляющих), «Фасады ящиков» (5), «Направляющие» (10)
- [x] Правка 2: тег «Корпус» (16 — стенки/царги/перегородки обоих коробов, изголовье, 4 опорных бруска настила)

**Remaining:**
- [ ] Замечания пользователя — он назовёт их сам в начале сессии; ждать

## SESSION CONTEXT

Состояние модели (ВАЖНО: модель отличается от спеки двумя одобренными амендментами):

- **Ламели 890 мм** вместо 910 (Y 24–914): по спеке §5 ламели 910 (Y 23–933) пересекали фасадную царгу (Y 920–938 @ Z 290–420) на 13 мм и физически не помещались в просвет 902 мм. Узлы: `A.slats` [18,18,320,2038,920,380], `B.slats` [2674,18,320,4694,920,380]. Закупка §9: 13×890 на кровать.
- **Матрасы Y 19–919** вместо 28–928 (пересекали царгу на 8 мм): `A.mattress` [28,19,380,2028,919,580], `B.mattress` [2684,19,380,4684,919,580].
- Спека НЕ правилась — §5/§6/§9 в этих местах устарели; истина = живая модель + ledger + этот промпт.
- Структура: `Bed_A` [-18,0,0,2056,1306,900] — A.box (5 дет.), A.slats (15), A.drawer1 (8, ВЫДВИНУТ dy=350, боковые направляющие), A.drawer2 (8, скрытый монтаж, закрыт), A.headboard, A.mattress. `Bed_B` [2656,0,0,4712,1306,580] — B.box (6), B.slats (15), B.drawer1..3 (по 8, средний ВЫДВИНУТ), B.mattress. Всего 95 групп; все 84 листовые детали тегированы (6 тегов), узлы-обёртки Untagged — так выключение тега не прячет соседей по узлу.
- 1 мм воздуха в камере 3 кровати B (коробка до X 4680.5, направляющая от 4681.5) — ЗАДУМАНО, не «чинить».

Технические правила (обязательны для любых правок):

- Каждая правка = отдельный `eval_ruby`-чанк; чанк САМ оборачивает мутации: `model.start_operation(...)` → `commit_operation`, `abort_operation` в rescue (eval_ruby этого не делает). Прелюдию из плана вставлять целиком в каждый чанк, создающий геометрию: `eval_ruby` исполняется в `TOPLEVEL_BINDING.dup`, локальные переменные/лямбды между вызовами НЕ живут.
- После мутаций сверять bbox (допуск ±0.2 мм); при ошибке — ровно один вызов MCP-инструмента `undo` (откатывает весь чанк как одну операцию), исправить скрипт, повторить. Не «допиливать» поверх ошибочной геометрии.
- `model.save` НЕ вызывать — пользователь сохраняет сам (модель уже сохранена им на диск); чужие сущности не трогать; правки модели репозиторий не меняют.
- Каждый вызов `eval_ruby` проходит per-call approval в клиенте — ожидаемо; при выключенном eval придёт ошибка `-32010` (включение: `Plugins → MCP Server → Settings... → Enable Ruby evaluation`).
- Скриншоты: `get_viewport_screenshot` работает (SU 2026), НО штатный пресет `iso` смотрит С ТЫЛА сцены (фасады смотрят в +Y). Для фасадного вида поставить камеру отдельным eval_ruby-вызовом (камера — не мутация модели, undo-операция не нужна), затем скриншот с `view_preset="current"`:
  `target = model.bounds.center; dir = Geom::Vector3d.new(1, 1.1, 0.75); dir.normalize!; eye = target.offset(dir, model.bounds.diagonal * 1.2); view.camera = Sketchup::Camera.new(eye, target, Geom::Vector3d.new(0,0,1)); view.zoom_extents` — камера сейчас так и стоит.
- Приём для демонстрации направляющих: временно скрыть коробки ящиков (`g.hidden = true` внутри операции), снять кадр, вернуть `hidden = false` симметричным чанком.
- Панель тегов в SketchUp: Window → Default Tray → Tags.
- Исполнение шло inline (superpowers:executing-plans) по явному выбору пользователя — правки продолжать inline, субагентов не разворачивать. Файлы `.superpowers/sdd/task-N-brief.md` — черновики отменённого субагентного захода, амендменты в них НЕ внесены; НЕ использовать как источник истины.
- Git: ветка `feature/bed-90x200`; спека и полный план в истории (`ae4f151`, `4b7be1b`), трим плана — `61c95af`. Старые untracked-файлы в `docs/superpowers/` не трогать. Перед будущим PR все файлы `docs/superpowers/` из ветки удаляются (правило CLAUDE.md пользователя).
- Общаться с пользователем по-русски.

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

## INSTRUCTIONS

1. Read the documents listed above
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any implementation
5. Ask: «Какие замечания вносим?»
