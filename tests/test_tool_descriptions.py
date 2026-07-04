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
        # Реальная форма stats из operations.rb::run_edge_op — ключа "failed"
        # не существует; дрейф докстринга от wire-формы ловится здесь.
        "chamfer_edge": "stats{attempted, skipped_no_match, subtract_failed, succeeded}",
        "fillet_edge": "stats{attempted, skipped_no_match, subtract_failed, succeeded}",
    }
    for name, frag in expected_fragments.items():
        desc = tools[name].description or ""
        assert frag in desc, f"{name}: Returns-пин «{frag}» не найден в докстринге"


async def test_set_material_lists_named_colors():
    tools = {t.name: t for t in await mcp.list_tools()}
    desc = tools["set_material"].description or ""
    for color in ("red", "wood", "gray", "#rrggbb"):
        assert color in desc, f"set_material: не перечислен {color}"
