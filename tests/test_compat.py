"""Tests for sketchup_mcp.compat — version parsing and Ruby compatibility check."""
import re
from pathlib import Path

import pytest

from sketchup_mcp import compat
from sketchup_mcp.errors import IncompatibleVersionError


# -------- _parse --------

def test_parse_valid_tuple():
    assert compat.parse("0.1.0") == (0, 1, 0)
    assert compat.parse("1.2.3") == (1, 2, 3)
    assert compat.parse("10.20.30") == (10, 20, 30)


@pytest.mark.parametrize(
    "bad",
    [
        "0.1",
        "0.1.0.0",
        "abc",
        "",
        "0.1.0-rc1",
        "v1.0.0",
        " 0.1.0",     # leading whitespace
        "0.1.0 ",     # trailing whitespace
        "0.1.0+",     # sign char
        "+1.0.0",     # sign char
        "1_0.0.0",    # underscore separator (rejected by strict regex)
        "١.٢.٣",  # Arabic-Indic digits (Unicode \d but not ASCII [0-9]+)
        "0.1.٣",            # mixed ASCII + Unicode digit — Ruby's ASCII \d rejects
    ],
)
def test_parse_invalid_raises(bad):
    with pytest.raises(ValueError):
        compat.parse(bad)


def test_parse_non_string_raises():
    with pytest.raises(ValueError):
        compat.parse(None)  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        compat.parse(123)  # type: ignore[arg-type]


# -------- check_ruby_version --------

def test_at_min_passes(monkeypatch):
    monkeypatch.setattr(compat, "MIN_RUBY", "0.1.0")
    compat.check_ruby_version("0.1.0")


def test_newer_plugin_accepted(monkeypatch):
    """No upper bound: a plugin released after this client (a plugin-only
    hotfix) passes — the newer side of a pair decides."""
    monkeypatch.setattr(compat, "MIN_RUBY", "0.1.0")
    compat.check_ruby_version("99.0.0")


def test_too_old_raises_with_reinstall_hint(monkeypatch):
    monkeypatch.setattr(compat, "MIN_RUBY", "0.1.0")
    with pytest.raises(IncompatibleVersionError) as exc:
        compat.check_ruby_version("0.0.3")
    msg = str(exc.value)
    assert "0.0.3" in msg and "too old" in msg
    assert "needs plugin v0.1.0 or newer" in msg  # names the floor
    assert "latest mcp_for_sketchup .rbz" in msg
    assert "get_version" in msg  # diagnostic pointer


def test_none_raises_with_pre_dates_hint():
    with pytest.raises(IncompatibleVersionError) as exc:
        compat.check_ruby_version(None)
    msg = str(exc.value)
    assert "pre-dates" in msg
    assert "latest mcp_for_sketchup .rbz" in msg
    assert "get_version" in msg


def test_unparseable_raises_clear_message():
    with pytest.raises(IncompatibleVersionError) as exc:
        compat.check_ruby_version("v1")
    msg = str(exc.value)
    assert "unparseable" in msg
    assert "v1" in msg


_COMPAT_RB = (
    Path(__file__).resolve().parent.parent
    / "mcp_for_sketchup" / "mcp_for_sketchup" / "core" / "compat.rb"
)


def _ruby_const(name: str, path: Path = _COMPAT_RB) -> str:
    """Read a constant such as ``SERVER_VERSION = "0.3.1"`` or
    ``EDGE_OP_BUDGET_S = 30.0`` from a Ruby file (compat.rb unless ``path``
    names another): the text of its string or number literal."""
    source = path.read_text(encoding="utf-8")
    m = re.search(rf'^\s*{name}\s*=\s*(?:"([^"]*)"|([\d_.]+))', source, re.M)
    assert m, f"{name} not found in {path}"
    return m.group(1) if m.group(1) is not None else m.group(2)


def test_in_repo_pair_is_compatible():
    """The client and the plugin in this commit must accept each other.

    Replaces the old MAX pinning tests: it catches a mistyped floor and a
    floor that names a counterpart version this commit does not have yet."""
    server_version = _ruby_const("SERVER_VERSION")
    min_python = _ruby_const("MIN_PYTHON")
    assert compat.parse(compat.MIN_RUBY) <= compat.parse(server_version), (
        f"MIN_RUBY {compat.MIN_RUBY} rejects the in-repo plugin v{server_version}"
    )
    assert compat.parse(min_python) <= compat.parse(compat.CLIENT_VERSION), (
        f"compat.rb MIN_PYTHON {min_python} rejects the in-repo client "
        f"v{compat.CLIENT_VERSION}"
    )


# Every release up to 0.3.1 caps its counterpart at its own version, so no
# 0.3.x build can pair with anything released later.
_LAST_CAPPED_RELEASE = "0.3.1"


def test_first_release_past_0_3_1_raises_floors():
    """A side released past 0.3.1 must also raise its floor past 0.3.1.

    No 0.3.x counterpart can pair with it anyway. The raised MIN_PYTHON makes
    the plugin reject a 0.3.x client itself, with the
    `uvx sketchup-mcp2@latest` hint, instead of letting the 0.3.x client
    print its own `uv pip install --upgrade` advice, which does not refresh a
    uvx install. Together with test_in_repo_pair_is_compatible this also
    refuses a one-sided first release after 0.3.1."""
    capped = compat.parse(_LAST_CAPPED_RELEASE)
    server_version = _ruby_const("SERVER_VERSION")
    min_python = _ruby_const("MIN_PYTHON")
    if compat.parse(server_version) > capped:
        assert compat.parse(min_python) > capped, (
            f"plugin v{server_version} ships past {_LAST_CAPPED_RELEASE}: "
            f"raise compat.rb MIN_PYTHON (now {min_python}) past it too"
        )
    if compat.parse(compat.CLIENT_VERSION) > capped:
        assert compat.parse(compat.MIN_RUBY) > capped, (
            f"client v{compat.CLIENT_VERSION} ships past {_LAST_CAPPED_RELEASE}: "
            f"raise MIN_RUBY (now {compat.MIN_RUBY}) past it too"
        )


def test_python_version_matches_installed_metadata():
    """QUAL-03: старый тест сравнивал compat.CLIENT_VERSION с тем же атрибутом,
    из которого он импортирован, — тавтология. Настоящий guard: __version__
    (источник CLIENT_VERSION) обязан совпадать с версией из метаданных
    установленного пакета (pyproject.toml), иначе релизный бамп одной из двух
    точек тихо разъезжается."""
    from importlib.metadata import version
    assert compat.CLIENT_VERSION == version("sketchup-mcp2")
