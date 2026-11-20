# test/test_net.rb
# Block C (spec §7.3): Core::Net.loopback?, the one loopback check behind the
# server's bind warning and the Settings dialog's host warning.
#
# A host is loopback only when every address it resolves to is a loopback
# address. Names such as localhost are resolved; a host that does not resolve
# counts as exposed — it is warned about, never trusted.
require "minitest/autorun"
require "socket"

require_relative "support/singleton_stubs"
require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/net"

class TestNet < Minitest::Test
  include SingletonStubs

  N = MCPforSketchUp::Core::Net

  def test_loopback_hosts
    %w[127.0.0.1 127.0.0.2 ::1 localhost].each { |host| assert N.loopback?(host), host }
  end

  def test_exposed_hosts
    ["0.0.0.0", "::", "192.168.1.5", "10.0.0.7", ""].each do |host|
      refute N.loopback?(host), host.inspect
    end
  end

  def test_unresolvable_host_is_not_loopback
    stub_singleton(Addrinfo, :getaddrinfo) { |*_| raise SocketError, "getaddrinfo: Name or service not known" }
    refute N.loopback?("no-such-host.invalid")
  end

  def test_a_name_with_one_exposed_address_is_not_loopback
    addresses = [Addrinfo.ip("127.0.0.1"), Addrinfo.ip("192.168.1.5")]
    stub_singleton(Addrinfo, :getaddrinfo) { |*_| addresses }
    refute N.loopback?("split-horizon.example")
  end
end
