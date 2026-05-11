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

  # --- one-time ENV→prefs migration banner ---

  class StubUI
    attr_reader :messages
    def initialize; @messages = []; end
    def messagebox(text); @messages << text; nil; end
  end

  def test_migration_banner_shows_once_when_env_set_and_prefs_empty
    reader = StubReader.new("migration_notified" => false)
    writer = StubWriter.new
    ui     = StubUI.new
    ENV["SKETCHUP_MCP_HOST"] = "0.0.0.0"
    begin
      C.show_migration_banner!(reader: reader, writer: writer, ui: ui)
    ensure
      ENV.delete("SKETCHUP_MCP_HOST")
    end
    assert_equal 1, ui.messages.size
    assert_includes ui.messages.first, "Plugins"
    assert_equal ["SU_MCP", "migration_notified", true], writer.writes[0]
  end

  def test_migration_banner_skipped_when_already_notified
    reader = StubReader.new("migration_notified" => true)
    writer = StubWriter.new
    ui     = StubUI.new
    ENV["SKETCHUP_MCP_PORT"] = "9999"
    begin
      C.show_migration_banner!(reader: reader, writer: writer, ui: ui)
    ensure
      ENV.delete("SKETCHUP_MCP_PORT")
    end
    assert_empty ui.messages
    assert_empty writer.writes
  end

  def test_migration_banner_skipped_when_no_env
    reader = StubReader.new
    writer = StubWriter.new
    ui     = StubUI.new
    %w[SKETCHUP_MCP_HOST SKETCHUP_MCP_PORT SKETCHUP_MCP_LOG_LEVEL].each { |v| ENV.delete(v) }
    C.show_migration_banner!(reader: reader, writer: writer, ui: ui)
    assert_empty ui.messages
    assert_empty writer.writes
  end

  def test_migration_banner_skipped_when_prefs_already_have_host
    reader = StubReader.new("host" => "192.168.1.1")
    writer = StubWriter.new
    ui     = StubUI.new
    ENV["SKETCHUP_MCP_HOST"] = "0.0.0.0"
    begin
      C.show_migration_banner!(reader: reader, writer: writer, ui: ui)
    ensure
      ENV.delete("SKETCHUP_MCP_HOST")
    end
    assert_empty ui.messages
    assert_empty writer.writes
  end
end
