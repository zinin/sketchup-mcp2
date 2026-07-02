# Review Iteration 1 — 2026-07-02 17:35

## Источник

- Design: отсутствует (дизайн-фазы не было; ревью проходил implementation-план)
- Plan: `docs/superpowers/plans/2026-07-02-p1-critical-fixes.md`
- Review agents: claude-self (Fable, сабагент сессии), codex (gpt-5.5, reasoning xhigh), ext-claude ×5: zai/glm, alibaba/qwen, deepseek/v4-pro, ollama/kimi, ollama/minimax
- Merged output: `docs/superpowers/specs/2026-07-02-p1-critical-fixes-review-merged-iter-1.md`
- Парсинг/дедупликация: агент `claude-mesh:review-discussion` (7 отчётов → 38 позиций)

Примечания прогона: первые попытки deepseek/v4-pro, ollama/kimi и zai/glm оборвались (провайдерские таймауты стрима ~10 мин на длинном thinking), перезапущены под watchdog и успешно доехали со второй попытки. Секция ollama/minimax в merged-файле без начала (C1–C6 обрезаны в output.txt самого прогона) — по итоговой таблице minimax уникальный контент не потерян (C2≈MAJOR-7, C3≈CRIT-1/MINOR-11). claude-self дополнительно ВЫПОЛНИЛ продиктованные планом тесты против кода: все red/green-предсказания плана совпали дословно; фиксы задач 5 и 7 просимулированы против их тестов — проходят.

## Замечания

### [CRIT-1] Адверсариальная команда Task 4 Step 5 прогоняет только первый файл
**Источник:** claude-self, codex · **Статус:** Автоисправлено
**Действие:** Step 5 переписан: файлы прогоняются отдельными командами; откат флипов точечной правкой (не `git checkout`); добавлены флипы №2 (call-site joints) и №3 (тело `subtract_tracked`) для проверки всех уровней guard'ов.

### [CRIT-2] `close_connection()` не сериализован с `get_connection()`
**Источник:** codex, deepseek, claude-self · **Статус:** Автоисправлено
**Действие:** тело `close_connection()` обёрнуто в `async with _get_connection_lock:` (консенсусный однострочник); docstring объясняет гонку двух «singleton'ов».

### [CRIT-3] Тест `test_aclose_cannot_clobber_concurrent_reconnect` хрупок к планировщику
**Источник:** glm, qwen · **Статус:** Автоисправлено
**Действие:** синхронизация через `started = asyncio.Event()` (set внутри `slow_wait_closed`) + `asyncio.wait_for(started.wait(), 1.0)` вместо одиночного `sleep(0)`.

### [CRIT-4] `requirements.txt` остаётся с незакапленным `mcp[cli]>=1.3.0`
**Источник:** codex · **Статус:** Авто-применено после анализа
**Ответ:** файл — мёртвый реликт форка: нигде не упоминается, не менялся с initial import, несёт НЕиспользуемые websockets/aiohttp. Вариант «обновить» отклонён (увековечивает разъезжающийся дубль метаданных).
**Действие:** Task 1: новый Step 1b `git rm requirements.txt`, файл в Files, commit message обновлён.

### [CRIT-5] Семантика `position` при комбинированном вызове с rotation/scale
**Источник:** claude-self, codex, kimi (контрапункт minimax) · **Статус:** Авто-применено после анализа ⚠ (вопрос пользователю задан, ответа за 60 с не было — применена рекомендация; откатывается одной правкой)
**Ответ:** вариант A — position применяется ПОСЛЕДНЕЙ (rotation → scale → position), дельта от пост-трансформационного bbox-min ⇒ обещание «bbox-min ровно в цели» безусловно, verify-паттерн LLM («сверь bbox_mm») работает без оговорок. Отклонены: B (документировать оговорку — консервирует LLM-ловушку), C (запретить комбинации — декларация вместо решения).
**Действие:** Task 6: Interfaces, NOTE-комментарий + перенос ветки в Step 3, докстринг Step 5, prompts Step 6.

### [CRIT-6] Live-DoD T-01 самообходится на warehouse-сборке
**Источник:** codex, glm · **Статус:** Автоисправлено
**Действие:** «После плана» п.1: явное предупреждение — при закрытом eval-гейте шаг 22 скипается; для полного DoD включить eval в Settings или собрать `--variant=github`.

### [CRIT-7] «Все последующие задачи коммитятся под CI» — неверно (push только master)
**Источник:** glm · **Статус:** Автоисправлено
**Действие:** Interfaces Task 2 переформулирован: первый прогон ветки — при открытии PR; локальные сьюты — основная верификация внутри плана.

### [MAJOR-1] CI-матрица без Python 3.10 при requires-python >= 3.10 (6/7 ревьюеров)
**Статус:** Автоисправлено
**Действие:** '3.10' добавлен в матрицу; Step 3 — локальная проверка floor `uv run --python 3.10 pytest`; при падении — стоп и обсуждение с владельцем (не выкидывать 3.10 молча).

### [MAJOR-2] Claim «moved/rotated boards» не доказан (покрытие translation-only)
**Источник:** codex, kimi, qwen · **Статус:** Автоисправлено
**Действие:** commit message Task 7 сужен до «translated boards»; Interfaces: границы фикса (компенсация точна для любых аффинных T, но рез в мировых осях — на повёрнутой доске axis-aligned, семантика place_tenon; rotated не заявляются; `carve_board2_slots` без нового покрытия — осознанно).

### [MAJOR-3] Тело `subtract_tracked` не закрыто ни одним guard'ом
**Источник:** deepseek · **Статус:** Автоисправлено
**Действие:** 5-й source-guard `test_subtract_tracked_body_receiver_is_cutter` (пин `result = cutter.subtract(target)`); флип №3 в Step 5.

### [MAJOR-4] Наследники `Exception` из eval-кода роняют запрос (в т.ч. `raise Exception`, `exit`)
**Источник:** minimax · **Статус:** Авто-применено после анализа
**Ответ:** вариант A — `rescue Exception` в eval.rb с re-raise только process-control (`NoMemoryError`, `SignalException`); `SystemExit` конвертируется намеренно (`exit` не должен убивать SketchUp). Вариант «сузить контракт» отклонён: оставляет исходный T-01-класс бага для предсказуемого LLM-ввода. Belt-and-braces в Dispatch не расширяется (хендлеры — наш код).
**Действие:** Task 3: rescue-цепочка в Step 3, 5-й тест (`raise Exception, 'raw boom'` → -32603), Expected 4→5 тестов и 5/≥15, Interfaces-контракт, commit message.

### [MAJOR-5] Публичные `connect()`/`disconnect()` lock-free — инвариант на дисциплине
**Источник:** codex, claude-self, glm, kimi · **Статус:** Автоисправлено
**Действие:** Step 3d — докстринги-контракты («Low-level/internal: вызывать под self._lock или в однозадачном контексте; внешний API — ensure_connected()/aclose()»). Переименование в приватные отклонено (скоуп: smoke зовёт их напрямую легитимно).

### [MAJOR-6] `aclose()` под замком ждёт in-flight до TIMEOUT — цена не проговорена
**Источник:** claude-self, kimi · **Статус:** Автоисправлено
**Действие:** Interfaces Task 8: осознанные цены варианта (ожидание до 60 с + wait_closed; lifespan-finally после остановки тулов — риск мал; cancel-in-flight не вводим). Вариант kimi (wait_closed вне замка) отклонён: не решает 60-секундный случай, усложняет код.

### [MAJOR-7] Source-guard'ы на regex хрупки к переформатированию (5/7 ревьюеров)
**Статус:** Автоисправлено
**Действие:** комментарии «намеренный literal-пин, обновлять осознанно, не чинить под форматтер» в guard-блоках Task 4 и Task 6. Механика проверок сохранена (поведенческую защиту даёт behavioral-тест).

### [MAJOR-8] Нет поведенческого теста хендлера `transform_component`
**Источник:** codex · **Статус:** Автоисправлено
**Действие:** Task 6 Step 4b — fake-тест: mm→inch на границе (381 мм = 15″), дельта от bounds.min (10,0,0) ⇒ transform! ровно один раз с (5,0,0).

### [MAJOR-9] Счётчик «136+» неверен
**Источник:** claude-self, glm · **Статус:** Автоисправлено → `135 passed` (132 − 1 + 2 + 1).

### [MAJOR-10] Floor-bump без обязательства/тикета
**Источник:** glm, kimi, qwen · **Статус:** Автоисправлено
**Действие:** «После плана» п.3: bump MIN-floor'ов — ОБЯЗАТЕЛЬНЫЙ пункт релизного чеклиста (не «подумать»); в ветке не бампаем (Global Constraints). CHANGELOG не заводится (в репо его нет).

### [MAJOR-11] Instance-вложенность joints не задокументирована как side effect
**Источник:** claude-self, deepseek, glm · **Статус:** Автоисправлено
**Действие:** Interfaces Task 7 + комментарий хелпера: вложенный instance намеренный; глубина list_components меняется; bbox/booleans/undo прозрачно; функциональная проверка — live smoke.

### [MINOR-1] Устаревающая ссылка «step 22 verifies this» в docstring smoke
**Статус:** Автоисправлено (Task 9 Step 1: → «step 25»).

### [MINOR-2] Smoke-cleanup оставляет мусор; NB про undo станет ложнее
**Статус:** Автоисправлено (Task 9 Step 3: сверить cleanup с фактическими живыми ID; NB переформулировать — undo откатывает последний delete).

### [MINOR-3] Смоук не проверяет идемпотентность absolute position
**Источник:** qwen · **Статус:** Автоисправлено (шаг 21: повторный вызов + ассерт неизменного bbox).

### [MINOR-4] Доски шага 21 не соприкасаются (зазор 20 мм)
**Источник:** kimi · **Статус:** Автоисправлено (комментарий: DoD — намеренно bbox-containment, ловит класс бага «улёт на |T|»; контакт не ассертится). Геометрию не двигаем.

### [MINOR-5] Скрытая зависимость порядка загрузки стабов Sketchup::Group
**Источник:** claude-self · **Статус:** Автоисправлено (NB в header test_boolean_direction.rb: reopen-семантика, где искать при падениях только в run_all).

### [MINOR-6] Асимметрия форматов сообщений между rescue-arm'ами dispatch
**Источник:** claude-self · **Статус:** Отклонено (wont-fix: не баг, тесты фиксируют явно; унификация трогает существующие message-пины — вне ценности батча).

### [MINOR-7] Дублирование каркаса place_tenon ↔ add_parent_frame_prototype
**Источник:** glm · **Статус:** Автоисправлено (перекрёстный комментарий «меняешь один — синхронизируй второй»).

### [MINOR-8] Walk-ассерт обходит стёртые группы — не проверяет булеву корректность
**Источник:** glm · **Статус:** Автоисправлено (границы теста зафиксированы в header-комментарии).

### [MINOR-9] Фидельность FaceCollector реальному SketchUp (TOLERANCE, nil-vs-raise, 256)
**Источник:** qwen, minimax, glm, deepseek · **Статус:** Автоисправлено (NB в header test_geometry_builders.rb: границы фейка; живой пин — smoke z-span; не подгонять фикс под 256).

### [MINOR-10] Нет нижней границы segments
**Источник:** kimi, codex · **Статус:** Автоисправлено (Task 5 Step 3b: `segments >= 3` иначе StructuredError −32602 + тест).

### [MINOR-11] Оракул manifold-теста без калибровки
**Источник:** deepseek · **Статус:** Автоисправлено (Step 4: адверсариальная проверка — пропуск одной грани обязан уронить тест; отмечена нечувствительность edge-count к winding'у).

### [MINOR-12] CI-гигиена: --frozen, кэш uv, permissions
**Источник:** codex, glm, minimax · **Статус:** Автоисправлено (workflow: `permissions: contents: read`, `enable-cache: true`, `uv sync --frozen --extra dev`).

### [MINOR-13] Expected шага 2 Task 8 обещает красноту lifespan-теста
**Источник:** glm · **Статус:** Автоисправлено (уточнение: тест 1d — regression-pin нового пути, red-фазы нет).

### [MINOR-14] Полировка Task 8: docstring'и тестов, WHY-дубль health-check, тест send_command
**Источник:** claude-self, deepseek, codex · **Статус:** Автоисправлено (Step 3e: обновить docstring'и; комментарий про нереентерабельный Lock; проверить/добавить тест «send_command → ConnectionError при отказе»).

### [MINOR-15] Остаточные заметки Task 3 (server.rb-экспозиция; MRI-специфика SystemStackError; owner restore)
**Статус:** (а),(в) Автоисправлено — комментарии в dispatch-arm и тесте. (б) Отклонено: `def self.` — уже singleton-метод модуля, restore через `define_singleton_method` идентичен (не-issue).

### [MINOR-16] Комментарий pyproject с деталями чужого роадмапа
**Источник:** claude-self, codex · **Статус:** Автоисправлено (комментарий сокращён до самодостаточного; даты/«Dispatcher» убраны).

### [MINOR-17] Тестовая гигиена: общие фейки; лишний require; dims-комментарий
**Статус:** (в) Автоисправлено (в NB header сферы); (б) Автоисправлено (NB исполнителю: проверить необходимость require helpers/geometry); (а) Отклонено (общий файл фейков — против осознанной конвенции независимых stdlib-only файлов).

### [MINOR-18] Устойчивость Task 7: guard на использование хелпера; ensure-путь; subtract_log
**Источник:** minimax, kimi · **Статус:** Автоисправлено (новый тест `test_carve_helpers_route_through_parent_frame_prototype`; комментарий ensure/erase!; NB про class-level subtract_log).

### [INVALID-1] qwen: «private-хелпер with_eval_enabled после использования → NameError»
**Статус:** Отклонено (ложное: Ruby резолвит методы в момент исполнения; minitest зовёт тесты после полной загрузки класса; эмпирически опровергнуто claude-self).

### [INVALID-2] qwen: «несуществующие reset_joint_stats!/joint_cut_stats»
**Статус:** Отклонено (ложное: методы существуют — joints.rb:143/163; qwen сам это подтвердил в своём же отчёте).

## Изменения в документах

| Файл | Изменение |
|------|-----------|
| `docs/superpowers/plans/2026-07-02-p1-critical-fixes.md` | Коммит 1 (auto-fixes, `133538f`): 27 правок по задачам 1–9 + Global/«После плана» — CRIT-1,2,3,6,7; MAJOR-1,2,3,5,6,7,8,9,10,11; MINOR-1…5,7…14,15(а,в),16,17,18. Коммит 2 (decisions): CRIT-4 (git rm requirements.txt), CRIT-5 (position последней — 4 места), MAJOR-4 (rescue Exception + 5-й тест — 6 мест) |
| `docs/superpowers/specs/2026-07-02-p1-critical-fixes-review-merged-iter-1.md` | Создан (merge 7 отчётов, 145 КБ) |

## Статистика

- Всего замечаний: 38
- Автоисправлено (без обсуждения): 32
- Авто-применено после анализа: 3 (CRIT-4, CRIT-5 ⚠ без ответа пользователя — по рекомендации, MAJOR-4)
- Обсуждено с пользователем: 0 (вопрос по CRIT-5 задан, таймаут 60 с)
- Отклонено: 3 (MINOR-6 wont-fix, INVALID-1, INVALID-2)
- Повторов (автоответ): 0
- Пользователь сказал «стоп»: Нет
- Агенты: claude-self, codex (gpt-5.5 xhigh), zai/glm, alibaba/qwen, deepseek/v4-pro, ollama/kimi, ollama/minimax
