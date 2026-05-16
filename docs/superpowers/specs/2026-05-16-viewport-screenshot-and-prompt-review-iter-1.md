# Review Iteration 1 — 2026-05-16

## Источник

- Design: `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-design.md`
- Plan: `docs/superpowers/plans/2026-05-16-viewport-screenshot-and-prompt-plan.md`
- Review agents:
  - codex-executor (gpt-5.5, xhigh)
  - ccs-executor (glm)
  - ollama-executor (kimi)
  - ollama-executor (minimax)
  - ollama-executor (deepseek)
- Merged output: `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-review-merged-iter-1.md`

## Сводка

| Категория | Кол-во |
|---|---|
| Всего замечаний | 36 |
| Автоисправлено (без обсуждения) | 30 |
| Авто-применено после анализа (disputed → single choice) | 2 (G3 + G2 group impact) |
| Обсуждено с пользователем | 2 (G1, G2) |
| Отклонено (false positives) | 3 |
| Повторов (предыдущих итераций) | 0 |
| Пользователь сказал «стоп» | Нет |

## Замечания

### [CRITICAL-1] `Sketchup.send_action` is asynchronous — breaks preset/restore semantics

**Источник:** codex, ccs/glm, ollama/kimi, ollama/minimax, ollama/deepseek (все 5).

**Статус:** Обсуждено с пользователем — затем эмпирически верифицировано.

**Ответ:** Пользователь предложил проверить прямо сейчас в живом SketchUp 2026 (MCP-сессия открыта). Эмпирическая проверка через `eval_ruby` подтвердила: `Sketchup.send_action("viewIso:")` АСИНХРОННЫЙ — камера не меняется до возврата. Выбран Variant A (direct camera construction).

**Действие:** Design §5.2 переписан — `view.camera = Sketchup::Camera.new(eye, target, up)` вместо `send_action`. Plan Task 6: добавлен `build_preset_camera` helper, `PRESET_DIR` mapping. Plan Task 5: тесты `test_send_action_called_for_preset` заменены на `test_camera_assigned_for_preset`.

---

### [CRITICAL-2] `rendering_options` style key mapping invalid for SketchUp 2026

**Источник:** codex, ccs/glm (Question), ollama/kimi (Concern), ollama/deepseek (Suggestion).

**Статус:** Авто-применено после эмпирической проверки.

**Ответ:** Boolean keys `DisplayShaded`, `DisplayShadedUsingAllSameObject`, `DrawEdges`, `DrawFaces` — WRITE-REJECTED в SketchUp 2026 (`ArgumentError: Rendering option could not be set to the given value`). Working keys: `RenderMode` (Integer enum 0..7), `DrawHidden`, `DrawProfilesOnly`, `Texture`, `DrawBackEdges`. Использован `RenderMode` enum.

**Действие:** Design §5.3 переписан с маппингом `wireframe=0, hidden_line=1, shaded=2`. Plan Task 6: `STYLE_RO` уменьшен до `{"RenderMode" => N}`. Plan Task 5: `RenderingOptionsStub` разделена на `WRITEABLE_KEYS` / `READONLY_KEYS`.

---

### [CRITICAL-3] Mutations are not protected by an outer `ensure`

**Источник:** codex (Critical), ollama/kimi (косвенно).

**Статус:** Автоисправлено.

**Действие:** Plan Task 6 переписан — single outer `begin/ensure`, restore (camera + RO) выполняется на любом exception path. Plan Task 5: новые тесты `test_camera_restored_after_zoom_extents_failure`, `test_rendering_options_restored_after_write_image_failure`.

---

### [CRITICAL-4] Python validation tests use non-existent `.fn` attribute

**Источник:** все 5 ревьюеров.

**Статус:** Автоисправлено.

**Действие:** Plan Task 3.1 переписан — `test_screenshot_max_size_clamps`, `test_screenshot_view_preset_invalid`, `test_screenshot_style_invalid` теперь идут через `await mcp.call_tool("get_viewport_screenshot", {...})` (FastMCP full dispatch path) с mocked connection. `.fn` устранён.

---

### [CRITICAL-5] `get_viewport_screenshot` missing from `_RETRY_SAFE_TOOLS`

**Источник:** codex, ccs/glm, ollama/kimi, ollama/deepseek.

**Статус:** Автоисправлено.

**Действие:** Design §4 указал `connection.py +1 entry`. Plan Task 4.3: добавление `"get_viewport_screenshot"` в `_RETRY_SAFE_TOOLS` с обоснованием идемпотентности. Plan Task 4.4: regression-тест в `tests/test_connection.py`.

---

### [CRITICAL-6] Ruby tests miss required `require_relative` for Core::Logger / Config

**Источник:** ccs/glm.

**Статус:** Автоисправлено.

**Действие:** Plan Task 5.1: блок `require_relative` расширен — добавлены `core/config`, `core/logger`, `helpers/units`, `helpers/entities` (требуются `Dispatch`, `Core::Logger`).

---

### [CONCERN-1] `view.camera` may return a live reference, not a deep copy

**Источник:** codex, ccs/glm, ollama/deepseek.

**Статус:** Автоисправлено + эмпирически верифицировано.

**Ответ:** Эмпирически: `view.camera` возвращает разные object_id каждый вызов (т.е. fresh object). Тем не менее deep-copy snapshot оставлен как defence-in-depth.

**Действие:** Design §5.4 step 1: `snap_camera = Sketchup::Camera.new(c.eye, c.target, c.up)` + copy `perspective?`, `fov`/`height`. Plan Task 6 содержит этот код.

---

### [CONCERN-2] No guard for `Sketchup.active_model == nil` or `active_view == nil`

**Источник:** codex, ccs/glm, ollama/kimi, ollama/minimax, ollama/deepseek.

**Статус:** Автоисправлено.

**Действие:** Plan Task 6: `model = EH.active_model!` (existing helper raises if nil), `view = model.active_view; raise StructuredError if view.nil?`. Plan Task 5: новый тест `test_no_active_view_raises`.

---

### [CONCERN-3] PNG size at high `max_size` may exceed 64 MiB wire limit

**Источник:** codex, ccs/glm (overhead concern).

**Статус:** Автоисправлено.

**Действие:** Plan Task 6: после `write_image`, перед `binread` — `File.size(tmp.path) > MAX_RAW_BYTES (32 MiB)` → `StructuredError` с подсказкой «reduce max_size». Plan Task 5: тест `test_oversize_png_raises`.

---

### [CONCERN-4] Python wrapper duplicates `_call` logic

**Источник:** ccs/glm, ollama/kimi, ollama/deepseek.

**Статус:** Обсуждено с пользователем (G2).

**Ответ:** Пользователь выбрал Variant A — извлечь `_raw_call() -> dict` helper. Существующий `_call` делегирует ему, добавляя string formatting. Screenshot wrapper использует `_raw_call` + парсит content для Image.

**Действие:** Design §5.8 добавлен с rationale. Plan Task 4.0 — pure refactor `_call`. Plan Task 4.2 — `get_viewport_screenshot` делегирует `_raw_call`.

---

### [CONCERN-5] Style mapping for `wireframe` functionally incomplete

**Источник:** ollama/kimi, codex (impl).

**Статус:** Автоисправлено (через CRITICAL-2 эмпирическую проверку).

**Действие:** Использован `RenderMode = 0` (wireframe) — это native SketchUp wireframe mode, корректно скрывающий грани. Boolean-key подход не нужен.

---

### [CONCERN-6] `rendering_options` undo claim unverified

**Источник:** codex.

**Статус:** Автоисправлено + эмпирически верифицировано.

**Ответ:** Через `Sketchup::ModelObserver` подписались на `onTransactionStart`/`Commit`, замутировали `RenderMode` и `DrawHidden` вне `start_operation` — события НЕ срабатывают. §5.5 design assumption holds.

**Действие:** Design §13 пункт acceptance "Live SketchUp 2026 verification" — отмечен `[x]` completed. Plan Task 0 — completed.

---

### [CONCERN-7] `test_camera_restored_when_flag_true` is tautological

**Источник:** codex, ollama/kimi, ollama/minimax, ollama/deepseek.

**Статус:** Автоисправлено.

**Действие:** Plan Task 5: тест переписан. Spy `@view.camera_writes` фиксирует каждое assignment. После CRITICAL-1 fix (direct camera) тест ожидает `>= 2` assignments (preset + restore) и final camera = original.

---

### [CONCERN-8] `img._mime_type` is private FastMCP attribute

**Источник:** ccs/glm, ollama/kimi, ollama/deepseek.

**Статус:** Автоисправлено.

**Действие:** Plan Task 3.1: `test_screenshot_returns_image` использует `img.format == "png"` (public constructor arg) вместо `_mime_type`. Добавлен `test_screenshot_via_mcp_dispatch` для проверки FastMCP serialization.

---

### [CONCERN-9] `test_screenshot_minimal_payload` uses non-realistic mock

**Источник:** ccs/glm.

**Статус:** Отклонено (false positive).

**Ответ:** Проверка connection.py + dispatch.rb показала: Ruby `wrap_content` оборачивает ответ в `{content: [{type:"text",text:"..."}], isError: false}` — это и есть `result` для JSON-RPC, который возвращается `send_command`. Mock корректно симулирует реальное поведение. Документ обновлён в plan: `_ruby_result_for(...)` helper строит именно эту структуру.

---

### [CONCERN-10] `smoke_check.py` uses raw connection, plan uses `session.call_tool`

**Источник:** codex, ollama/deepseek.

**Статус:** Обсуждено (G3) — авто-применено после анализа.

**Ответ:** Только один разумный вариант: smoke_check работает через raw `SketchUpConnection.send_command`, FastMCP не бутится — `session.call_tool` вне scope. FastMCP Image serialization покрыта unit-тестом `test_screenshot_via_mcp_dispatch` (без живого SketchUp). Дублирование в live smoke не нужно.

**Действие:** Plan Task 7.2: snippet переписан под существующий `call(conn, tool, **args)` helper. Assertion на PNG magic header.

---

### [CONCERN-11] Inconsistent `ConnectionError` handling

**Источник:** ollama/kimi, ollama/deepseek.

**Статус:** Автоисправлено в рамках G2 (CONCERN-4).

**Действие:** Design §5.8 явно документирует асимметрию: text-tools surface graceful string, Image-tool raises SketchUpError. Намеренно, не случайно.

---

### [CONCERN-12] `compression: 0.9` suboptimal for verification screenshots

**Источник:** ollama/kimi, ollama/deepseek (Question).

**Статус:** Автоисправлено.

**Действие:** Plan Task 6 + Plan Task 9 (cookbook): `compression: 1.0`. Lossless PNG, меньший wire payload.

---

### [CONCERN-13] `attr_accessor :vpwidth` + `@vpwidth = ...` fragile

**Источник:** ollama/minimax.

**Статус:** Автоисправлено.

**Действие:** Plan Task 5.1: stub `View#initialize` использует `self.vpwidth = 1920; self.vpheight = 1080` (через setter).

---

### [CONCERN-14] `test_tempfile_deleted_on_success` racy via `Dir.entries.count`

**Источник:** ollama/kimi.

**Статус:** Автоисправлено.

**Действие:** Plan Task 5.1: убрана хрупкая проверка `Dir.entries(Dir.tmpdir).count`; оставлена только сильная `Dir.glob(...)` assertion. Тест переименован в `test_tempfile_cleaned_up_on_success`.

---

### [CONCERN-15] `_RETRY_SAFE_TOOLS` decision not tested

**Источник:** ccs/glm (in CRITICAL-5).

**Статус:** Автоисправлено.

**Действие:** Plan Task 4.4: новый regression-тест в `tests/test_connection.py`.

---

### [CONCERN-16] Smoke test uses `"FAKE_PNG_BYTES"` literal

**Источник:** ollama/deepseek.

**Статус:** Автоисправлено.

**Действие:** Plan Task 5.1: stub `View#write_image` пишет реальные PNG bytes (тот же tiny PNG из Python fixture). `test_response_structure` валидирует PNG magic header `\x89PNG\r\n\x1a\n`.

---

### [SUGGESTION-1] Move prompt text to separate `.md` file

**Источник:** codex, ccs/glm.

**Статус:** Отклонено.

**Ответ:** Prompt ~1.5 KB inline в Python нормально; вынос в .md = overengineering на текущем scope. Можно вернуться позже, если prompt вырастет существенно.

---

### [SUGGESTION-2] Strengthen prompt tests beyond anchor phrases

**Источник:** codex.

**Статус:** Автоисправлено.

**Действие:** Plan Task 1.1: добавлен `test_prompt_required_sections` — проверяет наличие всех 7 заголовков секций. Anchor-phrase test остаётся.

---

### [SUGGESTION-3] Add Ruby tests for restore-after-exception

**Источник:** codex, ollama/kimi, ollama/minimax.

**Статус:** Автоисправлено.

**Действие:** Plan Task 5.1: `test_camera_restored_after_zoom_extents_failure`, `test_rendering_options_restored_after_write_image_failure`, `test_rendering_options_not_restored_when_restore_view_false` (negative case).

---

### [SUGGESTION-4] Add FastMCP `Image` serialization test

**Источник:** ccs/glm.

**Статус:** Автоисправлено.

**Действие:** Plan Task 3.1: `test_screenshot_via_mcp_dispatch` — `await mcp.call_tool(...)` с mocked connection, assert на `ImageContent` с `mimeType="image/png"` и PNG magic в base64-декодированных data.

---

### [SUGGESTION-5] Document double-encoding overhead

**Источник:** ccs/glm.

**Статус:** Автоисправлено.

**Действие:** Design §4: добавлен раздел «Double-encoding overhead» — ~2× raw PNG на wire (base64 +33%, JSON wrap +33%).

---

### [SUGGESTION-6] Justify version bump choice (0.1.0 vs 0.0.4)

**Источник:** ollama/deepseek.

**Статус:** Автоисправлено.

**Действие:** Design §9 step 6: явный rationale «0.1.0 — first user-facing feature after 0.0.x bugfix series». Design §11: version удалён из open decisions, перенесён в «Resolved during review iter 1».

---

### [SUGGESTION-7] Use `Tempfile.create` instead of timestamp + PID

**Источник:** ollama/deepseek.

**Статус:** Автоисправлено.

**Действие:** Design §5.4 step 5 + §5.7. Plan Task 6: `Tempfile.create(["sumcp_vp_", ".png"])` block. Plan Task 9 cookbook: тот же паттерн.

---

### [SUGGESTION-8] Document operation order in handler docstring

**Источник:** ollama/deepseek.

**Статус:** Автоисправлено.

**Действие:** Plan Task 4.2 docstring: «Note on operation order...». Plan Task 6.1 view.rb: header comment «Operation order...».

---

### [SUGGESTION-9] `_load_prompts` autouse fixture redundant

**Источник:** ollama/deepseek.

**Статус:** Автоисправлено.

**Действие:** Plan Task 1.1: убрана `@pytest.fixture(autouse=True)`, заменена на module-level `import sketchup_mcp.prompts`.

---

### [SUGGESTION-10] Add edge-case test `style="default"` + `restore_view=true`

**Источник:** ollama/deepseek.

**Статус:** Автоисправлено.

**Действие:** Plan Task 5.1: `test_no_ro_touched_when_style_default` — spy на `rendering_options[]=`, asserts no writes when `style="default"`.

---

### [QUESTION-1] `view_preset` native vs deterministic cameras

**Источник:** codex.

**Статус:** Решено вместе с G1.

**Ответ:** Direct camera construction (Variant A) → deterministic camera. Приемлемо для use case visual verification.

**Действие:** Design §5.2 содержит обоснование trade-off.

---

### [QUESTION-2] Respect hidden objects/tags or temporarily show all?

**Источник:** codex, ollama/minimax.

**Статус:** Автоисправлено.

**Действие:** Design §5.6: добавлен пункт «Hidden geometry / hidden tags / current style — captures what the user sees; handler does not temporarily unhide».

---

### [QUESTION-3] Live SketchUp 2026 verification — mandatory acceptance gate?

**Источник:** codex.

**Статус:** Автоисправлено + выполнено в этой итерации.

**Действие:** Design §13 — gate добавлен; завершён прямо в этой итерации через live `eval_ruby` (см. CRITICAL-1, CRITICAL-2, CONCERN-1, CONCERN-6). Plan Task 0 — completed.

---

### [QUESTION-4] Optimal default `max_size` (512 vs 800)?

**Источник:** ccs/glm.

**Статус:** Отклонено / deferred.

**Ответ:** 800 — explicit choice from brainstorming (match blender-mcp). Менять на 512 — отдельный design exercise, требующий experimental data о размере токенизации для Claude. Не блокирует текущий PR.

---

### [QUESTION-5] Should `transparency=true` be a parameter?

**Источник:** ccs/glm.

**Статус:** Отклонено.

**Ответ:** YAGNI. В §10 future batches.

---

### [QUESTION-6] Snapshot whole `rendering_options` vs target keys?

**Источник:** ccs/glm.

**Статус:** Автоисправлено через CRITICAL-1 решение.

**Действие:** После switch на direct camera (вместо send_action), preset больше не имеет побочных эффектов на RO. Snapshot target keys остаётся корректным. Design §5.3 содержит соответствующую заметку.

---

### [QUESTION-7] Section Plane / Scene/Page interaction

**Источник:** ccs/glm, ollama/deepseek.

**Статус:** Автоисправлено.

**Действие:** Design §5.6: документированы как «known behavior» — Section Plane respected, Page camera not modified.

---

### [QUESTION-8] `antialias: true` performance on large outputs

**Источник:** ollama/deepseek.

**Статус:** Автоисправлено.

**Действие:** Design §12 risks: новый bullet «`antialias: true` cost at large sizes» — пользователь может уменьшить max_size, если отзывчивость важнее fidelity.

---

### [QUESTION-9] `write_image` during active drag/orbit

**Источник:** ollama/kimi, ollama/minimax.

**Статус:** Автоисправлено.

**Действие:** Design §12 risks: уточнено wording — «may capture intermediate state; we won't try to suspend user input».

---

### [QUESTION-10] `zoom_extents` on empty model can trigger dialog

**Источник:** ollama/kimi.

**Статус:** Автоисправлено.

**Действие:** Plan Task 6: `view.zoom_extents` обёрнут в `begin/rescue StandardError` — exception swallowed + logged. Plan Task 5: тест `test_zoom_extents_failure_does_not_propagate`.

---

### [QUESTION-11] `pyproject.toml` and asyncio_mode contradiction

**Источник:** ollama/minimax.

**Статус:** Автоисправлено.

**Ответ:** Проверка `pyproject.toml:48-49` подтвердила: `asyncio_mode = "auto"` уже настроен.

**Действие:** Plan Task 2.4 (asyncio mode contingency) удалён. Plan «Files NOT touched»: подтверждено что `pyproject.toml` не трогается.

---

### [QUESTION-12] SketchUp default background is gradient, not blue

**Источник:** ollama/deepseek.

**Статус:** Автоисправлено.

**Действие:** Design §5.6 «Empty model»: «sky/ground gradient with horizon line» вместо «blue background».

---

## Изменения в документах

| Файл | Изменение |
|------|-----------|
| `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-design.md` | §4 wire contract + double-encoding + retry-safe; §5.2 переписан (direct camera); §5.3 переписан (RenderMode enum); §5.4 handler flow (outer ensure, deep-copy snapshot, active_view guard, size cap, Tempfile, compression 1.0, zoom_extents rescue); §5.6 edge cases (gradient, hidden, Section Plane, mid-drag, oversize); §5.7 Tempfile note; §5.8 NEW (_raw_call rationale); §7.1/7.2 testing tables; §9 release rationale; §11 open decisions cleaned; §12 risks rewritten; §13 acceptance gate (now completed) |
| `docs/superpowers/plans/2026-05-16-viewport-screenshot-and-prompt-plan.md` | Task 0 (completed in this iteration); Task 1 prompts tests + autouse removal + required_sections; Task 2 asyncio contingency removed; Task 3 Python tests rewritten (mcp.call_tool, img.format, via_mcp_dispatch); Task 4 split: 4.0 _raw_call refactor, 4.3 _RETRY_SAFE_TOOLS, 4.4 regression test, 4.5/4.6/4.7 updated; Task 5 stubs rewritten (Geom::Vector3d, BBox, RenderingOptionsStub split, real PNG bytes, full require_relative, camera spy tests, restore-after-exception, no_active_view, oversize, no-op, portrait); Task 6 view.rb rewritten (build_preset_camera, PRESET_DIR, RenderMode enum, outer ensure); Task 7 smoke (raw call); Task 11 test counts updated |
| `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-review-merged-iter-1.md` | NEW — merged review from 5 agents |
| `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-review-iter-1.md` | NEW — this file |

## Статистика

- **Всего замечаний:** 36
- **Автоисправлено (без обсуждения):** 30
- **Авто-применено после анализа:** 2 (G3 single-obvious-choice, CRITICAL-2 после эмпирической проверки)
- **Обсуждено с пользователем:** 2 (G1, G2)
- **Отклонено:** 3 (CONCERN-9, SUGGESTION-1, QUESTION-4, QUESTION-5)
- **Повторов (автоответ):** 0
- **Пользователь сказал «стоп»:** Нет
- **Агенты:** codex-executor, ccs-executor (glm), ollama-executor (kimi, minimax, deepseek)

## Особо ценный вклад

Эмпирическая проверка в живом SketchUp 2026 (по предложению пользователя) **изменила два архитектурных решения**:

1. `Sketchup.send_action` асинхронен в SketchUp 2026 — переключение на direct `view.camera = ...` assignment.
2. Половина старых `rendering_options` ключей в SketchUp 2026 не writable — полный переход на `RenderMode` enum.

Без этой проверки реализация бы прошла unit-тесты и **сломалась на первом же live-запуске**. Это поднимает acceptance gate из «nice-to-have» до «critical part of the workflow».
