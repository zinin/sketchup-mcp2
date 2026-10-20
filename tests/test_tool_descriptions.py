"""T-05: контракт с LLM — докстринг и Field(description) это ЕДИНСТВЕННОЕ,
что видит модель. Тесты держат 100%-покрытие описаний и отсутствие утечек
внутренних заметок."""
import json
from pathlib import Path

from sketchup_mcp.app import mcp
import sketchup_mcp.tools  # noqa: F401 — регистрация тулов
from test_compat import _ruby_const

_OPERATIONS_RB = (
    Path(__file__).resolve().parent.parent
    / "mcp_for_sketchup" / "mcp_for_sketchup" / "handlers" / "operations.rb"
)


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
        # Реальная форма stats из operations.rb::run_edge_op — ключа "failed"
        # не существует; дрейф докстринга от wire-формы ловится здесь.
        "chamfer_edge": "stats{attempted, succeeded, subtract_failed, "
                        "skipped_no_match, skipped_seam, skipped_concave, "
                        "skipped_curved}",
        "fillet_edge": "stats{attempted, succeeded, subtract_failed, "
                       "skipped_no_match, skipped_seam, skipped_concave, "
                       "skipped_curved}",
    }
    for name, frag in expected_fragments.items():
        # Пробелы схлопываются: перенос строки внутри фрагмента (stats{...}
        # у chamfer_edge/fillet_edge занимает две строки) пин не ломает.
        desc = " ".join((tools[name].description or "").split())
        assert frag in desc, f"{name}: Returns-пин «{frag}» не найден в докстринге"


async def test_edge_op_docstrings_name_the_ruby_budget():
    """T3-d: «30 s» в докстрингах chamfer_edge/fillet_edge — это
    EDGE_OP_BUDGET_S из operations.rb. Бюджет проверяется перед каждым резом,
    поэтому докстринг обещает не «не дольше 30 s», а «после 30 s новый рез не
    начинается». Смена константы без правки докстрингов ловится здесь."""
    budget = float(_ruby_const("EDGE_OP_BUDGET_S", _OPERATIONS_RB))
    phrase = f"starts no new cut after {budget:g} s"
    tools = {t.name: t for t in await mcp.list_tools()}
    for name in ("chamfer_edge", "fillet_edge"):
        desc = " ".join((tools[name].description or "").split())
        assert phrase in desc, f"{name}: в докстринге нет «{phrase}» (EDGE_OP_BUDGET_S)"


async def test_set_material_lists_named_colors():
    tools = {t.name: t for t in await mcp.list_tools()}
    desc = tools["set_material"].description or ""
    for color in ("red", "wood", "gray", "#rrggbb"):
        assert color in desc, f"set_material: не перечислен {color}"


async def test_group_only_tools_say_other_entities_fail():
    """M-04: delete_component и transform_component работают только с группами
    и экземплярами компонентов; id грани или ребра из get_selection даёт -32602.
    Докстринг — единственное, что об этом знает модель, поэтому фраза
    пинится."""
    tools = {t.name: t for t in await mcp.list_tools()}
    fragments = {
        "delete_component": "Raw faces, edges and other entities fail with -32602.",
        "transform_component": "Groups and component instances only; "
                               "other entities fail with -32602.",
    }
    for name, frag in fragments.items():
        desc = " ".join((tools[name].description or "").split())
        assert frag in desc, f"{name}: в докстринге нет «{frag}»"


async def test_export_scene_says_an_untitled_model_cannot_export_skp():
    """M-05: .skp-экспорт несохранённой модели отклоняется (-32602) намеренно
    (раньше T-27 сохранял её во временный файл и возвращал `warning`). Фраза
    об отказе пинится; поля `warning` в описании больше нет, ответ —
    {path, format}."""
    tools = {t.name: t for t in await mcp.list_tools()}
    tool = tools["export_scene"]
    desc = " ".join((tool.description or "").split())
    for frag in ("An untitled model cannot be exported to skp (-32602)",
                 "the user must save it first",
                 "Returns: JSON {path, format}."):
        assert frag in desc, f"export_scene: в докстринге нет «{frag}»"
    text = desc + json.dumps(tool.inputSchema)
    assert "warning" not in text.lower(), "export_scene: поле warning больше не существует"
