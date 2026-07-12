## TASK

Execute the implementation plan for «Присадка направляющих SETE SB-45750»: перестройка `A.drawer2` под боковые шариковые + guide-разметка присадки (линии + точки, тег «Присадка») на всех 4 кроватях в живой модели SketchUp через MCP.

Use `/superpowers:subagent-driven-development` skill for execution.

⚠ РЕЖИМ ИСПОЛНЕНИЯ: во всех прошлых фазах этого проекта модельные правки исполнялись **inline** (`superpowers:executing-plans`) — явный выбор пользователя ради скорости и экономии токенов (SketchUp — один живой ресурс, каждый `eval_ruby` проходит per-call review в клиенте). Перед стартом спроси пользователя, каким режимом исполнять; по умолчанию ожидай inline.

## DOCUMENTS

- Design: `docs/superpowers/specs/2026-07-11-drawer-slides-drilling-guides-design.md`
- Plan: `docs/superpowers/plans/2026-07-11-drawer-slides-drilling-guides.md` (Global Constraints, Прелюдия-A, Прелюдия-B и «Исполнительный блок присадки» обязательны; полные Expected-таблицы в тасках)
- Progress ledger: `.superpowers/sdd/progress.md` (вне git) — прочитать целиком; после каждого таска дописывать запись

Read both documents first.

## IMPORTANT: DO NOT START WORK YET

After reading the documents:
1. Confirm you have loaded all context
2. Summarize your understanding briefly
3. **WAIT for user instruction before taking any action**

Do NOT begin implementation until the user explicitly tells you to start.

## SESSION CONTEXT

- Сцена (мировые bbox): `Bed_A` [-18,0,0 → 2056,1306,900], `Bed_B` [2656,… → 4712,…,580], `Bed_C` [5312,… → 7368,…,580], `Bed_D` [7968,… → 10024,…,580]; всего **233 группы**. Модель: `Z:\git\sketchup\krovat90x200\1.skp`, сохраняет ТОЛЬКО пользователь (`model.save` не вызывать). Выдвинутые ящики: `A.drawer1`, `B.drawer2`, `C.drawer1`, `D.drawer2` (+350 по Y).
- Выбор пользователя: направляющие **SETE SB-45750** (Ozon; H45, L750, полное выдвижение, 30 кг/комплект, Китай; шурупы докупаются; собственного чертежа присадки НЕ существует). Скоуп — **все четыре кровати**; Bed_A/Bed_B остаются в сцене, ничего не удалять.
- Координаты точек — из официальной схемы GTV **PK-0H45…GX_250_750** (URL в спеке §4.1; размерные цепочки сверены суммами): корпусная часть 37/101/261/389/677 от переднего торца, ящичная 36/324/676; регулировочные овалы НЕ размечаются. Дисклеймер: перед реальным сверлением пользователь сверяет точки с купленными SETE — это уже написано в спеке, повторно не обсуждать.
- Отвергнутые альтернативы (не предлагать заново): только осевые линии без точек; точки по замерам реальных направляющих вторым шагом; отдельный top-level узел «Присадка»; микротела-«кернеры» вместо guides. Принято: guides (`add_cline`/`add_cpoint`) кладутся **внутрь definition самих деталей**, тег «Присадка» на каждой guide-сущности.
- Числа плана сняты с живой модели 2026-07-11 (`list_components`, 233 группы, truncated=false). Task 1 (preflight) пересверяет всё read-only; при ЛЮБОМ расхождении — СТОП и вопрос пользователю (возможно, модель менялась после снимка).
- Порядок: Task 2 (перестройка `A.drawer2`: коробка 991→976, рельсы со «под дном» на стенки Z 138–183, фасад не трогать) обязан идти ДО Task 3 — присадка Bed_A использует новые грани 1049,5/2025,5.
- Технические правила (Global Constraints плана, обязательны): каждый чанк = полная прелюдия + одна операция `start_operation`→`commit_operation` (`abort_operation` в rescue) = один вызов `eval_ruby`; чанки не объединять (per-call review — это норма); при провале сверки ровно ОДИН вызов MCP-инструмента `undo` → исправить чанк → повторить; сверка ±0,2 мм; инвариант 233 группы после каждого чанка; чужие сущности не трогать.
- `mark_part` считает локальные координаты через `tr.inverse` от мировых — это покрывает оба возможных способа, которыми выдвинутые ящики смещены на +350 (transform подгрупп или геометрия в выдвинутых координатах); assert «чистая трансляция» обязателен, при провале — abort, не чинить молча.
- Линии корпусной части лежат в плоскости контакта рельс↔стенка: при включённом теге «Направляющие» частично скрыты телами рельсов — это ожидаемо, НЕ дефект (кадр 2 в Task 7 снимается без «Направляющих»).
- `HideConstructionGeometry` (rendering option) в Task 7 меняется ВНЕ операций (не входит в undo) и возвращается в конце; видимость тегов восстанавливается по фактическим значениям `before` из отчёта Step 1, тег «Присадка» остаётся включённым.
- Пользователь бережёт токены: тяжёлые мульти-агентные раны/воркфлоу НЕ запускать. Общаться по-русски.
- Git: ветка `feature/bed-90x200`; спека — коммит `ae35bf7`, план — `7791ff7`. Исполнение модельных правок git НЕ меняет (только ledger-записи вне git). Этот execution-prompt не коммитить (untracked — как принято). Перед будущим PR все `docs/superpowers/` удаляются из ветки (правило CLAUDE.md пользователя).

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
