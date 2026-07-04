"""Tests for sketchup_mcp.compat — version parsing and Ruby compatibility check."""
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
    monkeypatch.setattr(compat, "MAX_RUBY", "0.2.0")
    compat.check_ruby_version("0.1.0")


def test_at_max_passes(monkeypatch):
    monkeypatch.setattr(compat, "MIN_RUBY", "0.1.0")
    monkeypatch.setattr(compat, "MAX_RUBY", "0.2.0")
    compat.check_ruby_version("0.2.0")


def test_too_old_raises_with_reinstall_hint(monkeypatch):
    monkeypatch.setattr(compat, "MIN_RUBY", "0.1.0")
    monkeypatch.setattr(compat, "MAX_RUBY", "0.2.0")
    with pytest.raises(IncompatibleVersionError) as exc:
        compat.check_ruby_version("0.0.3")
    msg = str(exc.value)
    assert "0.0.3" in msg and "too old" in msg
    assert ".rbz" in msg  # reinstall hint
    assert "get_version" in msg  # diagnostic pointer


def test_too_new_raises_with_upgrade_hint(monkeypatch):
    monkeypatch.setattr(compat, "MIN_RUBY", "0.1.0")
    monkeypatch.setattr(compat, "MAX_RUBY", "0.2.0")
    with pytest.raises(IncompatibleVersionError) as exc:
        compat.check_ruby_version("0.3.0")
    msg = str(exc.value)
    assert "0.3.0" in msg and "newer" in msg
    assert "uv pip install --upgrade" in msg
    assert "get_version" in msg


def test_none_raises_with_pre_dates_hint():
    with pytest.raises(IncompatibleVersionError) as exc:
        compat.check_ruby_version(None)
    msg = str(exc.value)
    assert "pre-dates" in msg
    assert ".rbz" in msg
    assert "get_version" in msg


def test_unparseable_raises_clear_message():
    with pytest.raises(IncompatibleVersionError) as exc:
        compat.check_ruby_version("v1")
    msg = str(exc.value)
    assert "unparseable" in msg
    assert "v1" in msg


def test_min_le_max_invariant():
    """Sanity: declared range cannot be empty."""
    assert compat.parse(compat.MIN_RUBY) <= compat.parse(compat.MAX_RUBY)


def test_max_ruby_matches_python_version():
    """Release-time forgot-to-bump catcher: when releasing N, MAX_RUBY == N."""
    assert compat.parse(compat.MAX_RUBY) == compat.parse(compat.CLIENT_VERSION)


def test_python_version_matches_installed_metadata():
    """QUAL-03: старый тест сравнивал compat.CLIENT_VERSION с тем же атрибутом,
    из которого он импортирован, — тавтология. Настоящий guard: __version__
    (источник CLIENT_VERSION) обязан совпадать с версией из метаданных
    установленного пакета (pyproject.toml), иначе релизный бамп одной из двух
    точек тихо разъезжается."""
    from importlib.metadata import version
    assert compat.CLIENT_VERSION == version("sketchup-mcp2")
