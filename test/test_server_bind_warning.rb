# test/test_server_bind_warning.rb
#
# Review #6: the server emits a WARN at the bind site when bound to a
# non-loopback host (e.g. 0.0.0.0) — a server-log echo of the Settings dialog's
# host-security warning. We drive the private warn_if_exposed_bind directly and
# capture the console output. Block C (spec §7.3): the host is judged by
# Core::Net.loopback?, the check the Settings dialog uses too, and the warning
# says what the token protects (who can connect) and what it does not (the
# traffic is not encrypted).
require "minitest/autorun"
require "stringio"

require_relative "support/singleton_stubs"

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/errors"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/logger"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/net"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/framing"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/client_state"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/server"
require_relative "support/config_reset"

class TestServerBindWarning < Minitest::Test
  include SingletonStubs

  def setup
    ConfigReset.reset_all!
    # WARN must be emitted at the WARN level (default). Set explicitly so the
    # capture sees it regardless of test-order leakage.
    MCPforSketchUp::Core::Config.log_level   = "WARN"
    MCPforSketchUp::Core::Config.log_to_file = false
    @srv = MCPforSketchUp::Core::Server.new
  end

  def teardown
    ConfigReset.reset_all!
  end

  # Capture everything Logger writes to the console during the block.
  def capture_console
    real = $stdout
    buf  = StringIO.new
    $stdout = buf
    yield
    buf.string
  ensure
    $stdout = real
  end

  def test_warns_for_wildcard_bind
    out = capture_console { @srv.send(:warn_if_exposed_bind, "0.0.0.0") }
    assert_match(/\[WARN\]/, out)
    assert_match(/non-loopback/, out)
    assert_match(/needs the token to connect/, out)
    assert_match(/not encrypted/, out)
    assert_match(/SSH tunnel/, out)
  end

  def test_warns_for_explicit_lan_ip
    out = capture_console { @srv.send(:warn_if_exposed_bind, "192.168.1.50") }
    assert_match(/\[WARN\]/, out)
  end

  def test_no_warning_for_loopback_ipv4
    out = capture_console { @srv.send(:warn_if_exposed_bind, "127.0.0.1") }
    assert_empty out, "127.0.0.1 must not emit an exposure warning, got: #{out.inspect}"
  end

  def test_no_warning_for_loopback_variants
    %w[::1 localhost 127.0.0.5].each do |h|
      out = capture_console { @srv.send(:warn_if_exposed_bind, h) }
      assert_empty out, "#{h} must be treated as loopback, got: #{out.inspect}"
    end
  end

  # One check for the server and the dialog: the server asks Core::Net.
  def test_the_bind_warning_asks_core_net
    stub_singleton(MCPforSketchUp::Core::Net, :loopback?) { |_host| true }
    out = capture_console { @srv.send(:warn_if_exposed_bind, "192.168.1.50") }
    assert_empty out
  end
end
