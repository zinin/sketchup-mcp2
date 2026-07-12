## TASK

Execute the implementation plan for «Кровать 90×200 с ящиками — модель в SketchUp через MCP» (две кровати-варианта в одной сцене).

Use `/superpowers:subagent-driven-development` skill for execution.

## DOCUMENTS

- Design: `docs/superpowers/specs/2026-07-10-bed-90x200-design.md`
- Plan: `docs/superpowers/plans/2026-07-10-bed-90x200-model.md`

Read both documents first.

## IMPORTANT: DO NOT START WORK YET

After reading the documents:
1. Confirm you have loaded all context
2. Summarize your understanding briefly
3. **WAIT for user instruction before taking any action**

Do NOT begin implementation until the user explicitly tells you to start.

## SESSION CONTEXT

Решения и обоснования (из brainstorming-сессии):

- Цель — «точная модель + фурнитура»: каждая деталь = отдельная именованная группа (для спецификации/раскроя), направляющие — упрощённые габаритные тела для проверки зазоров.
- Кровать взрослая/гостевая, стоит длинной стороной к стене → ящики выдвигаются только с одной длинной стороны. Верх матраса ~580 мм (настил 380, борт 420, матрас утоплен на 40).
- По явной просьбе пользователя строятся ОБА варианта рядом: A — 2 ящика + изголовье, B — 3 ящика без изголовья. В кровати A левый ящик на боковых шариковых направляющих 750 мм, правый — скрытого монтажа 750 мм (пользователь хотел сравнить: боковые сильно дешевле). Изножье не нужно нигде.
- Отклонённые альтернативы: рама на ножках (под направляющие всё равно пришлось бы строить жёсткие фанерные карманы, ящики ниже), короб на цоколе (+4–6 деталей); механизмы «колёсики по полу» и «деревянные полозья» — пользователь выбрал шариковые 750 мм.
- Фасады накладные, зазор 4 мм по периметру; в спеке есть ⚠-поправка: торцевые стенки **920** мм глубиной (в устном обсуждении звучало 938 — верно 920).

Технические предупреждения (критично для исполнения):

- `eval_ruby` НЕ оборачивает код в операцию undo: каждый чанк обязан сам вызывать `start_operation`/`commit_operation` + `abort_operation` в rescue. Это уже в коде плана — не удалять и не «упрощать».
- `eval_ruby` исполняется в `TOPLEVEL_BINDING.dup`: локальные переменные и лямбды между вызовами НЕ сохраняются. Прелюдию из раздела «Прелюдия» плана вставлять целиком в каждый строительный чанк (в коде тасков стоит комментарий-маркер `# --- PRELUDE ---`).
- `eval_ruby` может быть выключен (ошибка `-32010`): пользователь включает через `Plugins → MCP Server → Settings... → Enable Ruby evaluation` (+ security-подтверждение). Передавать инструкцию дословно и ждать.
- Task 1 проверяет конфликты имён групп (`Bed_A`, `A.box`, …): если список непуст — СТОП, спросить пользователя (остатки прошлого прогона не удалять без подтверждения).
- `get_viewport_screenshot` требует SketchUp 2026+ (`major ≥ 26` из ответа Task 1); для старших версий в Task 12 описан fallback (ручной осмотр).
- В камере 3 кровати B справа остаётся 1 мм воздуха между коробкой и телом направляющей — это задумано (камера 662 мм при коробке 636 + 2×12.5), НЕ ошибка, не «чинить».
- Сверка bbox: допуск ±0.2 мм. При расхождении — ровно один вызов MCP-инструмента `undo` (откатывает весь чанк как одну операцию), исправить скрипт, повторить чанк. Не корректировать модель дополнительными правками поверх ошибочной геометрии.
- Выдвинутые ящики (`A.drawer1`, `B.drawer2`) строятся сразу в сдвинутых координатах (`dy = 350`) — это эквивалент фразы спеки «группа смещена на Y +350»; их направляющие остаются в монтажном положении на стенках камер.
- Чужие сущности в модели пользователя не трогать; `model.save` не вызывать (export_scene в Task 12 Step 4 — только по желанию пользователя, файл появится на машине SketchUp).
- Каждый вызов `eval_ruby` проходит per-call approval в клиенте — это ожидаемо; чанки не объединять в один вызов.
- Git: рабочая ветка `feature/bed-90x200`, спека и план уже закоммичены. Исполнение тасков репозиторий НЕ меняет — промежуточных коммитов нет; старые untracked-файлы в `docs/superpowers/` не трогать.
- Способ исполнения: шаблон требует subagent-driven-development, но задача — живая модель SketchUp, таски механические (послать чанк → сверить bbox), скриншоты удобнее смотреть в основной сессии. Если пользователь предпочтёт, допустимо inline-исполнение через `superpowers:executing-plans` — уточнить у него перед стартом.
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
