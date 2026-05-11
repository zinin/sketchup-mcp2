# test/test_config.rb
require "minitest/autorun"
require_relative "../su_mcp/su_mcp/core/config"

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
  C = SU_MCP::Core::Config

  def setup
    C.host = nil
    C.port = nil
    C.log_level = nil
  end

  def test_section_constant
    assert_equal "SU_MCP", C::SECTION
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
    assert_equal "INFO",      C::DEFAULTS[:log_level]
  end

  def test_load_from_defaults_with_empty_prefs
    C.load_from_defaults!(StubReader.new)
    assert_equal "127.0.0.1", C.host
    assert_equal 9876,        C.port
    assert_equal "INFO",      C.log_level
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
    assert_equal ["SU_MCP", "host",      "10.0.0.5"], writer.writes[0]
    assert_equal ["SU_MCP", "port",      9999       ], writer.writes[1]
    assert_equal ["SU_MCP", "log_level", "WARN"     ], writer.writes[2]
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
    assert_equal "INFO", C.log_level
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

  def test_update_mutates_runtime_before_raising
    # Documented invariant: runtime is mutated BEFORE persistence (config.rb:57-65).
    # Even when write_default fails, the in-session Config reflects new values.
    writer = FailingWriter.new(fail_on_key: "log_level")
    begin
      C.update!(host: "10.0.0.5", port: 9999, log_level: "WARN", writer: writer)
    rescue RuntimeError
      # expected
    end
    assert_equal "10.0.0.5", C.host
    assert_equal 9999,       C.port
    assert_equal "WARN",     C.log_level
  end
end
