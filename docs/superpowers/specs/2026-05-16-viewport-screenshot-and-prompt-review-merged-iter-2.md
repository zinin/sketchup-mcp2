# Merged Design Review — Iteration 2

Documents reviewed:
- Design: `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-design.md`
- Plan: `docs/superpowers/plans/2026-05-16-viewport-screenshot-and-prompt-plan.md`

Review agents launched: codex-executor (gpt-5.5, xhigh), ccs-executor (glm), ollama-executor (kimi), ollama-executor (minimax), ollama-executor (deepseek).

**Reviewers that produced results:** codex, ccs/glm, ollama/deepseek.

**Reviewers that failed:**
- **ollama/kimi** — STALLED. Model performed ~50 tool-calls (read design/plan/source files, Bash, WebSearch on FastMCP `@mcp.prompt` API and SketchUp `View#write_image` compression) but never emitted the final assistant block with the four review sections. Upstream Ollama stream died silently between events 102 and 103.
- **ollama/minimax** — STALLED. Model emitted only 163 chars of Russian thinking-prefixes across 50 events, never the review body. Upstream Ollama daemon dropped the connection mid-stream at ~10 minutes; harness terminated without `result` event.

Given codex + ccs + deepseek all converged on the same critical issues (cookbook still contains rejected `send_action` and `DrawEdges` patterns; design §7.2 has obsolete test row), the three available reviews are sufficient for iter-2.

---

## codex-executor (gpt-5.5, xhigh)

### Critical Issues

**Неполный snapshot камеры ломает `restore_view=true`**
В design (line 223) и plan (line 1319) сохраняются только `eye/target/up`, `perspective`, `fov/height`. Но `Sketchup::Camera` также имеет `aspect_ratio`, `image_width`, двухточечный/match-photo режим (`is_2d?`, `center_2d`, `scale_2d`). Для таких камер restore может вернуть визуально другой viewport, нарушая обещание non-destructive default. Нужно либо полноценно проверить/копировать все восстанавливаемые свойства, либо явно детектить неподдерживаемые camera modes и документированно отказываться/упрощать поведение.

### Concerns

**Parallel projection не фреймится через distance**
В `build_preset_camera` (plan line 1404) distance считается от `bounds.diagonal`, но для orthographic камеры масштаб задаёт `height`, а не расстояние до target. Сейчас `height` просто копируется из текущей камеры, поэтому `view_preset="top"` без `zoom_extents=true` может дать cropped/пустой кадр. Добавить тест на `perspective=false` и задавать `height` из bbox/viewport aspect либо делать `zoom_extents` обязательной частью preset-framing.

**Большие ответы могут блокировать UI SketchUp**
Ruby-сервер single-threaded, но `write_response` делает blocking `@client.write(frame)` после одного `IO.select` (server.rb:143). При разрешённом raw PNG до 32 MiB итоговый JSON frame может быть десятки MiB; если клиент читает медленно, SketchUp UI может зависнуть внутри timer callback. Стоит либо снизить cap/`max_size`, либо писать большие ответы chunked/nonblocking, либо явно принять этот риск в §12.

**Часть Ruby tests может пройти при сломанном restore**
`test_camera_restored_after_zoom_extents_failure` (plan line 1072) вызывает failure без предварительного preset/style mutation, поэтому отсутствие restore всё равно оставит камеру "исходной". `test_camera_restored_when_flag_true` сравнивает только `eye`, не `target/up/perspective/fov/height/aspect`. Нужно сделать failure после реальной мутации и сравнивать полный camera snapshot.

**В документах остались следы `send_action` и старых RO keys**
Plan всё ещё говорит "send_action for preset" в file structure (line 26), design table всё ещё содержит `test_send_action_called_for_preset` (design line 543), а commit message в Task 6 снова пишет про `Sketchup.send_action` (plan line 1483). Cookbook snippet хуже: использует `Sketchup.send_action("viewIso:")` и `DrawEdges` (plan line 1649), хотя оба решения уже признаны неправильными. Надо вычистить, иначе исполнитель легко реализует или задокументирует старый broken path.

**Smoke step слабо проверяет реальный screenshot**
Task 7 вставляет screenshot перед cleanup, но hardcode `step = 21` (plan line 1520), тогда текущий smoke продолжит печатать cleanup как step 19/20. Кроме того, smoke проверяет только PNG magic header; handler, возвращающий валидный 1×1 PNG, пройдёт. Лучше перенумеровать cleanup/undo и assert'ить `width/height` плюс минимальный размер данных.

### Suggestions

**Не тестировать FastMCP `Image` через приватный `_format`**
В установленной версии `mcp.server.fastmcp.Image` нет публичного `format`, а плановый тест уже скатывается к `img._format` (plan line 444). Direct wrapper test пусть проверяет `Image` + bytes, а MIME/format проверяйте только через `mcp.call_tool(...) -> ImageContent.mimeType`.

**Prompt переобобщает ответы mutating tools**
В prompt сказано, что tools creating/modifying entities return `{id, name, type, bbox_mm}` (plan line 225). Это не верно для `delete_component`, `create_layer`, `undo`, и частично для selection с non-group entities. Лучше сузить формулировку до geometry/material/boolean/joinery/edge tools и сказать "when returned, use `bbox_mm`".

**Acceptance criteria не полностью покрыты задачами**
Acceptance требует callable through Claude Desktop returning MCP `Image` (design line 717), но live smoke идёт raw TCP, а FastMCP Image проверяется только mocked unit-тестом. Если это действительно acceptance, добавить ручной MCP-client/Claude Desktop check для tool; если нет, сузить критерий до "unit FastMCP serialization + live Ruby smoke".

### Questions

**Какая реальная матрица SketchUp versions?**
RenderMode/camera/RO поведение проверено только на SketchUp 2026, а repo местами говорит SketchUp 2024+ или номинально 2017+. Нужно явно решить: эта фича targets 2026 only, 2024+, или весь старый диапазон?

**Что ожидается для fixed aspect / two-point / match-photo cameras?**
Должен ли `restore_view=true` сохранять такие viewport states побитово визуально, или допустимо сбрасывать их к обычной Camera? От ответа зависит, нужен ли fail-fast guard для `camera.is_2d?`/fixed aspect.

**Preset framing должен учитывать hidden geometry?**
Direct camera строится по `model.bounds`, а screenshot при этом уважает hidden objects/tags. Если hidden/far geometry входит в bounds, видимая часть может стать мелкой; это ожидаемое "model extents" поведение или нужно frame'ить только видимое?

---

## ccs-executor (glm)

### Critical Issues

**C1. Cookbook-пример использует WRITE-REJECTED `rendering_options`-ключ**

Plan Task 9.1 добавляет в `docs/sketchup-ruby-cookbook.md` пример с `model.rendering_options["DrawEdges"] = true`. Однако в iter-1 эмпирически установлено, что `DrawEdges` — READONLY-ключ в SU 2026: запись вызывает `ArgumentError: Rendering option could not be set to the given value`. Кто угодно, скопировавший пример из cookbook в SketchUp 2026, получит краш. Нужно заменить на writeable-ключ — например `RenderMode`, аналогично продакшн-коду в `handlers/view.rb`.

**C2. Cookbook-пример использует асинхронный `send_action` для preset**

Тот же cookbook-пример применяет `Sketchup.send_action("viewIso:")` для переключения вида. Design §5.2 прямо говорит, что `send_action` — asynchronous в SU 2026, и хендлер переключён на прямое присваивание `view.camera = Sketchup::Camera.new(...)`. Cookbook учит паттерну, который дизайн сознательно отверг. Пример нужно переписать с прямым camera-присваиванием, как в продакшн-коде.

### Concerns

**CONC-1. `_raw_call` конвертирует `ConnectionError` → `SketchUpError`, создавая хрупкое обнаружение в `_call`**

Предложенный `_raw_call` переводит `ConnectionError` в `SketchUpError(-32000, "SketchUp not running: ...")`. Новый `_call` различает ошибки соединения от Ruby-ошибок через строковый поиск: `e.code == -32000 and "SketchUp not running" in (e.message or "")`. Это хрупко: если Ruby-сторона вернёт `StructuredError(-32000, "... SketchUp not running ...")` (например, при будущей проверке статуса расширения), он будет неверно распознан как connection error и обработан не через `format_error`, а как plain string. Чище: `_raw_call` не конвертирует `ConnectionError` вообще — пусть каждый caller (`_call` и screenshot-wrapper) ловит `ConnectionError` самостоятельно, каждый со своей стратегией.

**CONC-2. Мёртвый код во втором `except ConnectionError` в `_raw_call`**

Второй `except ConnectionError` в `_raw_call` (для `send_command`) недостижим: `send_command` в `connection.py` ловит все `ConnectionError` внутри `_send_once` и конвертирует их в `_StaleSocketError` (подкласс `SketchUpError`). Этот мёртвый код унаследован из текущего `_call`, но рефакторинг — хороший момент его удалить.

**CONC-3. Текст плана противоречит дизайну: ссылки на `send_action`**

- File Structure (раздел "Files to CREATE"): описание `handlers/view.rb` говорит "send_action for preset" — прямо противоречит §5.2 дизайна.
- Task 6.6 commit message: "optionally switches view_preset via Sketchup.send_action" — та же ошибка.

Обновить до "direct camera assignment via `view.camera = Camera.new(...)`".

**CONC-4. Дизайн §7.2 содержит устаревший тест `test_send_action_called_for_preset`**

Таблица §7.2 по-прежнему перечисляет `test_send_action_called_for_preset` с описанием "Spying on `Sketchup.send_action`, triggers exactly one `"viewIso:"`". Plan Task 5.1 корректно заменяет его на `test_camera_assigned_for_preset` (который проверяет прямое присваивание camera и что `send_action` НЕ вызывается). Но design и план не согласованы — может запутать будущего ревьюера.

**CONC-5. Изменение текста error message для существующих инструментов**

Текущий `_call` при connection error возвращает `"SketchUp not running or extension not started: {e}"`. После рефакторинга через `_raw_call` с `SketchUpError(-32000, "SketchUp not running: {e}")`, новый `_call` вернёт `"SketchUp not running: {e}"` — другой текст. Минимальное, но реальное изменение поведения для 22 существующих инструментов. Если CONC-1 решается через удаление конверсии в `_raw_call`, эта проблема исчезает.

**CONC-6. `test_screenshot_returns_image` обращается к приватному атрибуту `img._format`**

```python
assert getattr(img, "format", None) == "png" or img._format == "png"
```

Если `img` не имеет публичного `format` и не имеет `_format`, получим `AttributeError` вместо чистого `AssertionError`. Комментарий в тесте говорит "Public `format` attribute", но fallback на `_format` добавляет coupling с внутренностями FastMCP. Если `format` публичный — fallback не нужен; если нет — тест ненадёжен.

### Suggestions

**SUG-1. Упростить `_raw_call` — не конвертировать `ConnectionError`**

```python
async def _raw_call(ctx, tool_name, /, **kwargs) -> dict:
    sketchup = await get_connection()  # поднимает ConnectionError
    return await sketchup.send_command(tool_name, kwargs)  # поднимает SketchUpError
```

Тогда `_call` сохраняет точное текущее поведение:
```python
except ConnectionError as e:
    return f"SketchUp not running or extension not started: {e}"
except SketchUpError as e:
    return format_error(e, ...)
```

А screenshot wrapper добавляет свою конверсию:
```python
except ConnectionError as e:
    raise SketchUpError(-32000, f"SketchUp not running: {e}") from e
```

Это устраняет CONC-1, CONC-2 и CONC-5 одной правкой.

**SUG-2. Добавить guard для `Sketchup::View` в `run_all.rb`**

Хотя текущие тесты не конфликтуют при алфавитной загрузке (существующие файлы не определяют `Sketchup::Camera`/`Model`/`View`), будущее добавление таких стабов в другие файлы может привести к конфликтам. Стоит либо добавить conditional guard (`unless defined?(Sketchup::View)`), либо документировать порядок загрузки как важный инвариант.

**SUG-3. Исправить commit message Task 6.6**

Заменить "optionally switches view_preset via Sketchup.send_action" на "optionally switches view_preset via direct view.camera = Camera.new(...) (synchronous, locale-independent)".

### Questions

**Q1. Prompt text: Unicode vs ASCII**

Design §6.2 использует Unicode-символы (`≈ 0.3-0.5 × board thickness`), plan Task 2.1 — ASCII-эквиваленты (`~ 0.3-0.5 x board thickness`). Какой вариант предполагается в финальной реализации? Unicode более читаем, но ASCII надёжнее при передаче через JSON/RPC (хотя UTF-8 в JSON проблем не создаёт).

---

## ollama-executor (deepseek)

### Critical Issues

**CRITICAL-1: Cookbook содержит заведомо сломанные паттерны (`send_action` + `DrawEdges`/`DrawFaces`)**

Plan Task 9.1 добавляет в `docs/sketchup-ruby-cookbook.md` пример, который использует `Sketchup.send_action("viewIso:")` и `model.rendering_options["DrawEdges"] = true`. Оба паттерна были явно отвергнуты в iter-1. Cookbook — это референсный документ для пользователей `eval_ruby`. Если он показывает неработающие паттерны, пользователи будут копировать их и получать сломанное поведение.

Направление: cookbook должен показывать direct camera assignment (`view.camera = Sketchup::Camera.new(eye, target, up)`) и `RenderMode` enum. Пример должен быть консистентен с production-кодом из `handlers/view.rb`. Заодно стоит убрать `snap_camera = view.camera` (без deep copy) — production-код делает `Camera.new(c.eye, c.target, c.up)` для защиты от future API changes.

**CRITICAL-2: Design §7.2 и Plan Task 5 содержат разные версии одного и того же теста**

Design §7.2 (таблица тестов) содержит строку `test_send_action_called_for_preset`. Этот тест предполагает вызов `send_action`, что противоречит решению CRITICAL-1 из iter-1. Plan Task 5.1 содержит правильный тест `test_camera_assigned_for_preset`, который проверяет, что `send_action` НЕ вызывается. Но design-документ не был синхронизирован после iter-1.

Направление: удалить `test_send_action_called_for_preset` из design §7.2 или заменить на описание актуального теста. Document-level inconsistency, не затрагивающая имплементацию, но вводящая в заблуждение.

### Concerns

**CONCERN-1: Cookbook comment «max compression — smaller bytes on the wire» противоречит решению CONCERN-12 из iter-1**

Plan Task 9.1 cookbook comment: `compression: 1.0, # max compression — smaller bytes on the wire`. Но iter-1 CONCERN-12 изменил `compression` с 0.9 на 1.0 именно с пометкой "(lossless)". Для PNG формат всегда lossless. Если SketchUp интерпретирует `1.0` как "lossless/no subsampling", то даст больший, а не меньший размер файла. Если же SketchUp маппит `0.0..1.0` на `0..9`, то `1.0` действительно означает максимальное сжатие. Неясно, какая из интерпретаций верна без эмпирической проверки.

Направление: уточнить в cookbook-комментарии, что `1.0` выбрано для lossless (или максимального сжатия, в зависимости от реального поведения SU) и убрать противоречивую формулировку "smaller bytes". Либо явно проверить в SU 2026.

**CONCERN-2: `zoom_extents` на некоторых версиях SketchUp может показывать модальный диалог, а не райзить исключение**

Design §5.6 говорит про empty-model диалог, но handler ловит только `StandardError`. Если SketchUp показывает нативный модальный диалог (C++ уровень), Ruby-поток блокируется до закрытия диалога пользователем, и `rescue` в Ruby никогда не срабатывает. Python-сторона получит timeout через `config.TIMEOUT` секунд (по умолчанию 60). Это фундаментальное ограничение, не упомянутое в §12 Risks.

Направление: добавить в §12 Risks замечание, что модальные диалоги SketchUp (не только empty-model, но и потенциальные «model is empty» диалоги на старых версиях) не перехватываются Ruby-обработчиком и приводят к timeout на Python-стороне.

**CONCERN-3: `_raw_call` рефакторинг меняет текст сообщения об ошибке для всех string-returning tools**

Старый `_call` возвращал `"SketchUp not running or extension not started: {e}"`. Новый `_raw_call` → `_call` возвращает `"SketchUp not running: {e}"`. Потерялся текст `"or extension not started"`. LLM поймёт оба варианта, но это семантическая потеря — старый текст явно указывал, что причина может быть в незапущенном расширении. Внешние инструменты, парсящие error messages, могут сломаться.

Направление: сохранить исходный текст сообщения: `"SketchUp not running or extension not started: {e}"` вместо сокращённого `"SketchUp not running: {e}"`.

**CONCERN-4: `test_camera_restored_after_zoom_extents_failure` содержит dead code в rescue-блоке**

Plan Task 5.1:
```ruby
begin
  call("zoom_extents" => true, "restore_view" => true)
rescue SU_MCP::Core::StructuredError
  # zoom_extents failure is swallowed by handler's inner rescue...
end
```

`zoom_extents` failure всегда проглатывается handler'ом (внутренний `rescue StandardError`), поэтому внешний вызов `call()` всегда успешен. `rescue StructuredError` никогда не срабатывает — это dead code. Тест при этом корректен, так как проверяет `assert_equal original.eye, @view.camera.eye` после успешного вызова. Но rescue-блок вводит в заблуждение.

Направление: убрать rescue-блок из теста: вызов `call(...)` не должен райзить исключение при `zoom_extents` failure, и тест должен это подтверждать (отсутствием исключения), а не просто игнорировать.

**CONCERN-5: Отсутствие проверки на `model.bounds` в `build_preset_camera`**

Plan Task 6.1 `build_preset_camera` вызывает `bounds.center` и `bounds.diagonal`. Для пустой модели `bounds.diagonal` равен 0, и код корректно подставляет fallback `1000.0`. Но `bounds.center` на пустой модели может вернуть `ORIGIN` или `nil` — код не проверяет этот случай. В реальном SketchUp `bounds.center` всегда возвращает точку (origin для пустой модели), так что это не баг, но отсутствие явной проверки оставляет код менее защищённым от будущих изменений API.

Направление: опционально — добавить явный fallback для `bounds.center` (хотя в текущем SU API он не нужен).

### Suggestions

**SUGGESTION-1: Cookbook должен показывать deep-copy snapshot**

Plan Task 9.1 cookbook делает `snap_camera = view.camera` — простое присваивание. Но design §5.4 явно делает deep copy: `Sketchup::Camera.new(c.eye, c.target, c.up)`. Cookbook должен отражать production-паттерн с deep copy и копированием `perspective?`/`fov`/`height`.

**SUGGESTION-2: Design §5.3 ссылается на несуществующий раздел §11 «Default shaded variant»**

Design §5.3, строка таблицы для `shaded`:
> `Set Texture = true if the user has textured materials and wants them visible — see Open Decisions §11 ("Default shaded variant").`

В §11 нет пункта "Default shaded variant". Это битая ссылка. Нужно либо добавить этот пункт в §11, либо убрать упоминание.

**SUGGESTION-3: `PRESET_DIR` имена осей могут быть неверны для Z-направления в SketchUp**

Plan Task 6.1, `PRESET_DIR` использует `Geom::Vector3d.new(0, 0, 1)` для up-вектора во всех presets кроме top/bottom. Это корректно для стандартной ориентации SketchUp (Z = синий = вверх). Но направляющие векторы `(1, -1, 1)` не нормализованы — `length=` вызов нормализует их. Стоило бы явно комментировать, что `PRESET_DIR` содержит direction (не normalised), а нормализация происходит через `offset.length = dist`.

**SUGGESTION-4: `pyproject.toml` testpaths корректен**

Подтверждаю: `pyproject.toml:50` имеет `testpaths = ["tests"]`. Новые тесты создаются в `tests/` согласно плану — корректно.

### Questions

Нет.
