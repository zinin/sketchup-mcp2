# test/test_application.rb
require "minitest/autorun"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "support/config_reset"

# Stub the slice of the SketchUp Ruby API surface that Application touches at
# runtime so we can exercise lifecycle + running_config without a live SketchUp.
module Sketchup; def self.status_text=(_); end; end unless defined?(Sketchup)
module UI;       def self.messagebox(*); end;    end unless defined?(UI)
SKETCHUP_CONSOLE = nil unless defined?(SKETCHUP_CONSOLE)

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/application"

class StubServer
  attr_reader :start_called, :stop_called
  def initialize; @start_called = false; @stop_called = false; end
  def start; @start_called = true; end
  def stop;  @stop_called  = true; end
end

class StubServerThatFails
  def start; raise "simulated start failure"; end
  def stop; end
end

class TestApplication < Minitest::Test
  A = MCPforSketchUp::Core::Application

  def setup
    ConfigReset.reset_all!
    A.stop if A.running?
    A.server_class = StubServer
    MCPforSketchUp::Core::Config.host      = "127.0.0.1"
    MCPforSketchUp::Core::Config.port      = 9876
    MCPforSketchUp::Core::Config.log_level = "INFO"
  end

  def teardown
    A.stop if A.running?
    A.server_class = nil  # reset so Application.server_class falls back to ::Server next time
  end

  def test_start_captures_running_config_snapshot
    A.start
    rc = A.running_config
    refute_nil rc
    assert_equal "127.0.0.1", rc[:host]
    assert_equal 9876,         rc[:port]
    assert_equal "INFO",       rc[:log_level]
  end

  def test_stop_clears_running_config
    A.start
    A.stop
    assert_nil A.running_config
    refute A.running?
  end

  def test_start_failure_leaves_running_config_nil
    A.server_class = StubServerThatFails
    A.start
    assert_nil A.running_config
    refute A.running?
  end

  # file_uri_for builds the file:// URL for "Show Log". `?` and `#` are legal in
  # POSIX filenames but are the URL query / fragment delimiters; they must be
  # percent-encoded so the OS handler opens the right file (codex 4th-review).
  def test_file_uri_for_percent_encodes_query_and_fragment_chars
    uri = A.send(:file_uri_for, "/tmp/my?log#1.log")
    assert_includes uri, "%3F",        "`?` must be percent-encoded"
    assert_includes uri, "%23",        "`#` must be percent-encoded"
    refute_includes uri, "?",          "no raw `?` may remain in the file URI"
    refute_includes uri, "#",          "no raw `#` may remain in the file URI"
    assert uri.start_with?("file:///"), "a POSIX absolute path yields file:///…"
  end
end
