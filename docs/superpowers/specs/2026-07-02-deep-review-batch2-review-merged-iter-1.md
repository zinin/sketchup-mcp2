# Merged Design Review — Iteration 1

**Топик:** deep-review-batch2
**Дата ревью:** 2026-07-03
**Документы:** `docs/superpowers/specs/2026-07-02-deep-review-batch2-design.md`, `docs/superpowers/plans/2026-07-02-deep-review-batch2.md`
**Состав:** пресет `defaults.design_review` (builtin claude + codex + 5 внешних моделей).
**Статус агентов:** codex ✅, alibaba/qwen ✅, deepseek/v4-pro ✅, zai/glm ⚠ (частично — прогон оборван стримом, включён факт-чекинг из лога), ollama/minimax ⚠ (частично — контекстный лимит «Prompt is too long» на 8.1M входных токенов; включена выжимка промежуточных находок из лога), builtin claude ✅ (пришёл после первичного merge — включён), ollama/kimi ❌ (три обрыва стрима подряд, результата нет на момент merge).
**Решение:** по указанию пользователя merge выполнен по имеющимся результатам, не дожидаясь остальных.

---

## codex-executor (gpt-5.5, reasoning xhigh)

### Critical Issues

- В Task 1 тест для LOG_LEVEL сломан: `r.message % r.args` в `caplog.records` даст `TypeError`, потому что `record.message` уже отформатирован. Нужно `r.getMessage()`. См. [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-deep-review-batch2.md:87). Заодно RED-прогноз считает 6 старых `test_config.py`, но реально их 5: [tests/test_config.py](/opt/github/zinin/sketchup-mcp2/tests/test_config.py:27).

- Task 11 предлагает в `test_export_skp.rb` стабить реальные module methods через `define_singleton_method`, а в `ensure` делать `remove_method`. Комментарий в плане неверен: под `run_all` это удалит настоящий `Validation.require_enum` / `Entities.active_model!`, а не "снимет верхний стаб". Нужно сохранять `Method` и восстанавливать, как в других тестах. См. [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-deep-review-batch2.md:2352) и общий one-process loader [test/run_all.rb](/opt/github/zinin/sketchup-mcp2/test/run_all.rb:7).

- Пагинация T-07 не решает главный scalability-риск: план всё равно строит полный `components = collect_components(...)`, и только потом делает `slice`. Это ограничивает JSON-ответ, но не CPU/UI freeze и не память Ruby на больших моделях. См. [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-deep-review-batch2.md:1265). Если `total` обязателен, нужен traversal-аккумулятор, который считает total, но материализует только страницу.

- Ruby-валидация пагинации не соответствует заявленному контракту `limit 1..500`: `pagination_params` использует только `optional_int_positive`, а он проверяет `> 0`, без верхней границы. Прямой TCP-клиент сможет прислать огромный `limit`; Python `le=500` это не закрывает. См. [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-deep-review-batch2.md:1280) и текущий helper [validation.rb](/opt/github/zinin/sketchup-mcp2/mcp_for_sketchup/mcp_for_sketchup/helpers/validation.rb:85).

- "Зеркальные pydantic-констрейнты" в Task 13 не строгие. Pydantic по умолчанию коэрсит: `"3"` → `3`, `True` → `1`, `"false"` → `False`, `"1.5"` → `1.5`. Это противоречит Ruby strict-валидации для `recursive/max_depth/name/offsets`. Особенно опасен `EntityId = int | str`: `True` проходит как `1`. См. [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-deep-review-batch2.md:750), [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-deep-review-batch2.md:1403), текущие аннотации [tools.py](/opt/github/zinin/sketchup-mcp2/src/sketchup_mcp/tools.py:445).

- Backpressure T-13.2 проверяется только на уже заполненной очереди. Предложенный guard стоит в начале `drain_reads_all_clients`, но один `read_nonblock(64 KiB)` может декодировать тысячи мелких фреймов и раздувать `@frame_queue` сильно выше `FRAME_QUEUE_SOFT_MAX` до следующего тика. Нужно останавливать чтение внутри `drain_one_client`/после `feed`, когда очередь достигла soft max. См. текущий read loop [server.rb](/opt/github/zinin/sketchup-mcp2/mcp_for_sketchup/mcp_for_sketchup/core/server.rb:166).

- Pre-handshake timeout из T-13.5 может закрыть `close_after_response` клиента, который уже получил handshake-reject/error envelope в pending write, но ещё медленно дренируется. Метод должен пропускать `state.close_after_response` или pending writes, иначе конфликтует с T-13.1. См. [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-deep-review-batch2.md:2164).

- Task 15 самопротиворечив: тест требует `mm/millimeter` у `export_scene`, но предложенный докстринг `export_scene` этого не содержит, да и для export это неверное требование. Тест будет красным после "GREEN". См. [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-deep-review-batch2.md:3422) и докстринг ниже [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-deep-review-batch2.md:3486).

### Concerns

- Для Task 9 fallback `-> list` не теоретический: текущий `mcp==1.27.0` падает на регистрации `-> list[Image | str]`. План должен сразу предписывать `-> list`, а не "если споткнётся". См. [plan](/opt/github/zinin/sketchup-mcp2/docs/superpowers/plans/2026-07-02-deep-review-batch2.md:1683).

- Новые Ruby test-файлы в плане местами объявляют `module Sketchup` / `module Geom` не guarded, хотя Global Constraints требуют guarded-стабы. В one-process `run_all` это хрупко и может зависеть от порядка require.

- T-55 проверяет empty bbox только через `bb.min.x > bb.max.x`. Лучше использовать `bb.empty?` при наличии или проверять все оси, иначе helper кодирует частный вид sentinel-а.

- Финальный `git rm -r docs/superpowers/` удалит tracked design/plan, но оставит множество untracked prompt/spec файлов в этой директории. Для PR это, вероятно, не страшно, но утверждение "уйдут вместе с git rm" неверно.

### Suggestions

- Ввести Ruby helpers `optional_int_range(params, key, min:, max:, default:)` и, возможно, `optional_string_nonempty`; использовать для `limit`, `offset`, `max_depth`, `name/layer`.

- На Python-стороне использовать strict-типы: `StrictBool`, `StrictInt`, `FiniteFloat`/`Field(strict=True)`, а для `EntityId` исключить `bool` явно (`StrictInt` вместо `int`).

- Для T-07 переписать traversal как `collect_components_page(...) -> [page, total]`, чтобы не хранить все detailed entries. Если точный `total` слишком дорог, это надо явно решить в дизайне.

- Добавить серверные тесты на: один chunk с большим числом фреймов; slow-draining handshake rejection старше `PRE_HANDSHAKE_DEADLINE_S`; direct-TCP `limit > 500`, `max_depth > 10`, строковые/bool параметры.

- Для Ruby test stubs вынести общий support helper для `Sketchup`/`Geom`, чтобы не копировать глобальные классы по новым файлам.

### Questions

- `total` в `list/find_components` должен быть точным любой ценой, или допустим контракт с `total_known/estimated` ради UI-устойчивости?

- Нужно ли Python-схемам быть strict-зеркалом Ruby для всех параметров, или допустима клиентская коэрция строк/boolean?

- Empty string для `find_components(name/layer)` должен быть invalid params или "нет фильтра"?

- Финальная зачистка `docs/superpowers/`: нужно удалить только tracked файлы из PR-диффа или физически вычистить и untracked prompt-файлы из рабочего дерева?

---

## ext-claude-executor (alibaba/qwen, qwen3.7-plus)

План проверен against кодовой базой: базовые числа тестов (Ruby 354/939, Python 136), якоря на методы, структуры except'ов, wire-pin таблица, NAMED_COLORS, existing helpers — в целом сходятся. План самодостаточен и в значительной степени корректен. Ниже — проблемы, которые я нашёл.

### Critical Issues

**C1. `EntityId = int | Annotated[str, Field(min_length=1)]` — неверифицированная регистрация схемы (Task 5, T-06)**

План использует Pydantic v2 union-тип для id-параметров. FastMCP генерирует из неё JSON Schema. Pydantic v2 превращает такой Union в `anyOf: [{type: integer}, {type: string, minLength: 1}]`, но **FastMCP может**:
- (a) зарегистрировать схему как есть,
- (b) отвергнуть union и зарегистрировать `{}`,
- (c) зарегистрировать, но LLM не поймёт `anyOf`.

В плане нет RED-теста, который проверял бы корректность схемы после изменения. `test_entity_id_accepts_int_and_forwards_as_str` проверяет валидацию, но не схему.

**Решение**: добавить тест `test_entity_id_schema_has_int_and_string_variants`, который читает `tool.inputSchema["properties"]["id"]` и проверяет `anyOf`. Либо экспериментально проверить до написания кода.

**C2. `-> list[Image | str]` для `get_viewport_screenshot` может не работать с FastMCP (Task 9, T-28)**

Текущая аннотация `-> Image`. План меняет на `-> list[Image | str]`. FastMCP ожидает либо `Image`, `str`, либо `list[ImageContent | TextContent]` (из `mcp.types`). Возврат Python `[Image, str]` (где `str` — обычная строка, не `TextContent`) может:
- (a) сконвертировать `str` в `TextContent` автоматически,
- (b) упасть при сериализации.

План упоминает fallback `-> list`, но это не решает проблему конвертации `str` → `TextContent`.

**Решение**: экспериментально проверить ДО commit. Если не работает — использовать `mcp.types.TextContent(text=meta_json)` вместо `str`, либо возвращать через `_raw_call` с готовым MCP-конвертом.

**C3. Тройное дублирование логики `bb.min.x > bb.max.x` (Task 8, T-55)**

План вводит `Model.bbox_mm_or_nil(bb)` как хелпер в `handlers/model.rb`, но:
- `handlers/model.rb::describe_component` — inline-условие (3a),
- `handlers/model.rb::get_model_info` — через хелпер (2b),
- `handlers/geometry.rb::describe_entity` — inline-условие (Step 3), не вызывает хелпер.

Два из трёх сайтов дублируют логику вместо использования хелпера. Если один сайт изменит условие (например, добавит epsilon или проверит `bb.valid?`), другие продолжат отдавать сентинел.

**Решение**: использовать `bbox_mm_or_nil` во всех трёх местах. Либо вынести предикат в `Helpers::Geometry.empty_bbox?(bb)` и использовать его единообразно.

**C4. Нет инвентаризации маинтейнерских заметок перед T-05 (Task 15)**

Тест `test_no_internal_notes_leak_into_llm_visible_text` ищет «Ruby tool name» и «pydantic» в описаниях. Но план не приводит инвентаризацию заметок — какие именно заметки сейчас в докстрингах. Без этого исполнитель будет гадать, что именно переносить в `#`-комментарии.

**Решение**: добавить шаг 0 в Task 15: `grep -n "Ruby tool name\|Pydantic\|pydantic\|NOTE:\|TODO:\|Note:\|Note on" src/sketchup_mcp/tools.py`. Список — в комментарий к задаче.

**C5. Wire-pin для `create_component` использует `[1, 1, 1]`, но план добавляет Python-constraint `ge=1.0` (Task 13, MR-2)**

В `tests/test_tools.py:184-185`: `("create_component", {..., "dimensions": [1, 1, 1]}, ...)`. После MR-2 элементы `dimensions` — `Field(ge=1.0)`. Значение `1 == 1.0` в Python (и в Pydantic-валидации). Тест пройдёт. Но стоит явно зафиксировать в плане, что `1` (int) проходит `Field(ge=1.0)` — Pydantic v2 coerces int → float. Не критично.

**C6. Тест `test_schema_rejects_submillimeter_dimension` и граница `[1, 1, 1]` (Task 13, MR-2)**

`1.0 >= 1.0` — проходит; Pydantic принимает и int, и float. По факту ок — замечание о границе.

### Concerns (24 верификационных прохода; содержательные ниже)

**W1.** `dispatch_conn` fixture (Task 4) — патч `sketchup_mcp.tools.get_connection` через AsyncMock корректен, но mock возвращает один и тот же `conn` на все вызовы — может стать проблемой для тестов, проверяющих состояние `conn` после вызова.

**W2.** Task 10 (T-13.2) — взаимодействие `FRAME_QUEUE_SOFT_MAX = 256` и `DISPATCH_MAX_PER_TICK = 50`: корректный backpressure, но связку двух капов стоит задокументировать (возможны неожиданные паузы в обработке).

**W3.** Task 7 (T-07): `find_component_by_id` — `ensure seen.delete(def_id)` — семантика идентична `collect_components` (model.rb:79-91). Ок.

**W4.** Task 7 (T-07): `LOOKUP_MAX_DEPTH = 64` уже существует (model.rb:18) — план не упоминает; стоит явно указать.

**W5.** Task 11 (T-15): тест `test_other_export_hashes_unchanged` проверяет dae/stl, но не пинит остальные ключи `export_obj` (triangulated_faces, edges, texture_maps).

**W6.** Task 13 (T-17): `scale&.each_with_index` при отсутствии scale — no-op; Python-зеркало с `AfterValidator` после базовой валидации — ок.

**W7.** Task 13 (T-17): `test_dovetail_angle_at_60_passes_validation` использует `NoMethodError` как сигнал «валидация прошла» — хрупкий паттерн: если валидация сдвинется после `E.active_model!`, тест станет ложно-зелёным. Лучше явный сигнал (`raise "validation passed"` в stub).

**W8.** Task 6 (T-50): mutable default `[100, 100, 100]` — Pydantic v2 копирует default при каждом вызове, ок; прямой вызов мимо Pydantic получил бы общий список (маловероятно).

**W9–W24.** Верификационные проходы по T-13.3/13.4/13.5 (head_frame_remaining, overflow guard — логика корректна, монотонные часы), T-07 (paginate `slice(offset, limit) || []` ок), T-16 (make_unique на Group в SU2026 ок), T-25/T-29 (якоря README/CLAUDE.md/pyproject сходятся), T-21 (flip-проверка работает), T-22 (Literal-валидация ок), T-13.1 (JSON::ParserError → close_after_response взаимодействие корректно) — все с вердиктом «Ок», расхождений с кодовой базой не найдено.

### Suggestions

**S1.** Task 15 — шаг 0 с grep-инвентаризацией заметок (см. C4).

**S2.** Task 8 — вынести предикат `empty_bbox?(bb)` в `Helpers::Geometry` и использовать во всех трёх местах (см. C3).

**S3.** Task 5 — явный тест JSON Schema для EntityId (`anyOf` в `inputSchema["properties"]["id"]`, см. C1).

**S4.** Task 11 — расширить пин до всех ключей obj-экспорта:
```ruby
def test_obj_uses_all_official_keys
  model = OptionsCapture.new
  X.export_obj(model, "/tmp/x.obj")
  expected = { triangulated_faces: true, doublesided_faces: true,
               edges: false, texture_maps: true }
  assert_equal expected, model.last_options
end
```

**S5.** Task 9 — экспериментальная проверка `-> list[Image | str]` однострочником с FastMCP до написания кода; если регистрация падает — `TextContent` из `mcp.types` (см. C2).

**S6.** Task 7 — упомянуть в плане, что `LOOKUP_MAX_DEPTH` уже существует (model.rb:18).

**S7.** Task 13 — явный сигнал в dovetail-тесте вместо `NoMethodError` (см. W7).

### Questions

**Q1.** Task 12 (T-16): `make_unique` для plain (нескопированного) Group — no-op или что-то делает? Нужен ли отдельный тест для plain Group?

**Q2.** Task 9 (T-28): точный состав `meta`-JSON — только `{width, height, preset_used, style_used}` или включать другие поля из view.rb (camera, style_name)?

**Q3.** Task 7 (T-07): почему `response_format: "concise"` не включает `layer`? Полезно и почти не утяжеляет ответ.

**Q4.** Task 10 (T-13.2): почему именно `DISPATCH_MAX_PER_TICK = 50`? Эмпирика или расчёт?

**Q5.** Task 10 (T-13.5): почему `PRE_HANDSHAKE_DEADLINE_S = 30.0`? Для медленных клиентов (WAN) может быть мало.

**Q6.** Task 8 (T-55): как LLM должен реагировать на `bbox_mm = null`? Нужна ли инструкция в prompts.py для этого случая?

**Q7.** Task 15 (T-05): оверхол 22 тулов задан общими правилами; нужна ли декомпозиция на подзадачи (по ~5 тулов)?

**Q8.** Task 13 (T-17): Python-constraints (ge/le) и Ruby-валидация — полное зеркалирование или Python только для ранних ошибок, а Ruby — окончательная инстанция?

### Итог ревьюера

Главные проблемы: (1) Union-типы (EntityId, `list[Image | str]`) требуют экспериментальной проверки перед кодом; (2) дублирование empty-bbox логики — нужен общий хелпер; (3) нет инвентаризации маинтейнерских заметок — нужен шаг 0 в Task 15. Рекомендация: исправить C1–C3 до начала реализации, остальное по ходу.

---

## ext-claude-executor (deepseek/v4-pro)

### Верификация утверждений плана против реального кода

**Базлайны тестов — ТОЧНО.** 136 passed (Python), 354 runs / 939 assertions (Ruby) — подтверждено прогоном.

**Файловая структура — полная.** Все 47+ файлов, упомянутых в плане, существуют. Ни одного отсутствующего.

**Итог верификации: 27/27 утверждений плана о текущем состоянии кода соответствуют действительности** (config.py без валидации; partial-EOF ветки connection.py:326-335; нет `except OSError`; 22 `@mcp.tool()`; `dimensions=[1,1,1]`; TypeAdapter-зеркала tests/test_tools.py:135-177; `[project.entry-points.mcp]`; фантомные примеры README:137-138; «stdlib only» README:174; «Start» README:48,194; `.gemini/` нет в .gitignore; `sketchup-mcp` в server.py:11; `double_sided_faces:` export.rb:73; msg_python_too_new без pip-отката; 2×`defined?(Logger)` config.rb:73,89; отсутствие paginate/DEFAULT_LIMIT/find_component_by_id/optional_int_nonneg/optional_enum/optional_number/optional_string/mutable_entity_collection; ссылка на CLAUDE.md в helpers/geometry.rb:9; `Time.now` server.rb:340,385; отсутствие DISPATCH_MAX_PER_TICK/FRAME_QUEUE_SOFT_MAX/PRE_HANDSHAKE_DEADLINE_S/close_reason/head_frame_remaining/connected_at; translation-only test_joints_frame_compensation.rb:15-16; ScriptError-тесты в test_dispatch_post_handshake.rb; уехавшая ссылка settings_dialog.rb:104; наличие pick_color/filter_edges/closest_face). Ни одного ложного утверждения.

### Critical Issues

**CI-1: Формула полярной хорды сферы — пограничный false negative**

Формула `2·r·sin²(π/N)` для хорды первого полярного кольца верна. НО: при `d = 0.03"` (0.762 мм) и segments=16 полярная хорда ≈ 0.029 мм — проходит по грани порога 0.03, НЕ отклоняется, хотя сфера диаметром 0.762 мм при 16 сегментах геометрически вырождена (merge-tolerance SketchUp = 0.0254 мм). **Рекомендация:** поднять `MIN_POLAR_CHORD_MM` до 0.04 мм (~1.6× merge-tolerance) или добавить комбинированную проверку.

**CI-2: `get_viewport_screenshot` в `_RETRY_SAFE_TOOLS` — семантически не read-only**

Тул меняет viewport (camera, rendering options) и восстанавливает их в ensure-блоке Ruby-хендлера. Retry безопасен для данных, но повторный вызов дёрнет камеру дважды — UX-деградация (мерцание). **Рекомендация:** либо исключить из whitelist (перестраховка), либо задокументировать в докстринге (Task 15): «may briefly flicker the viewport if the server reconnects mid-response». Текущий план этого не делает.

**CI-3: Task 10 (T-13.3) — модификация констант через `remove_const`/`const_set` — риск в run_all.rb**

`with_pending_write_cap` мутирует `Server::PENDING_WRITE_MAX_BYTES` через remove_const/const_set. В едином процессе run_all.rb тест, упавший ДО ensure, оставит класс с мутированной константой — все последующие тесты получат испорченное значение. Также генерируются warning'и о переопределении констант. **Рекомендация:** перепроектировать (instance variable / class_variable / dependency injection), либо принять риск осознанно.

**CI-4: Task 11 Step 4 (T-27) — стабы test_export_skp.rb**

План не показывает, что тестовый файл уже определяет пустые стабы модулей ДО require export.rb — без них require упадёт на NameError. **Рекомендация:** явно указать в Step 4a наличие/добавление module-stubs (файл их уже определяет — сверить).

**CI-5: Task 8 (T-55) — предупреждение про test_transform_absolute.rb ложное**

`test_transform_absolute.rb` НЕ содержит упоминаний `describe_entity` — grep пуст. Source-guard пинит `transform_component`, не `describe_entity`. Ложная тревога плана. Реальный риск — `test_operation_names.rb` (пинит operation handlers — T-16 меняет `entity_collection` → `mutable_entity_collection` внутри `run_edge_op`). **Рекомендация:** убрать вводящее в заблуждение предупреждение; проверить `test_operation_names.rb` в Task 12 вместо этого.

### Concerns

**CONCERN-1: T-13 — 5 подфиксов в одной задаче = высокий риск конфликтов**

Все 5 правят server.rb и client_state.rb. Конфликт T-13.1/T-13.2 в `process_frame_queue` план разруливает корректно (новая версия включает guard `close_after_response`), но сложность интеграции 5 правок в 2 файла остаётся высокой — легко пропустить нюанс при merge review. Риск умеренный, управляется атомарными коммитами.

**CONCERN-2: Task 7 — `response_format: "concise"` вырезает `layer`**

Причина не объяснена. Если модель ищет «все entities на Layer0» через concise — она не увидит layer. Дизайн-решение не обосновано. **Рекомендация:** добавить `layer` в concise-набор или обосновать исключение.

**CONCERN-3: Task 13 (T-17) — валидация scale не работает для eval_ruby**

`eval_ruby` — сознательный escape hatch без валидации. Стоит упомянуть в докстринге transform_component (Task 15).

**CONCERN-4: MR-3 rotated-board тест — FakeAffineZ валидирует ЛОГИКУ, не арифметику**

Точная целочисленная алгебра поворотов 0/90/180/270 доказывает корректность алгоритма компенсации T⁻¹, но не покрывает накопление float-ошибок реального `Geom::Transformation`. Сознательное ограничение — стоит отметить.

**CONCERN-5: Task 15 — оверхол 22 докстрингов трудно ревьюить**

Тесты `test_tool_descriptions.py` проверяют ФОРМУ (описания есть, units упомянуты), не СОДЕРЖАНИЕ (правильность Returns-строк). Неправильная форма ответа в докстринге пройдёт тесты. **Рекомендация:** добавить content-пины Returns-строк хотя бы для топ-5 тулов.

### Suggestions

**SUGG-1:** Разбить T-13 на 5 отдельных задач (Tasks 10a–10e) для чистой трассировки коммитов.

**SUGG-2:** Автоматизировать flip-проверки discriminator-тестов (`git diff --exit-code` после каждого flip как guard от забытого checkout).

**SUGG-3:** Task 9 — вместо `list[Image | str]` вернуть MCP content types: FastMCP конвертирует `Image` в `ImageContent` автоматически; строку обернуть в `TextContent(type="text", text=meta_json)`. Структурно чище и гарантированно работает.

**SUGG-4:** Task 8 (T-55) — **silent gap в плане**: Python-сторона. Если какая-то Python-логика парсит `bbox_mm` как dict, `null` её сломает. Проверить, что Python-обёртки прозрачно пробрасывают JSON (они возвращают текст — влияния нет), но докстринги обязаны сказать «bbox_mm may be null» (Task 15 это делает). Явно зафиксировать отсутствие Python-валидации форм ответов.

**SUGG-5:** Task 7 — `get_component_info` fallback `describe_component(entity)` при глубине >64 возвращает bbox в parent-frame без world-коррекции — деградация точности для глубоко вложенных entity, не помеченная в ответе. Рассмотреть флаг/warning.

### Questions

**Q-1:** Почему `DISPATCH_MAX_PER_TICK = 50` не вычисляется из `READ_MAX_ITERATIONS` (50 per-client reads × 64 клиента >> 50 dispatch)? Значения 50/256 — эмпирика?

**Q-2:** `response_format: "concise"` — сознательное исключение `layer` или oversight?

**Q-3:** Task 12 (T-16): «скопированные Group» — что имеется в виду? Copy-paste группы в SketchUp шарит definition до первого редактирования (make_unique уместен), но формулировка неточна. Прояснить семантику make_unique для Group vs ComponentInstance.

**Q-4:** Почему concise оставляет `depth`, но вырезает `layer`? Кажется произвольным.

### Итоговая оценка

**Качество дизайна:** высокое. **Качество плана:** очень высокое — 0 фактических ошибок в утверждениях о коде на 3734 строки документа. Главные риски: T-13 (интеграция 5 правок), contract break форм ответов (T-07/T-08/T-28), T-16 source-guard'ы (проверять test_operation_names.rb, а не test_transform_absolute.rb). Рекомендуемые действия до старта: поднять порог хорды (CI-1), перепроектировать remove_const-тест (CI-3), закрыть SUGG-4, прояснить Q-2/Q-3.

---

## builtin claude (rev-claude, Fable)

Метод: оба документа прочитаны целиком; утверждения сверены с кодом (src/sketchup_mcp/, mcp_for_sketchup/, test/, tests/); базлайны воспроизведены (Python 136 passed; Ruby 354 runs / 939 assertions / 0 failures). Подавляющее большинство якорей плана точны: сигнатуры carve_* (9/8 аргументов), require_id парсит int и str, все 4 мутирующих call-site'а entity_collection найдены верно, лейблы меню, фантомные examples, entry-points, счётчики-суммы Python (136→172) и Ruby (+57≈411), пины source-guard'ов не задеваются, RED-прогнозы Task 2/3/6/7/11/13 корректны. Ниже — только проблемы.

### Critical Issues

1. **Task 10 / T-13.3 — ложный прогноз для существующего overflow-теста.** `test/test_server_multi_client.rb:408` (`test_pending_write_overflow_closes_client`) кладёт `near = "x" * (cap - 64)` прямым `state.append_pending_write(near)` на ПУСТОЙ буфер. После введения `head_frame_remaining` эти байты станут head-фреймом: `tail_backlog = backlog − head = 0`, `projected ≈ 250 байт < cap` — новый guard не сработает, `assert sock.closed?` упадёт. Основная ветка Step 6 («существующий тест обязан остаться зелёным: он набивает хвост при живом head — семантика сохранена») фактически неверна: тест набивает именно head. Нужно прямо предписать переработку теста (например, малый head через write_response при занятом сокете + большой прямой append хвоста), иначе исполнитель получит противоречие «обязан остаться зелёным» vs красный прогон.

2. **Task 1 / T-12 — битый caplog-ассерт в готовом коде теста + неверные per-file счётчики.** (а) `any("SKETCHUP_MCP_LOG_LEVEL" in r.message % r.args ...)`: LogCaptureHandler pytest'а форматирует record при emit (`record.message = record.getMessage()`), поэтому к моменту ассерта `r.message` — уже готовая строка без плейсхолдеров, а `r.args` непусты → `%` кинет `TypeError: not all arguments converted`. Нужно `r.getMessage()`. Ирония: ⚠-примечание плана обосновывает именно эту конструкцию. (б) В `tests/test_config.py` сейчас **5** тестов, а не 6: прогноз Step 2 «10 failed, 7 passed» на деле «10 failed, 6 passed», Step 4 «17 passed» → 16 (глобальные 147 верны, т.к. считаются от 136). План сам предписывает «СТОП при несоответствии RED-прогнозу» — эти числа гарантируют ложный стоп.

3. **Task 15 / T-05 — внутреннее противоречие: тест требует units в export_scene, а «точный» докстринг их не содержит.** `test_dimension_tools_mention_units` включает `export_scene` в список тулов, обязанных упоминать «mm»/«millimeter», но приведённый планом дословный текст докстринга export_scene не содержит ни того, ни другого (только «1920×1080» — пиксели). С предписанными текстами тест красный. Либо исключить export_scene из списка (линейных мм-параметров у него нет), либо дописать units — решить в плане, а не на лету.

### Concerns

1. **Полнота T-16.** make_unique ставится в 4 call-site'а `entity_collection` (materials.rb:80, joints.rb:226, joints.rb:288, operations.rb:159) — это все мутирующие точки entity_collection, сверено. Но мутации шаренной геометрии идут и мимо неё: `boolean_operation` и `place_mortise`/carve-цепочки режут через `subtract` на самих Group/ComponentInstance. Если SketchUp при solid-операции над инстансом шаренной definition сам не делает make_unique, «4 стула режутся разом» останется для boolean_operation — мотивация тикета закрыта частично. Минимум — зафиксировать границу в докстрингах (T-05).

2. **Task 16 Step 1 порождает дубликат.** README:135-136 УЖЕ содержат корректные строки про `smoke_check.py`/`smoke_multi_client.py`; инструкция «удалить :137-138… Вместо них: [те же две строки]» даст задвоение. Правильное действие — только удалить :137-138 (замена в CLAUDE.md корректна).

3. **T-23.3 наполовину дублирует существующее покрытие.** `test/test_dispatch_post_handshake.rb:243` (`test_dispatch_returns_error_envelope_for_script_error_from_any_handler`) уже проверяет ScriptError-arm (-32603 + id). Новый `test_handler_script_error_arm_produces_minus_32603` — почти дубликат; реальную дыру закрывает только StandardError-тест. Обоснование задачи «error-paths не покрыты» частично устарело.

4. **Глобальный backpressure T-13.2 стопорит чтение всех клиентов.** Guard `@frame_queue.length >= FRAME_QUEUE_SOFT_MAX` в начале drain_reads_all_clients: один клиент, накачавший 256 фреймов, останавливает чтение из ВСЕХ сокетов, а проверка выполняется раз за тик — очередь может уйти сильно выше soft-max за один тик (READ_MAX_ITERATIONS×64 KiB×N клиентов). При глобальном FIFO консистентно, но деградацию fairness и «однопроверочность» стоит явно проговорить в комментарии.

5. **T-07: заявленный «limit (1..500)» на Ruby-стороне не enforced.** Python — `Field(le=500)`, Ruby — `optional_int_positive` без верхней границы: клиент мимо Python-обёртки может запросить limit=10^9. Зеркальность (как в T-17) неполная.

### Suggestions

1. **T-28:** проверить поведение FastMCP (mcp 1.27) с аннотацией `-> list[Image | str]` одной быстрой пробой ДО исполнения, а не через «pytest упал на импорте — тогда fallback `-> list:`».
2. **Task 8:** сверка показала, что `describe_entity` не пинится ни одним source-guard'ом (test_transform_absolute пинит только `position_delta` внутри transform_component; test_operation_names — лейблы операций и subtract-паттерны). Предупреждение Step 3 «если пинит — обновить пин» можно заменить констатацией, чтобы исполнитель не искал несуществующие пины.
3. **T-11:** в тест raw-OSError добавить комментарий, почему выбран именно EHOSTUNREACH — `OSError(errno, …)` для ECONNRESET/EPIPE авто-инстанцирует подклассы ConnectionError, и «более привычный» errno при будущем рефакторе молча перестал бы тестировать голую OSError-ветку.
4. **Пакет мелких неточностей формулировок:** (a) Task 5 Files: «11 тулов с id-параметрами» — фактически 10 тулов / 14 параметров (таблица плана сама на 10 строк); (b) Task 12: строка `cur_edges = E.entity_collection(entity)` находится не «ниже» в `run_edge_op`, а в другом методе — `find_current_edge_spec` (operations.rb:254); (c) T-14: имя дополняемого теста `test_too_new_raises_with_reinstall_hint` после фикса станет вводить в заблуждение — суть меняется на «НЕ reinstall»; (d) MR-3: комментарий фейка «мировой bbox x 30..34» алгебраически не согласован с заданной трансформацией (R90 + dx=30 для локального 0..4×0..4 даёт мировой x 26..30) — на валидность проверки компенсации не влияет (bounds и transformation в тесте независимы), но «легенду» фейка стоит поправить.
5. **MR-1:** отметить в комментарии `_RETRY_SAFE_TOOLS`, что после MR-1 обрыв посреди ~43 MiB скриншот-кадра приведёт ко второму полному захвату и передаче — безопасно, но дорого; это осознанная цена.

### Questions

1. **T-16:** резка через `subtract` (boolean_operation, place_mortise) вне скоупа осознанно? Если да — где это ограничение фиксируется для пользователя (докстринги T-05 сейчас его не упоминают)?
2. **MR-2:** floor 1.0 мм на всех осях всех типов запрещает легитимные тонкие детали (шпон/лист 0.5–0.8 мм) через типизированный тул, оставляя только eval_ruby. Осознанный трейд-офф, или floor стоит опустить ближе к 2× merge-tolerance (~0.06 мм), раз вырождение сфер и так ловится polar-chord-формулой?
3. **T-13.2:** чем обоснованы DISPATCH_MAX_PER_TICK=50 и FRAME_QUEUE_SOFT_MAX=256 при TIMER_INTERVAL=0.1 с (потолок диспатча ~500 фреймов/с, окно разгрузки очереди ~0.5 с)? Числа стоит увязать с READ_MAX_ITERATIONS в комментарии.
4. **T-07:** concise-режим отбрасывает и `layer` — осознанно? Фильтрация по слою — частый сценарий, а поле дешёвое.
5. **T-28:** проверялась ли реакция целевых MCP-клиентов (Claude Desktop / Claude Code) на пару [ImageContent, TextContent] из одного тула — некоторые клиенты отображают только первый блок?

---

## ext-claude-executor (zai/glm, glm-5.2) — ЧАСТИЧНО

> Прогон оборван обрывом стрима на ~15-й минуте; финального ревью в формате Critical/Concerns/Suggestions/Questions нет. Ниже — содержательные находки из фактчекинг-фазы (лог прогона); повторный прогон на момент merge не завершён.

- ⚠ **Расположение тестов:** Ruby-тесты живут в repo-root `test/`, НЕ в `mcp_for_sketchup/test/` — ссылки плана должны использовать корневой путь (план в основном это соблюдает).
- ⚠ **Базлайн 354/939:** grep по `def test_` находит 340 методов — счётчик CLAUDE.md может быть стар; перед использованием как regression-gate перепрогнать `ruby test/run_all.rb` (прогон в среде ревью был недоступен — permission denied). [NB: grep ≠ runs — параметризация/наследование.]
- ✅ **T-19 подтверждён как латентный баг:** `defined?(Logger)` в config.rb при загруженном stdlib `logger` и незагруженном `Core::Logger` резолвится в `::Logger` → `NoMethodError` на `.log`; в продакшене замаскирован порядком загрузки main.rb (core/logger до load_from_defaults!). Standalone-тест плана дискриминирует баг корректно.
- ✅ **Существующий overflow-тест** (`test_pending_write_overflow_closes_client`) набивает буфер raw-байтами с запасом 64 байта >> 4-байтового заголовка — он пройдёт и под старой, и под новой формулой T-13.3, т.е. НЕ дискриминирует вычет head (обновление его ассертов не потребуется — но и доказательной силы к T-13.3 он не добавляет).
- ✅ Остальные структурные утверждения плана (server.rb константы, тела методов, ClientState-атрибуты, compat-строки, config-guard'ы, FakeSocket API — `stub_write_pending(times:)`, `stub_partial_write(max_bytes_per_call:, calls:)`, `read_chunks:`, 3×`Time.now` в test_server_multi_client.rb:379,422,479, `READ_MAX_ITERATIONS`) — совпадают с кодом.

---

## ext-claude-executor (ollama/minimax, MiniMax M3) — ЧАСТИЧНО (выжимка)

> Финального ревью НЕТ — контекстный лимит («Prompt is too long», 8.1M входных токенов). Ниже — выжимка СОБСТВЕННЫХ промежуточных находок minimax из логов прогона (модель успела верифицировать план по коду и начать черновик отчёта, оборванный на середине Suggestions; Questions не дописаны). «OK»-пункты отфильтрованы.

### Critical Issues (по оценке minimax)

1. **T-13.3 — неверная диагностика бага, ложный RED.** В core/server.rb:331 УЖЕ стоит guard `if backlog > 0 && projected > PENDING_WRITE_MAX_BYTES` — head-фрейм на пустой буфер уже допускается, и это уже запинено тестом `test_single_oversized_frame_on_empty_buffer_is_not_overflow` (test/test_server_multi_client.rb:435). Утверждение дизайна «один легитимный >16 MiB ответ плюс ЛЮБОЙ следующий фрейм закрывают соединение» не соответствует коду. Реальная проблема тоньше: пока head дренируется, ВЕСЬ backlog (head+tail) считается против капа. Логика `head_frame_remaining`/`tail_backlog` — валидная НОВАЯ функциональность, но RED-тест в формулировке плана не дискриминирует. Предложение: переформулировать RED — набить 16 MiB+ head на пустой буфер, задать `stub_partial_write(max_bytes_per_call: 10, calls: 1)` (медленный дренаж), положить малый tail-фрейм: текущий код закрывает клиента, новый должен допускать.

2. **T-19 — RED-тест не дискриминирует баг.** Тест `test_invalid_pref_fallback_survives_stdlib_logger_in_namespace` (Task 11 Step 3) уже пройдёт на текущем коде: `valid_port?("not-a-port")` → false → `warn_invalid_pref` → fallback 9876, и `assert port == 9876` зелёный до фикса. Тест не различает stdlib `::Logger` vs `Core::Logger`. Плюс риск порядка загрузки: под run_all.rb `Core::Logger` уже загружен другими тестами → `defined?(Core::Logger)` = true, RED не гарантирован. Предложение: изолированный тест, который грузит ТОЛЬКО core/config.rb (без core/logger.rb), делает `require "logger"` (stdlib) и проверяет, что `warn_invalid_pref` не падает (у stdlib Logger нет `.log`).

3. **T-21 — flip-проверка дискриминативности, по мнению minimax, не даст FAIL без importlib.reload:** compat.py биндит `from sketchup_mcp import __version__ as CLIENT_VERSION` при загрузке модуля, sed на `__init__.py` сам по себе не меняет compat.CLIENT_VERSION, а `version("sketchup-mcp2")` продолжает отдавать 0.2.0 из непересобранного dist-info → тест PASSES, ворота «Если flip НЕ дал провала — СТОП» сработают зря. Предложение: явно добавить reload в план. [См. примечание составителя внизу — вероятно, ЛОЖНОЕ: flip-прогон — новый процесс.]

4. **MR-1 (Task 3 Step 4a) — план ассертит текст `"NOT auto-retried"`, а реальный текст обогащённой ошибки в connection.py — `"do NOT retry"` (verified).** Тест из плана не пройдёт; сменить assertion на `"do NOT retry"` (менять текст в connection.py — хуже).

5. **T-23.2 — CountingSocket из плана сломан:** `def initialize(*args, **kwargs); super; ...` — но `FakeSocket#initialize` принимает только required kwargs (`read_chunks:`, `peer:`), голый super без разворота упадёт. Нужно `def initialize(**kwargs); super(**kwargs); @reads = 0; end`.

6. **MR-3 — проверка дискриминативности «временно заменить `acc.compose(inst[:transformation])` на `acc` — оба теста обязаны УПАСТЬ» ошибочна:** без compose acc уже содержит T_board, точки вычисляются в мировой системе доски (30..34, внутри bbox) — тест НЕ упадёт. Формулировать как «пропуск компенсации T_inst» (identity-композиция), а не «заменить на acc».

### Расхождения счётчиков и якорей

7. `tests/test_config.py` содержит **5** существующих тестов, а не 6 → после T-12 будет **16 passed**, а не «17 passed (6 старых + 11 новых)» (Task 1).
8. Task 17: ориентир «~411 runs (354 + ~57 новых)» завышен — пересчёт по задачам даёт ~47–50 новых Ruby-тестов.
9. `test_send_command_parse_error_disconnects` — реально tests/test_connection.py:97, план говорит «~строка 106».
10. Дизайн T-16 ссылается на пины `place_tenon`/`add_parent_frame_prototype`, но test_joints_frame_compensation.rb реально пинит `carve_board2_slots` (строки 236–251). На T-16 это не влияет (carve_board2_slots не модифицируется), но ссылка в дизайне неточна.

### Concerns

11. **T-23.3 — `test_handler_script_error_arm_produces_minus_32603` уже зелёный:** arm `rescue ScriptError, SystemStackError` существует (dispatch.rb:52-58). Это gap-filling, не RED — план должен говорить это явно; то же для T-23.1/T-23.2/T-23.4 (добавить «expected: PASS on existing code»).
12. **T-15 — сверка dae `triangulated_faces` и stl `units: "model"` оставлена «на веру»** без пин-теста; раз уж создаётся test_export_options.rb — добавить туда ассерты и для них. [NB составителя: тест `test_other_export_hashes_unchanged` в плане их пинит — сверить при обсуждении.]
13. **T-05 — конкретные тексты докстрингов даны только для ~8 из 22 тулов,** остальные 14 — только общие правила → риск непоследовательности; приложить полные тексты Returns.
14. **T-13.2 — тест read-backpressure хрупок:** результат зависит от соотношения DISPATCH_MAX_PER_TICK=50 и FRAME_QUEUE_SOFT_MAX=256 между тиками (dummy-фреймы дренируются по 50/тик). Сценарий сходится, но fragile.
15. **T-15/T-22 — leak-тест ищет подстроки "Ruby tool name" и "pydantic":** новые докстринги T-05/T-15 не должны случайно их содержать (например, слово «Pydantic» в новых текстах уронит тест).
16. **T-13.5 — план не описывает взаимодействие pre-handshake deadline с MAX_CLIENTS:** до 64 неактивных pre-handshake клиентов занимают слоты до 30-сек таймаута.

### Suggestions

17. После T-54 добавить в prompts.py §3 пункт: create_component принимает optional name — используйте его, чтобы find_components мог находить сущность по имени.
18. T-22 — добавить тест `test_transform_component_full_combination` (position+rotation+scale одновременно) для укрепления wire-pin.

### Questions (не дописаны моделью; из открытых нитей анализа)

19. T-23.4 — поведение `OPS.filter_edges` с несуществующими индексами (план ожидает `filter_edges(edges, [0, 99]) == ["e0"]` — «молча пропущен») осталось непроверенным по реальному коду operations.rb. [NB составителя: последний tool-вызов прогона перед обрывом прочитал operations.rb — `edges.select.with_index { |_, i| indices.include?(i) }` — ожидание плана подтверждается.]

> **Примечание составителя выжимки (агент rev-ollama-minimax, не находка модели):** пункт 3 (T-21) может быть ложным — flip-проверка в плане запускает НОВЫЙ процесс `uv run pytest`, где модули загружаются с диска заново (CLIENT_VERSION = 9.9.9), а dist-info editable-инсталла остаётся 0.2.0 → тест, скорее всего, упадёт как и задумано. Рассуждение minimax про «замыкание импорта» применимо только внутри одного процесса без reload. Перепроверить при обсуждении.

---

## Сбои (для полноты картины)

- **ollama/kimi** — три прогона подряд оборваны обрывом стрима (48 с / 80 с / третий на момент merge не завершён). Результата нет.
