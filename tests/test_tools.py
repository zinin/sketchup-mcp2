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


from typing import Annotated, Literal

from pydantic import Field, TypeAdapter, ValidationError


def test_field_rejects_zero_or_negative_size():
    adapter = TypeAdapter(Annotated[float, Field(gt=0)])
    adapter.validate_python(1.5)  # ok
    with pytest.raises(ValidationError):
        adapter.validate_python(0)
    with pytest.raises(ValidationError):
        adapter.validate_python(-1.0)


def test_literal_rejects_value_outside_set():
    adapter = TypeAdapter(Literal["cube", "cylinder", "cone", "sphere"])
    adapter.validate_python("cube")  # ok
    with pytest.raises(ValidationError):
        adapter.validate_python("invalid")


def test_field_rejects_wrong_coord_length():
    adapter = TypeAdapter(Annotated[list[float], Field(min_length=3, max_length=3)])
    adapter.validate_python([1.0, 2.0, 3.0])  # ok
    with pytest.raises(ValidationError):
        adapter.validate_python([1.0, 2.0])
    with pytest.raises(ValidationError):
        adapter.validate_python([1.0, 2.0, 3.0, 4.0])


def test_dimensions_rejects_zero_or_negative_element():
    """Element-wise gt=0 rejects [1, 0, 1] и [1, -2, 3]."""
    adapter = TypeAdapter(
        Annotated[
            list[Annotated[float, Field(gt=0)]],
            Field(min_length=3, max_length=3),
        ]
    )
    adapter.validate_python([1.0, 2.0, 3.0])  # ok
    with pytest.raises(ValidationError):
        adapter.validate_python([1.0, 0.0, 1.0])
    with pytest.raises(ValidationError):
        adapter.validate_python([1.0, -2.0, 3.0])


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
