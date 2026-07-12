# Review Iteration 2 — 2026-05-16 18:30

## Источник

- Design: `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-design.md`
- Plan: `docs/superpowers/plans/2026-05-16-viewport-screenshot-and-prompt-plan.md`
- Review agents launched: codex-executor (gpt-5.5, xhigh), ccs-executor (glm), ollama-executor (kimi, minimax, deepseek).
- Reviewers that produced results: **codex, ccs/glm, ollama/deepseek** (3 из 5).
- Reviewers that failed mid-stream: **ollama/kimi, ollama/minimax** — upstream Ollama daemon dropped connection without emitting `result` event. Documented as a known infrastructure issue, not a content gap (the three successful reviewers converged on the same critical issues, so iter-2 has sufficient signal).
- Merged output: `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-review-merged-iter-2.md`

## Сводка

| Категория | Кол-во |
|---|---|
| Всего замечаний (raw, до дедупликации) | 26 |
| После дедупликации (actionable entries) | 22 |
| Дубликатов слито в другие entries | 4 (I13→I10, I18→I5, I21→I8, I23→I1) |
| Повторов из iter-1 (документная допиловка) | 5 |
| Авто-исправлено (без обсуждения) | 8 |
| Обсуждено с пользователем | 6 |
| Отклонено (false positives) | 3 |
| Пользователь сказал «стоп» | Нет |

## Замечания

### [I1] Cookbook содержит rejected `send_action` + `DrawEdges` паттерны

**Источник:** codex (Critical), ccs/glm (C1+C2), ollama/deepseek (CRITICAL-1)
**Статус:** Повтор (iter-1, CRITICAL-1 + CRITICAL-2) — документная допиловка
**Ответ:** Iter-1 заменил handler и design на direct camera + RenderMode, но cookbook snippet (Plan Task 9.1) был пропущен в sync sweep. То же решение применяется к cookbook.
**Действие:** Plan Task 9.1 cookbook snippet полностью переписан: deep-copy snapshot (`Camera.new(c.eye, c.target, c.up)`), direct `view.camera = Camera.new(...)` для preset, `RenderMode` enum (= 2 для shaded) вместо `DrawEdges`. Plus File Structure line 26 — убрано «send_action for preset».

---

### [I2] Design §7.2 содержит obsolete `test_send_action_called_for_preset`

**Источник:** codex (Critical), ccs/glm (CONC-4), ollama/deepseek (CRITICAL-2)
**Статус:** Повтор (iter-1, CRITICAL-1) — документная допиловка
**Ответ:** Plan Task 5.1 заменил тест на `test_camera_assigned_for_preset` в iter-1, но design §7.2 table не была синхронизирована.
**Действие:** Design §7.2 row заменена: `test_camera_assigned_for_preset` (verifies direct `view.camera=` assignment + `send_action` NOT called).

---

### [I3] Cookbook comment "max compression — smaller bytes" противоречит iter-1 lossless rationale

**Источник:** ollama/deepseek (CONCERN-1)
**Статус:** Повтор (iter-1, CONCERN-12) — документная допиловка
**Ответ:** Iter-1 изменил `compression` с 0.9 на 1.0 с пометкой «(lossless)». Cookbook commit был сделан после, и комментарий не отразил это решение.
**Действие:** Cookbook comment изменён на `compression: 1.0, # PNG is always lossless; 1.0 = strongest compression`.

---

### [I4] `_raw_call` конвертирует ConnectionError — fragile detection в `_call`

**Источник:** ccs/glm (CONC-1+2+5, SUG-1), ollama/deepseek (CONCERN-3)
**Статус:** Обсуждено с пользователем
**Ответ:** Variant A — `_raw_call` НЕ конвертирует `ConnectionError`. Каждый caller (`_call`, screenshot wrapper) ловит сам со своей стратегией: text-tools graceful string, Image-tools raise SketchUpError. Это устраняет CONC-1 (no substring match), CONC-2 (dead code removed), CONC-5 (original error text preserved).
**Действие:** Plan Task 4.0 переписан: `_raw_call` raises ConnectionError naturally. `_call` ловит и возвращает «SketchUp not running or extension not started: {e}» (canonical legacy text). Plan Task 4.2 — screenshot wrapper sam catches ConnectionError → raise SketchUpError(-32000, ...). Design §5.8 обновлён — отражает новую механику + сохраняет асимметрию documented.

---

### [I5] Camera snapshot не полный — 2D / match-photo cameras

**Источник:** codex (Critical "Неполный snapshot камеры")
**Статус:** Обсуждено с пользователем
**Ответ:** Variant A — fail-fast guard. При `restore_view=true` и `camera.is_2d? == true` handler raises StructuredError с подсказкой использовать `restore_view=false`. Это для редких 2D/match-photo cameras; обычные perspective не затронуты. Variant B (full property copy) over-engineered, Variant C (document only) — silent partial restore.
**Действие:** Design §5.4 step 1: добавлен `if c.is_2d?` guard + raise. Design §5.6 edge cases: новый bullet про 2D cameras. Plan Task 6 (handler): добавлен guard. Plan Task 5.1: новые тесты `test_2d_camera_with_restore_view_fails_fast` и `test_2d_camera_with_restore_view_false_succeeds`. Design §7.2 — соответствующие row.

---

### [I6] Parallel projection preset framing использует distance вместо height

**Источник:** codex (Concern "Parallel projection не фреймится через distance")
**Статус:** Авто-исправлено
**Ответ:** Для orthographic камер видимый масштаб определяет `Camera#height`, не distance. Если current camera была orthographic с произвольным height, копирование того же height в новую preset camera клипит модель.
**Действие:** Plan Task 6.1 `build_preset_camera`: для `perspective=false` ветка теперь устанавливает `cam.height = diag * 0.6` (bbox-derived) вместо `current_camera.height`. Plan Task 5.1: новый тест `test_camera_assigned_for_preset_orthographic` проверяет что ortho preset height bbox-derived (refute_in_delta с большим baseline). Design §5.2 row для `view_preset=<other>` обновлён с упоминанием ortho height handling.

---

### [I7] Большие screenshot ответы могут блокировать SketchUp UI

**Источник:** codex (Concern "Большие ответы могут блокировать UI SketchUp")
**Статус:** Обсуждено с пользователем
**Ответ:** Variant A — документировать как accepted risk в §12. Default `max_size=800` (PNG ~200 KB) даёт неощутимый blocking write. Power users с `max_size=4096` на textured сцене могут наблюдать briefный UI hitch — documented. Variant B (снизить cap до 4 MiB) регрессирует iter-1 решение о 32 MiB headroom. Variant C (chunked write) — большой refactor основного wire-протокола, out of scope.
**Действие:** Design §12 risks: новый bullet про blocking write — численный анализ default vs max_size=4096 + явное упоминание chunked write rejected как out-of-scope.

---

### [I8] Camera restore tests слабые — eye-only assertion + dead rescue

**Источник:** codex (Concern), ollama/deepseek (CONCERN-4)
**Статус:** Авто-исправлено
**Ответ:** `test_camera_restored_when_flag_true` сравнивал только `original.eye` — broken restore (например пропуск target/up) проходил бы. `test_camera_restored_after_zoom_extents_failure` не имел prior mutation, плюс dead rescue для исключения которое handler всегда swallow'ит.
**Действие:** Plan Task 5.1: оба теста переписаны. `test_camera_restored_when_flag_true` проверяет eye/target/up/perspective/fov-or-height. `test_camera_restored_after_zoom_extents_failure` теперь делает preset switch первым (real mutation), убран dead rescue, full property check.

---

### [I9] Smoke step hardcoded `step=21` + слабая assertion

**Источник:** codex (Concern "Smoke step слабо проверяет реальный screenshot")
**Статус:** Авто-исправлено
**Ответ:** Текущий smoke имеет cleanup=19, undo=20. Plan hardcode'ил `step=21` для screenshot, что нарушает natural step sequence. Plus assertion проверяла только PNG magic — 1×1 валидный PNG бы прошёл.
**Действие:** Plan Task 7.2 переписан: explicit renumber instruction (screenshot → 19, cleanup → 20, undo → 21). Strong assertions — все 5 response keys, dimension bounds (0 < w,h ≤ max_size), PNG size > 1024 bytes (rule out trivial), preset_used и style_used echo check.

---

### [I10] `test_screenshot_returns_image` обращается к `img._format`

**Источник:** codex (Suggestion), ccs/glm (CONC-6)
**Статус:** Повтор (iter-1, CONCERN-8) — документная допиловка
**Ответ:** Iter-1 решил использовать public `img.format`; но plan line 444 ended up с hybrid `format` + `_format` fallback при final pass-through.
**Действие:** Plan Task 3.1: убран `_format` fallback, осталось чистое `assert img.format == "png"`. Комментарий обновлён — `_format` явно помечен как FastMCP internal, MIME/format covered separately by dispatch test.

---

### [I11] Prompt overgeneralizes `{id, name, type, bbox_mm}` for all tools

**Источник:** codex (Suggestion "Prompt переобобщает ответы mutating tools")
**Статус:** Авто-исправлено
**Ответ:** `delete_component`, `create_layer`, `undo`, `get_selection` имеют другие response shapes. Текст «tools that create or modify entities return {id, name, type, bbox_mm}» был слишком широкий и misleading для Claude.
**Действие:** Plan Task 2.1 + design §6.2 «# 4. After every mutation»: переписан bullet — «Geometry, material, boolean, joinery, and edge tools that create or modify a single entity return {id, name, type, bbox_mm}». Добавлен второй bullet про tools с other response shapes (delete_component, create_layer, undo, list/find, get_model_info, get_selection — «see the tool docs»).

---

### [I12] Acceptance criteria не полностью покрыты (Claude Desktop path)

**Источник:** codex (Suggestion)
**Статус:** Обсуждено с пользователем
**Ответ:** Variant A — сузить acceptance до реального покрытия. FastMCP Image serialization → unit `test_screenshot_via_mcp_dispatch` (mocked connection). Live Ruby handler → `examples/smoke_check.py` step 19 (raw TCP). End-to-end через real Claude Desktop — manual / out of automated acceptance, manual verification before each release. Variant B (manual MCP client smoke script) и C (Claude Desktop checklist) добавляли infrastructure для thin gap.
**Действие:** Design §13 acceptance переписан с явным разделением двух layers + note о deliberate non-coverage end-to-end Claude Desktop path (с указанием follow-up если регрессия появится).

---

### [I14] Sketchup::View guard в run_all.rb

**Источник:** ccs/glm (SUG-2)
**Статус:** Отклонено (false positive)
**Ответ:** Сами ccs/glm отметили что текущие тесты не конфликтуют при alphabetical load order — существующие файлы не определяют `Sketchup::Camera`/`Model`/`View`. Defensive coding против hypothetical future change. Iter-1 уже сделал require_relative restructure (CRITICAL-6), load order корректен. Re-consider при появлении второго test файла со stubs того же класса.

---

### [I15] Task 6.6 commit message пишет про `send_action`

**Источник:** ccs/glm (SUG-3), codex (Critical "В документах остались следы...")
**Статус:** Повтор (iter-1, CRITICAL-1) — документная допиловка
**Ответ:** Iter-1 заменил send_action на direct camera, но commit message Task 6.6 не был обновлён.
**Действие:** Plan Task 6.6 commit message переписан с упоминанием «direct view.camera = Sketchup::Camera.new(...) (synchronous, locale-independent — Sketchup.send_action was rejected as async in SU 2026, see review iter 1)».

---

### [I16] Unicode `≈ ×` vs ASCII `~ x` в prompt

**Источник:** ccs/glm (Q1)
**Статус:** Обсуждено с пользователем
**Ответ:** Variant A — Unicode в обоих документах. UTF-8 в JSON безопасно; FastMCP сериализует корректно; Claude рендерит чисто. Design — source of truth.
**Действие:** Plan Task 2.1 joinery section: `~ 0.3-0.5 x board thickness` → `≈ 0.3-0.5 × board thickness`. Соответствует design §6.2.

---

### [I17] SketchUp version matrix не определён

**Источник:** codex (Question "Какая реальная матрица SketchUp versions?")
**Статус:** Обсуждено с пользователем
**Ответ:** Variant B — официально target только SketchUp 2026. Iter-1 эмпирические находки (RenderMode keys, send_action async, is_2d?, RO undo behavior) проверены только на SU 2026. Earlier versions may work but not tested or supported by this tool. Все другие plugin tools сохраняют historical version baseline.
**Действие:** Design §13 — добавлен раздел «Supported SketchUp version» перед acceptance criteria. Plan Task 8.2 (CLAUDE.md update) — добавлена note про SU 2026+ requirement для viewport screenshot tool specifically.

---

### [I19] Preset framing должен учитывать только видимую геометрию

**Источник:** codex (Question "Preset framing должен учитывать hidden geometry?")
**Статус:** Авто-исправлено
**Ответ:** Согласно §5.6 design, screenshot captures «what the user currently sees» (не unhide hidden). Preset framing должен быть consistent — фреймить только видимое. С `model.bounds` (включая hidden) визуально модель может стать маленькой в кадре.
**Действие:** Plan Task 6.0 (NEW): добавлен helper `Helpers::Geometry.visible_bounds(model)` — фильтрует hidden entities + entities на скрытых layers; fall back на `model.bounds` если ничего не видно. Plan Task 6.1 (handler) использует visible_bounds вместо model.bounds. Plan Task 5.1: тесты `test_preset_camera_uses_visible_bounds` и `test_visible_bounds_not_called_for_current_preset` через method spy. Design §5.2 row обновлён. Plan Task 6.6 commit list расширен на `helpers/geometry.rb`.

---

### [I20] Native SU modal dialogs не перехватываются Ruby rescue

**Источник:** ollama/deepseek (CONCERN-2)
**Статус:** Авто-исправлено
**Ответ:** SketchUp может показывать C++-level модальные диалоги (например warning о пустой модели на некоторых версиях, low-memory warning). Эти диалоги блокируют SketchUp UI thread до пользовательского dismiss; Ruby `rescue StandardError` их не перехватывает. Python-сторона получает timeout.
**Действие:** Design §12 risks: новый bullet «SketchUp native modal dialogs» — описывает limitation, поясняет что inner begin/rescue для zoom_extents покрывает Ruby-level вариант, native escape остаётся environmental responsibility.

---

### [I22] Нет nil guard для `bounds.center` в build_preset_camera

**Источник:** ollama/deepseek (CONCERN-5)
**Статус:** Отклонено (false positive)
**Ответ:** Сами deepseek признают «In reality SketchUp `bounds.center` always returns a point (origin for empty model), so this is not a bug; the lack of explicit check just leaves code less defensive against future API changes.» Existing fallback (`bounds.diagonal == 0` → 1000.0) уже handle'ит empty-model case. Adding `nil` guard for hypothetical future API change без evidence of breakage — defensive coding против non-existent issue.

---

### [I24] Design §5.3 ссылается на несуществующий §11 «Default shaded variant»

**Источник:** ollama/deepseek (SUGGESTION-2)
**Статус:** Авто-исправлено
**Ответ:** Битая ссылка на не существующий пункт §11. Underlying question (Texture true/false default для shaded style) — реальный open decision.
**Действие:** Design §11: добавлен новый row «Default shaded variant» — default `RenderMode = 2` only (Texture не трогается); alternative — re-add `style="shaded_textured"` (RenderMode = 3) if user demand emerges. §5.3 shaded-row wording обновлён — «Texture is intentionally left untouched», ссылка теперь valid.

---

### [I25] PRESET_DIR vectors не нормализованы — нужен комментарий

**Источник:** ollama/deepseek (SUGGESTION-3)
**Статус:** Авто-исправлено
**Ответ:** `PRESET_DIR["iso"]` = `(1, -1, 1)` — это direction vector, не unit. Нормализация происходит позже через `offset.length = dist`. Без явного комментария читатель может задуматься почему не unit-vector.
**Действие:** Plan Task 6.1: блок PRESET_DIR теперь имеет explicit комментарий «NOT pre-normalized — `iso` is (1,-1,1), not (1/√3,-1/√3,1/√3). Normalization happens at use site via `offset.length = dist` in `build_preset_camera`. Kept unnormalized for readability of intent (axis-aligned ↔ unit, iso ↔ unit cube corner).»

---

### [I26] pyproject.toml testpaths корректен — confirmation, не issue

**Источник:** ollama/deepseek (SUGGESTION-4)
**Статус:** Отклонено (это не issue, а confirmation)
**Ответ:** deepseek прямо говорит «Confirming: pyproject.toml:50 has testpaths = ["tests"]. New tests are created in tests/ per the plan — correct.» Никаких действий не нужно.

---

## Изменения в документах

| Файл | Изменение |
|------|-----------|
| `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-design.md` | §5.2 row для view_preset — visible_bounds + ortho height note; §5.3 shaded row — fixed §11 link, Texture wording; §5.4 step 1 — 2D camera guard; §5.6 edge cases — bullets для 2D camera + (modal dialogs covered by §12); §5.8 _raw_call mechanics — does NOT convert ConnectionError; §6.2 prompt body — narrowed return-shape; §7.2 testing table — replaced send_action row, added 2D guard tests + ortho test + visible_bounds spy tests; §11 — added Default shaded variant entry; §12 risks — modal dialogs bullet + large response UI blocking bullet; §13 — Supported SketchUp version note + narrowed acceptance с двух-layer описанием |
| `docs/superpowers/plans/2026-05-16-viewport-screenshot-and-prompt-plan.md` | File Structure line 26 — removed send_action wording, added helpers/geometry; Task 2.1 prompt narrow + Unicode ≈ ×; Task 3.1 removed _format fallback; Task 4.0 _raw_call mechanics rewritten (no ConnectionError conversion) + _call with original text; Task 4.2 screenshot wrapper — explicit ConnectionError catch + raise SketchUpError; Task 5.1 — strengthened camera restore tests + 2D guard tests + ortho test + visible_bounds spy tests; Task 6.0 NEW — visible_bounds helper; Task 6.1 — handler 2D guard + visible_bounds usage + ortho height + PRESET_DIR comment; Task 6.6 commit message + helpers/geometry.rb in add list; Task 7.2 smoke renumber + strong assertions + step text update; Task 8.2 — SU 2026 note in CLAUDE.md; Task 9.1 cookbook snippet rewrite (direct camera, deep-copy, RenderMode, compression comment fix) + SU 2026 caveat block |
| `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-review-merged-iter-2.md` | NEW — merged review from 3 successful agents + failure notes for kimi/minimax |
| `docs/superpowers/specs/2026-05-16-viewport-screenshot-and-prompt-review-iter-2.md` | NEW — this file |

## Статистика

- **Всего замечаний (raw):** 26
- **Actionable (после дедупликации):** 22
- **Дубликатов слито:** 4 (I13→I10, I18→I5, I21→I8, I23→I1)
- **Автоисправлено (без обсуждения):** 8 (I6, I8, I9, I11, I19, I20, I24, I25)
- **Авто-применено повторов:** 5 (I1, I2, I3, I10, I15 — все unfinished iter-1 sync)
- **Обсуждено с пользователем:** 6 (I4, I5, I7, I12, I16, I17 — все приняли recommended Variant A или Variant B для I17)
- **Отклонено:** 3 (I14, I22, I26)
- **Повторов (полный auto-answer без действий):** 0 (все REPEAT entries требовали doc sync)
- **Пользователь сказал «стоп»:** Нет
- **Агенты launched:** 5 (codex, ccs/glm, ollama-kimi/minimax/deepseek)
- **Агенты с успешным ревью:** 3 (codex, ccs/glm, ollama/deepseek)
- **Агенты с infrastructure failure:** 2 (ollama/kimi, ollama/minimax — upstream Ollama daemon dropped mid-stream)

## Особо ценный вклад

1. **Согласованность документов** — три ревьюера независимо обнаружили что iter-1 sync sweep не дошёл до cookbook snippet и Plan Task 6.6 commit message. 5 REPEAT-issues — это критически важный clean-up phase, без которого implementer мог бы воспроизвести rejected паттерны прямо из reference docs.
2. **Architectural detail для `_raw_call`** (I4) — iter-1 решил «extract _raw_call», но не определил точный механизм ConnectionError handling. Ревьюеры iter-2 поймали three connected fallout (brittle string match, dead code, error text regression). Variant A решение убирает их одним движением.
3. **2D camera edge case** (I5) — codex поймал блочный case, где deep-copy snapshot восстановит обычную камеру, но silently потеряет 2D / match-photo state. Fail-fast guard сохраняет «non-destructive by default» promise.
4. **Visible bounds для preset framing** (I19) — codex заметил inconsistency: screenshot respects hidden geometry, но preset framing использует `model.bounds` который включает hidden. Helper `visible_bounds` восстанавливает symmetry.

## Стоит ли третья итерация?

Из 22 actionable issues — все обработаны. Из 6 disputed — все resolved с явным пользовательским выбором. Из 5 REPEAT — все были unfinished doc-sync sweeps, не новые споры. Никаких open questions не остаётся.

Возможные триггеры для iter-3:
- Если live SU 2026 verification обнаружит что-то новое во время implementation (e.g. visible_bounds helper неожиданно медленный, или 2D guard детектит false positives).
- Если implementer обнаружит структурную проблему в обновлённом `_raw_call` mechanism после написания тестов.

Иначе можно идти на implementation.
