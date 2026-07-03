"""Tests for sketchup_mcp.tools and sketchup_mcp.errors helpers."""
import pytest

from sketchup_mcp.errors import SketchUpError, format_error


def test_format_error_basic():
    err = SketchUpError(
        -32000,
        "entity not found",
        {"tool": "delete_component", "params": {"id": "123"}},
    )
    assert (
        format_error(err)
        == '[-32000] entity not found — tool=delete_component, params={"id": "123"}'
    )


def test_format_error_debug_adds_timestamp_and_first_three_backtrace():
    err = SketchUpError(
        -32000,
        "boom",
        {
            "tool": "T",
            "params": {},
            "timestamp": "2026-01-01T00:00:00Z",
            "backtrace": ["a.rb:1", "b.rb:2", "c.rb:3", "d.rb:4"],
        },
    )
    out = format_error(err, debug=True)
    assert "ts=2026-01-01T00:00:00Z" in out
    assert "['a.rb:1', 'b.rb:2', 'c.rb:3']" in out
    assert "d.rb:4" not in out


def test_format_error_truncates_huge_params():
    huge = {"code": "x" * 5000}
    err = SketchUpError(-32000, "boom", {"tool": "eval_ruby", "params": huge})
    out = format_error(err)
    assert "...<truncated>" in out
    assert len(out) < 1500  # компактный, а не 5 KiB


def test_format_error_truncates_non_ascii_by_bytes():
    # Каждая кириллическая буква — 2 байта в UTF-8. 1000 символов → ~2000 байт,
    # что превышает 512-байтовый лимит. До фикса режущий по len(str) пропускал
    # 1000 символов через как ~2000 байт.
    huge = {"code": "я" * 1000}
    err = SketchUpError(-32000, "boom", {"tool": "eval_ruby", "params": huge})
    out = format_error(err)
    assert "...<truncated>" in out
    # Граница UTF-8: декодирование с errors='ignore' гарантирует валидную строку.
    out.encode("utf-8")  # не должно бросать
    # Размер сообщения связан с лимитом 512 байт, не 512 символами.
    params_part = out.split("params=", 1)[1]
    assert len(params_part.encode("utf-8")) < 700  # 512 + маркер + запас


import json as _json
from unittest.mock import AsyncMock, MagicMock, patch

# asyncio_mode = "auto" in pyproject.toml → async test functions are
# auto-marked; sync tests stay unmarked. No module-level pytestmark needed.


@pytest.fixture
def mock_send_command():
    """Patch SketchUpConnection.send_command on a fake connection returned by get_connection."""
    fake_conn = MagicMock()
    fake_conn.send_command = AsyncMock()
    with patch(
        "sketchup_mcp.tools.get_connection",
        AsyncMock(return_value=fake_conn),
    ):
        yield fake_conn


@pytest.fixture
def mock_ctx():
    return MagicMock()


async def test_call_extracts_mcp_text_content(mock_send_command, mock_ctx):
    from sketchup_mcp.tools import _call

    mock_send_command.send_command.return_value = {
        "content": [{"type": "text", "text": "result text"}]
    }
    assert await _call(mock_ctx, "test_tool", x=1) == "result text"


async def test_call_returns_json_dump_when_no_mcp_shape(mock_send_command, mock_ctx):
    from sketchup_mcp.tools import _call

    mock_send_command.send_command.return_value = {"some": "thing"}
    assert await _call(mock_ctx, "test_tool") == _json.dumps({"some": "thing"})


async def test_call_handles_connection_error_gracefully(mock_ctx):
    from sketchup_mcp.tools import _call

    with patch(
        "sketchup_mcp.tools.get_connection",
        AsyncMock(side_effect=ConnectionError("refused")),
    ):
        result = await _call(mock_ctx, "x")
    assert "SketchUp not running" in result
    assert "refused" in result


async def test_call_formats_sketchup_error(mock_send_command, mock_ctx):
    from sketchup_mcp.tools import _call

    mock_send_command.send_command.side_effect = SketchUpError(
        -32000, "boom", {"tool": "x", "params": {}}
    )
    result = await _call(mock_ctx, "x")
    assert result.startswith("[-32000] boom")
    assert "tool=x" in result


async def test_call_fills_tool_name_when_error_lacks_it(mock_send_command, mock_ctx):
    """A locally-raised transport error carries no 'tool' in data (renders tool=?);
    _call must fill it from the tool name so format_error shows tool=<name>."""
    from sketchup_mcp.tools import _call

    mock_send_command.send_command.side_effect = SketchUpError(
        -32000, "connection error: Connection lost"
    )
    result = await _call(mock_ctx, "transform_component", id="5")
    assert "tool=transform_component" in result
    assert "tool=?" not in result


# --- T-22: валидация через РЕАЛЬНЫЕ схемы (mcp.call_tool), не TypeAdapter-зеркала.
# Убери Field(gt=0) из tools.py — зеркальный тест продолжил бы зеленеть, а эти
# упадут. Паттерн mcp.call_tool — как в tests/test_screenshot.py.
from sketchup_mcp.app import mcp


@pytest.fixture
def dispatch_conn():
    """Мокнутое соединение для вызовов через mcp.call_tool: валидация должна
    отработать ДО send_command; happy-path возвращает MCP-текст «ok»."""
    conn = MagicMock()
    conn.send_command = AsyncMock(return_value={"content": [{"text": "ok"}]})
    with patch("sketchup_mcp.tools.get_connection", AsyncMock(return_value=conn)):
        yield conn


async def test_schema_rejects_zero_dimension(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("create_component", {"dimensions": [100.0, 0.0, 100.0]})
    assert "dimensions" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()


async def test_schema_rejects_negative_dimension(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("create_component", {"dimensions": [100.0, -2.0, 100.0]})
    assert "dimensions" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()


async def test_schema_rejects_wrong_dimensions_length(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("create_component", {"dimensions": [100.0, 100.0]})
    assert "dimensions" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()


async def test_schema_rejects_unknown_component_type(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("create_component", {"type": "pyramid"})
    assert "type" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()


async def test_schema_rejects_wrong_position_length_in_transform(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("transform_component", {"id": "5", "position": [1.0, 2.0]})
    assert "position" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()


async def test_schema_accepts_valid_create_component(dispatch_conn):
    """Happy-path сквозь реальный дispatcher: валидация пропускает, wire-вызов
    уходит с дефолтами. dimensions заданы явно, чтобы тест не зависел от
    смены дефолта в Task 6 (T-50)."""
    await mcp.call_tool("create_component", {"dimensions": [120.0, 60.0, 40.0]})
    dispatch_conn.send_command.assert_called_once_with(
        "create_component",
        {"type": "cube", "position": [0, 0, 0], "dimensions": [120.0, 60.0, 40.0]},
    )


async def test_schema_accepts_full_transform_combination(dispatch_conn):
    """T-22 (требование дизайна): happy-path полной комбинации
    position+rotation+scale — валидация пропускает, все три уходят на провод
    как есть (пин против случайной потери одного из optional-полей)."""
    await mcp.call_tool("transform_component", {
        "id": "5", "position": [1.0, 2.0, 3.0],
        "rotation": [0.0, 0.0, 90.0], "scale": [2.0, 1.0, 1.0]})
    dispatch_conn.send_command.assert_called_once_with(
        "transform_component",
        {"id": "5", "position": [1.0, 2.0, 3.0],
         "rotation": [0.0, 0.0, 90.0], "scale": [2.0, 1.0, 1.0]})


# --- T-06: id принимается и как int, и как str; на провод уходит str(id) ---

async def test_entity_id_accepts_int_and_forwards_as_str(dispatch_conn):
    """Хендлеры возвращают id как JSON-число; модель, отдающая его обратно
    без кавычек, не должна ловить ValidationError (T-06/PY-TOOLS-05)."""
    await mcp.call_tool("delete_component", {"id": 12345})
    dispatch_conn.send_command.assert_called_once_with(
        "delete_component", {"id": "12345"})


async def test_entity_id_str_passes_unchanged(dispatch_conn):
    await mcp.call_tool("get_component_info", {"id": "67"})
    dispatch_conn.send_command.assert_called_once_with(
        "get_component_info", {"id": "67"})


async def test_boolean_operation_accepts_int_ids(dispatch_conn):
    await mcp.call_tool("boolean_operation", {"target_id": 1, "tool_id": 2})
    dispatch_conn.send_command.assert_called_once_with(
        "boolean_operation",
        {"target_id": "1", "tool_id": "2",
         "operation": "union", "delete_originals": False})


async def test_empty_string_id_still_rejected(dispatch_conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool("delete_component", {"id": ""})
    assert "id" in str(exc_info.value)
    dispatch_conn.send_command.assert_not_called()


async def test_entity_id_schema_exposes_int_and_string():
    """T-06: LLM-видимая схема id обязана предлагать ОБА типа —
    anyOf [{integer}, {string, minLength 1}]. Регистрация union в FastMCP
    проверена пробой на mcp 1.27; пин защищает от тихой деградации схемы
    (например, в {}) при апгрейде mcp."""
    tools = {t.name: t for t in await mcp.list_tools()}
    id_schema = tools["delete_component"].inputSchema["properties"]["id"]
    variants = {v.get("type") for v in id_schema.get("anyOf", [])}
    assert variants == {"integer", "string"}, f"unexpected id schema: {id_schema}"


async def test_bool_id_rejected(dispatch_conn):
    """P-05: bool — подкласс int; без strict-ветки True тихо коэрсился бы в
    id "1". Зелёный и ДО правки (id пока строго str) — роль теста: пин
    против bool-дыры ПОСЛЕ введения int-ветки."""
    with pytest.raises(Exception):
        await mcp.call_tool("delete_component", {"id": True})
    dispatch_conn.send_command.assert_not_called()


@pytest.mark.parametrize(
    "tool_name, kwargs, expected_ruby_name, expected_ruby_kwargs",
    [
        # Имена совпадают, аргументы 1:1
        ("create_component", {"type": "cube", "position": [0, 0, 0], "dimensions": [1, 1, 1]},
         "create_component", {"type": "cube", "position": [0, 0, 0], "dimensions": [1, 1, 1]}),
        ("delete_component", {"id": "1"}, "delete_component", {"id": "1"}),
        ("get_selection", {}, "get_selection", {}),
        ("set_material", {"id": "1", "material": "wood"}, "set_material", {"id": "1", "material": "wood"}),
        ("eval_ruby", {"code": "puts 'x'"}, "eval_ruby", {"code": "puts 'x'"}),
        ("create_mortise_tenon", {"mortise_id": "1", "tenon_id": "2"},
         "create_mortise_tenon", {"mortise_id": "1", "tenon_id": "2",
                                   "width": 50.0, "height": 25.0, "depth": 10.0,
                                   "offset_x": 0.0, "offset_y": 0.0, "offset_z": 0.0}),
        ("create_dovetail", {"tail_id": "1", "pin_id": "2"},
         "create_dovetail", {"tail_id": "1", "pin_id": "2",
                              "width": 50.0, "height": 50.0, "depth": 15.0, "angle": 15.0,
                              "num_tails": 3,
                              "offset_x": 0.0, "offset_y": 0.0, "offset_z": 0.0}),
        ("create_finger_joint", {"board1_id": "1", "board2_id": "2"},
         "create_finger_joint", {"board1_id": "1", "board2_id": "2",
                                  "width": 50.0, "height": 25.0, "depth": 10.0,
                                  "num_fingers": 5,
                                  "offset_x": 0.0, "offset_y": 0.0, "offset_z": 0.0}),
        ("transform_component", {"id": "1"}, "transform_component", {"id": "1"}),
        ("boolean_operation", {"target_id": "1", "tool_id": "2"},
         "boolean_operation", {"target_id": "1", "tool_id": "2",
                                "operation": "union", "delete_originals": False}),
        # Переименованные — критичные mapping'и
        ("export_scene", {"format": "skp"}, "export", {"format": "skp"}),
        ("chamfer_edge", {"id": "1"}, "chamfer_edges", {"entity_id": "1", "distance": 5.0}),
        ("fillet_edge", {"id": "1"}, "fillet_edges", {"entity_id": "1", "radius": 5.0, "segments": 8}),
        # Read-only / introspection tools (без user-параметра name)
        ("get_model_info", {}, "get_model_info", {}),
        ("list_components", {}, "list_components", {"recursive": False, "max_depth": 3}),
        ("list_components", {"recursive": True, "max_depth": 5},
         "list_components", {"recursive": True, "max_depth": 5}),
        ("get_component_info", {"id": "abc"}, "get_component_info", {"id": "abc"}),
        ("list_layers", {}, "list_layers", {}),
        ("undo", {}, "undo", {}),
        # Tools с user-параметром `name=` — regression для kwarg collision с `_call`.
        # До фикса сигнатура `_call(ctx, name, **kwargs)` ловила позиционное
        # tool-name И kwarg-name (через **args), вызывая
        # `TypeError: _call() got multiple values for argument 'name'`.
        ("find_components", {}, "find_components", {"max_depth": 3}),
        ("find_components", {"name": "Casting"},
         "find_components", {"name": "Casting", "max_depth": 3}),
        ("find_components",
         {"name": "X", "layer": "Frame_BSR", "type": "group", "max_depth": 5},
         "find_components",
         {"name": "X", "layer": "Frame_BSR", "type": "group", "max_depth": 5}),
        ("create_layer", {"name": "Frame_BSR"}, "create_layer", {"name": "Frame_BSR"}),
    ],
)
async def test_tool_wrapper_calls_ruby_correctly(
    tool_name, kwargs, expected_ruby_name, expected_ruby_kwargs,
    mock_send_command, mock_ctx,
):
    """Проверяет, что Python-wrapper передаёт правильное Ruby-имя и mapped kwargs.

    Покрывает три риска: (1) опечатка в Ruby-имени (export_scene→export),
    (2) забытое переименование параметра (id→entity_id), (3) пропуск default'ов.
    """
    import sketchup_mcp.tools as tools_module
    tool_func = getattr(tools_module, tool_name)
    mock_send_command.send_command.return_value = {"content": [{"text": "ok"}]}
    result = await tool_func(mock_ctx, **kwargs)
    assert result == "ok"
    mock_send_command.send_command.assert_called_once_with(
        expected_ruby_name, expected_ruby_kwargs
    )


async def test_eval_ruby_no_longer_returns_old_success_wrapper(
    mock_send_command, mock_ctx
):
    """Sanity: старый формат `{"success": bool, "result"|"error": ...}` ушёл.

    Теперь `eval_ruby` идёт через `_call`: при success — текст, при error —
    `format_error`-строка.
    """
    from sketchup_mcp.tools import eval_ruby

    # Success path
    mock_send_command.send_command.return_value = {"content": [{"text": "42"}]}
    out = await eval_ruby(mock_ctx, code="40 + 2")
    assert out == "42"
    assert '"success"' not in out

    # Error path
    mock_send_command.send_command.side_effect = SketchUpError(
        -32000, "boom", {"tool": "eval_ruby", "params": {"code": "..."}}
    )
    out = await eval_ruby(mock_ctx, code="raise 'x'")
    assert out.startswith("[-32000] boom")
    assert '"success"' not in out


async def test_eval_ruby_returns_actionable_text_on_minus32010(
    mock_send_command, mock_ctx
):
    """When Ruby returns -32010 (eval gate closed), Python wrapper returns
    a plain text suitable for Claude to surface to the end user — not a
    raised SketchUpError. The LLM should see "eval_ruby is disabled..."
    and pass it through verbatim. Contract pinned per spec §4.4.
    """
    from sketchup_mcp.tools import eval_ruby

    mock_send_command.send_command.side_effect = SketchUpError(
        -32010,
        "eval_ruby is disabled. Open Plugins → MCP Server → Settings...",
        {"tool": "eval_ruby", "params": {}},
    )
    out = await eval_ruby(mock_ctx, code="puts 'x'")
    assert isinstance(out, str)
    assert "eval_ruby is disabled" in out
    assert "Settings" in out
    # Must NOT be the [-32010] formatted-error string from format_error — the
    # spec wants the raw human-readable message to flow through.
    assert not out.startswith("[-32010]")


async def test_eval_ruby_fills_tool_name_when_error_lacks_it(mock_send_command, mock_ctx):
    """eval_ruby's transport-error backfill: a non-(-32010) error with no 'tool'
    in data must render tool=eval_ruby (not tool=?). Pins that the setdefault
    sits AFTER the -32010 verbatim early-return (which is pinned above)."""
    from sketchup_mcp.tools import eval_ruby

    mock_send_command.send_command.side_effect = SketchUpError(
        -32000, "connection error: Connection lost"
    )
    out = await eval_ruby(mock_ctx, code="1 + 1")
    assert "tool=eval_ruby" in out
    assert "tool=?" not in out
