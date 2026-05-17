"""Tests for the SketchUp modeling-strategy MCP prompt.

The prompt is registered as a side-effect of importing
``sketchup_mcp.prompts``. The module-level import below runs the
registration once for the whole test module (cheaper than a per-test
autouse fixture).
"""
import sketchup_mcp.prompts  # noqa: F401 — register the prompt for these tests

from sketchup_mcp.app import mcp


async def test_prompt_registered():
    prompts = await mcp.list_prompts()
    names = [p.name for p in prompts]
    assert "sketchup_modeling_strategy" in names


async def test_prompt_returns_non_empty_text():
    result = await mcp.get_prompt("sketchup_modeling_strategy", {})
    text = result.messages[0].content.text
    assert len(text) > 200, f"prompt body suspiciously short: {len(text)} chars"


async def test_prompt_anchor_phrases():
    """Guard rails — these phrases encode critical guidance and must
    survive future edits. If you intentionally rephrase one, update this
    test, but do NOT remove the concept."""
    result = await mcp.get_prompt("sketchup_modeling_strategy", {})
    text = result.messages[0].content.text
    for anchor in [
        "get_model_info",
        "millimeters",
        "undo",
        "eval_ruby",
        "boolean_operation",
        "bbox_mm",
    ]:
        assert anchor in text, f"missing anchor phrase: {anchor!r}"


async def test_prompt_required_sections():
    """Guard the structural skeleton of the prompt — section headers
    must all be present. Wording inside sections is allowed to drift;
    losing a whole section is not."""
    result = await mcp.get_prompt("sketchup_modeling_strategy", {})
    text = result.messages[0].content.text
    for section in [
        "# 1. Pre-flight",
        "# 2. Tool priority",
        "# 3. Conventions",
        "# 4. After every mutation",
        "# 5. Error recovery",
        "# 6. Known traps",
        "# 7. Joinery defaults",
    ]:
        assert section in text, f"missing section header: {section!r}"


async def test_prompt_description_present():
    prompts = await mcp.list_prompts()
    p = next(p for p in prompts if p.name == "sketchup_modeling_strategy")
    assert p.description
    assert "SketchUp" in p.description
