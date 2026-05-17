# test/test_compat.rb
require "minitest/autorun"

require_relative "../su_mcp/su_mcp/core/errors"
require_relative "../su_mcp/su_mcp/core/compat"

class TestCompat < Minitest::Test
  # -------- parse --------

  def test_parse_valid
    assert_equal [0, 1, 0], SU_MCP::Core::Compat.parse("0.1.0")
    assert_equal [10, 20, 30], SU_MCP::Core::Compat.parse("10.20.30")
  end

  # Mirrors tests/test_compat.py negatives. ١..٣ are Arabic-Indic
  # digits; Ruby's \d is ASCII-by-default but the regex is [0-9]+ to mirror
  # Python's ASCII-only intent.
  [
    "0.1", "0.1.0.0", "abc", "", "v1",
    "0.1.0-rc1", "v1.0.0",
    " 0.1.0", "0.1.0 ", "0.1.0+", "+1.0.0", "1_0.0.0",
    "١.٢.٣", "0.1.٣",
  ].each_with_index do |bad, i|
    define_method("test_parse_invalid_#{i}_#{bad.gsub(/\W/, '_')}") do
      assert_raises(ArgumentError) { SU_MCP::Core::Compat.parse(bad) }
    end
  end

  def test_parse_non_string_raises
    assert_raises(ArgumentError) { SU_MCP::Core::Compat.parse(nil) }
    assert_raises(ArgumentError) { SU_MCP::Core::Compat.parse(123) }
  end

  # -------- check_python_version --------

  # Safe swap of compat constants per-test. Uses defined?-guards in the
  # ensure block so a partial setup (e.g. exception between the two
  # remove_const calls) doesn't mask the original error with a secondary
  # NameError.
  def with_range(min, max)
    orig_min = SU_MCP::Core::Compat::MIN_PYTHON
    orig_max = SU_MCP::Core::Compat::MAX_PYTHON
    SU_MCP::Core::Compat.send(:remove_const, :MIN_PYTHON)
    SU_MCP::Core::Compat.send(:remove_const, :MAX_PYTHON)
    SU_MCP::Core::Compat.const_set(:MIN_PYTHON, min)
    SU_MCP::Core::Compat.const_set(:MAX_PYTHON, max)
    yield
  ensure
    if SU_MCP::Core::Compat.const_defined?(:MIN_PYTHON, false)
      SU_MCP::Core::Compat.send(:remove_const, :MIN_PYTHON)
    end
    if SU_MCP::Core::Compat.const_defined?(:MAX_PYTHON, false)
      SU_MCP::Core::Compat.send(:remove_const, :MAX_PYTHON)
    end
    SU_MCP::Core::Compat.const_set(:MIN_PYTHON, orig_min) if defined?(orig_min)
    SU_MCP::Core::Compat.const_set(:MAX_PYTHON, orig_max) if defined?(orig_max)
  end

  def test_at_min_passes
    with_range("0.1.0", "0.2.0") do
      SU_MCP::Core::Compat.check_python_version("0.1.0")  # no raise
    end
  end

  def test_at_max_passes
    with_range("0.1.0", "0.2.0") do
      SU_MCP::Core::Compat.check_python_version("0.2.0")
    end
  end

  def test_too_old_raises_with_upgrade_hint
    with_range("0.1.0", "0.2.0") do
      err = assert_raises(SU_MCP::Core::StructuredError) do
        SU_MCP::Core::Compat.check_python_version("0.0.3")
      end
      assert_equal(-32001, err.code)
      assert_includes err.message, "0.0.3"
      assert_includes err.message, "too old"
      assert_includes err.message, "uv pip install --upgrade"
    end
  end

  def test_too_new_raises_with_reinstall_hint
    with_range("0.1.0", "0.2.0") do
      err = assert_raises(SU_MCP::Core::StructuredError) do
        SU_MCP::Core::Compat.check_python_version("0.3.0")
      end
      assert_equal(-32001, err.code)
      assert_includes err.message, "0.3.0"
      assert_includes err.message, "newer"
      assert_includes err.message, ".rbz"
    end
  end

  def test_nil_raises_with_pre_dates_hint
    err = assert_raises(SU_MCP::Core::StructuredError) do
      SU_MCP::Core::Compat.check_python_version(nil)
    end
    assert_equal(-32001, err.code)
    assert_includes err.message, "pre-dates"
  end

  def test_unparseable_raises_clear_message
    err = assert_raises(SU_MCP::Core::StructuredError) do
      SU_MCP::Core::Compat.check_python_version("v1")
    end
    assert_equal(-32001, err.code)
    assert_includes err.message, "unparseable"
    assert_includes err.message, "v1"
  end

  def test_min_le_max_invariant
    min = SU_MCP::Core::Compat.parse(SU_MCP::Core::Compat::MIN_PYTHON)
    max = SU_MCP::Core::Compat.parse(SU_MCP::Core::Compat::MAX_PYTHON)
    assert (min <=> max) <= 0,
      "MIN_PYTHON (#{min}) must be <= MAX_PYTHON (#{max})"
  end

  def test_max_python_matches_server_version
    # Release-time forgot-to-bump catcher: when releasing version N,
    # MAX_PYTHON == N == plugin SERVER_VERSION.
    max = SU_MCP::Core::Compat.parse(SU_MCP::Core::Compat::MAX_PYTHON)
    sv  = SU_MCP::Core::Compat.parse(SU_MCP::Core::Compat::SERVER_VERSION)
    assert_equal sv, max,
      "MAX_PYTHON (#{max}) must match plugin SERVER_VERSION (#{sv})"
  end
end
