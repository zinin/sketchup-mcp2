# Merged Design Review — Iteration 1

Документ под ревью: `docs/superpowers/plans/2026-07-02-p1-critical-fixes.md` (design-дока нет — план самодостаточен).
Дата прогона: 2026-07-02. Агенты: claude-self (Fable), codex (gpt-5.5 xhigh), ext-claude ×5 (zai/glm, alibaba/qwen, deepseek/v4-pro — retry, ollama/kimi — retry, ollama/minimax).

## claude-self (Fable, сабагент сессии)

## Ревью плана «P1 Critical Fixes» (2026-07-02, ветка fix/deep-review-p1)

**Методика ревью.** Сверил все якоря строк с рабочим деревом; запустил обе сьюты (базлайны подтверждены: 327 runs / 844 assertions Ruby, 132 passed Python); выполнил все пять продиктованных планом тестовых файлов во временных копиях против текущего кода — **все красно-зелёные режимы совпали с предсказаниями плана дословно** (224 грани/0 треугольников/z≈0.038..3.96 для сферы; x 60.666..63.0 при допуске 29.5..34.5 для joints; NoMethodError + красный source-guard для transform; 3 error + 1 failure для dispatch; поведенческий тест задачи 4 зелёный на текущем коде). Дополнительно просимулировал standalone-скриптом **фиксы** задач 5 и 7 против их же тестов — все ассерты проходят (сфера: 256 граней = 224 квада + 32 треугольника, каждое ребро ровно в 2 гранях, z 0..4; joints: геометрия в допуске, attempted 3/2, scratch-группы не текут). План технически очень добротный; ниже — что нашёл.

### Critical Issues

1. **Task 4 Step 5: команда адверсариальной проверки не запускает второй файл.** `ruby test/test_boolean_direction.rb test/test_operation_names.rb` исполняет только первый файл; второе имя уходит в ARGV minitest и молча игнорируется — проверено эмпирически (summary показывает 3 runs первого файла, exit 0, ошибок парсинга опций нет). То есть требование Step 5 «ОБА файла обязаны упасть» этой командой невыполнимо: source-guard'ы при флипе `operations.rb:49` вообще не прогоняются, а `| tail -5` скроет от исполнителя, что второй сьюты в выводе нет. Флип behavioral-тест поймает, но весь смысл Step 5 — доказать, что guard'ят **оба** уровня. Фикс тривиален: две отдельные команды, либо `ruby -e 'require_relative "test/test_boolean_direction"; require_relative "test/test_operation_names"'`.

### Concerns

1. **Скрытая зависимость от порядка загрузки стабов `Sketchup::Group` в run_all.** Новый `test_boolean_direction.rb` («b») загрузится раньше `test_collect_components.rb` («c»), чей стаб `Sketchup::Group` определён **не-guarded и с методами** (test_collect_components.rb:16-24: `initialize`, `valid?`, attr_accessor'ы). Guarded-пустышка нового файла станет базовым определением, collect_components его переоткроет, `FakeSolid`/`FakeBoard` унаследуют чужие методы. Эмпирически сейчас всё зелено (проверил совместную загрузку в одном процессе — 6 runs, 0 failures: FakeSolid переопределяет всё, что трогает `boolean_operation`/`describe_entity`). Но конструкция хрупкая: переименование файла или добавление метода в стаб collect_components может тихо изменить поведение фейков. План сам декларирует конвенцию «глобальные стабы — только guarded», а опирается на файл, её нарушающий. Дёшево закрыть: попутно guard'ануть стаб в test_collect_components или хотя бы зафиксировать зависимость комментарием.

2. **Task 9: устаревающая ссылка на номер шага в docstring smoke_check.py.** Step 1 правит только строку 5 (`SketchUp 2024+`), но строка 8 docstring — «…(MIN_RUBY..MAX_RUBY); **step 22** verifies this» — после ренумерации указывает на новый eval-syntax-error шаг вместо version handshake (теперь шаг 25).

3. **Task 8: `aclose()` под `_lock` ждёт in-flight запрос — shutdown может висеть до TIMEOUT.** `send_command` держит замок весь roundtrip (до 60 с по умолчанию), значит `close_connection()` в lifespan-finally в худшем случае ждёт полный таймаут. Это осознанная цена «чистого» варианта, но план её нигде не проговаривает. Смежное: `close_connection()` не сериализован с `get_connection()` модульным замком — параллельный `get_connection` во время закрытия может получить объект, который вот-вот «забудут» (сокетов-сирот не будет, но два объекта могут ненадолго сосуществовать). Оба риска на практике малы (lifespan-finally выполняется после остановки тулов) — но стоит одной строки в Interfaces.

4. **Task 8: инвариант «мутации только под `_lock`» держится дисциплиной, а не кодом.** `connect()`/`disconnect()` остаются публичными и lock-free; их прямые вызовы извне (smoke_check.py зовёт `conn.connect()`/`conn.disconnect()` напрямую — там однозадачный контекст, это ок) инвариант формально нарушают. План не добавляет в докстринг `disconnect()` пометку «internal: вызывать под `_lock`; внешним — `aclose()`», хотя это единственное место, где будущий контрибьютор узнал бы об инварианте.

5. **Task 8 Step 6: счётчик «136+» неверен.** 132 − 1 (замена test_get_connection_raises…) + 4 новых = **135**. Мелочь, но план в других местах педантичен к числам, и исполнитель, увидев 135 < «136+», может начать искать несуществующую пропажу.

6. **Task 2: матрица не покрывает Python 3.10** при `requires-python >= 3.10` и классификаторе `Programming Language :: Python :: 3.10`. Либо добавить 3.10 в матрицу, либо поднять floor/убрать классификатор — иначе CI зелёный не гарантирует работоспособность на заявленном минимуме. (Остальное в Task 2 сходится: `[project.optional-dependencies].dev` существует → `uv sync --extra dev` корректен; `require "zip"` в test_package_default_variant.rb безусловный → `gem install rubyzip` в workflow действительно load-bearing; uv.lock фиксирует mcp 1.27.0 → floor 1.27 честный.)

7. **Task 6: семантика position при одновременных rotation/scale не оговорена.** Код применяет position → rotation → scale; rotation вокруг центра bbox **после** переноса меняет bbox-min, т.е. обещание докстринга «bbox-min lands exactly at [x,y,z]» строго верно только для вызова с одним position. Стоит добавить одну фразу в докстринг/промпт («if combined with rotation/scale, the move happens first»), иначе LLM будет удивляться расхождению bbox_mm после комбинированных вызовов.

8. **Task 7: результат — лишний уровень вложенности внутри доски.** Раньше pin_group/результаты subtract'ов лежали прямо в `board.entities`; теперь вся резьба живёт внутри инстанса прототипа (инстанс → definition → nested groups). Для bbox/booleans/undo это прозрачно, но наблюдаемая структура модели меняется (глубина `list_components`, потенциально назначение материалов на подгруппы). План не упоминает это как осознанный side effect; live-smoke (шаг 21) его частично покрывает. Также замечу: сами subtract'ы теперь выполняются между sibling-группами внутри scratch-группы на корне модели — паттерн эквивалентен прежнему (siblings внутри доски) и place_tenon-инстансинг production-проверен, но именно **комбинация** «subtract внутри прототипа + инстансинг» на живом SketchUp до ручного smoke не проверена — правильно, что план объявляет живой прогон DoD для T-03.

9. **Task 3: рассинхрон форматов сообщений между arm'ами dispatch.** Новый arm даёт `"#{e.class}: #{e.message}"`, существующий StandardError-arm — голый `e.message`. Для eval-путей класс добавляет eval.rb сам, а вот RuntimeError из любого «обычного» хендлера по-прежнему придёт без имени класса. Не баг (тесты это фиксируют явно), но асимметрия, которую при желании можно унифицировать в этом же батче.

10. **Smoke cleanup→undo quirk усиливается.** `delete_component` сам undoable, поэтому шаг undo (новый 24) откатывает **последний delete** (воскрешает `b_pin`), а не mortise_tenon, как утверждает NB-комментарий. Это pre-existing неточность (сегодня воскрешается `b_tenon`), план её не ухудшает функционально, но расширение cleanup-списка делает комментарий ещё более ложным — дёшево поправить формулировку NB заодно.

### Suggestions

1. **Step 5 задачи 4** — после исправления команды (см. Critical 1) стоит флипнуть адверсариально и один из joints call-site'ов (`subtract_tracked(board, cutter)`), чтобы убедиться, что и третий guard (`test_joints_subtract_call_sites_keep_cutter_first`) реально краснеет.
2. **Task 8**: в тексте переписываемого `test_get_connection_cold_start_race_creates_singleton_once` docstring останется про «две холодные точки вызывают open_connection» — при переписывании стоит обновить и его (семантика eager-connect переехала в `ensure_connected`). Аналогично устареют docstring'и существующих lifespan-тестов («get_connection raises IncompatibleVersionError») — они останутся зелёными, но описывают старую механику.
3. **Task 5**: `build_sphere` использует только `dims[0]` — эллипсоидные dimensions молча дают сферу. Вне скоупа T-02, но раз уж появился test_geometry_builders.rb, одна строка-комментарий в тесте («dims[1..2] игнорируются билдером — фиксируем сферу [4,4,4]») предотвратит ложное впечатление, что тест подтверждает поддержку эллипсоидов.
4. **Task 3**: belt-and-braces покрывает Dispatch, но `server.rb` (dispatch_frame, timer-loop) по-прежнему ловит только StandardError — ScriptError из не-хендлерных путей сервера всё ещё улетит в `UI.start_timer`. Реалистичный вектор (eval) закрыт; для полноты можно отметить остаточную экспозицию в комментарии, расширять rescue там необязательно.
5. **Task 1**: комментарий в pyproject про «новый Dispatcher, только спека 2025-11-25» — деталь чужого роадмапа, которая может устареть/оказаться неточной; сам cap самодостаточен. Достаточно «v2 ships breaking changes; migration is a separate ticket».
6. **Task 9**: ассерт `elapsed < 10` для шага 22 неявно зависит от того, что smoke-таймаут (30 с) больше порога — сейчас это так; если кто-то уменьшит `timeout=30.0`, ассерт останется валиден. Ок как есть; упоминаю для полноты.

### Questions

1. **Task 6**: какова желаемая контрактная семантика `position` при одновременной передаче `rotation`/`scale` (см. Concern 7) — «перенос до ротации» достаточно задокументировать, или комбинированные вызовы считаем неподдерживаемыми?
2. **Task 8**: приемлема ли задержка shutdown до полного TIMEOUT при in-flight запросе (aclose ждёт под замком), или нужен cancel in-flight на закрытии? Принятый «чистый» вариант этого не требует, но решение стоит зафиксировать явно.
3. **Task 2**: сознательно ли исключён Python 3.10 из матрицы (requires-python >= 3.10)? Если да — стоит синхронизировать floor/классификаторы.
4. **Task 9, шаг 21**: допуск `±(15+1)` мм по X — единица люфта заложена под CUTTER_OFFSET/погрешности солид-операций? Просто подтвердить, что +1 мм не маскирует потенциальный сдвиг на толщину реза.

**Итог.** План готов к исполнению после исправления Critical 1 (одна команда в Step 5 задачи 4). Качество продиктованного кода исключительное: все пять тестовых файлов и оба фикса (задачи 5, 7) верифицированы против реального кода и ведут себя ровно как предсказано, все ~30 якорей строк точны, порядковые зависимости (4→7: literal call-sites `subtract_tracked(cutter, pin_group)`/`(cutter, group)` в новом коде joints сохранены дословно; 6→9, 3/5/7→9) соблюдены, конвенции тестов (guarded-стабы, setup/teardown с восстановлением Method-объекта) выдержаны во всех новых файлах.

---

## codex-executor (gpt-5.5, reasoning xhigh)

### Critical Issues

- T-30 закрыт неполно. План меняет только [pyproject.toml](/opt/github/zinin/sketchup-mcp2/pyproject.toml:20) и `uv.lock`, но в tracked [requirements.txt](/opt/github/zinin/sketchup-mcp2/requirements.txt:1) остаётся `mcp[cli]>=1.3.0`. Если этот install path ещё поддерживается, пользователи всё равно могут получить `mcp>=2`. Нужно либо обновить `requirements.txt`, либо явно удалить/объявить устаревшим.

- T-08 не выполняет заявленный инвариант. План говорит, что `_reader/_writer` мутируются только под `self._lock`, но предложенный код оставляет публичные `connect()` и `disconnect()` без lock в [connection.py](/opt/github/zinin/sketchup-mcp2/src/sketchup_mcp/connection.py:77) и [connection.py](/opt/github/zinin/sketchup-mcp2/src/sketchup_mcp/connection.py:193). `close_connection()` также не синхронизирован с `_get_connection_lock`, поэтому concurrent `get_connection()` может получить объект, который `close_connection()` уже закрывает и потом выкинет из singleton. Нужен явный split: `_connect_unlocked`/`_disconnect_unlocked` private, публично только `ensure_connected()`/`aclose()`, а `close_connection()` должен атомарно забирать singleton под модульным lock.

- Живой DoD для T-01 сам себя обходит. Task 9 допускает skip eval-синтаксис шага через `_maybe_skip_eval()` ([план](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-p1-critical-fixes.md:1646)), а post-plan DoD предлагает собирать `--variant=warehouse` ([план](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-p1-critical-fixes.md:1734)), где `eval_ruby` по умолчанию выключен. Тогда T-01 не проверяется live-smoke, хотя план называет это DoD. Нужно требовать включить eval в Settings или прогонять GitHub-вариант для DoD T-01.

- Task 7 заявляет “moved/rotated boards”, но тестовая модель translation-only ([план](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-p1-critical-fixes.md:1105)), а реализация продолжает строить геометрию от axis-aligned `board.bounds.center` ([план](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-p1-critical-fixes.md:1224)). Это покрывает сдвиг, но не доказывает и, вероятно, не чинит реальные rotated/nested frame cases. Либо убрать claim/commit message про rotation, либо добавить rotated fake/live coverage и корректную oriented-frame математику.

- Adversarial check в Task 4 неверен: `ruby test/test_boolean_direction.rb test/test_operation_names.rb` ([план](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-p1-critical-fixes.md:569)) запускает только первый Ruby-файл, второй попадает в `ARGV`. Плюс `git checkout -- ...` может снести чужие незакоммиченные правки. Нужно запускать файлы отдельно и откатывать временный flip точечным патчем.

### Concerns

- `transform_component.position` не определён для combined call с `rotation`/`scale`. План обещает, что bbox-min “lands exactly there” ([план](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-p1-critical-fixes.md:906)), но Ruby применяет position до rotation/scale ([geometry.rb](/opt/github/zinin/sketchup-mcp2/mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb:92)), так что финальный bbox-min может уже не быть target. Нужно либо позиционировать последним, либо документировать order semantics.

- Task 6 тестирует pure helper и source-regex, но не поведение handler path: mm-to-inch conversion, `E.find!`, `start_operation`, `transform!`, `describe_entity`. Для breaking semantic этого маловато.

- CI matrix пропускает Python 3.10, хотя `requires-python = ">=3.10"` в [pyproject.toml](/opt/github/zinin/sketchup-mcp2/pyproject.toml:6). Минимальная версия должна быть в matrix, иначе легко случайно внести синтаксис/typing, ломающий 3.10.

- CI использует `uv sync --extra dev` без `--frozen` ([план](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-p1-critical-fixes.md:138)). Это хуже ловит рассинхрон `pyproject.toml`/`uv.lock`; в CI лучше `uv sync --frozen --extra dev`.

- Smoke cleanup всё ещё оставляет `id1`/`id2` после boolean union: текущий cleanup удаляет только [id_bool, b_mortise, b_tenon](/opt/github/zinin/sketchup-mcp2/examples/smoke_check.py:237), а план расширяет список без post-chamfer/post-fillet IDs ([план](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-p1-critical-fixes.md:1669)). Это оставляет мусор в live model.

- В smoke docstring останется stale ссылка “step 22 verifies handshake” ([smoke_check.py](/opt/github/zinin/sketchup-mcp2/examples/smoke_check.py:8)), если Task 9 обновит только первую precondition-строку. После ренумерации handshake будет step 25.

### Suggestions

- Для T-08 добавить Python-тест, где `get_connection()` возвращает fake conn, а `send_command()` бросает `ConnectionError`. Сейчас существующий тест покрывает старый источник ошибки: `get_connection` raising.

- Для T-04 добавить behavioral Ruby fake-test всего `transform_component`: entity starts at bbox-min `[10,0,0]`, call `position=[15,0,0]`, verify translation delta `5`, commit called, returned bbox reflects absolute target.

- Для T-02 добавить минимум guard на `segments < 3` или тесты малых значений. Сейчас сфера принимает любой positive int, но manifold sphere с `segments=1/2` не имеет смысла.

- Для Task 1 обновить формулировку релизов: PyPI уже показывает более новые prerelease/stable-line версии, но рекомендация `<2` остаётся корректной: https://pypi.org/project/mcp/ и https://pypi.org/project/mcp/2.0.0a1/. `setup-uv` с `python-version` сам по себе выглядит допустимо по официальной документации: https://github.com/astral-sh/setup-uv.

- Базовые проверки текущего дерева зелёные: `ruby test/run_all.rb` даёт `327 runs / 844 assertions`, `uv run pytest tests/ -q` даёт `132 passed`.

### Questions

- `requirements.txt` считается поддерживаемым install path или историческим мусором? От этого зависит, править его в T-30 или удалить из публичного контракта.

- Для `transform_component(position+rotation/scale)` целевой bbox-min должен быть финальным после всех transforms или только после translation sub-step?

- T-03 должен реально покрывать rotated boards в этом батче, или только boards moved after creation? Сейчас план и commit message обещают больше, чем тесты доказывают.

---

## ext-claude-executor (zai/glm)

Проверил тело `_maybe_skip_eval` (smoke_check.py:48-63) — оно ловит только `-32010` (eval disabled) и пробрасывает остальные `SketchUpError`. Значит шаг 22 (Task 9) корректно работает в обоих вариантах сборки. Все критичные якоря сверены. Пишу ревью.

---

# Ревью плана «P1 Critical Fixes»

План исключительно детальный: я досрочно сверил **все** дословные правки и тесты с реальным кодом — якоря строк точны (eval.rb:29-35, dispatch.rb:49-54, operations.rb:40-46/49/190, geometry.rb:76-109/151-183, joints.rb:271-354, connection.py:381-405, app.py:38-41, tools.py:45-46/127, prompts.py:34, pyproject.toml:20-22), а математику фиксов Task 5 и Task 7 я пересчитал вручную — цифры в плане (224→256 граней, геометрия x≈60.7 на старом коде против 30.7–33 на новом) сходятся. Это редкая зрелость плана. Ниже — проблемы.

## Critical Issues

**1. Task 8, шаг 1(c) `test_aclose_cannot_clobber_concurrent_reconnect` — хрупкость к планировщику asyncio (риск флаки в CI).**
Тест синхронизирует две корутины через одиночный `await asyncio.sleep(0)`, рассчитывая, что `aclose()` успеет за один цикл пройти `async with self._lock` → `disconnect()` → `wait_for(slow_wait_closed())` → `gate.wait()` и заблокироваться там, держа лок. Это верно **только как implementation detail CPython**: быстрый путь `asyncio.Lock.acquire()` (lock свободен) не делает `yield`. Контракт asyncio этого не гарантирует — изменение реализации локов в 3.13+, PyPy или патч `asyncio.Lock` сделает `ensure_connected()` способным захватить лок первым (`fake_connect` поставит fresh-пару), после чего `aclose` → `disconnect` безусловно обнулит её, и `assert conn._writer is fresh_writer` упадёт. Для CI-теста, который должен быть эталоном детерминизма, это слишком хрупко.
**Рекомендация:** добавить явную точку синхронизации — `asyncio.Event` внутри `slow_wait_closed`, который set'ится при входе, и в тесте `await started.wait()` перед созданием `reconnect_task`. Тогда тест не зависит от числа `sleep(0)` и поведения планировщика.

**2. Task 2 — утверждение «все последующие задачи плана коммитятся уже под CI» фактически неверно.**
Триггер `on: push: branches: [master]` + `pull_request:`. Коммиты задач 3–9 уходят в `fix/deep-review-p1`, а не в `master` — push-триггер их не покрывает. CI реально запустится только при открытии PR (`pull_request: synchronize` гоняет последующие push в head-ветку). То есть во время выполнения плана (до открытия PR) локальной обратной связи от CI нет. Формулировка вводит исполнителя в заблуждение (он может решить, что каждый коммит проверяется). Либо добавить `push: branches: [master, "fix/**"]`, либо убрать обещание «под CI» и явно сказать «CI прогонится на PR».

**3. Task 8, шаг 6 — ожидаемый счётчик `136+` не сходится с фактическим приростом.**
Текущий Python-базлайн 132. По плану: (a) замена 1→2 (net +1), (b) перепись cold-start (net 0), (c) +`test_aclose` (+1), (d) +`test_lifespan_degrades` (+1) = **135**, а не «136+». Незначительно (Task 10 всё равно обновит по факту), но «136+» собьёт исполнителя, который сочтёт, что что-то пропустил.

## Concerns

**C1. Source-guard'ы (Task 4 шаг 1, Task 6 шаг 1) хрупки к форматированию.** Пины вида `/when "difference"\s+then tool_copy\.subtract\(target_copy\)/` сломаются (ложно) при любом рефакторинге, который трогает пробелы/перенос — например, при прогоне `rubocop --auto-correct`. План это осознаёт («ловят правку literal-строки»), и поведенческий тест `test_boolean_direction.rb` — настоящая защита; но guard для joints (`subtract_tracked(cutter, board|pin_group|group|current)`) — **единственный** заслон от рефакторинга, меняющего receiver вычитания. Стоит хотя бы закомментировать в самих тестах, что это намеренный literal-pin и его нельзя «причёсывать».

**C2. Task 9, шаг 22 — live-DoD для T-01 срабатывает только в github-сборке.** `_maybe_skip_eval` глотает `-32010` (eval disabled) и возвращает `None` → на warehouse-сборке (по умолчанию, eval off) шаг 22 просто инкрементирует `eval_skipped` и пропускает проверку SyntaxError. При этом раздел «После плана» п.1 предписывает пересобрать именно **warehouse**-вариант. Несоответствие: чтобы живьём проверить T-01, нужен github-вариант (eval on). Unit-тесты Task 3 покрывают T-01 с принудительным `eval_enabled=true`, так что проверка есть — но стоит явно сказать, что live-smoke для T-01 требует github-сборки, иначе исполнитель решит, что T-01 провалиден, когда шаг просто skipped.

**C3. Task 8 — `disconnect()` остался публичным и сам по себе не берёт `self._lock`.** После фикса все *фактические* вызовы `disconnect` идут под локом (`aclose`, error-path'ы `connect`/`_send_once`, всё под `self._lock`). Но метод публичен — будущий caller, вызвавший `conn.disconnect()` напрямую, вернёт ровно ту гонку, которую фикс убирал. Стоит либо переименовать в `_disconnect`, либо явно задокументировать контрактом «call only under `self._lock`».

**C4. Task 6 — молчаливый breaking change `position` без bump версии.** В рамках батча (Global Constraints: «версии не бампаем») это решение осознанное, и recommendation поднять MIN-floor'ы при релизе — правильная. Но пока релиза нет, любой, кто обновит только сервер или только клиент, получит тихие промахи позиционирования (двойной сдвиг). Это не блокер плана, но риск тем выше, чем дольше тянется релиз — стоит хотя бы зафиксировать дату/тикет для floor-bump, чтобы «висящий» breaking change не забылся.

**C5. Task 7 — `add_parent_frame_prototype` дублирует каркас `place_tenon` (joints.rb:205-239).** `place_tenon` уже делает ровно то же: `prot = active_entities.add_group` → build → `prot.transform!(board.transformation.inverse)` → `add_instance(prot.definition, prot.transformation)` → `prot.erase!`. План создаёт параллельный хелпер вместо того, чтобы переписать `place_tenon` через него (DRY). План сознательно консервативен («соседние place_tenon/carve_board2_slots уже корректны — НЕ трогать») — это разумно (не трогать работающее), но осадок: теперь паттерн world-frame-компенсации описан в двух местах, и правка математики в одном не синхронизируется с другим. Как минимум — добавить в `add_parent_frame_prototype` комментарий «тот же паттерн, что у place_tenon; при изменении — синхронизировать».

**C6. Task 8, шаг 1(d) `test_lifespan_degrades_when_eager_connect_fails` — не «красный» на старом коде.** На старом `lifespan` `FakeConn.ensure_connected` не вызывается (старый код зовёт только `get_connection`), исключение не поднимается, `state=={}` → тест зелёный. То есть это regression-pin, а не TDD-red-тест (в отличие от `test_connection.py`, который честно падает по `AttributeError`). Шаг 2 (Expected) обещает «новые/переписанные тесты красные» — для `test_app.py` это не так. Не блокер, но формулировка плана неточна; стоит уточнить, что этот тест — фиксация нового пути, а не детекция старого бага.

**C7. Task 7 — walk-ассерт обходит стёртые группы.** В `FakeGroup.subtract` результат-группа добавляется в коллекцию, а operand'ы `erase!`, но их `.entities.faces` остаются доступны для `world_xs`. В реальном SketchUp стёртая группа геометрию не отдаёт. Тест проверяет **координаты построенных faces** (правильность фрейма), а не результат `subtract` — поэтому он зелёный даже при семантически неверном subtract (лишь бы faces были в правильном месте). Это сознательный компромисс (живая проверка результата — smoke шаг 21), но стоит явно отметить в комментарии теста, что он верифицирует frame-compensation, а не корректность булева результата.

**C8. Task 5 — unit-счётчик граней (256) может не совпасть с реальным SketchUp.** `FaceCollector.add_face` просто складывает точки в массив; реальный SketchUp может мержить копланарные грани или реджектить квази-вырожденные. После фикса полюса — треугольники (не копланарны с соседями), так что 256 правдоподобно, но unit-тест на фейке **гарантирует** лишь поведение фейка. Надёжная проверка — smoke шаг 20 (z-span), а не число граней. Стоит это проговорить, чтобы исполнитель не «подгонял» фикса под unit-цифру, если живой SketchUp даст иное число.

**C9. Task 2 — Python-matrix 3.11–3.13 при `requires-python = ">=3.10"`.** 3.10 в CI не тестируется. Код вроде не использует 3.11+-специфику, но формально floor заявлен 3.10. Либо добавить 3.10 в matrix, либо поднять `requires-python` до 3.11 (тогда и matrix, и классификаторы pyproject синхронны).

**C10. Task 2 — нет кэширования (`uv`/`gem`), CI медленный.** `gem install rubyzip` и `uv sync` на каждом run без кэша. Для 1.3 c + 2.4 c сьют это не смертельно, но `setup-uv` и `ruby/setup-ruby` поддерживают кэширование из коробки — стоит включить (`enable-cache` / `bundler-cache`).

## Suggestions

- **Усилить `test_aclose` (см. Critical 1)** явным `Event` вместо `sleep(0)` — единственное, что я бы точно правил до реализации.
- **CI**: либо расширить `push`-триггер на feature-ветки, либо убрать обещание per-commit CI (Critical 2); добавить 3.10 в matrix и кэширование (C9, C10).
- **`disconnect` → приватный/контракт** (C3) — дешёвое страхование от возвращения гонки будущим caller'ом.
- **Документировать literal-pin-характер source-guard'ов** прямо в тестах (C1) — чтобы будущий «причёсыватель» кода не сломал их.
- **Синхронизировать комментарий** `add_parent_frame_prototype` ↔ `place_tenon` (C5).
- **Обновить docstring smoke** не только строку 5, но и строку 8 (`step 22 verifies this` → `step 25` после ренумерации) — план Task 9 шаг 1 этого не учитывает, появится рассинхрон docstring/кода.

## Questions

1. **Task 9 / T-01 live-DoD:** планируется ли отдельный live-прогон smoke на **github**-варианте сборки, чтобы шаг 22 реально упражнял SyntaxError-путь? Или T-01 закрывается только unit-тестами Task 3?
2. **Task 8 naming:** почему `aclose` как отдельный публичный метод, а не `disconnect_locked`/приватный `_disconnect` + `aclose`-обёртка? Текущий вариант оставляет `disconnect` публичным и опасным (C3).
3. **C4 floor-bump:** есть ли уже тикет/дата на поднятие MIN_PYTHON/MIN_RUBY для breaking-change `position`, или это «при релизе подумаем»? Если второе — риск забыть.
4. **Task 7 carve_tails:** новый `carve_tails` создаёт хвосты как **instance** прототипа в `board.entities`, тогда как старый клал вложенную группу. Структурно сцена меняется (instance вместо group). Рассматривалось ли влияние на последующие `boolean_operation`/`find_components` по типу entity, или проверено, что `describe_entity`/boolean работают с instance так же?

---
**Итог:** план годен к реализации; математика фиксов верна, якоря точны, поведение `_maybe_skip_eval`/dispatch/entities сверено. К обязательной правке до имплементации — только **Critical 1** (флаки-риск `test_aclose`); остальное — уточнения формулировок и недорогие страховки, не меняющие скоуп. Решения пользователя (абсолютный `position`, чистый вариант T-08, порядок 4→7 и 3/5/7→9) реализованы корректно и оспаривать их не нужно.


---

## ext-claude-executor (alibaba/qwen)

Отлично, теперь у меня достаточно информации для критического ревью. Начинаю анализ.

---

## Критический анализ плана P1 Critical Fixes

### Critical Issues (Критические проблемы)

#### 1. **Task 3: Private helper `with_eval_enabled` определен ПОСЛЕ использования**

В Task 3 (строки плана 246-254) private-хелпер `with_eval_enabled` добавляется в конец класса `TestDispatchPostHandshake`, **после** всех тестовых методов, которые его вызывают (строки 184-244).

**Проблема:** В Ruby private-методы **должны быть определены до первого вызова** в теле класса, ИЛИ класс должен быть полностью определен до вызова методов. Если тесты определяются в том же порядке, что и в плане, Ruby поднимет `NameError: undefined local variable or method 'with_eval_enabled'` при определении класса.

**Решение:** Переместить `with_eval_enabled` **перед** первым тестом, который его использует (перед `test_eval_ruby_syntax_error_returns_structured_error_fast`), или сделать его public/class method.

#### 2. **Task 6: Source-guard тест слишком хрупок**

В Task 6 (строки плана 836-845) тест `test_transform_component_translates_via_position_delta` использует regex:

```ruby
body = src[/def self\.transform_component.*?(?=\n      def self\.)/m]
```

**Проблемы:**
- Regex ищет `def self.` после `transform_component`, но в `geometry.rb` следующий метод — `def self.position_delta` (plan line 882), который добавляется **после** `transform_component`. Regex захватит тело до `position_delta`, а не до следующего "настоящего" метода.
- Если порядок методов изменится или добавится новый метод между `transform_component` и `position_delta`, тест сломается.
- Вторая проверка (строки 843-844) ищет `translation(\s*\n?\s*Geom::Point3d.new(position[0]`, но новый код (план 876-878) использует `delta[0]`, а не `position[0]`. Проверка корректна, но regex может не совпасть с реальным форматированием.

**Решение:** Использовать более надежный парсинг (например, извлекать тело метода по отступам) или проверять наличие `position_delta(` в файле без привязки к конкретному методу.

#### 3. **Task 7: Тест вызывает несуществующие методы `J.reset_joint_stats!` и `J.joint_cut_stats`**

В Task 7 (строки плана 1164-1176) тест вызывает:
```ruby
J.reset_joint_stats!
J.carve_pins(...)
assert_equal 3, J.joint_cut_stats["attempted"]
```

**Проверка:** Я нашел `reset_joint_stats!` на строке 143 и `joint_cut_stats` на строке 163 в `joints.rb` — оба метода **существуют**. ✅

**Однако:** Методы `carve_tails`, `carve_pins`, `carve_board1_fingers` в текущем коде (строки 271-354) **НЕ вызывают** `reset_joint_stats!` — это делает только `create_mortise_tenon` (строка 28). Тест вызывает `carve_pins` напрямую, ожидая, что статика будет инициализирована.

**Проблема:** Если `carve_pins` вызывается без предварительного `reset_joint_stats!`, переменные `@_joint_cuts_attempted` и `@_joint_cuts_failed` могут быть `nil`, что приведет к `NoMethodError` при `+= 1` в `subtract_tracked`.

**Решение:** Тест **правильно** вызывает `J.reset_joint_stats!` перед `carve_pins` (строка 1165), но нужно убедиться, что это работает для всех carve-методов. Также стоит добавить `reset_joint_stats!` в начало каждого carve-метода (или в `subtract_tracked` с проверкой на nil).

#### 4. **Task 8: Тест `test_aclose_cannot_clobber_concurrent_reconnect` может быть недетерминированным**

В Task 8 (строки плана 1401-1440) тест использует:
```python
close_task = asyncio.create_task(conn.aclose())
await asyncio.sleep(0)   # aclose взял lock и повис в wait_closed
reconnect_task = asyncio.create_task(conn.ensure_connected())
await asyncio.sleep(0)   # ensure_connected ждёт lock
```

**Проблема:** `asyncio.sleep(0)` передает управление event loop, но **не гарантирует**, что `aclose` успеет взять lock до того, как `ensure_connected` попытается его взять. В разных версиях Python или при разной нагрузке порядок может отличаться, что сделает тест фaky.

**Решение:** Использовать `asyncio.Event` или другой механизм явной синхронизации, чтобы гарантировать порядок захвата lock'ов. Например:
```python
lock_acquired = asyncio.Event()
# В aclose: lock_acquired.set() после захвата lock
# В тесте: await lock_acquired.wait() перед созданием reconnect_task
```

### Concerns (Замечания)

#### 5. **Task 5: Тест использует `TOLERANCE = 1.0e-3`, но не проверяет, что это правильная толерантность SketchUp**

В Task 5 (строка плана 634) тест определяет:
```ruby
TOLERANCE = 1.0e-3
```

и проверяет:
```ruby
raise ArgumentError, "degenerate face: duplicate points" if d < TOLERANCE
```

**Замечание:** План утверждает, что SketchUp отвергает точки ближе `1e-3` дюйма, но это не проверено эмпирически. Если реальная толерантность SketchUp отличается (например, `1e-6` или `1e-2`), тест будет давать ложные результаты.

**Рекомендация:** Добавить комментарий с ссылкой на источник (документация, эмпирический тест) или использовать более консервативную толерантность (например, `1e-6`).

#### 6. **Task 9: Smoke-матрица не проверяет idempotency нового absolute position**

В Task 9 (строки плана 1623-1643) smoke-шаг 21 проверяет:
```python
moved = parse(await call(conn, "transform_component",
                         id=b_tail, position=[800, 0, 0]))
assert abs(moved["bbox_mm"]["min"][0] - 800) < 0.5
```

**Замечание:** План утверждает, что новая семантика `position` — **absolute** и **idempotent** (повторный вызов с тем же значением не меняет позицию). Но smoke **не проверяет** idempotency — только один вызов.

**Рекомендация:** Добавить повторный вызов `transform_component` с тем же `position=[800, 0, 0]` и проверить, что bbox не изменился:
```python
moved2 = parse(await call(conn, "transform_component",
                          id=b_tail, position=[800, 0, 0]))
assert abs(moved2["bbox_mm"]["min"][0] - moved["bbox_mm"]["min"][0]) < 0.01, \
    "absolute position must be idempotent"
```

#### 7. **Task 4: Source-guard проверяет literals, но не семантику**

В Task 4 (строки плана 348-374) source-guard'ы проверяют:
```ruby
/test_boolean_difference_receiver_is_tool_copy/
/test_edge_ops_subtract_receiver_is_cutter/
/test_joints_subtract_call_sites_keep_cutter_first/
```

**Замечание:** Это **синтаксические** проверки (grep по literals), а не семантические. Если кто-то переименует переменную (например, `tool_copy` → `tool_group`), тест упадет, даже если семантика правильная. И наоборот, если кто-то добавит обертку, которая меняет порядок, но сохраняет literals, тест пройдет.

**Рекомендация:** Source-guard'ы — хорошая первая линия защиты, но они **не заменяют** поведенческий тест `test_boolean_direction.rb`. План это понимает (оба теста добавляются), но стоит явно отметить, что source-guard'ы — дополнение, а не замена.

#### 8. **Task 2: CI workflow не тестирует Python 3.10**

В Task 2 (строки плана 132-139) CI matrix:
```yaml
python-version: ['3.11', '3.12', '3.13']
```

**Замечание:** `pyproject.toml` указывает `requires-python = ">=3.10"`, но CI не тестирует Python 3.10. Если код использует фичи 3.11+ (например, новый синтаксис `match`), это обнаружится только у пользователей.

**Рекомендация:** Добавить `'3.10'` в matrix, или поднять `requires-python` до `>=3.11` (если это решение принято).

### Suggestions (Предложения)

#### 9. **Task 6: Добавить миграционный гайд для breaking change**

План (строка 784) признает, что изменение семантики `position` — **breaking change**. Но нет миграционного гайда для пользователей.

**Предложение:** В `tools.py` докстринг (строки плана 904-915) добавить пример миграции:
```python
"""
...
Migration from relative semantics (pre-0.3.0):
  Old: position=[100, 0, 0] moved entity by +100mm on X
  New: position=[100, 0, 0] moves entity so bbox-min.x = 100mm
  
  To migrate: replace relative offsets with absolute targets.
  If you need relative movement, compute the target as:
    new_position = [current_bbox_min.x + delta_x, ...]
"""
```

#### 10. **Task 7: `add_parent_frame_prototype` можно упростить**

В Task 7 (строки плана 1207-1218) хелпер:
```ruby
def self.add_parent_frame_prototype(board)
  prot = MCPforSketchUp::Helpers::Entities.active_model!.active_entities.add_group
  begin
    yield prot
    prot.transform!(board.transformation.inverse)
    if prot.valid?
      E.entity_collection(board).add_instance(prot.definition, prot.transformation)
    end
  ensure
    prot.erase! if prot && prot.valid?
  end
end
```

**Замечание:** `prot.transform!(board.transformation.inverse)` применяется **после** yield, но геометрия строится в world-frame координатах (от `board.bounds.center`). Если внутри yield используются `board.bounds.center` (parent-frame), то `transform!` должен применяться **до** добавления геометрии, а не после.

**Проверка:** Смотрю на новый `carve_tails` (план 1231-1241):
```ruby
add_parent_frame_prototype(board) do |prot|
  num_tails.times do |i|
    tx = cx - width/2 + tail_w * 2 * i  # cx = c.x + ox, где c = board.bounds.center (PARENT frame)
    face = prot.entities.add_face(...)  # Координаты в prot (world-frame scratch group)
  end
end
```

Координаты `[tx, cy, cz]` — в **world-frame** (от `board.bounds.center` в parent-frame). `prot` создается в `active_model!.active_entities` (world-frame). Затем `prot.transform!(board.transformation.inverse)` — но это **не нужно**, если геометрия уже в world-frame!

**Проблема:** План смешивает два подхода:
1. Строить в world-frame → instance в board-local (с `board.transformation.inverse`)
2. Строить в board-local координатах

**Рекомендация:** Пересмотреть математику. Если геометрия строится от `board.bounds.center` (parent-frame), то:
- Либо строить в world-frame scratch group, потом instance в board с `board.transformation.inverse` (правильно)
- Либо строить в board-local координатах (но тогда `board.bounds.center` нужно пересчитать в board-local)

План использует подход 1, но комментарий (строки плана 1199-1206) нечеткий. Стоит добавить диаграмму или пример с координатами.

#### 11. **Общее: Добавить changelog entry**

План не упоминает обновление changelog. Если проект использует `CHANGELOG.md` или GitHub Releases, стоит добавить запись о breaking change в `transform_component.position`.

### Questions (Вопросы автору)

1. **Task 3:** Ruby private-методы должны быть определены до использования. Как вы планируете решить эту проблему — переместить `with_eval_enabled` перед тестами или сделать его public/class method?

2. **Task 7:** Математика `add_parent_frame_prototype` не совсем ясна. Если геометрия строится от `board.bounds.center` (parent-frame), то зачем применять `board.transformation.inverse` после yield? Не должно ли быть: строить в world-frame → instance в board с inverse transform? Или я неправильно понимаю план?

3. **Task 8:** Тест `test_aclose_cannot_clobber_concurrent_reconnect` использует `asyncio.sleep(0)` для синхронизации. Это может быть недетерминированным. Планируете ли вы использовать более надежный механизм синхронизации (например, `asyncio.Event`)?

4. **Task 6:** Source-guard тест `test_transform_component_translates_via_position_delta` использует regex, который может сломаться при изменении порядка методов. Рассматривали ли вы более надежный парсинг (например, по отступам) или упрощенную проверку (наличие `position_delta(` в файле)?

5. **Task 9:** Smoke-матрица не проверяет idempotency нового absolute position. Планируете ли вы добавить проверку, что повторный вызов `transform_component` с тем же `position` не меняет bbox?

6. **Общее:** Проект использует `CHANGELOG.md` или GitHub Releases для релизных заметок? Если да, стоит ли добавить запись о breaking change в `transform_component.position`?

---

### Резюме

План в целом **хорошо структурирован** и покрывает критические баги. Основные проблемы:

1. **Технические ошибки:** private helper после использования (Task 3), потенциальная недетерминированность async-теста (Task 8), непонятная математика в `add_parent_frame_prototype` (Task 7).

2. **Недостатки покрытия:** smoke не проверяет idempotency (Task 9), CI не тестирует Python 3.10 (Task 2).

3. **Хрупкость:** source-guard тесты (Task 4, 6) могут сломаться при рефакторинге.

**Рекомендация:** Исправить критические проблемы (1-4) перед реализацией, добавить предложения (5-11) по желанию.


---

## ext-claude-executor (deepseek/v4-pro)

Теперь у меня достаточно информации для полного ревью. Ниже — мой разбор плана.

---

## Critical Issues

### 1. Task 4 (T-10): Source-guard'ы НЕ покрывают тело `subtract_tracked` — дыра в тестовом покрытии самого опасного инварианта

План добавляет 4 source-guard паттерна в `test_operation_names.rb` для call-sites `subtract_tracked(cutter, ...)` в `joints.rb` (строки 201, 319, 351, 377). Но **ни один guard не проверяет тело самого `subtract_tracked`** (строка 149 `joints.rb`: `result = cutter.subtract(target)`). Если кто-то «починит» порядок внутри `subtract_tracked` на `target.subtract(cutter)`, все 4 source-guard'а останутся зелёными (call-sites не меняются), а поведенческий тест `test_boolean_direction.rb` тестирует `Operations.boolean_operation` (прямой `cutter.subtract(target)` — НЕ через `subtract_tracked`). Тесты `test_joints_frame_compensation.rb` проверяют только `refute_empty self.class.subtract_log` (не проверяют receiver/argument в логе).

**Риск:** единственный guard для `cutter.subtract(target)` в operations.rb (`test_edge_ops_subtract_receiver_is_cutter`, строка 190 `result = cutter.subtract(entity)`) может остаться зелёным, а `subtract_tracked` в joints.rb — «починен» втихую.

**Исправление:** добавить в `test_operation_names.rb` пятый guard-паттерн:
```ruby
def test_subtract_tracked_body_keeps_cutter_as_receiver
  src = source(HANDLERS, "joints.rb")
  assert_match(/result = cutter\.subtract\(target\)/, src,
    "subtract_tracked must call cutter.subtract(target), NOT target.subtract(cutter)")
end
```

### 2. Task 5 (T-02): build_sphere — неверный порядок вершин треугольника на южном полюсе

План предписывает для южного полюса (`lat_i == segments - 1`):
```ruby
group.entities.add_face(points[i1], points[i2], points[i4])
```

Индексы:
- `i1 = (segments-1)*(segments+1) + lon_i` — точка на предпоследней широте, столбец `lon_i`
- `i2 = i1 + 1` — точка на предпоследней широте, столбец `lon_i+1`
- `i4 = (segments)*(segments+1) + lon_i + 1` — ЮЖНЫЙ ПОЛЮС

Но `points[i4]` при `lat_i = segments-1` — это `points[(segments-1)*(segments+1) + lon_i + 1 + segments + 1]` = `points[segments*(segments+1) + lon_i + 1]`. Это действительно южный полюс (lat=segments, любое lon). ✓

Но порядок обхода: `(i1, i2, i4)` — две точки на одном кольце + полюс. Это корректный треугольник (все три точки различны). Направление normal'и грани зависит от порядка вершин: `(i1, i2, i4)` против `(i1, i4, i2)`. SketchUp автоматически ориентирует грань; если normal смотрит внутрь сферы, `pushpull` (которого для сферы нет — сфера строится из граней БЕЗ pushpull) не важен. Но для manifold-сетки **направление normal'и ВСЕХ граней должно быть наружу**. Если треугольник на южном полюсе ориентирован иначе, чем соседние квады, сетка может оказаться non-manifold (рёбра с 1 или 3 соседями вместо 2).

**Проверка:** manifold-тест в `test_geometry_builders.rb` (`test_sphere_face_mesh_is_manifold`) проверяет, что каждое ребро разделяют ровно 2 грани. Если порядок вершин треугольника не консистентен с соседними гранями, тест должен это поймать. **Это НЕ баг фикса, но это критическая зависимость от manifold-теста — если тест несовершенен, баг пройдёт.** Удостовериться, что manifold-тест реально ловит flipped normal, можно адверсариально: инвертировать один треугольник и прогнать тест.

**Рекомендация:** добавить в план явный шаг адверсариальной проверки manifold-теста.

### 3. Task 7 (T-03): `carve_tails`, `carve_pins`, `carve_board1_fingers` — теряется прямая принадлежность геометрии доске: добавляется лишний уровень вложенности

Старый код кладёт геометрию прямо в `board.entities` (entities доски). Новый код через `add_parent_frame_prototype` создаёт ComponentInstance (через `add_instance(prot.definition, prot.transformation)`), который содержит геометрию внутри себя. Результат:

- **Старый путь:** `board.entities → [tail_group]` (геометрия на поверхности доски)
- **Новый путь:** `board.entities → [ComponentInstance] → definition.entities → [tail_geometry]`

Это **семантическое изменение структуры модели**. Для `carve_tails` (которая добавляет, а не вырезает геометрию) это может быть неожиданным для пользователя: хвосты теперь вложены в ComponentInstance внутри доски, а не являются прямой частью доски. То же для `carve_pins` и `carve_board1_fingers`.

План ссылается на «паттерн `place_tenon`» как образец. `place_tenon` ДЕЙСТВИТЕЛЬНО использует `add_instance`, потому что tenon — это ВЫСТУПАЮЩАЯ геометрия, которая логически является отдельной частью. Но `carve_tails` и `carve_board1_fingers` вырезают материал ИЗ доски — результат subtract должен быть частью той же доски, без дополнительного уровня инстанса.

**Для `carve_pins` это корректно:** `place_tenon`-паттерн — вырезаем материал из доски через subtract внутри scratch-группы, результат subtract — новая группа внутри scratch, потом `add_instance` переносит результат в доску. Результат subtract УЖЕ является новой группой (не частью исходной доски), так что инстансинг её внутрь доски — правильная операция.

**Для `carve_tails` это НЕ вполне корректно:** `carve_tails` НЕ делает subtract — она ДОБАВЛЯЕТ геометрию (хвосты) к доске. В старом коде хвосты добавлялись прямо в `board.entities`. В новом коде через `add_parent_frame_prototype` они заворачиваются в ComponentInstance. Это меняет структуру: теперь хвосты — отдельный инстанс внутри доски, а не «родная» геометрия доски.

**Практическое следствие:** пользователь, дважды кликнувший на доску чтобы редактировать её геометрию, НЕ увидит хвосты — они внутри ComponentInstance, нужно проваливаться ещё на уровень. При этом `describe_entity(board)` вернёт bbox доски (который включает инстанс), так что внешне всё выглядит правильно.

Это архитектурное решение, не баг. Но план не обсуждает этот компромисс. Стоит явно зафиксировать в комментарии к `carve_tails`, что `place_tenon`-паттерн намеренно используется и для additive-геометрии ради консистентности frame-компенсации.

### 4. Task 6 (T-04): `test_transform_absolute.rb` — source-guard regex полагается на индентацию и следующий метод

```ruby
body = src[/def self\.transform_component.*?(?=\n      def self\.)/m]
```

После фикса Task 6, СЛЕДУЮЩИЙ за `transform_component` метод — `position_delta` (в секции private builders). Оба имеют отступ 6 пробелов. Regex использует `\n      def self\.` (6 пробелов + `def self.`). Это **зависит от индентации** — если кто-то отформатирует файл иначе (например, 4 пробела или 8), guard молча сломается (regex не найдёт тело метода → `refute_nil body` упадёт).

Это не критично для данного плана, но хрупкость guard'а стоит отметить. Более надёжный подход: грепать весь файл по конкретным паттернам, без привязки к методу.

### 5. Task 8 (T-08): `close_connection()` теряет защиту от гонки get/close

```python
async def close_connection() -> None:
    global _connection
    if _connection is not None:
        await _connection.aclose()
        _connection = None
```

После `aclose()` lock отпущен, но `_connection = None` — без модульного `_get_connection_lock`. Параллельный `get_connection()` может:
1. Увидеть `_connection is not None` (ещё не обнулён)
2. Вернуть singleton с `_writer = None`
3. Потом `_connection = None`

**Следствие:** два параллельных `get_connection()` после `close_connection()` могут создать ДВА разных singleton'а с двумя открытыми сокетами к SketchUp. Это не катастрофа (один умрёт по таймауту/keepalive, SketchUp multi-client это поддерживает), но это регрессия относительно ДОкументированного инварианта «singleton».

**Исправление:** взять `_get_connection_lock` в `close_connection()`:
```python
async def close_connection() -> None:
    global _connection
    async with _get_connection_lock:
        if _connection is not None:
            await _connection.aclose()
            _connection = None
```

---

## Concerns

### 6. Task 3 (T-01): `SystemStackError`-тест и shared-process test suite

```ruby
"f = nil; f = -> { f.call }; f.call"
```

В MRI стек очищается при обработке `SystemStackError`. Но в альтернативных Ruby (JRuby, TruffleRuby) поведение может отличаться. План заявляет поддержку Ruby 3.2 (MRI), так что это низкий риск. Однако если CI когда-либо переедет на JRuby — тест может уронить весь процесс.

### 7. Task 3 (T-01): `define_singleton_method(:get_version, original)` — подмена module-метода на singleton-метод

```ruby
sys = MCPforSketchUp::Handlers::System
original = sys.method(:get_version)
sys.define_singleton_method(:get_version) { |_params| raise ScriptError, "handler exploded" }
...
sys.define_singleton_method(:get_version, original)
```

После restore `original` — это `Method`-объект, который становится телом singleton-метода. Но оригинальный `get_version` был module-методом (определён через `def self.get_version`). После restore это **singleton-метод на модуле**, не module-метод. Ruby разрешает singleton-методы раньше module-методов, так что вызовы работают. Но метапрограмминг (`.method(:get_version).owner`) вернёт singleton class вместо модуля. Для последующих тестов в том же процессе это не должно быть проблемой (никто не проверяет `owner`), но это семантическая деформация, которую стоит как минимум отметить комментарием.

### 8. Task 3 (T-01): `test_eval_ruby_runtime_error_message_includes_class` проверяет `RuntimeError: boom`, но НЕ `StandardError`

Утверждение `assert_match(/RuntimeError: boom/, resp["error"]["message"])` проверяет конкретный класс `RuntimeError`. Если `raise 'boom'` неожиданно поднимет НЕ `RuntimeError` (что маловероятно), тест упадёт. Это нормально для детерминированного теста, но стоит отметить: `raise "string"` в Ruby создаёт `RuntimeError` — это гарантировано спецификацией.

### 9. Task 5 (T-02): `test_geometry_builders.rb` — hardcoded `TOLERANCE = 1.0e-3` против `SEGMENTS = 16`

Плановая `TOLERANCE` для `FaceCollector` — `1.0e-3` дюйма, что примерно соответствует точности SketchUp. При `SEGMENTS = 16`, соседние точки на одном кольце отстоят друг от друга на `2π * radius / 16`. Для радиуса 2 дюйма (сфера d=4") это ≈ 0.785 дюйма — значительно больше tolerance. Так что ложных срабатываний degenerate detection быть не должно. ✓

Но при УВЕЛИЧЕНИИ segments до больших значений (например, 128) расстояние между точками на полюсном кольце может упасть ниже tolerance. Для segments=16 это не проблема. ✓

### 10. Task 7 (T-03): teardown восстановление `active_model!` — thread-safety не нужна, но стоит отметить

```ruby
def teardown
    EH.define_singleton_method(:active_model!, @saved_active_model)
end
```

SketchUp однопоточен, тесты тоже однопоточны. Проблемы нет. Но сам паттерн `define_singleton_method` для restore (вместо instance_variable) используется консистентно с setup. ✓

### 11. Task 9 (T-24): `time.monotonic()` — нет импорта в текущем smoke_check.py

План добавляет `import time` (Step 1). ✓

### 12. Task 7 (T-03): `carve_tails` в новом коде — потеряна валидация?

Старый `carve_tails` не имел `rescue` или `assert`. Новый — тоже. Но теперь геометрия строится через `add_parent_frame_prototype`, которая имеет `ensure prot.erase!`. Если `pushpull` внутри блока raise'ит, `prot.erase!` всё равно вызывается (сборка мусора). ✓

### 13. Порядок исполнения задач (4→7, 6→9) и атомарность коммитов

План предписывает: Task 4 → Task 7, и Task 6 → Task 9. Это логично: source-guard'ы должны быть закоммичены до переписывания joints.rb; новая семантика position — до smoke-шагов с ней. Но план НЕ предписывает атомарность ДРУГИХ зависимостей: например, Task 3 (eval_ruby syntax error) и Task 9 (smoke-шаг с syntax error). Task 3 коммитится раньше, так что когда Task 9 дописывает smoke-шаг, фикс уже на месте. ✓

---

## Suggestions

### 14. Task 4: адверсариальная проверка manifold-теста сферы

После Task 5, инвертировать ОДИН треугольник в `build_sphere` и убедиться, что `test_sphere_face_mesh_is_manifold` его ловит. Без этого manifold-тест — оракул без проверки оракула.

### 15. Task 5: тест `test_geometry_builders.rb` — `FakeFace` и `FakeGroup` можно вынести в общий test-хелпер

Три новых тестовых файла (`test_boolean_direction.rb`, `test_geometry_builders.rb`, `test_joints_frame_compensation.rb`) каждый определяет свои фейковые классы с дублированием: `FakePoint`, `FakeBounds`, `FakeGroup`, `FakeCollection`. Стоит рассмотреть общий `test/fake_sketchup.rb` (но конвенция проекта — stdlib-only; это сознательное решение, не требующее правки в этом плане).

### 16. Task 8: `ensure_connected` и `_send_once` — дублирование логики connect

```python
# _send_once (уже существует):
if self._writer is None or self._writer.is_closing():
    await self._connect_or_raise()

# ensure_connected (новый):
if self._writer is None or self._writer.is_closing():
    await self._connect_or_raise()
```

Проверка дублируется. Можно сделать `ensure_connected` единственным местом, а `_send_once` пусть зовёт `await self.ensure_connected()`. Но `ensure_connected` берёт `self._lock`, а `_send_once` УЖЕ под `self._lock` — будет дедлок (`asyncio.Lock` не реентерабелен). Так что дублирование оправдано. Стоит добавить комментарий WHY.

### 17. Task 10: автообновление счётчиков в `CLAUDE.md`

Вместо ручного grep + replace, можно добавить в `run_all.rb` вывод в формате, который `sed`-скрипт сможет распарсить. Но это за рамками данного плана.

### 18. `README.md`: упоминание `22-step` — есть ли?

План говорит: «Проверить README: `grep -n "22" README.md` — если есть упоминание шагов smoke, обновить аналогично». В текущем README нет упоминания «22-step» (я прочитал первые 30 строк). Но grep лучше сделать во время исполнения.

---

## Questions

### 19. Task 4 — `test_boolean_direction.rb`: `require_relative` для `helpers/geometry`

Файл требует `helpers/geometry` и `handlers/geometry`. `handlers/geometry` внутри себя делает `G = MCPforSketchUp::Helpers::Geometry`. Модуль `Helpers::Geometry` определён как `module Geometry; end` в тесте. Но `helpers/geometry.rb` определяет методы типа `make_box`, `circle_points` — они ОПРЕДЕЛЯЮТСЯ при `require_relative`. Но сам модуль `MCPforSketchUp::Helpers::Geometry` УЖЕ существует (создан тестом как пустой). `helpers/geometry.rb` откроет существующий модуль и добавит методы — это нормально.

**Вопрос:** зачем тесту `boolean_operation` вообще `helpers/geometry`? `Operations.boolean_operation` вызывает `Geometry.describe_entity`, а тот определён в `handlers/geometry.rb`, не в `helpers/geometry.rb`. `helpers/geometry.rb` содержит `make_box` и `circle_points` — они не используются в тесте. Лишний require — не ошибка, но неопрятно. Впрочем, `describe_entity` использует `U.inch_to_mm` (из `helpers/units`), который уже заrequir'ен. Не критично.

### 20. Task 7 — smoke-шаг 21: почему bbox-ассерт для `pin` тоже проверяет X?

```python
for key in ("tail", "pin"):
    bb = dv[key]["bbox_mm"]
    assert bb["min"][0] >= 800 - 15 - 1 and bb["max"][0] <= 920 + 15 + 1
```

Обе доски (tail и pin) созданы у X=800 с шириной 120 мм (X: 800..920). Dovetail соединяет их по грани, перпендикулярной X (tail на X=800, pin на X=800, Y смещён). Так что bbox по X для ОБЕИХ досок должен остаться в пределах 800±depth. Но pin-доска находится на Y=120 (смещена по Y, не по X), так что её X-bbox тоже 800..920. Ассерт корректен. ✓

### 21. Task 8 — `test_ensure_connected_raises_connection_error_when_refused`: monkeypatch не чистит `_connection` после теста?

```python
monkeypatch.setattr(conn_module, "_connection", None)
...
conn = await conn_module.get_connection()
with pytest.raises(ConnectionError) as exc_info:
    await conn.ensure_connected()
...
monkeypatch.setattr(conn_module, "_connection", None)
```

После теста `_connection` не None (мы создали singleton через `get_connection()`). `monkeypatch.setattr` в конце восстанавливает оригинальное значение (которое было None в начале теста). Но `get_connection()` уже создал объект, на который может ссылаться другой тест... нет, потому что `_connection` — module-level переменная, и monkeypatch её контролирует. После выхода из теста monkeypatch откатывает `_connection` к исходному значению (None, если предыдущий тест чистил). ✓

---

## Итоговая оценка

План **качественный и детальный**. Все приведённые фрагменты кода (тесты и фиксы) синтаксически корректны, якоря строк соответствуют реальным файлам, логика фиксов правильная. План заслуживает **approval с 5 критическими замечаниями** (1 обязательное исправление + 4 требующих решения):

| # | Severity | Что | Действие |
|---|----------|-----|----------|
| 1 | **Critical** | Тело `subtract_tracked` не покрыто source-guard'ами | Добавить guard в Task 4 |
| 5 | **Critical** | `close_connection()` — гонка get/close без `_get_connection_lock` | Взять lock в `close_connection()` |
| 3 | **Critical** | `carve_tails` — лишний уровень ComponentInstance для additive-геометрии | Задокументировать компромисс |
| 2 | **Critical** | Порядок вершин треугольника южного полюса зависит от manifold-теста | Адверсариально проверить manifold-тест |
| 4 | **Critical** | Source-guard regex хрупок к переформатированию | Принять к сведению, не блокер |


---

## ext-claude-executor (ollama/kimi)

Ниже — критический обзор плана. Я сверил предписанные якоря строк с актуальным рабочим деревом ветки `fix/deep-review-p1`; большинство якорей корректны, но есть логические дыры и риски, которые стоит закрыть до начала реализации.

---

## Critical Issues

### 1. T-04: абсолютная `position` несовместима с одновременным `rotation`/`scale`
План сохраняет порядок применения трансформаций в `transform_component` (`mcp_for_sketchup/mcp_for_sketchup/handlers/geometry.rb:80-109`) неизменным: сначала `translation`, потом `rotation`, потом `scale`. При этом докстринг Python-обёртки (`src/sketchup_mcp/tools.py:119-135`) и промпт (`src/sketchup_mcp/prompts.py`) обещают, что *«bbox-min окажется ровно в заданной точке»*. Если одним вызовом передать и `position=[200,0,0]`, и `rotation`, и/или `scale`, реальный bbox-min не будет равен `position`, потому что поворот/масштаб изменят bbox после того, как абсолютный сдвиг уже применён.  
**Это реальная бага в плане**, а не просто недостаток документации. Нужно либо:
- вычислять `position_delta` от целевого bbox-min **после** применения rotation/scale, либо
- применять translation **последним**, либо
- явно документировать, что при комбинированном вызове `position` — якорь только для чистого переноса.

### 2. T-08: `aclose()` удерживает `conn._lock` на время `wait_closed()`
В новом `aclose()` (`src/sketchup_mcp/connection.py`) весь `disconnect()` выполняется под `self._lock`, включая `await self._writer.wait_closed()` (до 5 с по `_DISCONNECT_TIMEOUT`). Это блокирует все конкурентные `send_command` на время graceful-закрытия сокета. Если MCP-клиент держит таймаут на tool-call, это может выглядеть как зависание. Сериализация нужна, но удерживать lock на I/O-таймаут избыточно — лучше удерживать lock только для swap-а `_reader`/`_writer` в `None`, а `wait_closed()` делать вне lock.

### 3. T-09: CI-матрица Python не покрывает 3.10
`pyproject.toml:6` декларирует `requires-python = ">=3.10"`, а в `.github/workflows/test.yml` (план) матрица только `['3.11', '3.12', '3.13']`. Поддержка 3.10 не проверяется автоматически, хотя classifier и требование о ней есть.

### 4. T-03: тест и smoke проверяют только трансляцию, не поворот
`test/test_joints_frame_compensation.rb` строит `FakeTranslation` только со сдвигом, а `examples/smoke_check.py` step 21 использует доски, сдвинутые только по X. Хелпер `add_parent_frame_prototype` математически компенсирует полную трансформацию, но геометрия джойнта строится в parent-frame осях — для повёрнутой доски паз останется мировой ориентации, а не локальной. Это может быть отдельным багом, который тесты не ловят. Нужен хотя бы один тест с повёрнутой доской.

### 5. T-09: smoke-шаг 21 не проверяет, что шип и гнездо реально соприкасаются
Доски разнесены по Y (`position=[800,0,0]` и `[800,120,0]`). Джойнт режет каждую доску в своей локальной области, но шип и гнездо не пересекаются (между ними зазор ~120 мм). Ассерты проверяют только то, что bbox каждой доски не улетел — это слабая проверка T-03. Нужно либо придвинуть доски друг к другу, либо добавить проверку, что результат `create_dovetail` имеет общий bbox/пересечение.

---

## Concerns

### 6. T-08: имя `ensure_connected`/`aclose` vs публичного API
`get_connection()` теперь не коннектит, появляется `ensure_connected()`. Все внутренние вызывающие (`app.py`, `tools.py`, тесты) обновлены, но это меняет неявный контракт, который могут использовать внешние скрипты (`examples/smoke_check.py` использует прямой `conn.connect()` и не затронут). Стоит явно задокументировать: `get_connection` — только singleton, `ensure_connected` — ленивый/явный коннект.

### 7. T-03: `add_parent_frame_prototype` теряет геометрию при ошибке `add_instance`
В хелпере:
```ruby
if prot.valid?
  E.entity_collection(board).add_instance(prot.definition, prot.transformation)
end
```
Если `add_instance` бросит исключение, `ensure prot.erase!` сработает и прототип с геометрией исчезнет. Внутри одной `start_operation` это маловероятно, но стоит либо перенести `erase!` в ensure после успешного `add_instance`, либо явно комментировать, что `add_instance` не должен падать.

### 8. T-05: нет нижней границы `segments` для сферы
`V.optional_int_positive` позволяет `segments=1`. При `segments=1` в цикле будет только `lat_i=0` (и оно же `segments-1`), сработает только северная ветка, и сфера превратится в полусферу/клин. Стоит либо валидировать `segments >= 3` в `create_component`, либо в `build_sphere`.

### 9. T-04: breaking change без изменения handshake-диапазонов
План правильно отмечает в «После плана», что при релизе стоит поднять MIN-floor'ы, но сам план версии не бампает. Поскольку семантика `position` меняется, старый Python-клиент с новым Ruby-сервером будет молча смещать объекты. Это риск, особенно если `.rbz` обновится раньше PyPI. Возможно, стоит уже сейчас обновить `MIN_RUBY`/`MIN_PYTHON` или хотя бы добавить предупреждение в CHANGELOG/CLAUDE.md.

### 10. Source-guard'ы на regex — хрупкие
`test_transform_component_translates_via_position_delta` и guard'ы в `test_operation_names.rb` парсят исходники регулярками. Это допустимо как «пин», но любой рефакторинг форматирования (перенос строк, переименование локальной переменной) сломает тест, даже если семантика верна. Стоит сопроводить их комментарием, что guard'и — именно про буквальный вид кода.

### 11. Ruby-сюта: риск загрязнения процесса
`test_joints_frame_compensation.rb` определяет внутри тестового класса `FakeGroup`, `FakeBoard`, `FakeTranslation`. Конфликтов с существующими константами нет (проверил `grep -R "class Fake" test/`). Однако `TestJointsFrameCompensation.subtract_log` — класс-переменная, очищается в `setup`; если какой-то другой тест в будущем зайдёт в `Joints.subtract_tracked`, лог будет общим. Сейчас это не проблема, но стоит быть аккуратным.

### 12. T-03: `carve_board2_slots` не покрыт фрейм-компенсацией
План заявляет, что `carve_board2_slots` уже корректен, но тест на него не добавлен. Он строит cutter в `current.parent.entities` и использует `board.bounds.center` (parent-frame), что работает для сдвинутых досок, но для повёрнутых/вложенных может иметь те же проблемы. Добавление теста на `carve_board2_slots` с translated board устранил бы слепое пятно.

---

## Suggestions

### 13. T-04: применять translation последним или пересчитывать delta после rotation/scale
Рекомендую в `transform_component` сделать два прохода:
1. Применить `rotation` и `scale` (относительно центра bbox).
2. Вычислить `delta = position_delta(entity.bounds.min, position)` уже от нового bbox-min.
3. Применить translation.

Или, если порядок должен оставаться как в плане, явно описать в докстринге, что `position` — pre-transform anchor.

### 14. Добавить Python 3.10 в CI
В `.github/workflows/test.yml` добавить `'3.10'` в матрицу. Если какая-то зависимость не работает на 3.10, лучше узнать об этом сразу.

### 15. T-03: усилить smoke-шаг 21
- Расположить `pin` board вплотную к `tail` board (например, `position=[800, 100, 0]`, чтобы грани касались).
- Добавить ассерт, что bbox результата (`dv["tail"]["bbox_mm"]` и `dv["pin"]["bbox_mm"]`) имеют пересечение по Y.

### 16. T-05: валидировать `segments >= 3` в `create_component`
Это однострочная правка в `geometry.rb` и защитит от вырожденных сфер.

### 17. T-08: разделить lock и I/O-wait
В `aclose()` удерживать lock только для установки `_reader`/`_writer` в `None`, а `await disconnect()` выполнять снаружи (предварительно отменив/дождавшись in-flight roundtrip). Это сохранит сериализацию состояния и не будет блокировать отправщиков на 5 секунд.

---

## Questions

1. **T-04, комбинированный вызов:** каково ожидаемое поведение, когда в `transform_component` одновременно подаются `position`, `rotation` и/или `scale`? Должен ли финальный bbox-min совпадать с `position` после всех трансформаций? Если да, план нужно исправить.
2. **T-08, блокировка при закрытии:** приемлемо ли, что `aclose()` держит `conn._lock` на всё время `wait_closed()`? Не сломает ли это таймауты MCP-клиента при shutdown?
3. **T-03, повороты:** ожидается ли, что джойнт ориентирован по мировым осям даже для повёрнутой доски, или по локальным осям доски? Текущий хелпер компенсирует только положение; ориентация остаётся parent-frame.
4. **T-05, `segments=1`:** нужна ли явная валидация `segments >= 3` для сферы?
5. **Версионная совместимость:** хотя план не бампает версии, семантика `position` — breaking change. Не стоит ли уже в этой ветке обновить `MIN_RUBY`/`MIN_PYTHON` или добавить runtime-warning, чтобы старый клиент не получал молчаливые смещения?
6. **T-09, smoke:** достаточно ли для definition of done T-03 проверять, что bbox досок не улетел, или нужен реальный mechanical check (шип входит в гнездо)?

---

### Резюме по «критичности плана»

План в целом технически корректен: якоря строк совпадают с файлами, предписанные тесты действительно будут падать до фикса и зеленеть после, порядок задач обоснован. Однако перед имплементацией **обязательно нужно устранить T-04 combined-transform** и **пересмотреть T-08 lock-held-during-close**. Остальное — вопросы расширения покрытия и документации.


---

## ext-claude-executor (ollama/minimax)

OK, `require_relative` — гарантирует однократную загрузку. **OK**.

### C7. Тест `test_difference_receiver_is_tool_copy_argument_is_target_copy` ловит `find` через `:subtract` — но union/intersection тоже могут иметь `:subtract` в логе?

Нет, `FakeSolid` имеет отдельные методы `union`, `subtract`, `intersect`, и каждый логирует свой символ. **OK**.

## Concerns

### K1. `evaluate_connected` + `get_connection` + lifespan = потенциальный race на MCP startup

Task 8 Step 4: lifespan вызывает `get_connection` (быстро, не блокирует) + `ensure_connected` (медленно, делает TCP-connect + handshake). **НО:** FastMCP создаёт `mcp` на уровне модуля, и lifespan стартует при первом MCP-запросе. Если клиент (Claude Desktop) присылает параллельно 2 tool-call'а до завершения eager-connect — оба стартуют, оба зовут `get_connection()` (получают тот же singleton), оба зовут `ensure_connected()` — и оба берут `self._lock`, второй ждёт. **OK** — это не race, `ensure_connected` сериализован.

**НО:** `_get_connection_lock` (модульный) защищает только создание singleton, а не вызов `ensure_connected`. То есть два cold-start caller'а:
1. `t1: get_connection()` (создаёт singleton) → `t1: ensure_connected()` (берёт `self._lock`, коннектит).
2. `t2: get_connection()` (получает тот же singleton, **под модульным lock'ом**) → `t2: ensure_connected()` (ждёт `self._lock`).

Когда `t1` отпустит `self._lock` после handshake, `t2` возьмёт `self._lock` и увидит `self._writer is not None and not is_closing()` → **skip connect** → вернёт. **OK** — idempotent.

Однако: план в Task 8 Step 3b убирает из `get_connection` ветку `if _connection._writer is None or _connection._writer.is_closing()`. То есть в `get_connection` теперь **не** делается health-check. Если после `aclose()` `_connection = None` (в `close_connection`) — следующий `get_connection()` создаст новый. **OK**.

**Но:** в `close_connection` план Step 3c:
```python
async def close_connection() -> None:
    global _connection
    if _connection is not None:
        await _connection.aclose()
        _connection = None
```

Между `await _connection.aclose()` (которая под `self._lock` зануляет `_reader/_writer`) и `_connection = None` — **есть await-точка**. Другой caller может взять `_get_connection_lock` И увидеть `_connection` ещё не None, но `self._writer is None`. С новым `get_connection` — **не** вызовет `connect`, просто вернёт. **OK**.

### K2. `tools.py:45-46` — замена убирает `may raise ConnectionError` комментарий, но `ConnectionError` всё ещё может подняться

С новой логикой: `get_connection()` НЕ поднимает ConnectionError. `send_command` под `self._lock` лениво коннектит и может поднять ConnectionError через `_connect_or_raise`. Старый комментарий `# may raise ConnectionError` стоял на строке 45. План заменяет на:
```python
# ConnectionError при недоступном SketchUp поднимает send_command
# (ленивый connect под conn._lock, T-08), не get_connection — callers
# ловят её как раньше.
```

Корректно. **OK**.

### K3. `apply_rotation` после absolute `position` — порядок трансформаций имеет значение

Сейчас (старый код): position → rotation → scale. С новой семантикой position = absolute bbox-min. После position-трансформации, `entity.bounds.center` сместился → rotation вокруг нового center → scale вокруг нового center. **Это точно такая же семантика, как раньше** (относительно текущего center). **OK**.

### K4. Тест `test_dispatch_returns_error_envelope_for_script_error_from_any_handler` патчит singleton-метод

```ruby
sys.define_singleton_method(:get_version) { |_params| raise ScriptError, "handler exploded" }
begin
  ...
ensure
  sys.define_singleton_method(:get_version, original)
end
```

`original = sys.method(:get_version)` — `Method` объект. `define_singleton_method` с `Method` объектом — **поддерживается** в Ruby. **OK**.

**НО:** в shared-process (`run_all.rb`) если предыдущий тест упал **между** `define_singleton_method` и `ensure` (например, OOM или signal) — singleton останется запатченным. С `ensure`-блоком это **невозможно** в normal flow, но **возможно** при `Thread.raise` или внешнем сигнале. Plan должен упомянуть `at_exit` cleanup или каждый тест в `setup` сбрасывает singleton. **Мелочь, не блокер**.

### K5. Task 3 Step 4 — duplicate `rescue` arm в dispatch

План в Step 4 добавляет:
```ruby
rescue ScriptError, SystemStackError => e
  Core::Logger.log_error(tool || "?", e)
  return nil if is_notification
  Core::Errors.build_error_response(-32603, "#{e.class}: #{e.message}",
    Core::Errors.exception_to_data(e, tool || "?", params), request_id)
```

Перед этим (строки 49-54) уже есть `rescue StandardError => e`. **Порядок важен**: Ruby проверяет rescue-arms сверху вниз. `ScriptError` НЕ subclass `StandardError` (ScriptError < Exception, NOT < StandardError). Поэтому новый arm **должен** идти ДО `rescue StandardError` (или вообще отдельно) — иначе StandardError arm не поймает SyntaxError, и новый arm **должен** быть первым. **OK, план ставит новый arm после существующего (строка 54 → новый arm после)**. Это правильный порядок: новый arm будет пойман раньше (строки 49-54 → новый arm ниже). **OK**.

### K6. `Test` в `test_joints_frame_compensation.rb` line 1080: `FakeGroup#subtract` стирает `target` без проверки `valid?`

```ruby
def subtract(target)
  TestJointsFrameCompensation.subtract_log << [self, target]
  result = FakeGroup.new(parent_collection: @parent_collection)
  @parent_collection.groups << result if @parent_collection
  erase!
  target.erase! if target.respond_to?(:erase!)
  result
end
```

Стирает оба. **OK**, имитирует SketchUp.

**НО:** если `target.respond_to?(:erase!)` = true, а target — это `pin_group` который уже `valid? == false` (предыдущий subtract стёр его) — `erase!` будет вызван на невалидном. Это OK (просто `@valid = false` уже). **OK**.

### K7. `FakeBoard` в test_joints_frame_compensation.rb — не патчит `add_group` через `parent.entities` правильно

`FakeBoard.entities` это `FakeCollection` (строка 1092). `add_group` в `FakeCollection` (строка 1046-1050):
```ruby
def add_group
  g = FakeGroup.new(parent_collection: self)
  @groups << g
  g
end
```

OK, `FakeGroup.parent_collection` — это `FakeCollection`, не `FakeBoard`. `FakeBoard.parent` **не задан** (строка 1095). `place_tenon` зовёт `board.parent.entities.add_group` — но в реальном `FakeBoard` (нашем тесте) `board.parent` = nil. Это сломает `place_tenon` если мы его вызовем. **НО** план в Task 7 тестирует только `carve_tails`, `carve_pins`, `carve_board1_fingers` — **не** `place_tenon`. `carve_*` идут через `add_parent_frame_prototype`, который зовёт `active_model!.active_entities.add_group` (строки 1208 плана) — это `FakeModel.active_entities` (строка 1100-1103). **OK**.

**Проверим** FakeModel: `def initialize; @active_entities = FakeCollection.new; end`. `add_group` на `@active_entities` создаёт `FakeGroup` с `parent_collection: @active_entities`. **OK**.

### K8. `FakeBoard#transformation` — `translation`, не Transformation

```ruby
def initialize(bounds:, translation:)
  ...
  @transformation = translation
end
```

`@transformation = FakeTranslation.new(30, 0, 0)`. В `add_parent_frame_prototype` (план строка 1211): `prot.transform!(board.transformation.inverse)`. `FakeTranslation#inverse` возвращает `FakeTranslation.new(-30, 0, 0)`. `FakeGroup#transform!(t)` (строка 1069-1072): `@transformation = @transformation.compose(t)` — `FakeTranslation#compose` складывает dx. **OK**.

### K9. `world_xs` обход (строки 1128-1142) — учитывает только X

```ruby
walk = lambda do |coll, offset|
  coll.faces.each { |pts| pts.each { |p| xs << p[0] + offset } }
  coll.groups.each do |g|
    walk.call(g.entities, offset + g.transformation.dx)
  end
  coll.instances.each do |inst|
    walk.call(inst[:definition].owner.entities, offset + inst[:transformation].dx)
  end
end
```

Это обход ВСЕХ faces в коллекции + рекурсия в подгруппы + под-instance'ы. Учитывает dx трансформации. **Корректно** для теста — проверяет, что **мировые X** всех точек остаются в `board.bounds.min.x ± depth`.

**НО:** `g.transformation.dx` — это dx **трансформации группы** (т.е. `prot`'s dx после `transform!(inv)`). `prot` в `add_parent_frame_prototype` создаётся с `transformation = FakeTranslation.new(0,0,0)`, потом `prot.transform!(board.transformation.inverse)` = `prot.transform!(FakeTranslation.new(-30,0,0))` → `prot.transformation = FakeTranslation.new(-30,0,0)`. Когда `add_instance(prot.definition, prot.transformation)` — instance в `board.entities` получает `transformation = FakeTranslation.new(-30,0,0)`.

В `board.entities.instances` (FakeCollection) — `add_instance` создаёт запись `{ definition: ..., transformation: ... }`. В `walk` — `offset + inst[:transformation].dx = 0 + (-30) = -30`. Но реально мировая X = board.transformation.dx + inst.transformation.dx + face_point.x = 30 + (-30) + face_x = face_x. То есть `walk` правильно: `offset = board.transformation.dx = 30`, потом `inst.transformation.dx = -30`, итого `offset + dx = 0`. И тогда `xs << p[0] + 0 = p[0]`. **OK**.

А `g.transformation.dx` (для подгрупп prot) = -30 (после transform! inv). `offset + g.transformation.dx = 30 + (-30) = 0`. **OK** — `face_x` остаётся неизменной в мировых координатах, потому что prot-translation compensates board-translation.

**Это значит:** xs.min ≈ face_x_min (локальная) = -width/2 (т.е. -25 для width=50). board.bounds.min.x = 30 (мировой). `xs.min >= board.bounds.min.x - depth = 30 - 0.5 = 29.5`. `xs.min = -25` — **должно быть 5**, а не -25. **ПОЧЕМУ?**

**ПЕРЕСМОТРИМ:** `xs << p[0] + offset`. offset в root walk = `board.transformation.dx = 30`. `p[0]` — это `face_x` в локальных координатах prot. После fix, prot имеет transformation = inv(board.T) = (-30). Все face в prot построены в **parent-frame** координатах (как в `add_parent_frame_prototype` comment "мировой-frame scratch-группе (координаты — от board.bounds, т.е. РОДИТЕЛЬСКИЙ фрейм)"). Так что face_x ∈ `[cx - width/2, cx + width/2]` где `cx = board.bounds.center.x + ox = 32 + 0 = 32`. Так что face_x ∈ `[7, 57]`. И xs = face_x + 30 - 30 = face_x ∈ [7, 57]. **OK**.

`board.bounds.min.x = 30`, `lo = 30 - 0.5 - 1e-6 = 29.5`. `xs.min = 7 >= 29.5`? **НЕТ!** `7 < 29.5` — тест **должен упасть даже после fix'а**!

**Это серьёзная проблема в плане.** Либо мой расчёт неверен, либо план ошибочен.

Давайте пересчитаем `world_xs`:
- `board` имеет `bounds = FakeBounds.new(FakePoint.new(30, 0, 0), FakePoint.new(34, 4, 1))` (строки 1110-1111).
- `board.transformation = FakeTranslation.new(30, 0, 0)`.
- В `add_parent_frame_prototype`:
  - `prot = active_model.active_entities.add_group` (FakeGroup с `transformation = FakeTranslation.new(0,0,0)`).
  - `prot.transform!(board.transformation.inverse)` = `FakeTranslation.new(-30, 0, 0)`. `prot.transformation = FakeTranslation.new(-30, 0, 0)`.
  - `E.entity_collection(board).add_instance(prot.definition, prot.transformation)` — добавляет в `board.entities` (FakeCollection) instance с `transformation = FakeTranslation.new(-30, 0, 0)`.

- Внутри `prot.entities` (FakeCollection) `carve_tails` строит faces:
  - `c = board.bounds.center` = FakePoint.new(32, 2, 0.5) (среднее min/max).
  - `cx, cy, cz = 32, 2, 0.5`.
  - `tail_w = 50 / (2*3-1) = 10` (для width=50).
  - `tx = cx - width/2 + tail_w * 2 * i = 32 - 25 + 20*i = 7 + 20*i` (i=0,1,2).
  - Face: `[tx - 5, cy - height/2, cz] = [tx - 5, -23, 0.5]`, и т.д.
  - **face_x ∈ [2, 27]** для i=0,1,2 (tx ∈ [7, 27]).

- `walk` (строки 1128-1141):
  - `walk.call(board.entities, 30)`:
    - `board.entities.faces` — пусто (face'ы в `prot.entities`, не в `board.entities`).
    - `board.entities.groups` — пусто.
    - `board.entities.instances` — **один** instance с `transformation = FakeTranslation.new(-30, 0, 0)`.
    - `walk.call(prot.entities, 30 + (-30))` = `walk.call(prot.entities, 0)`:
      - `prot.entities.faces` — 3 face'а (num_tails=3) с face_x ∈ [2, 27].
      - `xs << 2 + 0 = 2`, `xs << 7 + 0 = 7`, `xs << 12 + 0 = 12`, ..., `xs << 27 + 0 = 27`.
      - `prot.entities.groups` — пусто (в carve_tails нет подгрупп).
      - `prot.entities.instances` — пусто.

- Итого: `xs = [2, 7, 12, 17, 22, 27, 2, 7, 12, 17, 22, 27, 2, 7, 12, 17, 22, 27]` (12 точек на 3 face × 4 точки).

- `xs.min = 2`, `xs.max = 27`.
- `board.bounds.min.x = 30`, `lo = 30 - 0.5 - 1e-6 = 29.5`, `hi = 34 + 0.5 + 1e-6 = 34.5`.
- `xs.min >= lo`? `2 >= 29.5` — **НЕТ**, тест упадёт.

**ВЫВОД:** тест в `test_joints_frame_compensation.rb` (Task 7) **НЕПРАВИЛЬНЫЙ** — после фикса он ВСЁ РАВНО УПАДЁТ.

Реальная живая семантика: tail_slot/carve ВЫРЕЗАЕТСЯ в доске, cutter простирается **глубже** доски (z=0..-depth). Для dovetail `width=50, height=50, depth=15` — cutter extrudes `height=50mm` (1.97") в `+y` (от `cy - height/2` к `cy + height/2`), но X-координаты ТАЛОВ `tx ∈ [7, 27]` — это **в пределах** `board.bounds.x ∈ [30, 34]`?

**Нет, не в пределах!** `board.bounds.x ∈ [30, 34]` (width=4" = ~100мм). `width=50mm = 1.97"` для dovetail — это ширина самих TAILS'ов, не доски. Доска 4" широкая, а хвосты шириной 2" — центрированы в `board.bounds.center.x = 32`. `tx ∈ [7, 27]` в локальных координатах prot.

`prot.transformation = (-30, 0, 0)` — это **instance transformation**, которая применяется к geometry при инстанцировании. Мировая X геометрии = prot.transformation * (geometry) = (geometry_x - 30). Так что **мировая X = local_x - 30**. Для tx=7: мировая = -23. Для tx=27: мировая = -3. **Мировая X ∈ [-23, -3]** — **СНАРУЖИ** доски [30, 34]!

**Это не имеет смысла.** Если бы dovetail cutter строился в parent-frame координатах (как ожидает fix), то его координаты должны быть в **[30, 34]**, а не в локальных [-30, 34]. Потому что `board.bounds.center.x = 32` — это **мировое** значение.

**Корень проблемы:** в исходном коде `carve_tails` использовал `board.bounds.center` (мировые координаты) и рисовал faces прямо в `E.entity_collection(board).add_group` (board-local frame). Это давало double offset: face_x в world ≈ 32, при добавлении в board-local превращалось в 32+30=62 (для shifted board) — НЕ 32. Это и был баг.

После fix'а с `add_parent_frame_prototype`: face строится в prot (root group) в parent-frame coordinates, потом **add_instance** с `prot.transformation = board.transformation.inverse` — то есть `instance.T = (-30, 0, 0)`. Когда instance добавляется в `board.entities`, мировая позиция geometry = `board.T * instance.T * geom = 30 + (-30) + geom = geom`. То есть **face_x В МИРЕ = local_x в prot**.

Но `board.bounds.center.x = 32` (мировые) — это **центр мирового bbox доски**. Чтобы хвосты попали в доску, `geom` (face_x) должно быть **в мировом [30, 34]**, а не в локальном [2, 27] (= parent-frame [7, 27], и **add_instance с inv.T = (-30)** даёт мировое [7-30, 27-30] = **[-23, -3]**).

**ПРОБЛЕМА:** `add_instance(prot.definition, prot.transformation)` помещает геометрию **в локальную систему координат** board'а, а prot.transformation = board.transformation.inverse компенсирует board.transformation, чтобы **face_x в parent-frame координатах prot = face_x в мире**. То есть:
- В prot: `geom_x ∈ [7, 27]` (parent-frame of board, т.е. мировые координаты, если board в world root).
- `add_instance(prot.def, T_inv)`: instance placed at `T_inv * geom`. Внутри `board.entities` instance имеет local-coords = `T_inv * geom_x = geom_x - 30 ∈ [-23, -3]`. **Мировые** instance coords = `board.T * local = 30 + (geom_x - 30) = geom_x`. Так что **мировые X геометрии = [7, 27]**.

**ХОРОШО, это правильно.** Геометрия оказывается в **мировых координатах [7, 27]**, не в [30, 34] (доска).

**ВОПРОС:** где должны быть хвосты? `board.bounds.x = [30, 34]`. `width=50mm = 1.97"` для dovetail. Хвосты центрированы в `board.bounds.center.x = 32` (мировых). Мировые tail_x ∈ `[32 - 25, 32 + 25] = [7, 57]`. **Но доска [30, 34]!** `width=50mm` **ШИРЕ** доски (4" = 100мм)!

**Это ОШИБКА В ТЕСТОВОМ СТЕНДЕ:** `width=50, height=50, depth=15` (мм) — это размеры dovetail'а. Доска в тесте — 4" (100мм). 50мм < 100мм — **всё ок, хвосты помещаются** в доску. Мировые [7, 57] — но доска [30, 34]. **Хвосты торчат за пределы доски** — это потому что `width=50mm` меньше доски 100мм, но центрированы в **board.bounds.center.x = 32** (мировых) — а 32 ± 25 = [7, 57], что **ШИРЕ доски [30, 34]**.

**Подождите.** `width=50mm = 1.97"`, `board width = 4" = 100mm`. Хвосты 50мм **уже** доски 100мм. Центрированы в `board.bounds.center.x`. Должны быть в [32-25, 32+25] = [7, 57] — НО доска 4" = 100мм шириной, значит её мировой bbox 30..34 (width=4). **То есть board.bounds = [30, 34]** при world origin (0,0,0) и `T = (30,0,0)`. Так что доска имеет **МИРОВУЮ ширину 4 дюйма** (а не 100мм). И `width=50mm = 1.97"` — это **уже**, чем доска (4"), **но центрировано в board.bounds.center.x = 32**. Мировые tail_x ∈ [7, 57] — **СНАРУЖИ** доски!

**ААА, понял.** В **ТЕСТОВОМ СТЕНДЕ** (строки 1108-1113) доска `bounds: FakeBounds.new(FakePoint.new(30, 0, 0), FakePoint.new(34, 4, 1))` — width=4" в мире. А `carve_tails(board, 2.0, 2.0, DEPTH, 15.0, 3, 0, 0, 0)` — width=2.0" (50.8мм), height=2.0". Но **доска 4" шириной**. Так что хвосты 2" **уже** доски 4" — должны помещаться. **Но центрированы в board.bounds.center.x = 32**, что даёт [7, 57] — **шире доски**!

**ОШИБКА В ТЕСТОВОМ СТЕНДЕ:** `width=2.0` (дюймы, аргумент carve_tails), `board width = 4"`. `tx = 32 - 1.0 + 0.667*2*i = 31 + 1.33*i` для i=0,1,2 → tx ∈ [31, 33.67]. **Это в [30, 34]** — OK.

**ПЕРЕСЧИТАЕМ заново:**
- `c = board.bounds.center` = `FakePoint.new(32, 2, 0.5)`.
- `cx, cy, cz = 32, 2, 0.5`.
- `width = 2.0`, `height = 2.0`, `depth = 0.5`, `angle = 15°`, `num_tails = 3`.
- `tail_w = 2.0 / (2*3 - 1) = 0.4`.
- `tx = 32 - 2.0/2 + 0.4 * 2 * i = 31 + 0.8*i` для i=0,1,2 → tx ∈ [31, 32.6].
- Face x ∈ `[tx - 0.2, tx + 0.2]` ∈ [30.8, 32.8] для каждого i.

**Геометрия в prot-entities (в parent-frame координатах prot = root group)**: face_x ∈ [30.8, 32.8]. prot.transformation = (-30, 0, 0) после fix.

**`add_instance(prot.def, (-30))`** — instance в board.entities имеет local = (-30) * geom. geom_x ∈ [30.8, 32.8], instance local = geom - 30 ∈ [0.8, 2.8]. Мировые = board.T + local = 30 + (geom - 30) = **geom ∈ [30.8, 32.8]**. 

**xs в walk** (board.entities → instances → prot.entities):
- `walk(board.entities, 30)`: instances → `walk(prot.entities, 30 + (-30)) = walk(prot.entities, 0)`.
- `walk(prot.entities, 0)`: faces → `xs << face_x + 0 = face_x`. face_x ∈ [30.8, 32.8].

**xs.min = 30.8, xs.max = 32.8**. `lo = 30 - 0.5 - 1e-6 = 29.5`, `hi = 34 + 0.5 + 1e-6 = 34.5`. `xs.min >= lo` (30.8 >= 29.5 — OK), `xs.max <= hi` (32.8 <= 34.5 — OK). **ТЕСТ ПРОХОДИТ после fix'а.**

**ДО fix'а** (старый код, carve_tails использовал `E.entity_collection(board).add_group`):
- `group = entities.add_group` — `entities = board.entities` (FakeCollection). `group` — FakeGroup с transformation = (0,0,0).
- Face добавляется в `group.entities` (FakeCollection) с теми же face_x ∈ [30.8, 32.8].
- `walk(board.entities, 30)`: groups → `walk(group.entities, 30 + 0) = walk(group.entities, 30)`.
- `walk(group.entities, 30)`: faces → `xs << face_x + 30 = 60.8 .. 62.8`. **xs.min = 60.8**, что **>= 29.5**? **ДА**, тест пройдёт. **Но живой smoke (T-03) ловит промах — почему?**

**ПЕРЕСЧИТАЕМ ДЛЯ ЖИВОГО REPRO:** «доска x 800..920, хвосты улетели в x 800..1704». Доска 800..920 (120мм = 4.72"). `width=50mm = 1.97"`. `tail_w = 1.97 / 5 = 0.394"`. `tx = 860 - 0.985 + 0.788*i = 859 + 0.788*i` ∈ [859, 861.4]. `face_x ∈ [858.6, 862.2]`.

**СТАРЫЙ КОД:** face в `group.entities` (subgroup of board.entities). Мировые = board.T + group.T + face_x. `board.T = (800, 0, 0)`, `group.T = (0, 0, 0)` (свежий), `face_x = 858.6..862.2`. Мировые = 800 + 0 + 858.6..862.2 = **1658.6..1662.2**. **Это вне доски 800..920 — как раз 1658 = 800 + 858, что похоже на 1704 в живом репро** (там другие числа width). 

**НО В ТЕСТЕ `bounds = FakeBounds.new(FakePoint.new(30, 0, 0), FakePoint.new(34, 4, 1))`** — это **мировые** bounds доски. `c = board.bounds.center = (32, 2, 0.5)` (мировые). `tx = 32 - 1.0 + 0.4*2*i = 31 + 0.8*i` ∈ [31, 32.6] (мировые).

В СТАРОМ КОДЕ `group` создаётся в `E.entity_collection(board)` (board-local frame) — но face_x координаты — **мировые** (потому что `board.bounds` в parent-frame = world). Когда face добавляется в `group.entities`, **face_x в parent-frame** = face_x = 31..32.6. `walk` для board.entities (старый): groups → `walk(group.entities, 30 + 0) = walk(group.entities, 30)`. `xs << face_x + 30 = 31+30 = 61, 32.6+30 = 62.6`. **xs.max = 62.6, hi = 34.5**. `62.6 <= 34.5`? **НЕТ — тест упадёт.**

**В НОВОМ КОДЕ** `add_parent_frame_prototype`: face строится в `prot.entities` (root group) с теми же face_x (parent-frame = world). `prot.transform!((−30,0,0))` → prot.transformation = (-30, 0, 0). `add_instance(prot.def, prot.transformation)` в `board.entities` — instance с transformation = (-30, 0, 0). `walk` для board.entities (новый): instances → `walk(prot.entities, 30 + (-30)) = walk(prot.entities, 0)`. `xs << face_x + 0 = 31..32.6`. **xs.max = 32.6, hi = 34.5**. `32.6 <= 34.5`? **ДА — тест пройдёт.**

**ОТЛИЧНО, тест корректен** — после моего пересчёта.

**Я ошибся в первом расчёте, перепутав `width` аргумента (мм) и реальные координаты в дюймах.**

### K10. Smoke шаг 21 (Task 9) — `b_tail` не пересоздаётся после transform

План в Task 9 Step 2:
```python
b_tail = parse(await call(conn, "create_component",
                          type="cube", dimensions=[120, 100, 20]))["id"]
moved = parse(await call(conn, "transform_component",
                         id=b_tail, position=[800, 0, 0]))
assert abs(moved["bbox_mm"]["min"][0] - 800) < 0.5, f"move failed: {moved}"
b_pin = parse(await call(conn, "create_component",
                         type="cube", position=[800, 120, 0],
                         dimensions=[120, 100, 20]))["id"]
dv = parse(await call(conn, "create_dovetail",
                      tail_id=b_tail, pin_id=b_pin,
                      width=50, height=50, depth=15))
```

`create_dovetail` использует `b_tail` — **исходный** ID, не `moved["id"]`. После `transform_component` ID **не меняется** (transform модифицирует трансформацию instance, не создаёт новый). `describe_entity` возвращает тот же ID. **OK**.

**НО:** `b_pin` создаётся с `position=[800, 120, 0]` — то есть в **абсолютной** bbox-min семантике (create_component). bbox b_pin = [800, 920, 100, 120, 20]? Нет: position = [800, 120, 0], dims = [120, 100, 20] → bbox = [800..920, 120..220, 0..20]. b_tail bbox после transform: position=[800,0,0] + dims=[120,100,20] → bbox = [800..920, 0..100, 0..20]. **OK**.

Dovetail cuts: bbox обеих досок должен остаться `[800-15-1, 920+15+1] = [784, 936]`. Это валидируется `assert bb["min"][0] >= 800 - 15 - 1`. **OK**.

### K11. Smoke шаг 22 (Task 9) — `t0 = time.monotonic()` ловит 60s timeout, но Python `asyncio.wait_for` уже мог отменить корутину

В Task 1 (cap mcp) — `mcp<2`. В Task 9 smoke шаг 22 — ловит, что `eval_ruby("def broken(")` поднимает `SketchUpError` с `code=-32603` и `SyntaxError` в message. **ОК**, но `time.monotonic()` в Python async-контексте — `await asyncio.sleep(0)` может не выполниться, если event loop забит. На самом деле, Python event loop обрабатывает `asyncio.sleep(0)` сразу. **OK**.

### K12. Task 2 CI matrix — `python-version: ['3.11', '3.12', '3.13']` НЕ включает 3.10

`pyproject.toml:6` говорит `requires-python = ">=3.10"`, classifiers (lines 16-18) включают 3.10. CI matrix в Task 2 Step 1 — `['3.11', '3.12', '3.13']`. **3.10 пропущен.** Это несоответствие, и `uv sync --extra dev` под 3.10 может дать несовместимые версии pytest-asyncio.

**Рекомендация:** добавить `'3.10'` в matrix ИЛИ явно обосновать исключение (pytest-asyncio 1.x может не работать с 3.10).

### K13. Task 2 CI `actions/checkout@v4` — `permissions:` не задан

Workflow не имеет `permissions:` блока. По умолчанию GITHUB_TOKEN имеет write-permissions, что позволяет actions делать `git push` и т.п. Best-practice для CI — `permissions: read-all` + явные `permissions: contents: read` для каждого job.

**Мелочь**, но с hardening-трендами GitHub это становится всё важнее. **Не блокер**.

### K14. Task 9 Step 2 — `dv["boolean_cuts"]["failed"] == 0` после fix T-03

После fix'а dovetail cutter'ы **попадают в доску** → `boolean_cuts.failed == 0`. Это **Definition of Done** — НО **до** fix'а T-03 `dv["boolean_cuts"]["failed"]` **может быть ненулевым**, потому что cutter'ы вне доски → SketchUp не может их subtract'ить. Проверка `assert dv["boolean_cuts"]["failed"] == 0` **падёт на старом коде** и **пройдёт на новом**. **OK, регрессионный guard**.

### K15. Task 3 `rubocop:disable Security/Eval` остаётся в `eval.rb`

План в Task 3 Step 3 заменяет блок eval, оставляя `# rubocop:disable Security/Eval`. **OK**.

### K16. Task 6 `apply_rotation` использует entity.bounds.center ПОСЛЕ position-трансформации

`position` теперь absolute bbox-min. После position, `entity.bounds.min == position`. `entity.bounds.center = position + (old_size/2)`. Rotation вокруг **нового** center. Если `position` сдвинут, rotation тоже сдвинется в новый центр. **Корректно** — rotation всегда relative around current center.

### K17. Тест `test_transform_component_translates_via_position_delta` использует fragile regex

```ruby
body = src[/def self\.transform_component.*?(?=\n      def self\.)/m]
```

Это захватывает **всё от `def self.transform_component`** до **следующего `def self.`**. Если внутри метода есть `def self.something` (sub-helper), он остановится раньше. Текущий код — между `transform_component` и `apply_rotation` нет вложенных `def self.`. **OK**.

**НО:** `refute_match(/translation\(\s*\n?\s*Geom::Point3d\.new\(position\[0\]/m, body, ...)` — этот regex ищет `translation(\n Geom::Point3d.new(position[0]`. Реальный старый код (строки 93-94):
```ruby
entity.transform!(Geom::Transformation.translation(
  Geom::Point3d.new(position[0], position[1], position[2])))
```

`translation(\n              Geom::Point3d.new(position[0]`. Regex `/translation\(\s*\n?\s*Geom::Point3d\.new\(position\[0\]/m` — `\s*\n?\s*` матчит `\n              ` (whitespace + newline). **OK**.

### K18. Task 9 — `eval_skipped` mutable container через `[0] += 1`

`eval_skipped = [0]` и `eval_skipped[0] += 1` — в Python это **изменяемый контейнер** (list). Используется потому что closure'ы не могут писать в nonlocal переменные без `nonlocal`. **OK**.

## Suggestions

### S1. Task 4 — добавить test на «add_parent_frame_prototype используется» (guard Task 7)

Source-guard `test_joints_subtract_call_sites_keep_cutter_first` (Task 4) — фиксирует literal-вызовы. После Task 7 эти вызовы **остаются** (обёрнуты в `add_parent_frame_prototype`). **OK** — guard'ы переживают рефакторинг.

**Рекомендация:** добавить в Task 7 source-guard «`add_parent_frame_prototype` определён и используется в `carve_tails`/`carve_pins`/`carve_board1_fingers`» — чтобы при будущем рефакторе `add_parent_frame_prototype` не удалили.

### S2. Task 5 — `group.entities.add_face` в `build_sphere` и реальный SketchUp

`group` это `entities.add_group` (строка 154). `add_group` в SketchUp возвращает новую `Sketchup::Group` в коллекции. `group.entities` — внутренняя коллекция. В тесте `FakeEntities` (строки 658-664) `add_group` создаёт FakeGroup с `entities = FaceCollector`. **OK**.

**НО:** в `add_face` реального SketchUp при вырожденной грани (точки совпадают) — поведение различается: некоторые версии возвращают nil, некоторые кидают. **План предполагает** `add_face` кидает. Если реальный SketchUp возвращает nil — план **не сработает**. **Рекомендация:** покрыть оба случая: `if face.nil? || degenerate?` (но нельзя знать, degenerate ли — нужно пробовать pushpull и смотреть).

**Это уже учтено** — `rescue StandardError` в плане Step 3. Если `add_face` возвращает nil без raise — будет слом. **Рекекомендация:** убрать `rescue` и явно проверять `face.nil?` после `add_face`. Но это сломает интерфейс (для не-полюсных граней `add_face` всегда возвращает face).

### S3. Task 6 source-guard `position_delta` — должна быть **до** `transform_component` в источнике?

План предлагает определить `position_delta` в секции `# ----- private builders ---` (после `transform_component`). Source-guard ищет `position_delta(entity.bounds.min, position)` в `transform_component`. **OK** — порядок определения не важен, важен факт вызова.

### S4. Task 6 prompts.py — новая конвенция про position, но не сказано про rotation/scale

Prompts.py Step 6:
```
- transform_component.position is an ABSOLUTE target: the entity's
  bbox-min corner lands exactly there (same anchor as
  create_component.position). rotation/scale are relative, about the
  bbox center.
```

Это явно. **OK**.

### S5. Task 9 — docstring обновлён на «SketchUp 2026+» (было «2024+»)

План в Step 1:
```
1. SketchUp 2026+ is running with an empty model (step 19 uses the
   viewport-screenshot tool, verified on SketchUp 2026 only).
```

Реальный код (строка 5): `1. SketchUp 2024+ is running with an empty model.` План обновляет на `2026+`. **Корректно** — но это **ужесточает** требования. **OK**, потому что viewport_screenshot tool **требует** 2026+ (см. CLAUDE.md).

### S6. Task 7 — fake Model active_entities vs `E.entity_collection(board)`

`E.entity_collection(board)` в тесте возвращает `board.entities` (FakeCollection). В реальном коде — возвращает `board.entities` (Sketchup::Entities). `add_instance` в FakeCollection (строки 1051-1054) возвращает `definition.owner` (group, чей definition передан). **OK**, имитирует SketchUp::Group, который возвращается из `add_instance`.

### S7. Task 8 — `aclose` тест использует `MagicMock` для writer

В реальном коде `disconnect()` зовёт `self._writer.close()` (sync) и `await self._writer.wait_closed()` (coroutine). `MagicMock` с `wait_closed = slow_wait_closed` — корутина, ждущая `gate.wait()`. **OK**.

**НО:** `MagicMock().close()` возвращает MagicMock (не AsyncMock). В `disconnect()` строка 196 `self._writer.close()` — sync вызов. `MagicMock()` поддерживает. **OK**.

### S8. Task 1 — комментарий в pyproject.toml о `mcp<2`

План Step 1 добавляет комментарий:
```
# <2: mcp v2 (июль 2026) ломает импорт-поверхность mcp.server.fastmcp
# (новый Dispatcher, только спека 2025-11-25). Floor 1.27 = фактическая
# версия из uv.lock. Миграция на v2 — отдельный тикет после стабилизации.
```

**OK**, информативно.

### S9. Plan структура — Step "адверсариальная проверка" может быть необязательной

Task 4 Step 5 (адверсариальная проверка флипом) — это **manual verification**. Можно автоматизировать: создать `test/test_boolean_direction_adversarial.rb` который **временно** патчит `operations.rb` через stub. Но это overkill — manual verification OK.

## Questions

### Q1. После Task 6 — `apply_rotation` зовётся ПОСЛЕ position, что для повторного `transform_component`?

Если вызвать `transform_component(id, position=[100, 0, 0])` дважды — в первый раз `bbox.min = [100, 0, 0]`, во второй — `bbox.min = [100, 0, 0]` (idempotent). **OK**. Но если `rotation=[90, 0, 0]` применится ПОСЛЕ position — rotation вокруг нового center. Повторный `transform_component(id, rotation=[180, 0, 0])` — повторно вокруг того же (или нового?) center. **OK, документировано как «relative around bbox center»**.

### Q2. Task 3 — что если `eval_ruby` поднимает **исключение, определённое в user-коде**, наследника `Exception` (не StandardError и не ScriptError)?

Пример: `class MyError < Exception; end; raise MyError`. `< Exception` — НЕ `StandardError`, НЕ `ScriptError`. **Не ловится ни одним rescue в `Dispatch.handle`.** План покрывает `ScriptError, SystemStackError, StandardError` + StructuredError. `Exception`-наследники (но не `ScriptError`!) **не ловятся** — запрос упадёт, пройдёт через `dispatch.rb:49` StandardError arm? **Нет**, `< Exception` не subclass `StandardError`. **ПРОБЛЕМА: пользовательский код может определить exception < Exception, и та же проблема повторится.**

**Рекомендация:** ловить `Exception` целиком (или `StandardError + ScriptError + SystemStackError + Exception`). Но `Exception` слишком широк (поймает `Interrupt`, `SystemExit`). **Правильный выбор:** `Exception`-наследники, кроме `Interrupt`, `SystemExit`, `SignalException`. Это Ruby-way `rescue Exception` с whitelist'ом.

**План этого не покрывает.** В рамках T-01 это **пограничный кейс**, но worth mentioning.

### Q3. Task 9 — smoke_check для eval_ruby: `assert e.code == -32603` — но если eval_disabled поднимет -32010?

В Task 9 Step 2 шаг 22 — `eval_ruby("def broken(")` — если eval отключён (`eval_enabled = false`), Ruby поднимет `EVAL_DISABLED_CODE = -32010`. `SketchUpError.code == -32010`, а тест ожидает `-32603`. Тест упадёт.

**Однако** план оборачивает в `_maybe_skip_eval`:
```python
raw = await _maybe_skip_eval(
    "eval_ruby step 22 (syntax error)",
    call(conn, "eval_ruby", code="def broken("),
)
if raw is None:
    eval_skipped[0] += 1
else:
    raise AssertionError(f"syntax error must raise an error, got: {raw}")
```

`_maybe_skip_eval` ловит `SketchUpError` с `code == EVAL_DISABLED_CODE` → возвращает `None`. Если `eval` отключён — `raw is None`, `eval_skipped[0] += 1`. **OK**.

**НО:** если eval включён, raw = result (без exception). План пишет `raise AssertionError(f"syntax error must raise an error, got: {raw}")` — то есть если raw — это какой-то результат, тест падает. После fix'а T-01 Ruby **всегда** поднимет `-32603` для syntax error. Так что **raw не будет None и не будет результатом** — `SketchUpError` поднимется. **OK**.

### Q4. Task 4 — `test_geometry_builders.rb` `add_face` stub raises, но реальный SketchUp ведёт себя иначе

В тесте `FaceCollector#add_face` кидает `ArgumentError` если расстояние между точками < TOLERANCE. В реальном SketchUp `add_face` на вырожденной грани может:
1. Вернуть nil (без raise).
2. Кинуть `ArgumentError` (некоторые версии).
3. «Тихо» слить точки (>= SketchUp 2024?).

**После fix'а T-02** полюсные грани строятся как треугольники (НЕ degenerate), и `add_face` возвращает Face. Plan **не** проверяет путь «`add_face` вернул nil без raise» — потому что **после fix'а** этого не происходит. **OK**.

### Q5. Task 9 — шаг 6 переименован в «ABSOLUTE bbox-min» — а как насчёт `apply_rotation` ПОСЛЕ position?

В Task 6 Step 5 docsstring:
```python
"""Move, rotate and/or scale a group or component (mm / degrees).
- position: ABSOLUTE target for the entity's bounding-box MIN corner, in mm.
- rotation: RELATIVE rotation in degrees around the bbox center, applied sequentially about world X, then Y, then Z.
- scale: RELATIVE scale factors about the bbox center.
"""
```

Это ясно. **OK**.

### Q6. Plan глобально — почему в `Task 5` не упомянуто про `apply_rotation` использующее `entity.bounds.center` ПОСЛЕ position?

Position абсолютный, после — `bounds.center` смещён. Rotation вокруг нового center. **OK, документировано в docsstring**.

### Q7. Task 7 — `add_parent_frame_prototype` использует `active_model!.active_entities.add_group`. Что если board — NESTED (внутри другого group)?

`active_model!.active_entities` — root коллекция модели. `add_group` в root. **Стирание prot в `ensure`** — `prot.erase!` стирает из root. **OK**. Но `add_instance(prot.definition, prot.transformation)` в `E.entity_collection(board)` — это board-local collection. Если board nested, `E.entity_collection(board)` это **локальная** entities вложенной группы. **OK** — instance добавляется туда.

**Проверим:** `place_tenon` (строки 226-238) делает то же самое — `entities = E.entity_collection(board)`, `prot = active_model!.active_entities.add_group`. Это **уже работает для nested boards** (комментарий в `place_tenon` явно об этом говорит: "World position of an instance added to board.entities is parent_t · T_board · T_inst · geom; with T_inst = T_board.inverse the T_board's cancel and we get parent_t · geom — correctly placing geometry at parent-frame origin for both top-level boards (T_board=identity, T_inst=identity) and nested/transformed boards"). **OK**.

### Q8. Task 1 (cap mcp) — почему `<2` а не `<2.0`?

`mcp[cli]>=1.27,<2` — Python's PEP 440 трактует `<2` как `<2.0.0` (а не `<2.0` — это `<2.0.0, dev0`). **Корректно** — cap на major version.

### Q9. Plan в Task 3 Step 1 — `with_eval_enabled` хелпер не делает `ensure` save/restore для `eval_skipped` и не изолирует тесты

Тест `test_eval_ruby_syntax_error_returns_structured_error_fast` использует `with_eval_enabled`. Если **внутри** теста raise'ится **исключение** (например, `assert_equal` падает) — `with_eval_enabled` всё равно сбрасывает `eval_enabled` через `ensure`. **OK**.

**НО:** если несколько тестов в shared-process параллельно патчат `Config.eval_enabled` — могут быть гонки. minitest по умолчанию **НЕ** запускает тесты параллельно. **OK**.

### Q10. Task 4 — `test_geometry_builders.rb` использует `MCPforSketchUp::Core::Config.log_level = "ERROR"` в setup

Зачем? Чтобы загасить `Logger.log("DEBUG", ...)` (план Step 3 fix оставляет rescue-arm). В текущем коде (строки 174-179):
```ruby
rescue StandardError => e
  MCPforSketchUp::Core::Logger.log("DEBUG",
    "build_sphere: skipped degenerate face at pole: #{e.class}: #{e.message}")
end
```

Это **до** fix'а. После fix'а `rescue` **остаётся** как «последний рубеж»:
```ruby
rescue StandardError => e
  MCPforSketchUp::Core::Logger.log("DEBUG",
    "build_sphere: skipped degenerate face at pole: #{e.class}: #{e.message}")
end
```

То есть в тесте `add_face` **всегда** бросает, **кроме полюсных** (которые теперь треугольники). В тесте `FaceCollector#add_face` **всегда** бросает на degenerate — после fix'а полюсные грани — **не** degenerate, поэтому не бросают. **OK**, debug-лог пуст. Зачем тогда `log_level = "ERROR"`?

**Возможно**, чтобы загасить setup/teardown или какие-то логи. **Не критично** — оставлено как defensive.

---

## Сводка

| Категория | Кол-во |
|---|---|
| Critical Issues | 7 (C1-C7) |
| Concerns | 18 (K1-K18) |
| Suggestions | 9 (S1-S9) |
| Questions | 10 (Q1-Q10) |

**Общая оценка:** План **очень хорошего качества**. Все якоря строк совпадают с реальным кодом, дословный код фиксов и тестов корректен по синтаксису. Основные риски:
- **C2** (source-guard false-positive при переименовании переменных) — некритично, рекомендация
- **C3** (адверсариальная проверка неполна) — рекомендация уточнить
- **K12** (CI matrix не покрывает Python 3.10) — стоит исправить
- **Q2** (eval_ruby не ловит Exception-наследников) — пограничный кейс, worth discussion
- **K17** (source-guard regex fragile) — minor, работает на текущем коде

План **готов к исполнению** после косметических правок K12 и Q2.

