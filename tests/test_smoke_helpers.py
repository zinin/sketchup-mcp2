import ast
import asyncio
import re

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


def test_export_file_is_local_on_loopback():
    assert _smoke._export_file_is_local("127.0.0.1", {}) is True


@pytest.mark.parametrize("host", ["localhost", "::1"])
def test_export_file_is_local_on_other_loopback_spellings(host):
    assert _smoke._export_file_is_local(host, {}) is True


def test_export_file_is_not_local_for_lan_host():
    assert _smoke._export_file_is_local("192.168.1.20", {}) is False


def test_export_file_is_not_local_behind_tunnel():
    # A reverse SSH tunnel keeps the host on loopback, but the export file
    # lands on the SketchUp machine at the other end.
    assert _smoke._export_file_is_local("127.0.0.1", {"SKETCHUP_MCP_SMOKE_REMOTE": "1"}) is False


@pytest.mark.parametrize("value", ["", "0", "true"])
def test_only_literal_one_opts_out_of_the_local_export_check(value):
    assert _smoke._export_file_is_local("127.0.0.1", {"SKETCHUP_MCP_SMOKE_REMOTE": value}) is True


# --- the wiring of main(): it needs a live SketchUp, so it is read, not run ---

_SMOKE_SOURCE = _SMOKE_PATH.read_text(encoding="utf-8")


def _smoke_main() -> ast.AsyncFunctionDef:
    tree = ast.parse(_SMOKE_SOURCE)
    return next(n for n in tree.body if isinstance(n, ast.AsyncFunctionDef) and n.name == "main")


def _step_assignments() -> list[tuple[int, int]]:
    """[(step number, line)] of every `step = N` assignment in main(), sorted.
    A list, not a dict: a number that is used twice must stay visible."""
    return sorted(
        (node.value.value, node.lineno)
        for node in ast.walk(_smoke_main())
        if isinstance(node, ast.Assign)
        and [t.id for t in node.targets if isinstance(t, ast.Name)] == ["step"]
        and isinstance(node.value, ast.Constant)
    )


def _step_line(number: int) -> int:
    """The line of the one `step = <number>` assignment in main()."""
    lines = [line for n, line in _step_assignments() if n == number]
    assert len(lines) == 1, f"step {number} is assigned {len(lines)} times in main()"
    return lines[0]


def test_step_18_asks_export_file_is_local_with_the_host_and_the_environment():
    """T14-d: step 18 chooses between «the file exists here» and «Ruby returned a
    path» by calling _export_file_is_local(config.HOST, os.environ). Тесты самого
    хелпера остались бы зелёными, если бы вызов убрали или подали ему литерал.
    Падающий local-assert подсказывает SKETCHUP_MCP_SMOKE_REMOTE=1."""
    branches = [
        node for node in ast.walk(_smoke_main())
        if isinstance(node, ast.If) and isinstance(node.test, ast.Call)
        and getattr(node.test.func, "id", None) == "_export_file_is_local"
    ]
    assert len(branches) == 1, "main() must call _export_file_is_local exactly once"
    branch = branches[0]
    assert _step_line(18) < branch.lineno < _step_line(19), "the call belongs to step 18"
    assert [ast.unparse(a) for a in branch.test.args] == ["config.HOST", "os.environ"]
    local_check = branch.body[0]
    assert isinstance(local_check, ast.Assert)
    assert "os.path.exists(path)" in ast.unparse(local_check.test)
    assert "SKETCHUP_MCP_SMOKE_REMOTE=1" in ast.unparse(local_check.msg)


def test_smoke_steps_are_consecutive_and_every_total_agrees():
    """Вставка шага перенумеровывает следующие за ним и все места, где названо
    число шагов: итоговая строка скрипта, README, CLAUDE.md. Каждый номер
    встречается один раз; в документах считаются только упоминания самого
    smoke_check.py (строка с его именем и «N-step»)."""
    numbers = [n for n, _ in _step_assignments() if n > 0]
    repeated = sorted({n for n in numbers if numbers.count(n) > 1})
    assert not repeated, f"step numbers used more than once: {repeated}"
    assert numbers == list(range(1, len(numbers) + 1)), f"steps are not 1..N: {numbers}"
    total = len(numbers)
    assert f"Smoke complete: {total} steps total" in _SMOKE_SOURCE
    for doc in ("README.md", "CLAUDE.md"):
        text = (_SMOKE_PATH.parents[1] / doc).read_text(encoding="utf-8")
        counts = set(re.findall(r"smoke_check\.py[^\n]*?\b(\d+)-step\b", text))
        assert counts == {str(total)}, (
            f"{doc} must say {total}-step on the lines that name smoke_check.py; found {sorted(counts)}")
