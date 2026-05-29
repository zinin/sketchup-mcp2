# test/test_config.rb
require "minitest/autorun"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "support/config_reset"

class StubReader
  def initialize(data = {})
    @data = data
  end

  def read_default(_section, key, default)
    @data.fetch(key, default)
  end
end

class StubWriter
  attr_reader :writes

  def initialize
    @writes = []
  end

  def write_default(section, key, value)
    @writes << [section, key, value]
    true
  end
end

# Simulates Sketchup.write_default returning false (corrupt prefs, disk full,
# etc.) for a specific key, exercising the Config.update! raise path that
# real-prod code depends on. Without this, the "write_default → false ⇒ raise"
# contract (config.rb:76) has zero test coverage.
class FailingWriter
  attr_reader :writes

  def initialize(fail_on_key:)
    @writes = []
    @fail_on_key = fail_on_key
  end

  def write_default(section, key, value)
    @writes << [section, key, value]
    key != @fail_on_key
  end
end

class TestConfig < Minitest::Test
  C = MCPforSketchUp::Core::Config

  def setup
    ConfigReset.reset_all!
  end

  def test_section_constant
    assert_equal "MCPforSketchUp", C::SECTION
  end

  def test_max_message_size_constant
    assert_equal 64 * 1024 * 1024, C::MAX_MESSAGE_SIZE
  end

  def test_levels_table
    assert_equal 0, C::LEVELS["DEBUG"]
    assert_equal 1, C::LEVELS["INFO"]
    assert_equal 2, C::LEVELS["WARN"]
    assert_equal 3, C::LEVELS["ERROR"]
  end

  def test_defaults_hash
    assert_equal "127.0.0.1", C::DEFAULTS[:host]
    assert_equal 9876,        C::DEFAULTS[:port]
    assert_equal "WARN",      C::DEFAULTS[:log_level]
  end

  def test_load_from_defaults_with_empty_prefs
    C.load_from_defaults!(StubReader.new)
    assert_equal "127.0.0.1", C.host
    assert_equal 9876,        C.port
    assert_equal "WARN",      C.log_level
  end

  def test_load_from_defaults_reads_all_three_keys
    reader = StubReader.new(
      "host"      => "0.0.0.0",
      "port"      => 8080,
      "log_level" => "DEBUG"
    )
    C.load_from_defaults!(reader)
    assert_equal "0.0.0.0", C.host
    assert_equal 8080,      C.port
    assert_equal "DEBUG",   C.log_level
  end

  def test_load_from_defaults_coerces_port_to_integer
    reader = StubReader.new("port" => "1234")
    C.load_from_defaults!(reader)
    assert_equal 1234, C.port
    assert_kind_of Integer, C.port
  end

  def test_load_from_defaults_upcases_log_level
    reader = StubReader.new("log_level" => "debug")
    C.load_from_defaults!(reader)
    assert_equal "DEBUG", C.log_level
  end

  def test_update_persists_to_writer
    writer = StubWriter.new
    C.update!(host: "10.0.0.5", port: 9999, log_level: "WARN", writer: writer)
    assert_equal ["MCPforSketchUp", "host",      "10.0.0.5"], writer.writes[0]
    assert_equal ["MCPforSketchUp", "port",      9999       ], writer.writes[1]
    assert_equal ["MCPforSketchUp", "log_level", "WARN"     ], writer.writes[2]
  end

  def test_update_mutates_runtime_state
    writer = StubWriter.new
    C.update!(host: "10.0.0.5", port: "9999", log_level: "WARN", writer: writer)
    assert_equal "10.0.0.5", C.host
    assert_equal 9999,       C.port
    assert_equal "WARN",     C.log_level
  end

  def test_level_value_uses_current_log_level
    C.log_level = "ERROR"
    assert_equal 3, C.level_value
  end

  def test_level_value_for_known
    assert_equal 0, C.level_value_for("DEBUG")
    assert_equal 3, C.level_value_for("ERROR")
  end

  def test_level_value_for_unknown_falls_back_to_info
    assert_equal 1, C.level_value_for("FOO")
  end

  # --- load_from_defaults! fallback-to-DEFAULTS on invalid persisted prefs ---

  def test_load_from_defaults_falls_back_when_host_invalid
    reader = StubReader.new("host" => "bad host with space")
    C.load_from_defaults!(reader)
    assert_equal "127.0.0.1", C.host
  end

  def test_load_from_defaults_falls_back_when_port_non_numeric
    reader = StubReader.new("port" => "abc")
    C.load_from_defaults!(reader)
    assert_equal 9876, C.port
  end

  def test_load_from_defaults_falls_back_when_port_out_of_range
    reader = StubReader.new("port" => "0")
    C.load_from_defaults!(reader)
    assert_equal 9876, C.port
  end

  def test_load_from_defaults_falls_back_when_log_level_unknown
    reader = StubReader.new("log_level" => "VERBOSE")
    C.load_from_defaults!(reader)
    assert_equal "WARN", C.log_level
  end

  # --- write_default → false must raise (config.rb:76 contract) ---

  def test_update_raises_when_write_default_returns_false_on_host
    writer = FailingWriter.new(fail_on_key: "host")
    error = assert_raises(RuntimeError) do
      C.update!(host: "10.0.0.5", port: 9999, log_level: "WARN", writer: writer)
    end
    assert_match(/host/, error.message)
  end

  def test_update_raises_when_write_default_returns_false_on_port
    writer = FailingWriter.new(fail_on_key: "port")
    error = assert_raises(RuntimeError) do
      C.update!(host: "10.0.0.5", port: 9999, log_level: "WARN", writer: writer)
    end
    assert_match(/port/, error.message)
  end

  def test_update_rolls_back_runtime_when_persistence_fails
    # Review F1: update! is transactional. A failing write_default must leave
    # runtime EXACTLY as it was before the call — no partial application — so
    # eval_enabled (the code-exec gate) can never be left open after a save
    # that errored.
    C.host      = "1.1.1.1"
    C.port      = 1111
    C.log_level = "ERROR"
    writer = FailingWriter.new(fail_on_key: "log_level")
    assert_raises(RuntimeError) do
      C.update!(host: "10.0.0.5", port: 9999, log_level: "WARN", writer: writer)
    end
    assert_equal "1.1.1.1", C.host,      "host must roll back on persistence failure"
    assert_equal 1111,      C.port,      "port must roll back on persistence failure"
    assert_equal "ERROR",   C.log_level, "log_level must roll back on persistence failure"
  end

  def test_update_does_not_open_eval_gate_when_persistence_fails
    # Review F1 (security): user enables eval but an earlier write fails. The
    # gate must stay CLOSED for the session — eval_enabled must NOT be left
    # true after update! raises.
    C.eval_enabled = false
    writer = FailingWriter.new(fail_on_key: "host")  # fails before any later key
    assert_raises(RuntimeError) do
      C.update!(host: "10.0.0.5", port: 9999, log_level: "WARN",
                eval_enabled: true, writer: writer)
    end
    assert_equal false, C.eval_enabled,
      "eval_enabled must roll back to false (fail closed) when the save fails"
    refute C.eval_enabled?, "eval gate must remain closed after a failed save"
  end

  # --- new prefs introduced in v0.2.0 (warehouse compliance) ---

  def test_defaults_include_eval_enabled_nil
    # Sentinel-nil: unset pref triggers the BuildProfile fallback (spec §4.2).
    # `false` here would mask the fallback and make github-variant indistinguishable
    # from warehouse — see iter-1 CRITICAL-1.
    assert_nil C::DEFAULTS[:eval_enabled]
  end

  def test_defaults_include_log_to_file_false
    assert_equal false, C::DEFAULTS[:log_to_file]
  end

  def test_defaults_include_log_file_path_in_tmpdir
    require "tmpdir"
    expected = File.join(Dir.tmpdir, "mcp_for_sketchup.log")
    assert_equal expected, C::DEFAULTS[:log_file_path]
  end

  def test_load_from_defaults_reads_eval_enabled
    reader = StubReader.new("eval_enabled" => true)
    C.load_from_defaults!(reader)
    assert_equal true, C.eval_enabled
  end

  def test_load_from_defaults_reads_log_to_file
    reader = StubReader.new("log_to_file" => true)
    C.load_from_defaults!(reader)
    assert_equal true, C.log_to_file
  end

  def test_load_from_defaults_reads_log_file_path
    reader = StubReader.new("log_file_path" => "/tmp/custom.log")
    C.load_from_defaults!(reader)
    assert_equal "/tmp/custom.log", C.log_file_path
  end

  def test_eval_enabled_question_mark_when_build_profile_absent_returns_false
    # Unset pref + no BuildProfile => safe warehouse default (false).
    refute MCPforSketchUp::Core.const_defined?(:BuildProfile),
      "test env should not have build_profile.rb loaded"
    C.load_from_defaults!(StubReader.new)  # no eval_enabled key in reader
    assert_nil C.eval_enabled,
      "sentinel: unset pref must leave @eval_enabled at nil"
    refute C.eval_enabled?
  end

  def test_eval_enabled_question_mark_when_pref_true
    C.load_from_defaults!(StubReader.new("eval_enabled" => true))
    assert C.eval_enabled?
  end

  def test_eval_enabled_question_mark_when_pref_explicit_false
    # Explicit `false` must be honoured (not fall through to BuildProfile).
    C.load_from_defaults!(StubReader.new("eval_enabled" => false))
    assert_equal false, C.eval_enabled,
      "explicit false must be preserved, not coerced to nil"
    refute C.eval_enabled?
  end

  def test_read_default_sentinel_round_trip_for_eval_enabled
    # StubReader contract mirror of Sketchup.read_default: when key is absent,
    # returns the default arg (nil sentinel); when key is `false`, returns `false`.
    # Verifies the assumption underlying CRITICAL-1's sentinel design (spec §4.2).
    reader_unset = StubReader.new                                   # no key
    reader_false = StubReader.new("eval_enabled" => false)
    assert_nil   reader_unset.read_default(C::SECTION, "eval_enabled", nil)
    assert_equal false, reader_false.read_default(C::SECTION, "eval_enabled", nil)
  end

  def test_update_with_only_3_args_does_not_touch_new_fields
    # Iter-1 CONCERN-10: legacy callers that pass only the original 3
    # keyword args must NOT silently start emitting writes for the new
    # eval_enabled / log_to_file / log_file_path keys — keyword-default
    # `nil` plus `unless …nil?` guards must keep them untouched.
    ConfigReset.reset_all!
    writer = StubWriter.new
    C.update!(host: "1.1.1.1", port: 1111, log_level: "INFO", writer: writer)
    assert_nil C.eval_enabled
    assert_nil C.log_to_file
    assert_nil C.log_file_path
    keys = writer.writes.map { |_section, k, _value| k }
    refute_includes keys, "eval_enabled"
    refute_includes keys, "log_to_file"
    refute_includes keys, "log_file_path"
  end

  def test_update_persists_new_prefs
    writer = StubWriter.new
    C.update!(
      host: "127.0.0.1", port: 9876, log_level: "WARN",
      eval_enabled: true, log_to_file: true, log_file_path: "/tmp/a.log",
      writer: writer,
    )
    keys = writer.writes.map { |_section, key, _value| key }
    assert_includes keys, "eval_enabled"
    assert_includes keys, "log_to_file"
    assert_includes keys, "log_file_path"
  end
end
