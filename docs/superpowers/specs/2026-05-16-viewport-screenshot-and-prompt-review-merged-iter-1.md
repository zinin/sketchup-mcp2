# Merged Design Review — Iteration 1

Documents reviewed:
- Design: `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-design.md`
- Plan: `docs/superpowers/plans/2026-05-16-viewport-screenshot-and-prompt-plan.md`

Review agents: codex-executor (gpt-5.5, xhigh), ccs-executor (glm), ollama-executor (kimi), ollama-executor (minimax), ollama-executor (deepseek).

---

## codex-executor (gpt-5.5, xhigh)

### Critical Issues

- Design §5.2 предполагает, что `Sketchup.send_action("viewIso:")` синхронен. Это неверно: официальный Ruby API описывает `send_action` как асинхронную отправку сообщения в очередь. При текущем плане Ruby handler может сделать screenshot до смены камеры, а затем restore может быть перезаписан отложенным action. Это ломает и `view_preset`, и обещание `restore_view=true`.

- Mapping стилей почти наверняка неверный. В design §5.3 и plan STYLE_RO используются `DisplayShaded`, `DisplayShadedUsingAllSameObject`, `DrawEdges`, `DrawFaces`; в официальном списке `Sketchup::RenderingOptions` этих ключей нет, а с SketchUp 2024 invalid key/value может бросать `ArgumentError`. Нужно перейти на подтвержденные ключи (`RenderMode`, `Texture`, `DrawHidden`/`DrawBackEdges`) и проверить live.

- Restore не защищён `ensure`. В плане restore идёт после `begin/ensure`, который удаляет только tmp-файл. Если `write_image` вернёт `false`, `File.binread` упадёт, RO assignment бросит `ArgumentError`, либо `zoom_extents` упадёт — камера/RO не восстановятся. Для "non-destructive by default" нужен внешний `ensure`, покрывающий все mutations.

- Python-тесты на Pydantic validation в плане нерабочие. FastMCP `@mcp.tool()` в установленной версии возвращает исходную функцию, у неё нет `.fn`. Прямой вызов функции также обходит FastMCP/Pydantic validation. Эти проверки надо делать через `await mcp.call_tool(...)` либо отдельные `TypeAdapter`-тесты.

- Ruby stubs в test_view.rb маскируют главные риски: `send_action` не асинхронен и не меняет камеру, `rendering_options` принимает любые ключи, а `test_camera_restored_when_flag_true` сравнивает тот же объект камеры. Такие тесты могут пройти при реализации, которая не работает в SketchUp.

### Concerns

- Утверждение, что `model.rendering_options[...] = v` не участвует в undo/dirty state, не доказано. Для `Model#rendering_options` нужен live-тест через `ModelObserver#onTransactionStart/Commit` и проверка undo menu.
- Snapshot камеры как `snap_camera = view.camera` может быть недостаточен. Нужно сохранять свойства в новый объект: `eye`, `target`, `up`, `perspective?`, `fov` или `height`, возможно `aspect_ratio`, 2D/match-photo параметры.
- Нет явного guard для `Sketchup.active_model == false/nil` и `model.active_view == nil`; лучше использовать существующий `Helpers::Entities.active_model!` и добавить structured error для отсутствующего active view.
- `_RETRY_SAFE_TOOLS` в `connection.py:39` не обновляется. Нужно явно решить, является ли screenshot retry-safe, особенно при `restore_view=false`.
- 4096px PNG может превысить 64 MiB после base64+JSON на детальной/текстурированной сцене. `compression: 0.9` для PNG не является надёжной защитой. Нужен лимит размера файла до base64 или меньший `max_size`.
- `examples/smoke_check.py` сейчас использует raw `SketchUpConnection`, а плановый snippet использует `session.call_tool`. Raw smoke проверит Ruby JSON, но не проверит FastMCP `Image` serialization.

### Suggestions

- Не использовать `send_action` для пресетов. Лучше строить камеру напрямую из `model.bounds` для `front/back/left/right/top/bottom/iso`; если нужен именно native action, придётся делать асинхронный state machine через `UI.start_timer`, что плохо ложится в текущий синхронный handler.
- Перед style assignment проверять `model.rendering_options.keys` и падать понятным `StructuredError`, если ожидаемый ключ отсутствует. В тестовом stub сделать unknown key raising.
- Вынести Python-логику разбора MCP-shaped text result в helper, чтобы не дублировать `_call`, но сохранить возможность вернуть `Image`.
- Добавить Ruby-тесты: restore после `write_image=false`, restore после exception, delayed `send_action`, invalid RO key, `active_model` отсутствует, zero viewport dimensions.
- Для prompt лучше хранить текст в отдельном `.md` или хотя бы тестировать не только anchor phrases, а ключевые инструкции целыми смысловыми блоками. Аргументы prompt сейчас не нужны.

### Questions

- Требуется ли `view_preset` быть точно SketchUp native standard view, или достаточно детерминированной камеры с тем же направлением?
- Должен ли screenshot уважать текущие hidden objects/tags/scenes как "что видит пользователь", или инструмент должен уметь временно показывать все?
- Можно ли сделать live SketchUp 2026 проверку обязательной acceptance gate именно для `send_action`, undo/transaction behavior и rendering_options mapping?

---

## ccs-executor (glm)

### Critical

- `get_viewport_screenshot` отсутствует в `_RETRY_SAFE_TOOLS` (`connection.py:43-52`). При stale-socket retry не сработает. Добавить и добавить тест.
- Ruby-тесты не загружают `Core::Logger` — `test_dispatch_routes_to_view_handler` упадёт с `NameError`. Расширить список `require_relative` (Config, Logger, units, etc.).
- Python-wrapper дублирует логику `_call`: connection acquisition и content extraction. Если протокол изменится, правка в двух местах. Рекомендация — выделить `_raw_call() -> dict` и переиспользовать.

### Concerns

- `Sketchup.send_action("viewIso:")` — не доказана синхронность. Stub не ловит асинхронность.
- Camera snapshot — ссылка, а не глубокая копия. SketchUp может вернуть тот же объект.
- `send_action` может изменять rendering_options за пределами snap (perspective ↔ parallel, и т.п.). Restore-логика не покрывает побочные RO-изменения preset'а.
- Нет защиты от `model.active_view == nil`.
- Python-тест обращается к приватному `Image._mime_type`. Заменить на `to_image_content().mimeType`.
- Double JSON-encoding — wire overhead ~2x от raw PNG (base64 +33%, JSON-wrap ещё ~33%). Это корректно, но стоит явно отметить в дизайне.
- `test_screenshot_minimal_payload` — неестественный mock с MCP-shaped envelope; реальный `send_command` возвращает только `result`.

### Suggestions

- S1. Вынести `_raw_call()` как общую основу.
- S2. Разделить на два MCP-tool (set_view_preset + get_viewport_screenshot) — для уменьшения связности (опционально, не в текущем scope).
- S3. Загружать prompt из файла, не embed в Python.
- S4. Добавить тест на `Image` return через FastMCP dispatch.

### Questions

- Подтверждена ли синхронность `send_action`?
- Возвращает ли `view.camera` новый объект каждый раз?
- Какой реальный размер PNG при `max_size=800`?
- Как поведёт себя handler при активном Section Plane?
- Какой `max_size` по умолчанию оптимален для LLM (default может быть 512, не 800)?
- Планируется ли `transparency=true` как параметр?
- Снимать ли `model.rendering_options` целиком (~30 ключей) при restore вместо целевых?

---

## ollama-executor (kimi)

### Critical

- `Sketchup.send_action` — неверное предположение о синхронности. Воспроизвести в живом SketchUp; иначе перейти на прямое `view.camera =` или `view.invalidate`.
- Python-тесты валидации вызывают `.fn()` — атрибута нет. `ValidationError` не возникнет; тесты упадут с `AttributeError`. Использовать `TypeAdapter` (как в `test_tools.py`) или `mcp._tool_manager.call_tool(...)`.
- `test_camera_restored_when_flag_true` тривиально проходящий: в стабе `send_action` не меняет камеру, поэтому равенство гарантированно. Шпионить за `camera=` (как в `test_camera_not_restored_when_flag_false`).
- `test_screenshot_returns_image` опирается на приватный `img._mime_type` — внутренняя реализация FastMCP. Использовать публичный API.
- Нет теста, что `send_action` реально меняет камеру. Если предположение неверно — весь `view_preset` неработоспособен.

### Concerns

- `ConnectionError` обрабатывается иначе, чем в остальных tools (raise vs str return). Архитектурная несогласованность.
- `test_tempfile_deleted_on_success` — гонка по `Dir.entries.count`; сильный `Dir.glob` уже есть, слабый assert избыточен.
- Стиль `wireframe` — неполное отображение: при `DisplayShaded=true` (default) грани всё равно могут рендериться. Нужно `DisplayShaded=false`.
- `rendering_options` keys: строки vs символы — в разных версиях SketchUp может отличаться.
- `zoom_extents` может триггерить диалог на пустой модели.

### Suggestions

- S11. Заменить `send_action` на прямое управление камерой или `view.invalidate`.
- S12. Исправить Python-тесты валидации (через TypeAdapter / mcp.call_tool).
- S13. Усилить `test_camera_restored_when_flag_true` через шпион на `camera=`.
- S14. Усилить тест восстановления rendering_options: предварительная мутация → handler → проверка восстановления.
- S15. Привести `compression: 0.9` в консистентность между screenshot tool и export.rb (или убрать).

### Questions

- Проверен ли `send_action` на синхронность в SketchUp 2026?
- Какие ключи `rendering_options` реально работают для shaded/hidden_line/wireframe в SketchUp 2026?
- Что происходит при `write_image` во время active drag/orbit?
- Как `get_viewport_screenshot` взаимодействует с `_RETRY_SAFE_TOOLS`? Нужно добавить в whitelist.

---

## ollama-executor (minimax)

### Critical

- `send_action` — несинхронное выполнение. Камера меняется в следующем tick; `write_image` снимет старое состояние. Фундаментальная проблема всей snapshot/restore логики preset.
- Portrait aspect ratio: `@vpwidth` / `@vpheight` — конфликт имени accessor в stub. `attr_accessor` + прямое присваивание `@vpwidth = ...` в `initialize` создаёт хрупкость, тест может упасть.
- `restore_view=false` — preset-эффект сохраняется без restore: если `send_action` deferred, камера фактически не меняется в момент `send_action`.

### Concerns

- `test_camera_restored_when_flag_true` проверяет только `eye` и `target`, не `up`. Расхождение со stub equality.
- Portrait: max_size вычисляется по большей стороне (не баг, но стоит документировать).
- `nil active_view` — не обработан.
- `rendering_options` restore: несимметричный key set; если оригинальное значение было `nil`, restore установит nil.
- `test_aspect_ratio_preserved` — assert комментирует только width.
- Integer type check (`is_a?(Integer)`): Python float (`800.0`) будет отклонён в Ruby. Это defense-in-depth, не проблема.

### Suggestions

- S1. Добавить тест на количество вызовов `send_action` (verify deferred behavior).
- S2. Portrait aspect ratio stub fix: использовать `self.vpwidth = ...` в `initialize`.
- S3. `nil active_view` guard: явный raise.
- S4. Документировать portrait behavior в docstring.
- S5. Добавить тест: `rendering_options NOT restored when restore_view=false` (негативный кейс).

### Questions

- Эмпирическое подтверждение синхронности `send_action("viewIso:")`?
- Какой версии Ruby API / SketchUp 2026? `View#write_image` поведение при modal dialog задокументировано?
- Почему `pyproject.toml` не упоминается в Files NOT touched? asyncio_mode уже настроен?
- Предусмотрена ли ситуация: SketchUp запущен, extension не загружена (`active_model` nil)?

---

## ollama-executor (deepseek)

### Critical

- `get_viewport_screenshot` отсутствует в `_RETRY_SAFE_TOOLS` (connection.py:43). Read-only операция — должна быть retry-safe.
- `img._mime_type` — приватный атрибут FastMCP в тесте. Заменить на публичный `img.format` или `to_image_content().mimeType`.
- Расхождение паттерна обработки ошибок: 22 существующих tool возвращают `str` через `_call`, screenshot обходит и re-raise'ит исключения. Дизайн молчаливо принимает, но не обсуждает последствия. Либо объяснить, либо fast-path в `_call` для `Image`.
- `.fn` паттерн в тестах валидации — вероятно нерабочий. Заменить на `TypeAdapter`.

### Concerns

- Семантика снапшота камеры не верифицирована (in-place vs new). Plan-тесты не покрывают этот случай.
- Smoke check использует неверное API: `session.call_tool` — но текущий `smoke_check.py` работает напрямую через `SketchUpConnection.send_command`. Правильный паттерн — через тот же `call`-хелпер.
- `model.active_view` без nil-проверки.
- Smoke check bypasses FastMCP — не тестирует Image-сериализацию. Нужен отдельный smoke через `mcp.ClientSession`.
- `_load_prompts` fixture с `autouse=True` избыточен — достаточно module-level import.

### Suggestions

- 10. Разделить smoke check на Python- и Ruby-level.
- 11. Добавить edge-case тест: `style="default"` + `restore_view=true` (пустой `snap_ro`).
- 12. Проверить rendering_options mapping эмпирически ДО реализации.
- 13. Заменить `"FAKE_PNG_BYTES"` на валидный PNG в тестах (smoke check проверяет PNG magic bytes).
- 14. Явно указать порядок операций в docstring: preset → style → zoom_extents.
- 15. Обосновать выбор 0.1.0 vs 0.0.4 в open decisions.

### Questions

- Scene/Page camera interaction при `restore_view=false`?
- Background color / style — дефолтный фон SketchUp это градиент, не «blue». Важно для visual verification?
- Tempfile race condition: `Time.now.strftime` + `Process.pid` теоретически коллидирует. Альтернатива: `Tempfile.create`.
- Почему `compression: 0.9`, а не 1.0 (verification screenshots)?
- `antialias: true` — производительность на больших размерах?
- `restore_view=false` + `style="default"` = no-op — стоит ли валидировать с warning?
