import asyncio
import pytest

from sketchup_mcp.compat import EVAL_DISABLED_CODE
from sketchup_mcp.errors import SketchUpError

# The helper lives in examples/smoke_check.py; importing the module
# directly keeps the test out of the package import path.
from importlib import util
from pathlib import Path

_SMOKE_PATH = Path(__file__).resolve().parents[1] / "examples" / "smoke_check.py"
_spec = util.spec_from_file_location("smoke_check", _SMOKE_PATH)
_smoke = util.module_from_spec(_spec)
_spec.loader.exec_module(_smoke)  # type: ignore[union-attr]


def test_maybe_skip_eval_returns_none_on_disabled_code(capsys):
    async def boom():
        raise SketchUpError(EVAL_DISABLED_CODE, "eval_ruby is disabled")

    result = asyncio.run(_smoke._maybe_skip_eval("step 5", boom()))
    assert result is None
    captured = capsys.readouterr().out
    assert "step 5" in captured
    assert "skipped" in captured


def test_maybe_skip_eval_re_raises_other_codes():
    async def boom():
        raise SketchUpError(-32000, "other error")

    with pytest.raises(SketchUpError) as ei:
        asyncio.run(_smoke._maybe_skip_eval("step 6", boom()))
    assert ei.value.code == -32000
