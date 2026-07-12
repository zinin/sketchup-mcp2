## TASK

Continue работу над «Кровать 90×200 с ящиками — модель в SketchUp через MCP» (две кровати в одной сцене).

Модель построена (Tasks 1–12 плана), Правки 1–3 внесены. Исследование конструкции ящиков под направляющие ЗАВЕРШЕНО-КАК-ЕСТЬ (часть 1 верифицирована, часть 2 остановлена — работаем с тем, что есть). Следующая фаза: правки ящиков в живой модели по результатам исследования + прочие замечания пользователя. На момент handoff SketchUp MCP был недоступен.

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
- Plan: `docs/superpowers/plans/2026-07-10-bed-90x200-model.md` — тримлен (тела Tasks 1–11 → ✅-строки); **Global Constraints и Прелюдия обязательны для любых правок модели**. Полный план: `git show 4b7be1b:docs/superpowers/plans/2026-07-10-bed-90x200-model.md`
- Progress ledger: `.superpowers/sdd/progress.md` (вне git) — история исполнения, амендменты, правки, исследование
- **Research (главный документ этой фазы):** `docs/bed-drawer-slides-research.md` — верифицированные требования к ящикам под скрытый монтаж; §6 = чек-лист правок модели; §5 = опровергнутые утверждения (НЕ использовать); §8 = что осталось непроверенным
- Сырьё исследования (вне git): `.superpowers/sdd/2026-07-10-research-drawer-slides-report.md` (полный верифицированный отчёт части 1), `...-drawer-slides-raw.md` (сырой дамп части 1), `...-750mm-raw.md` (часть 2 — 107 утверждений БЕЗ верификации)

Read design, plan, ledger, research doc first.

## PROGRESS

**Completed (всё — в живой модели SketchUp; git-коммитов исполнение не создавало):**
- [x] Tasks 1–12: обе кровати построены, bbox сверены, приёмка пройдена
- [x] Правка 1–2: 6 тегов видимости (Матрасы, Ламели, Ящики, Фасады ящиков, Направляющие, Корпус)
- [x] Правка 3: узел перегородок — опорные бруски порезаны на отрезки по камерам (`A.slats.cleat_back_1/2`, `A.slats.cleat_front_1/2` по 1001 мм; `B.slats.cleat_back_1..3`, `B.slats.cleat_front_1..3` по 661/661/662), все три перегородки пересозданы Γ-профилем с выборкой 18×70 мм (Y 920–938, Z 290–360) под царгу; дефектных пересечений 0. Итог: 90 листовых деталей, 101 группа, тег «Корпус» = 22
- [x] Исследование ящиков: часть 1 верифицирована (22 утверждения, все 3-0) → `docs/bed-drawer-slides-research.md`; часть 2 остановлена на фазе выборки (сырьё сохранено, верификации не было)

**Remaining:**
- [ ] ⚠ ПЕРВЫМ ДЕЛОМ при доступном MCP: проверить, пережила ли Правка 3 перезагрузку компьютера (см. SESSION CONTEXT — критично!)
- [ ] Правки ящиков по исследованию — ЖДАТЬ выбора пользователя. Система скрытого монтажа на 750 мм НЕ выбрана: все верифицированные серии кончаются на 548–620 мм и классе 30 кг (наш ящик брутто 40–50 кг). Варианты: (а) перестроить `A.drawer2` по верифицированной Blum-геометрии §6 как образец; (б) перевести на боковые шариковые; (в) сперва точечно допроверить Blum MOVENTO 760H / TANDEM 566H/569 / Hettich Actro (дёшево, 3–4 факта по официальным каталогам — НЕ полный харнесс)
- [ ] Прочие замечания пользователя — он назовёт сам

## SESSION CONTEXT

- ⚠ **Компьютер перезагружался ПОСЛЕ Правки 3**; сохранял ли пользователь модель — неизвестно. Проверка при первом подключении: `list_components` → искать группы `A.slats.cleat_back_1`/`_2`, `A.slats.cleat_front_1`/`_2`, `B.slats.cleat_back_1..3` (если есть только `A.slats.cleat_back` без суффикса — правка потеряна); перегородки: объём каждой ровно 5 938 920 мм³ (цельная без выборки — 5 961 600). Если правка потеряна — повторить по записи «Правка 3» в ledger.
- Модель: `Bed_A` [-18,0,0 → 2056,1306,900], `Bed_B` [2656,0,0 → 4712,1306,580]. Одобренные амендменты против спеки: ламели 890 мм (Y 24–914), матрасы Y 19–919 — спека §5/§6/§9 в этих местах устарела; истина = живая модель + ledger. 1 мм воздуха в камере 3 кровати B — задумано, не «чинить». A.drawer1 выдвинут dy=350 (боковые направляющие), A.drawer2 закрыт (скрытый монтаж, коробка пока унифицирована — её и предстоит переделывать), B.drawer2 (средний) выдвинут.
- **ВАЖНО (урок Правки 3):** `Bed_A`/`Bed_B` несут ненулевые собственные трансформы (у Bed_A origin X = −18; вложенные узлы — компенсирующие). Перед мутацией внутри узла — assert: `bed.transformation * node.transformation` == identity (±1e-6), иначе abort. Все bbox сверять в МИРОВЫХ координатах (8 углов `definition.bounds` × накопленный трансформ); голый `Group#bounds` для вложенных узлов даёт координаты в системе родителя и ВРЁТ.
- Технические правила правок (Global Constraints плана, обязательны): каждая правка = отдельный самодостаточный eval_ruby-чанк с прелюдией целиком (`TOPLEVEL_BINDING.dup` — локальные переменные между вызовами не живут); чанк сам оборачивает мутации `model.start_operation` → `commit_operation`, `abort_operation` в rescue; сверка bbox ±0.2 мм; при ошибке ровно один вызов MCP-инструмента `undo` → исправить скрипт → повторить; `model.save` НЕ вызывать (пользователь сохраняет сам); чужие сущности не трогать; работа inline, субагентов не разворачивать.
- Ключевые числа для перестройки ящика под скрытый монтаж — таблица §6 research-файла: наружная ширина A 991→**983** (проём − 18 при боковине 12 мм, зазор 9 мм/сторону); свес боковин под дном 13 мм — **уже совпадает** (низ дна Z 53 при низе боковины Z 40); вырез задней стенки ≥35×13 внизу + отверстия Ø6×10 (7 мм от каждой боковины, 24 мм от нижней кромки, зеркально L/R); замки парой L/R у переднего низа; направляющие пересадить с «под дном» на стенки камер (frameless, ось переднего крепежа 37 мм от низа проёма); глубина камеры ≥ NL+9 → для NL 750 нужно 759 мм, а камера 750 — **конфликт, требует решения** (короче NL или двигать заднюю стенку).
- НЕ отвечено исследованием: вердикт 12,5 vs 12,7 мм для боковых шариковых (в модели 12,5); нагрузка шариковых на 750 мм; РФ-марки/цены; достаточность дна 6 мм (у скрытого монтажа дно несущее). §5 research-файла — 3 опровергнутых утверждения, не использовать (в т.ч. присадка Quadro из RU-каталога AMIX).
- **Пользователь бережёт токены:** тяжёлые мульти-агентные раны (deep-research ≈ 75 верификаторов, ~1,6 млн токенов) НЕ запускать без явного запроса; он дважды останавливал раны. Возобновление остановленного рана wf_4c84b438-786 в новой сессии НЕВОЗМОЖНО (same-session only) — только сырьё из файлов.
- Git: ветка `feature/bed-90x200`; `docs/bed-drawer-slides-research.md` untracked — НЕ коммитить без просьбы; старые untracked-файлы в `docs/superpowers/` не трогать; перед будущим PR все файлы `docs/superpowers/` удаляются из ветки (правило CLAUDE.md пользователя).
- Камера в SketchUp стояла на фасадный вид, после перезагрузки могла сброситься; штатный пресет `iso` смотрит С ТЫЛА (фасады в +Y). Рецепт фасадной камеры: `target = model.bounds.center; dir = Geom::Vector3d.new(1, 1.1, 0.75); dir.normalize!; eye = target.offset(dir, model.bounds.diagonal * 1.2); view.camera = Sketchup::Camera.new(eye, target, Geom::Vector3d.new(0,0,1)); view.zoom_extents` (камера — не мутация, операция не нужна), затем скриншот с `view_preset="current"`.
- Общаться с пользователем по-русски.

## PLAN QUALITY WARNING

План и research-файл написаны для большой задачи и могут содержать ошибки, упущения и расхождения с реальной моделью.

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
5. Ask: «SketchUp запущен и MCP подключён? Начинаем с проверки Правки 3, а дальше — какую правку делаем?»
