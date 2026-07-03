# Deep-Review Batch 2 (P1-остатки + P2 + UX-квиквины) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Закрыть все оставшиеся P1/P2-находки deep-research-аудита (T-05, T-07, T-06, T-11…T-19, T-21…T-23, T-25…T-29), три кандидата финального mesh-ревью батча 1 (MR-1 partial-EOF retry, MR-2 min-dimensions, MR-3 rotated-board coverage) и три живых UX-квиквина (T-50, T-54, T-55) — одним батчем на ветке `fix/deep-review-p2`, финиш — единый PR в master с обоими батчами.

**Architecture:** Проект — мост Claude ↔ SketchUp: Python MCP-сервер (`src/sketchup_mcp/`, FastMCP + persistent TCP-клиент) и Ruby-расширение (`mcp_for_sketchup/mcp_for_sketchup/`, TCP-сервер внутри SketchUp). JSON-RPC 2.0 поверх 4-байтового length-prefix фрейминга. Все правки локальны; wire-протокол и handshake НЕ меняются. Дизайн-первоисточник: `docs/superpowers/specs/2026-07-02-deep-review-batch2-design.md`.

**Tech Stack:** Python ≥3.10 (pytest, pytest-asyncio `asyncio_mode=auto`, pydantic v2/FastMCP, mcp locked `>=1.27,<2`), Ruby 3.2 (minitest, stdlib + rubyzip только в package-тесте), GitHub Actions (уже настроен).

## Global Constraints

- **Единицы:** на границе MCP — миллиметры и градусы; внутри SketchUp — дюймы. Конвертация `MM = 25.4` (`helpers/units.rb`).
- **`Group#subtract` РЕВЕРСИРОВАН:** `A.subtract(B)` возвращает `B − A`. НИКОГДА не «исправлять» порядок аргументов; тесты `test/test_boolean_direction.rb`, `test/test_operation_names.rb` пинят это намеренно.
- **Literal source-guard тесты** пинят точный текст хендлеров (вплоть до отступов): `test/test_operation_names.rb`, `test/test_transform_absolute.rb`, `test/test_joints_frame_compensation.rb`. НИКАКИХ авто-форматтеров; при рефакторинге пины обновлять осознанно, отдельным шагом.
- **Ruby-тесты:** каждый `test/test_*.rb` обязан проходить (a) standalone `ruby test/test_<name>.rb` и (b) в одном процессе `ruby test/run_all.rb`. Глобальные стабы (`module Sketchup`, `module Geom`) — либо guarded (`unless defined?(...)`) для не-реопенимых конструкций (Struct, классы с константами), либо **аддитивный реопен классов** (эталон: шапка `test/test_collect_components.rb`) — реопен предпочтителен, когда файлу нужны конкретные аксессоры: guarded-скип чужого скупого стаба их бы не дал. Singleton-поверхности патчить в `setup`/`teardown` с сохранением `Method`-объекта (эталон: `test/test_collect_components.rb`, патч `Helpers::Entities.active_model!`); ⚠ это касается И модульных `def self.`-методов — они СУТЬ singleton-методы, «снять стаб» через `remove_method` без сохранённого `Method` под run_all удаляет реальный метод насовсем.
- **Прогоны и базлайны на старте батча:** Ruby — `ruby test/run_all.rb` → **354 runs / 939 assertions / 0 failures / 0 errors** (~1.4 с); Python — `uv run pytest tests/ -q` → **136 passed** (~2.4 с). На старте исполнения ПЕРЕПРОГНАТЬ оба базлайна и зафиксировать фактические числа в ledger (счётчики CLAUDE.md могли устареть).
- **Версии не бампаем** (ни `pyproject.toml`/`__init__.py`, ни Ruby `Compat::SERVER_VERSION`, ни `package.rb VERSION`, ни `extension.json`) — все четыре сейчас `0.2.0`. Wire-протокол/handshake не трогаем.
- **Contract break копится:** T-07/T-50/T-54 добавляют параметры, T-27/T-28/T-55 меняют формы ответов. Фиксация — в `docs/release.md`, блок «Pending contract break» (Task 16); MIN-floor'ы здесь НЕ трогаем.
- **Коммиты:** английские, conventional (`fix:`/`test:`/`feat:`/`docs:`), без AI-атрибуции. Рабочая директория — корень репо, ветка `fix/deep-review-p2`.
- **Отчёт-первоисточник** (`docs/deep-research-review-report.md`) закоммичен в ДРУГОЙ ветке (`docs/deep-research-review`); план самодостаточен, идентификаторы T-xx/MR-x — трассировка. ⚠ Номера строк в тикетах датируются 2026-06-12 — искать по содержимому.
- Python-окружение — через `uv` (`uv run pytest tests/ -q`). НЕ трогать `.venv.broken-task8/` и untracked-мусор корня до Task 16.

## Карта задач

| # | Тикеты | Суть | Волна |
|---|---|---|---|
| 1 | T-12, T-26 | config.py: валидация ENV + тест-гигиена reload | 1: Python-ядро |
| 2 | T-11 | connection.py: UnicodeDecodeError + голый OSError | 1 |
| 3 | MR-1 | retry read-only при partial-EOF | 1 |
| 4 | T-21, T-22 | версии: metadata-тест + Ruby-тройка; валидация через реальные схемы | 1 |
| 5 | T-06 | entity id как int \| str | 2: сигнатуры |
| 6 | T-50, T-54 | create_component: name + видимый дефолт dimensions | 2 |
| 7 | T-07 | пагинация list/find + быстрый get_component_info | 2 |
| 8 | T-55 | пустой bbox → null вместо сентинела 2.54e31 | 2 |
| 9 | T-28 | скриншот: метаданные width/height/preset/style | 2 |
| 10 | T-13 | server.rb: батч устойчивости ×5 | 3: Ruby-надёжность |
| 11 | T-14, T-15, T-19, T-27 | compat-сообщение, OBJ-ключ, Logger-guard, export-warning | 3 |
| 12 | T-16 | make_unique перед мутацией definition-entities | 3 |
| 13 | T-17, MR-2, T-18 | валидация параметров + min-dims + case-insensitive поиск | 3 |
| 14 | T-23, MR-3 | Ruby-тестовые пробелы + rotated-board coverage | 4: тесты/контракт |
| 15 | T-05 | докстринг-оверхол 22 тулов + prompts.py sync | 4 |
| 16 | T-25, T-29 | зачистка доков, .gitignore, entry-points, release.md | 5: финиш |
| 17 | — | финальная верификация, счётчики, smoke-синк | 5 |

Порядок строгий: 5–9 (сигнатуры) до 15 (T-05 документирует финальное API); 10 до 14 (T-23 тестирует новые пути server.rb); 13 до 15 (валидация меняет схемы); 16–17 последними. Задачи 7, 8, 13 трогают `handlers/model.rb` — выполнять последовательно, не параллелить.

---

### Task 1: config.py — валидация ENV-переменных (T-12) + тест-гигиена reload (T-26)

✅ Done — see commits: `5b32278` (T-12), `82b9093` (T-26)

### Task 2: connection.py — дыры таксономии исключений (T-11)

✅ Done — see commit: `a486f86`

### Task 3: retry read-only тулов при partial-EOF (MR-1)

✅ Done — see commit: `c054fdc`

### Task 4: Версионные guard'ы и валидация через реальные схемы (T-21 + T-22)

✅ Done — see commit: `4685036`

### Task 5: Entity id как `int | str` (T-06)

✅ Done — see commit: `31733a5`

### Task 6: create_component — `name` + видимый дефолт dimensions (T-54 + T-50)

✅ Done — see commit: `27e1fb5`

### Task 7: Пагинация интроспекции + быстрый lookup (T-07)

✅ Done — see commit: `48eb213`

### Task 8: Пустой bbox → null вместо сентинела 2.54e31 (T-55)

✅ Done — see commit: `889293e` (incl. 4 sanctioned require_relative lines in legacy test headers — see .superpowers/sdd/progress.md)

### Task 9: Скриншот — метаданные width/height/preset/style (T-28)

✅ Done — see commit: `aa9aa39`

### Task 10: server.rb — батч устойчивости ×5 (T-13)

✅ Done — see commits: `34bd3db`, `390ba6d`, `c29c590`, `85688af`, `43e2d88` (5 sub-fixes T-13.1–13.5)

### Task 11: Ruby-мелочь — compat-сообщение, OBJ-ключ, Logger-guard, export-warning (T-14 + T-15 + T-19 + T-27)

✅ Done — see commits: `ac01d80`, `74c5955`, `d4cb531`, `bca648f` (T-14, T-15, T-19, T-27)

### Task 12: make_unique перед мутацией definition-entities (T-16)

✅ Done — see commit: `ef85f89`

### Task 13: Валидация параметров + min-dims + case-insensitive поиск (T-17 + MR-2 + T-18)

✅ Done — see commit: `16fed5e` (incl. LOOKUP_MAX_DEPTH comment fix — ACTION from Task 7 review)

### Task 14: Ruby-тестовые пробелы + rotated-board coverage (T-23 + MR-3)

✅ Done — see commits: `aee1edb`, `07f6526`, `ecd3e01`, `2194e7e`, `5e545f4` (5th commit = controller-sanctioned T-55 follow-up pins, see .superpowers/sdd/progress.md)

### Task 15: Докстринг-оверхол всех 22 тулов + синк prompts.py (T-05)

**Files:**
- Modify: `src/sketchup_mcp/tools.py` (все регистрации)
- Modify: `src/sketchup_mcp/prompts.py` (§1, §4)
- Test: `tests/test_tool_descriptions.py` (новый), `tests/test_prompts.py` (пины могут потребовать осознанного обновления)

**Interfaces:**
- Consumes: финальные сигнатуры Task 5–9, 13 (EntityId, name, пагинация, метаданные скриншота, констрейнты).
- Produces: только описания — ни одной смены поведения/wire. Каждый параметр каждого тула получает `Field(description=...)`; каждый докстринг — units и строку «Returns:».

**Формы ответов (сверено с хендлерами — для строк «Returns:»):**

| Тул | Returns (JSON) |
|---|---|
| create_component, transform_component, set_material, boolean_operation | `{id, name, type, bbox_mm{min,max} \| null}` |
| chamfer_edge | то же + `edges_chamfered`, `stats{attempted, failed}` |
| fillet_edge | то же + `edges_filleted`, `stats{attempted, failed}` |
| create_mortise_tenon | `{mortise: {...}, tenon: {...}, boolean_cuts{attempted, failed}}` |
| create_dovetail | `{tail: {...}, pin: {...}, boolean_cuts{attempted, failed}}` |
| create_finger_joint | `{board1: {...}, board2: {...}, boolean_cuts{attempted, failed}}` |
| delete_component, undo | `{ok: true}` |
| export_scene | `{path, format[, warning]}` |
| get_model_info | `{path, title, units:"mm", bounding_box_mm \| null, entity_count, layers[]}` |
| list_components, find_components | `{components[], total, offset, truncated}` |
| get_component_info | `{id, name, type, layer, depth, bbox_mm \| null}` |
| list_layers | `{layers: [{name, visible, color, id}]}` |
| create_layer | `{id, name, visible}` |
| get_selection | `{entities: [...]}` |
| get_version | JSON-вердикт совместимости (докстринг уже полон — не трогать содержательно) |
| eval_ruby | строка: `.to_s` последнего выражения |
| get_viewport_screenshot | `[Image PNG, JSON {width, height, preset_used, style_used}]` |

- [ ] **Step 0 (P-12): инвентаризация маинтейнерских заметок**

Run: `grep -n "Ruby tool name\|Pydantic\|pydantic\|NOTE:\|Note:\|Note on" src/sketchup_mcp/tools.py`

Найдено на момент правки плана (сверить свежим grep'ом перед исполнением) — все ПЯТЬ переносятся в `#`-комментарии над функциями (правило 4 ниже):
- `:174` — `"""Export the current scene. Note: Ruby tool name is 'export'."""`
- `:193` — `...Pydantic always sends these...` (create_mortise_tenon)
- `:326-327` — `...Ruby tool name is ``chamfer_edges`` (plural); Python parameter ``id`` maps to Ruby ``entity_id``.`
- `:341-342` — `Note: Ruby tool name is ``fillet_edges`` (plural); ...maps to Ruby parameter ``entity_id``.`
- `:377` — `Note on operation order (Ruby handler): snapshot → preset → style → ...` (get_viewport_screenshot)

- [ ] **Step 1: RED — новый файл `tests/test_tool_descriptions.py`**

```python
"""T-05: контракт с LLM — докстринг и Field(description) это ЕДИНСТВЕННОЕ,
что видит модель. Тесты держат 100%-покрытие описаний и отсутствие утечек
внутренних заметок."""
import json

from sketchup_mcp.app import mcp
import sketchup_mcp.tools  # noqa: F401 — регистрация тулов


async def test_every_tool_parameter_has_description():
    tools = await mcp.list_tools()
    assert len(tools) == 22
    missing = []
    for tool in tools:
        for pname, pschema in tool.inputSchema.get("properties", {}).items():
            if not pschema.get("description"):
                missing.append(f"{tool.name}.{pname}")
    assert not missing, f"параметры без Field(description=...): {missing}"


async def test_no_internal_notes_leak_into_llm_visible_text():
    tools = await mcp.list_tools()
    for tool in tools:
        text = (tool.description or "") + json.dumps(tool.inputSchema)
        assert "Ruby tool name" not in text, f"{tool.name}: маинтейнерская заметка утекла"
        assert "pydantic" not in text.lower(), f"{tool.name}: внутренняя заметка утекла"


async def test_dimension_tools_mention_units():
    # P-08: export_scene ИСКЛЮЧЁН — у него нет линейных мм-параметров
    # (разрешение рендера в пикселях), units-требование к нему неверно.
    tools = {t.name: t for t in await mcp.list_tools()}
    for name in ("create_component", "transform_component", "chamfer_edge",
                 "fillet_edge", "create_mortise_tenon", "create_dovetail",
                 "create_finger_joint"):
        desc = tools[name].description or ""
        assert ("mm" in desc) or ("millimeter" in desc.lower()), f"{name}: нет units"


async def test_returns_lines_pin_top_response_shapes():
    """C-05: units/описания — это форма; Returns-строки топ-5 тулов пинятся
    СОДЕРЖАТЕЛЬНО, чтобы неверная форма ответа в докстринге не прошла тесты."""
    tools = {t.name: t for t in await mcp.list_tools()}
    expected_fragments = {
        "create_component": "{id, name, type, bbox_mm{min,max}|null}",
        "set_material": "{id, name, type, bbox_mm{min,max}|null}",
        "boolean_operation": "bbox_mm",
        "create_mortise_tenon": "boolean_cuts",
        "list_components": "truncated",
    }
    for name, frag in expected_fragments.items():
        desc = tools[name].description or ""
        assert frag in desc, f"{name}: Returns-пин «{frag}» не найден в докстринге"


async def test_set_material_lists_named_colors():
    tools = {t.name: t for t in await mcp.list_tools()}
    desc = tools["set_material"].description or ""
    for color in ("red", "wood", "gray", "#rrggbb"):
        assert color in desc, f"set_material: не перечислен {color}"
```

Run: `uv run pytest tests/test_tool_descriptions.py -q` → 5 FAIL (описаний нет; заметки «Ruby tool name» / «Pydantic» на месте; цвета не перечислены; Returns-пинов нет).

- [ ] **Step 2: GREEN — tools.py, общие правила**

Единые правила для ВСЕХ 22 тулов (применить к каждому):
1. У каждого параметра — `Annotated[..., Field(..., description="...")]`. Для id-параметров единый текст: `"Entity ID from a previous response (integer or its string form)"`.
2. Каждый докстринг с линейными величинами говорит «millimeters (mm)»; углы — «degrees».
3. Последняя строка докстринга — «Returns: …» из таблицы выше (+ у мутирующих: «Read bbox_mm to verify the result; it is null for empty geometry»).
4. Маинтейнерские заметки («Note: Ruby tool name is 'export'», «Pydantic always sends…», «Ruby parameter ``id`` maps to…») ПЕРЕНОСЯТСЯ из докстрингов в `#`-комментарии над функцией — они нужны разработчику, не модели.
5. НЕ менять: имена/типы/дефолты параметров, wire-пробросы (пины Task 4–13 обязаны остаться зелёными).
6. ⚠ M-11: новые тексты докстрингов и `Field(description=...)` НЕ должны содержать подстроки «Ruby tool name» и «pydantic» (в любом регистре) — их ищет leak-тест; случайное употребление уронит его.

Точные тексты ключевых докстрингов:

- `create_component`:

```python
    """Create a primitive (cube / cylinder / cone / sphere) in SketchUp.

    All linear values are millimeters (mm). Minimum size per dimension:
    0.1 mm for cube (thin stock like veneer is fine), 1.0 mm for sphere /
    cylinder / cone (tessellated types degenerate earlier). position is the
    bounding-box MIN corner (not the center); the same anchor is used by
    transform_component.position. Per-type dimensions: cube uses [x, y, z];
    cylinder and cone use [0]=diameter, [2]=height ([1] is ignored); sphere
    uses [0]=diameter only. New geometry is wrapped in a SketchUp Group.

    Returns: JSON {id, name, type, bbox_mm{min,max}|null}. Read bbox_mm to
    verify the result before the next step.
    """
```

- `transform_component` — существующий докстринг уже описывает семантику; добавить строку Returns из таблицы и `Field(description=...)` на id/position/rotation/scale (тексты: position — «ABSOLUTE target for the bbox-min corner, mm»; rotation — «relative degrees around bbox center, applied X then Y then Z»; scale — «relative factors about bbox center, each |s| > 1e-9»). C-08: добавить в докстринг фразу, что эти проверки действуют только на типизированном туле — прямой Ruby через eval_ruby их минует (escape hatch).
- `set_material`:

```python
    """Assign a material (color) to a group or component.

    material accepts a named color — red, green, blue, yellow, cyan,
    turquoise, magenta, purple, white, black, brown, wood, orange, gray,
    grey — or a 6-digit hex string like "#a05030" (#rrggbb). Anything else
    fails with error -32602. Named colors are case-insensitive. Painting
    affects only this instance (it is made unique first).

    Returns: JSON {id, name, type, bbox_mm{min,max}|null}.
    """
```

- `export_scene` (заметку про Ruby-имя — в `#`-комментарий):

```python
    """Export the current scene to a temp file on the SketchUp host.

    Formats: skp (native), obj / dae / stl (geometry), png / jpg (viewport
    render, default 1920×1080). The file is written on the machine running
    SketchUp — on a split-host setup the path is not directly readable here.

    Returns: JSON {path, format} plus a "warning" field when exporting skp
    from a never-saved model (SketchUp binds the live document to the export
    path — relay the warning to the user).
    """
```

- `eval_ruby` — дополнить существующий докстринг абзацем:

```python
    Returns the .to_s of the LAST evaluated expression; stdout (puts) is NOT
    captured. End scripts with an explicit expression — e.g. a final
    `result.to_json` — to get structured data back. Errors return
    "[code] message" with the Ruby exception class and message.
```

- `chamfer_edge` / `fillet_edge` — докстринги без Ruby-имён:

```python
    """Chamfer (bevel) edges of a group/component by ``distance`` mm.

    By default ALL edges are chamfered. Unreliable on non-manifold geometry.

    Returns: JSON {id, name, type, bbox_mm|null, edges_chamfered,
    stats{attempted, failed}} — check stats.failed == 0.
    """
```

(fillet аналогично: «Round (fillet) edges … by ``radius`` mm with ``segments`` arc segments … edges_filleted …».)

- `create_mortise_tenon` / `create_dovetail` / `create_finger_joint` — единый шаблон:

```python
    """Create a mortise-and-tenon joint between two boards.

    All dimensions in millimeters; offsets shift the joint from the board
    face's center. Defaults are sized for ~100 mm boards. The two boards must
    already touch/overlap along the joint axis.

    Returns: JSON {mortise: {id, name, type, bbox_mm|null}, tenon: {...},
    boolean_cuts: {attempted, failed}} — non-zero failed means some cuts did
    not apply (likely non-manifold geometry); verify via bbox_mm.
    """
```

(dovetail: `{tail, pin, boolean_cuts}`, упомянуть `angle` — degrees, (0, 60]; finger: `{board1, board2, boolean_cuts}`.)

- `list_components` / `find_components` — Returns-строка `{components[], total, offset, truncated}` + «if truncated, request the next page with offset += limit»; `find_components`: «name matching is case-insensitive substring».
- `get_model_info`, `get_component_info`, `list_layers`, `create_layer`, `undo`, `get_selection`, `delete_component` — короткие докстринги + Returns из таблицы; у `get_component_info`/`delete_component` id-описание как выше.
- `get_viewport_screenshot` — параметрам добавить description; докстринг уже переписан в Task 9. P-14: добавить фразу «if the connection drops mid-response the call is retried automatically; the viewport may briefly flicker in that rare case» (тул остаётся в retry-whitelist: restore камеры отрабатывает в ensure до записи ответа — повтор идемпотентен).
- `boolean_operation` — Returns + «difference = target minus tool»; `delete_originals` description: «erase the two source bodies after a successful operation»; C-10: добавить фразу «operating on an instance of a shared definition consumes only that instance — the result is a new group, sibling instances are untouched».

- [ ] **Step 3: prompts.py — синк**

3a. §1: строку про `list_components` дополнить: `(paginated: check "truncated" and page with offset/limit)`.

3b. §4 — заменить первые два пункта:

```
- Geometry, material, boolean, and edge tools return
  {id, name, type, bbox_mm} (edge tools add edges_*/stats). bbox_mm is null
  when the entity ended up with no geometry (e.g. a boolean difference
  consumed the whole body) — treat null as "inspect what happened", not as
  an error. When bbox_mm is present, read it to confirm the result matches
  the intent before the next step (and to relocate the entity if its id
  becomes stale after destructive operations).
- Joinery tools return ONE OBJECT PER BOARD — {mortise, tenon} /
  {tail, pin} / {board1, board2}, each {id, name, type, bbox_mm} — plus
  boolean_cuts {attempted, failed}: treat failed > 0 as a partial failure
  and verify via bbox_mm.
- Other tools — delete_component, create_layer, undo, list/find
  queries, get_model_info, get_selection — have their own response
  shapes; see the tool docs.
```

3c. §3: добавить пункты `- create_component minimum dimension: 0.1 mm for cube, 1.0 mm for curved types; defaults are a 100 mm cube.` и (M-12) `- create_component accepts an optional name — set it so find_components can locate the part later.`

- [ ] **Step 4: Прогнать + commit**

Run: `uv run pytest tests/ -q`
Expected: **176 passed** (171 + 5). ⚠ `tests/test_prompts.py` пинит фрагменты стратегии — если пины упали, обновить их под новый текст ОСОЗНАННО (в том же коммите). Wire-пины (`test_tool_wrapper_calls_ruby_correctly`) обязаны пройти без правок — поведение не менялось.

```bash
git add src/sketchup_mcp/tools.py src/sketchup_mcp/prompts.py tests/test_tool_descriptions.py tests/test_prompts.py
git commit -m "docs: overhaul LLM-visible descriptions of all 22 tools, sync strategy prompt (T-05)"
```

---

### Task 16: Зачистка документации + entry-points + release.md (T-25 + T-29)

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `docs/release.md`, `.gitignore`
- Modify: `src/sketchup_mcp/server.py` (докстринг), `pyproject.toml`, `src/sketchup_mcp/app.py`
- Modify: `mcp_for_sketchup/mcp_for_sketchup/helpers/geometry.rb`, `mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog.rb` (только комментарии)
- Delete: `diff.patch`, `docs/session-transfer-*.md` (untracked-мусор корня)

Только доки/комментарии/метаданные — поведенческих правок нет (кроме удаления entry-points группы, которую никто не потребляет).

- [ ] **Step 1 (T-25.1): несуществующие example-скрипты**

- `README.md:137-138`: ТОЛЬКО удалить строки про `arts_and_crafts_cabinet.py` и `simple_test.py, simple_ruby_eval.py, behavior_tester.py` (git log подтверждает: никогда не коммитились). ⚠ C-12: НИЧЕГО не вставлять взамен — корректные строки про `smoke_check.py`/`smoke_multi_client.py` УЖЕ стоят выше (README:135-136), вставка дала бы дубликат.

- `CLAUDE.md:91`: заменить строку `Other example scripts in ...` на:

```markdown
Other example scripts in `examples/`: `smoke_multi_client.py` (multi-client load check).
```

- [ ] **Step 2 (T-25.2): server.py — не «Legacy», а live entry point**

- `CLAUDE.md:135` (таблица Python side): строку `| \`server.py\` | Legacy connection helpers (kept for compat) |` заменить на `| \`server.py\` | CLI entry point (\`[project.scripts]\` → \`sketchup-mcp2\`) |`.
- В таблицу core/ CLAUDE.md добавить `client_state.rb` (строка `| core/ | \`application.rb\`, \`server.rb\`, \`client_state.rb\`, \`framing.rb\`, ... |`).
- `src/sketchup_mcp/server.py`: в докстринге `main()` заменить `\`\`sketchup-mcp\`\`` на `\`\`sketchup-mcp2\`\`` (фактическое имя из `[project.scripts]`).

- [ ] **Step 3 (T-25.3): названия пунктов меню в paste-verbatim инструкциях**

Фактические лейблы меню (main.rb:60-73): **«Start Server» / «Stop Server» / «Restart Server» / «Settings...» / «Show Log»**. Исправить:
- `README.md:48` и `README.md:194`: `Plugins → MCP Server → Start` → `Plugins → MCP Server → Start Server`.
- `docs/release.md:224`, `:258`, `:290`: та же замена (`→ Start` → `→ Start Server`); в :258 также «Repeated Start is idempotent» → «Repeated Start Server is idempotent».

- [ ] **Step 4 (T-25.4): висячие ссылки в комментариях**

- `helpers/geometry.rb` (комментарий над `make_box`): `See CLAUDE.md «make_box» note for context.` → `See docs/sketchup-ruby-cookbook.md (make_box recipe) for context.`
- `ui/settings_dialog.rb` (комментарий в eval-confirm блоке): `same quirk handled at settings_dialog.rb:100 for host/port restart` → `same quirk handled by the host/port restart prompt in this file` (без номера строки — он уехал и уедет снова).

- [ ] **Step 5 (T-25.5): .gitignore + мусор корня**

- В `.gitignore`, в секцию `# Local tooling`, добавить строку `.gemini/`.
- Удалить untracked-мусор: `rm diff.patch docs/session-transfer-*.md`. ⚠ НЕ трогать: `.venv.broken-task8/` (экшн владельца), `docs/superpowers/` (снимется перед PR), `.superpowers/`.

- [ ] **Step 6 (T-25): README stdlib-строка**

`README.md:174`: `ruby test/run_all.rb             # Ruby unit tests (minitest, stdlib only)` → `... (minitest; stdlib + rubyzip for the package test)`.

- [ ] **Step 7 (T-29): entry-points**

- `pyproject.toml`: удалить две строки группы `[project.entry-points.mcp]` (`sketchup = "sketchup_mcp.app:mcp"`) — потребитель неизвестен ни в python-sdk, ни в Claude Desktop/Code.
- `src/sketchup_mcp/app.py`: комментарий над side-effect импортами заменить на:

```python
# Side-effect imports: register tool/prompt handlers on `mcp`. Must come AFTER
# `mcp` is constructed (both modules do `from sketchup_mcp.app import mcp`).
# Without these imports a consumer of `sketchup_mcp.app.mcp` (the
# `sketchup-mcp2` CLI, `python -m sketchup_mcp`) would serve an EMPTY tool
# list — registration happens at import time.
```

- [ ] **Step 8 (T-25/T-04-наследие): release.md «Pending contract break»**

В `docs/release.md`, в конец блока «Pending contract break» (строка ~56) добавить:

```markdown
Batch 2 (branch `fix/deep-review-p2`) widens the same pending break: new tool
parameters (`name`, `limit`/`offset`/`response_format`), stricter validation
(min dimension 1 mm, dovetail angle ≤ 60°, non-zero scale), and changed
response shapes (`list/find_components` pagination envelope, `bbox_mm: null`
for empty bounds, screenshot metadata block, `export` warning field). Same
remedy: the release that ships them MUST bump both MIN floors.
```

- [ ] **Step 9: Прогнать + commit (двумя коммитами)**

```bash
uv run pytest tests/ -q     # 176 passed — pyproject-правка не ломает метаданных
ruby test/run_all.rb        # 0 failures (правки Ruby — только комментарии; но source-guard тесты прогнать обязательно)
git add README.md CLAUDE.md docs/release.md .gitignore src/sketchup_mcp/server.py mcp_for_sketchup/mcp_for_sketchup/helpers/geometry.rb mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog.rb
git commit -m "docs: fix phantom examples, stale server.py role, menu labels, dangling refs (T-25)"
git add pyproject.toml src/sketchup_mcp/app.py
git commit -m "build: drop unconsumed [project.entry-points.mcp] group (T-29)"
```

(`diff.patch` и `docs/session-transfer-*.md` — untracked, их удаляет обычный `rm` из Step 5; в git-историю они не входили.)

⚠ Если `uv run pytest` после правки pyproject.toml потребует переустановку editable-пакета — `uv pip install -e .` и повторить прогон (метаданные должны пересобраться без смены версии).

---

### Task 17: Финальная верификация, счётчики, smoke-синк

**Files:**
- Modify: `examples/smoke_check.py` (ассерты пагинации)
- Modify: `CLAUDE.md` (счётчики тестов)

- [ ] **Step 1: smoke-синк — шаг 16**

В `examples/smoke_check.py`, шаг 16 (`list_components(max_depth=2)`), после строки `ids = [c["id"] for c in lc["components"]]` добавить:

```python
        # T-07: пагинационный конверт — total/truncated обязаны присутствовать;
        # смоук-модель (< 50 entities) не должна усекаться дефолтным limit.
        assert isinstance(lc["total"], int) and lc["total"] >= len(lc["components"])
        assert lc["truncated"] is False, f"unexpected truncation: {lc}"
```

(шаг 17 `find_components` — конверт тот же, отдельного ассерта не требуется; существующий `len(fc["components"]) >= 4` продолжает работать).

- [ ] **Step 2: Полные прогоны + фиксация фактических счётчиков**

```bash
ruby test/run_all.rb        # ориентир: ~413 runs (354 на старте + ~59 новых), 0 failures
uv run pytest tests/ -q     # ориентир: 176 passed
```

Записать ФАКТИЧЕСКИЕ числа из прогонов (не ориентиры!) в `CLAUDE.md:84-85`:
- строка 84: `— 354 runs / 939 assertions` → фактические runs/assertions;
- строка 85: `— 136 tests` → фактическое число passed.

Расхождение с ориентиром при 0 failures — НЕ ошибка (ориентиры статические); задокументировать фактические числа в ledger. Провал любого теста — СТОП, разбираться.

- [ ] **Step 3: Сверка ветки**

```bash
git log --oneline master..HEAD | head -40   # все коммиты Tasks 1-16 на месте
git status --short --untracked-files=no     # tracked-дерево чистое
grep -rn "double_sided_faces" mcp_for_sketchup/ && echo "ОСТАЛСЯ ОПЕЧАТАННЫЙ КЛЮЧ" || true
grep -n "arts_and_crafts" README.md CLAUDE.md || echo "фантомные примеры вычищены"
```

- [ ] **Step 4: Commit**

```bash
git add examples/smoke_check.py CLAUDE.md
git commit -m "docs: refresh test counters, assert pagination envelope in smoke (batch 2 final)"
```

---

## После плана (вне задач — исполнителю и владельцу)

1. **Финальное whole-branch mesh-ревью** (по образцу батча 1: `/claude-mesh:mesh-review default`) — диф двух батчей; per-task ревью уже несут основную нагрузку.
2. **Перед PR:** `git rm -r docs/superpowers/ && git commit` (ветка трекает P1-план, 2 review-спеки, дизайн и план батча 2, а также merged/iter-файлы дизайн-ревью — в PR-дифф не попадают, остаются в истории ветки). ⚠ C-02: git rm снимает ТОЛЬКО tracked; untracked prompt-файлы в `docs/superpowers/plans/` останутся в рабочем дереве — осознанно, это локальный архив владельца, в PR они не попадают. Затем единый PR `fix/deep-review-p2` → master, включающий ОБА батча. В описании PR напомнить владельцу 5 автономных решений батча 1 (см. ledger: пред-фикс `165f214`; commit message «3.10-3.13»; 136 vs «ровно 135»; deepseek принят REAL; спорный source-guard `5de1987`).
3. **Живой DoD (владелец, вручную):** пересобрать `.rbz` (`cd mcp_for_sketchup && ruby package.rb --variant=warehouse`), установить в SketchUp 2026, прогнать `uv run python examples/smoke_check.py` — 25 шагов зелёные (для шага 22 включить eval в Settings или собрать `--variant=github`). Проверяет живьём T-07/T-16/T-54/T-55/T-27. Дополнительно (C-10, руками один раз): скопировать группу (две копии шаренной definition), выполнить `boolean_operation` над одной — вторая обязана остаться нетронутой; это подтверждает границу T-16 «subtract не мутирует definition in-place».
4. **Владелец:** рестарт живого MCP-сервера (нужен и для батча 2 — код Python-сервера изменился) → затем `rm -rf .venv.broken-task8/`.
5. **При следующем релизе:** bump MIN-floor'ов ОБЯЗАТЕЛЕН — блок «Pending contract break» в `docs/release.md` дополнен батчем 2 (Task 16.8).
6. **Остаток бэклога отчёта:** P3 (T-31…T-49, T-51…T-53) + продуктовое решение T-47 (физическое исключение eval.rb из warehouse-сборки — принять до сабмита в Extension Warehouse).




