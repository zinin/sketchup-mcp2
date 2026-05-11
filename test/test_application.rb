# test/test_application.rb
require "minitest/autorun"
require_relative "../su_mcp/su_mcp/core/config"

# Stub the slice of the SketchUp Ruby API surface that Application touches at
# runtime so we can exercise lifecycle + running_config without a live SketchUp.
module Sketchup; def self.status_text=(_); end; end unless defined?(Sketchup)
module UI;       def self.messagebox(*); end;    end unless defined?(UI)
SKETCHUP_CONSOLE = nil unless defined?(SKETCHUP_CONSOLE)

require_relative "../su_mcp/su_mcp/core/logger"
require_relative "../su_mcp/su_mcp/core/application"

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
  A = SU_MCP::Core::Application

  def setup
    A.stop if A.running?
    A.server_class = StubServer
    SU_MCP::Core::Config.host      = "127.0.0.1"
    SU_MCP::Core::Config.port      = 9876
    SU_MCP::Core::Config.log_level = "INFO"
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
end
